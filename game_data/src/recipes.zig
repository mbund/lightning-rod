const std = @import("std");

pub const Recipe = struct {
    index: u32 = 0,
    output: u32,
    count: u16,
    ticks: u32,
    experience: f32,
};

pub const Ingredient = struct { offset: u32 = 0, count: u16 = 0 };

pub const Craft = struct {
    width: u8,
    height: u8,
    count: u8,
    ingredients: [9]Ingredient = @splat(.{}),
    output: u32,
    amount: u16,
};

pub const Fuel = struct {
    ticks: u32 = 0,
    remainder: ?u32 = null,
};

pub const Table = struct {
    recipes: []const ?Recipe,
    cooking_experience: []const f32 = &.{},
    fuels: []const Fuel,
    crafting: []const Craft,
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
                    } else if (ingredient.count != 0) valid = false;
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
