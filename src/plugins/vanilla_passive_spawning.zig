const std = @import("std");
const lightning_rod = @import("lightning_rod");
const active_chunks = @import("../vanilla/active_chunks.zig");
const entity_store = lightning_rod.entities;
const living_entities = lightning_rod.living_entities;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const block_queries = lightning_rod.block_queries;
const geometry = lightning_rod.geometry;
const game_rules = lightning_rod.game_rules;
const world_random = lightning_rod.random;
const world_clock = lightning_rod.clock;
const config = lightning_rod.config.value;
const collision = lightning_rod.collision;
const registry = lightning_rod.registry_data;
const Packets = lightning_rod.Packets;
const world_store = lightning_rod.worlds;
const world_identity = lightning_rod.world_identity;

const SpawnContext = struct {
    clock: *world_clock.Clock,
    rules: *game_rules.GameRules,
    random: *world_random.Random,
    blocks: *block_store.Blocks,
    players: *player_store.Players,
    living: *entity_store.LivingEntities,
};

pub const PassiveSpawning = struct {
    pub const id = "minecraft:passive_spawning";

    worlds: *world_store.Worlds,
    clock: *world_clock.Clock,
    rules: *game_rules.GameRules,
    random: *world_random.Random,
    blocks: *block_store.Blocks,
    players: *player_store.Players,
    living: *entity_store.LivingEntities,
    packets: *Packets,

    pub fn create(allocator: std.mem.Allocator, worlds: *world_store.Worlds, clock: *world_clock.Clock, rules: *game_rules.GameRules, random: *world_random.Random, blocks: *block_store.Blocks, players: *player_store.Players, living: *entity_store.LivingEntities, packets: *Packets) !*PassiveSpawning {
        const self = try allocator.create(PassiveSpawning);
        self.* = .{ .worlds = worlds, .clock = clock, .rules = rules, .random = random, .blocks = blocks, .players = players, .living = living, .packets = packets };
        return self;
    }

    pub fn tick(self: *PassiveSpawning, _: std.mem.Allocator) void {
        const worlds = self.worlds;
        const clock = self.clock;
        const rules = self.rules;
        const random = self.random;
        const blocks = self.blocks;
        const players = self.players;
        const living = self.living;
        const packets = self.packets;
        var context = SpawnContext{
            .clock = clock,
            .rules = rules,
            .random = random,
            .blocks = blocks,
            .players = players,
            .living = living,
        };
        for (worlds.active()) |world| spawnWorld(&context, packets, world);
    }
};

fn spawnWorld(context: *SpawnContext, packets: *Packets, world: world_identity.Handle) void {
    if (!context.rules.do_mob_spawning or context.living.entities.free_count == 0 or
        context.clock.tick % 400 != 0) return;
    var eligible_players: [config.max_players]u16 = undefined;
    var eligible_count: usize = 0;
    for (context.players.activeSlots()) |slot| {
        const player = &context.players.records[slot];
        if (player.state != .play or player.gamemode == .spectator or !player.world.eql(world)) continue;
        eligible_players[eligible_count] = slot;
        eligible_count += 1;
    }
    if (eligible_count == 0) return;
    const radius = @min(@as(i32, 8), config.simulation_distance_chunks);
    const bounds = active_chunks.rowBounds(context.players, world, radius) orelse return;
    const spawning_chunks = active_chunks.countUnion(context.players, world, bounds, radius);
    const cap = 10 * spawning_chunks / 289;
    const count = passiveCount(&context.living.entities, world);
    if (count >= cap) return;
    _ = spawnPacks(
        context,
        packets,
        eligible_players[0..eligible_count],
        world,
        radius,
        cap - count,
        spawning_chunks,
    );
}

fn spawnPacks(
    context: *SpawnContext,
    packets: *Packets,
    eligible_players: []const u16,
    world: world_identity.Handle,
    radius: i32,
    remaining: usize,
    spawning_chunks: usize,
) usize {
    var spawned: usize = 0;
    const attempts = @min(spawning_chunks, @as(usize, 64));
    const diameter: u32 = @intCast(radius * 2 + 1);
    for (0..attempts) |_| {
        if (spawned == remaining or context.living.entities.free_count == 0) break;
        const slot = eligible_players[context.random.random.nextIntBounded(@intCast(eligible_players.len))];
        const player = &context.players.records[slot];
        const center_x = @divFloor(geometry.blockCoord(player.position.x), 16);
        const center_z = @divFloor(geometry.blockCoord(player.position.z), 16);
        const chunk_x = center_x + @as(i32, @intCast(context.random.random.nextIntBounded(diameter))) - radius;
        const chunk_z = center_z + @as(i32, @intCast(context.random.random.nextIntBounded(diameter))) - radius;
        spawned += spawnPack(context, packets, world, chunk_x, chunk_z, remaining - spawned);
    }
    return spawned;
}

