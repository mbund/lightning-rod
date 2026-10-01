const std = @import("std");
const chunks = @import("chunks");
const entities = @import("entities");
const registry = @import("game_data").registry;

const assert = std.debug.assert;

pub const ItemPhysics = struct {
    pub const id = "minecraft:item_physics";

    pub const Configuration = struct {};

    pub const Dependencies = struct { chunks: *chunks.Chunks };

    pub const Result = struct {
        body: entities.State,
        on_ground: bool,
        crossed_block: bool,
    };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*ItemPhysics {
        const self = try allocator.create(ItemPhysics);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn advance(self: *ItemPhysics, entity_id: u32, ticks: u32, body: entities.State, on_ground: bool) !Result {
        assert(entity_id > 0);
        var next = body;

        for (body.position ++ body.velocity) |value| assert(std.math.isFinite(value));
        next.velocity[1] -= 0.04;
        var grounded = on_ground;
        if (!on_ground or next.velocity[0] * next.velocity[0] + next.velocity[2] * next.velocity[2] > @as(f64, @as(f32, 0.00001)) or
            (ticks +% entity_id) % 4 == 0)
        {
            const order: [3]usize = if (@abs(next.velocity[0]) < @abs(next.velocity[2])) .{ 1, 2, 0 } else .{ 1, 0, 2 };

            for (order) |axis| {
                const requested = next.velocity[axis];
                if (requested == 0) continue;

                var movement = requested;
                const minimum: [3]f64 = .{ next.position[0] - 0.125, next.position[1], next.position[2] - 0.125 };
                const maximum: [3]f64 = .{ next.position[0] + 0.125, next.position[1] + 0.25, next.position[2] + 0.125 };
                var first: [3]i32 = undefined;
                var last: [3]i32 = undefined;

                for (0..3) |a| {
                    first[a] = @intFromFloat(@floor(minimum[a] + if (a == axis) @min(requested, 0) else 0) - 1);
                    last[a] = @intFromFloat(@floor(maximum[a] + if (a == axis) @max(requested, 0) else 0) + 1);
                }

                const sx = @divFloor(first[0], 16);
                const sy = @divFloor(first[1], 16);
                const sz = @divFloor(first[2], 16);
                const nx: usize = @intCast(@divFloor(last[0], 16) - sx + 1);
                const ny: usize = @intCast(@divFloor(last[1], 16) - sy + 1);
                const nz: usize = @intCast(@divFloor(last[2], 16) - sz + 1);
                var cursor: usize = 0;

                while (cursor < nx * ny * nz) {
                    var sections: [8]chunks.Section = undefined;
                    var leases: [8]chunks.Lease = undefined;
                    const count = @min(sections.len, self.deps.chunks.cache.entries.len, nx * ny * nz - cursor);
                    assert(count > 0);

                    for (sections[0..count], 0..) |*section, i| {
                        const at = cursor + i;
                        section.* = .{
                            .world = body.world,
                            .x = sx + @as(i32, @intCast(at % nx)),
                            .z = sz + @as(i32, @intCast(at / nx % nz)),
                            .y = sy + @as(i32, @intCast(at / nx / nz)),
                        };
                    }

                    try self.deps.chunks.acquireMany(sections[0..count], leases[0..count]);
                    defer for (leases[0..count]) |lease| lease.release();
                    cursor += count;

                    for (sections[0..count], leases[0..count]) |section, lease| {
                        var y = @max(first[1], section.y * 16);

                        while (y <= @min(last[1], section.y * 16 + 15)) : (y += 1) {
                            var z = @max(first[2], section.z * 16);

                            while (z <= @min(last[2], section.z * 16 + 15)) : (z += 1) {
                                var x = @max(first[0], section.x * 16);

                                while (x <= @min(last[0], section.x * 16 + 15)) : (x += 1) {
                                    const state = lease.get(chunks.localIndex(.{ .x = x, .y = y, .z = z }));
                                    if (state >= registry.block_state_collision_shape.len) return error.Corrupt;

                                    const shape = registry.collision_shapes[registry.block_state_collision_shape[state]];
                                    const offset: [3]f64 = .{ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) };

                                    for (registry.collision_boxes[shape.offset..][0..shape.count]) |box| {
                                        const low: [3]f64 = .{ offset[0] + @as(f64, @floatFromInt(box.min_x)) / 64, offset[1] + @as(f64, @floatFromInt(box.min_y)) / 64, offset[2] + @as(f64, @floatFromInt(box.min_z)) / 64 };
                                        const high: [3]f64 = .{ offset[0] + @as(f64, @floatFromInt(box.max_x)) / 64, offset[1] + @as(f64, @floatFromInt(box.max_y)) / 64, offset[2] + @as(f64, @floatFromInt(box.max_z)) / 64 };
                                        const a = (axis + 1) % 3;
                                        const b = (axis + 2) % 3;
                                        if (maximum[a] <= low[a] + 1e-7 or minimum[a] >= high[a] - 1e-7 or
                                            maximum[b] <= low[b] + 1e-7 or minimum[b] >= high[b] - 1e-7) continue;

                                        if (movement > 0 and maximum[axis] <= low[axis] + 1e-7) movement = @min(movement, @max(0, low[axis] - maximum[axis]));

                                        if (movement < 0 and minimum[axis] >= high[axis] - 1e-7) movement = @max(movement, @min(0, high[axis] - minimum[axis]));
                                    }
                                }
                            }
                        }
                    }
                }

                next.position[axis] += movement;

                if (axis == 1) grounded = requested < 0 and requested != movement;

                if (requested != movement) next.velocity[axis] = 0;
            }

            var friction: f32 = 0.98;
            if (grounded) {
                const below = try self.deps.chunks.getBlock(body.world, .{
                    .x = @intFromFloat(@floor(next.position[0])),
                    .y = @intFromFloat(@floor(next.position[1] - @as(f64, @as(f32, 0.999999)))),
                    .z = @intFromFloat(@floor(next.position[2])),
                });
                const name = registry.blockStateName(below) orelse return error.Corrupt;
                const slipperiness: f32 = if (std.mem.eql(u8, name, "minecraft:slime_block")) 0.8 else if (std.mem.eql(u8, name, "minecraft:blue_ice")) 0.989 else if (std.mem.eql(u8, name, "minecraft:ice") or std.mem.eql(u8, name, "minecraft:packed_ice") or std.mem.startsWith(u8, name, "minecraft:frosted_ice[")) 0.98 else 0.6;
                friction *= slipperiness;
            }

            next.velocity[0] *= friction;
            next.velocity[1] *= 0.98;
            next.velocity[2] *= friction;

            if (grounded and next.velocity[1] < 0) next.velocity[1] *= -0.5;
        }

        var crossed = false;

        for (body.position, next.position) |before, after| crossed = crossed or @floor(before) != @floor(after);
        return .{ .body = next, .on_ground = grounded, .crossed_block = crossed };
    }
};
