const std = @import("std");
const registry = @import("registry_data");

pub const coordinate_scale: f64 = 64.0;

pub const Axis = enum { x, y, z };

pub const Movement = extern struct {
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,

    pub fn component(self: Movement, axis: Axis) f64 {
        return switch (axis) {
            .x => self.x,
            .y => self.y,
            .z => self.z,
        };
    }

    pub fn withComponent(self: Movement, axis: Axis, value: f64) Movement {
        var result = self;
        switch (axis) {
            .x => result.x = value,
            .y => result.y = value,
            .z => result.z = value,
        }
        return result;
    }
};

pub const Box = extern struct {
    min_x: f64,
    min_y: f64,
    min_z: f64,
    max_x: f64,
    max_y: f64,
    max_z: f64,

    pub fn offset(self: Box, movement: Movement) Box {
        return .{
            .min_x = self.min_x + movement.x,
            .min_y = self.min_y + movement.y,
            .min_z = self.min_z + movement.z,
            .max_x = self.max_x + movement.x,
            .max_y = self.max_y + movement.y,
            .max_z = self.max_z + movement.z,
        };
    }

    pub fn stretch(self: Box, movement: Movement) Box {
        return .{
            .min_x = self.min_x + @min(movement.x, 0),
            .min_y = self.min_y + @min(movement.y, 0),
            .min_z = self.min_z + @min(movement.z, 0),
            .max_x = self.max_x + @max(movement.x, 0),
            .max_y = self.max_y + @max(movement.y, 0),
            .max_z = self.max_z + @max(movement.z, 0),
        };
    }

    pub fn intersects(self: Box, other: Box) bool {
        return self.max_x > other.min_x and self.min_x < other.max_x and
            self.max_y > other.min_y and self.min_y < other.max_y and
            self.max_z > other.min_z and self.min_z < other.max_z;
    }
};

pub fn segmentIntersectsBox(start: Movement, end: Movement, box: Box) bool {
    var minimum: f64 = 0;
    var maximum: f64 = 1;
    for ([_]Axis{ .x, .y, .z }) |axis| {
        const from = start.component(axis);
        const direction = end.component(axis) - from;
        const box_min, const box_max = switch (axis) {
            .x => .{ box.min_x, box.max_x },
            .y => .{ box.min_y, box.max_y },
            .z => .{ box.min_z, box.max_z },
        };
        if (direction == 0) {
            if (from < box_min or from > box_max) return false;
            continue;
        }
        var near = (box_min - from) / direction;
        var far = (box_max - from) / direction;
        if (near > far) std.mem.swap(f64, &near, &far);
        minimum = @max(minimum, near);
        maximum = @min(maximum, far);
        if (minimum > maximum) return false;
    }
    return maximum >= 0 and minimum <= 1;
}

pub fn entityBox(x: f64, y: f64, z: f64, width: f32, height: f32) Box {
    const half_width = @as(f64, width) / 2.0;
    return .{
        .min_x = x - half_width,
        .min_y = y,
        .min_z = z - half_width,
        .max_x = x + half_width,
        .max_y = y + @as(f64, height),
        .max_z = z + half_width,
    };
}

pub fn shapeBoxes(block_state: i32) []const registry.CollisionBox {
    if (block_state < 0 or block_state >= registry.block_state_collision_shape.len) return &.{};
    const shape_id = registry.block_state_collision_shape[@intCast(block_state)];
    const shape = registry.collision_shapes[shape_id];
    return registry.collision_boxes[shape.offset..][0..shape.count];
}

pub fn hasFullSquareTopSupport(block_state: i32) bool {
    const name = registry.blockStateName(block_state) orelse return false;
    const base_name = name[0 .. std.mem.indexOfScalar(u8, name, '[') orelse name.len];
    if (std.mem.endsWith(u8, base_name, "_leaves")) return false;

    for (0..64) |z| {
        var covered: u64 = 0;
        for (shapeBoxes(block_state)) |box| {
            if (box.max_y != 64 or box.min_z > z or box.max_z <= z) continue;
            const min_x: u6 = @intCast(@max(box.min_x, 0));
            const max_x: u7 = @intCast(@min(box.max_x, 64));
            if (max_x <= min_x) continue;
            const width: u7 = max_x - min_x;
            const mask = if (width == 64)
                std.math.maxInt(u64)
            else
                ((@as(u64, 1) << @intCast(width)) - 1) << min_x;
            covered |= mask;
        }
        if (covered != std.math.maxInt(u64)) return false;
    }
    return true;
}

