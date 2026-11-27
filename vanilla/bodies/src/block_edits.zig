//! What bodies do to the blocks they meet, as every kind of body does it: a block destroyed
//! without drops, and a cauldron lowered under something burning. The shared block effects ask
//! these of every kind's host.

const std = @import("std");
const game_data = @import("game_data");
const chunks = @import("chunks");
const Players = @import("players").players.Players;
const world_effects = @import("vanilla_world").world_effects;
const Levels = @import("levels.zig").Levels;

pub const BlockEdits = struct {
    pub const id = "minecraft:body_block_edits";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        chunks: *chunks.Chunks,
        players: *Players,
        levels: *Levels,
    };

    deps: Dependencies,
    effects: world_effects.Effects,
    cauldron: u16,
    water_cauldron: [2]u16,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*BlockEdits {
        const self = try allocator.create(BlockEdits);
        self.* = .{
            .deps = deps,
            .effects = try .init(allocator, deps.players),
            .cauldron = @intCast(game_data.registry.blockStateId("minecraft:cauldron").?),
            .water_cauldron = .{
                @intCast(game_data.registry.blockStateId("minecraft:water_cauldron[level=1]").?),
                @intCast(game_data.registry.blockStateId("minecraft:water_cauldron[level=2]").?),
            },
        };
        return self;
    }

    /// Level.destroyBlock without drops: the block's break effect, then air.
    pub fn destroyBlock(self: *BlockEdits, world: u32, position: [3]i32) !void {
        const level = self.deps.levels.level(world);
        const state = try level.state(position[0], position[1], position[2]);
        if (game_data.physics.get(state).air) return;
        self.effects.worldEvent(world, .{ .x = position[0], .y = position[1], .z = position[2] }, 2001, state);
        try self.deps.chunks.setBlock(world, .{ .x = position[0], .y = position[1], .z = position[2] }, level.air);
    }

    /// LayeredCauldronBlock.handleEntityOnFireInside: something burning takes a level of water,
    /// and powder snow turns to water a level lower.
    pub fn lowerCauldron(self: *BlockEdits, world: u32, position: [3]i32) !void {
        const level = self.deps.levels.level(world);
        const entry = level.blocks.get(try level.state(position[0], position[1], position[2]));
        if (entry.flags.level == 0) return;
        const remaining = entry.flags.level - 1;
        const lowered = if (remaining == 0) self.cauldron else self.water_cauldron[remaining - 1];
        try self.deps.chunks.setBlock(world, .{ .x = position[0], .y = position[1], .z = position[2] }, lowered);
    }
};
