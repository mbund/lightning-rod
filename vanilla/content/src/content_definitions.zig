const std = @import("std");
const ids = @import("content_ids.zig");
pub const Tag = @import("content_tags.zig").Definition;

pub const DimensionType = struct {
    name: []const u8,
    definition: Definition,

    pub const Light = union(enum) {
        constant: u4,
        uniform: struct { min_inclusive: u4, max_inclusive: u4 },
    };
    pub const Definition = struct {
        min_y: i32 = -64,
        height: u32 = 384,
        logical_height: u32 = 384,
        has_skylight: bool = true,
        has_ceiling: bool = false,
        ultrawarm: bool = false,
        natural: bool = true,
        coordinate_scale: f64 = 1,
        bed_works: bool = true,
        respawn_anchor_works: bool = false,
        infiniburn: []const u8 = "#minecraft:infiniburn_overworld",
        effects: []const u8 = "minecraft:overworld",
        ambient_light: f32 = 0,
        piglin_safe: bool = false,
        has_raids: bool = true,
        monster_spawn_light_level: Light = .{ .uniform = .{ .min_inclusive = 0, .max_inclusive = 7 } },
        monster_spawn_block_light_limit: u4 = 0,
        fixed_time: ?i64 = null,
        cloud_height: ?f32 = null,
    };

    pub fn validate(value: Definition) !void {
        if (@mod(value.min_y, 16) != 0 or value.min_y < -2032 or value.height < 16 or value.height > 4064 or
            @mod(value.height, 16) != 0 or @as(i64, value.min_y) + value.height > 2032 or value.logical_height > value.height or
            !std.math.isFinite(value.coordinate_scale) or value.coordinate_scale < 0.00001 or value.coordinate_scale > 30000000 or
            !std.math.isFinite(value.ambient_light) or value.ambient_light < 0 or value.ambient_light > 1) return error.InvalidDimension;
        if (value.cloud_height) |height| if (!std.math.isFinite(height)) return error.InvalidDimension;
        if (!std.mem.startsWith(u8, value.infiniburn, "#") or !ids.validName(value.infiniburn[1..]) or !ids.validName(value.effects)) return error.InvalidDimension;
        if (value.monster_spawn_light_level == .uniform) {
            const range = value.monster_spawn_light_level.uniform;
            if (range.min_inclusive > range.max_inclusive) return error.InvalidDimension;
        }
    }
};