fn spawnPack(
    context: *SpawnContext,
    packets: *Packets,
    world: world_identity.Handle,
    chunk_x: i32,
    chunk_z: i32,
    remaining: usize,
) usize {
    if (remaining == 0) return 0;
    const entity_type: living_entities.EntityType = if (context.random.random.nextIntBounded(18) < 8) .cow else .pig;
    var x = chunk_x * 16 + @as(i32, @intCast(context.random.random.nextIntBounded(16)));
    var z = chunk_z * 16 + @as(i32, @intCast(context.random.random.nextIntBounded(16)));
    var spawned: usize = 0;
    for (0..12) |_| {
        if (context.blocks.residentChunk(world, .{ .x = @divFloor(x, 16), .z = @divFloor(z, 16) }) != null) {
            const y = @as(i32, context.blocks.highestBlockYAt(world, x, z)) + 1;
            const position = geometry.BlockPos{ .x = x, .y = @intCast(y), .z = z };
            if (validSpawn(context, world, entity_type, position)) {
                spawn(context, packets, world, entity_type, position) catch return spawned;
                spawned += 1;
                if (spawned == @min(@as(usize, 4), remaining) or context.living.entities.free_count == 0) return spawned;
            }
        }
        x += @as(i32, @intCast(context.random.random.nextIntBounded(5))) - 2;
        z += @as(i32, @intCast(context.random.random.nextIntBounded(5))) - 2;
    }
    return spawned;
}

fn spawn(
    context: *SpawnContext,
    packets: *Packets,
    world: world_identity.Handle,
    entity_type: living_entities.EntityType,
    block: geometry.BlockPos,
) !void {
    const handle = try context.living.spawn(
        context.random,
        context.blocks,
        world,
        entity_type,
        .{ .x = @as(f64, @floatFromInt(block.x)) + 0.5, .y = @floatFromInt(block.y), .z = @as(f64, @floatFromInt(block.z)) + 0.5 },
        context.random.random.nextIntBounded(20) == 0,
        false,
    );
    const entities = &context.living.entities;
    entities.yaw[handle.index] = context.random.random.nextFloat() * 360;
    entities.body_yaw[handle.index] = entities.yaw[handle.index];
    entities.head_yaw[handle.index] = entities.yaw[handle.index];
    packets.living_spawned(handle.index);
}

fn validSpawn(
    context: *SpawnContext,
    world: world_identity.Handle,
    entity_type: living_entities.EntityType,
    position: geometry.BlockPos,
) bool {
    if (position.y <= config.world_min_y or position.y >= block_store.world_top_y) return false;
    const below = geometry.BlockPos{ .x = position.x, .y = position.y - 1, .z = position.z };
    const above = geometry.BlockPos{ .x = position.x, .y = position.y + 1, .z = position.z };
    if (context.blocks.blockAt(world, below) != registry.block_grass_block_default_state or
        collision.shapeBoxes(context.blocks.blockAt(world, position)).len != 0 or
        collision.shapeBoxes(context.blocks.blockAt(world, above)).len != 0) return false;
    const point = geometry.Vec3{
        .x = @as(f64, @floatFromInt(position.x)) + 0.5,
        .y = @floatFromInt(position.y),
        .z = @as(f64, @floatFromInt(position.z)) + 0.5,
    };
    if (!validPlayerDistance(context, world, point)) return false;
    const box = collision.entityBox(point.x, point.y, point.z, living_entities.width(entity_type, false), living_entities.height(entity_type, false));
    if (block_queries.livingBoxCollides(context.blocks, world, box)) return false;
    for (context.living.entities.active_indices[0..context.living.entities.active_count]) |index| {
        if (!context.living.entities.worlds[index].eql(world)) continue;
        const other = collision.entityBox(
            context.living.entities.position_x[index],
            context.living.entities.position_y[index],
            context.living.entities.position_z[index],
            living_entities.width(context.living.entities.entity_types[index], context.living.entities.baby[index]),
            living_entities.height(context.living.entities.entity_types[index], context.living.entities.baby[index]),
        );
        if (box.intersects(other)) return false;
    }
    return true;
}

fn validPlayerDistance(context: *const SpawnContext, world: world_identity.Handle, position: geometry.Vec3) bool {
    var nearest = std.math.inf(f64);
    for (context.players.activeSlots()) |slot| {
        const player = &context.players.records[slot];
        if (player.state != .play or player.gamemode == .spectator or !player.world.eql(world)) continue;
        const dx = player.position.x - position.x;
        const dy = player.position.y - position.y;
        const dz = player.position.z - position.z;
        nearest = @min(nearest, dx * dx + dy * dy + dz * dz);
    }
    return nearest > 24 * 24 and nearest <= 128 * 128;
}

fn passiveCount(entities: *const living_entities.Pool, world: world_identity.Handle) usize {
    var count: usize = 0;
    for (entities.active_indices[0..entities.active_count]) |index| {
        if (!entities.worlds[index].eql(world)) continue;
        count += @intFromBool(entities.entity_types[index] == .cow or entities.entity_types[index] == .pig);
    }
    return count;
}
