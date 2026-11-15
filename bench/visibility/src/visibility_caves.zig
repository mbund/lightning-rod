const std = @import("std");
const game_data = @import("game_data");
const topology = @import("topology");
const assert = std.debug.assert;

pub const clearance_limit = 16;
const minimum_cover = 16;
const minimum_separation = 32;

pub const Kind = enum { tight, chamber, tall };

pub const Site = struct {
    kind: Kind,
    position: [3]i32,
    clearance: [5]u8,
    cover: u16,

    pub fn feet(self: Site) [3]i64 {
        return .{ @as(i64, self.position[0]) * 1000 + 500, @as(i64, self.position[1]) * 1000, @as(i64, self.position[2]) * 1000 + 500 };
    }
};

pub const Volume = struct {
    grid: topology.Grid,
    blocks: []const u16,

    pub fn at(self: Volume, point: [3]i32) ?u16 {
        const section = self.grid.index(.{ @divFloor(point[0], 16), @divFloor(point[1], 16), @divFloor(point[2], 16) }) orelse return null;
        const local: usize = @intCast(@mod(point[1], 16) * 256 + @mod(point[2], 16) * 16 + @mod(point[0], 16));
        return self.blocks[section * 4096 + local];
    }
};

const Candidate = struct {
    site: Site,
    score: usize,
    rank: u64,

    fn better(self: Candidate, other: Candidate) bool {
        return self.score > other.score or (self.score == other.score and self.rank < other.rank);
    }
};

pub fn select(volume: Volume, radius: usize) ![3]Site {
    assert(volume.blocks.len == volume.grid.count() * 4096);
    if (volume.grid.side <= 2 * radius + 1) return error.CaveSearchTooSmall;
    var result: [3]Site = undefined;
    for (&result, 0..) |*site, index| site.* = try find(volume, radius, @fromBackingInt(@intCast(index)), result[0..index]);
    return result;
}

fn find(volume: Volume, radius: usize, kind: Kind, previous: []const Site) !Site {
    var best: ?Candidate = null;
    const margin: i32 = @intCast(radius * 16);
    const minimum = [3]i32{ volume.grid.minimum[0] * 16 + margin, volume.grid.minimum[1] * 16, volume.grid.minimum[2] * 16 + margin };
    const maximum = [3]i32{ (volume.grid.minimum[0] + @as(i32, @intCast(volume.grid.side))) * 16 - margin, (volume.grid.minimum[1] + @as(i32, @intCast(volume.grid.height))) * 16, (volume.grid.minimum[2] + @as(i32, @intCast(volume.grid.side))) * 16 - margin };
    var z = minimum[2];
    while (z < maximum[2]) : (z += 1) {
        var x = minimum[0];
        while (x < maximum[0]) : (x += 1) {
            var cover: u16 = 0;
            var y = maximum[1] - 2;
            while (y > minimum[1]) : (y -= 1) {
                cover += @intFromBool(game_data.physics.rendering(volume.at(.{ x, y + 1, z }).?).occluder);
                if (cover < minimum_cover) continue;
                if (!game_data.physics.get(volume.at(.{ x, y, z }).?).air or !game_data.physics.get(volume.at(.{ x, y + 1, z }).?).air) continue;
                if (!game_data.physics.rendering(volume.at(.{ x, y - 1, z }).?).occluder) continue;
                var separate = true;
                for (previous) |site| {
                    var distance: i64 = 0;
                    for ([_]i32{ x, y, z }, site.position) |a, b| {
                        const delta = @as(i64, a) - b;
                        distance += delta * delta;
                    }
                    separate = separate and distance >= minimum_separation * minimum_separation;
                }
                if (!separate) continue;
                var clearance: [5]u8 = @splat(0);
                for ([_][3]i32{ .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 }, .{ 0, 1, 0 } }, 0..) |direction, index| {
                    var point: [3]i32 = .{ x, y + 1, z };
                    for (0..clearance_limit) |_| {
                        for (&point, direction) |*coordinate, delta| coordinate.* += delta;
                        const state = volume.at(point) orelse break;
                        if (!game_data.physics.get(state).air) break;
                        clearance[index] += 1;
                    }
                }
                const width = [2]usize{ @as(usize, clearance[0]) + clearance[1] + 1, @as(usize, clearance[2]) + clearance[3] + 1 };
                const narrow = @min(width[0], width[1]);
                const wide = @max(width[0], width[1]);
                var bytes: [12]u8 = undefined;
                for ([_]i32{ x, y, z }, 0..) |coordinate, index| std.mem.writeInt(i32, bytes[index * 4 ..][0..4], coordinate, .little);
                const rank = std.hash.Wyhash.hash(0x3ca7e91, &bytes);
                const score: usize = switch (kind) {
                    .tight => if (narrow <= 3 and wide >= 6) (4 - narrow) * 128 + wide else continue,
                    .chamber => if (@min(@min(clearance[0], clearance[1]), @min(clearance[2], clearance[3])) >= 2 and clearance[4] >= 3 and clearance[4] < 8) narrow * 32 + wide + clearance[4] else continue,
                    .tall => if (clearance[4] >= 8 and wide >= 5) @as(usize, clearance[4]) * 64 + narrow else continue,
                };
                const candidate: Candidate = .{ .site = .{ .kind = kind, .position = .{ x, y, z }, .clearance = clearance, .cover = cover }, .score = score, .rank = rank };
                if (best == null or candidate.better(best.?)) best = candidate;
            }
        }
    }
    return if (best) |candidate| candidate.site else error.MissingDistinctCaveSite;
}

