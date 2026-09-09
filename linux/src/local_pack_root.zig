const std = @import("std");

pub const magic: u32 = 0x4c525250;
pub const version: u16 = 1;
pub const header_bytes = 32;
pub const entry_bytes = 32;

pub const Entry = extern struct {
    id: u64,
    bytes: u64,
    generation: u64,
    checksum: u64,
};

pub fn Root(comptime maximum_packs: usize) type {
    if (maximum_packs == 0 or maximum_packs >= std.math.maxInt(u16))
        @compileError("local pack root needs a bounded u16 pack count");
    return struct {
        const Self = @This();

        generation: u64 = 0,
        next_id: u64 = 1,
        count: u16 = 0,
        entries: [maximum_packs]Entry = @splat(.{ .id = 0, .bytes = 0, .generation = 0, .checksum = 0 }),

        pub const maximum_bytes = header_bytes + maximum_packs * entry_bytes;

        pub fn init() Self {
            return .{};
        }

        pub fn slice(self: *const Self) []const Entry {
            return self.entries[0..self.count];
        }

        pub fn append(self: *Self, entry: Entry) !void {
            if (self.count == maximum_packs) return error.PackCapacity;
            if (entry.id == 0 or entry.id >= std.math.maxInt(u32) or entry.bytes == 0) return error.InvalidPack;
            if (self.count != 0 and entry.id <= self.entries[self.count - 1].id)
                return error.InvalidPackOrder;
            if (entry.generation != self.generation + 1) return error.InvalidGeneration;
            self.entries[self.count] = entry;
            self.count += 1;
            self.generation = entry.generation;
            self.next_id = @max(self.next_id, entry.id + 1);
        }

        pub fn newEpoch(self: *const Self) Self {
            var next = Self.init();
            next.next_id = self.next_id;
            return next;
        }

        pub fn encode(self: *const Self, destination: []u8) ![]const u8 {
            const bytes = header_bytes + @as(usize, self.count) * entry_bytes;
            if (destination.len < bytes) return error.DestinationTooSmall;
            var cursor: usize = 0;
            write(destination, &cursor, u32, magic);
            write(destination, &cursor, u16, version);
            write(destination, &cursor, u16, self.count);
            write(destination, &cursor, u64, self.generation);
            write(destination, &cursor, u64, 0);
            write(destination, &cursor, u64, self.next_id);
            for (self.slice()) |entry| {
                write(destination, &cursor, u64, entry.id);
                write(destination, &cursor, u64, entry.bytes);
                write(destination, &cursor, u64, entry.generation);
                write(destination, &cursor, u64, entry.checksum);
            }
            const digest = checksum(destination[0..bytes]);
            std.mem.writeInt(u64, destination[16..24], digest, .little);
            return destination[0..bytes];
        }

        pub fn decode(source: []const u8) !Self {
            if (source.len < header_bytes) return error.Truncated;
            if (std.mem.readInt(u32, source[0..4], .little) != magic) return error.InvalidMagic;
            if (std.mem.readInt(u16, source[4..6], .little) != version) return error.InvalidVersion;
            const count: usize = std.mem.readInt(u16, source[6..8], .little);
            if (count > maximum_packs) return error.PackCapacity;
            const bytes = header_bytes + count * entry_bytes;
            if (source.len < bytes) return error.Truncated;
            if (source.len > bytes) return error.InvalidLength;
            const expected = std.mem.readInt(u64, source[16..24], .little);
            var copied: [maximum_bytes]u8 = undefined;
            @memcpy(copied[0..bytes], source);
            @memset(copied[16..24], 0);
            if (checksum(copied[0..bytes]) != expected) return error.InvalidChecksum;
            var root = Self.init();
            root.next_id = std.mem.readInt(u64, source[24..32], .little);
            if (root.next_id == 0) return error.InvalidPack;
            var cursor: usize = header_bytes;
            for (0..count) |_| {
                const entry: Entry = .{
                    .id = read(source, &cursor, u64),
                    .bytes = read(source, &cursor, u64),
                    .generation = read(source, &cursor, u64),
                    .checksum = read(source, &cursor, u64),
                };
                try root.append(entry);
            }
            if (root.generation != std.mem.readInt(u64, source[8..16], .little)) return error.InvalidGeneration;
            if (root.next_id <= root.generation) return error.InvalidPack;
            return root;
        }

        pub fn reservationBytes() usize {
            return @sizeOf(Self) + maximum_bytes;
        }
    };
}

fn write(bytes: []u8, cursor: *usize, comptime T: type, value: T) void {
    const length = @sizeOf(T);
    std.mem.writeInt(T, bytes[cursor.*..][0..length], value, .little);
    cursor.* += length;
}

fn read(bytes: []const u8, cursor: *usize, comptime T: type) T {
    const length = @sizeOf(T);
    const value = std.mem.readInt(T, bytes[cursor.*..][0..length], .little);
    cursor.* += length;
    return value;
}

fn checksum(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0x6c6f63616c2d726f, bytes);
}

test "root decode rejects a torn or mixed publication" {
    const TestRoot = Root(4);
    var root = TestRoot.init();
    try root.append(.{ .id = 1, .bytes = 128, .generation = 1, .checksum = 9 });
    var bytes: [TestRoot.maximum_bytes]u8 = undefined;
    const encoded = try root.encode(&bytes);
    try std.testing.expectEqual(@as(u64, 1), (try TestRoot.decode(encoded)).generation);
    try std.testing.expectError(error.Truncated, TestRoot.decode(encoded[0 .. encoded.len - 1]));
    bytes[encoded.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidChecksum, TestRoot.decode(encoded));
}

test "new epochs preserve non-contiguous immutable pack identities" {
    const TestRoot = Root(4);
    var root = TestRoot.init();
    try root.append(.{ .id = 7, .bytes = 80, .generation = 1, .checksum = 1 });
    try root.append(.{ .id = 19, .bytes = 96, .generation = 2, .checksum = 2 });
    var next = root.newEpoch();
    try std.testing.expectEqual(@as(u64, 20), next.next_id);
    try next.append(.{ .id = 20, .bytes = 64, .generation = 1, .checksum = 3 });
    var bytes: [TestRoot.maximum_bytes]u8 = undefined;
    const decoded = try TestRoot.decode(try next.encode(&bytes));
    try std.testing.expectEqual(@as(u64, 20), decoded.entries[0].id);
    try std.testing.expectEqual(@as(u64, 21), decoded.next_id);
}
