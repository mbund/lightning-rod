const std = @import("std");
const chunks = @import("chunks");
const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const Worlds = @import("worlds").Worlds;
const Players = @import("players").players.Players;
const Domains = @import("domains").domains.Domains;
const RandomTicks = @import("random_ticks.zig").RandomTicks;
const Hit = @import("random_ticks.zig").Hit;

/// Section 0 of every column ticks on its even cells, section 1 is empty.
const Source = struct {
    fn read(_: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
        for (batch.requests) |*request| {
            if (request.section.y != 0) {
                request.result = chunks.uniform(0, request.output);
                continue;
            }
            request.output[0] = 1;
            for (0..4096) |index| std.mem.writeInt(u16, request.output[1 + index * 2 ..][0..2], @intFromBool(index % 2 == 0), .little);
            request.result = chunks.encoding.dense_block_bytes;
        }
    }
};

const Counter = struct {
    hits: usize = 0,
    misplaced: usize = 0,
    /// Section 1 of the centre column may act once an edit gives it work.
    upper_allowed: bool = false,
    upper: usize = 0,

    fn run(self: *Counter, hit: Hit) !void {
        self.hits += 1;
        const cell = chunks.localIndex(hit.position);
        if (hit.position.y >= 16) self.upper += 1;
        const upper_ok = hit.position.y < 16 or (self.upper_allowed and hit.position.x >= 0 and hit.position.x < 16 and hit.position.z >= 0 and hit.position.z < 16);
        if (hit.state != 1 or cell % 2 != 0 or !upper_ok or hit.position.x < -16 or hit.position.x >= 32) self.misplaced += 1;
    }
};

test "hits land on tickable cells at vanilla's rate, follow edits and read counts from the store" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path: [256]u8 = undefined;
    var store = try storage.Store.init(allocator, io, .{ .path = try std.fmt.bufPrint(&path, ".zig-cache/tmp/{s}/random-ticks", .{directory.sub_path}) });
    defer store.deinit();
    var registry = try metrics.Registry.init(allocator, io, .{ .enabled = false });
    defer registry.deinit();
    const space = try store.openSpace(chunks.Chunks.id);
    const terrain = try chunks.Chunks.init(arena.allocator(), io, .{ .edit_sections = 1, .simulation_sections = 27, .cache_sections = 40 }, .{
        .metrics = &registry,
        .storage = space,
        .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}),
    });
    var source: Source = .{};
    terrain.setSource(chunks.Source.init(&source, Source.read));
    const catalog = try Worlds.allocate(arena.allocator(), .{ .maximum = 1 });
    const world = try catalog.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 2 } });
    var player_records = [_]Players.Player{.{ .handle = .{ .index = 0, .generation = 1 }, .world = world, .position = .{ .x = 8, .y = 4, .z = 8 } }};
    var player_plugin: Players = .{ .deps = undefined, .config = .{ .render_distance = 2, .simulation_distance = 1 }, .spawn_world = world, .records = &player_records, .dig_handlers = &.{} };
    const domains = try Domains.init(arena.allocator(), .{}, .{ .players = &player_plugin });
    const handlers = try RandomTicks.Registry.init(arena.allocator(), .{ .states = 16 });
    const tickable = try handlers.addSet();
    handlers.include(tickable, 1);
    var counter: Counter = .{};
    try handlers.register(.{ .selected = tickable }, .init(Counter, &counter, Counter.run));
    const random = try RandomTicks.init(arena.allocator(), .{}, .{ .domains = domains, .chunks = terrain, .worlds = catalog, .registry = handlers });
    try std.testing.expectError(error.RandomTicksStarted, handlers.register(.{ .selected = tickable }, .init(Counter, &counter, Counter.run)));
    terrain.attach();
    defer terrain.stop();

    // The ticking columns are written, so their counts come from records rather than memory.
    const reader = try terrain.client(.{ .name = "test", .sections = 2 });
    for (0..3) |x| for (0..3) |z| for (0..2) |y| {
        const lease = try reader.acquire(.{ .world = world, .x = @as(i32, @intCast(x)) - 1, .z = @as(i32, @intCast(z)) - 1, .y = @intCast(y) });
        lease.release();
    };
    try terrain.checkpoint(space);

    const ticks = 2000;
    for (0..ticks) |_| {
        domains.tick();
        try terrain.poll();
        try random.tick();
    }
    // Nine columns of 2048 tickable cells, three picks of 4096 cells a tick.
    const expected: f64 = ticks * 9 * 2048 * 3.0 / 4096.0;
    const deviation = @sqrt(expected);
    const hits: f64 = @floatFromInt(counter.hits);
    try std.testing.expect(@abs(hits - expected) < 6 * deviation + 9 * 3 * 2);
    try std.testing.expectEqual(@as(usize, 0), counter.misplaced);

    // Clearing the centre column's section stops its hits at once. Its count is taken again on
    // the simulation thread, so terrain, which answers topology requests, is not polled.
    var edits: [2048]chunks.BlockEdit = undefined;
    for (&edits, 0..) |*edit, index| edit.* = .{ .index = @intCast(index * 2), .state = 0 };
    try terrain.setBlocks(.{ .world = world, .x = 0, .y = 0, .z = 0 }, &edits);
    const before = counter.hits;
    for (0..ticks) |_| {
        domains.tick();
        try random.tick();
    }
    const after: f64 = @floatFromInt(counter.hits - before);
    const remaining = expected * 8 / 9;
    try std.testing.expect(@abs(after - remaining) < 6 * @sqrt(remaining) + 8 * 3 * 2);
    try std.testing.expectEqual(@as(usize, 0), counter.misplaced);

    // Giving the empty section above work makes it act from the next tick, still with terrain
    // silent: it had no acting cells, so only a count taken on this thread finds them.
    counter.upper_allowed = true;
    for (&edits) |*edit| edit.state = 1;
    try terrain.setBlocks(.{ .world = world, .x = 0, .y = 1, .z = 0 }, &edits);
    for (0..ticks) |_| {
        domains.tick();
        try random.tick();
    }
    const upper_expected: f64 = ticks * 2048 * 3.0 / 4096.0;
    const upper: f64 = @floatFromInt(counter.upper);
    try std.testing.expect(@abs(upper - upper_expected) < 6 * @sqrt(upper_expected) + 3 * 2);
    try std.testing.expectEqual(@as(usize, 0), counter.misplaced);
}

