const vanilla_content = @import("vanilla_content.zig");
const std = @import("std");
const chunks = @import("chunks");
const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const worlds = @import("worlds");
const game_data = @import("game_data");
const lighting = @import("lighting.zig");
const Scene = @import("lighting_load.zig").Scene;

const Mode = enum { cold, unrelated, other_world, local };
const passes_max = 18;

const Source = struct {
    fn read(_: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
        for (batch.requests) |*request| request.result = chunks.uniform(0, request.output);
    }
};

test "lighting pipeline makes progress under sustained edits" {
    const io = std.testing.io;
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &buffer);
    try output.interface.writeAll("Lighting pipeline, deterministic operation counts\nworkload       passes  complete  acquired  reads\n");
    for (std.enums.values(Mode)) |mode| {
        var directory = std.testing.tmpDir(.{});
        defer directory.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/lighting", .{directory.sub_path});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const allocator = bounded.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 64 });
        defer registry.deinit();
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        const resources = try records.Workspaces.init(allocator, io, .{});
        const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 4, .demand_sections = 1 }, .{ .metrics = &registry, .storage = try store.openSpace("terrain"), .record_workspaces = resources });
        const workspace = try lighting.Workspace.init(allocator, terrain, try game_data.lighting.init(allocator));
        var source: Source = .{};
        terrain.setSource(chunks.Source.init(&source, Source.read));
        bounded.fail_index = bounded.alloc_index;
        const dimension: worlds.Worlds.Dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 1 };
        const emitter: u16 = @intCast(game_data.registry.block_glowstone_default_state);
        const before_acquired = terrain.cache.metrics.acquired.value();
        const before_reads = terrain.cache.metrics.reads.value();
        var complete = false;
        var passes: usize = 0;
        while (passes < passes_max and !complete) {
            passes += 1;
            if (mode != .cold) {
                const noise: chunks.Position = .{ .x = if (mode == .local) 8 else 16000, .y = 8, .z = if (mode == .local) 8 else 16000 };
                try terrain.setBlock(if (mode == .other_world) 1 else 0, noise, if (passes % 2 == 0) 0 else emitter);
            }
            complete = try workspace.prepare(terrain, 0, 0, 0, dimension, 0);
            try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
            while (try terrain.generation.processOne(io)) {}
            try terrain.poll();
        }
        try output.interface.print("{s:<14} {d:>6} {s:>9} {d:>9} {d:>6}\n", .{ @tagName(mode), passes, if (complete) "yes" else "no", terrain.cache.metrics.acquired.value() - before_acquired, terrain.cache.metrics.reads.value() - before_reads });
        try output.interface.flush();
        try std.testing.expect(complete);
        const center = workspace.engine.dimensions.x / 2;
        const index = (24 * workspace.engine.dimensions.z + center) * workspace.engine.dimensions.x + center;
        try std.testing.expectEqual(@as(u4, if (mode == .local and passes % 2 != 0) 15 else 0), workspace.engine.get(.block, index));
    }
}

test "lighting pipeline retains overlapping neighborhoods in every direction" {
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/walking", .{directory.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = bounded.allocator();
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 64 });
    defer registry.deinit();
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    const resources = try records.Workspaces.init(allocator, io, .{});
    const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 48, .demand_sections = 24 }, .{ .metrics = &registry, .storage = try store.openSpace("terrain"), .record_workspaces = resources });
    const workspace = try lighting.Workspace.init(allocator, terrain, try game_data.lighting.init(allocator));
    var source: Scene = .{};
    terrain.setSource(chunks.Source.init(&source, Scene.read));
    const dimension: worlds.Worlds.Dimension = .{ .name = "test:dimension", .minimum_section = 4, .section_count = 1, .skylight = true };
    const Position = struct { x: i32, z: i32, retained: usize };
    const path_positions = [_]Position{
        .{ .x = 0, .z = 0, .retained = 0 },
        .{ .x = 1, .z = 0, .retained = 6 },
        .{ .x = 1, .z = 1, .retained = 6 },
        .{ .x = 0, .z = 1, .retained = 6 },
        .{ .x = 0, .z = 0, .retained = 6 },
        .{ .x = -1, .z = -1, .retained = 4 },
        .{ .x = 0, .z = 0, .retained = 4 },
        .{ .x = 5, .z = 5, .retained = 0 },
    };
    var buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &buffer);
    try output.interface.writeAll("Walking neighborhoods: x z retained decoded_sections\n");
    bounded.fail_index = bounded.alloc_index;
    for (path_positions) |position| {
        const before = workspace.work;
        var complete = false;
        for (0..18) |_| {
            complete = try workspace.prepare(terrain, 0, position.x, position.z, dimension, 0);
            if (complete) break;
            while (try terrain.generation.processOne(io)) {}
            try terrain.poll();
        }
        try std.testing.expect(complete);
        const retained = workspace.work.retained_columns - before.retained_columns;
        const decoded = workspace.work.decoded_sections - before.decoded_sections;
        try std.testing.expectEqual(position.retained, retained);
        try std.testing.expectEqual(9 - position.retained, decoded);
        for (0..9) |column| for (0..4096) |local| {
            const section: chunks.Section = .{ .world = 0, .x = position.x + @as(i32, @intCast(column % 3)) - 1, .y = 4, .z = position.z + @as(i32, @intCast(column / 3)) - 1 };
            const x = column % 3 * 16 + local % 16;
            const z = column / 3 * 16 + local / 16 % 16;
            const y = 16 + local / 256;
            const index = (y * 48 + z) * 48 + x;
            try std.testing.expectEqual(Scene.state(section, local), workspace.engine.blockState(index));
        };
        try output.interface.print("{d:>3} {d:>3} {d:>8} {d:>16}\n", .{ position.x, position.z, retained, decoded });
    }
    try output.interface.flush();
}

