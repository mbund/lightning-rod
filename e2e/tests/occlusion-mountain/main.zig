const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const protocols = @import("protocols");
const e2e = @import("e2e");

pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.replace(e2e.profile.plugins(), .{
        lightning_rod.plugin.configured(vanilla.Players, .{ .maximum = 1, .render_distance = 32, .spawn = .{ .x = -224, .y = 112, .z = 0 } }),
        lightning_rod.plugin.configured(vanilla.Streaming, .{ .prefetch = 3 }),
        lightning_rod.plugin.configured(Mountain, .{}),
    });
    try e2e.profile.run(init, plugins, .{});
}

const Mountain = struct {
    pub const id = vanilla.Flat.id;
    pub const Configuration = struct {};
    pub const Dependencies = struct { chunks: *vanilla.Chunks };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Mountain {
        const self = try allocator.create(Mountain);
        self.* = .{};
        deps.chunks.setSource(vanilla.ChunkSource.init(self, read));
        return self;
    }

    fn read(_: *Mountain, _: std.Io, batch: vanilla.ChunkSource.Batch) void {
        for (batch.requests) |*request| request.result = section(request.section, request.output);
    }

    fn uniformSection(state: u16, output: []u8) usize {
        output[0] = 0;
        std.mem.writeInt(u16, output[1..3], state, .little);
        return 3;
    }

    fn section(at: vanilla.Section, output: []u8) usize {
        const stone: u16 = @intCast(protocols.registry.block_stone_default_state);
        if (at.y < 4 and at.y != 1) return uniformSection(stone, output);
        const x0 = at.x * 16;
        const z0 = at.z * 16;
        const near_x = @min(@abs(x0), @abs(x0 + 15));
        const near_z = @min(@abs(z0), @abs(z0 + 15));
        const far_x = @max(@abs(x0), @abs(x0 + 15));
        const far_z = @max(@abs(z0), @abs(z0 + 15));
        const highest = 64 + @max(0, 192 - @as(i32, @intCast((near_x + near_z) * 3 / 2)));
        const lowest = 64 + @max(0, 192 - @as(i32, @intCast((far_x + far_z) * 3 / 2)));
        if (at.y * 16 > highest) return uniformSection(0, output);
        if (at.y != 1 and at.y * 16 + 15 < lowest) return uniformSection(stone, output);
        var heights: [256]i32 = undefined;
        for (&heights, 0..) |*height, index| {
            const x = x0 + @as(i32, @intCast(index % 16));
            const z = z0 + @as(i32, @intCast(index / 16));
            height.* = 64 + @max(0, 192 - @as(i32, @intCast((@abs(x) + @abs(z)) * 3 / 2)));
        }
        output[0] = 1;
        var first: u16 = 0;
        var uniform = true;
        for (0..4096) |index| {
            const x = at.x * 16 + @as(i32, @intCast(index % 16));
            const y = at.y * 16 + @as(i32, @intCast(index / 256));
            const z = at.z * 16 + @as(i32, @intCast(index / 16 % 16));
            const height = heights[index % 256];
            const cave = y >= 20 and y < 28 and @mod(x, 64) >= 8 and @mod(x, 64) < 16 and @mod(z, 64) >= 8 and @mod(z, 64) < 16;
            const state: u16 = if (y > height or cave) 0 else if (y == height) @intCast(if (height >= 192) protocols.registry.block_snow_block_default_state else protocols.registry.block_grass_block_default_state) else stone;
            if (index == 0) first = state;
            uniform = uniform and state == first;
            std.mem.writeInt(u16, output[1 + index * 2 ..][0..2], state, .little);
        }
        return if (uniform) uniformSection(first, output) else 8193;
    }
};
