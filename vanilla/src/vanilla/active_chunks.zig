const std = @import("std");
const lightning_rod = @import("lightning_rod");

const geometry = lightning_rod.geometry;
const player_store = lightning_rod.players;
const world_identity = lightning_rod.world_identity;

pub const Interval = struct { first: i32, last: i32 };
pub const RowBounds = struct { first: i32, last: i32 };

pub const ActiveChunks = struct {
    pub const id = "minecraft:active_chunks";
    pub const Dependencies = struct { players: *player_store.Players };
    pub const Configuration = struct { simulation_distance_chunks: i32 = 12 };

    deps: Dependencies,
    simulation_distance_chunks: i32,
    intervals: []Interval = &.{},

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, settings: Configuration) !*ActiveChunks {
        if (settings.simulation_distance_chunks < 0 or settings.simulation_distance_chunks > 32)
            return error.InvalidSimulationDistance;
        const self = try allocator.create(ActiveChunks);
        self.* = .{
            .deps = deps,
            .simulation_distance_chunks = settings.simulation_distance_chunks,
            .intervals = try allocator.alloc(Interval, deps.players.records.len),
        };
        return self;
    }

    pub fn simulationDistance(self: *const ActiveChunks) i32 {
        return self.simulation_distance_chunks;
    }

    pub fn entityTicking(self: *const ActiveChunks, world: world_identity.Handle, chunk: geometry.ChunkPos) bool {
        return self.withinPlayerDistance(world, chunk, @min(self.simulation_distance_chunks, 31));
    }

    pub fn blockTicking(self: *const ActiveChunks, world: world_identity.Handle, chunk: geometry.ChunkPos) bool {
        return self.withinPlayerDistance(world, chunk, @min(self.simulation_distance_chunks + 1, 32));
    }

    pub fn rowBounds(self: *const ActiveChunks, world: world_identity.Handle, radius: i32) ?RowBounds {
        var result: ?RowBounds = null;
        for (self.deps.players.activeSlots()) |slot| {
            const player = &self.deps.players.records[slot];
            if (!eligible(player, world)) continue;
            const chunk_z = chunkCoordinate(player.position.z);
            if (result) |*bounds| {
                bounds.first = @min(bounds.first, chunk_z - radius);
                bounds.last = @max(bounds.last, chunk_z + radius);
            } else result = .{ .first = chunk_z - radius, .last = chunk_z + radius };
        }
        return result;
    }

    pub fn rowIntervals(self: *ActiveChunks, world: world_identity.Handle, chunk_z: i32, radius: i32) []const Interval {
        var count: usize = 0;
        for (self.deps.players.activeSlots()) |slot| {
            const player = &self.deps.players.records[slot];
            if (!eligible(player, world) or @abs(chunkCoordinate(player.position.z) - chunk_z) > radius) continue;
            const center_x = chunkCoordinate(player.position.x);
            const value = Interval{ .first = center_x - radius, .last = center_x + radius };
            var insert_at = count;
            for (0..count) |_| {
                if (insert_at == 0 or self.intervals[insert_at - 1].first <= value.first) break;
                self.intervals[insert_at] = self.intervals[insert_at - 1];
                insert_at -= 1;
            }
            self.intervals[insert_at] = value;
            count += 1;
        }
        if (count == 0) return self.intervals[0..0];
        var output: usize = 1;
        for (self.intervals[1..count]) |interval| {
            const previous = &self.intervals[output - 1];
            if (interval.first <= previous.last +| 1) {
                previous.last = @max(previous.last, interval.last);
                continue;
            }
            self.intervals[output] = interval;
            output += 1;
        }
        return self.intervals[0..output];
    }

    pub fn countUnion(self: *ActiveChunks, world: world_identity.Handle, bounds: RowBounds, radius: i32) usize {
        var result: usize = 0;
        const rows: usize = @intCast(bounds.last - bounds.first + 1);
        for (0..rows) |offset| {
            const chunk_z = bounds.first + @as(i32, @intCast(offset));
            for (self.rowIntervals(world, chunk_z, radius)) |interval|
                result += @intCast(interval.last - interval.first + 1);
        }
        return result;
    }

    fn withinPlayerDistance(self: *const ActiveChunks, world: world_identity.Handle, chunk: geometry.ChunkPos, radius: i32) bool {
        for (self.deps.players.activeSlots()) |slot| {
            const player = &self.deps.players.records[slot];
            if (!eligible(player, world)) continue;
            if (@max(@abs(chunkCoordinate(player.position.x) - chunk.x), @abs(chunkCoordinate(player.position.z) - chunk.z)) <= radius)
                return true;
        }
        return false;
    }
};

fn eligible(player: *const player_store.CorePlayer, world: world_identity.Handle) bool {
    return player.state == .play and player.gamemode != .spectator and player.world.eql(world);
}

fn chunkCoordinate(value: f64) i32 {
    return @divFloor(geometry.blockCoord(value), 16);
}
