const lightning_rod = @import("lightning_rod");
const entity_store = lightning_rod.entities;
const living_entities = lightning_rod.living_entities;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const geometry = lightning_rod.geometry;
const world_random = lightning_rod.random;
const std = @import("std");
const test_state = lightning_rod.test_support.state;
const registry = lightning_rod.registry_data;
const diagnostics = lightning_rod.diagnostics;
const Packets = lightning_rod.Packets;

pub const Cause = enum {
    player_attack,
    fall,
    fire,
};

const no_attacker = std.math.maxInt(u16);

pub const PendingDeath = struct {
    index: u16,
    generation: u16,
    attacker_slot: u16,
    cause: Cause,
    deferred: bool = false,
    extension_complete: bool = false,
};

pub const LivingDeaths = struct {
    pub const id = "lightning_rod:living_deaths";
    pub const Configuration = struct {};
    pub const Dependencies = struct { living: *entity_store.LivingEntities };

    deps: Dependencies,
    pending: []PendingDeath = &.{},
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*LivingDeaths {
        const self = try allocator.create(LivingDeaths);
        self.* = .{ .deps = deps };
        self.pending = try allocator.alloc(PendingDeath, deps.living.entities.active.len);
        self.count = 0;
        return self;
    }

    pub fn kill(self: *LivingDeaths, living: *entity_store.LivingEntities, index: u16, cause: Cause, attacker_slot: ?u16) bool {
        const entities = &living.entities;
        if (index >= entities.active.len or !entities.active[index] or entities.dead[index]) return false;
        if (self.count == self.pending.len)
            diagnostics.panic("living death queue capacity exceeded (capacity, entity index)", &.{
                diagnostics.integer(self.pending.len),
                diagnostics.integer(index),
            });

        entities.dead[index] = true;
        entities.death_time[index] = 0;
        entities.attacking[index] = false;
        entities.target_goal_running[index] = false;
        entities.melee_goal_running[index] = false;
        living.paths.clear(index);
        self.pending[self.count] = .{
            .index = index,
            .generation = entities.generations[index],
            .attacker_slot = attacker_slot orelse no_attacker,
            .cause = cause,
        };
        self.count += 1;
        return true;
    }

    pub fn pendingDeaths(self: *const LivingDeaths) []const PendingDeath {
        return self.pending[0..self.count];
    }

    pub fn deferDeath(self: *LivingDeaths, index: u16, generation: u16) void {
        for (self.pending[0..self.count]) |*death| {
            if (death.index == index and death.generation == generation) {
                death.deferred = true;
                return;
            }
        }
    }

    pub fn completeExtension(self: *LivingDeaths, index: u16, generation: u16) void {
        for (self.pending[0..self.count]) |*death| {
            if (death.index == index and death.generation == generation) {
                death.extension_complete = true;
                return;
            }
        }
    }

    pub fn process(
        self: *LivingDeaths,
        random: *world_random.Random,
        blocks: *block_store.Blocks,
        living: *entity_store.LivingEntities,
        items: *entity_store.ItemEntities,
        outputs: *Packets,
    ) void {
        const pending_count = self.count;
        self.count = 0;
        for (self.pending[0..pending_count]) |death| {
            const entities = &living.entities;
            if (!entities.active[death.index] or
                entities.generations[death.index] != death.generation or
                !entities.dead[death.index]) continue;
            if (death.deferred) {
                var retained = death;
                retained.deferred = false;
                entities.death_time[death.index] = 0;
                self.pending[self.count] = retained;
                self.count += 1;
                continue;
            }
            _ = death.cause;
            if (!commitLoot(random, blocks, living, items, outputs, death.index)) {
                entities.death_time[death.index] = 0;
                self.pending[self.count] = death;
                self.count += 1;
                continue;
            }
            outputs.living_died(.{
                .index = death.index,
                .attacker_slot = if (death.attacker_slot == no_attacker) 0 else death.attacker_slot,
            });
        }
    }

    pub fn spawnStack(random: *world_random.Random, blocks: *block_store.Blocks, living: *entity_store.LivingEntities, items: *entity_store.ItemEntities, outputs: *Packets, entity_index: u16, position: geometry.Vec3, stack: player_store.HotbarStack) bool {
        if (stack.isEmpty()) return true;
        const item_index = items.spawn(
            random,
            blocks,
            living.entities.worlds[entity_index],
            position,
            .{},
            stack,
            entity_store.block_drop_pickup_delay_ticks,
        ) catch return false;
        outputs.item_spawned(@intCast(item_index));
        return true;
    }

    fn commitLoot(random: *world_random.Random, blocks: *block_store.Blocks, living: *entity_store.LivingEntities, items: *entity_store.ItemEntities, outputs: *Packets, entity_index: u16) bool {
        const entities = &living.entities;
        const position = geometry.Vec3{ .x = entities.position_x[entity_index], .y = entities.position_y[entity_index], .z = entities.position_z[entity_index] };
        var entity_random = entities.random[entity_index];
        var specifications: [8]entity_store.ItemEntities.Spawn = undefined;
        var count: usize = 0;
        switch (entities.entity_types[entity_index]) {
            .zombie => appendRandomDrop(&specifications, &count, entities.worlds[entity_index], position, &entity_random, registry.item_rotten_flesh_id, 0, 2),
            .cow => {
                appendRandomDrop(&specifications, &count, entities.worlds[entity_index], position, &entity_random, registry.item_leather_id, 0, 2);
                appendRandomDrop(&specifications, &count, entities.worlds[entity_index], position, &entity_random, if (entities.fire_ticks[entity_index] > 0) registry.item_cooked_beef_id else registry.item_beef_id, 1, 3);
            },
            .pig => appendRandomDrop(&specifications, &count, entities.worlds[entity_index], position, &entity_random, if (entities.fire_ticks[entity_index] > 0) registry.item_cooked_porkchop_id else registry.item_porkchop_id, 1, 3),
            else => {},
        }
        for (0..6) |equipment_slot| {
            const equipped = entities.equipment[entity_index][equipment_slot];
            if (equipped.count == 0) continue;
            const chance: f32 = if (entities.equipment_drop_guaranteed[entity_index][equipment_slot]) 2 else 0.085;
            if (entity_random.nextFloat() >= chance) continue;
            var stack = player_store.stackForItem(equipped.item_id, equipped.count);
            stack.damage = equipped.damage;
            appendDrop(&specifications, &count, entities.worlds[entity_index], position, stack);
        }
        for (specifications[0..count]) |specification| items.validateSpawn(blocks, specification) catch return false;
        var reservation = items.reserve(count) catch return false;
        var indices: [8]usize = undefined;
        items.commitReserved(&reservation, random, specifications[0..count], indices[0..count]);
        entities.random[entity_index] = entity_random;
        for (indices[0..count]) |index| outputs.item_spawned(@intCast(index));
        return true;
    }
};

