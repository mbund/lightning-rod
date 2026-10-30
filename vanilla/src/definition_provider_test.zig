const vanilla_content = @import("vanilla_content.zig");
const std = @import("std");
const game_data = @import("game_data");
const loot = @import("loot.zig");
const Enchantments = @import("enchantments.zig").Enchantments;
const item_data = @import("item_data.zig");

const provider = @import("definition_provider.zig");
test "vanilla content initializes from native definitions without a datapack loader" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content = try vanilla_content.prepare(arena.allocator());
    try std.testing.expect(content.book.table.book.len > 100);
    try std.testing.expect(content.items.tags.find("minecraft:logs") != null);
    try std.testing.expectEqual(@as(u16, 24), (try content.dimensions.dimension("minecraft:overworld")).section_count);
    const stone: u16 = @intCast(game_data.registry.blockStateId("minecraft:stone").?);
    try std.testing.expect(content.loot.tables.blocks[game_data.registry.block_state_to_block[stone]] != null);
    try std.testing.expect(content.enchantments.effects.values.len > 0);
    try std.testing.expect(content.book.unlocks.rules.len > 100);
}

test "native contributions preserve source order and resolve current tag membership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const content = try vanilla_content.prepare(allocator);
    const source = try provider.register(content, allocator, .{
        .tags = &.{.{ .registry = "minecraft:item", .name = "test:ingredients", .values = &.{.{ .id = "minecraft:paper" }} }},
        .recipes = &.{.{ .name = "test:craft", .definition = .{ .shapeless = .{ .ingredients = &.{.{ .tag = "test:ingredients" }}, .result = .{ .item = "minecraft:diamond" } } } }},
    }, null);
    const paper: u32 = @intCast(game_data.registry.itemId("minecraft:paper").?);
    const emerald: u32 = @intCast(game_data.registry.itemId("minecraft:emerald").?);
    try std.testing.expect(content.items.tags.contains(content.items.tags.find("test:ingredients").?, paper));
    _ = try provider.register(content, allocator, .{ .tags = &.{.{ .registry = "minecraft:item", .name = "test:ingredients", .replace = true, .values = &.{.{ .id = "minecraft:emerald" }} }} }, null);
    _ = try provider.register(content, allocator, .{
        .tags = &.{.{ .registry = "minecraft:item", .name = "test:ingredients", .values = &.{.{ .id = "minecraft:diamond" }} }},
        .recipes = &.{.{ .name = "test:craft", .definition = .{ .shapeless = .{ .ingredients = &.{.{ .tag = "test:ingredients" }}, .result = .{ .item = "minecraft:diamond" } } } }},
    }, source);
    const tag = content.items.tags.find("test:ingredients").?;
    try std.testing.expect(!content.items.tags.contains(tag, paper));
    try std.testing.expect(content.items.tags.contains(tag, emerald));
    try std.testing.expect(content.crafting.table.matches(&.{ emerald, null, null, null }, 2) != null);
    try std.testing.expect(content.crafting.table.matches(&.{ paper, null, null, null }, 2) == null);
    try std.testing.expectError(error.InvalidDimension, provider.register(content, allocator, .{ .dimension_types = &.{.{ .name = "test:invalid", .definition = .{ .height = 17 } }} }, null));
    try std.testing.expect(content.items.tags.contains(content.items.tags.find("test:ingredients").?, emerald));
}

