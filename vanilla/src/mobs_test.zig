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
