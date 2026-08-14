const std = @import("std");
const lightning_rod = @import("lightning_rod");
const goals = @import("../vanilla/animal_goals.zig");
const interaction = @import("../vanilla/animal_interaction.zig");
const entity_store = lightning_rod.entities;
const input_store = lightning_rod.inputs;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const world_random = lightning_rod.random;
const registry = lightning_rod.registry_data;
const Packets = lightning_rod.Packets;

const cow_food = [_]i32{registry.item_wheat_id};
const breeding_cooldown = 6_000;
const baby_age = -24_000;
const milk_bucket_id = blk: {
    @setEvalBranchQuota(100_000);
    break :blk registry.itemId("minecraft:milk_bucket").?;
};

pub const CowAi = struct {
    pub const id = "minecraft:cow_ai";

    state: goals.State = .{},
    random: *world_random.Random,
    blocks: *block_store.Blocks,
    players: *player_store.Players,
    living: *entity_store.LivingEntities,
    items: *entity_store.ItemEntities,
    inputs: *input_store.Inputs,
    packets: *Packets,

    pub fn create(allocator: std.mem.Allocator, random: *world_random.Random, blocks: *block_store.Blocks, players: *player_store.Players, living: *entity_store.LivingEntities, items: *entity_store.ItemEntities, inputs: *input_store.Inputs, packets: *Packets) !*CowAi {
        const self = try allocator.create(CowAi);
        self.* = .{ .random = random, .blocks = blocks, .players = players, .living = living, .items = items, .inputs = inputs, .packets = packets };
        try self.state.init(allocator);
        return self;
    }

    pub fn tick(self: *CowAi, _: std.mem.Allocator) void {
        const random = self.random;
        const blocks = self.blocks;
        const players = self.players;
        const living = self.living;
        const items = self.items;
        const inputs = self.inputs;
        const packets = self.packets;
        self.processInteractions(random, blocks, players, living, items, inputs, packets);
        var context = goals.initContext(&self.state, blocks, players, living);
        const entities = &living.entities;
        const count = entities.active_count;
        for (entities.active_indices[0..count]) |living_index| {
            const index: usize = living_index;
            if (entities.dead[index] or entities.entity_types[index] != .cow) continue;
            self.tickCow(&context, random, packets, index);
        }
    }

    fn tickCow(
        self: *CowAi,
        context: *goals.Context,
        random: *world_random.Random,
        packets: *Packets,
        index: usize,
    ) void {
        const entities = &context.living.entities;
        if (!goals.isEntityTicking(context, entities, index)) {
            goals.stopNavigation(context.living, index);
            entities.jump_requested[index] = false;
            return;
        }
        if (self.state.generation[index] != entities.generations[index]) self.state.resetEntity(entities, index);
        const previous_yaw = entities.yaw[index];
        const previous_pitch = entities.pitch[index];
        const previous_head_yaw = entities.head_yaw[index];
        goals.tickLifecycle(entities, index);
        self.emitAmbient(context, random, packets, index);
        if (goals.isWater(context.blocks, entities, index) and entities.random[index].nextFloat() < 0.8)
            entities.jump_requested[index] = true;
        if ((entities.age[index] & 1) == 0) self.tickGoals(context, random, packets, index);
        entities.jump_requested[index] = entities.jump_requested[index] or goals.tickNavigation(context.living, index);
        entities.pose_dirty[index] = entities.pose_dirty[index] or entities.yaw[index] != previous_yaw or
            entities.pitch[index] != previous_pitch or entities.head_yaw[index] != previous_head_yaw;
    }

    fn tickGoals(
        self: *CowAi,
        context: *goals.Context,
        random: *world_random.Random,
        packets: *Packets,
        index: usize,
    ) void {
        if (self.state.temptation_cooldown[index] != 0) self.state.temptation_cooldown[index] -= 1;
        self.selectGoal(context, index);
        self.tickSelectedGoal(context, random, packets, index);
        goals.tickLookGoals(context, index, self.state.move_goal[index] == .mate or self.state.move_goal[index] == .tempt);
    }

    fn tickSelectedGoal(
        self: *CowAi,
        context: *goals.Context,
        random: *world_random.Random,
        packets: *Packets,
        index: usize,
    ) void {
        const entities = &context.living.entities;
        switch (self.state.move_goal[index]) {
            .none, .panic, .wander => {},
            .mate => {
                const mate = self.state.target[index];
                goals.lookAt(entities, index, entities.position_x[mate], entities.position_y[mate] + 0.7, entities.position_z[mate]);
                _ = goals.beginPath(context, index, goals.entityBlockPosition(entities, mate), 1, 0);
                self.state.goal_ticks[index] += 1;
                if (self.state.goal_ticks[index] >= 30 and goals.distanceSquared(entities, index, mate) < 9 and index < mate)
                    self.spawnBaby(context, random, packets, index, mate);
            },
            .tempt => {
                const player = &context.players.records[self.state.target[index]];
                goals.lookAt(entities, index, player.position.x, player.position.y + 1.62, player.position.z);
                if (goals.distanceSquaredToPlayer(entities, index, player) < 6.25)
                    goals.stopNavigation(context.living, index)
                else
                    _ = goals.beginPath(context, index, goals.playerBlockPosition(player), 1.25, 0);
            },
            .follow_parent => self.tickFollowParent(context, index),
        }
    }

    fn tickFollowParent(self: *CowAi, context: *goals.Context, index: usize) void {
        if (self.state.repath_ticks[index] != 0) {
            self.state.repath_ticks[index] -= 1;
            return;
        }
        const parent = self.state.target[index];
        _ = goals.beginPath(context, index, goals.entityBlockPosition(&context.living.entities, parent), 1.25, 0);
        self.state.repath_ticks[index] = 4;
    }

    fn spawnBaby(
        self: *CowAi,
        context: *goals.Context,
        random: *world_random.Random,
        packets: *Packets,
        first: usize,
        second: usize,
    ) void {
        const entities = &context.living.entities;
        const child = context.living.spawn(random, context.blocks, entities.worlds[first], .cow, .{
            .x = (entities.position_x[first] + entities.position_x[second]) * 0.5,
            .y = @max(entities.position_y[first], entities.position_y[second]),
            .z = (entities.position_z[first] + entities.position_z[second]) * 0.5,
        }, true, false) catch return;
        entities.breeding_age[child.index] = baby_age;
        entities.breeding_age[first] = breeding_cooldown;
        entities.breeding_age[second] = breeding_cooldown;
        entities.love_ticks[first] = 0;
        entities.love_ticks[second] = 0;
        goals.stopGoal(context, first);
        goals.stopGoal(context, second);
        packets.living_status(.{ .index = @intCast(first), .status = 18 });
        packets.living_status(.{ .index = @intCast(second), .status = 18 });
        packets.living_spawned(child.index);
        _ = self;
    }

    fn selectGoal(self: *CowAi, context: *goals.Context, index: usize) void {
        const entities = &context.living.entities;
        if (!goals.goalStillValid(context, index, &cow_food)) goals.stopGoal(context, index);
        if (self.state.move_goal[index] == .panic or goals.startPanicGoal(context, index)) return;
        if (self.selectMate(context, index)) return;
        if (self.selectTemptation(context, index)) return;
        if (self.state.move_goal[index] == .follow_parent) return;
        if (entities.baby[index]) {
            const parent = goals.nearestParent(entities, index);
            if (parent != goals.no_index and goals.distanceSquared(entities, index, parent) >= 9) {
                goals.stopGoal(context, index);
                goals.startGoal(context, index, .follow_parent, parent);
                return;
            }
        }
        if (self.state.move_goal[index] == .wander) return;
        if (entities.random[index].nextIntBounded(60) != 0) return;
        const target = goals.randomLandTarget(context, index, 10, 7) orelse return;
        goals.startGoal(context, index, .wander, goals.no_index);
        _ = goals.beginPath(context, index, target, 1, 0);
    }

    fn selectMate(self: *CowAi, context: *goals.Context, index: usize) bool {
        if (self.state.move_goal[index] == .mate) return true;
        const entities = &context.living.entities;
        if (entities.love_ticks[index] == 0 or entities.breeding_age[index] != 0) return false;
        const mate = goals.nearestMate(context, index);
        if (mate == goals.no_index) return false;
        goals.stopGoal(context, index);
        goals.startGoal(context, index, .mate, mate);
        return true;
    }

    fn selectTemptation(self: *CowAi, context: *goals.Context, index: usize) bool {
        if (self.state.move_goal[index] == .tempt) {
            const player = goals.nearestTemptingPlayer(context, index, &cow_food);
            if (player != goals.no_index) {
                self.state.target[index] = player;
                return true;
            }
            goals.stopGoal(context, index);
        }
        if (self.state.temptation_cooldown[index] != 0) return false;
        const player = goals.nearestTemptingPlayer(context, index, &cow_food);
        if (player == goals.no_index) return false;
        goals.stopGoal(context, index);
        goals.startGoal(context, index, .tempt, player);
        return true;
    }

    fn processInteractions(
        self: *CowAi,
        random: *world_random.Random,
        blocks: *block_store.Blocks,
        players: *player_store.Players,
        living: *entity_store.LivingEntities,
        items: *entity_store.ItemEntities,
        inputs: *input_store.Inputs,
        packets: *Packets,
    ) void {
        _ = self;
        const entities = &living.entities;
        for (players.activeSlots()) |slot| {
            const pending = &inputs.living_interactions[slot];
            if (!pending.active) continue;
            const index = entities.indexForEntityId(pending.entity_id) orelse continue;
            if (entities.entity_types[index] != .cow) continue;
            const request = pending.*;
            pending.* = .{};
            if (entities.dead[index] or !interaction.inReach(&players.records[slot], entities, index)) continue;
            if (!entities.baby[index] and milk(random, blocks, players, items, packets, slot, request.hand)) continue;
            const stack = interaction.heldStack(&players.records[slot], request.hand);
            if (stack.isEmpty() or !goals.containsItem(&cow_food, stack.item_id)) continue;
            interaction.feed(players, living, packets, slot, index, request.hand);
        }
    }

    fn milk(
        random: *world_random.Random,
        blocks: *block_store.Blocks,
        players: *player_store.Players,
        items: *entity_store.ItemEntities,
        packets: *Packets,
        slot: u16,
        hand: i32,
    ) bool {
        const player = &players.records[slot];
        const stack = interaction.heldStack(player, hand);
        if (stack.item_id != registry.item_bucket_id or stack.count == 0) return false;
        if (player.gamemode == .creative) return true;
        if (stack.count == 1) stack.* = player_store.stackForItem(milk_bucket_id, 1) else {
            stack.count -= 1;
            var milk_stack = player_store.stackForItem(milk_bucket_id, 1);
            player_store.moveStackInto(&player.hotbar, &milk_stack);
            if (!milk_stack.isEmpty()) player_store.moveStackInto(&player.main_inventory, &milk_stack);
            if (!milk_stack.isEmpty()) dropMilk(random, blocks, player, items, packets, milk_stack);
            packets.inventory_changed(slot);
            return true;
        }
        interaction.emitHeldStack(players, packets, slot, hand);
        return true;
    }

    fn dropMilk(
        random: *world_random.Random,
        blocks: *block_store.Blocks,
        player: *const player_store.CorePlayer,
        items: *entity_store.ItemEntities,
        packets: *Packets,
        stack: player_store.HotbarStack,
    ) void {
        const dropped = items.spawn(random, blocks, player.world, player.position, .{}, stack, entity_store.block_drop_pickup_delay_ticks) catch return;
        packets.item_spawned(@intCast(dropped));
    }

    fn emitAmbient(
        self: *CowAi,
        context: *goals.Context,
        random: *world_random.Random,
        packets: *Packets,
        index: usize,
    ) void {
        _ = self;
        const entities = &context.living.entities;
        const before = entities.ambient_sound_chance[index];
        entities.ambient_sound_chance[index] +%= 1;
        if (entities.random[index].nextIntBounded(1000) >= before) return;
        entities.ambient_sound_chance[index] = -80;
        const base_pitch: f32 = if (entities.baby[index]) 1.5 else 1.0;
        packets.living_sound(.{
            .index = @as(u16, @intCast(index)),
            .sound = .cow_ambient,
            .volume = 0.4,
            .pitch = base_pitch + (entities.random[index].nextFloat() - entities.random[index].nextFloat()) * 0.2,
            .seed = @as(i64, @bitCast(random.random.next())),
        });
    }
};

test "cow food is wheat" {
    try std.testing.expect(goals.containsItem(&cow_food, registry.item_wheat_id));
    try std.testing.expect(!goals.containsItem(&cow_food, registry.item_carrot_id));
}
