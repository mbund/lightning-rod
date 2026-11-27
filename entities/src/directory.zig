//! Every entity in memory, by slot: its id, its kind, and where each of its components' records
//! lies. A slot is the entity's address while it is in memory: other entities hold it with the id
//! (a `Handle`), clients know it by the slot plus one, and it grows in the entities' pool a page at
//! a time. Slots let go are taken again first in, first out: a slot, and so a network id, comes
//! back as late as it can.
//!
//! Finding a slot by id goes through `ids`, which pages ids in order, without hashing.

const std = @import("std");
const pool_module = @import("pool.zig");
const IdIndex = @import("id_index.zig").IdIndex;

const assert = std.debug.assert;

pub const Id = u64;
pub const none = std.math.maxInt(u32);

pub const Entry = struct {
    id: Id = 0,
    kind: u32 = 0,
    /// Where its row lies in its kind's table: the block's page and the row in it, and whether
    /// the table's dormant part holds it rather than the part that ticks.
    block: u32 = none,
    row: u16 = 0,
    dormant: bool = false,
    /// Its place in the tick order, 0 while out of it; whether the order walks it; and the
    /// pass it fell asleep in.
    sequence: u64 = 0,
    awake: bool = false,
    slept: u32 = 0,
    /// Where it is in the space: its column's index, and the block and row there, the column
    /// none while it is not placed.
    space_column: u32 = none,
    space_block: u32 = 0,
    space_row: u16 = 0,
    /// The slot of what it rides, Entity.vehicle, none riding nothing. Freed with the slot.
    vehicle: u32 = none,
    /// While the slot is free, the one let go after it.
    next_free: u32 = none,
    /// Whether clients still know the entity, so the slot, and with it the network id, stays
    /// its own until they are told it is gone.
    held: bool = false,
    /// Whether the entity left memory while held: the slot frees once let go.
    retired: bool = false,
};

/// An entity held by another: its slot, and its id to tell it from a later one in the slot.
pub const Handle = struct {
    slot: u32,
    id: Id,
};

pub const Directory = struct {
    entries: pool_module.Array(Entry),
    /// Slots let go, oldest first.
    free_head: u32 = none,
    free_tail: u32 = none,
    free_count: usize = 0,
    ids: IdIndex,
    /// Entities in memory at most.
    room: usize,

    pub fn init(allocator: std.mem.Allocator, pool: *pool_module.Pool, room: usize) !Directory {
        if (room == 0 or room >= std.math.maxInt(i32)) return error.InvalidConfiguration;
        return .{ .entries = try .init(allocator, pool), .ids = try .init(allocator, pool), .room = room };
    }

    /// Slots used or ever used: every slot below it has an entry.
    pub fn high(self: *const Directory) usize {
        return self.entries.len;
    }

    pub fn capacity(self: *const Directory) usize {
        return self.room;
    }

    pub fn count(self: *const Directory) usize {
        return self.ids.count;
    }

    pub fn slotOf(self: *const Directory, entity: Id) ?u32 {
        return @constCast(&self.ids).get(entity);
    }

    pub fn entry(self: *const Directory, slot: u32) *Entry {
        return self.entries.at(slot);
    }

    /// The slot a handle names, if its entity is still there.
    pub fn find(self: *const Directory, handle: Handle) ?u32 {
        if (handle.slot >= self.entries.len or self.entries.at(handle.slot).id != handle.id) return null;
        return handle.slot;
    }

    pub fn handleOf(self: *const Directory, slot: u32) Handle {
        return .{ .slot = slot, .id = self.entries.at(slot).id };
    }

    /// A slot for a new entity in memory: the one let go longest ago, or a new one.
    pub fn add(self: *Directory, entity: Id, kind: u32) !u32 {
        assert(entity != 0 and !@constCast(&self.ids).contains(entity));
        if (self.ids.count == self.room) return error.DirectoryFull;
        const slot: u32 = slot: {
            if (self.free_head != none) {
                const slot = self.free_head;
                self.free_head = self.entries.at(slot).next_free;
                if (self.free_head == none) self.free_tail = none;
                self.free_count -= 1;
                break :slot slot;
            }
            // Network ids end at the protocol's last positive one.
            if (self.entries.len == std.math.maxInt(i32) - 1) return error.NetworkIdsExhausted;
            break :slot @intCast(self.entries.grow() catch return error.DirectoryFull);
        };
        self.ids.put(entity, slot) catch {
            // The slot goes back, unused.
            self.entries.at(slot).* = .{};
            if (self.free_tail == none) self.free_head = slot else self.entries.at(self.free_tail).next_free = slot;
            self.free_tail = slot;
            self.free_count += 1;
            return error.EntityMemoryExhausted;
        };
        self.entries.at(slot).* = .{ .id = entity, .kind = kind };
        return slot;
    }

    /// The entity leaves memory; its components' records must have gone first.
    pub fn remove(self: *Directory, slot: u32) void {
        const gone = self.entries.at(slot);
        assert(!gone.held and !gone.retired);
        assert(self.ids.remove(gone.id));
        self.free(slot);
    }

    /// The entity leaves memory but its slot stays taken: clients still know it by the slot.
    /// Lookups by its id miss from now on.
    pub fn retire(self: *Directory, slot: u32) void {
        const gone = self.entries.at(slot);
        assert(gone.held and !gone.retired);
        assert(self.ids.remove(gone.id));
        gone.* = .{ .held = true, .retired = true };
    }

    /// A slot no entity holds any more goes back, taken again last.
    pub fn free(self: *Directory, slot: u32) void {
        self.entries.at(slot).* = .{};
        if (self.free_tail == none) self.free_head = slot else self.entries.at(self.free_tail).next_free = slot;
        self.free_tail = slot;
        self.free_count += 1;
    }
};

test "slots come and go, the oldest let go taken first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pool = try pool_module.Pool.init(arena.allocator(), 4 * pool_module.page_bytes);
    var directory = try Directory.init(arena.allocator(), &pool, 3);
    const a = try directory.add(10, 1);
    const b = try directory.add(11, 1);
    const c = try directory.add(12, 1);
    try std.testing.expectError(error.DirectoryFull, directory.add(13, 1));
    try std.testing.expectEqual(@as(?u32, b), directory.slotOf(11));
    const held = directory.handleOf(b);
    directory.remove(b);
    directory.remove(a);
    try std.testing.expectEqual(@as(?u32, null), directory.find(held));
    // B went first, so it comes back first.
    try std.testing.expectEqual(b, try directory.add(14, 2));
    try std.testing.expectEqual(a, try directory.add(15, 2));
    try std.testing.expectEqual(@as(?u32, c), directory.find(directory.handleOf(c)));
}
