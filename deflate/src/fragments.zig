const std = @import("std");
const deflate = @import("deflate.zig");
const generated = @import("fragment_table.zig");
const assert = std.debug.assert;

/// Data coded with the shared table and no block around it, then one marker bit and zero
/// padding, so the highest set bit of the last byte is where the data ends.
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

pub const literal_symbols = 286;
pub const distance_symbols = 30;
/// The longest literal or length code, which bounds what any byte costs.
pub const maximum_literal_bits = 13;
const maximum_distance_bits = 15;

/// Code lengths for both alphabets. Every symbol has a code, so any bytes can be written.
pub const Table = struct {
    literal: [literal_symbols]u8,
    distance: [distance_symbols]u8,

    /// The lengths themselves, which caches of fragments coded with the table hash.
    pub fn identity(self: *const Table) [literal_symbols + distance_symbols]u8 {
        return self.literal ++ self.distance;
    }

    /// Lengths of complete prefix codes within the limits the stitcher assumes.
    pub fn valid(self: *const Table) bool {
        return complete(&self.literal, maximum_literal_bits) and complete(&self.distance, maximum_distance_bits);
    }

    fn complete(lengths: []const u8, maximum: u8) bool {
        var space: u64 = 0;
        for (lengths) |length| {
            if (length == 0 or length > maximum) return false;
            space += @as(u64, 1) << @intCast(15 - length);
        }
        return space == 1 << 15;
    }
};

pub const shared: Table = .{ .literal = generated.literal, .distance = generated.distance };

comptime {
    assert(shared.valid());
}

/// Bytes a fragment of `length` input bytes takes at most: every byte as its longest literal,
/// then the marker.
pub fn bound(length: usize) usize {
    return (length * maximum_literal_bits + 7) / 8 + 1;
}

/// How often a parse used each symbol, for training a table.
pub const Counts = struct {
    literal: [literal_symbols]u64 = @splat(0),
    distance: [distance_symbols]u64 = @splat(0),
};

/// Huffman code lengths of at most `maximum` bits for symbols with nonzero counts, and zero for
/// the rest. Counts are halved until the longest code fits.
pub fn huffmanLengths(counts: []const u64, lengths: []u8, maximum: u4) void {
    assert(counts.len == lengths.len and counts.len <= 2 * literal_symbols);
    var used: usize = 0;
    for (counts) |value| used += @intFromBool(value != 0);
    assert(used >= 2 and maximum >= std.math.log2_int_ceil(usize, used));
    var shift: u6 = 0;
    while (true) : (shift += 1) {
        var weights: [2 * literal_symbols]u64 = undefined;
        var parents: [2 * literal_symbols]usize = undefined;
        var active: [2 * literal_symbols]bool = @splat(false);
        for (counts, 0..) |value, index| {
            weights[index] = if (value == 0) 0 else (value >> shift) + 1;
            active[index] = value != 0;
        }
        var nodes = counts.len;
        while (true) {
            var first: ?usize = null;
            var second: ?usize = null;
            for (0..nodes) |index| {
                if (!active[index]) continue;
                if (first == null or weights[index] < weights[first.?]) {
                    second = first;
                    first = index;
                } else if (second == null or weights[index] < weights[second.?]) second = index;
            }
            if (second == null) break;
            weights[nodes] = weights[first.?] + weights[second.?];
            active[nodes] = true;
            active[first.?] = false;
            active[second.?] = false;
            parents[first.?] = nodes;
            parents[second.?] = nodes;
            nodes += 1;
        }
        var longest: usize = 0;
        for (counts, lengths, 0..) |value, *length, index| {
            var depth: usize = 0;
            if (value != 0) {
                var node = index;
                while (node != nodes - 1) : (depth += 1) node = parents[node];
            }
            length.* = @intCast(@min(depth, 255));
            longest = @max(longest, depth);
        }
        if (longest <= maximum) return;
    }
}

const Code = struct { code: u16, bits: u6 };

