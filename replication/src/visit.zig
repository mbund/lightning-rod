//! Which of a kind's entities its replication looks at in a tick: those tracking changed an
//! audience of, those whose replicated state changed, and those some viewer is owed whole.
//! Nothing else has anything to send, so the rest are never walked.

const std = @import("std");
const lightning_rod = @import("lightning_rod");
const Tracking = @import("tracking.zig").Tracking;

const IndexSet = lightning_rod.system.IndexSet;

pub const Visit = struct {
    /// Slots whose replicated state changed since they were last visited, as their kind says.
    changed: IndexSet,
    /// Slots a viewer missed a delta of, until caught up.
    owed: IndexSet,
    /// The slots of a tick's visit.
    order: []u32,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, slots: usize) !Visit {
        return .{ .changed = try .init(allocator, slots), .owed = try .init(allocator, slots), .order = try allocator.alloc(u32, slots) };
    }

    /// What clients have of the entity in a slot changed: its next visit sends it.
    pub fn mark(self: *Visit, slot: u32) void {
        self.changed.insert(slot);
    }

    /// A viewer missed a delta of it: it is visited until every viewer has it whole.
    pub fn owe(self: *Visit, slot: u32) void {
        self.owed.insert(slot);
    }

    /// Its viewers have it whole again, or it has none.
    pub fn settle(self: *Visit, slot: u32) void {
        self.owed.remove(slot);
    }

    /// The slots to look at this tick, each once, in the order `before` puts them: those of the
    /// tracker's changes, those marked, and those owed. Good until the next collect.
    pub fn collect(self: *Visit, tracking: *const Tracking, tracker: Tracking.TrackerId, context: anytype, comptime before: fn (@TypeOf(context), u32, u32) bool) []const u32 {
        self.count = 0;
        var changes = tracking.changesOf(tracker);
        while (changes.next()) |change| self.changed.insert(change.slot);
        for (self.owed.values()) |slot| self.changed.insert(slot);
        for (self.changed.values()) |slot| {
            self.order[self.count] = @intCast(slot);
            self.count += 1;
        }
        self.changed.clear();
        const visited = self.order[0..self.count];
        // Slots are distinct, so the order is total and an unstable sort gives one result.
        std.sort.pdq(u32, visited, context, before);
        return visited;
    }
};
