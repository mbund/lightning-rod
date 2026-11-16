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
const Terrain = @import("path_terrain.zig").Terrain;

/// Vanilla's paths on random terrain, printed by running vanilla 1.21.8's WalkNodeEvaluator and
/// PathFinder for a cow on the same terrain, which the Java and Zig sides generate alike from a
/// java.util.Random of the scenario's seed. Each scenario lists the path's nodes, or none.
const golden_paths = @embedFile("testdata/paths.txt");

test "paths follow vanilla on random terrain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const deps = try defaults.prepare(allocator);
    const blocks = try mob_blocks.MobBlocks.init(allocator, deps.blocks);
    var terrain = try Terrain.init(allocator);
    var search = try pathfinding.Search.init(allocator, 16384);
    const output = try allocator.alloc(pathfinding.PathNode, 512);
    var lines = std.mem.tokenizeScalar(u8, golden_paths, '\n');
    var scenarios: usize = 0;
    while (lines.next()) |header| {
        var fields = std.mem.tokenizeScalar(u8, header, ' ');
        const seed = try std.fmt.parseInt(i64, fields.next().?, 10);
        const outcome = fields.next().?;
        const count = try std.fmt.parseInt(usize, fields.next().?, 10);
        const scenario = terrain.generate(seed);
        const level = terrain.level(blocks);
        const found = try search.findPath(&level, &scenario.mob, scenario.request, output);
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

/// Vanilla's collision shape classes, printed by ShapeOracle.java: each state's class numbered as
/// first seen, in runs written class*count.
const golden_shape_classes = @embedFile("testdata/shape_classes.txt");

test "collision shape classes follow vanilla for every block state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const deps = try defaults.prepare(allocator);
    const blocks = try mob_blocks.MobBlocks.init(allocator, deps.blocks);
    const states = game_data.registry.block_state_names.len;
    const vanilla = try allocator.alloc(u32, states);
    var filled: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, golden_shape_classes, " \n");
    while (tokens.next()) |token| {
        const star = std.mem.indexOfScalar(u8, token, '*');
        const class = try std.fmt.parseInt(u32, token[0 .. star orelse token.len], 10);
        const count = if (star) |at| try std.fmt.parseInt(usize, token[at + 1 ..], 10) else 1;
        @memset(vanilla[filled..][0..count], class);
        filled += count;
    }
    try std.testing.expectEqual(states, filled);
    // The two partitions match when each class of one maps to exactly one class of the other.
    var to_port: std.AutoHashMapUnmanaged(u32, u16) = .empty;
    var to_vanilla: std.AutoHashMapUnmanaged(u16, u32) = .empty;
    var differences: usize = 0;
    for (vanilla, 0..) |class, index| {
        const state: u16 = @intCast(index);
        const ported = blocks.get(state).collision;
        const forward = try to_port.getOrPutValue(allocator, class, ported);
        const backward = try to_vanilla.getOrPutValue(allocator, ported, class);
        if (forward.value_ptr.* == ported and backward.value_ptr.* == class) continue;
        if (differences < 8) std.debug.print("{s}: vanilla class {d}, port class {d}\n", .{ game_data.registry.blockStateName(state).?, class, ported });
        differences += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), differences);
}
