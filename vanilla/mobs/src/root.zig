//! Mobs: vanilla's mob bodies, pathfinding, goals and the cow.
const std = @import("std");

pub const mth = @import("mth.zig");
pub const java_random = @import("java_random.zig");
pub const mob_blocks = @import("mob_blocks.zig");
pub const shape_classes = @import("shape_classes.zig");
pub const body = @import("body.zig");
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
pub const grid = @import("grid.zig");
pub const mob_replication = @import("mob_replication.zig");
pub const spawn_eggs = @import("spawn_eggs.zig");
pub const pathfinding = @import("pathfinding.zig");
pub const senses = @import("senses.zig");
pub const random_positions = @import("random_positions.zig");
pub const damage = @import("damage.zig");
pub const mob_interaction = @import("mob_interaction.zig");

test {
    std.testing.refAllDecls(@This());
}

comptime {
    // Plugins and their functions compile only where referenced, so reference the entry points.
    _ = &mobs.Mobs.init;
    _ = &mobs.Mobs.tick;
    _ = &mobs.Mobs.checkpoint;
    _ = &mobs.Mobs.spawn;
    _ = &mob_replication.MobReplication.init;
    _ = &mob_replication.MobReplication.tick;
    _ = &spawn_eggs.SpawnEggs.init;
    _ = &mob_interaction.MobInteraction.init;
    _ = &mob_interaction.MobInteraction.tick;
}
