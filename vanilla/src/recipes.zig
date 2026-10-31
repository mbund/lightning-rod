const smelting_behavior = @import("smelting.zig");
const fuel = @import("fuel.zig");
const std = @import("std");
const crafting = @import("crafting.zig");
const inventories = @import("inventories");
const item_data = @import("item_data.zig");
const item_registry = @import("item_registry.zig");

pub const Component = struct { key: u64, value: ?[]const u8 };

pub const Recipe = struct {
    callback: ?*const smelting_behavior.Binding = null,
    components: []const Component = &.{},
    index: u32 = 0,
    output: u32,
    item_id: inventories.ItemId,
    stack_limit: u16,
    count: u16,
    ticks: u32,
    experience: f32,
};

pub const Ingredient = struct { offset: u32 = 0, count: u16 = 0, required: bool = false };

pub const Craft = struct {
    name: []const u8 = "",
    components: []const Component = &.{},
    width: u8,
    height: u8,
    count: u8,
    ingredients: [9]Ingredient = @splat(.{}),
    output: u32,
    amount: u16,
};

pub const Fuel = struct { ticks: u32 = 0, slot_limit: ?u16 = null, callback: ?*const fuel.Binding = null };
pub const FuelDefinition = struct {
    input: Input,
    /// A callback without ticks inherits earlier declarative fuel properties.
    ticks: ?u32 = null,
    slot_limit: ?u16 = null,
    callback: ?fuel.Binding = null,
};
pub const RemainderDefinition = struct { input: Input, item: ?[]const u8 };
pub const FuelConversionDefinition = struct {
    input: []const u8,
    fuel: []const u8,
    /// Null cancels an earlier conversion for this input and fuel pair.
    result: ?[]const u8,
};
pub const FuelConversion = struct { input: u32, fuel: u32, result: ?u32 };
pub const Rules = struct {
    mode: enum { all, crafting, furnace } = .all,
    properties: []const item_registry.Properties = &.{},
    item_remainders: []const ?u32 = &.{},
    fuels: []const FuelDefinition = &.{},
    fuel_conversions: []const FuelConversionDefinition = &.{},
};

pub const Category = enum {
    crafting_building_blocks,
    crafting_redstone,
    crafting_equipment,
    crafting_misc,
    furnace_food,
    furnace_blocks,
    furnace_misc,
};
pub const DisplayInput = struct { input: ?Input = null, components: []const Component = &.{} };
pub const Display = struct {
    width: u8 = 0,
    height: u8 = 0,
    ingredients: []const DisplayInput,
    result: Result,
    category: Category = .crafting_misc,
    group: []const u8 = "",
    initially_unlocked: bool = false,
};
pub const BookIngredient = struct { ingredient: Ingredient, components: []const Component = &.{} };
pub const BookEntry = struct {
    name: []const u8,
    ingredients: []const BookIngredient,
    result: crafting.Draft,
    width: u8 = 0,
    height: u8 = 0,
    furnace: bool = false,
    ticks: u32 = 0,
    experience: f32 = 0,
    category: Category = .crafting_misc,
    group: []const u8 = "",
    show_notification: bool = true,
    group_id: i32 = 0,
    initially_unlocked: bool = false,
    algorithm: ?usize = null,
};

