const lightning_rod = @import("lightning_rod");
const entity_store = lightning_rod.entities;
const living_entities = lightning_rod.living_entities;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const block_queries = lightning_rod.block_queries;
const geometry = lightning_rod.geometry;
const std = @import("std");
const config = lightning_rod.config.value;
const preallocated = lightning_rod.preallocated;
const registry = lightning_rod.registry_data;
const land_navigation = @import("land_navigation.zig");
const active_chunks = @import("active_chunks.zig");

pub const no_index: u16 = std.math.maxInt(u16);

pub const MoveGoal = enum(u8) {
    none,
    panic,
    mate,
    tempt,
    follow_parent,
    wander,
};

pub const State = struct {
    generation: []u16 = &.{},
    move_goal: []MoveGoal = &.{},
    target: []u16 = &.{},
    goal_ticks: []u16 = &.{},
    repath_ticks: []u8 = &.{},
    temptation_cooldown: []u8 = &.{},
    look_ticks: []u8 = &.{},
    look_yaw: []f32 = &.{},

    pub fn resetEntity(self: *State, entities: *const living_entities.Pool, index: usize) void {
        self.generation[index] = entities.generations[index];
        self.move_goal[index] = .none;
        self.target[index] = no_index;
        self.goal_ticks[index] = 0;
        self.repath_ticks[index] = 0;
        self.temptation_cooldown[index] = 0;
        self.look_ticks[index] = 0;
        self.look_yaw[index] = 0;
    }

    pub fn init(self: *State, allocator: std.mem.Allocator) !void {
        self.generation = try preallocated.alloc(u16, allocator, config.max_living_entities);
        self.move_goal = try preallocated.alloc(MoveGoal, allocator, config.max_living_entities);
        self.target = try preallocated.alloc(u16, allocator, config.max_living_entities);
        self.goal_ticks = try preallocated.alloc(u16, allocator, config.max_living_entities);
        self.repath_ticks = try preallocated.alloc(u8, allocator, config.max_living_entities);
        self.temptation_cooldown = try preallocated.alloc(u8, allocator, config.max_living_entities);
        self.look_ticks = try preallocated.alloc(u8, allocator, config.max_living_entities);
        self.look_yaw = try preallocated.alloc(f32, allocator, config.max_living_entities);
        @memset(self.generation, 0);
        @memset(self.move_goal, .none);
        @memset(self.target, no_index);
        @memset(self.goal_ticks, 0);
        @memset(self.repath_ticks, 0);
        @memset(self.temptation_cooldown, 0);
        @memset(self.look_ticks, 0);
        @memset(self.look_yaw, 0);
    }
};

pub const Context = struct {
    blocks: *block_store.Blocks,
    players: *player_store.Players,
    living: *entity_store.LivingEntities,
    state: *State,
};

pub fn containsItem(items: []const i32, item_id: i32) bool {
    for (items) |candidate| if (candidate == item_id) return true;
    return false;
}

pub fn distanceSquared(entities: *const living_entities.Pool, first: usize, second: usize) f64 {
    const dx = entities.position_x[first] - entities.position_x[second];
    const dy = entities.position_y[first] - entities.position_y[second];
    const dz = entities.position_z[first] - entities.position_z[second];
    return dx * dx + dy * dy + dz * dz;
}

pub fn distanceSquaredToPlayer(entities: *const living_entities.Pool, index: usize, player: *const player_store.CorePlayer) f64 {
    const dx = entities.position_x[index] - player.position.x;
    const dy = entities.position_y[index] - player.position.y;
    const dz = entities.position_z[index] - player.position.z;
    return dx * dx + dy * dy + dz * dz;
}

pub fn lookAt(entities: *living_entities.Pool, index: usize, x: f64, y: f64, z: f64) void {
    const dx = x - entities.position_x[index];
    const dz = z - entities.position_z[index];
    const horizontal = @sqrt(dx * dx + dz * dz);
    entities.head_yaw[index] = @floatCast(std.math.radiansToDegrees(std.math.atan2(-dx, dz)));
    entities.pitch[index] = @floatCast(-std.math.radiansToDegrees(std.math.atan2(y - entities.position_y[index], horizontal)));
}

