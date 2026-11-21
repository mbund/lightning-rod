const std = @import("std");
const chunks = @import("chunks");
const game_data = @import("game_data");
const minecraft = @import("minecraft_model");

/// A cell of a trace outside the world's height: air, with no section behind it.
const void_air: u8 = std.math.maxInt(u8);

pub const Hit = struct { block: chunks.Position, state: u16, position: minecraft.Position, distance: f64 };

pub fn direction(rotation: minecraft.Rotation) [3]f64 {
    const yaw = @as(f64, rotation.yaw) * std.math.pi / 180;
    const pitch = @as(f64, rotation.pitch) * std.math.pi / 180;
    return .{ -@sin(yaw) * @cos(pitch), -@sin(pitch), @cos(yaw) * @cos(pitch) };
}

pub const Ray = struct {
    origin: [3]f64,
    direction: [3]f64,
    maximum: f64,
    cell: [3]i32,
    step: [3]i32,
    crossing: [3]f64,
    interval: [3]f64,
    distance: f64 = 0,

    pub fn init(origin: minecraft.Position, vector: [3]f64, maximum: f64) !Ray {
        const position: [3]f64 = .{ origin.x, origin.y, origin.z };
        if (!std.math.isFinite(maximum) or maximum < 0 or maximum > 1024) return error.InvalidRay;
        var length_squared: f64 = 0;
        for (position, vector) |at, component| {
            if (!std.math.isFinite(at) or @abs(at) > 30_000_000 or !std.math.isFinite(component)) return error.InvalidRay;
            length_squared += component * component;
        }
        if (!std.math.isFinite(length_squared) or length_squared == 0) return error.InvalidRay;
        const length = @sqrt(length_squared);
        var ray: Ray = .{ .origin = position, .direction = undefined, .maximum = maximum, .cell = undefined, .step = undefined, .crossing = undefined, .interval = undefined };
        for (0..3) |axis| {
            const component = vector[axis] / length;
            ray.direction[axis] = component;
            ray.cell[axis] = @intFromFloat(@floor(position[axis]));
            ray.step[axis] = if (component > 0) 1 else if (component < 0) -1 else 0;
            ray.interval[axis] = if (component == 0) std.math.inf(f64) else @abs(1 / component);
            ray.crossing[axis] = if (component == 0) std.math.inf(f64) else (@as(f64, @floatFromInt(ray.cell[axis] + @as(i32, if (component > 0) 1 else 0))) - position[axis]) / component;
        }
        return ray;
    }

    pub fn next(self: *Ray) ?chunks.Position {
        if (self.distance > self.maximum) return null;
        const result: chunks.Position = .{ .x = self.cell[0], .y = self.cell[1], .z = self.cell[2] };
        var axis: usize = 0;
        if (self.crossing[1] < self.crossing[axis]) axis = 1;
        if (self.crossing[2] < self.crossing[axis]) axis = 2;
        self.distance = self.crossing[axis];
        self.crossing[axis] += self.interval[axis];
        self.cell[axis] += self.step[axis];
        return result;
    }

    pub fn box(self: *const Ray, minimum: [3]f64, maximum: [3]f64) ?f64 {
        var enter: f64 = 0;
        var leave = self.maximum;
        for (0..3) |axis| {
            if (self.direction[axis] == 0) {
                if (self.origin[axis] < minimum[axis] or self.origin[axis] > maximum[axis]) return null;
                continue;
            }
            const a = (minimum[axis] - self.origin[axis]) / self.direction[axis];
            const b = (maximum[axis] - self.origin[axis]) / self.direction[axis];
            enter = @max(enter, @min(a, b));
            leave = @min(leave, @max(a, b));
            if (enter > leave) return null;
        }
        return enter;
    }
};

/// The blocks a world has, bottom first; above and below them is air, as vanilla's void air.
pub const Height = struct {
    minimum: i32,
    /// Exclusive.
    maximum: i32,

    pub const unbounded: Height = .{ .minimum = std.math.minInt(i32), .maximum = std.math.maxInt(i32) };

    pub fn contains(self: Height, y: i32) bool {
        return y >= self.minimum and y < self.maximum;
    }
};

