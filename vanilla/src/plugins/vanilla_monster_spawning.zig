const lightning_rod = @import("lightning_rod");
const entity_store = lightning_rod.entities;
const living_entities = lightning_rod.living_entities;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const block_queries = lightning_rod.block_queries;
const geometry = lightning_rod.geometry;
const vanilla_time = lightning_rod.time;
const game_rules = lightning_rod.game_rules;
const world_random = lightning_rod.random;
const world_clock = lightning_rod.clock;
const std = @import("std");
const test_state = lightning_rod.test_support.state;
const collision = lightning_rod.collision;
const registry = lightning_rod.registry_data;
const active_chunks = @import("../vanilla/active_chunks.zig");
const Packets = lightning_rod.Packets;
const vanilla_lighting = @import("vanilla_lighting.zig");
const world_store = lightning_rod.worlds;
const world_identity = lightning_rod.world_identity;
const world_limits = lightning_rod.world_limits;

const SpawnContext = struct {
    worlds: *world_store.Worlds,
    clock: *world_clock.Clock,
    time: *vanilla_time.Time,
    rules: *game_rules.GameRules,
    random: *world_random.Random,
    blocks: *block_store.Blocks,
    players: *player_store.Players,
    active: ?*active_chunks.ActiveChunks = null,
    living: *entity_store.LivingEntities,
    lighting: *vanilla_lighting.Lighting,

    fn activePlayerSlots(self: *const SpawnContext) []const u16 {
        return self.players.active_slots[0..self.players.active_count];
    }

    fn spawnZombie(self: *SpawnContext, world: world_identity.Handle, position: geometry.Vec3, baby: bool, persistent: bool) !living_entities.Handle {
        return self.living.spawn(
            self.random,
            self.blocks,
            world,
            .zombie,
            position,
            baby,
            persistent,
        );
    }
};

fn spawnMonsterWorld(context: *SpawnContext, outputs: *Packets, world: world_identity.Handle) void {
    const simulation = context;
    if (!simulation.rules.do_mob_spawning or simulation.living.entities.free_count == 0) return;
    const active = simulation.active orelse return;
    var eligible_player_count: usize = 0;
    for (simulation.activePlayerSlots()) |slot| {
        const player = &simulation.players.records[slot];
        if (player.state != .play or player.gamemode == .spectator or !player.world.eql(world)) continue;
        eligible_player_count += 1;
    }
    if (eligible_player_count == 0) return;
    const radius = @min(@as(i32, 8), active.simulationDistance());
    const bounds = active.rowBounds(world, radius) orelse return;
    const spawning_chunks = active.countUnion(world, bounds, radius);
    if (simulation.rules.difficulty == .peaceful) return;
    const cap = 70 * spawning_chunks / 289;
    var count = countMonsters(&simulation.living.entities, world);
    if (count >= cap) return;

    var chunk_z = bounds.first;
    while (chunk_z <= bounds.last) : (chunk_z += 1) {
        const intervals = active.rowIntervals(world, chunk_z, radius);
        for (intervals) |interval| {
            var chunk_x = interval.first;
            while (chunk_x <= interval.last) : (chunk_x += 1) {
                count += spawnZombiePackInChunk(context, outputs, world, chunk_x, chunk_z, cap - count);
                if (count >= cap) return;
                if (simulation.living.entities.free_count == 0) return;
            }
        }
    }
}

fn isExposedMonsterSpawningTime(day_time: u64) bool {
    const time = day_time % 24_000;
    return time >= 13_000 and time <= 23_000;
}

fn countMonsters(entities: *const living_entities.Pool, world: world_identity.Handle) usize {
    var count: usize = 0;
    for (entities.active_indices[0..entities.active_count]) |index| {
        count += @intFromBool(entities.worlds[index].eql(world) and
            (entities.entity_types[index] == .zombie or entities.entity_types[index] == .zombified_piglin));
    }
    return count;
}

