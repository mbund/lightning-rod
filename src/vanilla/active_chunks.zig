const lightning_rod = @import("lightning_rod");
const player_store = lightning_rod.players;
const geometry = lightning_rod.geometry;
const config = lightning_rod.config.value;
const world_identity = lightning_rod.world_identity;

pub const Interval = struct { first: i32, last: i32 };
pub const RowBounds = struct { first: i32, last: i32 };

pub fn rowBounds(players: *const player_store.Players, world: world_identity.Handle, radius: i32) ?RowBounds {
    var result: ?RowBounds = null;
    for (players.active_slots[0..players.active_count]) |slot| {
        const player = &players.records[slot];
        if (player.state != .play or player.gamemode == .spectator or !player.world.eql(world)) continue;
        const chunk_z = @divFloor(geometry.blockCoord(player.position.z), 16);
        if (result) |*bounds| {
            bounds.first = @min(bounds.first, chunk_z - radius);
            bounds.last = @max(bounds.last, chunk_z + radius);
        } else result = .{ .first = chunk_z - radius, .last = chunk_z + radius };
    }
    return result;
}

pub fn rowIntervals(players: *const player_store.Players, world: world_identity.Handle, chunk_z: i32, radius: i32, intervals: *[config.max_players]Interval) usize {
    var count: usize = 0;
    for (players.active_slots[0..players.active_count]) |slot| {
        const player = &players.records[slot];
        if (player.state != .play or player.gamemode == .spectator or !player.world.eql(world)) continue;
        const center_z = @divFloor(geometry.blockCoord(player.position.z), 16);
        if (@abs(center_z - chunk_z) > radius) continue;
        const center_x = @divFloor(geometry.blockCoord(player.position.x), 16);
        const value = Interval{ .first = center_x - radius, .last = center_x + radius };
        var insert_at = count;
        while (insert_at != 0 and intervals[insert_at - 1].first > value.first) : (insert_at -= 1) intervals[insert_at] = intervals[insert_at - 1];
        intervals[insert_at] = value;
        count += 1;
    }
    return count;
}

pub fn countUnion(players: *const player_store.Players, world: world_identity.Handle, bounds: RowBounds, radius: i32) usize {
    var intervals: [config.max_players]Interval = undefined;
    var result: usize = 0;
    var chunk_z = bounds.first;
    while (chunk_z <= bounds.last) : (chunk_z += 1) {
        const count = rowIntervals(players, world, chunk_z, radius, &intervals);
        if (count == 0) continue;
        var first = intervals[0].first;
        var last = intervals[0].last;
        for (intervals[1..count]) |interval| {
            if (interval.first <= last +| 1) {
                last = @max(last, interval.last);
            } else {
                result += @intCast(last - first + 1);
                first = interval.first;
                last = interval.last;
            }
        }
        result += @intCast(last - first + 1);
    }
    return result;
}

pub fn isBlockTicking(players: *const player_store.Players, world: world_identity.Handle, chunk: geometry.ChunkPos, simulation_distance: i32) bool {
    const radius = @min(simulation_distance + 1, 32);
    return isWithinPlayerDistance(players, world, chunk, radius);
}

pub fn isEntityTicking(players: *const player_store.Players, world: world_identity.Handle, chunk: geometry.ChunkPos, simulation_distance: i32) bool {
    return isWithinPlayerDistance(players, world, chunk, @min(simulation_distance, 31));
}

fn isWithinPlayerDistance(players: *const player_store.Players, world: world_identity.Handle, chunk: geometry.ChunkPos, radius: i32) bool {
    for (players.active_slots[0..players.active_count]) |slot| {
        const player = &players.records[slot];
        if (player.state != .play or player.gamemode == .spectator or !player.world.eql(world)) continue;
        const player_chunk = geometry.chunkForBlock(.{
            .x = geometry.blockCoord(player.position.x),
            .y = 0,
            .z = geometry.blockCoord(player.position.z),
        });
        if (@max(@abs(player_chunk.x - chunk.x), @abs(player_chunk.z - chunk.z)) <= radius) return true;
    }
    return false;
}
