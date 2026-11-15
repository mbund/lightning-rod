const std = @import("std");
const storage = @import("storage");
const records = @import("records");

pub const Random = struct {
    source: std.Random.Xoshiro256,
    saved: [32]u8 = @splat(0),

    pub fn init(seed: u64, space: storage.Space) !Random {
        var self: Random = .{ .source = .init(seed) };
        if (try records.Value.init(space).read(&self.saved)) |length| {
            try self.restore(self.saved[0..length]);
        }
        return self;
    }

    pub fn restore(self: *Random, bytes: []const u8) !void {
        if (bytes.len != self.saved.len) return error.CorruptRandomState;
        for (&self.source.s, 0..) |*word, index|
            word.* = std.mem.readInt(u64, bytes[index * 8 ..][0..8], .little);
        if (self.source.s[0] | self.source.s[1] | self.source.s[2] | self.source.s[3] == 0)
            return error.CorruptRandomState;
    }

    pub fn encode(self: *const Random) [32]u8 {
        var bytes: [32]u8 = undefined;
        for (self.source.s, 0..) |word, index|
            std.mem.writeInt(u64, bytes[index * 8 ..][0..8], word, .little);
        return bytes;
    }

    pub fn random(self: *Random) std.Random {
        return self.source.random();
    }

    pub fn checkpoint(self: *Random, space: storage.Space) !void {
        const bytes = self.encode();
        if (std.mem.eql(u8, &bytes, &self.saved)) return;
        try records.Value.init(space).write(&bytes);
        self.saved = bytes;
    }
};

test "random streams resume after durable reopen without changing clean checkpoints" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/random", .{directory.sub_path});
    const options: storage.Store.Options = .{ .path = path, .maximum_wal_pages = 128 };
    var expected: [16]u64 = undefined;
    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, options);
        defer store.deinit();
        const space = try store.openSpace("random");
        var state = try Random.init(42, space);
        for (0..25) |_| _ = state.random().int(u64);
        try state.checkpoint(space);
        try store.waitDurable(try store.commit(1));
        try state.checkpoint(space);
        try std.testing.expect(!store.hasWrites());
        for (&expected) |*value| value.* = state.random().int(u64);
    }
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, options);
    defer store.deinit();
    const space = try store.openSpace("random");
    var resumed = try Random.init(0, space);
    for (expected) |value| try std.testing.expectEqual(value, resumed.random().int(u64));
    try records.Value.init(space).write(&@as([32]u8, @splat(0)));
    try std.testing.expectError(error.CorruptRandomState, Random.init(42, space));
    try records.Value.init(space).write(&.{1});
    try std.testing.expectError(error.CorruptRandomState, Random.init(42, space));
}
