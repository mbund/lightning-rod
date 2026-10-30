const std = @import("std");
const vanilla = @import("vanilla");
const game_data = @import("game_data");

pub const SilkSpawners = struct {
    pub const id = "example:silk_spawners";
    pub const Configuration = struct {};
    pub const Dependencies = struct { loot: *vanilla.Loot, mining: *vanilla.Mining.Registry };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*SilkSpawners {
        // Vanilla spawners bypass enchantment effects when awarding mining XP.
        var experience = deps.mining.get(@intCast(game_data.registry.blockStateId("minecraft:spawner").?)).experience;
        experience.enchantments = true;
        try deps.mining.addDefinitions(&.{.{ .name = "minecraft:spawner", .experience = experience }});
        try deps.loot.addTables(&.{.{ .name = "minecraft:blocks/spawner", .table = .{ .pools = &.{.{
            .conditions = &.{.{ .tool = .{ .enchantments = &.{.{ .names = &.{"minecraft:silk_touch"}, .minimum = 1 }} } }},
            .entries = &.{.{ .kind = .{ .item = @intCast(game_data.registry.itemId("minecraft:spawner").?) } }},
        }} } }});
        return allocator.create(SilkSpawners);
    }
};
