//! The damage types the server deals, and what the damage type registry's tags say of each, read
//! once each time the registries change rather than on every hurt.

const std = @import("std");
const ClientRegistries = @import("vanilla_content").client_registries.ClientRegistries;

const assert = std.debug.assert;

/// The damage types the server deals, by their names in the damage_type registry.
pub const DamageType = enum(u8) {
    generic,
    fall,
    in_wall,
    drown,
    on_fire,
    in_fire,
    campfire,
    lava,
    hot_floor,
    cactus,
    sweet_berry_bush,
    cramming,
    freeze,
    player_attack,
    stalagmite,
    out_of_world,
    generic_kill,
    mob_attack,
    thorns,
    arrow,
    trident,
    mace_smash,
};

/// What the registry's tags say of a damage type.
pub const Flags = packed struct(u16) {
    fire: bool = false,
    bypasses_cooldown: bool = false,
    no_impact: bool = false,
    no_knockback: bool = false,
    panic: bool = false,
    bypasses_invulnerability: bool = false,
    bypasses_armor: bool = false,
    bypasses_shield: bool = false,
    bypasses_effects: bool = false,
    bypasses_resistance: bool = false,
    bypasses_enchantments: bool = false,
    damages_helmet: bool = false,
    projectile: bool = false,
    padding: u3 = 0,
};

const count = @typeInfo(DamageType).@"enum".field_names.len;

pub const DamageTypes = struct {
    pub const id = "minecraft:damage_types";
    pub const Configuration = struct {};
    pub const Dependencies = struct { client: *ClientRegistries };

    deps: Dependencies,
    flags: [count]Flags,
    /// Ids in the registry players were sent, as damage packets name types.
    ids: [count]i32,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*DamageTypes {
        const self = try allocator.create(DamageTypes);
        self.* = .{ .deps = deps, .flags = @splat(.{}), .ids = @splat(0) };
        try self.read();
        try deps.client.registry.onChange(self, read);
        return self;
    }

    pub fn flagsOf(self: *const DamageTypes, damage_type: DamageType) Flags {
        return self.flags[@intFromEnum(damage_type)];
    }

    pub fn idOf(self: *const DamageTypes, damage_type: DamageType) i32 {
        return self.ids[@intFromEnum(damage_type)];
    }

    pub fn name(damage_type: DamageType) []const u8 {
        return switch (damage_type) {
            inline else => |tag| "minecraft:" ++ @tagName(tag),
        };
    }

    fn read(self: *DamageTypes) !void {
        self.flags = @splat(.{});
        self.ids = @splat(0);
        const registry = self.deps.client.client.get("minecraft:damage_type") orelse return;
        const Tag = struct { name: []const u8, flag: []const u8 };
        const tags = [_]Tag{
            .{ .name = "minecraft:is_fire", .flag = "fire" },
            .{ .name = "minecraft:bypasses_cooldown", .flag = "bypasses_cooldown" },
            .{ .name = "minecraft:no_impact", .flag = "no_impact" },
            .{ .name = "minecraft:no_knockback", .flag = "no_knockback" },
            .{ .name = "minecraft:panic_causes", .flag = "panic" },
            .{ .name = "minecraft:bypasses_invulnerability", .flag = "bypasses_invulnerability" },
            .{ .name = "minecraft:bypasses_armor", .flag = "bypasses_armor" },
            .{ .name = "minecraft:bypasses_shield", .flag = "bypasses_shield" },
            .{ .name = "minecraft:bypasses_effects", .flag = "bypasses_effects" },
            .{ .name = "minecraft:bypasses_resistance", .flag = "bypasses_resistance" },
            .{ .name = "minecraft:bypasses_enchantments", .flag = "bypasses_enchantments" },
            .{ .name = "minecraft:damages_helmet", .flag = "damages_helmet" },
            .{ .name = "minecraft:is_projectile", .flag = "projectile" },
        };
        inline for (@typeInfo(DamageType).@"enum".field_names, 0..) |field, index| {
            if (registry.id("minecraft:" ++ field)) |type_id| {
                self.ids[index] = @intCast(type_id);
                inline for (tags) |tag| {
                    if (registry.tags.find(tag.name)) |found| {
                        if (registry.tags.contains(found, type_id)) @field(self.flags[index], tag.flag) = true;
                    }
                }
            }
        }
        // The client's own registry has every type the server deals.
        assert(registry.id("minecraft:player_attack") != null);
    }
};