/// Canonical codes for lengths, bit reversed for least significant bit first output.
fn canonical(comptime count: usize, lengths: *const [count]u8) [count]Code {
    var per_length: [16]u16 = @splat(0);
    for (lengths) |length| per_length[length] += 1;
    per_length[0] = 0;
    var next: [16]u16 = undefined;
    var code: u16 = 0;
    for (1..16) |length| {
        code = (code + per_length[length - 1]) << 1;
        next[length] = code;
    }
    var result: [count]Code = undefined;
    for (lengths, 0..) |length, symbol| {
        if (length == 0) {
            result[symbol] = .{ .code = 0, .bits = 0 };
            continue;
        }
        result[symbol] = .{ .code = @bitReverse(next[length]) >> @intCast(16 - @as(u5, @intCast(length))), .bits = @intCast(length) };
        next[length] += 1;
    }
    return result;
}

/// What canonical decoding needs: codes per length and symbols in code order.
fn Decoding(comptime count: usize) type {
    return struct {
        per_length: [16]u16,
        symbols: [count]u16,

        fn of(lengths: *const [count]u8) @This() {
            var result: @This() = .{ .per_length = @splat(0), .symbols = undefined };
            for (lengths) |length| result.per_length[length] += 1;
            var offsets: [16]u16 = undefined;
            offsets[1] = 0;
            for (1..15) |length| offsets[length + 1] = offsets[length] + result.per_length[length];
            for (lengths, 0..) |length, symbol| {
                result.symbols[offsets[length]] = @intCast(symbol);
                offsets[length] += 1;
            }
            return result;
        }

        fn decode(self: *const @This(), reader: *Reader) u16 {
            var code: u32 = 0;
            var first: u32 = 0;
            var index: u32 = 0;
            for (1..16) |length| {
                code |= reader.bit();
                const here = self.per_length[length];
                if (code < first + here) return self.symbols[index + code - first];
                index += here;
                first = (first + here) << 1;
                code <<= 1;
            }
            unreachable;
        }
    };
}

const literal_codes = canonical(literal_symbols, &shared.literal);
const distance_codes = canonical(distance_symbols, &shared.distance);
const literal_decoding = Decoding(literal_symbols).of(&shared.literal);
const distance_decoding = Decoding(distance_symbols).of(&shared.distance);

