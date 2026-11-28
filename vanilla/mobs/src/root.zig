//! Mobs: vanilla's mob bodies, pathfinding, goals and the species registry every mob plugin, as the
//! cow's and the sheep's, registers with.
const std = @import("std");

pub const mth = @import("vanilla_bodies").mth;
pub const java_random = @import("vanilla_bodies").java_random;
pub const mob_blocks = @import("vanilla_bodies").mob_blocks;
pub const shape_classes = @import("vanilla_bodies").shape_classes;
pub const body = @import("vanilla_bodies").body;
pub const mob = @import("mob.zig");
pub const species = @import("species.zig");
pub const living = @import("living.zig");
pub const mob_tick = @import("mob_tick.zig");
pub const ai = @import("ai.zig");
pub const goals = @import("goals.zig");
pub const navigation = @import("navigation.zig");
pub const block_effects = @import("block_effects.zig");
pub const mobs = @import("mobs.zig");
pub const herd = @import("herd.zig");
pub const mob_replication = @import("mob_replication.zig");
pub const spawn_eggs = @import("spawn_eggs.zig");
pub const pathfinding = @import("pathfinding.zig");
pub const senses = @import("senses.zig");
pub const random_positions = @import("random_positions.zig");
pub const damage = @import("damage.zig");
pub const melee = @import("melee.zig");
pub const projectiles = @import("projectiles.zig");
pub const projectile_replication = @import("projectile_replication.zig");
pub const ranged = @import("ranged.zig");
pub const projectile_store = @import("projectile_store.zig");
pub const mob_interaction = @import("mob_interaction.zig");
pub const boat = @import("boat.zig");
pub const boats = @import("boats.zig");
pub const boat_items = @import("boat_items.zig");
pub const boat_replication = @import("boat_replication.zig");

test {
    std.testing.refAllDecls(@This());
}

comptime {
    // Plugins and their functions compile only where referenced, so reference the entry points.
    _ = &mobs.Mobs.init;
    _ = &mobs.Mobs.tickRun;
    _ = &mobs.Mobs.checkpoint;
    _ = &mobs.Mobs.spawn;
    _ = &mob_replication.MobReplication.init;
    _ = &mob_replication.MobReplication.tick;
    _ = &spawn_eggs.SpawnEggs.init;
    _ = &mob_interaction.MobInteraction.init;
    _ = &melee.Melee.init;
    _ = &melee.Melee.tick;
    _ = &projectiles.Projectiles.init;
    _ = &projectiles.Projectiles.tickRun;
    _ = &ranged.Ranged.init;
    _ = &boats.Boats.init;
    _ = &boats.Boats.tickRun;
    _ = &boats.Boats.checkpoint;
    _ = &boat_items.BoatItems.init;
    _ = &boat_replication.BoatReplication.init;
    _ = &boat_replication.BoatReplication.tick;
}
