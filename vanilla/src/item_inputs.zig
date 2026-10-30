const std = @import("std");
const game_data = @import("game_data");
const recipes = @import("recipes.zig");
const Tags = @import("content_tags.zig").Tags;
const ids = @import("content_ids.zig");

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    tags: *const Tags,
    names: std.StringHashMapUnmanaged(u32),
    pub fn init(allocator: std.mem.Allocator, tags: *const Tags) !Resolver {
        return .{ .allocator = allocator, .tags = tags, .names = try ids.index(allocator, game_data.registry.item_names) };
    }
    pub fn resolve(self: *const Resolver, input: recipes.Input) ![]const u32 {
        var entries: std.ArrayList(u32) = .empty;
        try self.expand(input, &entries, 0);
        std.mem.sort(u32, entries.items, {}, std.sort.asc(u32));
        var count: usize = 0;
        for (entries.items) |entry| {
            if (count > 0 and entries.items[count - 1] == entry) continue;
            entries.items[count] = entry;
            count += 1;
        }
        return entries.items[0..count];
    }
    fn expand(self: *const Resolver, input: recipes.Input, entries: *std.ArrayList(u32), depth: usize) anyerror!void {
        if (depth == 64) return error.RecipeIngredientDepth;
        switch (input) {
            .item => |name| try entries.append(self.allocator, self.names.get(try ids.identifier(self.allocator, name)) orelse return error.UnknownRecipeItem),
            .tag => |name| try entries.appendSlice(self.allocator, self.tags.members(self.tags.find(try ids.identifier(self.allocator, name)) orelse return error.UnknownRecipeTag)),
            .alternatives => |alternatives| for (alternatives) |value| try self.expand(value, entries, depth + 1),
        }
    }
};
