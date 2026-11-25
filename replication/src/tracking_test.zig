//! The tracking layer against a brute-force oracle: players and entities moving, spawning,
//! leaving, reconnecting, respawning and changing view distance at random, with every change
//! accepted, partly accepted, or more of them than the work holds.

const std = @import("std");
const entities = @import("entities");
const Players = @import("players").players.Players;
const Tracking = @import("tracking.zig").Tracking;
const minecraft = @import("minecraft_model");

const Fixture = struct {
    entities: *entities.Entities,
    records: []Players.Player,
    players: Players,
    tracking: *Tracking,
    modes: []minecraft.GameMode,
    random: std.Random.DefaultPrng,
    next_id: u64 = 1,
    live: std.ArrayList(u64) = .empty,
    allocator: std.mem.Allocator,
    /// Entities of kind 3 sleep along straight paths, boxed, as arrows do.
    plans: []Plan,
    now: u64 = 0,
    sleepy: bool = false,
    /// How far players walk a tick at most, before any jump.
    stride: f64 = 6,

    const Plan = struct { start: [3]f64 = .{ 0, 0, 0 }, velocity: [3]f64 = .{ 0, 0, 0 }, since: u64 = 0 };
    const swept_kind = 3;
    const shape: entities.space.Shape = .{ .kind = swept_kind, .half_width = 0.25, .height = 0.5 };

    fn init(self: *Fixture, allocator: std.mem.Allocator, count: usize, work: u32, seed: u64) !void {
        const records = try allocator.alloc(Players.Player, count);
        for (records, 0..) |*player, index| player.* = .{ .handle = .{ .index = @intCast(index), .generation = 1 }, .uuid = index + 1, .stage = .ready, .position = .{ .x = 0, .y = 64, .z = 0 } };
        self.* = .{
            .entities = try entities.Entities.allocate(allocator, std.testing.io, .{ .memory = 1024 * entities.pool.page_bytes }, undefined),
            .records = records,
            .players = .{ .deps = undefined, .config = .{ .maximum = count, .render_distance = 6 }, .spawn_world = 0, .records = records, .dig_handlers = &.{} },
            .tracking = undefined,
            .modes = try allocator.alloc(minecraft.GameMode, count),
            .plans = undefined,
            .random = .init(seed),
            .allocator = allocator,
        };
        @memset(self.modes, .survival);
        try self.entities.places.space.sleepsOwn(.of(&.{swept_kind}));
        self.players.setRules(.init(Fixture, self, gameMode, spawnWorld, spawnPoint));
        // Its players place themselves among these entities.
        self.players.entities = self.entities;
        try self.players.initIndexes(allocator);
        try self.players.rebuildIndexes();
        self.tracking = try Tracking.init(allocator, .{ .work = work }, .{ .entities = self.entities, .players = &self.players });
        _ = try self.tracking.register(.{ .kinds = .of(&.{1}), .range = 96 });
        _ = try self.tracking.register(.{ .kinds = .of(&.{2}), .range = 160, .max_range = 240 });
        self.plans = try allocator.alloc(Plan, self.entities.directory.capacity());
        @memset(self.plans, .{});
        _ = try self.tracking.register(.{ .kinds = .of(&.{swept_kind}), .range = 64, .exact = .of(Fixture, self) });
    }

    /// Where a sleeping entity is now, along its plan.
    pub fn trackingPlace(self: *Fixture, slot: u32) !entities.Space.Placed {
        const plan = self.plans[slot];
        const ticks: f64 = @floatFromInt(self.now - plan.since);
        const position: [3]f64 = .{ plan.start[0] + plan.velocity[0] * ticks, plan.start[1], plan.start[2] + plan.velocity[2] * ticks };
        return .{ .entry = .{ .id = self.entities.directory.entry(slot).id, .slot = slot, .section = entities.space.coordinate(position[1]), .entered = 0, .position = position, .shape = shape }, .world = 0 };
    }

    /// Some entities of kind 3 go to sleep along a path, some only where tracking says they are
    /// settled; those whose sleep ends wake where their path took them.
    fn sleepSome(self: *Fixture) !void {
        const random = self.random.random();
        var due: [256]u32 = undefined;
        var found: usize = 0;
        self.entities.places.space.takeDue(self.now, .all, &due, &found);
        for (due[0..found]) |slot| {
            const placed = try self.trackingPlace(slot);
            _ = self.entities.places.space.unbox(slot);
            try self.entities.places.space.insert(placed.entry.id, 0, placed.entry.position, shape);
        }
        for (self.live.items) |id| {
            const slot = self.entities.directory.slotOf(id).?;
            if (self.entities.directory.entry(slot).kind != swept_kind or self.entities.places.space.boxOf(slot) != null) continue;
            if (random.uintLessThan(u8, 4) != 0) continue;
            const start = self.entities.places.space.get(id).?.position;
            const velocity: [3]f64 = .{ (random.float(f64) - 0.5) * 2, 0, (random.float(f64) - 0.5) * 2 };
            const ticks = random.intRangeAtMost(u64, 2, 20);
            const end: [3]f64 = .{ start[0] + velocity[0] * @as(f64, @floatFromInt(ticks)), start[1], start[2] + velocity[2] * @as(f64, @floatFromInt(ticks)) };
            const feet: entities.Feet = .{ .low = .{ @min(start[0], end[0]), start[1], @min(start[2], end[2]) }, .high = .{ @max(start[0], end[0]), start[1], @max(start[2], end[2]) } };
            if (!entities.Space.boxFits(feet, shape.half_width)) continue;
            if (random.boolean() and !try self.tracking.settled(slot, 0, feet, shape.half_width, shape.height)) continue;
            self.plans[slot] = .{ .start = start, .velocity = velocity, .since = self.now };
            if (!try self.entities.places.space.box(slot, 0, feet, shape.half_width, shape.height, self.now, self.now + ticks)) unreachable;
        }
    }

    fn gameMode(self: *Fixture, slot: usize) minecraft.GameMode {
        return self.modes[slot];
    }

    fn spawnWorld(_: *Fixture) u32 {
        return 0;
    }

    fn spawnPoint(_: *Fixture, _: *const Players.Player) anyerror!?Players.Rules.Spawn {
        return null;
    }

    /// Changes what some entities say of themselves, and who spectates, at random.
    fn sayThings(self: *Fixture) !void {
        const random = self.random.random();
        for (self.modes) |*mode| if (random.uintLessThan(u8, 30) == 0) {
            mode.* = if (mode.* == .spectator) .survival else .spectator;
        };
        for (self.live.items) |id| {
            if (random.uintLessThan(u8, 40) != 0) continue;
            const slot = self.entities.directory.slotOf(id).?;
            switch (random.uintLessThan(u8, 4)) {
                0 => if (self.entities.directory.entry(slot).kind == 2) try self.tracking.setRange(slot, if (random.boolean()) random.intRangeAtMost(u32, 100, 240) else null),
                1 => try self.tracking.setOwner(slot, if (random.boolean()) random.uintLessThan(usize, self.records.len) else null),
                2 => try self.tracking.setSpectatorsOnly(slot, random.boolean()),
                else => {
                    var words: [8]usize = @splat(0);
                    for (0..self.records.len) |player| if (random.boolean()) {
                        words[player / 64] |= @as(usize, 1) << @intCast(player % 64);
                    };
                    _ = try self.tracking.restrict(slot, if (random.boolean()) .{ .words = words[0..self.tracking.row_words], .capacity = self.records.len } else null);
                },
            }
        }
    }

    fn point(self: *Fixture) [3]f64 {
        const random = self.random.random();
        return .{ (random.float(f64) - 0.5) * 600, 64, (random.float(f64) - 0.5) * 600 };
    }

    fn spawn(self: *Fixture) !void {
        const id = self.next_id;
        self.next_id += 1;
        const kind: u32 = if (self.sleepy and self.random.random().uintLessThan(u8, 3) == 0) swept_kind else if (self.random.random().boolean()) 1 else 2;
        _ = try self.entities.enter(id, kind);
        try self.entities.places.insert(id, 0, self.point(), .{ .kind = kind, .half_width = 0.25, .height = 0.5 });
        self.plans[self.entities.directory.slotOf(id).?] = .{};
        try self.live.append(self.allocator, id);
    }

    fn despawn(self: *Fixture, at: usize) void {
        const id = self.live.swapRemove(at);
        const slot = self.entities.directory.slotOf(id).?;
        _ = self.entities.places.space.unbox(slot);
        self.entities.places.remove(id);
        self.entities.leave(slot);
    }

    /// One tick of random change.
    fn shake(self: *Fixture) !void {
        const random = self.random.random();
        for (self.records) |*player| {
            switch (random.uintLessThan(u8, 40)) {
                0 => player.position = .{ .x = (random.float(f64) - 0.5) * 600, .y = 64, .z = (random.float(f64) - 0.5) * 600 },
                1 => player.view_distance = random.intRangeAtMost(i32, 2, 10),
                2 => player.stage = if (player.stage == .ready) .respawn else .ready,
                3 => player.life += 1,
                4 => player.handle.?.generation += 1,
                else => {
                    player.position.x += (random.float(f64) - 0.5) * self.stride;
                    player.position.z += (random.float(f64) - 0.5) * self.stride;
                },
            }
        }
        try self.players.rebuildIndexes();
        self.now += 1;
        try self.stir();
    }

    /// Entities alone move, come and go, as they do while they tick.
    fn stir(self: *Fixture) !void {
        const random = self.random.random();
        for (self.live.items) |id| {
            if (random.uintLessThan(u8, 3) != 0) continue;
            // A sleeping one moves along its plan alone.
            const at = (self.entities.places.space.get(id) orelse continue).position;
            const far = random.uintLessThan(u8, 50) == 0;
            const next: [3]f64 = if (far) self.point() else .{ at[0] + (random.float(f64) - 0.5) * 2, at[1], at[2] + (random.float(f64) - 0.5) * 2 };
            try self.entities.places.moveById(id, 0, next);
        }
        for (0..random.uintLessThan(usize, 4)) |_| try self.spawn();
        if (self.live.items.len > 0 and random.boolean()) self.despawn(random.uintLessThan(usize, self.live.items.len));
    }

    /// Accepts every change, or only those for some players.
    fn deliver(self: *Fixture, accept: *const fn (usize) bool) void {
        const tracking = self.tracking;
        const words = tracking.row_words;
        var spawned: [8]usize = undefined;
        var removed: [8]usize = undefined;
        for (0..tracking.tracker_count) |tracker| {
            var changes = tracking.changesOf(@intCast(tracker));
            while (changes.next()) |change| {
                @memset(spawned[0..words], 0);
                @memset(removed[0..words], 0);
                for (0..self.records.len) |player| {
                    if (!accept(player)) continue;
                    if (change.spawn.contains(player)) spawned[player / 64] |= @as(usize, 1) << @intCast(player % 64);
                    if (change.remove.contains(player)) removed[player / 64] |= @as(usize, 1) << @intCast(player % 64);
                }
                tracking.confirm(change.slot, .{ .words = spawned[0..words], .capacity = self.records.len }, .{ .words = removed[0..words], .capacity = self.records.len });
            }
        }
    }
};

