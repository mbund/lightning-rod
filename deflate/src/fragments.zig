const std = @import("std");
const deflate = @import("deflate.zig");
const assert = std.debug.assert;

/// An independent nonfinal DEFLATE stream ending at a byte boundary.
pub const Fragment = struct {
    bytes: []const u8,
    decoded: u32,
    checksum: u32,
};

pub const Digest = struct {
    decoded: u32 = 0,
    checksum: u32 = 1,

    pub fn append(self: *Digest, fragment: Fragment) void {
        assert(fragment.decoded > 0 and fragment.decoded <= std.math.maxInt(u32) - self.decoded);
        self.checksum = combine(self.checksum, fragment.checksum, fragment.decoded);
        self.decoded += fragment.decoded;
    }
};

pub const Baker = struct {
    pub const default_level = 6;
    allocator: std.mem.Allocator,
    /// Libdeflate encodes each fragment as one block. It compresses a 2 KiB light section
    /// several times faster than std, which also rebuilt its 64 KiB hash heads per fragment.
    fast: deflate.Encoder,
    /// Encodes inputs libdeflate splits into several blocks, whose final bits it hides.
    compressor: *std.compress.flate.Compress,
    history: []u8,
    /// Compress keeps its stream functions private, so init captures them once.
    vtable: *const std.Io.Writer.VTable,
    options: std.compress.flate.Compress.Options,
    level: u4,

    pub fn init(allocator: std.mem.Allocator) !Baker {
        return initLevel(allocator, default_level);
    }

    /// Levels follow libdeflate. Above 9 its matcher exceeds the module memory limit.
    pub fn initLevel(allocator: std.mem.Allocator, level: u4) !Baker {
        if (level == 0 or level > 9) return error.InvalidLevel;
        var fast = try deflate.Encoder.init(allocator, level);
        errdefer fast.deinit();
        const compressor = try allocator.create(std.compress.flate.Compress);
        errdefer allocator.destroy(compressor);
        const history = try allocator.alloc(u8, std.compress.flate.max_window_len);
        const fallback = [_]std.compress.flate.Compress.Options{ .level_1, .level_2, .level_3, .level_4, .level_5, .level_6, .level_7, .level_8, .level_9 };
        var sink: [16]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&sink);
        compressor.* = try .init(&writer, history, .raw, .level_5);
        return .{
            .allocator = allocator,
            .fast = fast,
            .compressor = compressor,
            .history = history,
            .vtable = compressor.writer.vtable,
            .options = fallback[@min(level, fallback.len) - 1],
            .level = level,
        };
    }

    pub fn deinit(self: *Baker) void {
        self.fast.deinit();
        self.allocator.destroy(self.compressor);
        self.allocator.free(self.history);
        self.* = undefined;
    }

    pub fn memoryBytes(self: *const Baker) usize {
        return self.fast.memory_bytes + @sizeOf(std.compress.flate.Compress) + self.history.len;
    }

    /// Borrows output. Compression and all of its working memory are reused.
    pub fn encode(self: *Baker, input: []const u8, output: []u8) !Fragment {
        assert(input.len > 0 and input.len <= std.math.maxInt(u32));
        if (self.fast.fragment(input, output)) |bytes| return .{ .bytes = bytes, .decoded = @intCast(input.len), .checksum = deflate.checksum(input) };
        return self.encodeStd(input, output);
    }

    /// The path for inputs libdeflate splits into several blocks. Public so tests reach it.
    pub fn encodeStd(self: *Baker, input: []const u8, output: []u8) !Fragment {
        assert(input.len > 0 and input.len <= std.math.maxInt(u32));
        var writer: std.Io.Writer = .fixed(output);
        self.reset(&writer);
        try self.compressor.writer.writeAll(input);
        try self.compressor.writer.flush();
        return .{ .bytes = writer.buffered(), .decoded = @intCast(input.len), .checksum = deflate.checksum(input) };
    }

    /// Matches Compress.init for a raw stream without building a new value. Assigning init
    /// copied all 224 KiB through an error union, which cost more than compressing a section.
    fn reset(self: *Baker, writer: *std.Io.Writer) void {
        const options = self.options;
        assert(options.chain != 0 and options.good >= 3 and options.nice >= 3);
        assert(options.good <= 258 and options.nice <= 258 and options.lazy <= options.nice);
        const compressor = self.compressor;
        compressor.writer = .{ .buffer = self.history, .vtable = self.vtable };
        compressor.history_len = 0;
        compressor.history_end_unhashed = false;
        compressor.bit_writer = .init(writer);
        compressor.buffered_tokens.pos = 0;
        compressor.buffered_tokens.n = 0;
        @memset(&compressor.buffered_tokens.lit_freqs, 0);
        @memset(&compressor.buffered_tokens.dist_freqs, 0);
        // Every head is null with the maximum position, as init sets it.
        @memset(&compressor.lookup.head, @bitCast(@as(u16, std.math.maxInt(u16))));
        compressor.lookup.chain_pos = std.math.maxInt(u15);
        compressor.container = .raw;
        compressor.hasher = .init(.raw);
        compressor.opts = options;
    }
};

