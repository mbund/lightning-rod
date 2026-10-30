const std = @import("std");
const lightning_rod = @import("lightning_rod");
const game_data = @import("game_data");
const registry = @import("registry.zig");
const recipes = @import("recipes.zig");
const ItemRegistry = @import("item_registry.zig").ItemRegistry;
const Crafting = @import("crafting_registry.zig").Crafting;
const Furnaces = @import("furnaces.zig").Furnaces;
const unlocks = @import("recipe_unlocks.zig");
pub const RecipeBookRegistry = struct {
    pub const id = "minecraft:recipe_unlocks";
    pub const Definitions = struct { unlocks: []const unlocks.Definition = &.{} };
    pub const Data = struct { table: recipes.BookTable, unlocks: unlocks.Rules };
    pub const Dependencies = struct { items: *ItemRegistry, crafting: *Crafting, furnaces: *Furnaces };
    pub const Configuration = registry.Registry(RecipeBookRegistry).Configuration;
    registry: registry.Registry(RecipeBookRegistry),
    deps: Dependencies,
    table: recipes.BookTable,
    unlocks: unlocks.Rules,
    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*RecipeBookRegistry {
        const self = try allocator.create(RecipeBookRegistry);
        self.deps = deps;
        try registry.Registry(RecipeBookRegistry).init(self, allocator, configuration);
        try deps.items.registry.onChange(self, refresh);
        try deps.crafting.registry.onChange(self, refresh);
        try deps.furnaces.registry.onChange(self, refresh);
        return self;
    }
    pub fn addDefinitions(self: *RecipeBookRegistry, entries: []const unlocks.Definition) !void {
        try self.registry.add(.{ .unlocks = entries });
    }
    fn refresh(self: *RecipeBookRegistry) !void {
        try self.registry.refresh();
    }
    pub fn compile(self: *RecipeBookRegistry, allocator: std.mem.Allocator, scratch: std.mem.Allocator, definitions: Definitions) !Data {
        const crafting = &self.deps.crafting.table;
        const furnaces = &self.deps.furnaces.table;
        const entries = try allocator.alloc(recipes.BookEntry, crafting.book.len + furnaces.book.len);
        @memcpy(entries[0..crafting.book.len], crafting.book);
        @memcpy(entries[crafting.book.len..], furnaces.book);
        for (entries[crafting.book.len..]) |*entry| {
            const ingredients = try allocator.dupe(recipes.BookIngredient, entry.ingredients);
            for (ingredients) |*ingredient| ingredient.ingredient.offset += @intCast(crafting.alternatives.len);
            entry.ingredients = ingredients;
        }
        std.mem.sort(recipes.BookEntry, entries, {}, struct {
            fn less(_: void, a: recipes.BookEntry, b: recipes.BookEntry) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);
        for (entries, 0..) |*entry, index| {
            if (index > 0 and std.mem.eql(u8, entries[index - 1].name, entry.name)) return error.DuplicateRecipe;
            entry.group_id = 0;
            if (entry.group.len == 0) continue;
            entry.group_id = @intCast(index + 1);
            for (entries[0..index]) |previous| if (entry.category == previous.category and std.mem.eql(u8, entry.group, previous.group)) {
                entry.group_id = previous.group_id;
                break;
            };
        }
        const alternatives = try allocator.alloc(u32, crafting.alternatives.len + furnaces.alternatives.len);
        @memcpy(alternatives[0..crafting.alternatives.len], crafting.alternatives);
        @memcpy(alternatives[crafting.alternatives.len..], furnaces.alternatives);
        const table: recipes.BookTable = .{
            .book = entries,
            .alternatives = alternatives,
            .remainders = self.deps.items.remainders,
            .cooking = furnaces.recipes,
        };
        return .{ .table = table, .unlocks = try unlocks.Rules.prepare(allocator, scratch, definitions.unlocks, table.book, &self.deps.items.tags) };
    }
    pub fn close(self: *RecipeBookRegistry, _: *lightning_rod.Closing) void {
        self.registry.close();
    }
};