pub fn worldBox(box: registry.CollisionBox, block_x: i32, block_y: i32, block_z: i32) Box {
    return .{
        .min_x = @as(f64, @floatFromInt(block_x)) + @as(f64, @floatFromInt(box.min_x)) / coordinate_scale,
        .min_y = @as(f64, @floatFromInt(block_y)) + @as(f64, @floatFromInt(box.min_y)) / coordinate_scale,
        .min_z = @as(f64, @floatFromInt(block_z)) + @as(f64, @floatFromInt(box.min_z)) / coordinate_scale,
        .max_x = @as(f64, @floatFromInt(block_x)) + @as(f64, @floatFromInt(box.max_x)) / coordinate_scale,
        .max_y = @as(f64, @floatFromInt(block_y)) + @as(f64, @floatFromInt(box.max_y)) / coordinate_scale,
        .max_z = @as(f64, @floatFromInt(block_z)) + @as(f64, @floatFromInt(box.max_z)) / coordinate_scale,
    };
}

pub fn clipAxis(axis: Axis, moving: Box, obstacle: Box, requested: f64) f64 {
    if (requested == 0) return 0;
    const overlaps_other_axes = switch (axis) {
        .x => moving.max_y > obstacle.min_y and moving.min_y < obstacle.max_y and moving.max_z > obstacle.min_z and moving.min_z < obstacle.max_z,
        .y => moving.max_x > obstacle.min_x and moving.min_x < obstacle.max_x and moving.max_z > obstacle.min_z and moving.min_z < obstacle.max_z,
        .z => moving.max_x > obstacle.min_x and moving.min_x < obstacle.max_x and moving.max_y > obstacle.min_y and moving.min_y < obstacle.max_y,
    };
    if (!overlaps_other_axes) return requested;

    const moving_min, const moving_max, const obstacle_min, const obstacle_max = switch (axis) {
        .x => .{ moving.min_x, moving.max_x, obstacle.min_x, obstacle.max_x },
        .y => .{ moving.min_y, moving.max_y, obstacle.min_y, obstacle.max_y },
        .z => .{ moving.min_z, moving.max_z, obstacle.min_z, obstacle.max_z },
    };
    if (requested > 0 and moving_max <= obstacle_min) return @min(requested, obstacle_min - moving_max);
    if (requested < 0 and moving_min >= obstacle_max) return @max(requested, obstacle_max - moving_min);
    return requested;
}

test "generated air and stone collision shapes are exact" {
    try std.testing.expectEqual(@as(usize, 0), shapeBoxes(registry.block_air_default_state).len);
    const stone = shapeBoxes(registry.block_stone_default_state);
    try std.testing.expectEqual(@as(usize, 1), stone.len);
    try std.testing.expectEqual(registry.CollisionBox{ .min_x = 0, .min_y = 0, .min_z = 0, .max_x = 64, .max_y = 64, .max_z = 64 }, stone[0]);
}

test "top support uses the support face rather than collision volume" {
    try std.testing.expect(hasFullSquareTopSupport(registry.block_stone_default_state));
    try std.testing.expect(!hasFullSquareTopSupport(registry.block_oak_leaves_default_state));
    const top_slab = registry.blockStateId("minecraft:oak_slab[type=top,waterlogged=false]").?;
    const bottom_slab = registry.blockStateId("minecraft:oak_slab[type=bottom,waterlogged=false]").?;
    try std.testing.expect(hasFullSquareTopSupport(top_slab));
    try std.testing.expect(!hasFullSquareTopSupport(bottom_slab));
}

test "axis clipping stops an entity at a full cube boundary" {
    const moving = Box{ .min_x = 0, .min_y = 1, .min_z = 0, .max_x = 0.6, .max_y = 2.95, .max_z = 0.6 };
    const obstacle = Box{ .min_x = 1, .min_y = 1, .min_z = 0, .max_x = 2, .max_y = 2, .max_z = 1 };
    try std.testing.expectEqual(@as(f64, 0.4), clipAxis(.x, moving, obstacle, 1));
}

test "segment intersection handles hits misses and parallel axes" {
    const box = Box{ .min_x = 1, .min_y = 1, .min_z = 1, .max_x = 2, .max_y = 2, .max_z = 2 };
    try std.testing.expect(segmentIntersectsBox(.{ .x = 0, .y = 1.5, .z = 1.5 }, .{ .x = 3, .y = 1.5, .z = 1.5 }, box));
    try std.testing.expect(!segmentIntersectsBox(.{ .x = 0, .y = 2.5, .z = 1.5 }, .{ .x = 3, .y = 2.5, .z = 1.5 }, box));
}