/// Patterns and their baker outlive the cache. One owner builds each immutable result once.
pub fn Repetitions(comptime encoded_maximum: usize) type {
    return struct {
        const Self = @This();
        const Entry = struct { state: enum { empty, ready, literal }, fragment: Fragment, bytes: [encoded_maximum]u8 };
        allocator: std.mem.Allocator,
        patterns: []const []const u8,
        maximum: usize,
        entries: []Entry,
        scratch: []u8,
        baker: *Baker,

        pub fn init(allocator: std.mem.Allocator, patterns: []const []const u8, maximum: usize, baker: *Baker) !Self {
            if (maximum == 0 or encoded_maximum <= 8) return error.InvalidArgument;
            var length: usize = 0;
            for (patterns) |pattern| {
                if (pattern.len == 0) return error.InvalidArgument;
                length = @max(length, pattern.len);
            }
            const bytes = try std.math.mul(usize, length, maximum);
            if (bytes > std.math.maxInt(u32)) return error.InvalidArgument;
            const entries = try allocator.alloc(Entry, try std.math.mul(usize, patterns.len, maximum));
            errdefer allocator.free(entries);
            for (entries) |*entry| entry.state = .empty;
            return .{ .allocator = allocator, .patterns = patterns, .maximum = maximum, .entries = entries, .scratch = try allocator.alloc(u8, bytes), .baker = baker };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.entries);
            self.allocator.free(self.scratch);
            self.* = undefined;
        }

        pub fn get(self: *Self, pattern: usize, count: usize) !?Fragment {
            assert(pattern < self.patterns.len and count > 0 and count <= self.maximum);
            const entry = &self.entries[pattern * self.maximum + count - 1];
            switch (entry.state) {
                .ready => return entry.fragment,
                .literal => return null,
                .empty => {},
            }
            var writer: std.Io.Writer = .fixed(self.scratch);
            try writer.splatBytesAll(self.patterns[pattern], count);
            const fragment = self.baker.encode(writer.buffered(), &entry.bytes) catch {
                entry.state = .literal;
                return null;
            };
            if (fragment.bytes.len >= fragment.decoded) {
                entry.state = .literal;
                return null;
            }
            entry.fragment = fragment;
            entry.state = .ready;
            assert(fragment.decoded == self.patterns[pattern].len * count);
            return fragment;
        }
    };
}

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    codec: deflate.Decoder,
    frame: []u8,

    pub fn init(allocator: std.mem.Allocator, maximum: usize) !Decoder {
        var codec = try deflate.Decoder.init(allocator);
        errdefer codec.deinit();
        const frame = try allocator.alloc(u8, try std.math.add(usize, maximum, 11));
        return .{ .allocator = allocator, .codec = codec, .frame = frame };
    }

    pub fn deinit(self: *Decoder) void {
        self.codec.deinit();
        self.allocator.free(self.frame);
        self.* = undefined;
    }

    pub fn decode(self: *Decoder, fragment: Fragment, output: []u8) ![]u8 {
        if (fragment.decoded > output.len or fragment.bytes.len > self.frame.len - 11) return error.InvalidData;
        var writer = try Stream.begin(self.frame);
        try writer.append(fragment);
        const frame = try writer.finish();
        const decoded = try self.codec.decode(frame, output[0..fragment.decoded]);
        if (decoded.len != fragment.decoded) return error.InvalidData;
        return decoded;
    }
};

fn combine(a: u32, b: u32, length: usize) u32 {
    const prime = 65521;
    const a1: u64 = a & 65535;
    const b1: u64 = b & 65535;
    const low = (a1 + b1 + prime - 1) % prime;
    const high = ((a >> 16) + @as(u64, b >> 16) + ((a1 + prime - 1) % prime) * (length % prime)) % prime;
    return @as(u32, @intCast(high << 16 | low));
}

