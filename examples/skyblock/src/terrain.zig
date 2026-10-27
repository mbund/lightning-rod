const std = @import("std");
const chunks = @import("chunks");
const game_data = @import("game_data");
const vanilla = @import("vanilla");

pub const Terrain = struct {
    pub const id = "minecraft:world_source";
    pub const Configuration = struct { kind: Kind };
    pub const Kind = enum { hub, island };
    pub const Dependencies = struct {
        registry_identity: *vanilla.RegistryIdentity,
        chunks: *vanilla.Chunks,
        worlds: *vanilla.VanillaWorlds,
    };

    deps: Dependencies,
    kind: Kind,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*Terrain {
        const self = try allocator.create(Terrain);
        self.* = .{ .deps = deps, .kind = config.kind };
        deps.chunks.setSource(chunks.Source.init(self, read));
        return self;
    }

    fn read(self: *Terrain, io: std.Io, batch: chunks.Source.Batch) void {
        for (batch.requests) |*request| request.result = self.readOne(io, request.section, request.output);
    }

    fn readOne(self: *Terrain, _: std.Io, section: chunks.Section, output: []u8) !usize {
        if (section.world != self.deps.worlds.overworld) return chunks.uniform(0, output);
        return generate(self.kind, section, output);
    }
};

fn block(kind: Terrain.Kind, x: i32, y: i32, z: i32) u16 {
    if (kind == .hub) return if (y == 64 and x >= -4 and x <= 4 and z >= -4 and z <= 4) game_data.registry.block_stone_default_state else 0;

    if (x >= -3 and x < 3 and z >= -3 and z < 3 and (x >= 0 or z >= 0)) {
        if (y == 64) return game_data.registry.block_grass_block_default_state;
        if (y == 62 or y == 63) return game_data.registry.block_dirt_default_state;
    }
    if (x == 1 and y == 65 and z == -2) return game_data.registry.block_chest_default_state;
    if (x == -2 and z == 1 and y >= 65 and y <= 69) return game_data.registry.block_oak_log_default_state;

    const dx = @abs(x + 2);
    const dz = @abs(z - 1);
    if ((y == 68 or y == 69) and dx <= 2 and dz <= 2 and (dx != 2 or dz != 2)) return game_data.registry.block_oak_leaves_default_state;
    if (y == 70 and dx <= 1 and dz <= 1) return game_data.registry.block_oak_leaves_default_state;
    if (y == 71 and dx + dz <= 1) return game_data.registry.block_oak_leaves_default_state;
    return 0;
}

fn generate(kind: Terrain.Kind, section: chunks.Section, output: []u8) usize {
    std.debug.assert(output.len >= 8193);
    if (section.x < -1 or section.x > 0 or section.z < -1 or section.z > 0 or section.y < 3 or section.y > 4 or
        (kind == .hub and section.y != 4)) return chunks.uniform(0, output);
    output[0] = 1;
    var occupied = false;
    for (0..4096) |index| {
        const x = section.x * 16 + @as(i32, @intCast(index % 16));
        const y = section.y * 16 + @as(i32, @intCast(index / 256));
        const z = section.z * 16 + @as(i32, @intCast(index / 16 % 16));
        const state = block(kind, x, y, z);
        occupied = occupied or state != 0;
        std.mem.writeInt(u16, output[1 + index * 2 ..][0..2], state, .little);
    }
    return if (occupied) 8193 else chunks.uniform(0, output);
}

test "starter island has an L shaped grass surface two dirt layers a tree and one chest" {
    var grass: usize = 0;
    var dirt: usize = 0;
    var logs: usize = 0;
    var chests: usize = 0;
    for (0..12) |yi| for (0..10) |zi| for (0..10) |xi| {
        const state = block(.island, @as(i32, @intCast(xi)) - 5, @as(i32, @intCast(yi)) + 61, @as(i32, @intCast(zi)) - 5);
        grass += @intFromBool(state == game_data.registry.block_grass_block_default_state);
        dirt += @intFromBool(state == game_data.registry.block_dirt_default_state);
        logs += @intFromBool(state == game_data.registry.block_oak_log_default_state);
        chests += @intFromBool(state == game_data.registry.block_chest_default_state);
    };
    try std.testing.expectEqual(@as(usize, 27), grass);
    try std.testing.expectEqual(@as(usize, 54), dirt);
    try std.testing.expectEqual(@as(usize, 5), logs);
    try std.testing.expectEqual(@as(usize, 1), chests);
    try std.testing.expectEqual(@as(u16, 0), block(.island, -1, 64, -1));
    try std.testing.expectEqual(@as(u16, 0), block(.island, 0, 61, 0));
    try std.testing.expectEqual(@as(u16, game_data.registry.block_oak_leaves_default_state), block(.island, -2, 71, 1));
}

test "hub is a single stone platform and section generation leaves the rest void" {
    var buffer: [8193]u8 = undefined;
    for ([_]Terrain.Kind{ .hub, .island }) |kind| {
        for ([_]chunks.Section{
            .{ .world = 0, .x = 0, .y = -4, .z = 0 },
            .{ .world = 0, .x = 0, .y = 0, .z = 0 },
            .{ .world = 0, .x = 0, .y = 5, .z = 0 },
            .{ .world = 0, .x = std.math.minInt(i32), .y = 4, .z = 0 },
            .{ .world = 0, .x = 0, .y = 4, .z = std.math.maxInt(i32) },
        }) |section| {
            try std.testing.expectEqual(@as(usize, 3), generate(kind, section, &buffer));
            try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, buffer[0..3]);
        }
    }
    var stone: usize = 0;
    for ([_]i32{ -1, 0 }) |x| for ([_]i32{ -1, 0 }) |z| {
        try std.testing.expectEqual(@as(usize, 8193), generate(.hub, .{ .world = 0, .x = x, .y = 4, .z = z }, &buffer));
        for (0..4096) |index| {
            const state = std.mem.readInt(u16, buffer[1 + index * 2 ..][0..2], .little);
            if (state != 0) {
                try std.testing.expectEqual(@as(u16, game_data.registry.block_stone_default_state), state);
                try std.testing.expect(index < 256);
                stone += 1;
            }
        }
    };
    try std.testing.expectEqual(@as(usize, 81), stone);
}
