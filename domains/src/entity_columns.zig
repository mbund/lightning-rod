//! The entity tick list follows the ticking domain: as columns begin and stop ticking, the
//! entities in them, of every kind, join or leave the one order, as vanilla's entity sections
//! start and stop ticking. Columns change only while the domains tick, before any entity does.
//! The entities of every kind follow the loaded domain too: a column coming in has its entities read
//! from the store before it ticks, and one leaving has them written there after it stops.

const std = @import("std");
const entities = @import("entities");
const domains_module = @import("domains.zig");

const Domains = domains_module.Domains;

pub const EntityColumns = struct {
    pub const id = "lightning_rod:entity_columns";
    pub const Configuration = struct {};
    pub const Dependencies = struct { domains: *Domains, entities: *entities.Entities };

    deps: Dependencies,
    entered: []entities.Column,
    left: []entities.Column,
    /// What went wrong following the domains, told at this plugin's turn in the tick.
    failure: ?anyerror = null,
    /// Columns made in the space as of the last look for entities outside the loaded domain.
    columns_seen: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, _: Configuration, deps: Dependencies) !*EntityColumns {
        const self = try allocator.create(EntityColumns);
        self.* = .{
            .deps = deps,
            .entered = try allocator.alloc(entities.Column, deps.domains.capacity()),
            .left = try allocator.alloc(entities.Column, deps.domains.capacity()),
        };
        // Observers come before anything ticks, so no column ticks yet.
        try deps.domains.observe(.init(EntityColumns, self, changed));
        try deps.domains.observeLoaded(.init(EntityColumns, self, loadedChanged));
        deps.entities.columns_followed = true;
        return self;
    }

    fn changed(self: *EntityColumns, entered: []const domains_module.Column, left: []const domains_module.Column) void {
        if (self.failure != null) return;
        self.follow(entered, left) catch |err| {
            self.failure = err;
        };
    }

    fn loadedChanged(self: *EntityColumns, entered: []const domains_module.Column, left: []const domains_module.Column) void {
        if (self.failure != null) return;
        self.load(entered, left) catch |err| {
            self.failure = err;
        };
    }

    fn load(self: *EntityColumns, entered: []const domains_module.Column, left: []const domains_module.Column) !void {
        // Told one way at a time, each no more than the loaded domain holds.
        var columns: [64]entities.Column = undefined;
        var at: usize = 0;
        while (at < entered.len + left.len) {
            const leaving = at >= entered.len;
            const from = if (leaving) left[at - entered.len ..] else entered[at..];
            const count = @min(from.len, columns.len);
            for (from[0..count], columns[0..count]) |column, *into| into.* = .{ .world = column.world, .x = column.x, .z = column.z };
            if (leaving) try self.deps.entities.columnsChanged(&.{}, columns[0..count]) else try self.deps.entities.columnsChanged(columns[0..count], &.{});
            at += count;
        }
    }

    fn follow(self: *EntityColumns, entered: []const domains_module.Column, left: []const domains_module.Column) !void {
        const places = &self.deps.entities.places;
        if (entered.len > self.entered.len or left.len > self.left.len) {
            // More than room to hold: the ticking columns are taken afresh.
            var columns = self.deps.domains.tickingColumns();
            return places.resyncTicking(&columns);
        }
        for (entered, self.entered[0..entered.len]) |column, *into| into.* = .{ .world = column.world, .x = column.x, .z = column.z };
        for (left, self.left[0..left.len]) |column, *into| into.* = .{ .world = column.world, .x = column.x, .z = column.z };
        try places.changeTicking(self.entered[0..entered.len], self.left[0..left.len]);
    }

    pub fn tick(self: *EntityColumns) !void {
        if (self.failure) |err| return err;
        try self.sweep();
    }

    /// Entities came into columns outside the loaded domain, as one made or moved where no player
    /// keeps the chunk: they go to the store as their column would, since vanilla keeps no
    /// entities of chunks not loaded. Looked for only when some column gained its first entity.
    fn sweep(self: *EntityColumns) !void {
        const space = &self.deps.entities.places.space;
        if (space.columns_made == self.columns_seen) return;
        self.columns_seen = space.columns_made;
        // A run at a time, as each leaving changes the space, until none is left.
        while (true) {
            var strays: [64]entities.Column = undefined;
            var count: usize = 0;
            for (0..space.columnCount()) |at| {
                const held = space.columnAt(at);
                // Only what is stored goes to the store: players as subjects stay where they are.
                if (held.count == 0 or !space.holdsStored(held)) continue;
                const column = held.column;
                if (self.deps.domains.loads(.{ .world = column.world, .x = column.x, .z = column.z })) continue;
                if (count == strays.len) break;
                strays[count] = column;
                count += 1;
            }
            if (count == 0) return;
            std.sort.pdq(entities.Column, strays[0..count], {}, columnBefore);
            const before = space.count();
            try self.deps.entities.columnsChanged(&.{}, strays[0..count]);
            // What no kind takes to the store stays; the rest went.
            if (space.count() == before or count < strays.len) return;
        }
    }

    fn columnBefore(_: void, a: entities.Column, b: entities.Column) bool {
        if (a.world != b.world) return a.world < b.world;
        if (a.x != b.x) return a.x < b.x;
        return a.z < b.z;
    }
};