const length_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const length_extra = [29]u6{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const distance_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const distance_extra = [30]u6{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

/// The length symbol of each match length, offset from 257.
const length_codes = codes: {
    @setEvalBranchQuota(10_000);
    var table: [259]u8 = @splat(0);
    for (3..259) |length| {
        var code: u8 = 28;
        while (length_base[code] > length) code -= 1;
        table[length] = code;
    }
    break :codes table;
};

fn distanceSlot(distance: usize) usize {
    assert(distance >= 1 and distance <= 32768);
    if (distance <= 4) return distance - 1;
    const bits = std.math.log2_int(usize, distance - 1);
    return 2 * bits + @intFromBool((distance - 1) >> @intCast(bits - 1) & 1 != 0);
}

/// Bits each choice costs under a table.
const Costs = struct {
    literal: [256]u8,
    /// A match's length symbol and extra bits, by length.
    length: [259]u8,
    /// A distance symbol and extra bits, by slot.
    distance: [distance_symbols]u8,

    fn of(table: *const Table) Costs {
        var result: Costs = .{ .literal = table.literal[0..256].*, .length = @splat(0), .distance = undefined };
        for (3..259) |length| result.length[length] = table.literal[257 + @as(usize, length_codes[length])] + length_extra[length_codes[length]];
        for (&result.distance, table.distance, distance_extra) |*cost, bits, extra| cost.* = bits + extra;
        return result;
    }
};

const shared_costs = Costs.of(&shared);

/// Bits written least significant first into a buffer the caller sized.
const Writer = struct {
    bytes: []u8,
    end: usize = 0,
    accumulator: u64 = 0,
    count: u6 = 0,

    fn put(self: *Writer, value: u32, width: u6) void {
        assert(width <= 32 and (width == 32 or value >> @intCast(width) == 0));
        self.accumulator |= @as(u64, value) << self.count;
        self.count += width;
        while (self.count >= 8) : (self.count -= 8) {
            self.bytes[self.end] = @truncate(self.accumulator);
            self.end += 1;
            self.accumulator >>= 8;
        }
    }

    fn code(self: *Writer, entry: Code) void {
        self.put(entry.code, entry.bits);
    }

    fn pad(self: *Writer) void {
        if (self.count != 0) self.put(0, 8 - self.count);
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize,

    fn bit(self: *Reader) u1 {
        const value: u1 = @truncate(self.bytes[self.position / 8] >> @intCast(self.position % 8));
        self.position += 1;
        return value;
    }

    fn take(self: *Reader, width: u6) u32 {
        var value: u32 = 0;
        for (0..width) |index| value |= @as(u32, self.bit()) << @intCast(index);
        return value;
    }
};

/// The dynamic block header every stitched stream opens with: final, the shared lengths, and
/// those lengths run length coded under a code of their own.
const header = header: {
    @setEvalBranchQuota(2_000_000);
    const all = shared.identity();
    const Token = struct { symbol: u5, extra: u2 };
    var tokens: [all.len]Token = undefined;
    var token_count: usize = 0;
    var at: usize = 0;
    while (at < all.len) {
        var run: usize = 1;
        while (at + run < all.len and all[at + run] == all[at]) run += 1;
        tokens[token_count] = .{ .symbol = all[at], .extra = 0 };
        token_count += 1;
        var left = run - 1;
        while (left >= 3) {
            const repeat = @min(left, 6);
            tokens[token_count] = .{ .symbol = 16, .extra = repeat - 3 };
            token_count += 1;
            left -= repeat;
        }
        for (0..left) |_| {
            tokens[token_count] = .{ .symbol = all[at], .extra = 0 };
            token_count += 1;
        }
        at += run;
    }
    var counts: [19]u64 = @splat(0);
    for (tokens[0..token_count]) |token| counts[token.symbol] += 1;
    var lengths: [19]u8 = undefined;
    huffmanLengths(&counts, &lengths, 7);
    const codes = canonical(19, &lengths);
    const order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
    var used: usize = 19;
    while (used > 4 and lengths[order[used - 1]] == 0) used -= 1;
    var bytes: [256]u8 = @splat(0);
    var writer: Writer = .{ .bytes = &bytes };
    writer.put(0b101, 3);
    writer.put(literal_symbols - 257, 5);
    writer.put(distance_symbols - 1, 5);
    writer.put(used - 4, 4);
    for (order[0..used]) |symbol| writer.put(lengths[symbol], 3);
    for (tokens[0..token_count]) |token| {
        writer.code(codes[token.symbol]);
        if (token.symbol == 16) writer.put(token.extra, 2);
    }
    const bits = writer.end * 8 + writer.count;
    writer.pad();
    const end = writer.end;
    const Header = struct { bytes: [end]u8, bits: usize };
    break :header Header{ .bytes = bytes[0..end].*, .bits = bits };
};

/// Room a stream needs around the fragments and literals it holds.
pub const stream_overhead = 2 + header.bytes.len + Stream.tail_room + 2;

/// Codes fragments with the shared table. Its costs are fixed, so the cheapest parse of the
/// matches it finds is one pass of shortest paths, and no table is built per fragment.
pub const Baker = struct {
    /// Fragments are sections, light layers and heightmaps, all well below this.
    pub const maximum_input = 16384;
    const hash_bits = 14;
    /// Candidates each position compares, and the length that ends its search.
    const chain_limit = 16;
    const nice_length = 64;
    const none = std.math.maxInt(u16);
    const literal_step = 0;

    allocator: std.mem.Allocator,
    state: *State,

    const State = struct {
        /// A position plus the base of the input it came from. Heads from earlier inputs fall
        /// below the current base and read as empty, so nothing is cleared per input.
        head: [1 << hash_bits]u32,
        base: u32,
        previous: [maximum_input]u16,
        /// Bits to reach each position, then the steps of the chosen path in reverse.
        cost: [maximum_input + 1]u32,
        /// How each position is reached: a literal, or a length with its distance above bit 9.
        step: [maximum_input + 1]u32,
    };

    pub fn init(allocator: std.mem.Allocator) !Baker {
        const state = try allocator.create(State);
        state.head = @splat(0);
        state.base = 1;
        return .{ .allocator = allocator, .state = state };
    }

    pub fn deinit(self: *Baker) void {
        self.allocator.destroy(self.state);
        self.* = undefined;
    }

    pub fn memoryBytes(self: *const Baker) usize {
        _ = self;
        return @sizeOf(State);
    }

    /// Borrows output. `bound(input.len)` bytes always suffice.
    pub fn encode(self: *Baker, input: []const u8, output: []u8) error{ InputTooLarge, NoSpaceLeft }!Fragment {
        assert(input.len > 0);
        if (input.len > maximum_input) return error.InputTooLarge;
        const bits = self.parse(input, &shared_costs);
        if (bits / 8 + 1 > output.len) return error.NoSpaceLeft;
        const steps = self.path(input.len);
        var writer: Writer = .{ .bytes = output };
        var at: usize = 0;
        var index = steps.len;
        while (index > 0) {
            index -= 1;
            const step = steps[index];
            if (step == literal_step) {
                writer.code(literal_codes[input[at]]);
                at += 1;
                continue;
            }
            const length = step & 511;
            const distance = step >> 9;
            const code = length_codes[length];
            writer.code(literal_codes[257 + @as(usize, code)]);
            writer.put(length - length_base[code], length_extra[code]);
            const slot = distanceSlot(distance);
            writer.code(distance_codes[slot]);
            writer.put(distance - distance_base[slot], distance_extra[slot]);
            at += length;
        }
        assert(at == input.len and writer.end * 8 + writer.count == bits);
        writer.put(1, 1);
        writer.pad();
        return .{ .bytes = output[0..writer.end], .decoded = @intCast(input.len), .checksum = deflate.checksum(input) };
    }

    /// Bits the cheapest parse under a table costs, adding the symbols it used to counts.
    pub fn measure(self: *Baker, input: []const u8, table: *const Table, counts: *Counts) usize {
        assert(input.len > 0 and input.len <= maximum_input and table.valid());
        const costs = Costs.of(table);
        const bits = self.parse(input, &costs);
        const steps = self.path(input.len);
        var at: usize = 0;
        var index = steps.len;
        while (index > 0) {
            index -= 1;
            const step = steps[index];
            if (step == literal_step) {
                counts.literal[input[at]] += 1;
                at += 1;
                continue;
            }
            counts.literal[257 + @as(usize, length_codes[step & 511])] += 1;
            counts.distance[distanceSlot(step >> 9)] += 1;
            at += step & 511;
        }
        return bits;
    }

    /// Finds the cheapest bits to reach every position from the matches the chains offer.
    /// Every length of every longer match is a candidate, so a shorter match that leaves a
    /// cheaper continuation wins.
    fn parse(self: *Baker, input: []const u8, costs: *const Costs) u32 {
        const state = self.state;
        const n = input.len;
        if (state.base > std.math.maxInt(u32) - 2 * maximum_input) {
            @memset(&state.head, 0);
            state.base = 1;
        }
        const base = state.base;
        state.base += @intCast(n + 1);
        const cost = state.cost[0 .. n + 1];
        @memset(cost[1..], std.math.maxInt(u32));
        cost[0] = 0;
        var skip_until: usize = 0;
        for (0..n) |at| {
            const here = cost[at];
            const literal = here + costs.literal[input[at]];
            if (literal < cost[at + 1]) {
                cost[at + 1] = literal;
                state.step[at + 1] = literal_step;
            }
            if (at + 3 > n) continue;
            const key = @as(u32, input[at]) | @as(u32, input[at + 1]) << 8 | @as(u32, input[at + 2]) << 16;
            const hash = (key *% 0x9e3779b1) >> (32 - hash_bits);
            const tagged = state.head[hash];
            state.head[hash] = base + @as(u32, @intCast(at));
            state.previous[at] = if (tagged >= base) @intCast(tagged - base) else none;
            // Inside a long match, positions join the chains but search nothing.
            if (at < skip_until) continue;
            var candidate = state.previous[at];
            var best: usize = 2;
            var remaining: usize = chain_limit;
            const limit = @min(258, n - at);
            while (candidate != none and remaining > 0) : (remaining -= 1) {
                const from: usize = candidate;
                candidate = state.previous[from];
                if (input[from + best] != input[at + best]) continue;
                const length = matchLength(input, from, at, limit);
                if (length <= best) continue;
                const distance_cost = costs.distance[distanceSlot(at - from)];
                const step: u32 = @intCast((at - from) << 9);
                for (best + 1..length + 1) |each| {
                    const total = here + costs.length[each] + distance_cost;
                    if (total < cost[at + each]) {
                        cost[at + each] = total;
                        state.step[at + each] = step | @as(u32, @intCast(each));
                    }
                }
                best = length;
                if (length >= nice_length or length == limit) {
                    skip_until = at + length;
                    break;
                }
            }
        }
        return cost[n];
    }

    /// The chosen steps from the end back to the start, kept in the cost array.
    fn path(self: *Baker, n: usize) []const u32 {
        const state = self.state;
        var position = n;
        var count: usize = 0;
        while (position > 0) {
            const step = state.step[position];
            state.cost[count] = step;
            count += 1;
            position -= if (step == literal_step) 1 else step & 511;
        }
        return state.cost[0..count];
    }

    fn matchLength(input: []const u8, from: usize, at: usize, limit: usize) usize {
        var length: usize = 0;
        while (length + 8 <= limit) {
            const a = std.mem.readInt(u64, input[from + length ..][0..8], .little);
            const b = std.mem.readInt(u64, input[at + length ..][0..8], .little);
            if (a != b) return length + @ctz(a ^ b) / 8;
            length += 8;
        }
        while (length < limit and input[from + length] == input[at + length]) length += 1;
        return length;
    }
};

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
        const frame = try allocator.alloc(u8, try std.math.add(usize, maximum, stream_overhead));
        return .{ .allocator = allocator, .codec = codec, .frame = frame };
    }

    pub fn deinit(self: *Decoder) void {
        self.codec.deinit();
        self.allocator.free(self.frame);
        self.* = undefined;
    }

    pub fn decode(self: *Decoder, fragment: Fragment, output: []u8) ![]u8 {
        if (fragment.decoded > output.len or fragment.bytes.len > self.frame.len - stream_overhead) return error.InvalidData;
        var writer = try Stream.begin(self.frame);
        try writer.append(fragment);
        const frame = try writer.seal(false);
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

/// One zlib stream of a single block under the shared table. Fragments join at the bit their
/// data ends, and the bytes between them are coded with the same table, a run of one byte as
/// matches one back. Literals collect high in the output and are coded below, which never
/// overtakes them. A small stream may end as fixed codes instead, without the header.
pub const Stream = struct {
    storage: []u8,
    writer: std.Io.Writer,
    /// Whole bytes written, then `bit_count` more bits held in `bits`.
    end: usize = 2,
    bits: u8 = 0,
    bit_count: u3 = 0,
    decoded: u32 = 0,
    checksum: u32 = 1,
    finished: bool = false,
    /// Counts what it is given and writes nothing.
    counting: bool = false,

    /// Room kept for the end code, its padding and the checksum.
    const tail_room = 8;
    /// Below this many bits of codes, fixed codes without the header can come out smaller.
    const fixed_check_bits = 6 * header.bits;

    pub fn begin(output: []u8) std.Io.Writer.Error!Stream {
        if (output.len < stream_overhead) return error.WriteFailed;
        output[0..2].* = .{ 0x78, 0x01 };
        var result: Stream = .{ .storage = output, .writer = .{ .vtable = &.{ .drain = drain, .rebase = rebase }, .buffer = &.{} } };
        const whole = header.bits / 8;
        @memcpy(output[2..][0..whole], header.bytes[0..whole]);
        result.end = 2 + whole;
        const rest: u3 = @intCast(header.bits % 8);
        if (rest != 0) result.put(header.bytes[whole] & ((@as(u8, 1) << rest) - 1), rest);
        result.refresh();
        return result;
    }

    /// A stream that only counts the bytes it would decode to, for a length that precedes them.
    /// Its writer buffers in scratch.
    pub fn counter(scratch: []u8) Stream {
        assert(scratch.len > 0);
        return .{ .storage = &.{}, .counting = true, .writer = .{ .vtable = &.{ .drain = countDrain, .rebase = countRebase }, .buffer = scratch } };
    }

    pub fn count(self: *const Stream) u32 {
        assert(!self.finished);
        return self.decoded + @as(u32, @intCast(self.writer.end));
    }

    /// Bytes from `end` on that output can reach, short of the tail room.
    fn limit(self: *const Stream) usize {
        return self.storage.len -| tail_room;
    }

    /// Places the literal buffer where coding its contents can never write past what it has
    /// read: no byte costs more than the longest literal code.
    fn refresh(self: *Stream) void {
        const top = self.limit();
        const most = maximum_literal_bits;
        const start = @min(top, (8 * (self.end + 4) + (most - 8) * top + most - 1) / most + 1);
        const length = @min(top - start, std.math.maxInt(u32) - self.decoded);
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

    fn flushLiteral(self: *Stream) void {
        assert(!self.finished and !self.counting);
        const bytes = self.writer.buffered();
        if (bytes.len == 0) return;
        self.checksum = combine(self.checksum, deflate.checksum(bytes), bytes.len);
        self.decoded += @intCast(bytes.len);
        var at: usize = 0;
        while (at < bytes.len) {
            const byte = bytes[at];
            self.symbol(byte);
            at += 1;
            // A run of the byte just written goes as matches one back where those cost less.
            var run: usize = 0;
            while (at + run < bytes.len and bytes[at + run] == byte) run += 1;
            while (run >= 3) {
                const length = @min(run, 258);
                if (shared_costs.length[length] + shared_costs.distance[0] >= length * @as(usize, shared_costs.literal[byte])) break;
                self.match(length);
                at += length;
                run -= length;
            }
            for (0..run) |_| self.symbol(byte);
            at += run;
        }
        self.refresh();
    }

    fn symbol(self: *Stream, value: u16) void {
        const entry = literal_codes[value];
        self.put(entry.code, entry.bits);
    }

    /// A match one byte back.
    fn match(self: *Stream, length: usize) void {
        assert(length >= 3 and length <= 258);
        const code = length_codes[length];
        self.symbol(257 + @as(u16, code));
        self.put(@intCast(length - length_base[code]), length_extra[code]);
        self.put(distance_codes[0].code, distance_codes[0].bits);
    }

    pub fn append(self: *Stream, fragment: Fragment) std.Io.Writer.Error!void {
        assert(!self.finished and fragment.bytes.len > 0 and fragment.decoded > 0);
        if (fragment.decoded > std.math.maxInt(u32) - self.count()) return error.WriteFailed;
        if (self.counting) {
            self.decoded += fragment.decoded;
            return;
        }
        self.flushLiteral();
        try self.join(fragment.bytes);
        self.checksum = combine(self.checksum, fragment.checksum, fragment.decoded);
        self.decoded += fragment.decoded;
        self.refresh();
    }

    pub fn appendMany(self: *Stream, fragments: []const Fragment, digest: Digest) std.Io.Writer.Error!void {
        assert(!self.finished and fragments.len > 0);
        var decoded: u64 = 0;
        for (fragments) |fragment| {
            assert(fragment.bytes.len > 0 and fragment.decoded > 0);
            decoded = std.math.add(u64, decoded, fragment.decoded) catch return error.WriteFailed;
        }
        assert(decoded == digest.decoded);
        if (decoded > std.math.maxInt(u32) - self.count()) return error.WriteFailed;
        if (self.counting) {
            self.decoded += digest.decoded;
            return;
        }
        self.flushLiteral();
        for (fragments) |fragment| try self.join(fragment.bytes);
        self.checksum = combine(self.checksum, digest.checksum, digest.decoded);
        self.decoded += digest.decoded;
        self.refresh();
    }

    /// Copies a fragment's data to the current bit, without its marker.
    fn join(self: *Stream, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len + 2 > self.limit() -| self.end) return error.WriteFailed;
        assert(@intFromPtr(bytes.ptr) + bytes.len <= @intFromPtr(self.storage.ptr + self.end) or
            @intFromPtr(self.storage.ptr + self.end + bytes.len + 2) <= @intFromPtr(bytes.ptr));
        const last = bytes[bytes.len - 1];
        if (last == 0) return error.WriteFailed;
        const data = (bytes.len - 1) * 8 + 7 - @as(usize, @clz(last));
        const whole = data / 8;
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
        return self.seal(true);
    }

    /// Ends the block and the stream. With `compact`, a small stream is rewritten as fixed codes
    /// when those and no header come out shorter.
    fn seal(self: *Stream, compact: bool) std.Io.Writer.Error![]u8 {
        assert(!self.finished and !self.counting);
        self.flushLiteral();
        if (self.end + 7 > self.storage.len) return error.WriteFailed;
        self.symbol(256);
        if (compact) self.compactFixed();
        if (self.bit_count != 0) self.put(0, 8 - @as(u6, self.bit_count));
        std.mem.writeInt(u32, self.storage[self.end..][0..4], self.checksum, .big);
        self.end += 4;
        self.finished = true;
        return self.storage[0..self.end];
    }

    fn compactFixed(self: *Stream) void {
        const start = 16 + header.bits;
        const total = self.end * 8 + self.bit_count;
        if (total - start >= fixed_check_bits) return;
        // The partial byte joins the storage so the codes read back whole.
        self.storage[self.end] = self.bits;
        const fixed = 16 + 3 + transcode(self.storage, start, null);
        const used = (total + 7) / 8;
        const needed = (fixed + 7) / 8;
        if (needed >= used or used + needed + 1 > self.storage.len) return;
        var writer: Writer = .{ .bytes = self.storage[used..] };
        writer.put(0b011, 3);
        assert(transcode(self.storage, start, &writer) == fixed - 19);
        std.mem.copyForwards(u8, self.storage[2..][0..writer.end], writer.bytes[0..writer.end]);
        self.end = 2 + writer.end;
        self.bits = @truncate(writer.accumulator);
        self.bit_count = @intCast(writer.count);
    }

    /// Reads shared codes from `start` through the end code and returns what fixed codes for
    /// the same symbols cost, writing them when given a writer.
    fn transcode(bytes: []const u8, start: usize, writer: ?*Writer) usize {
        var reader: Reader = .{ .bytes = bytes, .position = start };
        var bits: usize = 0;
        while (true) {
            const value = literal_decoding.decode(&reader);
            const fixed = fixed_codes[value];
            bits += fixed.bits;
            if (writer) |output| output.code(fixed);
            if (value == 256) return bits;
            if (value < 256) continue;
            const extra = length_extra[value - 257];
            const length = reader.take(extra);
            const slot = distance_decoding.decode(&reader);
            const distance = reader.take(distance_extra[slot]);
            bits += extra + 5 + distance_extra[slot];
            if (writer) |output| {
                output.put(length, extra);
                output.put(@bitReverse(@as(u5, @intCast(slot))), 5);
                output.put(distance, distance_extra[slot]);
            }
        }
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
        // Coding writes below the literal buffer, so the kept bytes survive the flush in place.
        const tail = writer.buffer[writer.end - kept .. writer.end];
        writer.end -= kept;
        self.flushLiteral();
        if (kept > writer.buffer.len or minimum > writer.buffer.len - kept) return error.WriteFailed;
        const destination = writer.buffer[0..kept];
        if (@intFromPtr(destination.ptr) <= @intFromPtr(tail.ptr)) std.mem.copyForwards(u8, destination, tail) else std.mem.copyBackwards(u8, destination, tail);
        writer.end = kept;
    }

    fn countDrain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Stream = @alignCast(@fieldParentPtr("writer", writer));
        var written: usize = 0;
        for (data, 0..) |slice, index| written += slice.len * (if (index + 1 == data.len) splat else 1);
        if (written + writer.end > std.math.maxInt(u32) - self.decoded) return error.WriteFailed;
        self.decoded += @intCast(written + writer.end);
        writer.end = 0;
        return written;
    }

    fn countRebase(writer: *std.Io.Writer, preserve: usize, minimum: usize) std.Io.Writer.Error!void {
        const self: *Stream = @alignCast(@fieldParentPtr("writer", writer));
        const kept = @min(preserve, writer.end);
        if (kept > writer.buffer.len or minimum > writer.buffer.len - kept) return error.WriteFailed;
        self.decoded += @intCast(writer.end - kept);
        std.mem.copyForwards(u8, writer.buffer[0..kept], writer.buffer[writer.end - kept .. writer.end]);
        writer.end = kept;
    }
};

/// DEFLATE's fixed literal and length codes, bit reversed for least significant bit first output.
const fixed_codes = codes: {
    var table: [288]Code = undefined;
    for (&table, 0..) |*entry, value| {
        const code: u16, const bits: u6 = if (value < 144) .{ 0x30 + value, 8 } else if (value < 256) .{ 0x190 + value - 144, 9 } else if (value < 280) .{ value - 256, 7 } else .{ 0xc0 + value - 280, 8 };
        entry.* = .{ .code = @bitReverse(code) >> @intCast(16 - bits), .bits = bits };
    }
    break :codes table;
};
