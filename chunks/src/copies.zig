//! Copies of the sections a system on the simulation thread reads, decoded once and kept across
//! ticks. A section is leased only while it is decoded, so nothing is held when the reader edits
//! blocks, which an edit waits for. Every edit is applied to the copies as well, so they read as
//! the chunks do, including the reader's own writes. Reads after the first are an array lookup.
//!
//! A section held in the chunks changes only by an edit, so its copy stays true. A section that
//! is not there yet reads as air and may be filled by generation without an edit, so its copy
//! lasts only until the end of the tick. When the copies are full, the clock replaces one not
//! read since it last came round.

const std = @import("std");
const chunks = @import("chunks.zig");

const assert = std.debug.assert;

pub const Copies = struct {
    owner: *chunks.Chunks,
    client: chunks.Chunks.Client,
    sections: []chunks.Section,
    states: [][chunks.encoding.blocks]u16,
    /// Copies of sections that were absent, dropped at the end of the tick.
    absent: []bool,
    referenced: []bool,
    used: []bool,
    /// Slots by section. Its capacity is reserved at init.
    index: std.AutoHashMapUnmanaged(chunks.Section, u32) = .empty,
    /// Slots never used or freed, taken before the clock replaces any.
    free: []u32,
    free_count: usize,
    hand: usize = 0,
    /// Copies read lately, by the low two bits of each section coordinate, as reads come in runs
    /// over a few neighbouring sections: any four by four by four of them fit at once.
    recent: [64]u32 = @splat(no_slot),
    /// Sections decoded, for measuring.
    decoded: u64 = 0,

    /// Startup only. Registers an edit observer, so make one per reader.
    pub fn init(allocator: std.mem.Allocator, owner: *chunks.Chunks, capacity: u32) !*Copies {
        if (capacity == 0) return error.InvalidConfiguration;
        const self = try allocator.create(Copies);
        self.* = .{
            .owner = owner,
            .client = try owner.simulation(1),
            .sections = try allocator.alloc(chunks.Section, capacity),
            .states = try allocator.alloc([chunks.encoding.blocks]u16, capacity),
            .absent = try allocator.alloc(bool, capacity),
            .referenced = try allocator.alloc(bool, capacity),
            .used = try allocator.alloc(bool, capacity),
            .free = try allocator.alloc(u32, capacity),
            .free_count = capacity,
        };
        @memset(self.used, false);
        @memset(self.referenced, false);
        for (self.free, 0..) |*slot, at| slot.* = @intCast(capacity - 1 - at);
        try self.index.ensureTotalCapacity(allocator, capacity);
        try owner.observe(.init(self, changed));
        return self;
    }

    pub fn get(self: *Copies, world: u32, position: chunks.Position) !u16 {
        const section: chunks.Section = .{ .world = world, .x = @divFloor(position.x, 16), .y = @divFloor(position.y, 16), .z = @divFloor(position.z, 16) };
        const slot = try self.find(section);
        return self.states[slot][chunks.localIndex(position)];
    }

    /// Writes through to the chunks. The edit comes back through the observer to the copy.
    pub fn set(self: *Copies, world: u32, position: chunks.Position, state: u16) !void {
        try self.owner.setBlock(world, position, state);
    }

    /// Drops the copies of sections that were absent, which generation may fill.
    pub fn endTick(self: *Copies) void {
        for (self.used, self.absent, 0..) |used, absent, slot| {
            if (used and absent) self.drop(@intCast(slot));
        }
    }

    fn drop(self: *Copies, slot: u32) void {
        assert(self.used[slot]);
        assert(self.index.remove(self.sections[slot]));
        self.used[slot] = false;
        self.referenced[slot] = false;
        self.free[self.free_count] = slot;
        self.free_count += 1;
        const recent = recentIndex(self.sections[slot]);
        if (self.recent[recent] == slot) self.recent[recent] = no_slot;
    }

    fn find(self: *Copies, section: chunks.Section) !u32 {
        const recent = recentIndex(section);
        const cached = self.recent[recent];
        if (cached != no_slot and sameSection(self.sections[cached], section)) {
            self.referenced[cached] = true;
            return cached;
        }
        if (self.index.get(section)) |slot| {
            self.referenced[slot] = true;
            self.recent[recent] = slot;
            return slot;
        }
        const slot = self.take();
        const lease = try self.client.acquire(section);
        defer lease.release();
        const view = lease.view();
        for (&self.states[slot], 0..) |*state, cell| state.* = view.get(@intCast(cell));
        self.sections[slot] = section;
        self.absent[slot] = lease.record.read() == null;
        self.used[slot] = true;
        self.referenced[slot] = true;
        self.index.putAssumeCapacityNoClobber(section, slot);
        self.recent[recent] = slot;
        self.decoded += 1;
        return slot;
    }

    const no_slot = std.math.maxInt(u32);

    fn recentIndex(section: chunks.Section) usize {
        const x: usize = @as(u2, @truncate(@as(u32, @bitCast(section.x))));
        const y: usize = @as(u2, @truncate(@as(u32, @bitCast(section.y))));
        const z: usize = @as(u2, @truncate(@as(u32, @bitCast(section.z))));
        return x | y << 2 | z << 4;
    }

    fn sameSection(a: chunks.Section, b: chunks.Section) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z and a.world == b.world;
    }

    /// A free slot, or the first the clock finds unread since it last passed.
    fn take(self: *Copies) u32 {
        if (self.free_count != 0) {
            self.free_count -= 1;
            return self.free[self.free_count];
        }
        while (true) : (self.hand = (self.hand + 1) % self.sections.len) {
            if (self.referenced[self.hand]) {
                self.referenced[self.hand] = false;
                continue;
            }
            const slot: u32 = @intCast(self.hand);
            self.hand = (self.hand + 1) % self.sections.len;
            self.drop(slot);
            self.free_count -= 1;
            return slot;
        }
    }

    fn changed(self: *Copies, section: chunks.Section, edits: []const chunks.BlockEdit, _: []const u16) void {
        const slot = self.index.get(section) orelse return;
        // An edit generates a section that was absent first, which the air copy does not hold.
        if (self.absent[slot]) return self.drop(slot);
        for (edits) |edit| self.states[slot][edit.index] = edit.state;
    }
};