fn spawnZombiePackInChunk(
    context: *SpawnContext,
    outputs: *Packets,
    world: world_identity.Handle,
    chunk_x: i32,
    chunk_z: i32,
    remaining: usize,
) usize {
    const simulation = context;
    const origin_x = chunk_x * 16 + @as(i32, @intCast(simulation.random.random.nextIntBounded(16)));
    const origin_z = chunk_z * 16 + @as(i32, @intCast(simulation.random.random.nextIntBounded(16)));
    if (simulation.blocks.residentChunk(world, .{ .x = chunk_x, .z = chunk_z }) == null) return 0;
    const top_y = @as(i32, simulation.blocks.highestBlockYAt(world, origin_x, origin_z)) + 1;
    const height_range: u32 = @intCast(top_y - @as(i32, world_limits.min_y) + 1);
    const origin_y = @as(i32, world_limits.min_y) + @as(i32, @intCast(simulation.random.random.nextIntBounded(height_range)));
    var pack_x = origin_x;
    var pack_z = origin_z;
    var spawned: usize = 0;
    for (0..3) |_| {
        for (0..4) |_| {
            pack_x += @as(i32, @intCast(simulation.random.random.nextIntBounded(6))) - @as(i32, @intCast(simulation.random.random.nextIntBounded(6)));
            pack_z += @as(i32, @intCast(simulation.random.random.nextIntBounded(6))) - @as(i32, @intCast(simulation.random.random.nextIntBounded(6)));
            if (simulation.blocks.residentChunk(world, .{
                .x = @divFloor(pack_x, 16),
                .z = @divFloor(pack_z, 16),
            }) == null) continue;
            const pos = geometry.BlockPos{ .x = pack_x, .y = @intCast(origin_y), .z = pack_z };
            if (!validNaturalZombieSpawn(simulation, world, pos)) continue;
            const position = geometry.Vec3{ .x = @as(f64, @floatFromInt(pack_x)) + 0.5, .y = @floatFromInt(origin_y), .z = @as(f64, @floatFromInt(pack_z)) + 0.5 };
            const baby = simulation.random.random.nextFloat() < 0.05;
            const zombie = simulation.spawnZombie(world, position, baby, false) catch return spawned;
            simulation.living.entities.yaw[zombie.index] = simulation.random.random.nextFloat() * 360;
            simulation.living.entities.body_yaw[zombie.index] = simulation.living.entities.yaw[zombie.index];
            simulation.living.entities.head_yaw[zombie.index] = simulation.living.entities.yaw[zombie.index];
            outputs.living_spawned(zombie.index);
            spawned += 1;
            if (spawned == @min(@as(usize, 4), remaining) or simulation.living.entities.free_count == 0) return spawned;
        }
    }
    return spawned;
}

fn validNaturalZombieSpawn(simulation: *SpawnContext, world: world_identity.Handle, pos: geometry.BlockPos) bool {
    if (pos.y <= world_limits.min_y or pos.y >= block_store.world_top_y) return false;
    const below = geometry.BlockPos{ .x = pos.x, .y = pos.y - 1, .z = pos.z };
    const above = geometry.BlockPos{ .x = pos.x, .y = pos.y + 1, .z = pos.z };
    if (collision.shapeBoxes(simulation.blocks.blockAt(world, below)).len == 0 or
        collision.shapeBoxes(simulation.blocks.blockAt(world, pos)).len != 0 or
        collision.shapeBoxes(simulation.blocks.blockAt(world, above)).len != 0) return false;
    if (simulation.lighting.blockLightAt(world, pos) != 0) return false;
    if (!isExposedMonsterSpawningTime(simulation.time.day_time) and
        simulation.lighting.skyLightAt(world, pos) > 7) return false;
    const position = geometry.Vec3{ .x = @as(f64, @floatFromInt(pos.x)) + 0.5, .y = @floatFromInt(pos.y), .z = @as(f64, @floatFromInt(pos.z)) + 0.5 };
    const spawn_dx = position.x - 8.5;
    const spawn_dz = position.z - 8.5;
    if (spawn_dx * spawn_dx + spawn_dz * spawn_dz < 576) return false;
    var nearest_player_distance = std.math.inf(f64);
    for (simulation.activePlayerSlots()) |slot| {
        const player = &simulation.players.records[slot];
        if (player.state != .play or player.gamemode == .spectator or !player.world.eql(world)) continue;
        const dx = player.position.x - position.x;
        const dy = player.position.y - position.y;
        const dz = player.position.z - position.z;
        nearest_player_distance = @min(nearest_player_distance, dx * dx + dy * dy + dz * dz);
    }
    if (nearest_player_distance <= 24 * 24 or nearest_player_distance > 128 * 128) return false;
    const box = collision.entityBox(position.x, position.y, position.z, 0.6, 1.95);
    if (block_queries.livingBoxCollides(simulation.blocks, world, box)) return false;
    for (simulation.living.entities.active_indices[0..simulation.living.entities.active_count]) |index| {
        if (!simulation.living.entities.worlds[index].eql(world)) continue;
        const other = collision.entityBox(
            simulation.living.entities.position_x[index],
            simulation.living.entities.position_y[index],
            simulation.living.entities.position_z[index],
            living_entities.width(simulation.living.entities.entity_types[index], simulation.living.entities.baby[index]),
            living_entities.height(simulation.living.entities.entity_types[index], simulation.living.entities.baby[index]),
        );
        if (box.intersects(other)) return false;
    }
    return true;
}

