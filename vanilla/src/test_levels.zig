//! Item physics for tests, over levels of their own: the blocks of the test's chunks, read as
//! every body reads them.

const std = @import("std");
const chunks = @import("chunks");
const worlds = @import("worlds");
const storage = @import("storage");
const Blocks = @import("vanilla_content").blocks.Blocks;
const Levels = @import("vanilla_bodies").levels.Levels;
const ItemPhysics = @import("vanilla_item_entities").item_physics.ItemPhysics;
const BlockEdits = @import("vanilla_bodies").block_edits.BlockEdits;
const Players = @import("players").players.Players;

pub fn itemPhysics(allocator: std.mem.Allocator, blocks: *Blocks, terrain: *chunks.Chunks, dimensions: *worlds.Worlds) !*ItemPhysics {
    const levels = try Levels.init(allocator, .{}, .{ .chunks = terrain, .worlds = dimensions, .block_definitions = blocks });
    return ItemPhysics.init(allocator, .{ .blocks = blocks, .levels = levels });
}

/// A world of sixteen sections from y 0, the first the test makes.
pub fn testWorlds(allocator: std.mem.Allocator, space: storage.Space) !*worlds.Worlds {
    const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = space });
    _ = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
    return dimensions;
}

/// What bodies do to blocks, over the levels `physics` reads.
pub fn blockEdits(allocator: std.mem.Allocator, physics: *ItemPhysics, players: *Players) !*BlockEdits {
    const levels = physics.deps.levels;
    return BlockEdits.init(allocator, .{ .chunks = levels.deps.chunks, .players = players, .levels = levels });
}