fn fixture(allocator: std.mem.Allocator, mode: enum { normal, flooded, one_high }) !Volume {
    const grid: topology.Grid = .{ .minimum = .{ -3, -1, -3 }, .side = 7, .height = 4 };
    const blocks = try allocator.alloc(u16, grid.count() * 4096);
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    const water: u16 = @intCast(game_data.registry.block_water_default_state);
    for (0..grid.count()) |section| {
        const at = grid.position(section);
        for (blocks[section * 4096 ..][0..4096], 0..) |*state, index| {
            const x = at[0] * 16 + @as(i32, @intCast(index % 16));
            const y = at[1] * 16 + @as(i32, @intCast(index / 256));
            const z = at[2] * 16 + @as(i32, @intCast(index / 16 % 16));
            const tight = x >= -32 and x < 0 and z >= -24 and z < -23 and y >= -8 and y < (if (mode == .one_high) @as(i32, -7) else -6);
            const chamber = x >= 16 and x < 48 and z >= -32 and z < -8 and y >= -8 and y < (if (mode == .one_high) @as(i32, -7) else 0);
            const tall = x >= -32 and x < 0 and z >= 16 and z < 48 and y >= 0 and y < (if (mode == .one_high) @as(i32, 1) else 16);
            state.* = if (y >= 32) 0 else if (tight or chamber or tall) (if (mode == .flooded) water else 0) else stone;
        }
    }
    return .{ .grid = grid, .blocks = blocks };
}

test "cave viewpoints are deterministic walkable covered and separated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const volume = try fixture(arena.allocator(), .normal);
    const first = try select(volume, 1);
    try std.testing.expectEqual(first, try select(volume, 1));
    for (first, 0..) |site, index| {
        try std.testing.expectEqual(@as(Kind, @fromBackingInt(@intCast(index))), site.kind);
        try std.testing.expect(site.cover >= minimum_cover);
        try std.testing.expect(site.position[1] < 32);
        try std.testing.expect(game_data.physics.get(volume.at(site.position).?).air);
        var head = site.position;
        head[1] += 1;
        try std.testing.expect(game_data.physics.get(volume.at(head).?).air);
        var floor = site.position;
        floor[1] -= 1;
        try std.testing.expect(game_data.physics.rendering(volume.at(floor).?).occluder);
        for (first[0..index]) |previous| {
            var distance: i64 = 0;
            for (site.position, previous.position) |a, b| {
                const delta = @as(i64, a) - b;
                distance += delta * delta;
            }
            try std.testing.expect(distance >= minimum_separation * minimum_separation);
        }
    }
}

test "flooded caves single block gaps and surface air cannot replace missing cave samples" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    inline for (.{ .flooded, .one_high }) |mode| {
        const volume = try fixture(arena.allocator(), mode);
        try std.testing.expectError(error.MissingDistinctCaveSite, select(volume, 1));
    }
    const volume = try fixture(arena.allocator(), .normal);
    try std.testing.expectError(error.CaveSearchTooSmall, select(volume, 3));
}

test "distinct cave selection considers smaller rooms outside the highest scoring cluster" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var volume = try fixture(arena.allocator(), .normal);
    const blocks = try arena.allocator().dupe(u16, volume.blocks);
    volume.blocks = blocks;
    for (20..31) |x| for (20..31) |z| for (0..8) |height| {
        const y = @as(i32, @intCast(height)) - 8;
        const section = volume.grid.index(.{ @intCast(x / 16), @divFloor(y, 16), @intCast(z / 16) }).?;
        const local = @as(usize, @intCast(@mod(y, 16))) * 256 + z % 16 * 16 + x % 16;
        blocks[section * 4096 + local] = 0;
    };
    const first = try find(volume, 1, .chamber, &.{});
    try std.testing.expect(first.position[2] < 0);
    const second = try find(volume, 1, .chamber, &.{first});
    try std.testing.expect(second.position[0] >= 20 and second.position[0] < 31);
    try std.testing.expect(second.position[2] >= 20 and second.position[2] < 31);
}
