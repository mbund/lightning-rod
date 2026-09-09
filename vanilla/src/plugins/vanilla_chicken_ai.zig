const std = @import("std");
const lightning_rod = @import("lightning_rod");
const entity_store = lightning_rod.entities;
const living_entities = lightning_rod.living_entities;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const geometry = lightning_rod.geometry;
const world_random = lightning_rod.random;
const Packets = lightning_rod.Packets;
const deaths = @import("vanilla_living_death.zig");

const lava_chicken_disc_id = blk: {
    @setEvalBranchQuota(100_000);
    break :blk lightning_rod.registry_data.itemId("minecraft:music_disc_lava_chicken").?;
};

pub const lava_chicken_comparator_output: u8 = 9;

pub fn isLavaChickenJockey(entities: *const living_entities.Pool, index: u16) bool {
    if (index >= entities.active.len or !entities.active[index]) return false;
    if (entities.entity_types[index] != .zombie or !entities.baby[index]) return false;
    const rider = living_entities.Handle{ .index = index, .generation = entities.generations[index] };
    const vehicle = entities.vehicleFor(rider) orelse return false;
    return entities.isAlive(vehicle) and !entities.dead[vehicle.index] and
        entities.entity_types[vehicle.index] == .chicken and
        entities.worlds[index].eql(entities.worlds[vehicle.index]);
}

pub const ChickenAi = struct {
    pub const id = "minecraft:chicken_ai";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        random: *world_random.Random,
        blocks: *block_store.Blocks,
        living: *entity_store.LivingEntities,
        packets: *Packets,
    };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*ChickenAi {
        const self = try allocator.create(ChickenAi);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn mount(self: *ChickenAi, zombie: living_entities.Handle, chicken: living_entities.Handle) bool {
        const entities = &self.deps.living.entities;
        if (!isMountable(entities, zombie, chicken)) return false;
        return entities.setVehicle(zombie, chicken);
    }

    pub fn tick(self: *ChickenAi, _: std.mem.Allocator) void {
        const entities = &self.deps.living.entities;
        const count = entities.active_count;
        for (entities.active_indices[0..count]) |index| {
            self.createJockey(index);
            self.synchronize(entities, index);
        }
    }

    fn createJockey(self: *ChickenAi, index: u16) void {
        const entities = &self.deps.living.entities;
        if (!entities.jockey_candidate[index]) return;
        entities.jockey_candidate[index] = false;
        const zombie = living_entities.Handle{ .index = index, .generation = entities.generations[index] };
        if (!entities.isAlive(zombie) or entities.dead[index] or !entities.baby[index]) return;
        const position = geometry.Vec3{ .x = entities.position_x[index], .y = entities.position_y[index], .z = entities.position_z[index] };
        const chicken = self.deps.living.spawn(self.deps.random, self.deps.blocks, entities.worlds[index], .chicken, position, false, false) catch return;
        if (!self.mount(zombie, chicken)) return;
        self.deps.packets.living_spawned(chicken.index);
        self.deps.packets.living_passengers(chicken.index, zombie.index);
    }

    fn synchronize(self: *ChickenAi, entities: *living_entities.Pool, index: u16) void {
        if (!isLavaChickenJockey(entities, index)) {
            const vehicle = entities.vehicleFor(.{ .index = index, .generation = entities.generations[index] });
            if (vehicle) |value| if (entities.isAlive(value)) self.deps.packets.living_passengers(value.index, null);
            entities.clearVehicle(.{ .index = index, .generation = entities.generations[index] });
            return;
        }
        const vehicle = entities.vehicleFor(.{ .index = index, .generation = entities.generations[index] }).?;
        const rider: usize = index;
        entities.position_x[rider] = entities.position_x[vehicle.index];
        entities.position_y[rider] = entities.position_y[vehicle.index] + 0.7;
        entities.position_z[rider] = entities.position_z[vehicle.index];
        entities.velocity_x[rider] = 0;
        entities.velocity_y[rider] = 0;
        entities.velocity_z[rider] = 0;
        entities.yaw[rider] = entities.yaw[vehicle.index];
        entities.body_yaw[rider] = entities.body_yaw[vehicle.index];
        entities.head_yaw[rider] = entities.head_yaw[vehicle.index];
        self.deps.packets.living_moved(index);
    }
};

fn isMountable(entities: *const living_entities.Pool, zombie: living_entities.Handle, chicken: living_entities.Handle) bool {
    return entities.isAlive(zombie) and entities.isAlive(chicken) and
        !entities.dead[zombie.index] and !entities.dead[chicken.index] and
        entities.entity_types[zombie.index] == .zombie and entities.baby[zombie.index] and
        entities.entity_types[chicken.index] == .chicken and
        entities.worlds[zombie.index].eql(entities.worlds[chicken.index]);
}

pub const LavaChickenLoot = struct {
    pub const id = "minecraft:living_death_loot";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        deaths: *deaths.LivingDeaths,
        random: *world_random.Random,
        blocks: *block_store.Blocks,
        living: *entity_store.LivingEntities,
        items: *entity_store.ItemEntities,
        outputs: *Packets,
    };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*LavaChickenLoot {
        const self = try allocator.create(LavaChickenLoot);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *LavaChickenLoot, _: std.mem.Allocator) void {
        for (self.deps.deaths.pendingDeaths()) |death| {
            if (death.extension_complete) continue;
            if (self.dropLavaChickenDisc(death))
                self.deps.deaths.completeExtension(death.index, death.generation)
            else
                self.deps.deaths.deferDeath(death.index, death.generation);
        }
        self.deps.deaths.process(self.deps.random, self.deps.blocks, self.deps.living, self.deps.items, self.deps.outputs);
    }

    fn dropLavaChickenDisc(self: *LavaChickenLoot, death: deaths.PendingDeath) bool {
        const entities = &self.deps.living.entities;
        if (death.index >= entities.active.len or !entities.active[death.index]) return true;
        if (entities.generations[death.index] != death.generation or !entities.dead[death.index]) return true;
        if (!isLavaChickenJockey(entities, death.index)) return true;
        const index: usize = death.index;
        const position = geometry.Vec3{ .x = entities.position_x[index], .y = entities.position_y[index], .z = entities.position_z[index] };
        return deaths.LivingDeaths.spawnStack(self.deps.random, self.deps.blocks, self.deps.living, self.deps.items, self.deps.outputs, death.index, position, player_store.stackForItem(lava_chicken_disc_id, 1));
    }
};

test "Lava Chicken eligibility requires a living mounted chicken" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var entities: living_entities.Pool = undefined;
    try entities.allocate(arena.allocator(), .{ .first_entity_id = 1 });
    const world = lightning_rod.world_identity.Handle{ .index = 0, .generation = 1 };
    const zombie = try entities.spawn(.{ .world = world, .entity_type = .zombie, .position = .{ .x = 0, .y = 64, .z = 0 }, .uuid = 1, .random_seed = 1, .baby = true });
    const chicken = try entities.spawn(.{ .world = world, .entity_type = .chicken, .position = .{ .x = 0, .y = 64, .z = 0 }, .uuid = 2, .random_seed = 2 });
    try std.testing.expect(entities.setVehicle(zombie, chicken));
    try std.testing.expect(isLavaChickenJockey(&entities, zombie.index));
    entities.dead[zombie.index] = true;
    try std.testing.expect(isLavaChickenJockey(&entities, zombie.index));
    entities.dead[chicken.index] = true;
    try std.testing.expect(!isLavaChickenJockey(&entities, zombie.index));
}