pub const MonsterSpawning = struct {
    pub const id = "minecraft:monster_spawning";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        lighting: *vanilla_lighting.Lighting,
        worlds: *world_store.Worlds,
        clock: *world_clock.Clock,
        time: *vanilla_time.Time,
        rules: *game_rules.GameRules,
        random: *world_random.Random,
        blocks: *block_store.Blocks,
        players: *player_store.Players,
        active: *active_chunks.ActiveChunks,
        living: *entity_store.LivingEntities,
        outputs: *Packets,
    };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*MonsterSpawning {
        const self = try allocator.create(MonsterSpawning);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *MonsterSpawning, _: std.mem.Allocator) void {
        const lighting = self.deps.lighting;
        const worlds = self.deps.worlds;
        const clock = self.deps.clock;
        const time = self.deps.time;
        const rules = self.deps.rules;
        const random = self.deps.random;
        const blocks = self.deps.blocks;
        const players = self.deps.players;
        const living = self.deps.living;
        const outputs = self.deps.outputs;
        var context = SpawnContext{ .worlds = worlds, .clock = clock, .time = time, .rules = rules, .random = random, .blocks = blocks, .players = players, .active = self.deps.active, .living = living, .lighting = lighting };
        for (worlds.active()) |world| spawnMonsterWorld(&context, outputs, world);
    }
};

test "surface monster darkness follows the daylight cycle" {
    try std.testing.expect(!isExposedMonsterSpawningTime(1_000));
    try std.testing.expect(isExposedMonsterSpawningTime(13_000));
    try std.testing.expect(isExposedMonsterSpawningTime(23_000));
    try std.testing.expect(!isExposedMonsterSpawningTime(23_001));
    try std.testing.expect(isExposedMonsterSpawningTime(37_000));
}

test "exposed surface rejects daytime zombie spawning" {
    const simulation = try std.testing.allocator.create(test_state.State);
    defer std.testing.allocator.destroy(simulation);
    var lighting_storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer lighting_storage.deinit();
    try simulation.init(std.testing.allocator, 52);
    defer simulation.deinit();
    var session_store = lightning_rod.sessions.Sessions.init(772);
    const lighting = try vanilla_lighting.Lighting.init(lighting_storage.allocator(), .{
        .clock = &simulation.clock,
        .blocks = &simulation.blocks,
        .players = &simulation.players,
        .sessions = &session_store,
        .paging = null,
    }, .{
        .source_mutations = 16,
    });
    simulation.generator.mode = .flat;
    simulation.players.records[0].state = .play;
    simulation.players.records[0].world = simulation.world;
    simulation.players.records[0].position = .{ .x = 0.5, .y = 101, .z = 0.5 };
    simulation.players.rebuildActive();
    simulation.blocks.ensureChunkAt(simulation.world, 40, 0, simulation.clock.tick);
    try std.testing.expect(try simulation.blocks.setBlock(simulation.world, .{ .x = 40, .y = 100, .z = 0 }, registry.block_stone_default_state));
    _ = try simulation.blocks.setBlock(simulation.world, .{ .x = 40, .y = 101, .z = 0 }, registry.block_air_default_state);
    _ = try simulation.blocks.setBlock(simulation.world, .{ .x = 40, .y = 102, .z = 0 }, registry.block_air_default_state);

    var dependencies = SpawnContext{
        .worlds = simulation.worlds,
        .clock = &simulation.clock,
        .time = &simulation.time,
        .rules = &simulation.rules,
        .random = &simulation.random,
        .blocks = &simulation.blocks,
        .players = &simulation.players,
        .active = null,
        .living = &simulation.living,
        .lighting = lighting,
    };
    const position = geometry.BlockPos{ .x = 40, .y = 101, .z = 0 };
    simulation.time.day_time = 1_000;
    try std.testing.expect(!validNaturalZombieSpawn(&dependencies, simulation.world, position));
    simulation.time.day_time = 13_000;
    try std.testing.expect(validNaturalZombieSpawn(&dependencies, simulation.world, position));
}
