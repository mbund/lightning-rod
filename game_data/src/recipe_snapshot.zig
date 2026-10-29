const std = @import("std");
const registry = @import("registry");
const data = @import("recipe_data");
const Recipe = data.Recipe;
const Fuel = data.Fuel;
const Craft = data.Craft;

const Buffers = struct { recipes: []?Recipe, fuels: []Fuel, crafting: []Craft, alternatives: []u32 };

pub fn load(allocator: std.mem.Allocator, snapshot: []const u8) !data.Table {
    const smelting = try allocator.alloc(?Recipe, registry.items.len);
    errdefer allocator.free(smelting);
    const fuels = try allocator.alloc(Fuel, registry.items.len);
    errdefer allocator.free(fuels);
    var self: Buffers = .{
        .recipes = smelting,
        .fuels = fuels,
        .crafting = &.{},
        .alternatives = &.{},
    };
    errdefer allocator.free(self.crafting);
    errdefer allocator.free(self.alternatives);
    @memset(self.recipes, null);
    @memset(self.fuels, .{});
    var reader = std.Io.Reader.fixed(snapshot);
    if (!std.mem.eql(u8, try reader.take(8), "LRRCP002")) return error.InvalidRecipeSnapshot;
    const items = try reader.takeInt(u32, .big);
    if (items != registry.items.len) return error.InvalidCookingRegistry;
    for (0..items) |_| {
        const kind = try itemKind(try string(&reader));
        const ticks = try reader.takeInt(u32, .big);
        const remainder = try string(&reader);
        self.fuels[kind] = .{
            .ticks = ticks,
            .remainder = if (remainder.len == 0) null else try itemKind(remainder),
        };
    }
    const recipes = try reader.takeInt(u32, .big);
    var highest_recipe: u32 = 0;
    for (0..recipes) |_| {
        const input = try itemKind(try string(&reader));
        const output = try itemKind(try string(&reader));
        const count = try reader.takeInt(u32, .big);
        const ticks = try reader.takeInt(u32, .big);
        const experience: f32 = @bitCast(try reader.takeInt(u32, .big));
        const index = try reader.takeInt(u32, .big);
        if (index >= recipes) return error.InvalidCookingRecipe;
        highest_recipe = @max(highest_recipe, index);
        if (count == 0 or count > 99 or ticks == 0 or !std.math.isFinite(experience) or experience < 0) return error.InvalidCookingRecipe;
        if (self.recipes[input] == null) self.recipes[input] = .{ .index = index, .output = output, .count = @intCast(count), .ticks = ticks, .experience = experience };
    }
    const cooking_experience = try allocator.alloc(f32, if (recipes == 0) 0 else highest_recipe + 1);
    errdefer allocator.free(cooking_experience);
    @memset(cooking_experience, 0);
    for (self.recipes) |entry| if (entry) |recipe| {
        cooking_experience[recipe.index] = recipe.experience;
    };
    const crafting_count = try reader.takeInt(u32, .big);
    var measure = reader;
    var alternatives: usize = 0;
    for (0..crafting_count) |_| {
        _ = try measure.take(2);
        const ingredients = try measure.takeByte();
        if (ingredients == 0 or ingredients > 9) return error.InvalidCraftingRecipe;
        _ = try string(&measure);
        _ = try measure.takeInt(u32, .big);
        for (0..ingredients) |_| {
            const count = try measure.takeInt(u16, .big);
            alternatives = try std.math.add(usize, alternatives, count);
            for (0..count) |_| _ = try string(&measure);
        }
    }
    self.crafting = try allocator.alloc(Craft, crafting_count);
    self.alternatives = try allocator.alloc(u32, alternatives);
    var offset: usize = 0;
    for (self.crafting) |*craft| {
        const width = try reader.takeByte();
        const height = try reader.takeByte();
        const count = try reader.takeByte();
        const output = try itemKind(try string(&reader));
        const amount = try reader.takeInt(u32, .big);
        if (width > 3 or height > 3 or (width == 0) != (height == 0) or (width != 0 and width * height != count) or amount == 0 or amount > 99) return error.InvalidCraftingRecipe;
        craft.* = .{ .width = width, .height = height, .count = count, .output = output, .amount = @intCast(amount) };
        for (craft.ingredients[0..count]) |*ingredient| {
            const length = try reader.takeInt(u16, .big);
            ingredient.* = .{ .offset = @intCast(offset), .count = length };
            for (self.alternatives[offset..][0..length]) |*kind| kind.* = try itemKind(try string(&reader));
            offset += length;
        }
    }
    std.debug.assert(offset == self.alternatives.len);
    if (reader.seek != snapshot.len) return error.InvalidRecipeSnapshot;
    return .{ .cooking_experience = cooking_experience, .recipes = self.recipes, .fuels = self.fuels, .crafting = self.crafting, .alternatives = self.alternatives };
}

fn itemKind(name: []const u8) !u32 {
    return @intCast(registry.itemId(name) orelse return error.UnknownRecipeItem);
}

fn string(reader: *std.Io.Reader) ![]const u8 {
    return reader.take(try reader.takeInt(u16, .big));
}
