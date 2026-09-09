const game_data = @import("lightning_rod").game_data;
const std = @import("std");

pub const Recipes = struct {
    pub const id = "minecraft:recipes";
    pub const Configuration = struct {};

    pub fn init(allocator: std.mem.Allocator, _: Configuration) !*Recipes {
        const self = try allocator.create(Recipes);
        self.* = .{};
        return self;
    }

    pub fn craft(_: *const Recipes, grid: []const i32, width: u8, height: u8) ?game_data.CraftResult {
        return game_data.craft(grid, width, height);
    }

    pub fn smelt(_: *const Recipes, item_id: i32) ?game_data.SmeltResult {
        return game_data.smelt(item_id);
    }

    pub fn fuelTicks(_: *const Recipes, item_id: i32) u16 {
        return game_data.fuelTicks(item_id);
    }
};
