const lightning_rod = @import("lightning_rod");
const input_store = lightning_rod.inputs;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const geometry = lightning_rod.geometry;
const std = @import("std");
const test_state = lightning_rod.test_support.state;
const core_exchange = lightning_rod.core_exchange;
const registry = lightning_rod.registry_data;
const block_writer = lightning_rod.block_writer;
const leaf_behavior = @import("../vanilla/leaf_behavior.zig");
const Packets = lightning_rod.Packets;
const diagnostics = lightning_rod.diagnostics;
const world_identity = lightning_rod.world_identity;

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
        inputs: *input_store.Inputs,
        outputs: *Packets,
    };

    scheduled: []LeafUpdate = &.{},
    scheduled_count: usize = 0,
    next: []LeafUpdate = &.{},
    next_count: usize = 0,
    next_generation: u32 = 1,
    next_lookup: []LeafUpdateLookupEntry = &.{},
    watched: []struct {
        world: world_identity.Handle,
        pos: geometry.BlockPos,
        old_state: i32,
    } = &.{},
    watched_count: usize = 0,
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*LeafDistance {
        const self = try allocator.create(LeafDistance);
        self.* = .{ .deps = deps };
        self.scheduled = try allocator.alloc(LeafUpdate, max_leaf_distance_updates);
        self.next = try allocator.alloc(LeafUpdate, max_leaf_distance_updates);
        self.next_lookup = try allocator.alloc(LeafUpdateLookupEntry, leaf_update_lookup_slots);
        self.watched = try allocator.alloc(@TypeOf(self.watched[0]), deps.inputs.block_requests.len);
        @memset(self.next_lookup, .{});
        self.next_generation = 1;
        return self;
    }

    pub fn tick(self: *LeafDistance, _: std.mem.Allocator) void {
        const blocks = self.deps.blocks;
        const inputs = self.deps.inputs;
        const outputs = self.deps.outputs;
        self.capture(blocks, inputs);
        self.updateScheduled(blocks, outputs);
    }

    fn capture(self: *LeafDistance, blocks: *block_store.Blocks, inputs: *const input_store.Inputs) void {
        self.watched_count = 0;
        const count = @min(inputs.block_request_count, self.watched.len);
        for (inputs.block_requests[0..count]) |request| {
            self.watched[self.watched_count] = .{ .world = request.world, .pos = request.pos, .old_state = blocks.blockAt(request.world, request.pos) };
            self.watched_count += 1;
        }
    }

    fn updateScheduled(self: *LeafDistance, blocks: *block_store.Blocks, outputs: *Packets) void {
        self.next_count = 0;
        self.next_generation +%= 1;
        if (self.next_generation == 0) {
            @memset(self.next_lookup, .{});
            self.next_generation = 1;
        }
        const writer = block_writer.Writer.init(blocks, outputs);
        for (self.scheduled[0..self.scheduled_count]) |update| self.updateLeafDistance(blocks, update, writer);
        for (self.watched[0..self.watched_count]) |watched| {
            if (blocks.blockAt(watched.world, watched.pos) == watched.old_state) continue;
            if (leafDistance(blocks.blockAt(watched.world, watched.pos)) != null) self.scheduleLeafUpdate(watched.world, watched.pos);
            self.scheduleNeighborLeaves(blocks, watched.world, watched.pos);
        }
        self.scheduled_count = self.next_count;
        @memcpy(self.scheduled[0..self.next_count], self.next[0..self.next_count]);
    }

    test "oak leaf distance follows logs and disconnected leaves become decay candidates" {
        @setEvalBranchQuota(20_000);
        const log = registry.blockStateId("minecraft:oak_log[axis=y]").?;
        const disconnected = registry.blockStateId("minecraft:oak_leaves[distance=7,persistent=false,waterlogged=false]").?;
        const connected = registry.blockStateId("minecraft:oak_leaves[distance=1,persistent=false,waterlogged=false]").?;
        const persistent = registry.blockStateId("minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]").?;
        try std.testing.expect(leaf_behavior.isDecayingOak(disconnected));
        try std.testing.expect(!leaf_behavior.isDecayingOak(connected));
        try std.testing.expect(!leaf_behavior.isDecayingOak(persistent));
        const placed = player_store.playerPlacedBlockState(disconnected);
        try std.testing.expectEqual(
            registry.blockStateId("minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]").?,
            placed,
        );

        const simulation = try std.testing.allocator.create(test_state.State);
        defer std.testing.allocator.destroy(simulation);
        try simulation.init(std.testing.allocator, 7);
        defer simulation.deinit();
        var plugin: LeafDistance = .{ .deps = undefined };
        var state_storage = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer state_storage.deinit();
        plugin.next = try state_storage.allocator().alloc(LeafUpdate, max_leaf_distance_updates);
        plugin.next_lookup = try state_storage.allocator().alloc(LeafUpdateLookupEntry, leaf_update_lookup_slots);
        @memset(plugin.next_lookup, .{});
        var input: lightning_rod.inputs.Inputs = undefined;
        var players: lightning_rod.players.Players = undefined;
        var living: lightning_rod.entities.LivingEntities = undefined;
        var items: lightning_rod.entities.ItemEntities = undefined;
        var containers: lightning_rod.players.Containers = undefined;
        var output = Packets{
            .deps = .{
                .inputs = &input,
                .blocks = &simulation.blocks,
                .players = &players,
                .containers = &containers,
                .living = &living,
                .items = &items,
                .worlds = simulation.worlds,
                .sessions = undefined,
            },
            .config = .{},
            .input = try core_exchange.InputBatch.init(std.testing.allocator, 8, 128),
        };
        defer output.input.deinit(std.testing.allocator);
        const blocks = block_writer.Writer.init(&simulation.blocks, &output);
        const log_pos = geometry.BlockPos{ .x = 0, .y = 100, .z = 0 };
        const leaf_pos = geometry.BlockPos{ .x = 1, .y = 100, .z = 0 };
        try std.testing.expect(try simulation.blocks.setBlock(simulation.world, log_pos, log));
        try std.testing.expect(try simulation.blocks.setBlock(simulation.world, leaf_pos, disconnected));
        plugin.updateLeafDistance(&simulation.blocks, .{ .world = simulation.world, .pos = leaf_pos }, blocks);
        try std.testing.expectEqual(connected, simulation.blocks.blockAt(simulation.world, leaf_pos));
        try std.testing.expectEqual(@as(?u8, 1), leaf_behavior.connectedDistance(&simulation.blocks, simulation.world, leaf_pos));

        try std.testing.expect(try simulation.blocks.setBlock(simulation.world, log_pos, registry.block_air_default_state));
        plugin.updateLeafDistance(&simulation.blocks, .{ .world = simulation.world, .pos = leaf_pos }, blocks);
        try std.testing.expectEqual(disconnected, simulation.blocks.blockAt(simulation.world, leaf_pos));
        try std.testing.expectEqual(@as(?u8, null), leaf_behavior.connectedDistance(&simulation.blocks, simulation.world, leaf_pos));
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

    fn scheduleLeafUpdate(self: *LeafDistance, world: world_identity.Handle, pos: geometry.BlockPos) void {
        const mask = self.next_lookup.len - 1;
        var probe = leafUpdateHash(world, pos);
        for (0..self.next_lookup.len) |_| {
            const entry = &self.next_lookup[probe & mask];
            if (entry.generation != self.next_generation) {
                entry.* = .{ .generation = self.next_generation, .world = world, .pos = pos };
                break;
            }
            if (entry.world.eql(world) and std.meta.eql(entry.pos, pos)) return;
            probe += 1;
        } else diagnostics.panic("leaf update lookup capacity exhausted", &.{});
        if (self.next_count == self.next.len) return;
        self.next[self.next_count] = .{ .world = world, .pos = pos };
        self.next_count += 1;
    }

    fn scheduleNeighborLeaves(self: *LeafDistance, blocks: *const block_store.Blocks, world: world_identity.Handle, pos: geometry.BlockPos) void {
        for (leaf_directions) |direction| {
            const neighbor = offsetBlock(pos, direction);
            const neighbor_state = blocks.blockAtIfResident(world, neighbor) orelse continue;
            if (leafDistance(neighbor_state) != null) self.scheduleLeafUpdate(world, neighbor);
        }
    }

    fn updateLeafDistance(self: *LeafDistance, block_world: *block_store.Blocks, update: LeafUpdate, writer: block_writer.Writer) void {
        const pos = update.pos;
        const old_state = block_world.blockAt(update.world, pos);
        const old_distance = leafDistance(old_state) orelse return;
        var new_distance: u8 = 7;
        for (leaf_directions) |direction| {
            const neighbor = offsetBlock(pos, direction);
            const neighbor_state = block_world.blockAtIfResident(update.world, neighbor) orelse return;
            const neighbor_distance: u8 = if (isLogState(neighbor_state)) 0 else leafDistance(neighbor_state) orelse 7;
            new_distance = @min(new_distance, neighbor_distance +| 1);
            if (new_distance == 1) break;
        }
        if (new_distance == old_distance) return;
        const new_state = withLeafDistance(old_state, new_distance);
        if (writer.set(update.world, pos, new_state) catch false) {
            self.scheduleNeighborLeaves(block_world, update.world, pos);
        }
    }
};