const Marked = struct {
    hits: usize = 0,
    misplaced: usize = 0,

    fn run(self: *Marked, hit: Hit) !void {
        self.hits += 1;
        // Only cells under a marker act, and the blocks around the hit read as stored.
        const above = hit.blocks.get(.{ .x = hit.position.x, .y = hit.position.y + 1, .z = hit.position.z });
        if (hit.state != 1 or above != 2 or hit.position.y != 3 or hit.position.z != 0) self.misplaced += 1;
    }
};

test "rules that read around a cell wake only the cells an edit gives work, and save what they found" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path: [256]u8 = undefined;
    var store = try storage.Store.init(allocator, io, .{ .path = try std.fmt.bufPrint(&path, ".zig-cache/tmp/{s}/random-ticks-layers", .{directory.sub_path}) });
    defer store.deinit();
    var registry = try metrics.Registry.init(allocator, io, .{ .enabled = false });
    defer registry.deinit();
    const space = try store.openSpace(chunks.Chunks.id);
    const terrain = try chunks.Chunks.init(arena.allocator(), io, .{ .edit_sections = 1, .simulation_sections = 27, .cache_sections = 40 }, .{
        .metrics = &registry,
        .storage = space,
        .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}),
    });
    var source: Source = .{};
    terrain.setSource(chunks.Source.init(&source, Source.read));
    const catalog = try Worlds.allocate(arena.allocator(), .{ .maximum = 1 });
    const world = try catalog.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 2 } });
    var player_records = [_]Players.Player{.{ .handle = .{ .index = 0, .generation = 1 }, .world = world, .position = .{ .x = 8, .y = 4, .z = 8 } }};
    var player_plugin: Players = .{ .deps = undefined, .config = .{ .render_distance = 2, .simulation_distance = 1 }, .spawn_world = world, .records = &player_records, .dig_handlers = &.{} };
    const domains = try Domains.init(arena.allocator(), .{}, .{ .players = &player_plugin });
    const handlers = try RandomTicks.Registry.init(arena.allocator(), .{ .states = 16 });
    const tickable = try handlers.addSet();
    const marker = try handlers.addSet();
    handlers.include(tickable, 1);
    handlers.include(marker, 2);
    var marked: Marked = .{};
    try handlers.register(.{ .selected = tickable, .nodes = &.{ .{ .set = marker }, .{ .offset = .{ .of = 0, .by = .{ 0, 1, 0 } } } } }, .init(Marked, &marked, Marked.run));
    const random = try RandomTicks.init(arena.allocator(), .{ .speed = 255 }, .{ .domains = domains, .chunks = terrain, .worlds = catalog, .registry = handlers });
    terrain.attach();
    defer terrain.stop();
    const reader = try terrain.client(.{ .name = "test", .sections = 2 });
    for (0..3) |x| for (0..3) |z| for (0..2) |y| {
        const lease = try reader.acquire(.{ .world = world, .x = @as(i32, @intCast(x)) - 1, .z = @as(i32, @intCast(z)) - 1, .y = @intCast(y) });
        lease.release();
    };
    try terrain.checkpoint(space);
    for (0..200) |_| {
        domains.tick();
        try terrain.poll();
        try random.tick();
    }
    // No cell has a marker above it, so nothing acts in a world full of tickable cells.
    try std.testing.expectEqual(@as(usize, 0), marked.hits);

    // Markers on eight cells give the eight below them work, and only those.
    var edits: [8]chunks.BlockEdit = undefined;
    for (&edits, 0..) |*edit, index| edit.* = .{ .index = @intCast(4 * 256 + index * 2), .state = 2 };
    try terrain.setBlocks(.{ .world = world, .x = 0, .y = 0, .z = 0 }, &edits);
    for (0..400) |_| {
        domains.tick();
        try terrain.poll();
        try random.tick();
    }
    // Eight cells at 255 picks of 4096 a tick for about 400 ticks.
    try std.testing.expect(marked.hits > 100 and marked.hits < 300);
    try std.testing.expectEqual(@as(usize, 0), marked.misplaced);

    // Columns nothing edited were counted from clean blocks, and their counts were saved.
    var bytes: [chunks.topology.record_max]u8 = undefined;
    var values: [1]?[]const u8 = undefined;
    var complete: [1]bool = undefined;
    var read: records.PackedRead = .{ .bytes = &bytes, .values = &values, .complete = &complete };
    terrain.cache.backend.store.columnRecords(.layer, &.{.{ .world = world, .x = 1, .z = 1 }}, &read);
    try std.testing.expect(values[0] != null);
}
