//! Domains say which columns the server works on. The ticking domain is every column within
//! simulation distance of a player in a world, plus forced columns. Systems that change the world
//! on their own, such as random ticks, run there and read one column further. A player counts
//! from the moment they are placed in a world, as vanilla adds the player ticket then. The view domain
//! is each player's render distance, a circle as vanilla measures it.

const std = @import("std");
const Players = @import("players").players.Players;
const ticking = @import("ticking.zig");

const assert = std.debug.assert;

pub const Column = ticking.Column;

pub const Domains = struct {
    pub const id = "lightning_rod:domains";
    pub const Configuration = struct {
        /// Columns commands and plugins may force to tick at once.
        forced: usize = 256,
        observers: usize = 8,
    };
    pub const Dependencies = struct { players: *Players };

    /// Told once per tick which columns began and stopped ticking. Columns are borrowed for the
    /// call. A column that did both in one tick is in neither.
    pub const Observer = struct {
        context: *anyopaque,
        changed: *const fn (*anyopaque, []const Column, []const Column) void,

        pub fn init(comptime Context: type, context: *Context, comptime changed: fn (*Context, []const Column, []const Column) void) Observer {
            const Adapter = struct {
                fn call(raw: *anyopaque, entered: []const Column, left: []const Column) void {
                    changed(@ptrCast(@alignCast(raw)), entered, left);
                }
            };
            return .{ .context = context, .changed = Adapter.call };
        }
    };

    deps: Dependencies,
    simulation: ticking.Ticking,
    observers: []Observer,
    observer_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Domains {
        if (config.observers == 0) return error.InvalidConfiguration;
        const self = try allocator.create(Domains);
        errdefer allocator.destroy(self);
        var simulation = try ticking.Ticking.init(allocator, .{
            .sources = deps.players.records.len,
            .maximum_radius = deps.players.config.simulation_distance,
            .forced = config.forced,
        });
        errdefer simulation.deinit(allocator);
        self.* = .{ .deps = deps, .simulation = simulation, .observers = try allocator.alloc(Observer, config.observers) };
        return self;
    }

    pub fn observe(self: *Domains, observer: Observer) !void {
        if (self.observer_count == self.observers.len) return error.ObserverCapacity;
        // Observers register before anything ticks, so none misses a column already ticking.
        assert(self.simulation.columns() == 0);
        self.observers[self.observer_count] = observer;
        self.observer_count += 1;
    }

    /// Columns that may tick at once: every player's simulation distance and the forced ones.
    pub fn capacity(self: *const Domains) usize {
        return self.simulation.capacity;
    }

    /// Whether systems that change the world run in a column this tick.
    pub fn ticks(self: *const Domains, column: Column) bool {
        return self.simulation.contains(column);
    }

    /// Ticking columns and their neighbours, which ticking systems may read.
    pub fn readable(self: *const Domains, column: Column) bool {
        return self.simulation.readable(column);
    }

    pub fn tickingColumns(self: *const Domains) ticking.Ticking.Iterator {
        return self.simulation.iterator();
    }

    pub fn force(self: *Domains, column: Column) !void {
        try self.simulation.force(column);
    }

    pub fn unforce(self: *Domains, column: Column) !void {
        try self.simulation.unforce(column);
    }

    /// Whether a player's client shows a column: vanilla's view distance from the nearest edge of
    /// the player's column, by strict squared distance.
    pub fn viewed(self: *const Domains, slot: usize, column: Column) bool {
        assert(slot < self.deps.players.records.len);
        const player = self.deps.players.records[slot];
        if (!player.inWorld() or player.world != column.world) return false;
        return viewContains(self.deps.players.viewDistanceOf(player), playerColumn(player), .{ column.x, column.z });
    }

    /// Players are positioned by the time plugins after Players tick, so the domain moves first.
    pub fn tick(self: *Domains) void {
        const players = self.deps.players;
        for (players.records, 0..) |player, slot| {
            const source: ?ticking.Source = if (player.inWorld()) source: {
                const at = playerColumn(player);
                break :source .{ .world = player.world, .x = at[0], .z = at[1], .radius = players.config.simulation_distance };
            } else null;
            self.simulation.update(slot, source);
        }
        const changes = self.simulation.drain();
        if (changes.entered.len == 0 and changes.left.len == 0) return;
        for (self.observers[0..self.observer_count]) |observer| observer.changed(observer.context, changes.entered, changes.left);
    }
};

fn playerColumn(player: Players.Player) [2]i32 {
    return .{ @intFromFloat(@floor(player.position.x / 16)), @intFromFloat(@floor(player.position.z / 16)) };
}

pub fn viewContains(radius: i32, center: [2]i32, at: [2]i32) bool {
    assert(radius >= 0);
    const x = @abs(@as(i64, at[0]) - center[0]);
    const z = @abs(@as(i64, at[1]) - center[1]);
    const r: u64 = @intCast(radius);
    if (x > r or z > r) return false;
    if (radius == 0) return true;
    return (x -| 1) * (x -| 1) + (z -| 1) * (z -| 1) < r * r;
}

test "view containment measures from the nearest edge like vanilla" {
    try std.testing.expect(viewContains(2, .{ 0, 0 }, .{ 2, 0 }));
    try std.testing.expect(viewContains(2, .{ 0, 0 }, .{ 2, 2 }));
    try std.testing.expect(!viewContains(2, .{ 0, 0 }, .{ 3, 0 }));
    try std.testing.expect(viewContains(0, .{ 5, 5 }, .{ 5, 5 }));
}