pub fn nearestTemptingPlayer(context: *Context, index: usize, tempting_items: []const i32) u16 {
    const entities = &context.living.entities;
    var closest = no_index;
    var closest_distance: f64 = 100;
    for (context.players.activeSlots()) |slot| {
        const player = &context.players.records[slot];
        if (player.state != .play or !player.world.eql(entities.worlds[index]) or player.gamemode == .spectator or player.health <= 0) continue;
        const main = player.hotbar[player.selected_hotbar_slot];
        if (!containsItem(tempting_items, main.item_id) and
            !containsItem(tempting_items, player.offhand.item_id)) continue;
        const distance = distanceSquaredToPlayer(entities, index, player);
        if (distance < closest_distance) {
            closest_distance = distance;
            closest = slot;
        }
    }
    return closest;
}

pub fn nearestMate(context: *Context, index: usize) u16 {
    const entities = &context.living.entities;
    var closest = no_index;
    var closest_distance: f64 = 64;
    for (entities.active_indices[0..entities.active_count]) |candidate| {
        if (candidate == index or !entities.worlds[candidate].eql(entities.worlds[index]) or entities.dead[candidate] or entities.entity_types[candidate] != entities.entity_types[index] or
            entities.love_ticks[candidate] == 0 or entities.breeding_age[candidate] != 0 or
            entities.panic_ticks[candidate] != 0 or context.state.move_goal[candidate] == .panic) continue;
        const distance = distanceSquared(entities, index, candidate);
        if (distance < closest_distance) {
            closest_distance = distance;
            closest = candidate;
        }
    }
    return closest;
}

pub fn closestWater(context: *Context, index: usize) ?geometry.BlockPos {
    const origin = entityBlockPosition(&context.living.entities, index);
    var best: ?geometry.BlockPos = null;
    var best_distance: i32 = std.math.maxInt(i32);
    var y: i32 = origin.y - 4;
    while (y <= origin.y + 4) : (y += 1) {
        var z = origin.z - 5;
        while (z <= origin.z + 5) : (z += 1) {
            var x = origin.x - 5;
            while (x <= origin.x + 5) : (x += 1) {
                const state = context.blocks.blockAtIfResident(context.living.entities.worlds[index], .{ .x = x, .y = @intCast(y), .z = z }) orelse continue;
                if (!block_store.isWaterBlockState(state)) continue;
                const dx = x - origin.x;
                const dy = y - origin.y;
                const dz = z - origin.z;
                const distance = dx * dx + dy * dy + dz * dz;
                if (distance < best_distance) {
                    best_distance = distance;
                    best = .{ .x = x, .y = @intCast(y), .z = z };
                }
            }
        }
    }
    return best;
}

pub fn nearestParent(entities: *const living_entities.Pool, index: usize) u16 {
    var closest = no_index;
    var closest_distance: f64 = 64;
    for (entities.active_indices[0..entities.active_count]) |candidate| {
        if (!entities.worlds[candidate].eql(entities.worlds[index]) or entities.dead[candidate] or entities.entity_types[candidate] != entities.entity_types[index] or entities.baby[candidate]) continue;
        const dx = entities.position_x[candidate] - entities.position_x[index];
        const dy = entities.position_y[candidate] - entities.position_y[index];
        const dz = entities.position_z[candidate] - entities.position_z[index];
        if (@abs(dy) > 4) continue;
        const distance = dx * dx + dy * dy + dz * dz;
        if (distance < closest_distance) {
            closest_distance = distance;
            closest = candidate;
        }
    }
    return closest;
}

pub fn entityBlockPosition(entities: *const living_entities.Pool, index: usize) geometry.BlockPos {
    return .{
        .x = geometry.blockCoord(entities.position_x[index]),
        .y = @intFromFloat(@floor(entities.position_y[index] + 0.5)),
        .z = geometry.blockCoord(entities.position_z[index]),
    };
}

pub fn playerBlockPosition(player: *const player_store.CorePlayer) geometry.BlockPos {
    return .{
        .x = geometry.blockCoord(player.position.x),
        .y = @intFromFloat(@floor(player.position.y + 0.5)),
        .z = geometry.blockCoord(player.position.z),
    };
}

