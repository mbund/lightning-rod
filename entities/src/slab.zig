//! Records of one size, chosen at startup, by entity id, in the entities' pool: each stays where
//! it was made until it goes, so several may be in hand at once. Ids find their records through
//! an id index, without hashing; memory is the only bound.

const std = @import("std");
const pool_module = @import("pool.zig");
const IdIndexOf = @import("id_index.zig").IdIndexOf;

const assert = std.debug.assert;
const Array = pool_module.Array;

pub const Id = u64;

pub const Slab = struct {
    pool: *pool_module.Pool,
    record_bytes: usize,
    per_page: usize,
    /// The pool pages records lie in, the id of each record's owner, 0 for one let go, and those
    /// let go to take first.
    pages: Array(u32),
    owners: Array(Id),
    free: Array(u32),
    free_count: usize = 0,
    slots: IdIndexOf(1024),
    /// Records at most, as whoever keeps them sized what they read them into.
    capacity: usize,

    pub fn init(allocator: std.mem.Allocator, pool: *pool_module.Pool, record_bytes: usize, capacity: usize) !Slab {
        assert(record_bytes > 0 and capacity > 0);
        const stride = std.mem.alignForward(usize, record_bytes, 16);
        assert(stride <= pool_module.page_bytes);
        return .{
            .pool = pool,
            .record_bytes = stride,
            .per_page = pool_module.page_bytes / stride,
            .pages = try .init(allocator, pool),
            .owners = try .init(allocator, pool),
            .free = try .init(allocator, pool),
            .slots = try .init(allocator, pool),
            .capacity = capacity,
        };
    }

    pub fn count(self: *const Slab) usize {
        return self.slots.count;
    }

    fn bytesAt(self: *const Slab, slot: u32) []align(16) u8 {
        const page = self.pool.bytes(self.pages.at(slot / self.per_page).*);
        return @alignCast(page[(slot % self.per_page) * self.record_bytes ..][0..self.record_bytes]);
    }

    pub fn get(self: *const Slab, entity: Id) ?[]align(16) u8 {
        const slot = @constCast(&self.slots).get(entity) orelse return null;
        return self.bytesAt(slot);
    }

    /// The entity's record, made zeroed if it had none.
    pub fn getOrCreate(self: *Slab, entity: Id) ![]align(16) u8 {
        if (self.slots.get(entity)) |slot| return self.bytesAt(slot);
        if (self.slots.count == self.capacity) return error.SlabFull;
        const slot: u32 = slot: {
            if (self.free_count > 0) {
                self.free_count -= 1;
                break :slot self.free.at(self.free_count).*;
            }
            const made = self.owners.len;
            if (made == self.pages.len * self.per_page) {
                const page = self.pool.take() catch return error.EntityMemoryExhausted;
                errdefer self.pool.give(page);
                _ = try self.pages.append(page);
            }
            try self.owners.ensure(made + 1);
            try self.free.ensure(made + 1);
            break :slot @intCast(made);
        };
        try self.slots.put(entity, slot);
        self.owners.at(slot).* = entity;
        const bytes = self.bytesAt(slot);
        @memset(bytes, 0);
        return bytes;
    }

    pub fn clear(self: *Slab) void {
        for (0..self.owners.len) |at| {
            const owner = self.owners.at(at);
            if (owner.* == 0) continue;
            owner.* = 0;
            self.free.at(self.free_count).* = @intCast(at);
            self.free_count += 1;
        }
        self.slots.clear();
    }

    pub fn remove(self: *Slab, entity: Id) void {
        const slot = self.slots.get(entity) orelse return;
        _ = self.slots.remove(entity);
        self.owners.at(slot).* = 0;
        self.free.at(self.free_count).* = slot;
        self.free_count += 1;
    }

    pub const Entry = struct { id: Id, bytes: []align(16) u8 };

    pub const Iterator = struct {
        slab: *const Slab,
        at: usize = 0,

        pub fn next(self: *Iterator) ?Entry {
            while (self.at < self.slab.owners.len) {
                const slot: u32 = @intCast(self.at);
                self.at += 1;
                const owner = self.slab.owners.at(slot).*;
                if (owner != 0) return .{ .id = owner, .bytes = self.slab.bytesAt(slot) };
            }
            return null;
        }
    };

    /// Every record, in no order, for passes that change none of which there are.
    pub fn iterator(self: *const Slab) Iterator {
        return .{ .slab = self };
    }

    /// The ids with records, into `output`, sorted, for passes that may change which have them.
    pub fn ids(self: *const Slab, output: []Id) []Id {
        assert(output.len >= self.count());
        var walk = self.iterator();
        var at: usize = 0;
        while (walk.next()) |entry| : (at += 1) output[at] = entry.id;
        std.sort.pdq(Id, output[0..at], {}, std.sort.asc(Id));
        return output[0..at];
    }
};

test "records keep their place while others come and go" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pool = try pool_module.Pool.init(arena.allocator(), 16 * pool_module.page_bytes);
    var slab = try Slab.init(arena.allocator(), &pool, 24, 600);
    const first = try slab.getOrCreate(1);
    first[0] = 7;
    for (2..601) |entity| _ = try slab.getOrCreate(entity);
    try std.testing.expectError(error.SlabFull, slab.getOrCreate(700));
    try std.testing.expectEqual(@as(u8, 7), slab.get(1).?[0]);
    try std.testing.expect(slab.get(1).?.ptr == first.ptr);
    slab.remove(300);
    try std.testing.expect(slab.get(300) == null);
    const again = try slab.getOrCreate(300);
    try std.testing.expectEqual(@as(u8, 0), again[5]);
    try std.testing.expectEqual(@as(usize, 600), slab.count());
    var output: [600]Id = undefined;
    try std.testing.expectEqual(@as(usize, 600), slab.ids(&output).len);
}
