//! Copies of the sections a system on the simulation thread reads, decoded once and kept until
//! it clears them, normally at the end of the tick. A section is leased only while it is
//! decoded, so nothing is held when the reader edits blocks, which an edit waits for. Every edit
//! is applied to the copies as well, so they read as the chunks do, including the reader's own
//! writes. Reads after the first are an array lookup.

const std = @import("std");
const chunks = @import("chunks.zig");

const assert = std.debug.assert;

pub const Copies = struct {
    owner: *chunks.Chunks,
    client: chunks.Chunks.Client,
    sections: []chunks.Section,
    states: [][chunks.encoding.blocks]u16,
    count: usize = 0,
    /// The copy the last read used, as reads come in runs over one section.
    last: usize = 0,
    /// Sections decoded since the copies were made, for measuring.
    decoded: u64 = 0,

    /// Startup only. Registers an edit observer, so make one per reader rather than per tick.
    pub fn init(allocator: std.mem.Allocator, owner: *chunks.Chunks, capacity: usize) !*Copies {
        if (capacity == 0) return error.InvalidConfiguration;
        const self = try allocator.create(Copies);
        self.* = .{
            .owner = owner,
            .client = try owner.simulation(1),
            .sections = try allocator.alloc(chunks.Section, capacity),
            .states = try allocator.alloc([chunks.encoding.blocks]u16, capacity),
        };
        try owner.observe(.init(self, changed));
        return self;
    }

    pub fn get(self: *Copies, world: u32, position: chunks.Position) !u16 {
        const section: chunks.Section = .{ .world = world, .x = @divFloor(position.x, 16), .y = @divFloor(position.y, 16), .z = @divFloor(position.z, 16) };
        const index = try self.find(section);
        return self.states[index][chunks.localIndex(position)];
    }

    /// Writes through to the chunks. The edit comes back through the observer to the copy.
    pub fn set(self: *Copies, world: u32, position: chunks.Position, state: u16) !void {
        try self.owner.setBlock(world, position, state);
    }

    /// Drops every copy. Sections can change without an edit, as when generation fills one, so
    /// copies do not outlive the tick they were made in.
    pub fn clear(self: *Copies) void {
        self.count = 0;
        self.last = 0;
    }

    fn find(self: *Copies, section: chunks.Section) !usize {
        if (self.last < self.count and std.meta.eql(self.sections[self.last], section)) return self.last;
        for (self.sections[0..self.count], 0..) |held, index| {
            if (!std.meta.eql(held, section)) continue;
            self.last = index;
            return index;
        }
        // Copies are a cache of the chunks, so a full set may start over at any time.
        if (self.count == self.sections.len) self.clear();
        const index = self.count;
        const lease = try self.client.acquire(section);
        defer lease.release();
        const view = lease.view();
        for (&self.states[index], 0..) |*state, cell| state.* = view.get(@intCast(cell));
        self.sections[index] = section;
        self.count += 1;
        self.last = index;
        self.decoded += 1;
        return index;
    }

    fn changed(self: *Copies, section: chunks.Section, edits: []const chunks.BlockEdit, _: []const u16) void {
        for (self.sections[0..self.count], self.states[0..self.count]) |held, *states| {
            if (!std.meta.eql(held, section)) continue;
            for (edits) |edit| states[edit.index] = edit.state;
            return;
        }
    }
};