fn everyone(_: usize) bool {
    return true;
}

fn evens(player: usize) bool {
    return player % 2 == 0;
}

test "what clients have matches the rule asked of every pair, tick after tick" {
    for ([_]u64{ 1, 2, 3, 4, 5, 6 }) |seed| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fixture: Fixture = undefined;
        // A few players, and more than a word of them.
        try fixture.init(arena.allocator(), if (seed % 2 == 0) 70 else 6, 65536, seed);
        for (0..150) |_| try fixture.spawn();
        for (0..300) |_| {
            try fixture.shake();
            try fixture.tracking.tick();
            fixture.deliver(&everyone);
            try fixture.tracking.check();
        }
    }
}

test "a second pass answers what entities did against the players as first heard" {
    for ([_]u64{ 21, 22 }) |seed| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fixture: Fixture = undefined;
        try fixture.init(arena.allocator(), if (seed % 2 == 0) 70 else 6, 65536, seed);
        for (0..150) |_| try fixture.spawn();
        for (0..200) |_| {
            try fixture.shake();
            try fixture.tracking.tick();
            fixture.deliver(&everyone);
            try fixture.tracking.check();
            try fixture.stir();
            try fixture.tracking.tickEntities();
            fixture.deliver(&everyone);
            try fixture.tracking.check();
        }
    }
}

