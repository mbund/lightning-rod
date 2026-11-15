const std = @import("std");
const encoding = @import("encoding.zig");
const storage = @import("storage");
const records = @import("records");
const zstandard = @import("zstandard");
const assert = std.debug.assert;

pub const bytes = 2 + 64 * @sizeOf(u64);
pub const key_bytes = 25;
pub const maximum_prefix = 16;
pub const column_batch_max = records.Table.read_batch_size / 2;
pub const Column = struct { world: u32, x: i32, z: i32, minimum: i32, count: u8 };
pub const ColumnSummary = struct {
    known: u32 = 0,
    missing: u32 = 0,
    prefixed: u32 = 0,
    common: [32]u8 = @splat(0),
    prefixes: [32][maximum_prefix]u8 = @splat(@splat(0)),
    prefix_bytes: u8 = 0,
};
pub const Projection = enum { full, flags, prefix };
pub const Header = struct {
    pub const sections = 32;
    pub const maximum_size = 12 + sections * (1 + maximum_prefix);
    known: u32 = 0,
    missing: u32 = 0,
    stored: u32 = 0,
    common: [sections]u8 = @splat(0),
    prefixes: [sections][maximum_prefix]u8 = @splat(@splat(0)),

    pub fn size(prefix: usize) usize {
        assert(prefix <= maximum_prefix);
        return 12 + sections * (1 + prefix);
    }

    pub fn key(section: []const u8) error{InvalidArgument}![key_bytes]u8 {
        if (section.len != 16) return error.InvalidArgument;
        var result: [key_bytes]u8 = undefined;
        result[0] = 2;
        @memcpy(result[1..13], section[0..12]);
        const y = std.mem.readInt(i32, section[12..16], .big);
        std.mem.writeInt(i32, result[13..17], @divFloor(y, sections), .big);
        @memset(result[17..], 0);
        return result;
    }

    pub fn part(section: []const u8) u5 {
        assert(section.len == 16);
        return @intCast(@mod(std.mem.readInt(i32, section[12..16], .big), sections));
    }

    pub fn encode(self: *const Header, output: []u8, prefix: usize) []const u8 {
        assert(output.len >= size(prefix) and self.stored & ~self.known == 0);
        std.mem.writeInt(u32, output[0..4], self.known, .little);
        std.mem.writeInt(u32, output[4..8], self.stored, .little);
        std.mem.writeInt(u32, output[8..12], self.missing, .little);
        var cursor: usize = 12;
        var selected = self.known;
        while (selected != 0) : (selected &= selected - 1) {
            output[cursor] = self.common[@ctz(selected)];
            cursor += 1;
        }
        selected = self.stored;
        while (selected != 0) : (selected &= selected - 1) {
            @memcpy(output[cursor..][0..prefix], self.prefixes[@ctz(selected)][0..prefix]);
            cursor += prefix;
        }
        assert(cursor <= output.len);
        return output[0..cursor];
    }

    pub fn decode(input: []const u8, prefix: usize) !Header {
        const view = try read(input, prefix);
        var result: Header = .{ .known = view.known, .missing = view.missing, .stored = view.stored };
        var selected = view.known;
        while (selected != 0) : (selected &= selected - 1) {
            const part_: u5 = @intCast(@ctz(selected));
            result.common[part_] = view.commonAt(part_);
        }
        selected = view.stored;
        while (selected != 0) : (selected &= selected - 1) {
            const part_: u5 = @intCast(@ctz(selected));
            @memcpy(result.prefixes[part_][0..prefix], view.prefixAt(part_, prefix));
        }
        return result;
    }

    pub const View = struct {
        known: u32 = 0,
        missing: u32 = 0,
        stored: u32 = 0,
        common: []const u8 = &.{},
        prefixes: []const u8 = &.{},

        pub fn commonAt(self: View, index: u5) u8 {
            const bit = @as(u32, 1) << index;
            assert(self.known & bit != 0);
            return self.common[@popCount(self.known & (bit - 1))];
        }

        pub fn prefixAt(self: View, index: u5, prefix: usize) []const u8 {
            const bit = @as(u32, 1) << index;
            assert(self.stored & bit != 0);
            const offset = @as(usize, @popCount(self.stored & (bit - 1))) * prefix;
            return self.prefixes[offset..][0..prefix];
        }
    };

    pub fn read(input: []const u8, prefix: usize) !View {
        assert(prefix <= maximum_prefix);
        if (input.len < 12) return error.Corrupt;
        const known = std.mem.readInt(u32, input[0..4], .little);
        const stored = std.mem.readInt(u32, input[4..8], .little);
        if (stored & ~known != 0) return error.Corrupt;
        const missing = std.mem.readInt(u32, input[8..12], .little);
        if (missing & known != 0) return error.Corrupt;
        const common_end = 12 + @as(usize, @popCount(known));
        const end = common_end + @as(usize, @popCount(stored)) * prefix;
        if (input.len != end) return error.Corrupt;
        return .{ .known = known, .missing = missing, .stored = stored, .common = input[12..common_end], .prefixes = input[common_end..] };
    }

    pub const Batch = struct {
        keys: [records.Table.read_batch_size][key_bytes]u8 = undefined,
        mapping: [records.Table.read_batch_size]u8 = undefined,
        parts: [records.Table.read_batch_size]u5 = undefined,
        buckets: [512]u16 = @splat(std.math.maxInt(u16)),
        count: usize = 0,
        unique: usize = 0,

        pub fn append(self: *Batch, section: []const u8) !void {
            assert(self.count < self.mapping.len);
            const value = try Header.key(section);
            var bucket: usize = @intCast(std.hash.Wyhash.hash(0, &value) & (self.buckets.len - 1));
            while (self.buckets[bucket] != std.math.maxInt(u16) and !std.mem.eql(u8, &self.keys[self.buckets[bucket]], &value)) bucket = (bucket + 1) & (self.buckets.len - 1);
            if (self.buckets[bucket] == std.math.maxInt(u16)) {
                self.buckets[bucket] = @intCast(self.unique);
                self.keys[self.unique] = value;
                self.unique += 1;
            }
            self.mapping[self.count] = @intCast(self.buckets[bucket]);
            self.parts[self.count] = Header.part(section);
            self.count += 1;
        }
    };
};
pub const Encoded = struct { raw: []const u8, bytes: []const u8, common: u8, stored: bool, prefix: []const u8 };
pub const Prepared = struct { bytes: []u8, length: usize = 0 };
pub const ColumnCodec = struct {
    identity: []const u8,
    maximum: usize,
    encode: *const fn (*const ColumnSummary, []u8) storage.Error!usize,
};
pub const Codec = struct {
    identity: []const u8,
    maximum: usize,
    prefix_bytes: u8 = 0,
    /// Pure projection from an immutable section classification.
    encode: *const fn (*const encoding.Classification.Known, []u8) storage.Error!usize,
    column: ?ColumnCodec = null,
};

