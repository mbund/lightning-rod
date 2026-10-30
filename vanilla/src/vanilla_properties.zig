const std = @import("std");
const game_data = @import("game_data");
const Properties = @import("item_registry.zig").Properties;

pub fn items(allocator: std.mem.Allocator) ![]const Properties {
    const result = try allocator.alloc(Properties, game_data.registry.items.len);
    for (result, game_data.registry.items) |*value, item| value.* = .{ .stack_size = item.stack_size, .durability = @intCast(item.max_durability) };
    return result;
}

pub fn equipment(name: []const u8) u8 {
    if (!std.mem.startsWith(u8, name, "minecraft:")) return 0;
    const local = name["minecraft:".len..];
    for ([_][]const u8{ "leather_", "golden_", "chainmail_", "iron_", "diamond_", "netherite_" }) |material| {
        if (!std.mem.startsWith(u8, local, material)) continue;
        const kind = local[material.len..];
        if (std.mem.eql(u8, kind, "helmet")) return 5;
        if (std.mem.eql(u8, kind, "chestplate")) return 4;
        if (std.mem.eql(u8, kind, "leggings")) return 3;
        if (std.mem.eql(u8, kind, "boots")) return 2;
    }
    if (std.mem.eql(u8, local, "turtle_helmet") or std.mem.eql(u8, local, "carved_pumpkin") or std.mem.endsWith(u8, local, "_head") or std.mem.endsWith(u8, local, "_skull")) return 5;
    if (std.mem.eql(u8, local, "elytra")) return 4;
    if (std.mem.eql(u8, local, "shield")) return 1;
    return 0;
}