pub const BookTable = struct {
    book: []const BookEntry,
    alternatives: []const u32,
    remainders: []const ?u32,
    cooking: []const ?Recipe,
};
pub const FurnaceTable = struct {
    variants: []const []const Recipe = &.{},
    recipes: []const ?Recipe,
    book: []const BookEntry,
    cooking_names: []const []const u8,
    cooking_experience: []const f32,
    fuels: []const Fuel,
    remainders: []const ?u32,
    fuel_conversions: []const FuelConversion,
    alternatives: []const u32,
};
pub const CraftingTable = struct {
    book: []const BookEntry,
    crafting: []const Craft,
    algorithms: []const Algorithm,
    remainders: []const ?u32,
    alternatives: []const u32,
    pub fn matches(self: *const @This(), grid: []const ?u32, width: usize) ?*const Craft {
        std.debug.assert((width == 2 or width == 3) and grid.len == width * width);
        var occupied: [9]u32 = undefined;
        var count: usize = 0;
        var min_x = width;
        var min_y = width;
        var max_x: usize = 0;
        var max_y: usize = 0;
        for (grid, 0..) |kind, index| if (kind) |value| {
            occupied[count] = value;
            count += 1;
            min_x = @min(min_x, index % width);
            min_y = @min(min_y, index / width);
            max_x = @max(max_x, index % width);
            max_y = @max(max_y, index / width);
        };
        if (count == 0) return null;
        recipes: for (self.crafting) |*craft| {
            if (craft.width == 0) {
                if (count != craft.count) continue;
                var assigned: [9]?usize = @splat(null);
                for (occupied[0..count], 0..) |kind, at| {
                    var visited: u16 = 0;
                    if (!self.assign(craft, occupied[0..count], &assigned, &visited, kind, at)) continue :recipes;
                }
                return craft;
            }
            if (craft.width != max_x - min_x + 1 or craft.height != max_y - min_y + 1) continue;
            for (0..2) |mirror| {
                var valid = true;
                for (0..craft.height) |y| for (0..craft.width) |x| {
                    const ingredient = craft.ingredients[y * craft.width + if (mirror == 0) x else craft.width - 1 - x];
                    const kind = grid[(min_y + y) * width + min_x + x];
                    if (kind) |value| {
                        if (!self.accepts(ingredient, value)) valid = false;
                    } else if (ingredient.required or ingredient.count != 0) valid = false;
                };
                if (valid) return craft;
            }
        }
        return null;
    }

    fn accepts(self: *const @This(), ingredient: Ingredient, kind: u32) bool {
        return std.mem.indexOfScalar(u32, self.alternatives[ingredient.offset..][0..ingredient.count], kind) != null;
    }

    fn assign(self: *const @This(), craft: *const Craft, occupied: []const u32, assigned: *[9]?usize, visited: *u16, kind: u32, at: usize) bool {
        for (craft.ingredients[0..craft.count], 0..) |ingredient, index| {
            const bit = @as(u16, 1) << @intCast(index);
            if (visited.* & bit != 0 or !self.accepts(ingredient, kind)) continue;
            visited.* |= bit;
            if (assigned[index] == null or self.assign(craft, occupied, assigned, visited, occupied[assigned[index].?], assigned[index].?)) {
                assigned[index] = at;
                return true;
            }
        }
        return false;
    }
};

pub const Prepared = struct {
    variants: []const []const Recipe = &.{},
    recipes: []const ?Recipe,
    book: []const BookEntry = &.{},
    cooking_names: []const []const u8 = &.{},
    cooking_experience: []const f32 = &.{},
    fuels: []const Fuel,
    remainders: []const ?u32,
    fuel_conversions: []const FuelConversion,
    crafting: []const Craft,
    algorithms: []const Algorithm = &.{},
    alternatives: []const u32,

    pub fn craftingTable(self: *const Prepared) CraftingTable {
        return .{ .book = self.book, .crafting = self.crafting, .algorithms = self.algorithms, .remainders = self.remainders, .alternatives = self.alternatives };
    }
    pub fn furnaceTable(self: *const Prepared) FurnaceTable {
        return .{ .variants = self.variants, .book = self.book, .recipes = self.recipes, .cooking_names = self.cooking_names, .cooking_experience = self.cooking_experience, .fuels = self.fuels, .remainders = self.remainders, .fuel_conversions = self.fuel_conversions, .alternatives = self.alternatives };
    }
};

pub const Algorithm = struct { name: []const u8, binding: crafting.Binding };

pub const Definition = union(enum) {
    algorithmic: crafting.Binding,
    shaped: Shaped,
    shapeless: Shapeless,
    smelting: Smelting,
};
pub const Input = union(enum) { item: []const u8, tag: []const u8, alternatives: []const Input };
pub const Result = struct { item: []const u8, count: u16 = 1, components: []const Component = &.{} };
pub const Key = struct { symbol: u21, input: Input };
pub const Book = struct { group: []const u8 = "", category: Category = .crafting_misc, show_notification: bool = true };
pub const Shaped = struct { book: Book = .{}, pattern: []const []const u8, keys: []const Key, result: Result };
pub const Shapeless = struct { book: Book = .{}, ingredients: []const Input, result: Result };
pub const Smelting = struct { book: Book = .{}, input: Input, result: Result, ticks: u32 = 200, experience: f32 = 0, callback: ?smelting_behavior.Binding = null };
pub const Entry = struct { name: []const u8, definition: Definition };
const ids = @import("content_ids.zig");
const Tags = @import("content_tags.zig").Tags;

