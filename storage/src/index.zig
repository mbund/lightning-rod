const std = @import("std");
const assert = std.debug.assert;

pub const Location = struct {
    epoch: u64 = 0,
    current: u64,
    owner: u32,
    committed: u64 = 0,
    // Null follows committed. Zero preserves absence in the active checkpoint snapshot.
    checkpoint: ?u64 = null,
    uncommitted: u64 = 0,
    materialized: u64 = 0,
    replacement: u64 = 0,
    replacement_dirty: bool = false,
    dirty: bool = false,
};

/// Removal shifts entries. Do not retain pointers or mutate the index while iterating.
pub const Index = struct {
    const Entry = struct { key: u64, value: Location };
    const Reference = struct { key_ptr: *u64, value_ptr: *Location };
    const Result = struct { found_existing: bool, value_ptr: *Location };

    entries: []Entry,
    slots: []u32,
    occupied: []u64,
    length: usize = 0,

    pub fn init(allocator: std.mem.Allocator, limit: u32) !Index {
        assert(limit > 0);
        const capacity = try std.math.ceilPowerOfTwo(usize, @as(usize, limit) * 2);
        const entries = try allocator.alloc(Entry, limit);
        errdefer allocator.free(entries);
        const slots = try allocator.alloc(u32, capacity);
        errdefer allocator.free(slots);
        const occupied = try allocator.alloc(u64, (capacity + 63) / 64);
        @memset(occupied, 0);
        return .{ .entries = entries, .slots = slots, .occupied = occupied };
    }

    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.slots);
        allocator.free(self.occupied);
        self.* = undefined;
    }

    pub fn count(self: *const Index) usize {
        return self.length;
    }

    pub fn position(self: *const Index, id: u64) usize {
        const at = self.slot(id);
        assert(self.isOccupied(at));
        return self.slots[at];
    }

    pub fn memoryBytes(self: *const Index) usize {
        return self.entries.len * @sizeOf(Entry) + self.slots.len * @sizeOf(u32) + self.occupied.len * @sizeOf(u64);
    }

    fn isOccupied(self: *const Index, at: usize) bool {
        return self.occupied[at / 64] & (@as(u64, 1) << @intCast(at % 64)) != 0;
    }

    fn slot(self: *const Index, id: u64) usize {
        const mask = self.slots.len - 1;
        var at = @as(usize, @truncate(std.hash.int(id))) & mask;
        while (self.isOccupied(at) and self.entries[self.slots[at]].key != id) at = (at + 1) & mask;
        return at;
    }

    pub fn get(self: *const Index, id: u64) ?Location {
        const at = self.slot(id);
        return if (!self.isOccupied(at)) null else self.entries[self.slots[at]].value;
    }

    pub fn getPtr(self: *Index, id: u64) ?*Location {
        const at = self.slot(id);
        return if (!self.isOccupied(at)) null else &self.entries[self.slots[at]].value;
    }

    pub fn contains(self: *const Index, id: u64) bool {
        return self.isOccupied(self.slot(id));
    }

    pub fn getOrPutAssumeCapacity(self: *Index, id: u64) Result {
        const at = self.slot(id);
        const found = self.isOccupied(at);
        if (!found) {
            assert(self.length < self.entries.len);
            self.entries[self.length].key = id;
            self.slots[at] = @intCast(self.length);
            self.occupied[at / 64] |= @as(u64, 1) << @intCast(at % 64);
            self.length += 1;
        }
        return .{ .found_existing = found, .value_ptr = &self.entries[self.slots[at]].value };
    }

    pub fn putAssumeCapacity(self: *Index, id: u64, value: Location) void {
        self.getOrPutAssumeCapacity(id).value_ptr.* = value;
    }

    pub fn remove(self: *Index, id: u64) bool {
        var hole = self.slot(id);
        if (!self.isOccupied(hole)) return false;
        const removed = self.slots[hole];
        const mask = self.slots.len - 1;
        var at = (hole + 1) & mask;
        while (self.isOccupied(at)) : (at = (at + 1) & mask) {
            const home = @as(usize, @truncate(std.hash.int(self.entries[self.slots[at]].key))) & mask;
            if (((at -% home) & mask) >= ((at -% hole) & mask)) {
                self.slots[hole] = self.slots[at];
                hole = at;
            }
        }
        self.occupied[hole / 64] &= ~(@as(u64, 1) << @intCast(hole % 64));
        self.length -= 1;
        if (removed != self.length) {
            const moved = self.slot(self.entries[self.length].key);
            self.entries[removed] = self.entries[self.length];
            self.slots[moved] = removed;
        }
        return true;
    }

    pub const Iterator = struct {
        index: *Index,
        at: usize = 0,

        pub fn next(self: *Iterator) ?Reference {
            if (self.at == self.index.length) return null;
            const entry = &self.index.entries[self.at];
            self.at += 1;
            return .{ .key_ptr = &entry.key, .value_ptr = &entry.value };
        }
    };

    pub fn iterator(self: *Index) Iterator {
        return .{ .index = self };
    }

    pub const ValueIterator = struct {
        entries: Iterator,

        pub fn next(self: *ValueIterator) ?*Location {
            const entry = self.entries.next() orelse return null;
            return entry.value_ptr;
        }
    };

    pub fn valueIterator(self: *Index) ValueIterator {
        return .{ .entries = self.iterator() };
    }
};
