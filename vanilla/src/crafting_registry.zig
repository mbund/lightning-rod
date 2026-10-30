const std = @import("std");
const lightning_rod = @import("lightning_rod");
const game_data = @import("game_data");
const registry = @import("registry.zig");
const recipes = @import("recipes.zig");
const ItemRegistry = @import("item_registry.zig").ItemRegistry;

pub const Crafting = struct {
    pub const id = "minecraft:crafting_registry";
    pub const Definitions = struct { recipes: []const recipes.Entry = &.{} };
    pub const Data = struct { table: recipes.CraftingTable };
    pub const Dependencies = struct { items: *ItemRegistry };
    pub const Configuration = registry.Registry(Crafting).Configuration;
    registry: registry.Registry(Crafting),
    deps: Dependencies,
    table: recipes.CraftingTable,
    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*Crafting {
        const self = try allocator.create(Crafting);
        self.deps = deps;
        try registry.Registry(Crafting).init(self, allocator, configuration);
        try deps.items.registry.onChange(self, refresh);
        return self;
    }
    pub fn addRecipes(self: *Crafting, entries: []const recipes.Entry) !void {
        try self.registry.add(.{ .recipes = entries });
    }
    pub fn addDefinitions(self: *Crafting, definitions: Definitions) !void {
        try self.registry.add(definitions);
    }
    fn refresh(self: *Crafting) !void {
        try self.registry.refresh();
    }
    pub fn compile(self: *Crafting, allocator: std.mem.Allocator, scratch: std.mem.Allocator, definitions: Definitions) !Data {
        for (definitions.recipes) |entry| {
            if (entry.definition == .smelting) return error.InvalidCraftingRecipe;
        }
        const table = try recipes.prepare(allocator, scratch, &self.deps.items.tags, game_data.registry.item_names, .{ .mode = .crafting, .properties = self.deps.items.properties, .item_remainders = self.deps.items.remainders }, definitions.recipes);
        for (table.book) |entry| {
            if (entry.result.count == 0 or entry.result.count > try self.deps.items.maximumDefinition(entry.result.kind, entry.result.components)) return error.InvalidRecipeResult;
        }
        for (table.algorithms) |algorithm| if (algorithm.binding.maximum_inputs > 9 or algorithm.binding.minimum_inputs > algorithm.binding.maximum_inputs) return error.InvalidRecipeInputs;
        return .{ .table = table.craftingTable() };
    }
    pub fn close(self: *Crafting, _: *lightning_rod.Closing) void {
        self.registry.close();
    }
};
