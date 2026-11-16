const std = @import("std");
const storage = @import("storage");
const records = @import("records");
const Players = @import("players").players.Players;
const Domains = @import("domains").domains.Domains;
const ticks = @import("ticks.zig");

const Ticks = ticks.Ticks;

const Recorder = struct {
    runs: [16]struct { tick: u64, x: i32 } = undefined,
    count: usize = 0,
    owner: *Ticks = undefined,

    fn run(self: *Recorder, event: ticks.Event) !void {
        self.runs[self.count] = .{ .tick = self.owner.now(), .x = event.position.x };
        self.count += 1;
    }
};

const World = struct {
    player_records: [1]Players.Player,
    plugin: Players,
    domains: *Domains,
    ticks: *Ticks,
    recorder: Recorder = .{},
    kind: ticks.Kind,

    fn init(self: *World, allocator: std.mem.Allocator, store: *storage.Store) !void {
        return self.initNamed(allocator, store, null);
    }

    /// Registers a kind named `before` ahead of the marking kind, as a server whose plugins changed.
    fn initNamed(self: *World, allocator: std.mem.Allocator, store: *storage.Store, before: ?[]const u8) !void {
        self.player_records = .{.{ .handle = .{ .index = 0, .generation = 1 }, .world = 0, .position = .{ .x = 8, .y = 64, .z = 8 } }};
        self.plugin = .{ .deps = undefined, .config = .{ .render_distance = 2, .simulation_distance = 2 }, .spawn_world = 0, .records = &self.player_records, .dig_handlers = &.{} };
        self.domains = try Domains.init(allocator, .{}, .{ .players = &self.plugin });
        const workspaces = try records.Workspaces.init(allocator, store.io, .{});
        self.ticks = try Ticks.init(allocator, .{ .events = 64, .columns = 64, .column_events = 64 }, .{ .domains = self.domains, .record_workspaces = workspaces, .storage = try store.openSpace(Ticks.id) });
        self.recorder = .{ .owner = self.ticks };
        if (before) |name| _ = try self.ticks.register(name, .init(Recorder, &self.recorder, Recorder.run));
        self.kind = try self.ticks.register("test:mark", .init(Recorder, &self.recorder, Recorder.run));
    }

    fn step(self: *World) !void {
        self.domains.tick();
        try self.ticks.tick();
    }

    fn away(self: *World) void {
        self.player_records[0].position = .{ .x = 8000, .y = 64, .z = 8 };
    }
};

fn mark(world: *World, x: i32, priority: ticks.Priority) ticks.Event {
    return .{ .world = 0, .position = .{ .x = x, .y = 70, .z = 3 }, .kind = world.kind, .priority = priority };
}

test "scheduled ticks run in the ticking domain after their delay in vanilla order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path: [256]u8 = undefined;
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = try std.fmt.bufPrint(&path, ".zig-cache/tmp/{s}/ticks", .{directory.sub_path}) });
    defer store.deinit();
    var world: World = undefined;
    try world.init(arena.allocator(), &store);
    try world.step();
    try world.ticks.schedule(mark(&world, 1, .normal), 3);
    try world.ticks.schedule(mark(&world, 2, .high), 3);
    try world.ticks.schedule(mark(&world, 3, .normal), 1);
    // A second tick of the kind at the block keeps the first one's time.
    try world.ticks.schedule(mark(&world, 3, .normal), 9);
    try std.testing.expect(world.ticks.scheduled(mark(&world, 1, .low)));
    const start = world.ticks.now();
    for (0..4) |_| try world.step();
    try std.testing.expectEqual(@as(usize, 3), world.recorder.count);
    try std.testing.expectEqual(@as(i32, 3), world.recorder.runs[0].x);
    try std.testing.expectEqual(start + 1, world.recorder.runs[0].tick);
    try std.testing.expectEqual([2]i32{ 2, 1 }, .{ world.recorder.runs[1].x, world.recorder.runs[2].x });
    try std.testing.expectEqual(start + 3, world.recorder.runs[1].tick);
}

test "ticks of a column that stops ticking wait, survive a restart and resume their delay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path: [256]u8 = undefined;
    const options: storage.Store.Options = .{ .path = try std.fmt.bufPrint(&path, ".zig-cache/tmp/{s}/ticks-restart", .{directory.sub_path}) };
    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, options);
        defer store.deinit();
        var world: World = undefined;
        try world.init(arena.allocator(), &store);
        try world.step();
        try world.ticks.schedule(mark(&world, 5, .normal), 6);
        try world.step();
        try world.step();
        // Four ticks are left when the player walks away.
        world.away();
        for (0..50) |_| try world.step();
        try std.testing.expectEqual(@as(usize, 0), world.recorder.count);
        try world.ticks.checkpoint(try store.openSpace(Ticks.id));
        try store.waitDurable(try store.commit(1));
        // The saved column left memory.
        try std.testing.expectEqual(@as(u32, 0), world.ticks.queue.used);
    }
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, options);
    defer store.deinit();
    var world: World = undefined;
    try world.init(arena.allocator(), &store);
    try world.step();
    const start = world.ticks.now();
    for (0..6) |_| try world.step();
    try std.testing.expectEqual(@as(usize, 1), world.recorder.count);
    try std.testing.expectEqual(@as(i32, 5), world.recorder.runs[0].x);
    // Read on the first tick before time moves, so the four ticks left count from the tick before.
    try std.testing.expectEqual(start + 3, world.recorder.runs[0].tick);
}

test "saved ticks keep their kind by name when kinds register in another order or go away" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path: [256]u8 = undefined;
    const options: storage.Store.Options = .{ .path = try std.fmt.bufPrint(&path, ".zig-cache/tmp/{s}/ticks-kinds", .{directory.sub_path}) };
    for (0..3) |run| {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, options);
        defer store.deinit();
        var world: World = undefined;
        // The first run registers a kind the others do not, so the marking kind moves, and the
        // last registers one new to the world.
        try world.initNamed(arena.allocator(), &store, switch (run) {
            0 => "test:gone",
            1 => null,
            else => "test:fresh",
        });
        try world.step();
        if (run == 0) {
            try world.ticks.schedule(mark(&world, 7, .normal), 2);
            try world.ticks.schedule(.{ .world = 0, .position = .{ .x = 9, .y = 70, .z = 3 }, .kind = 0 }, 40);
            world.away();
            try world.step();
        } else {
            for (0..3) |_| try world.step();
            // The gone kind's tick is dropped, the marking tick runs under its new index.
            try std.testing.expectEqual(@as(usize, if (run == 1) 1 else 0), world.recorder.count);
            if (run == 1) try std.testing.expectEqual(@as(i32, 7), world.recorder.runs[0].x);
        }
        try world.ticks.checkpoint(try store.openSpace(Ticks.id));
        try store.waitDurable(try store.commit(run + 1));
    }
}