fn appendRandomDrop(destination: []entity_store.ItemEntities.Spawn, count: *usize, world: lightning_rod.world_identity.Handle, position: geometry.Vec3, random: anytype, item_id: i32, minimum: u8, maximum: u8) void {
    const amount = minimum + @as(u8, @intCast(random.nextIntBounded(maximum - minimum + 1)));
    appendDrop(destination, count, world, position, player_store.stackForItem(item_id, amount));
}

fn appendDrop(destination: []entity_store.ItemEntities.Spawn, count: *usize, world: lightning_rod.world_identity.Handle, position: geometry.Vec3, stack: player_store.HotbarStack) void {
    if (stack.isEmpty()) return;
    std.debug.assert(count.* < destination.len);
    destination[count.*] = .{
        .world = world,
        .position = position,
        .stack = stack,
        .pickup_delay_ticks = entity_store.block_drop_pickup_delay_ticks,
    };
    count.* += 1;
}

pub const LivingDeathLoot = struct {
    pub const id = "minecraft:living_death_loot";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        deaths: *LivingDeaths,
        random: *world_random.Random,
        blocks: *block_store.Blocks,
        living: *entity_store.LivingEntities,
        items: *entity_store.ItemEntities,
        outputs: *Packets,
    };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*LivingDeathLoot {
        const self = try allocator.create(LivingDeathLoot);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *LivingDeathLoot, _: std.mem.Allocator) void {
        self.deps.deaths.process(self.deps.random, self.deps.blocks, self.deps.living, self.deps.items, self.deps.outputs);
    }
};

test "death queue is dense and idempotent" {
    const simulation = try std.testing.allocator.create(test_state.State);
    defer std.testing.allocator.destroy(simulation);
    try simulation.init(std.testing.allocator, 91);
    defer simulation.deinit();
    const cow = try simulation.spawnLiving(.cow, .{ .x = 0.5, .y = 65, .z = 0.5 }, false, true);
    var deaths = LivingDeaths{ .deps = .{ .living = &simulation.living } };
    deaths.pending = try std.testing.allocator.alloc(PendingDeath, simulation.living.entities.active.len);
    defer std.testing.allocator.free(deaths.pending);

    try std.testing.expect(deaths.kill(&simulation.living, cow.index, .fall, null));
    try std.testing.expect(!deaths.kill(&simulation.living, cow.index, .player_attack, 0));
    try std.testing.expectEqual(@as(usize, 1), deaths.count);
    try std.testing.expectEqual(cow.index, deaths.pending[0].index);
    try std.testing.expect(simulation.living.entities.dead[cow.index]);
}