test "lighting pipeline simulation queries group points and reuse cached light" {
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/queries", .{directory.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = bounded.allocator();
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
    defer registry.deinit();
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    const resources = try records.Workspaces.init(allocator, io, .{});
    const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 48, .demand_sections = 24 }, .{ .metrics = &registry, .storage = try store.openSpace("terrain"), .record_workspaces = resources });
    const dimensions = try worlds.Worlds.allocate(allocator, .{});
    const world = try dimensions.create(.{ .name = "test:queries", .dimension = .{ .name = "test:dimension", .minimum_section = -4, .section_count = 24, .skylight = true } });
    const service = try lighting.Lighting.init(allocator, .{}, .{ .blocks = try vanilla_content.blocks(allocator), .chunks = terrain, .worlds = dimensions });
    var source: Scene = .{};
    terrain.setSource(chunks.Source.init(&source, Scene.read));
    const positions: [256]chunks.Position = @splat(.{ .x = 17, .y = 66, .z = 2 });
    var samples: [positions.len]lighting.Sample = undefined;
    var buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &buffer);
    try output.interface.writeAll("Simulation queries: points CPU_us decoded_sections cache_hits cache_misses\n");
    bounded.fail_index = bounded.alloc_index;
    const start = std.Io.Clock.now(.cpu_thread, io).nanoseconds;
    try service.sampleMany(world, positions[0..1], samples[0..1]);
    const elapsed = std.Io.Clock.now(.cpu_thread, io).nanoseconds - start;
    try output.interface.print("cold: 1 {d:.2} {d} {d} {d}\n", .{ @as(f64, @floatFromInt(elapsed)) / 1000, service.simulation.work.decoded_sections, service.cache_hits, service.cache_misses });
    try std.testing.expectEqual(@as(u64, 9 * 24), service.simulation.work.decoded_sections);
    const initial = samples[0];
    for ([_]usize{ 1, 16, 256 }) |count| {
        var timings: [32]u64 = undefined;
        for (&timings) |*timing| {
            const before = std.Io.Clock.now(.cpu_thread, io).nanoseconds;
            try service.sampleMany(world, positions[0..count], samples[0..count]);
            timing.* = @intCast(std.Io.Clock.now(.cpu_thread, io).nanoseconds - before);
            for (samples[0..count]) |sample| try std.testing.expectEqual(initial, sample);
        }
        std.mem.sort(u64, &timings, {}, std.sort.asc(u64));
        try output.interface.print("warm: {d} {d:.2} {d} {d} {d}\n", .{ count, @as(f64, @floatFromInt(timings[timings.len / 2])) / 1000, service.simulation.work.decoded_sections, service.cache_hits, service.cache_misses });
    }
    try std.testing.expectEqual(@as(u64, 1), service.cache_misses);
    try std.testing.expectEqual(@as(u64, 96), service.cache_hits);
    try std.testing.expectEqual(@as(u64, 9 * 24), service.simulation.work.decoded_sections);
    try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
    try output.interface.flush();
}