pub fn randomLandTarget(context: *Context, index: usize, horizontal: i32, vertical: i32) ?geometry.BlockPos {
    const entities = &context.living.entities;
    const origin = entityBlockPosition(entities, index);
    var best: ?geometry.BlockPos = null;
    var best_score: f64 = -std.math.inf(f64);
    for (0..10) |_| {
        const x = origin.x + entities.random[index].nextIntBounded(horizontal * 2 + 1) - horizontal;
        const z = origin.z + entities.random[index].nextIntBounded(horizontal * 2 + 1) - horizontal;
        const offset_y = entities.random[index].nextIntBounded(vertical * 2 + 1) - vertical;
        const y: i32 = origin.y + offset_y;
        var candidate: ?geometry.BlockPos = null;
        var scan: i32 = 0;
        while (scan <= vertical * 2) : (scan += 1) {
            const down = y - @divTrunc(scan + 1, 2);
            const up = y + @divTrunc(scan, 2);
            for ([_]i32{ down, up }) |candidate_y| {
                if (candidate_y <= config.world_min_y or candidate_y > block_store.world_top_y) continue;
                const resident = context.blocks.residentChunk(entities.worlds[index], .{ .x = @divFloor(x, 16), .z = @divFloor(z, 16) }) orelse continue;
                const node = block_queries.pathNodeInResident(context.blocks, resident, x, @intCast(candidate_y), z, entities.baby[index]);
                if (node.passable) {
                    candidate = .{ .x = x, .y = @intCast(candidate_y), .z = z };
                    break;
                }
            }
            if (candidate != null) break;
        }
        const value = candidate orelse continue;
        const below = context.blocks.blockAtIfResident(entities.worlds[index], .{ .x = value.x, .y = value.y - 1, .z = value.z }) orelse continue;
        const score: f64 = if (below == registry.block_grass_block_default_state) 10 else 0;
        if (score > best_score) {
            best_score = score;
            best = value;
        }
    }
    return best;
}

pub fn beginPath(context: *Context, index: usize, target: geometry.BlockPos, speed: f64, target_distance: i32) bool {
    return land_navigation.start(context.blocks, context.living, index, target, target_distance, speed);
}

pub fn stopGoal(context: *Context, index: usize) void {
    if (context.state.move_goal[index] == .tempt) context.state.temptation_cooldown[index] = 50;
    context.state.move_goal[index] = .none;
    context.state.target[index] = no_index;
    context.state.goal_ticks[index] = 0;
    context.state.repath_ticks[index] = 0;
    land_navigation.stop(context.living, index);
}

pub fn startGoal(context: *Context, index: usize, goal: MoveGoal, target: u16) void {
    context.state.move_goal[index] = goal;
    context.state.target[index] = target;
    context.state.goal_ticks[index] = 0;
    context.state.repath_ticks[index] = 0;
}

pub fn goalStillValid(context: *Context, index: usize, tempting_items: []const i32) bool {
    const entities = &context.living.entities;
    return switch (context.state.move_goal[index]) {
        .none => false,
        .panic, .wander => !land_navigation.isIdle(context.living, index),
        .mate => blk: {
            const mate = context.state.target[index];
            break :blk mate != no_index and entities.active[mate] and !entities.dead[mate] and
                entities.love_ticks[index] != 0 and entities.love_ticks[mate] != 0 and
                context.state.goal_ticks[index] < 30 and entities.panic_ticks[mate] == 0 and
                context.state.move_goal[mate] != .panic;
        },
        .tempt => blk: {
            const slot = context.state.target[index];
            if (slot == no_index) break :blk false;
            const player = &context.players.records[slot];
            const main = player.hotbar[player.selected_hotbar_slot];
            break :blk player.state == .play and player.health > 0 and player.gamemode != .spectator and
                (containsItem(tempting_items, main.item_id) or
                    containsItem(tempting_items, player.offhand.item_id)) and
                distanceSquaredToPlayer(entities, index, player) < 100;
        },
        .follow_parent => blk: {
            const parent = context.state.target[index];
            if (parent == no_index or !entities.active[parent] or entities.dead[parent] or !entities.baby[index]) break :blk false;
            const distance = distanceSquared(entities, index, parent);
            break :blk distance >= 9 and distance <= 256;
        },
    };
}

