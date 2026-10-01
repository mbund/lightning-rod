const std = @import("std");

pub const Registry = struct {
    entities: []const i32,
    items: []const i32,
    blocks: []const i32,
    block_states: []const i32,
    sounds: []const i32,
    effects: []const i32,
    attributes: []const i32,

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

fn lookup(mapping: []const i32, canonical: i32) error{UnsupportedRegistryEntry}!i32 {
    if (canonical < 0 or canonical >= mapping.len) return error.UnsupportedRegistryEntry;
    const mapped = mapping[@intCast(canonical)];
    if (mapped < 0) return error.UnsupportedRegistryEntry;
    std.debug.assert(mapped >= 0);
    return mapped;
}