pub const Index = struct {
    identity: [32]u8,
    properties: []const u8,
    selected: u8,
    codec: ?Codec,
    table: records.Table,
    encoder: zstandard.Compressor.Encoder,
    scratch: []u8,
    next: ?*Index = null,

    pub fn fingerprint(properties: []const u8, selected: u8, codec: ?Codec) [32]u8 {
        assert(properties.len > 0 and std.math.isPowerOfTwo(selected));
        var hash = std.crypto.hash.Blake3.init(.{});
        hash.update("lightning_rod:section_classification:8");
        hash.update(&.{ selected, if (codec) |extra| extra.prefix_bytes else 0 });
        var lengths: [24]u8 = undefined;
        std.mem.writeInt(u64, lengths[0..8], properties.len, .little);
        std.mem.writeInt(u64, lengths[8..16], if (codec) |extra| extra.identity.len else 0, .little);
        std.mem.writeInt(u64, lengths[16..24], if (codec) |extra| extra.maximum else 0, .little);
        hash.update(&lengths);
        hash.update(properties);
        if (codec) |extra| hash.update(extra.identity);
        if (codec) |extra| if (extra.column) |column| {
            var size: [8]u8 = undefined;
            std.mem.writeInt(u64, &size, column.maximum, .little);
            hash.update(&size);
            hash.update(column.identity);
        };
        var identity: [32]u8 = undefined;
        hash.final(&identity);
        return identity;
    }

    pub fn key(self: *const Index, section: []const u8) [key_bytes]u8 {
        assert(section.len == 16);
        _ = self;
        var result: [key_bytes]u8 = undefined;
        result[0] = 1;
        @memcpy(result[1..17], section);
        @memset(result[17..], 0);
        return result;
    }

    pub fn encode(self: *const Index, key_: []const u8, value: []const u8, output: []u8) !Encoded {
        assert(output.len > zstandard.bound(self.scratch.len));
        const raw = self.scratch[8..];
        const classified = try encoding.classify(value, self.properties, self.selected);
        const words: @Vector(64, u64) = classified.selected;
        const zero = @reduce(.Or, words) == 0;
        const full = @reduce(.And, words) == std.math.maxInt(u64);
        raw[0] = classified.common;
        raw[1] = if (zero) 0 else if (full) 1 else 2;
        const prefix = if (zero or full) @as(usize, 2) else bytes;
        if (prefix == bytes) for (classified.selected, 0..) |word, index| std.mem.writeInt(u64, raw[2 + index * 8 ..][0..8], word, .little);
        const suffix = if (self.codec) |extra| try extra.encode(&classified, raw[prefix..][0..extra.maximum]) else 0;
        const length = prefix + suffix;
        std.mem.writeInt(u64, self.scratch[0..8], self.checksum(key_, raw[0..length]), .little);
        const record = self.scratch[0 .. 8 + length];
        const fixed = if (self.codec) |extra| extra.prefix_bytes else @as(usize, 0);
        if ((suffix != 0 or prefix == bytes) and suffix < fixed) return error.Corrupt;
        const summary = if (suffix == 0) &.{} else raw[prefix..][0..fixed];
        assert(length <= raw.len);
        if (length >= 64) {
            const frame = try self.encoder.encode(record, output[1..]);
            if (frame.len < record.len) {
                output[0] = 1;
                return .{ .raw = record, .bytes = output[0 .. frame.len + 1], .common = classified.common, .stored = true, .prefix = summary };
            }
        }
        output[0] = 0;
        @memcpy(output[1..][0..record.len], record);
        return .{ .raw = record, .bytes = output[0 .. record.len + 1], .common = classified.common, .stored = length > 2, .prefix = summary };
    }

    // An interrupted cache update can leave an index pointing at a reused overflow page.
    fn checksum(self: *const Index, key_: []const u8, value: []const u8) u64 {
        var hash = std.hash.Wyhash.init(std.mem.readInt(u64, self.identity[0..8], .little));
        hash.update(key_);
        hash.update(value);
        return hash.final();
    }

    pub fn decode(self: *const Index, key_: []const u8, record: []const u8, prepared: ?*Prepared) !encoding.Classification {
        if (record.len < 10) return error.Corrupt;
        const input = record[8..];
        if (std.mem.readInt(u64, record[0..8], .little) != self.checksum(key_, input)) return error.Corrupt;
        const tag = input[1];
        const prefix = if (tag == 2) bytes else @as(usize, 2);
        if (tag > 2 or input.len < prefix) return error.Corrupt;
        const maximum = if (self.codec) |extra| extra.maximum else @as(usize, 0);
        if (input.len - prefix > maximum) return error.Corrupt;
        var result: encoding.Classification.Known = .{ .common = input[0], .property = self.selected, .selected = undefined };
        if (tag != 2) {
            @memset(&result.selected, if (tag == 0) 0 else std.math.maxInt(u64));
        } else for (&result.selected, 0..) |*word, index| word.* = std.mem.readInt(u64, input[2 + index * 8 ..][0..8], .little);
        if ((result.common & self.selected != 0) != (tag == 1)) return error.Corrupt;
        if (prepared) |output| {
            if (input.len - prefix > output.bytes.len) return error.BufferTooSmall;
            output.length = input.len - prefix;
            @memcpy(output.bytes[0..output.length], input[prefix..]);
        }
        return .{ .known = result };
    }
};

