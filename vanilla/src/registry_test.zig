const fuel = @import("fuel.zig");
const game_data = @import("game_data");
const std = @import("std");
const ItemRegistry = @import("item_registry.zig").ItemRegistry;
const Crafting = @import("crafting_registry.zig").Crafting;
const Furnaces = @import("furnaces.zig").Furnaces;
const Mining = @import("mining_registry.zig").MiningRegistry;
const Placement = @import("placement_registry.zig").PlacementRegistry;
const Loot = @import("loot_registry.zig").Loot;
const Dimensions = @import("dimensions.zig").Dimensions;
const Blocks = @import("blocks.zig").Blocks;
const Enchantments = @import("enchantment_registry.zig").EnchantmentRegistry;
const Book = @import("recipe_book_registry.zig").RecipeBookRegistry;
const Client = @import("client_registries.zig").ClientRegistries;
const provider = @import("definition_provider.zig");
const Vanilla = @import("vanilla_content.zig").Vanilla;

test "subsystem registries initialize without vanilla providers" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const allocator = memory.allocator();
    const items = try ItemRegistry.init(allocator, .{});
    const crafting = try Crafting.init(allocator, .{}, .{ .items = items });
    const furnaces = try Furnaces.init(allocator, .{}, .{ .items = items });
    _ = try Mining.init(allocator, .{}, .{ .items = items });
    _ = try Placement.init(allocator, .{});
    _ = try Loot.init(allocator, .{}, .{ .items = items });
    _ = try Dimensions.init(allocator, .{});
    _ = try Blocks.init(allocator, .{});
    _ = try Enchantments.init(allocator, .{});
    const book = try Book.init(allocator, .{}, .{ .items = items, .crafting = crafting, .furnaces = furnaces });
    _ = try Client.init(allocator, .{});
    try std.testing.expectEqual(@as(usize, 0), crafting.table.book.len);
    try std.testing.expectEqual(@as(usize, 0), book.table.book.len);
}

test "vanilla provider configures independent registries" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const allocator = memory.allocator();
    const deps = try provider.prepare(allocator);
    _ = try Vanilla.init(allocator, deps);
    try std.testing.expect(deps.crafting.table.book.len > 100);
    try std.testing.expect(deps.furnaces.table.book.len > 10);
    try std.testing.expect(deps.items.tags.find("minecraft:logs") != null);
}

test "failed recipe registration preserves independently owned mechanics" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const allocator = memory.allocator();
    const items = try ItemRegistry.init(allocator, .{});
    const crafting = try Crafting.init(allocator, .{}, .{ .items = items });
    const furnaces = try Furnaces.init(allocator, .{}, .{ .items = items });
    try items.addDefinitions(.{ .items = &.{.{ .name = "minecraft:paper", .stack_size = 8 }} });
    try furnaces.addFuels(&.{.{ .input = .{ .item = "minecraft:paper" }, .ticks = 37 }});
    const before = crafting.table.book.ptr;
    try std.testing.expectError(error.InvalidRecipeResult, crafting.addRecipes(&.{.{ .name = "test:oversized", .definition = .{ .shapeless = .{
        .ingredients = &.{.{ .item = "minecraft:dirt" }},
        .result = .{ .item = "minecraft:paper", .count = 9 },
    } } }}));
    try std.testing.expectEqual(before, crafting.table.book.ptr);
    try std.testing.expectEqual(@as(usize, 0), crafting.table.book.len);
    const paper = @as(usize, @intCast(game_data.registry.itemId("minecraft:paper").?));
    try std.testing.expectEqual(@as(u32, 37), furnaces.table.fuels[paper].ticks);
    try std.testing.expectEqual(@as(u16, 8), items.properties[paper].stack_size);
}

test "native exclusions affect only earlier contributions and cancellation restores them" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const allocator = memory.allocator();
    const items = try ItemRegistry.init(allocator, .{});
    const paper: u32 = @intCast(game_data.registry.itemId("minecraft:paper").?);
    const diamond: u32 = @intCast(game_data.registry.itemId("minecraft:diamond").?);
    const tag = "test:ingredients";
    try items.addDefinitions(.{ .tags = &.{.{ .registry = "minecraft:item", .name = tag, .values = &.{.{ .id = "minecraft:paper" }} }} });
    var change = try items.registry.stageExcluded(null, .{ .tags = &.{.{ .registry = "minecraft:item", .name = tag, .values = &.{.{ .id = "minecraft:diamond" }} }} }, &.{.{ .field = .tags, .name = tag, .registry = "minecraft:item" }});
    try std.testing.expect(!items.tags.contains(items.tags.find(tag).?, paper));
    try std.testing.expect(items.tags.contains(items.tags.find(tag).?, diamond));
    change.cancel();
    try std.testing.expect(items.tags.contains(items.tags.find(tag).?, paper));
    change = try items.registry.stageExcluded(null, .{}, &.{.{ .field = .tags, .name = tag, .registry = "minecraft:item" }});
    try change.commit();
    try items.registry.refresh();
    try std.testing.expect(items.tags.find(tag) == null);
    try items.addDefinitions(.{ .tags = &.{.{ .registry = "minecraft:item", .name = tag, .values = &.{.{ .id = "minecraft:diamond" }} }} });
    try std.testing.expect(items.tags.contains(items.tags.find(tag).?, diamond));
    try std.testing.expect(!items.tags.contains(items.tags.find(tag).?, paper));
}

const DefaultFuel = struct {
    pub const Parameters = struct {};
    pub fn prepare(_: *DefaultFuel, _: *const Parameters, context: *const fuel.Context) !?fuel.Plan {
        return .{ .properties = context.standard };
    }
};

test "fuel callbacks inherit declarative defaults and later declarative rules replace callbacks" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const allocator = memory.allocator();
    const deps = try provider.prepare(allocator);
    _ = try Vanilla.init(allocator, deps);
    const coal: u32 = @intCast(game_data.registry.itemId("minecraft:coal").?);
    var owner: DefaultFuel = .{};
    try deps.furnaces.addFuels(&.{.{ .input = .{ .item = "minecraft:coal" }, .callback = try fuel.Handler(DefaultFuel, DefaultFuel.Parameters, DefaultFuel.prepare).define(allocator, &owner, .{}) }});
    try std.testing.expectEqual(@as(u32, 1600), deps.furnaces.table.fuels[coal].ticks);
    try std.testing.expect(deps.furnaces.table.fuels[coal].callback != null);
    try deps.furnaces.addFuels(&.{.{ .input = .{ .item = "minecraft:coal" }, .ticks = 7 }});
    try std.testing.expectEqual(@as(u32, 7), deps.furnaces.table.fuels[coal].ticks);
    try std.testing.expect(deps.furnaces.table.fuels[coal].callback == null);
    try std.testing.expectError(error.InvalidFuelDefinition, deps.furnaces.addFuels(&.{.{ .input = .{ .item = "minecraft:coal" } }}));
    try std.testing.expectEqual(@as(u32, 7), deps.furnaces.table.fuels[coal].ticks);
}
