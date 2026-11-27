//! The world as bodies read it, one for every kind that moves: copies of the sections they read,
//! the classes of their blocks, room to gather colliders in, and for each world a level with its
//! height, its border and the entities bodies collide with. Mobs, boats, items and orbs all read
//! through it, so a section one of them decoded the rest find decoded.

const std = @import("std");
const game_data = @import("game_data");
const chunks = @import("chunks");
const worlds = @import("worlds");
const Blocks = @import("vanilla_content").blocks.Blocks;
const WorldBorder = @import("vanilla_world").world_border.WorldBorder;
const body = @import("body.zig");
const mob_blocks = @import("mob_blocks.zig");
const EntityCollisions = @import("entity_collisions.zig").EntityCollisions;

pub const Levels = struct {
    pub const id = "minecraft:body_levels";
    pub const Configuration = struct {
        /// Sections held decoded at once.
        copies: u32 = 512,
    };
    pub const Dependencies = struct {
        chunks: *chunks.Chunks,
        worlds: *worlds.Worlds,
        block_definitions: *Blocks,
        /// The border bodies collide with, and the entities, where the server has them.
        world_border: ?*WorldBorder = null,
        collisions: ?*EntityCollisions = null,
    };

    deps: Dependencies,
    copies: *chunks.Copies,
    blocks: *mob_blocks.MobBlocks,
    /// Room to gather colliders in, which every move fills and leaves.
    colliders: *body.Colliders,
    air: u16,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Levels {
        const self = try allocator.create(Levels);
        const colliders = try allocator.create(body.Colliders);
        colliders.* = .{};
        self.* = .{
            .deps = deps,
            .copies = try chunks.Copies.init(allocator, deps.chunks, config.copies),
            .blocks = try mob_blocks.MobBlocks.init(allocator, deps.block_definitions),
            .colliders = colliders,
            .air = @intCast(game_data.registry.blockStateId("minecraft:air").?),
        };
        self.copies.mark(self.blocks.marks);
        return self;
    }

    /// The world as a body in it reads it.
    pub fn level(self: *Levels, world: u32) body.Level {
        const definition = self.deps.worlds.get(world).?;
        return .{
            .copies = self.copies,
            .blocks = self.blocks,
            .world = world,
            .minimum_y = definition.dimension.minimumSection() * 16,
            .height = @intCast(definition.dimension.sectionCount() * 16),
            .air = self.air,
            .border = if (self.deps.world_border) |border| border.bounds(world) else null,
            .colliders = self.colliders,
            .entities = if (self.deps.collisions) |collisions| collisions.source() else null,
        };
    }

    /// Copies of sections that were absent go at the tick's end, as generation may fill them.
    pub fn endTick(self: *Levels, _: bool) void {
        self.copies.endTick();
    }
};
