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

/// Literals are written in place. Contiguous reservations fit one 65535-byte stored block.
pub const Stream = struct {
    pub const Patch = struct { owner: *const Stream, bytes: []u8, offset: u32 };
    storage: []u8,
    writer: std.Io.Writer,
    end: usize = 2,
    decoded: u32 = 0,
    checksum: u32 = 1,
    finished: bool = false,

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

    pub fn placeholder(self: *Stream, bytes: []const u8) std.Io.Writer.Error!Patch {
        assert(!self.finished);
        if (bytes.len == 0 or bytes.len > 65535) return error.WriteFailed;
        const destination = try self.writer.writableSlice(bytes.len);
        @memcpy(destination, bytes);
        const offset = self.count() - @as(u32, @intCast(bytes.len));
        self.flushLiteral();
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

    fn refresh(self: *Stream) void {
        const start = self.end + 5;
        const available = (self.storage.len - 9) -| start;
        const length = @min(65535, available, std.math.maxInt(u32) - self.decoded);
        self.writer.buffer = self.storage[@min(start, self.storage.len)..][0..length];
        self.writer.end = 0;
    }

    fn flushLiteral(self: *Stream) void {
        assert(!self.finished);
        const bytes = self.writer.buffered();
        if (bytes.len == 0) return;
        assert(bytes.len <= 65535 and bytes.ptr == self.storage.ptr + self.end + 5);
        self.storage[self.end] = 0;
        const length: u16 = @intCast(bytes.len);
        std.mem.writeInt(u16, self.storage[self.end + 1 ..][0..2], length, .little);
        std.mem.writeInt(u16, self.storage[self.end + 3 ..][0..2], ~length, .little);
        self.checksum = combine(self.checksum, deflate.checksum(bytes), bytes.len);
        self.decoded += length;
        self.end += 5 + bytes.len;
        self.refresh();
    }

    pub fn append(self: *Stream, fragment: Fragment) std.Io.Writer.Error!void {
        assert(!self.finished and fragment.bytes.len > 0 and fragment.decoded > 0);
        self.flushLiteral();
        if (fragment.bytes.len > self.storage.len - 9 - self.end or fragment.decoded > std.math.maxInt(u32) - self.decoded) return error.WriteFailed;
        const destination = self.storage[self.end..][0..fragment.bytes.len];
        assert(@intFromPtr(fragment.bytes.ptr) + fragment.bytes.len <= @intFromPtr(destination.ptr) or
            @intFromPtr(destination.ptr) + destination.len <= @intFromPtr(fragment.bytes.ptr));
        @memcpy(destination, fragment.bytes);
        self.end += fragment.bytes.len;
        self.checksum = combine(self.checksum, fragment.checksum, fragment.decoded);
        self.decoded += fragment.decoded;
        self.refresh();
    }

    pub fn appendMany(self: *Stream, fragments: []const Fragment, digest: Digest) std.Io.Writer.Error!void {
        assert(!self.finished and fragments.len > 0);
        self.flushLiteral();
        var encoded: usize = 0;
        var decoded: u64 = 0;
        for (fragments) |fragment| {
            assert(fragment.bytes.len > 0 and fragment.decoded > 0);
            encoded = std.math.add(usize, encoded, fragment.bytes.len) catch return error.WriteFailed;
            decoded = std.math.add(u64, decoded, fragment.decoded) catch return error.WriteFailed;
        }
        assert(decoded == digest.decoded);
        if (encoded > self.storage.len - 9 - self.end or decoded > std.math.maxInt(u32) - self.decoded) return error.WriteFailed;
        for (fragments) |fragment| {
            const destination = self.storage[self.end..][0..fragment.bytes.len];
            assert(@intFromPtr(fragment.bytes.ptr) + fragment.bytes.len <= @intFromPtr(destination.ptr) or @intFromPtr(destination.ptr) + destination.len <= @intFromPtr(fragment.bytes.ptr));
            @memcpy(destination, fragment.bytes);
            self.end += fragment.bytes.len;
        }
        self.checksum = combine(self.checksum, digest.checksum, digest.decoded);
        self.decoded += digest.decoded;
        self.refresh();
    }

    pub fn finish(self: *Stream) std.Io.Writer.Error![]u8 {
        assert(!self.finished);
        self.flushLiteral();
        const checksum = self.checksum;
        assert(self.end + 9 <= self.storage.len);
        self.storage[self.end..][0..5].* = .{ 1, 0, 0, 255, 255 };
        std.mem.writeInt(u32, self.storage[self.end + 5 ..][0..4], checksum, .big);
        self.end += 9;
        self.checksum = checksum;
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
        const tail = writer.buffer[writer.end - kept .. writer.end];
        writer.end -= kept;
        self.flushLiteral();
        if (kept > writer.buffer.len or minimum > writer.buffer.len - kept) return error.WriteFailed;
        @memmove(writer.buffer[0..kept], tail);
        writer.end = kept;
    }
};
