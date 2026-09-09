const lightning_rod = @import("lightning_rod");
const std = @import("std");
const registry = lightning_rod.registry_data;
const chests_plugin = @import("vanilla_chests.zig");
const furnaces_plugin = @import("vanilla_furnaces.zig");
const hinged_blocks_plugin = @import("vanilla_hinged_blocks.zig");
const loot_plugin = @import("vanilla_block_loot.zig");
const leaf_behavior = @import("../vanilla/leaf_behavior.zig");

pub const BlockDestruction = struct {
    pub const id = "minecraft:block_destruction";
    pub const Configuration = struct {
        maximum_item_entities_per_operation: usize = 2_048,

        pub fn validate(self: Configuration) !void {
            if (self.maximum_item_entities_per_operation == 0)
                return error.InvalidDestructionCapacity;
        }
    };
    pub const Dependencies = struct {
        random: *lightning_rod.random.Random,
        blocks: *lightning_rod.blocks.Blocks,
        items: *lightning_rod.entities.ItemEntities,
        chests: *chests_plugin.Chests,
        furnaces: *furnaces_plugin.Furnaces,
        hinged_blocks: *hinged_blocks_plugin.HingedBlocks,
        loot: *loot_plugin.BlockLoot,
        outputs: *lightning_rod.Packets,
    };
    pub const Request = struct {
        world: lightning_rod.world_identity.Handle,
        position: lightning_rod.geometry.BlockPos,
        tool: lightning_rod.players.HotbarStack = .{},
        creative: bool = false,
    };

    deps: Dependencies,
    spawns: []lightning_rod.entities.ItemEntities.Spawn,
    spawned: []usize,
    chest_removals: []chests_plugin.Chests.Removal,
    furnace_removals: []furnaces_plugin.Furnaces.Removal,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, configuration: Configuration) !*BlockDestruction {
        try configuration.validate();
        const self = try allocator.create(BlockDestruction);
        self.* = .{
            .deps = deps,
            .spawns = try allocator.alloc(lightning_rod.entities.ItemEntities.Spawn, configuration.maximum_item_entities_per_operation),
            .spawned = try allocator.alloc(usize, configuration.maximum_item_entities_per_operation),
            .chest_removals = try allocator.alloc(chests_plugin.Chests.Removal, lightning_rod.mutations.maximum_writes),
            .furnace_removals = try allocator.alloc(furnaces_plugin.Furnaces.Removal, lightning_rod.mutations.maximum_writes),
        };
        return self;
    }

    pub fn destroy(
        self: *BlockDestruction,
        world: lightning_rod.world_identity.Handle,
        position: lightning_rod.geometry.BlockPos,
        tool: lightning_rod.players.HotbarStack,
        creative: bool,
    ) !bool {
        const requests = [_]Request{.{ .world = world, .position = position, .tool = tool, .creative = creative }};
        return try self.destroyMany(&requests) != 0;
    }

    pub fn destroyMany(self: *BlockDestruction, requests: []const Request) !usize {
        if (requests.len > lightning_rod.mutations.maximum_writes)
            return error.CausalChainLimit;
        var transaction = lightning_rod.mutations.Transaction.init(self.deps.blocks);
        var random_after_plan = self.deps.random.random;
        var spawn_count: usize = 0;
        var chest_count: usize = 0;
        var furnace_count: usize = 0;

        for (requests) |request| {
            if (transaction.staged(request.world, request.position) != null) continue;
            const current = self.deps.blocks.blockAtIfMaterialized(request.world, request.position) orelse
                return error.ChunkNotMaterialized;
            if (current == registry.block_air_default_state) continue;
            try transaction.prepare(request.world, request.position, registry.block_air_default_state);
            const block_id = registry.block_state_to_block[@intCast(current)];
            if (block_id == registry.block_chest_id) {
                const removal = self.deps.chests.prepareRemoval(request.world, request.position, current);
                if (removal.partner_position) |partner|
                    try transaction.prepare(request.world, partner, removal.partner_state);
                self.chest_removals[chest_count] = removal;
                chest_count += 1;
                try appendStacks(self.spawns, &spawn_count, request.world, request.position, &removal.items);
            } else if (block_id == registry.block_furnace_id) {
                const removal = self.deps.furnaces.prepareRemoval(request.world, request.position);
                self.furnace_removals[furnace_count] = removal;
                furnace_count += 1;
                try appendStacks(self.spawns, &spawn_count, request.world, request.position, &removal.items);
            }
            if (self.deps.hinged_blocks.removalPartner(request.world, request.position, current)) |partner|
                try transaction.prepare(request.world, partner, registry.block_air_default_state);
            if (!request.creative) {
                if (leaf_behavior.isOak(current)) {
                    const drops = leaf_behavior.rollOakDrops(&random_after_plan);
                    const stacks = leaf_behavior.oakDropStacks(drops);
                    try appendStacks(self.spawns, &spawn_count, request.world, request.position, &stacks);
                } else {
                    const drops = self.deps.loot.evaluate(current, request.tool);
                    try appendStacks(self.spawns, &spawn_count, request.world, request.position, drops.stacks[0..drops.count]);
                }
            }
        }
        if (transaction.count == 0) return 0;
        try transaction.reserve();
        for (self.spawns[0..spawn_count]) |spawn|
            try self.deps.items.validateSpawn(self.deps.blocks, spawn);
        var item_reservation = try self.deps.items.reserve(spawn_count);

        const changed = try transaction.commit();
        self.deps.random.random = random_after_plan;
        self.deps.items.commitReserved(&item_reservation, self.deps.random, self.spawns[0..spawn_count], self.spawned[0..spawn_count]);
        for (self.chest_removals[0..chest_count]) |removal| self.deps.chests.commitRemoval(removal);
        for (self.furnace_removals[0..furnace_count]) |removal| self.deps.furnaces.commitRemoval(removal);
        var changes: [lightning_rod.mutations.maximum_writes]lightning_rod.packet_args.BlockChanged = undefined;
        var change_count: usize = 0;
        for (0..transaction.count) |index| {
            if (!transaction.wasChanged(index)) continue;
            const write = transaction.writeAt(index);
            changes[change_count] = .{ .world = write.world, .pos = write.pos, .block_state = write.block_state };
            change_count += 1;
        }
        self.deps.outputs.blocksChanged(changes[0..change_count]);
        for (self.spawned[0..spawn_count]) |index| self.deps.outputs.item_spawned(@intCast(index));
        return changed;
    }
};