test "vanilla block loot uses state conditions silk touch and random count functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const content = try vanilla_content.prepare(allocator);
    const tables = content.loot.tables;
    const Case = struct { block: []const u8, output: []const u8, minimum: u16 = 1, maximum: u16 = 1, silk: bool = false, fortune: u32 = 0 };
    for ([_]Case{
        .{ .block = "minecraft:stone", .output = "minecraft:cobblestone" },
        .{ .block = "minecraft:stone", .output = "minecraft:stone", .silk = true },
        .{ .block = "minecraft:clay", .output = "minecraft:clay_ball", .minimum = 4, .maximum = 4 },
        .{ .block = "minecraft:clay", .output = "minecraft:clay", .silk = true },
        .{ .block = "minecraft:bookshelf", .output = "minecraft:book", .minimum = 3, .maximum = 3 },
        .{ .block = "minecraft:oak_slab[type=double,waterlogged=false]", .output = "minecraft:oak_slab", .minimum = 2, .maximum = 2 },
        .{ .block = "minecraft:diamond_ore", .output = "minecraft:diamond", .maximum = 4, .fortune = 3 },
        .{ .block = "minecraft:lapis_ore", .output = "minecraft:lapis_lazuli", .minimum = 4, .maximum = 9 },
        .{ .block = "minecraft:nether_gold_ore", .output = "minecraft:gold_nugget", .minimum = 2, .maximum = 6 },
        .{ .block = "minecraft:sculk", .output = "minecraft:sculk", .silk = true },
    }) |case| {
        var random: std.Random.DefaultPrng = .init(7);
        var enchantment_bytes: [128]u8 = undefined;
        var enchantments: [1]Enchantments.Entry = .{.{ .name = if (case.silk) "minecraft:silk_touch" else "minecraft:fortune", .level = if (case.silk) 1 else case.fortune }};
        const enchantment_data = try Enchantments.encode(&enchantments, &enchantment_bytes);
        var tool_bytes: [256]u8 = undefined;
        @memcpy(tool_bytes[0..4], "LRI2");
        std.mem.writeInt(u32, tool_bytes[4..8], @intCast(game_data.registry.itemId("minecraft:diamond_pickaxe").?), .little);
        std.mem.writeInt(u16, tool_bytes[8..10], 1, .little);
        std.mem.writeInt(u64, tool_bytes[10..18], item_data.key(.enchantments), .little);
        std.mem.writeInt(u32, tool_bytes[18..22], @intCast(enchantment_data.len), .little);
        @memcpy(tool_bytes[22..][0..enchantment_data.len], enchantment_data);
        const view = try item_data.View.parse(tool_bytes[0 .. 22 + enchantment_data.len]);
        const state_id: u16 = @intCast(game_data.registry.blockStateId(case.block).?);
        const table = tables.blocks[game_data.registry.block_state_to_block[state_id]].?;
        var maximum_seen: u16 = 0;
        for (0..64) |_| {
            var buffer: [16384]u8 = undefined;
            var scratch: std.heap.FixedBufferAllocator = .init(&buffer);
            var output: [loot.maximum_drops]loot.Drop = undefined;
            const drops = try table.evaluate(&.{ .items = content.items, .state = state_id, .tool = view, .random = random.random(), .scratch = &scratch }, &output);
            try std.testing.expectEqual(@as(usize, 1), drops.len);
            try std.testing.expectEqual(@as(u32, @intCast(game_data.registry.itemId(case.output).?)), drops[0].kind);
            try std.testing.expect(drops[0].count >= case.minimum and drops[0].count <= case.maximum);
            maximum_seen = @max(maximum_seen, drops[0].count);
        }
        if (case.fortune != 0) try std.testing.expect(maximum_seen > 1);
    }
}