pub const Preparation = struct {
    allocator: std.mem.Allocator,
    temporary: std.mem.Allocator,
    tags: *const Tags,
    items: std.StringHashMapUnmanaged(u32) = .empty,
    cooking: []?Recipe,
    variants: []std.ArrayList(Recipe),
    has_variants: bool = false,
    crafting: std.ArrayList(Craft) = .empty,
    algorithms: std.ArrayList(Algorithm) = .empty,
    alternatives: std.ArrayList(u32) = .empty,
    cooking_names: std.ArrayList([]const u8) = .empty,
    cooking_experience: std.ArrayList(f32) = .empty,
    fuels: []Fuel,
    remainders: []const ?u32,
    properties: []const item_registry.Properties,
    fuel_conversions: []FuelConversion,
    book: std.ArrayList(BookEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator, temporary: std.mem.Allocator, tags: *const Tags, item_names: []const []const u8, rules: Rules) !Preparation {
        const remainders = if (rules.item_remainders.len > 0) rules.item_remainders else empty: {
            const entries = try allocator.alloc(?u32, item_names.len);
            @memset(entries, null);
            break :empty entries;
        };
        var self: Preparation = .{
            .allocator = allocator,
            .temporary = temporary,
            .tags = tags,
            .cooking = try allocator.alloc(?Recipe, if (rules.mode == .crafting) 0 else item_names.len),
            .variants = try temporary.alloc(std.ArrayList(Recipe), if (rules.mode == .crafting) 0 else item_names.len),
            .fuels = try allocator.alloc(Fuel, if (rules.mode == .crafting) 0 else item_names.len),
            .remainders = remainders,
            .properties = rules.properties,
            .fuel_conversions = try allocator.alloc(FuelConversion, rules.fuel_conversions.len),
        };
        @memset(self.cooking, null);
        @memset(self.variants, .empty);
        @memset(self.fuels, .{});
        try self.items.ensureTotalCapacity(temporary, @intCast(item_names.len));
        for (item_names, 0..) |name, index| self.items.putAssumeCapacityNoClobber(name, @intCast(index));
        for (rules.fuel_conversions, self.fuel_conversions) |rule, *compiled| compiled.* = .{ .input = try self.item(rule.input), .fuel = try self.item(rule.fuel), .result = if (rule.result) |name| try self.item(name) else null };
        for (rules.fuels) |*rule| {
            if (rule.ticks) |ticks| {
                if (ticks > std.math.maxInt(i32)) return error.InvalidFuelDuration;
            } else if (rule.callback == null) return error.InvalidFuelDefinition;
            if (rule.slot_limit) |limit| if (limit > 99) return error.InvalidFuelSlotLimit;
            const input = try self.ingredient(rule.input);
            for (self.alternatives.items[input.offset..][0..input.count]) |kind| {
                const previous = self.fuels[kind];
                self.fuels[kind] = .{
                    .ticks = rule.ticks orelse previous.ticks,
                    .slot_limit = if (rule.ticks != null or rule.slot_limit != null) rule.slot_limit else previous.slot_limit,
                    .callback = if (rule.callback) |*callback| callback else null,
                };
            }
            self.alternatives.clearRetainingCapacity();
        }
        return self;
    }

    pub fn compile(self: *Preparation, name: []const u8, definition: Definition) !void {
        switch (definition) {
            .algorithmic => |binding| {
                const index = self.algorithms.items.len;
                try self.algorithms.append(self.temporary, .{ .name = try self.allocator.dupe(u8, name), .binding = binding });
                if (binding.display) |display| {
                    if (display.ingredients.len == 0 or display.ingredients.len > 9 or display.width > 3 or display.height > 3 or
                        (display.width == 0 and display.height != 0) or (display.width != 0 and display.width * display.height != display.ingredients.len)) return error.InvalidRecipeDisplay;
                    const ingredients = try self.allocator.alloc(BookIngredient, display.ingredients.len);
                    for (display.ingredients, ingredients) |input, *prepared| prepared.* = .{
                        .ingredient = if (input.input) |value| try self.ingredient(value) else .{},
                        .components = try self.copyComponents(input.components),
                    };
                    try self.book.append(self.temporary, .{
                        .name = try self.allocator.dupe(u8, name),
                        .ingredients = ingredients,
                        .result = .{ .kind = try self.item(display.result.item), .count = try validCount(display.result.count), .components = try self.copyComponents(display.result.components) },
                        .width = display.width,
                        .height = display.height,
                        .algorithm = index,
                        .category = display.category,
                        .group = try self.allocator.dupe(u8, display.group),
                        .initially_unlocked = display.initially_unlocked,
                    });
                }
            },
            .shaped => |shaped| {
                if (shaped.pattern.len == 0 or shaped.pattern.len > 3 or shaped.keys.len > 9) return error.InvalidRecipe;
                var pattern: [3][3]u21 = @splat(@splat(' '));
                var row_width: ?usize = null;
                for (shaped.pattern, 0..) |row, y| {
                    var characters = (try std.unicode.Utf8View.init(row)).iterator();
                    var x: usize = 0;
                    while (characters.nextCodepoint()) |character| {
                        if (x == 3 or character > 0xffff) return error.InvalidRecipe;
                        pattern[y][x] = character;
                        x += 1;
                    }
                    if (x == 0 or (row_width != null and row_width.? != x)) return error.InvalidRecipe;
                    row_width = x;
                }
                for (shaped.keys, 0..) |key, index| {
                    if (key.symbol == ' ' or key.symbol > 0xffff) return error.InvalidRecipe;
                    for (shaped.keys[0..index]) |previous| if (key.symbol == previous.symbol) return error.InvalidRecipe;
                }
                var used: [9]bool = @splat(false);
                var minimum: [2]usize = .{ 3, 3 };
                var maximum: [2]usize = .{ 0, 0 };
                var occupied: usize = 0;
                for (pattern[0..shaped.pattern.len], 0..) |row, y| {
                    for (row[0..row_width.?], 0..) |symbol, x| {
                        if (symbol == ' ') continue;
                        const key_index = for (shaped.keys, 0..) |key, index| {
                            if (key.symbol == symbol) break index;
                        } else return error.InvalidRecipe;
                        used[key_index] = true;
                        minimum = .{ @min(minimum[0], x), @min(minimum[1], y) };
                        maximum = .{ @max(maximum[0], x), @max(maximum[1], y) };
                        occupied += 1;
                    }
                }
                if (occupied == 0) return error.InvalidRecipe;
                for (used[0..shaped.keys.len]) |present| if (!present) return error.InvalidRecipe;
                const width = maximum[0] - minimum[0] + 1;
                const height = maximum[1] - minimum[1] + 1;
                var craft: Craft = .{ .name = try self.allocator.dupe(u8, name), .width = @intCast(width), .height = @intCast(height), .count = @intCast(width * height), .components = try self.copyComponents(shaped.result.components), .output = try self.item(shaped.result.item), .amount = try validCount(shaped.result.count) };
                for (0..height) |y| for (0..width) |x| {
                    const symbol = pattern[minimum[1] + y][minimum[0] + x];
                    if (symbol != ' ') {
                        const input = for (shaped.keys) |key| {
                            if (key.symbol == symbol) break key.input;
                        } else unreachable;
                        craft.ingredients[y * width + x] = try self.ingredient(input);
                    }
                };
                try self.crafting.append(self.temporary, craft);
                try self.bookCraft(craft, shaped.book);
            },
            .shapeless => |shapeless| {
                if (shapeless.ingredients.len == 0 or shapeless.ingredients.len > 9) return error.InvalidRecipe;
                var craft: Craft = .{ .name = try self.allocator.dupe(u8, name), .width = 0, .height = 0, .count = @intCast(shapeless.ingredients.len), .components = try self.copyComponents(shapeless.result.components), .output = try self.item(shapeless.result.item), .amount = try validCount(shapeless.result.count) };
                for (shapeless.ingredients, 0..) |input, index| craft.ingredients[index] = try self.ingredient(input);
                try self.crafting.append(self.temporary, craft);
                try self.bookCraft(craft, shapeless.book);
            },
            .smelting => |smelting| {
                if (smelting.ticks == 0 or smelting.ticks > std.math.maxInt(i32) or !std.math.isFinite(smelting.experience) or smelting.experience < 0) return error.InvalidRecipe;
                const ingredient_value = try self.ingredient(smelting.input);
                const index: u32 = @intCast(self.cooking_names.items.len);
                const output = try self.item(smelting.result.item);
                const components = try self.copyComponents(smelting.result.components);
                const stack_limit = try item_registry.maximum(self.properties, output, components);
                const count = try validCount(smelting.result.count);
                if (count > stack_limit) return error.InvalidRecipeResult;
                const encoded = try item_data.encode(try self.temporary.alloc(u8, try item_data.encodedSize(components)), output, components);
                var item_id: inventories.ItemId = undefined;
                std.crypto.hash.Blake3.hash(encoded.bytes, &item_id, .{});
                const callback = if (smelting.callback) |binding| block: {
                    const owned = try self.allocator.create(smelting_behavior.Binding);
                    owned.* = binding;
                    break :block owned;
                } else null;
                const recipe: Recipe = .{ .callback = callback, .index = index, .components = components, .output = output, .item_id = item_id, .stack_limit = stack_limit, .count = count, .ticks = smelting.ticks, .experience = smelting.experience };
                try self.cooking_names.append(self.temporary, try self.allocator.dupe(u8, name));
                try self.cooking_experience.append(self.temporary, smelting.experience);
                const ingredients = try self.allocator.alloc(BookIngredient, 1);
                ingredients[0] = .{ .ingredient = ingredient_value };
                try self.book.append(self.temporary, .{
                    .name = self.cooking_names.items[index],
                    .ingredients = ingredients,
                    .result = .{ .kind = recipe.output, .count = recipe.count, .components = recipe.components },
                    .furnace = true,
                    .ticks = recipe.ticks,
                    .experience = recipe.experience,
                    .category = switch (smelting.book.category) {
                        .crafting_misc => .furnace_misc,
                        else => smelting.book.category,
                    },
                    .group = try self.allocator.dupe(u8, smelting.book.group),
                    .show_notification = smelting.book.show_notification,
                });
                for (self.alternatives.items[ingredient_value.offset..][0..ingredient_value.count]) |input| {
                    if (callback != null) {
                        try self.variants[input].append(self.temporary, recipe);
                        self.has_variants = true;
                    }
                    if (self.cooking[input] == null or (self.cooking[input].?.callback != null and callback == null)) self.cooking[input] = recipe;
                }
            },
        }
    }

    fn bookCraft(self: *Preparation, craft: Craft, metadata: Book) !void {
        const ingredients = try self.allocator.alloc(BookIngredient, craft.count);
        for (craft.ingredients[0..craft.count], ingredients) |input, *prepared| prepared.* = .{ .ingredient = input };
        try self.book.append(self.temporary, .{
            .name = craft.name,
            .ingredients = ingredients,
            .width = craft.width,
            .height = craft.height,
            .result = .{ .kind = craft.output, .count = craft.amount, .components = craft.components },
            .category = metadata.category,
            .group = try self.allocator.dupe(u8, metadata.group),
            .show_notification = metadata.show_notification,
        });
    }

    fn copyComponents(self: *const Preparation, components: []const Component) ![]const Component {
        const output = try self.allocator.dupe(Component, components);
        for (output) |*component| if (component.value) |bytes| {
            component.value = try self.allocator.dupe(u8, bytes);
        };
        return output;
    }

    pub fn item(self: *const Preparation, name: []const u8) !u32 {
        return self.items.get(try ids.identifier(self.allocator, name)) orelse error.UnknownRecipeItem;
    }

    fn ingredient(self: *Preparation, input: Input) !Ingredient {
        const start = self.alternatives.items.len;
        try self.expand(input, 0);
        const values = self.alternatives.items[start..];
        std.mem.sortUnstable(u32, values, {}, std.sort.asc(u32));
        var count: usize = 0;
        for (values) |value| {
            if (count > 0 and values[count - 1] == value) continue;
            values[count] = value;
            count += 1;
        }
        if (count > std.math.maxInt(u16)) return error.RecipeIngredientCapacity;
        self.alternatives.shrinkRetainingCapacity(start + count);
        return .{ .offset = @intCast(start), .count = @intCast(count), .required = true };
    }

    fn expand(self: *Preparation, input: Input, depth: usize) anyerror!void {
        if (depth == 64) return error.RecipeIngredientDepth;
        switch (input) {
            .item => |name| try self.alternatives.append(self.temporary, try self.item(name)),
            .tag => |name| {
                const tag = self.tags.find(try ids.identifier(self.allocator, name)) orelse return error.UnknownRecipeTag;
                try self.alternatives.appendSlice(self.temporary, self.tags.members(tag));
            },
            .alternatives => |values| for (values) |value| try self.expand(value, depth + 1),
        }
    }

    pub fn finish(self: *Preparation) !Prepared {
        const variants = try self.allocator.alloc([]const Recipe, if (self.has_variants) self.variants.len else 0);
        for (variants, self.variants[0..variants.len]) |*destination, entries| destination.* = try self.allocator.dupe(Recipe, entries.items);
        return .{
            .variants = variants,
            .book = try self.allocator.dupe(BookEntry, self.book.items),
            .algorithms = try self.allocator.dupe(Algorithm, self.algorithms.items),
            .recipes = self.cooking,
            .cooking_names = try self.allocator.dupe([]const u8, self.cooking_names.items),
            .cooking_experience = try self.allocator.dupe(f32, self.cooking_experience.items),
            .fuels = self.fuels,
            .remainders = self.remainders,
            .fuel_conversions = self.fuel_conversions,
            .crafting = try self.allocator.dupe(Craft, self.crafting.items),
            .alternatives = try self.allocator.dupe(u32, self.alternatives.items),
        };
    }
};

