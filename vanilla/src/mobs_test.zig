const std = @import("std");
const game_data = @import("game_data");
const defaults = @import("vanilla_definitions").defaults;
const loot = @import("vanilla_items").loot;
const mob_blocks = @import("vanilla_mobs").mob_blocks;

test "path types follow vanilla for every block state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deps = try defaults.prepare(arena.allocator());
    const blocks = try mob_blocks.MobBlocks.init(arena.allocator(), deps.blocks);
    var differences: usize = 0;
    for (0..game_data.registry.block_state_names.len) |index| {
        const state: u16 = @intCast(index);
        const vanilla = game_data.physics.mobState(state).vanilla_path_type;
        const ported: u8 = @backingInt(blocks.get(state).path);
        if (vanilla == ported) continue;
        if (differences < 8) std.debug.print("{s}: vanilla {d}, port {d}\n", .{ game_data.registry.blockStateName(state).?, vanilla, ported });
        differences += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), differences);
}

test "cows drop beef and leather, cooked when they burn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deps = try defaults.prepare(arena.allocator());
    const table = deps.loot.tables.get("minecraft:entities/cow") orelse return error.MissingCowLoot;
    const beef: u32 = @intCast(game_data.registry.itemId("minecraft:beef").?);
    const cooked: u32 = @intCast(game_data.registry.itemId("minecraft:cooked_beef").?);
    const leather: u32 = @intCast(game_data.registry.itemId("minecraft:leather").?);
    const Furnace = struct {
        fn smelt(context: *const anyopaque, kind: u32) ?loot.Smelted {
            const furnaces: *const @TypeOf(deps.furnaces.*) = @ptrCast(@alignCast(context));
            const recipe = furnaces.table.recipes[kind] orelse return null;
            return .{ .kind = recipe.output, .count = recipe.count };
        }
    };
    var scratch = std.heap.FixedBufferAllocator.init(try arena.allocator().alloc(u8, 16 * 1024));
    var prng = std.Random.DefaultPrng.init(1);
    for ([_]bool{ false, true }) |burning| {
        var beef_seen: [4]bool = @splat(false);
        var leather_seen: [3]bool = @splat(false);
        for (0..400) |_| {
            scratch.reset();
            var buffer: [loot.maximum_drops]loot.Drop = undefined;
            const drops = try table.evaluate(&.{
                .items = deps.items,
                .on_fire = burning,
                .smelter = .{ .context = deps.furnaces, .smelt = Furnace.smelt },
                .random = prng.random(),
                .scratch = &scratch,
            }, &buffer);
            for (drops) |drop| {
                if (drop.kind == leather) {
                    leather_seen[@intCast(drop.count)] = true;
                } else if (drop.kind == (if (burning) cooked else beef)) {
                    beef_seen[@intCast(drop.count)] = true;
                } else return error.UnexpectedDrop;
            }
        }
        // Beef comes one to three at a time, leather none to two, and an empty stack is no drop.
        try std.testing.expect(beef_seen[1] and beef_seen[2] and beef_seen[3]);
        try std.testing.expect(leather_seen[1] and leather_seen[2]);
    }
}

const pathfinding = @import("vanilla_mobs").pathfinding;
const body = @import("vanilla_mobs").body;
const JavaRandom = @import("vanilla_mobs").java_random.JavaRandom;

/// Vanilla's paths on random terrain, printed by running vanilla 1.21.8's WalkNodeEvaluator and
/// PathFinder for a cow on the same terrain, which the Java and Zig sides generate alike from a
/// java.util.Random of the scenario's seed. Each scenario lists the path's nodes, or none.
const golden_paths = @embedFile("testdata/paths.txt");
const golden_palette = @embedFile("testdata/path_palette.txt");

