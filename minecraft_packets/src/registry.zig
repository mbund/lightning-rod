const std = @import("std");

/// The particles the server sends, each found by name in a release's particle registry.
pub const Particle = enum { sweep_attack, damage_indicator, crit, enchanted_hit, happy_villager, soul_fire_flame, wax_on, wax_off };

pub const Registry = struct {
    /// Wire ids by Particle, absent ones negative. A mapping built by hand has none.
    particles: []const i32 = &.{},
    entities: []const i32,
    items: []const i32,
    blocks: []const i32,
    block_states: []const i32,
    block_state_bits: u8,
    sounds: []const i32,
    effects: []const i32,
    attributes: []const i32,

    pub fn forVersion(comptime Version: type) Registry {
        return .{
            .particles = comptime particleIds(Version),
            .entities = Version.Registry.canonical_entity_to_wire,
            .items = Version.Registry.canonical_item_to_wire,
            .blocks = Version.Registry.canonical_block_to_wire,
            .block_states = Version.Registry.canonical_block_state_to_wire,
            .block_state_bits = Version.Registry.block_state_bits,
            .sounds = Version.Registry.canonical_sound_to_wire,
            .effects = Version.Registry.canonical_effect_to_wire,
            .attributes = Version.Registry.canonical_attribute_to_wire,
        };
    }

    pub fn particleId(self: Registry, particle: Particle) !i32 {
        return lookup(self.particles, @backingInt(particle));
    }

    pub fn entityId(self: Registry, canonical: i32) !i32 {
        return lookup(self.entities, canonical);
    }

    pub fn itemId(self: Registry, canonical: i32) !i32 {
        return lookup(self.items, canonical);
    }

    pub fn blockId(self: Registry, canonical: i32) !i32 {
        return lookup(self.blocks, canonical);
    }

    pub fn blockState(self: Registry, canonical: i32) !i32 {
        return lookup(self.block_states, canonical);
    }

    pub fn soundId(self: Registry, canonical: i32) !i32 {
        return lookup(self.sounds, canonical);
    }

    pub fn effectId(self: Registry, canonical: i32) !i32 {
        return lookup(self.effects, canonical);
    }

    pub fn attributeId(self: Registry, canonical: i32) !i32 {
        return lookup(self.attributes, canonical);
    }
};

fn particleIds(comptime Version: type) []const i32 {
    @setEvalBranchQuota(100_000);
    const all = std.enums.values(Particle);
    var ids: [all.len]i32 = undefined;
    for (all, &ids) |particle, *id| id.* = Version.Registry.particleId("minecraft:" ++ @tagName(particle)) orelse -1;
    const final = ids;
    return &final;
}

fn lookup(mapping: []const i32, canonical: i32) error{UnsupportedRegistryEntry}!i32 {
    if (canonical < 0 or canonical >= mapping.len) return error.UnsupportedRegistryEntry;
    const mapped = mapping[@intCast(canonical)];
    if (mapped < 0) return error.UnsupportedRegistryEntry;
    std.debug.assert(mapped >= 0);
    return mapped;
}
