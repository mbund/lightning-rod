//! What each mob species is: its entity type, dimensions and default attributes from the
//! snapshot, and the constants its vanilla class hard codes.

const std = @import("std");
const game_data = @import("game_data");
const mob = @import("mob.zig");

const registry = game_data.registry;

pub const Attribute = enum {
    max_health,
    movement_speed,
    follow_range,
    tempt_range,
    step_height,
    gravity,
    jump_strength,
    safe_fall_distance,
    fall_damage_multiplier,
    water_movement_efficiency,
    movement_efficiency,
    knockback_resistance,
    armor,
    armor_toughness,
    oxygen_bonus,
    scale,
    burning_time,
};

pub const Traits = struct {
    entity_type: u32,
    width: f32,
    height: f32,
    eye_height: f32,
    baby_width: f32,
    baby_height: f32,
    baby_eye_height: f32,
    fire_immune: bool,
    tracking_range: u8,
    update_interval: u32,
    track_deltas: bool,
    attributes: [@typeInfo(Attribute).@"enum".field_names.len]f64,
    ambient_interval: i32,
    sound_volume: f32,

    pub fn attribute(self: *const Traits, which: Attribute) f64 {
        return self.attributes[@backingInt(which)];
    }
};

/// Attribute.getDefaultValue for attributes an entity type does not list.
fn defaultValue(which: Attribute) f64 {
    return switch (which) {
        .max_health => 20,
        .movement_speed => 0.7,
        .follow_range => 32,
        .tempt_range => 10,
        .step_height => 0.6,
        .gravity => 0.08,
        .jump_strength => 0.42,
        .safe_fall_distance => 3,
        .fall_damage_multiplier => 1,
        .water_movement_efficiency => 0,
        .movement_efficiency => 0,
        .knockback_resistance => 0,
        .armor => 0,
        .armor_toughness => 0,
        .oxygen_bonus => 0,
        .scale => 1,
        .burning_time => 1,
    };
}

fn attributeId(name: []const u8) u16 {
    @setEvalBranchQuota(1_000_000);
    for (registry.named_registries) |named| {
        if (!std.mem.eql(u8, named.name, "minecraft:attribute")) continue;
        for (named.entries, 0..) |entry, index| if (std.mem.eql(u8, entry, name)) return @intCast(index);
    }
    unreachable;
}

pub fn traits(species: mob.Species) Traits {
    const name = switch (species) {
        .cow => "minecraft:cow",
    };
    const entity_type: u32 = @intCast(registry.entityId(name).?);
    const entity = game_data.physics.entityType(entity_type);
    var result: Traits = .{
        .entity_type = entity_type,
        .width = entity.width,
        .height = entity.height,
        .eye_height = entity.eye_height,
        .baby_width = entity.width * 0.5,
        .baby_height = entity.height * 0.5,
        // AbstractCow.BABY_DIMENSIONS sets its own eye height.
        .baby_eye_height = 0.665,
        .fire_immune = entity.fire_immune,
        .tracking_range = entity.tracking_range,
        .update_interval = entity.update_interval,
        .track_deltas = entity.track_deltas,
        .attributes = undefined,
        // Animal.getAmbientSoundInterval and AbstractCow.getSoundVolume.
        .ambient_interval = 120,
        .sound_volume = 0.4,
    };
    inline for (@typeInfo(Attribute).@"enum".field_names, 0..) |field, index| {
        const id = comptime attributeId("minecraft:" ++ field);
        result.attributes[index] = game_data.physics.attribute(entity_type, id) orelse defaultValue(@field(Attribute, field));
    }
    return result;
}

test "cows have vanilla's dimensions and attributes" {
    const cow = traits(.cow);
    try std.testing.expectEqual(@as(f32, 0.9), cow.width);
    try std.testing.expectEqual(@as(f32, 1.4), cow.height);
    try std.testing.expectEqual(@as(f64, 10), cow.attribute(.max_health));
    try std.testing.expectEqual(@as(f64, @as(f32, 0.2)), cow.attribute(.movement_speed));
    try std.testing.expectEqual(@as(f64, 16), cow.attribute(.follow_range));
    try std.testing.expectEqual(@as(f64, 0.6), cow.attribute(.step_height));
    try std.testing.expectEqual(@as(u8, 10), cow.tracking_range);
    try std.testing.expectEqual(@as(u32, 3), cow.update_interval);
}
