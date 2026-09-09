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
const active_chunks = @import("../vanilla/active_chunks.zig");

const pig_food = [_]i32{
    registry.item_carrot_id,
    registry.item_potato_id,
    registry.item_beetroot_id,
};
const pig_tempting_items = [_]i32{
    registry.item_carrot_id,
    registry.item_potato_id,
    registry.item_beetroot_id,
    registry.item_carrot_on_a_stick_id,
};
const breeding_cooldown = 6_000;
const baby_age = -24_000;

pub const PigAi = struct {
    pub const id = "minecraft:pig_ai";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        random: *world_random.Random,
        blocks: *block_store.Blocks,
        players: *player_store.Players,
        active: *active_chunks.ActiveChunks,
        living: *entity_store.LivingEntities,
        inputs: *input_store.Inputs,
        packets: *Packets,
    };

    state: goals.State = .{},
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*PigAi {
        const self = try allocator.create(PigAi);
        self.* = .{ .deps = deps };
        try self.state.init(allocator, deps.living.entities.active.len);
        return self;
    }

    pub fn tick(self: *PigAi, _: std.mem.Allocator) void {
        const random = self.deps.random;
        const blocks = self.deps.blocks;
        const players = self.deps.players;
        const living = self.deps.living;
        const inputs = self.deps.inputs;
        const packets = self.deps.packets;
        self.processInteractions(players, living, inputs, packets);
        var context = goals.initContext(&self.state, blocks, players, self.deps.active, living);
        const entities = &living.entities;
        const count = entities.active_count;
        for (entities.active_indices[0..count]) |living_index| {
            const index: usize = living_index;
            if (entities.dead[index] or entities.entity_types[index] != .pig) continue;
            self.tickPig(&context, random, packets, index);
        }
    }

    fn tickPig(
        self: *PigAi,
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
        if (goals.isWater(context.blocks, entities, index) and entities.random[index].nextFloat() < 0.8)
            entities.jump_requested[index] = true;
        if ((entities.age[index] & 1) == 0) self.tickGoals(context, random, packets, index);
        entities.jump_requested[index] = entities.jump_requested[index] or goals.tickNavigation(context.living, index);
        entities.pose_dirty[index] = entities.pose_dirty[index] or entities.yaw[index] != previous_yaw or
            entities.pitch[index] != previous_pitch or entities.head_yaw[index] != previous_head_yaw;
    }

    fn tickGoals(
        self: *PigAi,
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
        self: *PigAi,
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

    fn tickFollowParent(self: *PigAi, context: *goals.Context, index: usize) void {
        if (self.state.repath_ticks[index] != 0) {
            self.state.repath_ticks[index] -= 1;
            return;
        }
        const parent = self.state.target[index];
        _ = goals.beginPath(context, index, goals.entityBlockPosition(&context.living.entities, parent), 1.25, 0);
        self.state.repath_ticks[index] = 4;
    }

    fn spawnBaby(
        self: *PigAi,
        context: *goals.Context,
        random: *world_random.Random,
        packets: *Packets,
        first: usize,
        second: usize,
    ) void {
        const entities = &context.living.entities;
        const child = context.living.spawn(random, context.blocks, entities.worlds[first], .pig, .{
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

    fn selectGoal(self: *PigAi, context: *goals.Context, index: usize) void {
        const entities = &context.living.entities;
        if (!goals.goalStillValid(context, index, &pig_tempting_items)) goals.stopGoal(context, index);
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

    fn selectMate(self: *PigAi, context: *goals.Context, index: usize) bool {
        if (self.state.move_goal[index] == .mate) return true;
        const entities = &context.living.entities;
        if (entities.love_ticks[index] == 0 or entities.breeding_age[index] != 0) return false;
        const mate = goals.nearestMate(context, index);
        if (mate == goals.no_index) return false;
        goals.stopGoal(context, index);
        goals.startGoal(context, index, .mate, mate);
        return true;
    }

    fn selectTemptation(self: *PigAi, context: *goals.Context, index: usize) bool {
        if (self.state.move_goal[index] == .tempt) {
            const player = goals.nearestTemptingPlayer(context, index, &pig_tempting_items);
            if (player != goals.no_index) {
                self.state.target[index] = player;
                return true;
            }
            goals.stopGoal(context, index);
        }
        if (self.state.temptation_cooldown[index] != 0) return false;
        const player = goals.nearestTemptingPlayer(context, index, &pig_tempting_items);
        if (player == goals.no_index) return false;
        goals.stopGoal(context, index);
        goals.startGoal(context, index, .tempt, player);
        return true;
    }

    fn processInteractions(
        self: *PigAi,
        players: *player_store.Players,
        living: *entity_store.LivingEntities,
        inputs: *input_store.Inputs,
        packets: *Packets,
    ) void {
        _ = self;
        const entities = &living.entities;
        for (players.activeSlots()) |slot| {
            const pending = &inputs.living_interactions[slot];
            if (!pending.active) continue;
            const index = entities.indexForEntityId(pending.entity_id) orelse continue;
            if (entities.entity_types[index] != .pig) continue;
            const request = pending.*;
            pending.* = .{};
            if (entities.dead[index] or !interaction.inReach(&players.records[slot], entities, index)) continue;
            const stack = interaction.heldStack(&players.records[slot], request.hand);
            if (stack.isEmpty() or !goals.containsItem(&pig_food, stack.item_id)) continue;
            interaction.feed(players, living, packets, slot, index, request.hand);
        }
    }
};

test "pig breeding and temptation items are distinct" {
    try std.testing.expect(goals.containsItem(&pig_food, registry.item_carrot_id));
    try std.testing.expect(goals.containsItem(&pig_food, registry.item_potato_id));
    try std.testing.expect(goals.containsItem(&pig_food, registry.item_beetroot_id));
    try std.testing.expect(!goals.containsItem(&pig_food, registry.item_carrot_on_a_stick_id));
    try std.testing.expect(goals.containsItem(&pig_tempting_items, registry.item_carrot_on_a_stick_id));
}