test "players creeping along their reach are answered as they go, and entities near it as they move" {
    for ([_]u64{ 41, 42 }) |seed| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fixture: Fixture = undefined;
        try fixture.init(arena.allocator(), if (seed % 2 == 0) 70 else 6, 65536, seed);
        fixture.stride = 0.5;
        fixture.sleepy = true;
        for (0..400) |_| try fixture.spawn();
        for (0..400) |_| {
            try fixture.shake();
            try fixture.sleepSome();
            try fixture.tracking.tick();
            fixture.deliver(&everyone);
            try fixture.tracking.check();
        }
        // The near entities were what was measured, most ticks.
        try std.testing.expect(fixture.tracking.stats.near_measured > fixture.tracking.stats.edge_walks);
    }
}

test "changes not accepted are offered again until they are" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator(), 6, 65536, 7);
    for (0..150) |_| try fixture.spawn();
    for (0..100) |round| {
        try fixture.shake();
        try fixture.tracking.tick();
        // Half the clients take nothing for a while, then everything.
        fixture.deliver(if (round % 10 < 6) &evens else &everyone);
        if (round % 10 == 9) {
            // Nothing changes for a tick, and what was owed goes out.
            try fixture.tracking.tick();
            fixture.deliver(&everyone);
            try fixture.tracking.check();
        }
    }
}