/// Joins fragments into one zlib stream at the bit where each one's data ends, and writes the
/// bytes between them as fixed Huffman literal blocks with runs of one byte as matches. Literals
/// collect high in the output and are encoded below, which never overtakes them. Fragments that
/// carry no end marker join at a byte boundary instead. Patched bytes stay in stored blocks.
pub const Stream = struct {
    pub const Patch = struct { owner: *const Stream, bytes: []u8, offset: u32 };
    storage: []u8,
    writer: std.Io.Writer,
    /// Whole bytes written, then `bit_count` more bits held in `bits`.
    end: usize = 2,
    bits: u8 = 0,
    bit_count: u3 = 0,
    decoded: u32 = 0,
    checksum: u32 = 1,
    finished: bool = false,

    /// Room kept for the final block, its padding and the checksum.
    const tail_room = 8;

    pub fn begin(output: []u8) std.Io.Writer.Error!Stream {
        if (output.len < 11) return error.WriteFailed;
        output[0..2].* = .{ 0x78, 0x01 };
        var result: Stream = .{ .storage = output, .writer = .{ .vtable = &.{ .drain = drain, .rebase = rebase }, .buffer = &.{} } };
        result.refresh();
        return result;
    }

    pub fn count(self: *const Stream) u32 {
        assert(!self.finished);
        return self.decoded + @as(u32, @intCast(self.writer.end));
    }

    /// Bytes a later `patch` rewrites, in a stored block of their own.
    pub fn placeholder(self: *Stream, bytes: []const u8) std.Io.Writer.Error!Patch {
        assert(!self.finished);
        if (bytes.len == 0 or bytes.len > 65535) return error.WriteFailed;
        self.flushLiteral();
        const offset = self.decoded;
        const destination = try self.stored(bytes);
        return .{ .owner = self, .bytes = destination, .offset = offset };
    }

    pub fn patch(self: *Stream, field: Patch, bytes: []const u8) void {
        assert(!self.finished and field.owner == self and bytes.len == field.bytes.len);
        assert(field.offset <= self.decoded and bytes.len <= self.decoded - field.offset);
        var a: i64 = self.checksum & 65535;
        var b: i64 = self.checksum >> 16;
        for (field.bytes, bytes, 0..) |before, after, index| {
            const difference = @as(i64, after) - before;
            a += difference;
            // Adler's second sum weights each byte by the following decoded length.
            b += difference * @as(i64, @intCast(self.decoded - field.offset - index));
        }
        self.checksum = @as(u32, @intCast(@mod(b, 65521))) << 16 | @as(u32, @intCast(@mod(a, 65521)));
        @memcpy(field.bytes, bytes);
    }

    /// Bytes from `end` on that output can reach, short of the tail room.
    fn limit(self: *const Stream) usize {
        return self.storage.len -| tail_room;
    }

    /// Places the literal buffer where encoding its contents can never write past what it has
    /// read: a fixed block spends at most nine bits on a byte, plus a header and an end.
    fn refresh(self: *Stream) void {
        const top = self.limit();
        const start = @min(top, (8 * (self.end + 4) + top + 8) / 9 + 1);
        const length = @min(65535, top - start, std.math.maxInt(u32) - self.decoded);
        self.writer.buffer = self.storage[start..][0..length];
        self.writer.end = 0;
    }

    fn put(self: *Stream, value: u32, width: u6) void {
        assert(width <= 25 and (width == 0 or value >> @intCast(width) == 0));
        var accumulator: u64 = @as(u64, self.bits) | @as(u64, value) << self.bit_count;
        var pending: u6 = @as(u6, self.bit_count) + width;
        while (pending >= 8) : (pending -= 8) {
            self.storage[self.end] = @truncate(accumulator);
            self.end += 1;
            accumulator >>= 8;
        }
        self.bits = @truncate(accumulator);
        self.bit_count = @intCast(pending);
    }

    /// Ends the current byte with the header of a stored block and its padding.
    fn toBoundary(self: *Stream, final: bool) void {
        self.put(@intFromBool(final), 3);
        if (self.bit_count != 0) self.put(0, 8 - @as(u6, self.bit_count));
    }

    /// Writes bytes as one stored block and returns where they landed.
    fn stored(self: *Stream, bytes: []const u8) std.Io.Writer.Error![]u8 {
        if (bytes.len + 6 > self.limit() -| self.end) return error.WriteFailed;
        self.toBoundary(false);
        const length: u16 = @intCast(bytes.len);
        std.mem.writeInt(u16, self.storage[self.end..][0..2], length, .little);
        std.mem.writeInt(u16, self.storage[self.end + 2 ..][0..2], ~length, .little);
        self.end += 4;
        const destination = self.storage[self.end..][0..bytes.len];
        std.mem.copyForwards(u8, destination, bytes);
        self.end += bytes.len;
        self.checksum = combine(self.checksum, deflate.checksum(bytes), bytes.len);
        self.decoded += length;
        self.refresh();
        return destination;
    }

    fn flushLiteral(self: *Stream) void {
        assert(!self.finished);
        const bytes = self.writer.buffered();
        if (bytes.len == 0) return;
        self.checksum = combine(self.checksum, deflate.checksum(bytes), bytes.len);
        self.decoded += @intCast(bytes.len);
        // A nonfinal block of fixed codes.
        self.put(0b010, 3);
        var at: usize = 0;
        while (at < bytes.len) {
            const byte = bytes[at];
            self.symbol(byte);
            at += 1;
            // A run of the byte just written is one match a byte back, in pieces of at most 258.
            var run: usize = 0;
            while (at + run < bytes.len and bytes[at + run] == byte) run += 1;
            while (run >= 3) {
                const length = @min(run, 258);
                self.match(length);
                at += length;
                run -= length;
            }
        }
        self.symbol(256);
        self.refresh();
    }

    fn symbol(self: *Stream, value: u16) void {
        const entry = fixed_codes[value];
        self.put(entry.code, entry.bits);
    }

    /// A match one byte back.
    fn match(self: *Stream, length: usize) void {
        assert(length >= 3 and length <= 258);
        var code: usize = 28;
        while (length_base[code] > length) code -= 1;
        self.symbol(@intCast(257 + code));
        self.put(@intCast(length - length_base[code]), length_extra[code]);
        // Distance code zero, a distance of one, five zero bits.
        self.put(0, 5);
    }

    pub fn append(self: *Stream, fragment: Fragment) std.Io.Writer.Error!void {
        assert(!self.finished and fragment.bytes.len > 0 and fragment.decoded > 0);
        self.flushLiteral();
        if (fragment.decoded > std.math.maxInt(u32) - self.decoded) return error.WriteFailed;
        try self.join(fragment.bytes);
        self.checksum = combine(self.checksum, fragment.checksum, fragment.decoded);
        self.decoded += fragment.decoded;
        self.refresh();
    }

    pub fn appendMany(self: *Stream, fragments: []const Fragment, digest: Digest) std.Io.Writer.Error!void {
        assert(!self.finished and fragments.len > 0);
        self.flushLiteral();
        var decoded: u64 = 0;
        for (fragments) |fragment| {
            assert(fragment.bytes.len > 0 and fragment.decoded > 0);
            decoded = std.math.add(u64, decoded, fragment.decoded) catch return error.WriteFailed;
        }
        assert(decoded == digest.decoded);
        if (decoded > std.math.maxInt(u32) - self.decoded) return error.WriteFailed;
        for (fragments) |fragment| try self.join(fragment.bytes);
        self.checksum = combine(self.checksum, digest.checksum, digest.decoded);
        self.decoded += digest.decoded;
        self.refresh();
    }

    /// Copies a fragment's blocks. One that marks where its data ends joins at that bit and
    /// leaves its closing stored block out. Any other joins whole at a byte boundary.
    fn join(self: *Stream, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len + 6 > self.limit() -| self.end) return error.WriteFailed;
        assert(@intFromPtr(bytes.ptr) + bytes.len <= @intFromPtr(self.storage.ptr + self.end) or
            @intFromPtr(self.storage.ptr + self.end + bytes.len + 6) <= @intFromPtr(bytes.ptr));
        const data = dataBits(bytes) orelse {
            if (self.bit_count != 0) {
                self.toBoundary(false);
                self.storage[self.end..][0..4].* = .{ 0, 0, 0xff, 0xff };
                self.end += 4;
            }
            @memcpy(self.storage[self.end..][0..bytes.len], bytes);
            self.end += bytes.len;
            return;
        };
        const whole = data / 8;
        // A stored block keeps its bytes on byte boundaries, so it cannot shift. Its header goes
        // here, padding follows, and its lengths and bytes copy whole. A baked fragment is one
        // block, so a stored one ends on a boundary too.
        if ((bytes[0] >> 1) & 3 == 0) {
            if (data % 8 != 0 or whole < 5) return error.WriteFailed;
            self.toBoundary(false);
            @memcpy(self.storage[self.end..][0 .. whole - 1], bytes[1..whole]);
            self.end += whole - 1;
            return;
        }
        if (self.bit_count == 0) {
            @memcpy(self.storage[self.end..][0..whole], bytes[0..whole]);
            self.end += whole;
        } else {
            // Each source byte splits across two output bytes.
            const shift: u3 = self.bit_count;
            var carry: u8 = self.bits;
            for (bytes[0..whole]) |byte| {
                self.storage[self.end] = carry | (byte << shift);
                self.end += 1;
                carry = byte >> @intCast(8 - @as(u4, shift));
            }
            self.bits = carry;
        }
        const rest: u3 = @intCast(data % 8);
        if (rest != 0) self.put(bytes[whole] & ((@as(u8, 1) << rest) - 1), rest);
    }

    pub fn finish(self: *Stream) std.Io.Writer.Error![]u8 {
        assert(!self.finished);
        self.flushLiteral();
        // An empty final block of fixed codes, then the boundary and the checksum.
        if (self.end + 6 > self.storage.len) return error.WriteFailed;
        self.put(0b011, 3);
        self.symbol(256);
        if (self.bit_count != 0) self.put(0, 8 - @as(u6, self.bit_count));
        std.mem.writeInt(u32, self.storage[self.end..][0..4], self.checksum, .big);
        self.end += 4;
        self.finished = true;
        return self.storage[0..self.end];
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Stream = @alignCast(@fieldParentPtr("writer", writer));
        self.flushLiteral();
        var written: usize = 0;
        for (data, 0..) |slice, index| {
            const repeats = if (index + 1 == data.len) splat else 1;
            if (slice.len == 0 or repeats == 0) continue;
            if (writer.buffer.len == writer.end) return if (written == 0) error.WriteFailed else written;
            if (slice.len == 1) {
                const length = @min(repeats, writer.buffer.len - writer.end);
                @memset(writer.buffer[writer.end..][0..length], slice[0]);
                writer.end += length;
                written += length;
                if (length != repeats) return written;
                continue;
            }
            for (0..repeats) |_| {
                const length = @min(slice.len, writer.buffer.len - writer.end);
                @memcpy(writer.buffer[writer.end..][0..length], slice[0..length]);
                writer.end += length;
                written += length;
                if (length != slice.len) return written;
            }
        }
        return written;
    }

    fn rebase(writer: *std.Io.Writer, preserve: usize, minimum: usize) std.Io.Writer.Error!void {
        const self: *Stream = @alignCast(@fieldParentPtr("writer", writer));
        const kept = @min(preserve, writer.end);
        // Encoding writes below the literal buffer, so the kept bytes survive the flush in place.
        const tail = writer.buffer[writer.end - kept .. writer.end];
        writer.end -= kept;
        self.flushLiteral();
        if (kept > writer.buffer.len or minimum > writer.buffer.len - kept) return error.WriteFailed;
        const destination = writer.buffer[0..kept];
        if (@intFromPtr(destination.ptr) <= @intFromPtr(tail.ptr)) std.mem.copyForwards(u8, destination, tail) else std.mem.copyBackwards(u8, destination, tail);
        writer.end = kept;
    }
};

