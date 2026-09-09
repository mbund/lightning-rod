const lightning_rod = @import("lightning_rod");
const block_store = lightning_rod.blocks;
const geometry = lightning_rod.geometry;
const std = @import("std");
const leaf_behavior = @import("../vanilla/leaf_behavior.zig");
const Packets = lightning_rod.Packets;
const world_identity = lightning_rod.world_identity;
const vanilla_persistence = @import("vanilla_persistence.zig");

const max_leaf_distance_updates = 4096;
const leaf_update_lookup_slots = max_leaf_distance_updates * 2;

const LeafUpdateLookupEntry = struct {
    generation: u32 = 0,
    world: world_identity.Handle = world_identity.invalid,
    pos: geometry.BlockPos = .{ .x = 0, .y = 0, .z = 0 },
};

const LeafUpdate = struct {
    world: world_identity.Handle,
    pos: geometry.BlockPos,
};

pub const LeafDistance = struct {
    pub const id = "minecraft:leaf_distance";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        blocks: *block_store.Blocks,
        materialization: *vanilla_persistence.Materializer,
        outputs: *Packets,
    };

    scheduled: []LeafUpdate = &.{},
    scheduled_count: usize = 0,
    next: []LeafUpdate = &.{},
    next_count: usize = 0,
    next_generation: u32 = 1,
    next_lookup: []LeafUpdateLookupEntry = &.{},
    observed_mutation_sequence: u64 = 0,
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*LeafDistance {
        const self = try allocator.create(LeafDistance);
        self.* = .{ .deps = deps };
        self.scheduled = try allocator.alloc(LeafUpdate, max_leaf_distance_updates);
        self.next = try allocator.alloc(LeafUpdate, max_leaf_distance_updates);
        self.next_lookup = try allocator.alloc(LeafUpdateLookupEntry, leaf_update_lookup_slots);
        @memset(self.next_lookup, .{});
        self.next_generation = 1;
        self.observed_mutation_sequence = deps.blocks.mutationCursor().sequence;
        return self;
    }

    pub fn tick(self: *LeafDistance, io: std.Io, _: std.mem.Allocator) lightning_rod.plugin_lifecycle.FatalError!void {
        self.next_count = 0;
        self.next_generation +%= 1;
        if (self.next_generation == 0) {
            @memset(self.next_lookup, .{});
            self.next_generation = 1;
        }
        var cursor = self.deps.blocks.mutationCursorFrom(self.observed_mutation_sequence);
        while (cursor.next(self.deps.blocks) catch return error.WorkingMemoryExceeded) |mutation| {
            if (leafDistance(mutation.block_state) != null)
                try self.scheduleLeafUpdate(mutation.world, mutation.pos);
            const previous: u8 = if (isLogState(mutation.previous_state)) 0 else leafDistance(mutation.previous_state) orelse 7;
            const current: u8 = if (isLogState(mutation.block_state)) 0 else leafDistance(mutation.block_state) orelse 7;
            if (previous != current) try self.scheduleNeighborLeaves(mutation.world, mutation.pos);
        }
        self.observed_mutation_sequence = cursor.sequence;
        for (self.scheduled[0..self.scheduled_count]) |update| try self.updateLeafDistance(io, update, self.deps.outputs);
        self.scheduled_count = self.next_count;
        std.mem.swap([]LeafUpdate, &self.scheduled, &self.next);
    }

    const leaf_directions = leaf_behavior.directions;
    const offsetBlock = leaf_behavior.offset;
    const leafDistance = leaf_behavior.distance;
    const withLeafDistance = leaf_behavior.withDistance;
    const isLogState = leaf_behavior.isSupport;
    fn leafUpdateHash(world: world_identity.Handle, pos: geometry.BlockPos) usize {
        var value: u64 = @as(u32, @bitCast(pos.x)) ^ @as(u32, @bitCast(world));
        value ^= @as(u64, @as(u16, @bitCast(pos.y))) << 32;
        value ^= @as(u64, @as(u32, @bitCast(pos.z))) *% 0x9e37_79b9;
        value ^= value >> 32;
        value *%= 0xd6e8_feb8_6659_fd93;
        value ^= value >> 32;
        return @intCast(value);
    }

    fn scheduleLeafUpdate(self: *LeafDistance, world: world_identity.Handle, pos: geometry.BlockPos) lightning_rod.plugin_lifecycle.FatalError!void {
        const mask = self.next_lookup.len - 1;
        var probe = leafUpdateHash(world, pos);
        for (0..self.next_lookup.len) |_| {
            const entry = &self.next_lookup[probe & mask];
            if (entry.generation != self.next_generation) {
                if (self.next_count == self.next.len) return error.WorkingMemoryExceeded;
                entry.* = .{ .generation = self.next_generation, .world = world, .pos = pos };
                break;
            }
            if (entry.world.eql(world) and std.meta.eql(entry.pos, pos)) return;
            probe += 1;
        } else return error.WorkingMemoryExceeded;
        self.next[self.next_count] = .{ .world = world, .pos = pos };
        self.next_count += 1;
    }

    fn scheduleNeighborLeaves(self: *LeafDistance, world: world_identity.Handle, pos: geometry.BlockPos) lightning_rod.plugin_lifecycle.FatalError!void {
        var neighbors: [leaf_directions.len]geometry.BlockPos = undefined;
        var states: [leaf_directions.len]?i32 = undefined;
        for (leaf_directions, 0..) |direction, index| neighbors[index] = offsetBlock(pos, direction);
        try self.deps.materialization.readStoredBlocks(world, &neighbors, &states);
        for (neighbors, states) |neighbor, neighbor_state| {
            const state = neighbor_state orelse {
                _ = self.deps.materialization.requestProjection(world, geometry.chunkForBlock(neighbor));
                continue;
            };
            if (leafDistance(state) != null) try self.scheduleLeafUpdate(world, neighbor);
        }
    }

    fn updateLeafDistance(self: *LeafDistance, io: std.Io, update: LeafUpdate, outputs: *Packets) lightning_rod.plugin_lifecycle.FatalError!void {
        const pos = update.pos;
        const old_state = try self.deps.materialization.readStoredBlock(update.world, pos) orelse {
            _ = self.deps.materialization.requestProjection(update.world, geometry.chunkForBlock(pos));
            try self.scheduleLeafUpdate(update.world, pos);
            return;
        };
        const old_distance = leafDistance(old_state) orelse return;
        var new_distance: u8 = 7;
        var neighbors: [leaf_directions.len]geometry.BlockPos = undefined;
        var states: [leaf_directions.len]?i32 = undefined;
        for (leaf_directions, 0..) |direction, index| neighbors[index] = offsetBlock(pos, direction);
        try self.deps.materialization.readStoredBlocks(update.world, &neighbors, &states);
        for (neighbors, states) |neighbor, neighbor_state| {
            const state = neighbor_state orelse {
                _ = self.deps.materialization.requestProjection(update.world, geometry.chunkForBlock(neighbor));
                try self.scheduleLeafUpdate(update.world, pos);
                return;
            };
            const neighbor_distance: u8 = if (isLogState(state)) 0 else leafDistance(state) orelse 7;
            new_distance = @min(new_distance, neighbor_distance +| 1);
            if (new_distance == 1) break;
        }
        if (new_distance == old_distance) return;
        const new_state = withLeafDistance(old_state, new_distance);
        const writes = [_]lightning_rod.chunk_storage.BlockWrite{.{ .position = pos, .state = new_state }};
        var mutations: [1]geometry.BlockMutation = undefined;
        const changed = self.deps.materialization.writeStoredBlocks(io, update.world, geometry.chunkForBlock(pos), &writes, &mutations) catch |err| switch (err) {
            error.ChunkMissing => {
                _ = self.deps.materialization.requestProjection(update.world, geometry.chunkForBlock(pos));
                try self.scheduleLeafUpdate(update.world, pos);
                return;
            },
            error.InvalidMutation, error.MutationCapacity => return error.WorkingMemoryExceeded,
            else => |remaining| return remaining,
        };
        if (changed == 0) return;
        outputs.blocksChanged(&.{.{ .world = update.world, .pos = pos, .block_state = new_state }});
        try self.scheduleNeighborLeaves(update.world, pos);
    }
};
