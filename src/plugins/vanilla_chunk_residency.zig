const std = @import("std");
const lightning_rod = @import("lightning_rod");
const block_store = lightning_rod.blocks;
const entity_store = lightning_rod.entities;
const geometry = lightning_rod.geometry;
const input_store = lightning_rod.inputs;
const player_store = lightning_rod.players;
const Packets = lightning_rod.Packets;

pub const ChunkResidency = struct {
    pub const id = "minecraft:chunk_residency";

    blocks: *block_store.Blocks,
    players: *player_store.Players,
    living: *entity_store.LivingEntities,
    items: *entity_store.ItemEntities,
    inputs: *input_store.Inputs,
    outputs: *Packets,

    pub fn create(
        allocator: std.mem.Allocator,
        blocks: *block_store.Blocks,
        players: *player_store.Players,
        living: *entity_store.LivingEntities,
        items: *entity_store.ItemEntities,
        inputs: *input_store.Inputs,
        outputs: *Packets,
    ) !*ChunkResidency {
        const self = try allocator.create(ChunkResidency);
        self.* = .{
            .blocks = blocks,
            .players = players,
            .living = living,
            .items = items,
            .inputs = inputs,
            .outputs = outputs,
        };
        return self;
    }

    pub fn tick(self: *ChunkResidency, _: std.mem.Allocator) void {
        self.blocks.beginResidentTickets();
        self.ticketPlayers();
        self.ticketLivingEntities();
        self.ticketItemEntities();
        _ = self.blocks.evictUnticketedChunks();
        self.materializePlayerNeighborhoods();
        self.admitBlockInteractions();
    }

    fn ticketPlayers(self: *ChunkResidency) void {
        for (self.players.activeSlots()) |slot| {
            const player = &self.players.records[slot];
            self.ticketNeighborhood(player.world, chunkForPosition(player.position));
        }
    }

    fn ticketLivingEntities(self: *ChunkResidency) void {
        const entities = &self.living.entities;
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
        for (self.items.active_indices[0..self.items.active_count]) |index| {
            const position = geometry.Vec3{
                .x = self.items.position_x[index],
                .y = self.items.position_y[index],
                .z = self.items.position_z[index],
            };
            self.ticketNeighborhood(self.items.worlds[index], chunkForPosition(position));
        }
    }

    fn ticketNeighborhood(
        self: *ChunkResidency,
        world: lightning_rod.world_identity.Handle,
        center: geometry.ChunkPos,
    ) void {
        const offsets = [_]i32{ -1, 0, 1 };
        for (offsets) |z| {
            for (offsets) |x| {
                _ = self.blocks.ticketResidentChunk(world, .{
                    .x = center.x +| x,
                    .z = center.z +| z,
                });
            }
        }
    }

    fn materializePlayerNeighborhoods(self: *ChunkResidency) void {
        for (self.players.activeSlots()) |slot| {
            const player = &self.players.records[slot];
            const center = chunkForPosition(player.position);
            const offsets = [_]i32{ -1, 0, 1 };
            for (offsets) |z| {
                for (offsets) |x| {
                    self.materialize(slot, player.world, .{
                        .x = center.x +| x,
                        .z = center.z +| z,
                    });
                }
            }
        }
    }

    fn materialize(
        self: *ChunkResidency,
        slot: u16,
        world: lightning_rod.world_identity.Handle,
        chunk: geometry.ChunkPos,
    ) void {
        if (self.blocks.ticketResidentChunk(world, chunk)) return;
        const prepared = self.outputs.prepareChunkData(slot, chunk) catch return;
        if (prepared == .missing and !self.outputs.generateChunkData(slot, chunk)) return;
        _ = self.blocks.ticketResidentChunk(world, chunk);
    }

    fn admitBlockInteractions(self: *ChunkResidency) void {
        for (self.inputs.block_requests[0..self.inputs.block_request_count]) |*request| {
            if (request.handled or (self.blocks.residentChunk(request.world, geometry.chunkForBlock(request.pos)) != null and
                self.blocks.residentChunk(request.world, geometry.chunkForBlock(request.against_pos)) != null)) continue;
            request.handled = true;
            self.outputs.block_correction(.{ .slot = request.slot, .pos = request.pos });
            self.outputs.block_correction(.{ .slot = request.slot, .pos = request.against_pos });
            self.outputs.inventory_changed(request.slot);
        }
        for (self.players.activeSlots()) |slot| {
            const intent = self.inputs.blockDigIntent(slot) orelse continue;
            const world = self.players.records[slot].world;
            if (self.blocks.residentChunk(world, geometry.chunkForBlock(intent.pos)) != null) continue;
            self.inputs.rejectBlockDig(slot);
            self.outputs.block_correction(.{ .slot = slot, .pos = intent.pos });
        }
    }
};

fn chunkForPosition(position: geometry.Vec3) geometry.ChunkPos {
    return .{
        .x = geometry.chunkCoord(geometry.blockCoord(position.x)),
        .z = geometry.chunkCoord(geometry.blockCoord(position.z)),
    };
}