test "paths follow vanilla on random terrain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const deps = try defaults.prepare(allocator);
    const blocks = try mob_blocks.MobBlocks.init(allocator, deps.blocks);
    var palette: std.ArrayList(u16) = .empty;
    var names = std.mem.tokenizeScalar(u8, golden_palette, '\n');
    while (names.next()) |name| try palette.append(allocator, @intCast(game_data.registry.blockStateId(name) orelse return error.UnknownState));
    const size_x = 24;
    const size_y = 12;
    const size_z = 24;
    const states = try allocator.alloc(u16, size_x * size_y * size_z);
    const air: u16 = @intCast(game_data.registry.blockStateId("minecraft:air").?);
    const stone: u16 = @intCast(game_data.registry.blockStateId("minecraft:stone").?);
    const grass: u16 = @intCast(game_data.registry.blockStateId("minecraft:grass_block[snowy=false]").?);
    var search = try pathfinding.Search.init(allocator, 16384);
    const output = try allocator.alloc(pathfinding.PathNode, 512);
    var lines = std.mem.tokenizeScalar(u8, golden_paths, '\n');
    var scenarios: usize = 0;
    while (lines.next()) |header| {
        var fields = std.mem.tokenizeScalar(u8, header, ' ');
        const seed = try std.fmt.parseInt(i64, fields.next().?, 10);
        const outcome = fields.next().?;
        const count = try std.fmt.parseInt(usize, fields.next().?, 10);
        // The generator, as PathOracle.java has it.
        var random = JavaRandom.init(seed);
        @memset(states, air);
        var heights: [size_z][size_x]i32 = undefined;
        for (0..size_z) |z| for (0..size_x) |x| {
            const height = 3 + random.nextIntBounded(3);
            heights[z][x] = height;
            var y: i32 = 0;
            while (y < height) : (y += 1) states[(@as(usize, @intCast(y)) * size_z + z) * size_x + x] = if (y == height - 1) grass else stone;
            y = height;
            while (y < height + 2) : (y += 1) {
                if (random.nextIntBounded(5) == 0) states[(@as(usize, @intCast(y)) * size_z + z) * size_x + x] = palette.items[@intCast(random.nextIntBounded(@intCast(palette.items.len)))];
            }
        };
        const start_x = 6 + random.nextIntBounded(12);
        const start_z = 6 + random.nextIntBounded(12);
        const target_x = random.nextIntBounded(size_x);
        const target_z = random.nextIntBounded(size_z);
        const baby = random.nextIntBounded(2) == 0;
        const volume: body.Volume = .{ .size = .{ size_x, size_y, size_z }, .states = states };
        const level: body.Level = .{ .copies = null, .volume = &volume, .blocks = blocks, .world = 0, .minimum_y = 0, .height = 256, .air = air };
        var mob: pathfinding.Mob = .{
            .width = if (baby) 0.45 else 0.9,
            .height = if (baby) 0.7 else 1.4,
            .max_up_step = 0.6,
            .position = .{ @as(f64, @floatFromInt(start_x)) + 0.5, @floatFromInt(heights[@intCast(start_z)][@intCast(start_x)]), @as(f64, @floatFromInt(start_z)) + 0.5 },
            .on_ground = true,
            .in_water = false,
            .can_float = true,
        };
        mob.malus[@backingInt(mob_blocks.PathType.danger_fire)] = 16.0;
        mob.malus[@backingInt(mob_blocks.PathType.damage_fire)] = -1.0;
        const found = try search.findPath(&level, &mob, .{
            .target = .{ target_x, heights[@intCast(target_z)][@intCast(target_x)], target_z },
            .max_range = 16.0,
            .accuracy = 1,
            .max_visited_nodes = 256,
        }, output);
        if (std.mem.eql(u8, outcome, "none")) {
            try std.testing.expect(found == null);
        } else {
            const path = found orelse return error.MissingPath;
            errdefer {
                std.debug.print("seed {d}: vanilla {s} with {d} nodes, port {s} with {d}\n", .{ seed, outcome, count, if (path.reached) "reached" else "unreached", path.count });
                for (path.nodes) |node| std.debug.print("  port {d} {d} {d} {d}\n", .{ node.x, node.y, node.z, @backingInt(node.type) });
            }
            try std.testing.expectEqual(std.mem.eql(u8, outcome, "reached"), path.reached);
            try std.testing.expectEqual(count, path.count);
        }
        for (0..count) |index| {
            var node_fields = std.mem.tokenizeScalar(u8, lines.next().?, ' ');
            const node = found.?.nodes[index];
            const expected: [4]i32 = .{
                try std.fmt.parseInt(i32, node_fields.next().?, 10),
                try std.fmt.parseInt(i32, node_fields.next().?, 10),
                try std.fmt.parseInt(i32, node_fields.next().?, 10),
                try std.fmt.parseInt(i32, node_fields.next().?, 10),
            };
            errdefer std.debug.print("seed {d} node {d}: vanilla {any}, port {d} {d} {d} {d}\n", .{ seed, index, expected, node.x, node.y, node.z, @backingInt(node.type) });
            try std.testing.expectEqual(expected, [4]i32{ node.x, node.y, node.z, @backingInt(node.type) });
        }
        scenarios += 1;
    }
    try std.testing.expectEqual(@as(usize, 1000), scenarios);
}