test "column headers preserve sparse sections and batch independently of terrain grouping" {
    var random = std.Random.DefaultPrng.init(0x81572);
    var output: [Header.maximum_size]u8 = undefined;
    for (0..256) |pass| {
        var value: Header = .{ .known = random.random().int(u32), .stored = 0 };
        value.stored = random.random().int(u32) & value.known;
        value.missing = random.random().int(u32) & ~value.known;
        const prefix = pass % (maximum_prefix + 1);
        var selected = value.known;
        while (selected != 0) : (selected &= selected - 1) value.common[@ctz(selected)] = random.random().int(u8);
        selected = value.stored;
        while (selected != 0) : (selected &= selected - 1) random.random().bytes(value.prefixes[@ctz(selected)][0..prefix]);
        const encoded = value.encode(&output, prefix);
        try std.testing.expectEqual(12 + @as(usize, @popCount(value.known)) + @as(usize, @popCount(value.stored)) * prefix, encoded.len);
        try std.testing.expectEqualDeep(value, try Header.decode(encoded, prefix));
        try std.testing.expectError(error.Corrupt, Header.read(encoded[0 .. encoded.len - 1], prefix));
    }
    var batch: Header.Batch = .{};
    for (0..32) |offset| {
        var key_: [16]u8 = @splat(0);
        std.mem.writeInt(i32, key_[4..8], -19, .big);
        std.mem.writeInt(i32, key_[8..12], 37, .big);
        std.mem.writeInt(i32, key_[12..16], @as(i32, @intCast(offset)) - 4, .big);
        try batch.append(&key_);
        try std.testing.expectEqual(@as(u5, @intCast((offset + 28) % 32)), batch.parts[offset]);
        try std.testing.expectEqual(@as(u8, @intFromBool(offset >= 4)), batch.mapping[offset]);
    }
    try std.testing.expectEqual(@as(usize, 2), batch.unique);
    try std.testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, batch.keys[0][13..17], .big));
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, batch.keys[1][13..17], .big));
    try std.testing.expectError(error.InvalidArgument, Header.key(&.{0}));
}

test "prepared records bind their complete payload to their source key" {
    const allocator = std.testing.allocator;
    const properties = [_]u8{ 0, 1 };
    var compressor = try zstandard.Compressor.init(allocator, 6, bytes + 8);
    defer compressor.deinit();
    var scratch: [bytes + 8]u8 = undefined;
    const output = try allocator.alloc(u8, 1 + zstandard.bound(scratch.len));
    defer allocator.free(output);
    const index: Index = .{ .identity = Index.fingerprint(&properties, 1, null), .properties = &properties, .selected = 1, .codec = null, .table = undefined, .encoder = try compressor.borrow(6, scratch.len), .scratch = &scratch };
    const first: [key_bytes]u8 = @splat(0);
    var second = first;
    second[16] = 1;
    const encoded = try index.encode(&first, &.{ 0, 1, 0 }, output);
    const expected = try encoding.classify(&.{ 0, 1, 0 }, &properties, 1);
    try std.testing.expectEqualDeep(expected, (try index.decode(&first, encoded.raw, null)).known);
    try std.testing.expectError(error.Corrupt, index.decode(&second, encoded.raw, null));
    scratch[9] ^= 1;
    try std.testing.expectError(error.Corrupt, index.decode(&first, encoded.raw, null));
}
