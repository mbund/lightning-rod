const std = @import("std");
const lightning_rod = @import("lightning_rod");
const block_store = lightning_rod.blocks;
const entity_store = lightning_rod.entities;
const geometry = lightning_rod.geometry;
const input_store = lightning_rod.inputs;
const player_store = lightning_rod.players;
const Packets = lightning_rod.Packets;
const paging = @import("vanilla_persistence.zig");

pub const BeginResidency = struct {
    pub const id = "minecraft:begin_chunk_residency";
    pub const Configuration = struct {};
    pub const Dependencies = struct { blocks: *block_store.Blocks };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*BeginResidency {
        const self = try allocator.create(BeginResidency);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *BeginResidency, _: std.mem.Allocator) void {
        self.deps.blocks.beginResidentTickets();
    }
};

pub const EndResidency = struct {
    pub const id = "minecraft:end_chunk_residency";
    pub const Configuration = struct {};
    pub const Dependencies = struct { blocks: *block_store.Blocks };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*EndResidency {
        const self = try allocator.create(EndResidency);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *EndResidency, _: std.mem.Allocator) void {
        _ = self.deps.blocks.evictUnticketedChunks();
    }
};

pub const ChunkResidency = struct {
    pub const id = "minecraft:chunk_residency";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        blocks: *block_store.Blocks,
        players: *player_store.Players,
        living: *entity_store.LivingEntities,
        items: *entity_store.ItemEntities,
        inputs: *input_store.Inputs,
        paging: *paging.Persistence,
        outputs: *Packets,
    };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*ChunkResidency {
        const self = try allocator.create(ChunkResidency);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *ChunkResidency, _: std.mem.Allocator) void {
        self.ticketPlayers();
        self.ticketLivingEntities();
        self.ticketItemEntities();
        self.admitBlockInteractions();
    }

    fn ticketPlayers(self: *ChunkResidency) void {
        for (self.deps.players.activeSlots()) |slot| {
            const player = &self.deps.players.records[slot];
            self.ticketNeighborhood(player.world, chunkForPosition(player.position));
        }
    }

    fn ticketLivingEntities(self: *ChunkResidency) void {
        const entities = &self.deps.living.entities;
        for (entities.active_indices[0..entities.active_count]) |index| {
            const position = geometry.Vec3{
                .x = entities.position_x[index],
                .y = entities.position_y[index],
                .z = entities.position_z[index],
            };
            self.ticketNeighborhood(entities.worlds[index], chunkForPosition(position));
        }
    }

    fn ticketItemEntities(self: *ChunkResidency) void {
        for (self.deps.items.active_indices[0..self.deps.items.active_count]) |index| {
            const position = geometry.Vec3{
                .x = self.deps.items.position_x[index],
                .y = self.deps.items.position_y[index],
                .z = self.deps.items.position_z[index],
            };
            self.ticketNeighborhood(self.deps.items.worlds[index], chunkForPosition(position));
        }
    }

    fn ticketNeighborhood(
        self: *ChunkResidency,
        world: lightning_rod.world_identity.Handle,
        center: geometry.ChunkPos,
    ) void {
        const offsets = [_]geometry.ChunkPos{
            .{ .x = 0, .z = 0 },
            .{ .x = 0, .z = -1 },
            .{ .x = -1, .z = 0 },
            .{ .x = 1, .z = 0 },
            .{ .x = 0, .z = 1 },
            .{ .x = -1, .z = -1 },
            .{ .x = 1, .z = -1 },
            .{ .x = -1, .z = 1 },
            .{ .x = 1, .z = 1 },
        };
        for (offsets) |offset| {
            const chunk = geometry.ChunkPos{
                .x = center.x +| offset.x,
                .z = center.z +| offset.z,
            };
            if (!self.deps.blocks.ticketResidentChunk(world, chunk))
                _ = self.deps.paging.request(world, chunk);
        }
    }

    fn admitBlockInteractions(self: *ChunkResidency) void {
        for (self.deps.inputs.block_requests[0..self.deps.inputs.block_request_count]) |*request| {
            if (request.handled or (self.deps.blocks.residentChunk(request.world, geometry.chunkForBlock(request.pos)) != null and
                self.deps.blocks.residentChunk(request.world, geometry.chunkForBlock(request.against_pos)) != null)) continue;
            request.handled = true;
            self.deps.outputs.block_correction(.{ .slot = request.slot, .pos = request.pos });
            self.deps.outputs.block_correction(.{ .slot = request.slot, .pos = request.against_pos });
            self.deps.outputs.inventory_changed(request.slot);
        }
        for (self.deps.players.activeSlots()) |slot| {
            const intent = self.deps.inputs.blockDigIntent(slot) orelse continue;
            const world = self.deps.players.records[slot].world;
            if (self.deps.blocks.residentChunk(world, geometry.chunkForBlock(intent.pos)) != null) continue;
            self.deps.inputs.rejectBlockDig(slot);
            self.deps.outputs.block_correction(.{ .slot = slot, .pos = intent.pos });
        }
    }
};

fn chunkForPosition(position: geometry.Vec3) geometry.ChunkPos {
    return .{
        .x = geometry.chunkCoord(geometry.blockCoord(position.x)),
        .z = geometry.chunkCoord(geometry.blockCoord(position.z)),
    };
}