test "more changes than the work holds sweep everything near every player" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator(), 6, 4, 11);
    for (0..150) |_| try fixture.spawn();
    for (0..120) |_| {
        try fixture.shake();
        try fixture.tracking.tick();
        fixture.deliver(&everyone);
        try fixture.tracking.check();
    }
}

test "a gone entity keeps its slot until every client that had it was told" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator(), 2, 65536, 13);
    const id = fixture.next_id;
    fixture.next_id += 1;
    const slot = try fixture.entities.enter(id, 1);
    try fixture.entities.places.insert(id, 0, .{ 4, 64, 4 }, .{ .kind = 1, .half_width = 0.25, .height = 0.5 });
    try fixture.tracking.tick();
    fixture.deliver(&everyone);
    try std.testing.expectEqual(@as(usize, 2), fixture.tracking.known(slot).count());
    fixture.entities.places.remove(id);
    fixture.entities.leave(slot);
    // Still owed to both clients: the slot, and its network id, are nobody else's.
    try std.testing.expect(fixture.entities.directory.entry(slot).retired);
    try fixture.tracking.tick();
    var changes = fixture.tracking.changesOf(0);
    const change = changes.next().?;
    try std.testing.expect(change.gone and change.remove.count() == 2);
    // One client is told; the other is not yet.
    fixture.deliver(&evens);
    try std.testing.expect(fixture.entities.directory.entry(slot).retired);
    try fixture.tracking.tick();
    fixture.deliver(&everyone);
    try std.testing.expect(!fixture.entities.directory.entry(slot).retired);
    try fixture.tracking.check();
}

test "what entities say of themselves and who spectates are followed as the rule asks" {
    for ([_]u64{ 21, 22, 23 }) |seed| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fixture: Fixture = undefined;
        try fixture.init(arena.allocator(), if (seed % 2 == 0) 70 else 6, 65536, seed);
        for (0..150) |_| try fixture.spawn();
        for (0..300) |_| {
            try fixture.shake();
            try fixture.sayThings();
            try fixture.tracking.tick();
            fixture.deliver(&everyone);
            // What was said is looked at by the next tick: one more settles it.
            try fixture.tracking.tick();
            fixture.deliver(&everyone);
            try fixture.tracking.check();
        }
    }
}

test "entities asleep along paths are answered by their boxes, the kind asked only where unsure" {
    for ([_]u64{ 31, 32, 33, 34 }) |seed| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fixture: Fixture = undefined;
        try fixture.init(arena.allocator(), if (seed % 2 == 0) 70 else 6, 65536, seed);
        fixture.sleepy = true;
        for (0..150) |_| try fixture.spawn();
        var boxed: usize = 0;
        var unsure: usize = 0;
        for (0..300) |_| {
            try fixture.shake();
            try fixture.sleepSome();
            boxed += fixture.entities.places.space.box_count;
            unsure += fixture.tracking.unsettled.len;
            if (seed >= 33) try fixture.sayThings();
            try fixture.tracking.tick();
            fixture.deliver(&everyone);
            if (seed >= 33) {
                try fixture.tracking.tick();
                fixture.deliver(&everyone);
            }
            try fixture.tracking.check();
        }
        // Both ways of answering were asked of.
        try std.testing.expect(boxed > 300 and unsure > 0);
    }
}
