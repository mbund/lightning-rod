const std = @import("std");
const storage = @import("storage");
const records = @import("records");
const inventories = @import("inventories");
const metrics = @import("metrics");
const game_data = @import("game_data");
const Items = @import("items.zig").Items;
const RegistryIdentity = @import("registry_identity.zig").RegistryIdentity;
const BlockLoot = @import("block_loot.zig").BlockLoot;

pub fn benchmark() !void {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/mining", .{temporary.sub_path});
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
    defer registry.deinit();
    const workspaces = try records.Workspaces.init(allocator, io, .{});
    const ownership = try inventories.Inventories.init(allocator, io, .{ .cache_slots = 32, .cache_items = 8, .max_item_bytes = 1024 }, .{
        .metrics = &registry,
        .storage = try store.openSpace("inventory"),
        .record_workspaces = workspaces,
    });
    const identity = try RegistryIdentity.init(allocator, .{ .storage = try store.openSpace("registry") });
    const items = try Items.init(allocator, .{}, .{ .inventories = ownership, .registry_identity = identity });
    const loot = try BlockLoot.init(allocator);
    const Case = struct { block: []const u8, tool: []const u8, drop: []const u8, speed: f32 };
    const cases = [_]Case{
        .{ .block = "minecraft:stone", .tool = "minecraft:diamond_pickaxe", .drop = "minecraft:cobblestone", .speed = 8 },
        .{ .block = "minecraft:dirt", .tool = "minecraft:golden_shovel", .drop = "minecraft:dirt", .speed = 12 },
        .{ .block = "minecraft:coal_ore", .tool = "minecraft:netherite_pickaxe", .drop = "minecraft:coal", .speed = 9 },
        .{ .block = "minecraft:oak_log[axis=y]", .tool = "minecraft:iron_axe", .drop = "minecraft:oak_log", .speed = 6 },
        .{ .block = "minecraft:sand", .tool = "minecraft:diamond_shovel", .drop = "minecraft:sand", .speed = 8 },
        .{ .block = "minecraft:gravel", .tool = "minecraft:stone_shovel", .drop = "minecraft:gravel", .speed = 4 },
        .{ .block = "minecraft:stone", .tool = "minecraft:wooden_pickaxe", .drop = "minecraft:cobblestone", .speed = 2 },
        .{ .block = "minecraft:stone", .tool = "minecraft:stone_pickaxe", .drop = "minecraft:cobblestone", .speed = 4 },
        .{ .block = "minecraft:stone", .tool = "minecraft:iron_pickaxe", .drop = "minecraft:cobblestone", .speed = 6 },
        .{ .block = "minecraft:stone", .tool = "minecraft:golden_pickaxe", .drop = "minecraft:cobblestone", .speed = 12 },
        .{ .block = "minecraft:dirt", .tool = "minecraft:wooden_shovel", .drop = "minecraft:dirt", .speed = 2 },
        .{ .block = "minecraft:dirt", .tool = "minecraft:iron_shovel", .drop = "minecraft:dirt", .speed = 6 },
    };
    var tools: [cases.len]inventories.Stack = undefined;
    var states: [cases.len]u16 = undefined;
    for (cases, &tools, &states) |case, *tool, *state| {
        tool.* = .{ .item = try items.define(case.tool), .count = 1 };
        state.* = @intCast(game_data.registry.blockStateId(case.block).?);
    }
    var buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &buffer);
    try output.interface.writeAll("miners | progress evaluations | definition acquisitions | reference acquisitions | definition backend reads\n");
    for ([_]usize{ 1, 6, 12, 32 }) |miners| {
        var resolved: [32]BlockLoot.Tool = @splat(.{});
        for (resolved[0..miners], 0..) |*tool, index| _ = try tool.resolve(items, tools[index % cases.len]);
        const definitions = ownership.items.metrics.acquired.value();
        const references = ownership.references.metrics.acquired.value();
        const reads = ownership.items.metrics.reads.value();
        const writes = ownership.items.metrics.writes.value();
        for (0..20) |_| for (0..miners) |index| {
            const at = index % cases.len;
            const result = loot.evaluate(states[at], try resolved[index].resolve(items, tools[at]));
            try std.testing.expectEqual(cases[at].speed, result.speed);
            try std.testing.expect(result.harvest);
            try std.testing.expectEqual(@as(u32, @intCast(game_data.registry.itemId(cases[at].drop).?)), result.drop.?.kind);
            try std.testing.expectEqual(@as(u16, 1), result.drop.?.count);
        };
        const acquired = ownership.items.metrics.acquired.value() - definitions;
        const referenced = ownership.references.metrics.acquired.value() - references;
        const loaded = ownership.items.metrics.reads.value() - reads;
        try std.testing.expectEqual(0, acquired);
        try std.testing.expectEqual(0, referenced);
        try std.testing.expectEqual(0, loaded);
        try std.testing.expectEqual(writes, ownership.items.metrics.writes.value());
        try output.interface.print("{d:6} | {d:20} | {d:23} | {d:22} | {d}\n", .{ miners, 20 * miners, acquired, referenced, loaded });
    }
    const DropCase = struct { block: []const u8, drop: []const u8, count: u16 };
    for ([_]DropCase{
        .{ .block = "minecraft:clay", .drop = "minecraft:clay_ball", .count = 4 },
        .{ .block = "minecraft:bookshelf", .drop = "minecraft:book", .count = 3 },
        .{ .block = "minecraft:oak_slab[type=double,waterlogged=false]", .drop = "minecraft:oak_slab", .count = 2 },
        .{ .block = "minecraft:oak_slab[type=bottom,waterlogged=false]", .drop = "minecraft:oak_slab", .count = 1 },
    }) |case| {
        const result = loot.evaluate(@intCast(game_data.registry.blockStateId(case.block).?), &.{});
        const definitions = ownership.items.metrics.acquired.value();
        const references = ownership.references.metrics.acquired.value();
        const stack = try result.drop.?.materialize(items);
        try std.testing.expectEqual(definitions + 1, ownership.items.metrics.acquired.value());
        try std.testing.expectEqual(references + 1, ownership.references.metrics.acquired.value());
        try std.testing.expectEqual(case.count, stack.count);
        try std.testing.expectEqual(@as(u32, @intCast(game_data.registry.itemId(case.drop).?)), try items.kind(stack));
    }
    const stone = loot.evaluate(@intCast(game_data.registry.blockStateId("minecraft:stone").?), &.{});
    try std.testing.expect(!stone.harvest);
    try std.testing.expectEqual(null, stone.drop);
    var selected: BlockLoot.Tool = .{};
    const bedrock = loot.evaluate(@intCast(game_data.registry.blockStateId("minecraft:bedrock").?), try selected.resolve(items, tools[0]));
    try std.testing.expectEqual(null, bedrock.drop);
    const acquired = ownership.items.metrics.acquired.value();
    try std.testing.expectEqual(selected.kind, (try selected.resolve(items, .{ .item = tools[0].item, .count = 2 })).kind);
    try std.testing.expectEqual(acquired, ownership.items.metrics.acquired.value());
    try std.testing.expectEqual(@as(u32, @intCast(game_data.registry.itemId(cases[1].tool).?)), (try selected.resolve(items, tools[1])).kind.?);
    try std.testing.expectEqual(acquired + 1, ownership.items.metrics.acquired.value());
    try std.testing.expectEqual(null, (try selected.resolve(items, null)).kind);
    try std.testing.expectEqual(null, selected.item);
    _ = try selected.resolve(items, tools[1]);
    try std.testing.expectEqual(acquired + 2, ownership.items.metrics.acquired.value());
    try output.interface.flush();
}
