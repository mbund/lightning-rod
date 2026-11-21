//! Where projectiles live: one records cache over the projectiles' storage, as chunks and
//! entities use, with every kind of entry under a prefix byte. Keys order as the tick does: by
//! entity id, which is tick-list order, big-endian; by time; by block.
//!
//! - record: id → the projectile.
//! - ticking: id → nothing. Those that fly, in tick-list order.
//! - due: tick, id → nothing. Stuck arrows by when they go.
//! - stuck: world, cell x, cell z, place in cell, y, id → nothing. Stuck projectiles by the block
//!   they are in, blocks by the four by four column of blocks they are in.
//! - parked: group, id → nothing. Stuck arrows by the tick of a second they look over viewers.
//! - removal: id → network id and viewers still to tell.
//! - woken: id → nothing. Stuck projectiles whose block was edited.
//! - sleeping: id → nothing. Flying projectiles left alone until they wake, which memory keeps.

const std = @import("std");
const records = @import("records");

const assert = std.debug.assert;

pub const Prefix = enum(u8) { record = 1, ticking = 2, due = 3, stuck = 4, parked = 5, removal = 6, woken = 7, sleeping = 8 };

/// The longest key: a stuck entry.
pub const key_bytes = 1 + 4 + 4 + 4 + 1 + 4 + 8;
/// Blocks a side of a stuck cell, as a shift.
pub const cell_shift = 2;

pub const Key = struct {
    bytes: [key_bytes]u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Key) []const u8 {
        return self.bytes[0..self.len];
    }

    fn put(self: *Key, comptime T: type, value: T) void {
        std.mem.writeInt(T, self.bytes[self.len..][0..@sizeOf(T)], value, .big);
        self.len += @sizeOf(T);
    }

    /// Signed values order as unsigned with their sign bit flipped.
    fn putSigned(self: *Key, value: i32) void {
        self.put(u32, @as(u32, @bitCast(value)) ^ 0x8000_0000);
    }

    /// The entity id that ends every key but a prefix.
    pub fn id(bytes: []const u8) u64 {
        assert(bytes.len >= 9);
        return std.mem.readInt(u64, bytes[bytes.len - 8 ..][0..8], .big);
    }
};

fn start(prefix: Prefix) Key {
    var key: Key = .{};
    key.bytes[0] = @intFromEnum(prefix);
    key.len = 1;
    return key;
}

pub fn byId(prefix: Prefix, id: u64) Key {
    assert(prefix == .record or prefix == .ticking or prefix == .removal or prefix == .woken or prefix == .sleeping);
    var key = start(prefix);
    key.put(u64, id);
    return key;
}

pub fn due(at: u64, id: u64) Key {
    return timed(.due, at, id);
}

fn timed(prefix: Prefix, at: u64, id: u64) Key {
    var key = start(prefix);
    key.put(u64, at);
    key.put(u64, id);
    return key;
}

/// The tick a due or sleeping key comes due at.
pub fn dueAt(bytes: []const u8) u64 {
    assert(bytes.len == 17 and (bytes[0] == @intFromEnum(Prefix.due) or bytes[0] == @intFromEnum(Prefix.sleeping)));
    return std.mem.readInt(u64, bytes[1..9], .big);
}

/// A stuck key, or with no id, the prefix of a block.
pub fn stuck(world: u32, x: i32, z: i32, y: i32, id: ?u64) Key {
    var key = cell(world, x >> cell_shift, z >> cell_shift);
    key.put(u8, @intCast((x & 3) << 2 | (z & 3)));
    key.putSigned(y);
    if (id) |entity| key.put(u64, entity);
    return key;
}

/// The prefix of the stuck keys of a cell.
pub fn cell(world: u32, x: i32, z: i32) Key {
    var key = start(.stuck);
    key.put(u32, world);
    key.putSigned(x);
    key.putSigned(z);
    return key;
}

/// The block of a stuck key.
pub fn stuckBlock(bytes: []const u8) [3]i32 {
    assert(bytes.len == key_bytes and bytes[0] == @intFromEnum(Prefix.stuck));
    const cell_x: i32 = @bitCast(std.mem.readInt(u32, bytes[5..9], .big) ^ 0x8000_0000);
    const cell_z: i32 = @bitCast(std.mem.readInt(u32, bytes[9..13], .big) ^ 0x8000_0000);
    const place = bytes[13];
    return .{ cell_x << cell_shift | (place >> 2), @bitCast(std.mem.readInt(u32, bytes[14..18], .big) ^ 0x8000_0000), cell_z << cell_shift | (place & 3) };
}

pub fn parked(group: u8, id: ?u64) Key {
    var key = start(.parked);
    key.put(u8, group);
    if (id) |entity| key.put(u64, entity);
    return key;
}

pub fn under(kind: Prefix) Key {
    return start(kind);
}

/// An ordered pass over the keys under a prefix, a batch at a time. Keys are copied out, so the
/// cache may change between batches; a key added behind the pass is not seen.
pub const Pass = struct {
    pub const batch = 64;
    cache: *records.Cache,
    within: Key,
    after: [key_bytes]u8 = undefined,
    after_len: usize = 0,
    done: bool = false,
    keys: [batch]Key = undefined,

    pub fn init(cache: *records.Cache, within: Key) Pass {
        var pass: Pass = .{ .cache = cache, .within = within };
        @memcpy(pass.after[0..within.len], within.slice());
        pass.after_len = within.len;
        return pass;
    }

    /// The next keys under the prefix, none once past it.
    pub fn next(self: *Pass) ![]const Key {
        if (self.done) return &.{};
        var entries: [batch]records.BorrowedEntry = undefined;
        var cursor: records.ScanCursor = .{ .after = &self.after, .after_len = self.after_len };
        const result = try self.cache.scanBorrowed(&cursor, &entries);
        self.after_len = cursor.after_len;
        var count: usize = 0;
        for (entries[0..result.count]) |entry| {
            if (!std.mem.startsWith(u8, entry.key, self.within.slice())) {
                self.done = true;
                break;
            }
            assert(entry.key.len <= key_bytes);
            self.keys[count] = .{ .len = @intCast(entry.key.len) };
            @memcpy(self.keys[count].bytes[0..entry.key.len], entry.key);
            count += 1;
        }
        if (!result.more) self.done = true;
        return self.keys[0..count];
    }
};

test "keys order by id, by time and by block, signed coordinates included" {
    try std.testing.expect(std.mem.order(u8, byId(.record, 1).slice(), byId(.record, 256).slice()) == .lt);
    try std.testing.expect(std.mem.order(u8, due(5, 900).slice(), due(6, 1).slice()) == .lt);
    try std.testing.expect(std.mem.order(u8, stuck(0, -5, 0, 64, 1).slice(), stuck(0, 0, 0, 64, 1).slice()) == .lt);
    try std.testing.expect(std.mem.startsWith(u8, stuck(0, -3, 7, -60, 9).slice(), cell(0, -1, 1).slice()));
    try std.testing.expect(std.mem.startsWith(u8, stuck(0, -3, 7, -60, 9).slice(), stuck(0, -3, 7, -60, null).slice()));
    try std.testing.expectEqual([3]i32{ -3, -60, 7 }, stuckBlock(stuck(0, -3, 7, -60, 9).slice()));
    try std.testing.expectEqual(@as(u64, 9), Key.id(stuck(0, -3, 7, -60, 9).slice()));
    try std.testing.expectEqual(@as(u64, 77), dueAt(due(77, 3).slice()));
}