/// Traces collision shapes. Fluids and blocks without collision are ignored.
pub fn trace(terrain: chunks.Chunks.Client, world: u32, origin: minecraft.Position, vector: [3]f64, maximum: f64) !?Hit {
    var window = chunks.ReadWindow(8).init(terrain);
    defer window.deinit();
    return traceIn(&window, world, .unbounded, origin, vector, maximum);
}

/// Traces through a window the caller keeps, so traces near each other share its sections.
/// Cells outside the height are air and read nothing.
pub fn traceIn(window: *chunks.ReadWindow(8), world: u32, height: Height, origin: minecraft.Position, vector: [3]f64, maximum: f64) !?Hit {
    var ray = try Ray.init(origin, vector, maximum);
    while (true) {
        var positions: [8]chunks.Position = undefined;
        // Eight cells lie in one or two sections more often than not: each is read once.
        var sections: [8]chunks.Section = undefined;
        var which: [8]u8 = undefined;
        var distinct: usize = 0;
        var count: usize = 0;
        while (count < positions.len) : (count += 1) {
            const position = ray.next() orelse break;
            positions[count] = position;
            if (!height.contains(position.y)) {
                which[count] = void_air;
                continue;
            }
            const section = chunks.sectionAt(world, position);
            const known = for (sections[0..distinct], 0..) |held, index| {
                if (std.meta.eql(held, section)) break index;
            } else blk: {
                sections[distinct] = section;
                distinct += 1;
                break :blk distinct - 1;
            };
            which[count] = @intCast(known);
        }
        if (count == 0) return null;
        var read: [8]chunks.View = undefined;
        if (distinct != 0) try window.readMany(sections[0..distinct], read[0..distinct]);
        for (positions[0..count], which[0..count]) |position, index| {
            if (index == void_air) continue;
            const state = read[index].get(chunks.localIndex(position));
            if (state >= game_data.registry.block_state_collision_shape.len) return error.Corrupt;
            const shape = game_data.registry.collision_shapes[game_data.registry.block_state_collision_shape[state]];
            var closest: ?f64 = null;
            for (game_data.registry.collision_boxes[shape.offset..][0..shape.count]) |box| {
                const base: [3]f64 = .{ @floatFromInt(position.x), @floatFromInt(position.y), @floatFromInt(position.z) };
                const hit = ray.box(.{ base[0] + @as(f64, @floatFromInt(box.min_x)) / 64, base[1] + @as(f64, @floatFromInt(box.min_y)) / 64, base[2] + @as(f64, @floatFromInt(box.min_z)) / 64 }, .{ base[0] + @as(f64, @floatFromInt(box.max_x)) / 64, base[1] + @as(f64, @floatFromInt(box.max_y)) / 64, base[2] + @as(f64, @floatFromInt(box.max_z)) / 64 }) orelse continue;
                closest = if (closest) |previous| @min(previous, hit) else hit;
            }
            if (closest) |distance| return .{ .block = position, .state = state, .distance = distance, .position = .{ .x = origin.x + ray.direction[0] * distance, .y = origin.y + ray.direction[1] * distance, .z = origin.z + ray.direction[2] * distance } };
        }
    }
}

test "ray traversal handles negative coordinates boundaries and range limits" {
    var ray = try Ray.init(.{ .x = -0.5, .y = 2.5, .z = 0.5 }, .{ -1, 0, 0 }, 2);
    for ([_]i32{ -1, -2, -3 }) |x| try std.testing.expectEqualDeep(chunks.Position{ .x = x, .y = 2, .z = 0 }, ray.next().?);
    try std.testing.expect(ray.next() == null);
    var boundary = try Ray.init(.{ .x = 0, .y = 0.5, .z = 0.5 }, .{ -1, 0, 0 }, 1);
    try std.testing.expectEqual(@as(i32, 0), boundary.next().?.x);
    try std.testing.expectEqual(@as(i32, -1), boundary.next().?.x);
    try std.testing.expectEqual(@as(f64, 0), boundary.box(.{ -1, 0, 0 }, .{ 0, 1, 1 }).?);
    try std.testing.expectError(error.InvalidRay, Ray.init(.{ .x = 0, .y = 0, .z = 0 }, .{ 0, 0, 0 }, 10));
}