fn appendStacks(
    destination: []lightning_rod.entities.ItemEntities.Spawn,
    count: *usize,
    world: lightning_rod.world_identity.Handle,
    position: lightning_rod.geometry.BlockPos,
    stacks: []const lightning_rod.players.HotbarStack,
) !void {
    for (stacks) |stack| try appendStack(destination, count, world, position, stack);
}

fn appendStack(
    destination: []lightning_rod.entities.ItemEntities.Spawn,
    count: *usize,
    world: lightning_rod.world_identity.Handle,
    position: lightning_rod.geometry.BlockPos,
    stack: lightning_rod.players.HotbarStack,
) !void {
    if (stack.isEmpty()) return;
    if (count.* == destination.len) return error.DestructionItemLimit;
    destination[count.*] = .{
        .world = world,
        .position = lightning_rod.entities.blockDropPosition(position),
        .velocity = .{ .y = 0.1 },
        .stack = stack,
        .pickup_delay_ticks = lightning_rod.entities.block_drop_pickup_delay_ticks,
    };
    count.* += 1;
}

test "destruction staging reports its item bound before world mutation" {
    var destination: [1]lightning_rod.entities.ItemEntities.Spawn = undefined;
    var count: usize = 0;
    const stacks = [_]lightning_rod.players.HotbarStack{
        .{ .item_id = 1, .count = 1 },
        .{ .item_id = 2, .count = 1 },
    };
    try std.testing.expectError(
        error.DestructionItemLimit,
        appendStacks(&destination, &count, .{ .index = 0, .generation = 1 }, .{ .x = 0, .y = 64, .z = 0 }, &stacks),
    );
    try std.testing.expectEqual(@as(usize, 1), count);
}