test "native Zig loot handlers compose and own their parameters" {
    const Gate = struct {
        pub const kind: loot.Kind = .condition;
        pub const Parameters = struct { player: u128 };
        pub fn matches(_: *const @This(), parameters: *const Parameters, context: *const loot.Context) !bool {
            return context.player == parameters.player;
        }
    };
    const Multiply = struct {
        pub const kind: loot.Kind = .function;
        pub const Parameters = struct { multiplier: u16 };
        pub fn apply(_: *const @This(), parameters: *const Parameters, _: *const loot.Context, stack: *loot.Stack) !void {
            stack.count *|= parameters.multiplier;
        }
    };
    const Generate = struct {
        pub const kind: loot.Kind = .entry;
        pub const Parameters = struct { count: u16 };
        pub fn generate(_: *const @This(), parameters: *const Parameters, _: *const loot.Context, output: *loot.Output) !void {
            try output.append(.{ .kind = @intCast(game_data.registry.itemId("minecraft:paper").?), .count = parameters.count });
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const gate: Gate = .{};
    const multiply: Multiply = .{};
    const generate: Generate = .{};
    const content = try vanilla_content.prepare(allocator);
    {
        var temporary = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer temporary.deinit();
        const scratch = temporary.allocator();
        const table: loot.TableDefinition = .{
            .pools = &.{.{
                .conditions = &.{.{ .custom = try loot.Implementation(Gate).define(scratch, &gate, .{ .player = 7 }) }},
                .entries = &.{.{ .kind = .{ .custom = try loot.Implementation(Generate).define(scratch, &generate, .{ .count = 40 }) }, .functions = &.{.{ .operation = .{ .custom = try loot.Implementation(Multiply).define(scratch, &multiply, .{ .multiplier = 2 }) } }} }},
                .functions = &.{.{ .operation = .{ .count = .{ .value = .{ .constant = 1 }, .add = true } } }},
            }},
            .functions = &.{.{ .operation = .{ .custom = try loot.Implementation(Multiply).define(scratch, &multiply, .{ .multiplier = 2 }) } }},
        };
        _ = try provider.register(content, allocator, .{ .loot_tables = &.{.{ .name = "test:reward", .table = table }} }, null);
    }
    var random: std.Random.DefaultPrng = .init(7);
    var bytes: [8192]u8 = undefined;
    var scratch: std.heap.FixedBufferAllocator = .init(&bytes);
    var output: [3]loot.Drop = undefined;
    const table = content.loot.tables.get("test:reward").?;
    var context: loot.Context = .{ .items = content.items, .player = 7, .random = random.random(), .scratch = &scratch };
    const drops = try table.evaluate(&context, &output);
    try std.testing.expectEqual(@as(usize, 3), drops.len);
    try std.testing.expectEqual(@as(u16, 34), drops[2].count);
    scratch.reset();
    try std.testing.expectError(error.LootCapacity, table.evaluate(&context, output[0..2]));
    context.player = 8;
    scratch.reset();
    try std.testing.expectEqual(@as(usize, 0), (try table.evaluate(&context, &output)).len);
}

test "native loot references reject cycles before publication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const content = try vanilla_content.prepare(allocator);
    const first: loot.TableDefinition = .{ .pools = &.{.{ .entries = &.{.{ .kind = .{ .table = "test:second" } }} }} };
    const second: loot.TableDefinition = .{ .pools = &.{.{ .entries = &.{.{ .kind = .{ .table = "test:first" } }} }} };
    const original = content.book.table.book.ptr;
    try std.testing.expectError(error.LootTableCycle, provider.register(content, allocator, .{ .loot_tables = &.{ .{ .name = "test:first", .table = first }, .{ .name = "test:second", .table = second } } }, null));
    try std.testing.expectEqual(original, content.book.table.book.ptr);
}

test "mechanics begin without gameplay rules and accept ordinary native registrations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const content = try provider.prepare(allocator);
    try std.testing.expectEqual(@as(usize, 0), content.book.table.book.len);
    try std.testing.expectEqual(@as(usize, 0), content.crafting.table.crafting.len);
    try std.testing.expectEqual(@as(usize, 0), content.furnaces.table.fuel_conversions.len);
    try std.testing.expectEqual(@as(usize, 0), content.loot.tables.named.count());
    for (content.furnaces.table.recipes) |recipe| try std.testing.expect(recipe == null);
    for (content.furnaces.table.fuels) |fuel| {
        try std.testing.expectEqual(@as(u32, 0), fuel.ticks);
        try std.testing.expect(fuel.slot_limit == null);
    }
    for (content.book.table.remainders) |remainder| try std.testing.expect(remainder == null);
    try std.testing.expectError(error.UnknownDimension, content.dimensions.dimension("minecraft:overworld"));
    _ = try provider.register(content, allocator, .{
        .tags = &.{.{ .registry = "minecraft:item", .name = "test:fuels", .values = &.{ .{ .id = "minecraft:paper" }, .{ .id = "minecraft:stick" } } }},
        .fuels = &.{.{ .input = .{ .tag = "test:fuels" }, .ticks = 37 }},
        .remainders = &.{.{ .input = .{ .item = "minecraft:paper" }, .item = "minecraft:glass_bottle" }},
        .recipes = &.{
            .{ .name = "test:craft", .definition = .{ .shapeless = .{ .ingredients = &.{.{ .item = "minecraft:dirt" }}, .result = .{ .item = "minecraft:diamond" } } } },
            .{ .name = "test:cook", .definition = .{ .smelting = .{ .input = .{ .item = "minecraft:stone" }, .result = .{ .item = "minecraft:emerald" }, .ticks = 7 } } },
        },
    }, null);
    const paper: u32 = @intCast(game_data.registry.itemId("minecraft:paper").?);
    const stick: u32 = @intCast(game_data.registry.itemId("minecraft:stick").?);
    const dirt: u32 = @intCast(game_data.registry.itemId("minecraft:dirt").?);
    const stone: u32 = @intCast(game_data.registry.itemId("minecraft:stone").?);
    const coal: u32 = @intCast(game_data.registry.itemId("minecraft:coal").?);
    try std.testing.expectEqual(@as(u32, 37), content.furnaces.table.fuels[paper].ticks);
    try std.testing.expectEqual(@as(u32, 37), content.furnaces.table.fuels[stick].ticks);
    try std.testing.expectEqual(@as(u32, 0), content.furnaces.table.fuels[coal].ticks);
    try std.testing.expectEqual(@as(?u32, @intCast(game_data.registry.itemId("minecraft:glass_bottle").?)), content.book.table.remainders[paper]);
    try std.testing.expectEqualStrings("test:craft", content.crafting.table.matches(&.{ dirt, null, null, null }, 2).?.name);
    try std.testing.expectEqual(@as(u32, 7), content.furnaces.table.recipes[stone].?.ticks);
    _ = try provider.register(content, allocator, .{
        .fuels = &.{.{ .input = .{ .item = "minecraft:paper" }, .ticks = 0 }},
        .remainders = &.{.{ .input = .{ .item = "minecraft:paper" }, .item = null }},
    }, null);
    try std.testing.expectEqual(@as(u32, 0), content.furnaces.table.fuels[paper].ticks);
    try std.testing.expectEqual(@as(u32, 37), content.furnaces.table.fuels[stick].ticks);
    try std.testing.expect(content.book.table.remainders[paper] == null);
}
