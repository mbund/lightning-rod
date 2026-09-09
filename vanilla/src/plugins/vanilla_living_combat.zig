const lightning_rod = @import("lightning_rod");
const entity_store = lightning_rod.entities;
const living_entities = lightning_rod.living_entities;
const input_store = lightning_rod.inputs;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const block_queries = lightning_rod.block_queries;
const geometry = lightning_rod.geometry;
const game_rules = lightning_rod.game_rules;
const world_random = lightning_rod.random;
const std = @import("std");
const world_limits = lightning_rod.world_limits;
const game_data = lightning_rod.game_data;
const collision = lightning_rod.collision;
const packet_args = lightning_rod.packet_args;
const vanilla_living_death = @import("vanilla_living_death.zig");
const Packets = lightning_rod.Packets;
const world_identity = lightning_rod.world_identity;
const vanilla_collision_projection = @import("vanilla_collision_projection.zig");

pub const LivingCombat = struct {
    pub const id = "minecraft:living_combat";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        deaths: *vanilla_living_death.LivingDeaths,
        random: *world_random.Random,
        rules: *game_rules.GameRules,
        blocks: *block_store.Blocks,
        collision_projection: *vanilla_collision_projection.CollisionProjection,
        players: *player_store.Players,
        living: *entity_store.LivingEntities,
        inputs: *input_store.Inputs,
        outputs: *Packets,
    };

    velocities: []packet_args.LivingVelocityChanged = &.{},
    velocity_count: usize = 0,
    hotbar_changes: []packet_args.HotbarChanged = &.{},
    hotbar_change_count: usize = 0,
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*LivingCombat {
        const self = try allocator.create(LivingCombat);
        self.* = .{ .deps = deps };
        self.velocities = try allocator.alloc(packet_args.LivingVelocityChanged, deps.players.records.len);
        self.hotbar_changes = try allocator.alloc(packet_args.HotbarChanged, deps.players.records.len);
        return self;
    }

    pub fn tick(self: *LivingCombat, _: std.mem.Allocator) void {
        self.run(self.deps.deaths, self.deps.random, self.deps.rules, self.deps.blocks, self.deps.collision_projection, self.deps.players, self.deps.living, self.deps.inputs, self.deps.outputs);
    }

    fn run(self: *LivingCombat, deaths: *vanilla_living_death.LivingDeaths, random: *world_random.Random, rules: *game_rules.GameRules, blocks: *block_store.Blocks, projection: *vanilla_collision_projection.CollisionProjection, players: *player_store.Players, living: *entity_store.LivingEntities, inputs: *input_store.Inputs, outputs: *Packets) void {
        self.velocity_count = 0;
        self.hotbar_change_count = 0;
        for (players.activeSlots()) |active_slot| {
            const slot: usize = active_slot;
            const pending = &inputs.living_attacks[slot];
            if (!pending.active) {
                @branchHint(.likely);
                continue;
            }
            const entity_id = pending.entity_id;
            pending.* = .{};
            const player = &players.records[slot];
            if (player.state != .play or player.gamemode == .spectator or player.health <= 0) continue;
            const living_index = targetInReach(players, living, slot, entity_id) orelse continue;
            const index: usize = living_index;
            const held = players.selectedHotbarStack(@intCast(slot));
            const raw_damage = game_data.cooldownScaledAttackDamage(held.item_id, player.last_attacked_ticks);
            player.last_attacked_ticks = 0;
            const accepted_damage = acceptedDamage(&living.entities, index, raw_damage);
            if (accepted_damage <= 0) continue;
            living.entities.health[index] = @max(0, living.entities.health[index] - accepted_damage);
            applyKnockback(&living.entities, index, player.position);
            reactToDamage(random, living, outputs, living_index, @intCast(slot));
            self.recordVelocity(&living.entities, living_index);
            outputs.living_metadata_changed(living_index);
            if (living.entities.entity_types[index] == .zombie)
                trySpawnZombieReinforcement(random, rules, blocks, projection, players, living, outputs, living_index, @intCast(slot));
            self.damageHeldItem(players, @intCast(slot));
            if (living.entities.health[index] == 0)
                _ = deaths.kill(living, living_index, .player_attack, @intCast(slot));
        }
    }

    fn targetInReach(players: *const player_store.Players, living_store: *const entity_store.LivingEntities, slot: usize, entity_id: i32) ?u16 {
        const living = &living_store.entities;
        const living_index = living.indexForEntityId(entity_id) orelse return null;
        const index: usize = living_index;
        if (living.dead[index] or living.health[index] <= 0) return null;
        const player = &players.records[slot];
        if (!living.worlds[index].eql(player.world)) return null;
        const eye = geometry.Vec3{ .x = player.position.x, .y = player.position.y + 1.62, .z = player.position.z };
        const half_width = @as(f64, living_entities.width(
            living.entity_types[index],
            living.baby[index],
        )) * 0.5;
        const height = living_entities.height(
            living.entity_types[index],
            living.baby[index],
        );
        const closest = geometry.Vec3{
            .x = std.math.clamp(eye.x, living.position_x[index] - half_width, living.position_x[index] + half_width),
            .y = std.math.clamp(eye.y, living.position_y[index], living.position_y[index] + height),
            .z = std.math.clamp(eye.z, living.position_z[index] - half_width, living.position_z[index] + half_width),
        };
        const dx = closest.x - eye.x;
        const dy = closest.y - eye.y;
        const dz = closest.z - eye.z;
        return if (dx * dx + dy * dy + dz * dz < 36) living_index else null;
    }

    fn acceptedDamage(living: *living_entities.Pool, index: usize, raw: f32) f32 {
        var accepted = raw;
        if (living.time_until_regen[index] > 10) {
            if (raw <= living.last_damage_taken[index]) return 0;
            accepted -= living.last_damage_taken[index];
        } else {
            living.last_damage_taken[index] = raw;
            living.time_until_regen[index] = 20;
        }
        const armor = living.armor[index];
        const toughness = living.armor_toughness[index];
        const reduction = @min(@as(f64, 20), @max(armor / 5, armor - @as(f64, accepted) / (2 + toughness / 4)));
        return accepted * @as(f32, @floatCast(1 - reduction / 25));
    }

    fn applyKnockback(living: *living_entities.Pool, index: usize, attacker: geometry.Vec3) void {
        const x = living.position_x[index] - attacker.x;
        const z = living.position_z[index] - attacker.z;
        const length_squared = x * x + z * z;
        if (length_squared <= 1.0e-8) return;
        const scale = 0.4 / @sqrt(length_squared);
        living.velocity_x[index] = living.velocity_x[index] * 0.5 + x * scale;
        living.velocity_z[index] = living.velocity_z[index] * 0.5 + z * scale;
        if (living.on_ground[index])
            living.velocity_y[index] = @min(0.4, living.velocity_y[index] * 0.5 + 0.4);
    }

    fn reactToDamage(random_state: *world_random.Random, living_store: *entity_store.LivingEntities, outputs: *Packets, living_index: u16, attacker_slot: u16) void {
        const living = &living_store.entities;
        const index: usize = living_index;
        switch (living.entity_types[index]) {
            .zombie => {
                living.targets[index] = .{ .player = attacker_slot };
                living.target_goal_running[index] = true;
            },
            .cow, .pig => {
                living.panic_ticks[index] = 100;
                living.love_ticks[index] = 0;
                living.loving_player[index] = std.math.maxInt(u16);
            },
            else => {},
        }
        if (living.entity_types[index] == .cow) {
            const random = &living.random[index];
            const base_pitch: f32 = if (living.baby[index]) 1.5 else 1.0;
            outputs.living_sound(.{
                .index = living_index,
                .sound = if (living.health[index] == 0) .cow_death else .cow_hurt,
                .volume = 0.4,
                .pitch = base_pitch + (random.nextFloat() - random.nextFloat()) * 0.2,
                .seed = @bitCast(random_state.random.next()),
            });
        }
        outputs.living_damaged(.{ .index = living_index, .attacker_slot = attacker_slot });
    }

    fn recordVelocity(self: *LivingCombat, living: *living_entities.Pool, living_index: u16) void {
        if (self.velocity_count == self.velocities.len) return;
        const index: usize = living_index;
        self.velocities[self.velocity_count] = .{
            .index = living_index,
            .x = living.velocity_x[index],
            .y = living.velocity_y[index],
            .z = living.velocity_z[index],
        };
        self.velocity_count += 1;
    }

    fn damageHeldItem(self: *LivingCombat, players: *player_store.Players, slot: u16) void {
        const player = &players.records[slot];
        if (player.gamemode != .survival) return;
        const hotbar_slot = player.selected_hotbar_slot;
        const stack = &player.hotbar[hotbar_slot];
        if (stack.isEmpty() or game_data.maxDurability(stack.item_id) == 0) return;
        stack.damage +|= 2;
        if (stack.damage >= game_data.maxDurability(stack.item_id)) stack.* = .{};
        if (self.hotbar_change_count == self.hotbar_changes.len) return;
        self.hotbar_changes[self.hotbar_change_count] = .{ .slot = slot, .hotbar_slot = hotbar_slot };
        self.hotbar_change_count += 1;
    }

    fn flush(self: *LivingCombat, outputs: *Packets) void {
        if (self.velocity_count == 0 and self.hotbar_change_count == 0) {
            @branchHint(.likely);
            return;
        }
        for (self.velocities[0..self.velocity_count]) |velocity| outputs.living_velocity_changed(velocity);
        for (self.hotbar_changes[0..self.hotbar_change_count]) |change| outputs.hotbar_changed(change);
        self.velocity_count = 0;
        self.hotbar_change_count = 0;
    }

    fn trySpawnZombieReinforcement(
        random: *world_random.Random,
        rules: *const game_rules.GameRules,
        blocks: *block_store.Blocks,
        projection: *vanilla_collision_projection.CollisionProjection,
        players: *const player_store.Players,
        living_store: *entity_store.LivingEntities,
        outputs: *Packets,
        living_index: u16,
        attacker_slot: u16,
    ) void {
        const living = &living_store.entities;
        const index: usize = living_index;
        const world = living.worlds[index];
        if (rules.difficulty != .hard or !rules.do_mob_spawning or living.free_count == 0) return;
        if (living.random[index].nextFloat() >= living.reinforcement_chance[index]) return;
        const origin_x: i32 = geometry.blockCoord(living.position_x[index]);
        const origin_y: i32 = geometry.blockCoord(living.position_y[index]);
        const origin_z: i32 = geometry.blockCoord(living.position_z[index]);
        for (0..50) |_| {
            const x = origin_x + (living.random[index].nextIntBounded(34) + 7) * (living.random[index].nextIntBounded(3) - 1);
            const y = origin_y + (living.random[index].nextIntBounded(34) + 7) * (living.random[index].nextIntBounded(3) - 1);
            const z = origin_z + (living.random[index].nextIntBounded(34) + 7) * (living.random[index].nextIntBounded(3) - 1);
            if (y <= world_limits.min_y or y + 2 > block_store.world_top_y) continue;
            const position = geometry.Vec3{ .x = @as(f64, @floatFromInt(x)) + 0.5, .y = @floatFromInt(y), .z = @as(f64, @floatFromInt(z)) + 0.5 };
            var player_too_close = false;
            for (players.activeSlots()) |slot| {
                const player = &players.records[slot];
                if (player.state != .play or !player.world.eql(world)) continue;
                const dx = player.position.x - position.x;
                const dy = player.position.y - position.y;
                const dz = player.position.z - position.z;
                if (dx * dx + dy * dy + dz * dz < 49) {
                    player_too_close = true;
                    break;
                }
            }
            if (player_too_close) continue;
            const box = collision.entityBox(position.x, position.y, position.z, 0.6, 1.95);
            if (block_queries.livingBoxCollidesFrom(projection.source(), world, box)) continue;
            const below = projection.blockState(world, .{ .x = x, .y = @intCast(y - 1), .z = z }) orelse continue;
            if (collision.shapeBoxes(below).len == 0) continue;
            var entity_intersection = false;
            for (living.active_indices[0..living.active_count]) |other_index| {
                const other_box = collision.entityBox(
                    living.position_x[other_index],
                    living.position_y[other_index],
                    living.position_z[other_index],
                    living_entities.width(living.entity_types[other_index], living.baby[other_index]),
                    living_entities.height(living.entity_types[other_index], living.baby[other_index]),
                );
                if (box.intersects(other_box)) {
                    entity_intersection = true;
                    break;
                }
            }
            if (entity_intersection) continue;
            const reinforcement = living_store.spawn(random, blocks, living.worlds[index], .zombie, position, false, false) catch return;
            living.targets[reinforcement.index] = .{ .player = attacker_slot };
            living.target_goal_running[reinforcement.index] = true;
            living.reinforcement_chance[index] -= 0.05;
            living.reinforcement_chance[reinforcement.index] -= 0.05;
            outputs.living_spawned(reinforcement.index);
            return;
        }
    }
};

pub const LivingCombatProjection = struct {
    pub const id = "minecraft:living_combat_projection";
    pub const Configuration = struct {};
    pub const Dependencies = struct { combat: *LivingCombat, outputs: *Packets };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*LivingCombatProjection {
        const self = try allocator.create(LivingCombatProjection);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *LivingCombatProjection, _: std.mem.Allocator) void {
        self.deps.combat.flush(self.deps.outputs);
    }
};
