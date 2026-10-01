const std = @import("std");
const players = @import("players.zig");
const block_sync = @import("block_sync.zig");
const chunks = @import("chunks");
const worlds = @import("worlds");
const registry = @import("game_data").registry;
const BlockActions = @import("block_actions.zig").BlockActions;

const assert = std.debug.assert;

pub const Doors = struct {
    pub const id = "minecraft:doors";

    pub const Configuration = struct {};

    pub const Dependencies = struct {
        actions: *BlockActions,
        chunks: *chunks.Chunks,
        players: *players.Players,
        worlds: *worlds.Worlds,
        synchronization: *block_sync.BlockSynchronization,
    };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Doors {
        const self = try allocator.create(Doors);
        self.* = .{ .deps = deps };

        for (registry.blocks) |block| {
            const name = registry.blockStateName(block.default_state).?;
            if (std.mem.indexOf(u8, name, "_door[") == null) continue;
            assert(block.max_state - block.min_state == 63);

            for (0..64) |offset| {
                const state = registry.blockStateName(block.min_state + @as(i32, @intCast(offset))).?;
                assert(std.mem.indexOf(u8, state, ([_][]const u8{ "facing=north", "facing=south", "facing=west", "facing=east" })[offset / 16]) != null);
                assert(std.mem.indexOf(u8, state, if (offset & 8 == 0) "half=upper" else "half=lower") != null);
                assert(std.mem.indexOf(u8, state, if (offset & 4 == 0) "hinge=left" else "hinge=right") != null);
                assert(std.mem.indexOf(u8, state, if (offset & 2 == 0) "open=true" else "open=false") != null);
                assert(std.mem.indexOf(u8, state, if (offset & 1 == 0) "powered=true" else "powered=false") != null);
            }

            try deps.actions.register(.{
                .minimum = @intCast(block.min_state),
                .maximum = @intCast(block.max_state),
                .context = self,
                .apply = apply,
            });
        }

        return self;
    }

    fn apply(raw: *anyopaque, request: BlockActions.Request) !BlockActions.Result {
        const self: *Doors = @ptrCast(@alignCast(raw));
        const world = request.player.world;
        const block = registry.blocks[registry.block_state_to_block[request.state]];
        const minimum: u16 = @intCast(block.min_state);
        var offset = request.state - minimum;
        var bottom = request.position;

        if (request.action != .place and offset & 8 == 0) bottom.y -= 1;
        const top: chunks.Position = .{ .x = bottom.x, .y = bottom.y + 1, .z = bottom.z };
        const dimension = self.deps.worlds.get(world).?.dimension;
        const minimum_y = dimension.minimumSection() * 16;
        const maximum_y = minimum_y + @as(i32, @intCast(dimension.sectionCount() * 16));
        if (bottom.y < minimum_y or top.y >= maximum_y) {
            if (request.action != .remove) return .denied;
            try self.deps.chunks.setBlock(world, request.position, 0);
            return .applied;
        }

        if (request.action == .place) {
            self.deps.synchronization.correct(world, top);
            if (bottom.y == minimum_y) return .denied;

            const below = try self.deps.chunks.getBlock(world, .{ .x = bottom.x, .y = bottom.y - 1, .z = bottom.z });
            const support = registry.collisionLightFace(registry.block_state_collision_shape[below], 3);
            if (!std.mem.allEqual(u64, &support, std.math.maxInt(u64))) return .denied;

            const facing: usize = @intFromFloat(@mod(@floor(request.player.rotation.yaw / 90.0 + 0.5), 4));
            const directions = [_][2]i32{ .{ 0, 1 }, .{ -1, 0 }, .{ 0, -1 }, .{ 1, 0 } };
            const dx = directions[facing][0];
            const dz = directions[facing][1];
            var score: i8 = 0;
            var neighbors: [2]bool = .{ false, false };

            for (0..2) |side| {
                const sign: i32 = if (side == 0) 1 else -1;

                for (0..2) |height| {
                    const state = try self.deps.chunks.getBlock(world, .{
                        .x = bottom.x + dz * sign,
                        .y = bottom.y + @as(i32, @intCast(height)),
                        .z = bottom.z - dx * sign,
                    });
                    const shape = registry.collision_shapes[registry.block_state_collision_shape[state]];

                    if (shape.count == 1 and std.meta.eql(registry.collision_boxes[shape.offset], .{
                        .min_x = 0,
                        .min_y = 0,
                        .min_z = 0,
                        .max_x = 64,
                        .max_y = 64,
                        .max_z = 64,
                    })) score += if (side == 0) @as(i8, -1) else 1;
                    const info = registry.blocks[registry.block_state_to_block[state]];
                    neighbors[side] = neighbors[side] or (height == 0 and std.mem.indexOf(u8, registry.blockStateName(state).?, "_door[") != null and (state - @as(u16, @intCast(info.min_state))) & 8 != 0);
                }
            }

            const hit = request.hit.?;
            const x = @as(f64, @floatFromInt(hit.position.x - bottom.x)) + hit.cursor[0];
            const z = @as(f64, @floatFromInt(hit.position.z - bottom.z)) + hit.cursor[2];
            const right = if ((neighbors[0] and !neighbors[1]) or score > 0) true else if ((neighbors[1] and !neighbors[0]) or score < 0) false else (dx < 0 and z < 0.5) or (dx > 0 and z > 0.5) or (dz < 0 and x > 0.5) or (dz > 0 and x < 0.5);
            offset = ([_]u16{ 1, 2, 0, 3 })[facing] * 16 + 8 + @as(u16, @intFromBool(right)) * 4 + 3;
            const shape = registry.collision_shapes[registry.block_state_collision_shape[minimum + offset]];

            for (self.deps.players.records) |player| {
                if (player.handle == null or player.world != world or player.stage != .ready or player.gamemode == .spectator) continue;

                for (registry.collision_boxes[shape.offset..][0..shape.count]) |box| {
                    const bx: f64 = @floatFromInt(bottom.x);
                    const by: f64 = @floatFromInt(bottom.y);
                    const bz: f64 = @floatFromInt(bottom.z);
                    if (player.position.x + 0.3 > bx + @as(f64, @floatFromInt(box.min_x)) / 64 and player.position.x - 0.3 < bx + @as(f64, @floatFromInt(box.max_x)) / 64 and
                        player.position.z + 0.3 > bz + @as(f64, @floatFromInt(box.min_z)) / 64 and player.position.z - 0.3 < bz + @as(f64, @floatFromInt(box.max_z)) / 64 and
                        player.position.y + 1.8 > by and player.position.y < by + 2) return .denied;
                }
            }
        }

        const sections = [_]chunks.Section{ chunks.sectionAt(world, bottom), chunks.sectionAt(world, top) };
        const count: usize = if (std.meta.eql(sections[0], sections[1])) 1 else 2;
        var leases: [2]chunks.Lease = undefined;
        try self.deps.chunks.acquireMany(sections[0..count], leases[0..count]);
        defer for (leases[0..count]) |lease| lease.release();
        const lower = leases[0].get(chunks.localIndex(bottom));
        const upper = leases[count - 1].get(chunks.localIndex(top));

        switch (request.action) {
            .place => if (lower != 0 or upper != 0) return .denied,
            .use => {
                if (std.mem.startsWith(u8, registry.blockStateName(request.state).?, "minecraft:iron_door[")) return .pass;
                if (lower < minimum or lower > minimum + 63 or upper < minimum or upper > minimum + 63 or (lower - minimum) & 8 == 0 or (upper - minimum) & 8 != 0)
                    return .denied;
                offset = (lower - minimum) ^ 2;
            },
            .remove => {},
        }

        const edits = [_]chunks.BlockEdit{
            .{ .index = chunks.localIndex(bottom), .state = if (request.action == .remove) 0 else minimum + (offset | 8) },
            .{ .index = chunks.localIndex(top), .state = if (request.action == .remove) 0 else minimum + (offset & ~@as(u16, 8)) },
        };

        if (request.action == .remove and (lower < minimum or lower > minimum + 63 or upper < minimum or upper > minimum + 63)) {
            try self.deps.chunks.setBlock(world, request.position, 0);
        } else if (count == 1) {
            try self.deps.chunks.setBlocks(sections[0], &edits);
        } else {
            try self.deps.chunks.setBlocks(sections[0], edits[0..1]);
            try self.deps.chunks.setBlocks(sections[1], edits[1..2]);
        }

        return .applied;
    }
};