pub fn prepare(allocator: std.mem.Allocator, temporary: std.mem.Allocator, tags: *const Tags, item_names: []const []const u8, rules: Rules, definitions: []const Entry) !Prepared {
    var selected: std.StringHashMapUnmanaged(Definition) = .empty;
    for (definitions) |entry| {
        if (!ids.validName(entry.name)) return error.InvalidResourceName;
        try selected.put(temporary, entry.name, entry.definition);
    }
    const names = try temporary.alloc([]const u8, selected.count());
    var iterator = selected.keyIterator();
    var count: usize = 0;
    while (iterator.next()) |name| {
        names[count] = name.*;
        count += 1;
    }
    std.mem.sortUnstable([]const u8, names, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    var preparation = try Preparation.init(allocator, temporary, tags, item_names, rules);
    for (names) |name| try preparation.compile(name, selected.get(name).?);
    return preparation.finish();
}

fn validCount(count: u16) !u16 {
    if (count == 0 or count > 99) return error.InvalidRecipe;
    return count;
}

test "native recipes resolve tags and match shaped and shapeless inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tags = try Tags.prepare(allocator, allocator, &.{.{ .registry = "minecraft:item", .name = "test:ingredients", .values = &.{ .{ .id = "minecraft:stone" }, .{ .id = "minecraft:dirt" } } }}, "minecraft:item", &.{ "minecraft:stone", "minecraft:dirt", "minecraft:diamond" });
    const entries = [_]Entry{
        .{ .name = "test:shaped", .definition = .{ .shaped = .{ .pattern = &.{"SS"}, .keys = &.{.{ .symbol = 'S', .input = .{ .item = "minecraft:stone" } }}, .result = .{ .item = "minecraft:diamond" } } } },
        .{ .name = "test:shapeless", .definition = .{ .shapeless = .{ .ingredients = &.{.{ .tag = "test:ingredients" }}, .result = .{ .item = "minecraft:diamond", .count = 2 } } } },
    };
    const table = try prepare(allocator, allocator, &tags, &.{ "minecraft:stone", "minecraft:dirt", "minecraft:diamond" }, .{}, &entries);
    try std.testing.expectEqualStrings("test:shaped", table.craftingTable().matches(&.{ 0, 0, null, null }, 2).?.name);
    try std.testing.expectEqualStrings("test:shapeless", table.craftingTable().matches(&.{ null, 1, null, null }, 2).?.name);
    try std.testing.expect(table.craftingTable().matches(&.{ 2, null, null, null }, 2) == null);
    try std.testing.expectError(error.InvalidRecipe, prepare(allocator, allocator, &tags, &.{ "minecraft:stone", "minecraft:dirt", "minecraft:diamond" }, .{}, &.{.{ .name = "test:invalid", .definition = .{ .shapeless = .{ .ingredients = &.{.{ .item = "minecraft:stone" }}, .result = .{ .item = "minecraft:diamond", .count = 0 } } } }}));
}