pub fn startPanicGoal(context: *Context, index: usize) bool {
    const entities = &context.living.entities;
    if (entities.panic_ticks[index] == 0 and entities.fire_ticks[index] == 0) return false;
    entities.panic_ticks[index] = 0;
    const target = if (entities.fire_ticks[index] > 0) closestWater(context, index) else randomLandTarget(context, index, 5, 4);
    const destination = target orelse return false;
    stopGoal(context, index);
    startGoal(context, index, .panic, no_index);
    _ = beginPath(context, index, destination, 2, 0);
    return true;
}

pub fn tickLookGoals(context: *Context, index: usize, look_claimed: bool) void {
    const entities = &context.living.entities;
    if (look_claimed) return;
    if (context.state.look_ticks[index] != 0) {
        context.state.look_ticks[index] -= 1;
        entities.head_yaw[index] = context.state.look_yaw[index];
        return;
    }

    var closest = no_index;
    var closest_distance: f64 = 36;
    for (context.players.activeSlots()) |slot| {
        const player = &context.players.records[slot];
        if (player.state != .play or player.gamemode == .spectator) continue;
        const distance = distanceSquaredToPlayer(entities, index, player);
        if (distance < closest_distance) {
            closest_distance = distance;
            closest = slot;
        }
    }
    if (closest != no_index and entities.random[index].nextFloat() < 0.02) {
        const player = &context.players.records[closest];
        lookAt(entities, index, player.position.x, player.position.y + 1.62, player.position.z);
        context.state.look_yaw[index] = entities.head_yaw[index];
        context.state.look_ticks[index] = @intCast(20 + entities.random[index].nextIntBounded(20));
    } else if (context.state.move_goal[index] == .none and entities.random[index].nextFloat() < 0.02) {
        const angle = entities.random[index].nextDouble() * std.math.tau;
        context.state.look_yaw[index] = @floatCast(std.math.radiansToDegrees(angle));
        context.state.look_ticks[index] = @intCast(10 + entities.random[index].nextIntBounded(10));
        entities.head_yaw[index] = context.state.look_yaw[index];
    }
}

pub fn tickLifecycle(entities: *living_entities.Pool, index: usize) void {
    if (entities.breeding_age[index] < 0) {
        entities.breeding_age[index] += 1;
        if (entities.breeding_age[index] == 0) {
            entities.baby[index] = false;
            entities.metadata_dirty[index] = true;
        }
    } else if (entities.breeding_age[index] > 0) {
        entities.breeding_age[index] -= 1;
    }
    if (entities.breeding_age[index] != 0) entities.love_ticks[index] = 0 else if (entities.love_ticks[index] > 0) entities.love_ticks[index] -= 1;
}

pub fn isWater(blocks: *const block_store.Blocks, entities: *const living_entities.Pool, index: usize) bool {
    const state = blocks.blockAtIfResident(entities.worlds[index], .{
        .x = geometry.blockCoord(entities.position_x[index]),
        .y = @intFromFloat(@floor(entities.position_y[index] + 0.2)),
        .z = geometry.blockCoord(entities.position_z[index]),
    }) orelse return false;
    return block_store.isWaterBlockState(state);
}

pub fn isEntityTicking(context: *Context, entities: *const living_entities.Pool, index: usize) bool {
    const chunk = geometry.ChunkPos{
        .x = @divFloor(geometry.blockCoord(entities.position_x[index]), 16),
        .z = @divFloor(geometry.blockCoord(entities.position_z[index]), 16),
    };
    return context.blocks.residentChunk(entities.worlds[index], chunk) != null and
        active_chunks.isEntityTicking(context.players, entities.worlds[index], chunk, config.simulation_distance_chunks);
}

pub fn initContext(
    state: *State,
    blocks: *block_store.Blocks,
    players: *player_store.Players,
    living: *entity_store.LivingEntities,
) Context {
    return .{ .blocks = blocks, .players = players, .living = living, .state = state };
}

pub fn stopNavigation(living: *entity_store.LivingEntities, index: usize) void {
    land_navigation.stop(living, index);
}

pub fn tickNavigation(living: *entity_store.LivingEntities, index: usize) bool {
    return land_navigation.tick(living, index);
}
