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
        // The three axes at once, each lane the same operations as one axis alone.
        const V = @Vector(3, f64);
        const zero: V = @splat(0);
        const at: V = position;
        const component: V = @as(V, vector) / @as(V, @splat(length));
        const cell = @floor(at);
        const ahead = component > zero;
        const still = component == zero;
        const infinite: V = @splat(std.math.inf(f64));
        const boundary = cell + @select(f64, ahead, @as(V, @splat(1)), zero);
        return .{
            .origin = position,
            .direction = component,
            .maximum = maximum,
            .cell = @as(@Vector(3, i32), @intFromFloat(cell)),
            .step = @select(i32, ahead, @as(@Vector(3, i32), @splat(1)), @select(i32, component < zero, @as(@Vector(3, i32), @splat(-1)), @as(@Vector(3, i32), @splat(0)))),
            .crossing = @select(f64, still, infinite, (boundary - at) / component),
            .interval = @select(f64, still, infinite, @abs(@as(V, @splat(1)) / component)),
        };
    }

    /// Ray.init as it was, an axis at a time, for tests to hold the vector form to.
    fn initScalar(origin: minecraft.Position, vector: [3]f64, maximum: f64) Ray {
        const position: [3]f64 = .{ origin.x, origin.y, origin.z };
        const length = @sqrt(vector[0] * vector[0] + vector[1] * vector[1] + vector[2] * vector[2]);
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
    if (outside(height, origin.y, vector[1], maximum, vector)) return null;
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

/// Whether every cell of a trace lies above or below the world's blocks, where all is air. The
/// cells a ray visits lie between the floors of its two ends' heights.
fn outside(height: Height, y: f64, rise: f64, maximum: f64, vector: [3]f64) bool {
    const length = @sqrt(vector[0] * vector[0] + vector[1] * vector[1] + vector[2] * vector[2]);
    if (!std.math.isFinite(length) or length == 0 or !std.math.isFinite(y)) return false;
    // The ray stops past the cell its end is in, so the end is reached in full and a cell further.
    const end = y + rise / length * (maximum + 1);
    const low = @floor(@min(y, end));
    const high = @floor(@max(y, end));
    return low >= @as(f64, @floatFromInt(height.maximum)) or high < @as(f64, @floatFromInt(height.minimum));
}

test "vector ray setup matches the axis at a time setup bit for bit" {
    var random = std.Random.DefaultPrng.init(0x7261_7973);
    for (0..10_000) |_| {
        const r = random.random();
        const origin: minecraft.Position = .{ .x = (r.float(f64) - 0.5) * 2e5, .y = (r.float(f64) - 0.5) * 600, .z = (r.float(f64) - 0.5) * 2e5 };
        var vector: [3]f64 = undefined;
        for (&vector) |*axis| axis.* = switch (r.uintLessThan(u8, 4)) {
            0 => 0,
            1 => (r.float(f64) - 0.5) * 8,
            2 => -r.float(f64) * 1e-9,
            else => r.float(f64) * 100,
        };
        if (vector[0] == 0 and vector[1] == 0 and vector[2] == 0) vector[1] = -0.05;
        const fast = try Ray.init(origin, vector, 4);
        const slow = Ray.initScalar(origin, vector, 4);
        try std.testing.expectEqual(slow.cell, fast.cell);
        try std.testing.expectEqual(slow.step, fast.step);
        for (0..3) |axis| {
            try std.testing.expectEqual(@as(u64, @bitCast(slow.direction[axis])), @as(u64, @bitCast(fast.direction[axis])));
            try std.testing.expectEqual(@as(u64, @bitCast(slow.crossing[axis])), @as(u64, @bitCast(fast.crossing[axis])));
            try std.testing.expectEqual(@as(u64, @bitCast(slow.interval[axis])), @as(u64, @bitCast(fast.interval[axis])));
        }
    }
}

test "a trace wholly above or below the world reads nothing" {
    const height: Height = .{ .minimum = -64, .maximum = 320 };
    try std.testing.expect(outside(height, 4000, -5, 5, .{ 0, -5, 0 }));
    try std.testing.expect(outside(height, -200, 3, 3, .{ 0, 3, 0 }));
    // Its last cell reaches the top block: it must be traced.
    try std.testing.expect(!outside(height, 323.5, -3, 3, .{ 0, -3, 0 }));
    try std.testing.expect(!outside(height, 100, -5, 5, .{ 0, -5, 0 }));
    try std.testing.expect(!outside(.unbounded, 1e9, 0, 1, .{ 1, 0, 0 }));
}