/// Where a fragment's data ends, in bits, when its closing stored block is padded with ones:
/// the three zero bits of the stored header sit right below the padding. Null for fragments
/// padded with zeros, whose end cannot be told from their data.
fn dataBits(bytes: []const u8) ?usize {
    if (bytes.len < 6 or !std.mem.eql(u8, bytes[bytes.len - 4 ..], &.{ 0, 0, 0xff, 0xff })) return null;
    const last = bytes[bytes.len - 5];
    if (last & 0x80 == 0) return null;
    const padding: usize = @clz(~last);
    return (bytes.len - 5) * 8 + (8 - padding) - 3;
}

const length_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const length_extra = [29]u6{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };

/// DEFLATE's fixed literal and length codes, bit reversed for least significant bit first output.
const fixed_codes = codes: {
    var table: [288]struct { code: u16, bits: u6 } = undefined;
    for (&table, 0..) |*entry, symbol| {
        const code: u16, const bits: u6 = if (symbol < 144) .{ 0x30 + symbol, 8 } else if (symbol < 256) .{ 0x190 + symbol - 144, 9 } else if (symbol < 280) .{ symbol - 256, 7 } else .{ 0xc0 + symbol - 280, 8 };
        entry.* = .{ .code = @bitReverse(code) >> @intCast(16 - bits), .bits = bits };
    }
    break :codes table;
};
