const std = @import("std");
const geometry = @import("bounds.zig");
const production = @import("section_visibility_world.zig");
const lighting = @import("lighting.zig");
const game_data = @import("game_data");

const Fixture = struct {
    const count = 8;
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    world: production.World,
    states: []u16,
    sections: [9 * count]lighting.Section = undefined,
    disclosed: u32 = 0,
    column: production.Column = .{ .world = 3, .x = 0, .z = 0, .minimum = -4 },

    fn init(allocator: std.mem.Allocator) !*Fixture {
        const self = try allocator.create(Fixture);
        self.* = .{
            .world = try .init(allocator, .{ .columns = 9, .sources = 1, .radius = 1 }),
            .states = try allocator.alloc(u16, count * 16 * 48 * 48),
        };
        for (0..9) |neighbor| for (0..count) |y| {
            self.sections[neighbor * count + y] = .{ .stamp = .{}, .view = .{ .rows = self.states[(y * 16 * 48 + neighbor / 3 * 16) * 48 + neighbor % 3 * 16 ..] } };
        };
        return self;
    }

    fn set(self: *Fixture, point: [3]i32, state: u16) void {
        const x: usize = @intCast(point[0] + 16);
        const y: usize = @intCast(point[1] + 64);
        const z: usize = @intCast(point[2] + 16);
        self.states[(y * 48 + z) * 48 + x] = state;
    }

    fn fill(self: *Fixture, box: geometry.Box, state: u16) void {
        var y = box.minimum[1];
        while (y < box.maximum[1]) : (y += 1) {
            var z = box.minimum[2];
            while (z < box.maximum[2]) : (z += 1) {
                var x = box.minimum[0];
                while (x < box.maximum[0]) : (x += 1) self.set(.{ x, y, z }, state);
            }
        }
    }

    fn learn(self: *Fixture) void {
        self.world.invalidate();
        for (0..9) |neighbor| {
            var column = self.column;
            column.x += @as(i32, @intCast(neighbor % 3)) - 1;
            column.z += @as(i32, @intCast(neighbor / 3)) - 1;
            self.world.learn(column, self.sections[neighbor * count ..][0..count]);
        }
    }

    fn disclose(self: *Fixture, eye: [3]i32) !void {
        var source_storage: production.Source = undefined;
        const source = self.world.source(self.column.world, self.column.minimum, count, eye, &source_storage).?;
        self.world.beginPoll();
        const query = self.world.query(source, self.column.minimum, count, 1);
        while (!self.world.ready(query)) try std.testing.expectEqual(@as(usize, 0), self.world.advance().requests.len);
        self.disclosed = self.world.mask(query, self.column.x, self.column.z);
    }

    fn visible(self: *const Fixture, point: [3]i32) bool {
        const section: u5 = @intCast(@divFloor(point[1], 16) - self.column.minimum);
        return self.disclosed & (@as(u32, 1) << section) != 0;
    }

    fn at(self: *const Fixture, point: [3]i32) ?u16 {
        const x = point[0] + 16;
        const y = point[1] + 64;
        const z = point[2] + 16;
        if (x < 0 or x >= 48 or z < 0 or z >= 48 or y < 0 or y >= count * 16) return null;
        return self.states[@as(usize, @intCast((y * 48 + z) * 48 + x))];
    }

    fn witness(self: *Fixture, eye: [3]i32, target: [3]i32) bool {
        var cell = eye;
        var direction: [3]i64 = undefined;
        var numerator: [3]i64 = undefined;
        var denominator: [3]i64 = undefined;
        for (0..3) |axis| {
            const fraction: i64 = 37 + @as(i64, @intCast(axis)) * 13;
            direction[axis] = (@as(i64, target[axis]) - eye[axis]) * 100 + 50 - fraction;
            denominator[axis] = @intCast(@abs(direction[axis]));
            numerator[axis] = if (direction[axis] > 0) 100 - fraction else fraction;
        }
        for (0..256) |_| {
            if (std.meta.eql(cell, target)) return true;
            if (game_data.physics.rendering(self.at(cell) orelse Fixture.stone).occluder) return false;
            var first: ?usize = null;
            for (0..3) |axis| {
                if (denominator[axis] == 0) continue;
                if (first == null or numerator[axis] * denominator[first.?] < numerator[first.?] * denominator[axis]) first = axis;
            }
            const chosen = first orelse return false;
            for (0..3) |axis| if (axis != chosen and denominator[axis] != 0 and numerator[axis] * denominator[chosen] == numerator[chosen] * denominator[axis]) return false;
            cell[chosen] += if (direction[chosen] > 0) @as(i32, 1) else -1;
            numerator[chosen] += 100;
        }
        return false;
    }
};

test "section disclosure separates surface observers and sealed caves at different depths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fixture = try Fixture.init(arena.allocator());
    for ([_]u16{ Fixture.stone, @intCast(game_data.registry.block_netherrack_default_state) }) |wall| {
        @memset(fixture.states, wall);
        fixture.fill(.{ .minimum = .{ -16, 9, -16 }, .maximum = .{ 32, 64, 32 } }, 0);
        fixture.fill(.{ .minimum = .{ 2, -24, 2 }, .maximum = .{ 7, -16, 7 } }, 0);
        fixture.fill(.{ .minimum = .{ 10, -56, 10 }, .maximum = .{ 15, -48, 15 } }, 0);
        fixture.set(.{ 4, -20, 4 }, @intCast(game_data.registry.block_spawner_default_state));
        fixture.set(.{ 12, -52, 12 }, @intCast(game_data.registry.block_lava_default_state));
        fixture.learn();
        try fixture.disclose(.{ 4, 52, 4 });
        try std.testing.expect(fixture.visible(.{ 4, 8, 4 }));
        try std.testing.expect(!fixture.visible(.{ 4, -20, 4 }));
        try std.testing.expect(!fixture.visible(.{ 12, -52, 12 }));
        try fixture.disclose(.{ 3, -22, 3 });
        try std.testing.expect(fixture.visible(.{ 4, -20, 4 }));
        try std.testing.expect(fixture.visible(.{ 4, -16, 4 }));
        try std.testing.expect(!fixture.visible(.{ 12, -52, 12 }));
        try std.testing.expect(!fixture.visible(.{ 4, 52, 4 }));
    }
}

test "air cover preserves a visible ceiling on the first layer of its section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fixture = try Fixture.init(arena.allocator());
    @memset(fixture.states, Fixture.stone);
    fixture.fill(.{ .minimum = .{ -16, 49, -16 }, .maximum = .{ 32, 64, 32 } }, 0);
    fixture.fill(.{ .minimum = .{ 0, 17, 0 }, .maximum = .{ 16, 32, 16 } }, 0);
    fixture.learn();
    try fixture.disclose(.{ 4, 24, 4 });
    try std.testing.expect(fixture.visible(.{ 4, 32, 4 }));
    try std.testing.expect(!fixture.visible(.{ 4, 48, 4 }));
}

test "opening and closing a shaft invalidates section disclosure certificates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fixture = try Fixture.init(arena.allocator());
    @memset(fixture.states, Fixture.stone);
    fixture.fill(.{ .minimum = .{ -16, 9, -16 }, .maximum = .{ 32, 64, 32 } }, 0);
    fixture.fill(.{ .minimum = .{ 2, -24, 2 }, .maximum = .{ 7, -16, 7 } }, 0);
    fixture.fill(.{ .minimum = .{ 4, -16, 4 }, .maximum = .{ 5, 8, 5 } }, 0);
    fixture.learn();
    const eye: [3]i32 = .{ 4, 10, 4 };
    try fixture.disclose(eye);
    try std.testing.expect(!fixture.visible(.{ 4, -20, 4 }));
    fixture.set(.{ 4, 8, 4 }, 0);
    fixture.world.changed(3, fixture.column.minimum, .{ .minimum = .{ 4, 8, 4 }, .maximum = .{ 5, 9, 5 } });
    fixture.world.learn(fixture.column, fixture.sections[4 * Fixture.count ..][0..Fixture.count]);
    try fixture.disclose(eye);
    try std.testing.expect(fixture.visible(.{ 4, -20, 4 }));
    fixture.set(.{ 4, 8, 4 }, Fixture.stone);
    fixture.world.changed(3, fixture.column.minimum, .{ .minimum = .{ 4, 8, 4 }, .maximum = .{ 5, 9, 5 } });
    fixture.world.learn(fixture.column, fixture.sections[4 * Fixture.count ..][0..Fixture.count]);
    try fixture.disclose(eye);
    try std.testing.expect(!fixture.visible(.{ 4, -20, 4 }));
}

test "section disclosure preserves independent exact voxel ray witnesses through windows and irregular terrain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fixture = try Fixture.init(arena.allocator());
    var random: std.Random.DefaultPrng = .init(0xab62f17);
    var witnesses: usize = 0;
    for (0..12) |scene| {
        @memset(fixture.states, 0);
        fixture.fill(.{ .minimum = .{ -16, -64, -16 }, .maximum = .{ 32, 0, 32 } }, Fixture.stone);
        for (0..48) |z| for (0..48) |x| {
            const wx = @as(i32, @intCast(x)) - 16;
            const wz = @as(i32, @intCast(z)) - 16;
            for (0..64) |y| {
                const wall = (wx == 8 or wz == 8) and y < 48 and !(y >= 8 and y < 12 and @mod(wx + wz, 7) == scene % 7);
                const roof = y == 16 + (x + z) % 5 and !(wx >= 2 and wx <= 6 and wz >= 2 and wz <= 6);
                if (wall or roof) fixture.set(.{ wx, @intCast(y), wz }, Fixture.stone);
            }
        };
        if (scene % 2 == 0) fixture.fill(.{ .minimum = .{ 8, 8, 2 }, .maximum = .{ 9, 12, 7 } }, @intCast(game_data.registry.block_glass_default_state));
        fixture.fill(.{ .minimum = .{ 9, 24, 9 }, .maximum = .{ 16, 56, 16 } }, Fixture.stone);
        fixture.fill(.{ .minimum = .{ 10, 25, 10 }, .maximum = .{ 15, 55, 15 } }, 0);
        fixture.learn();
        const eye: [3]i32 = .{ 4, 9, 4 };
        try fixture.disclose(eye);
        for (0..1024) |_| {
            const point: [3]i32 = .{ random.random().uintLessThan(u8, 16), random.random().uintLessThan(u8, 64), random.random().uintLessThan(u8, 16) };
            const blocked = game_data.physics.rendering(fixture.at(point).?).occluder;
            const revealed = fixture.visible(point);
            if (!fixture.witness(eye, point)) continue;
            witnesses += 1;
            if (!revealed) {
                std.debug.print("scene={} eye={any} visible_voxel={any} opaque={}\n", .{ scene, eye, point, blocked });
                return error.VisibleVoxelConcealed;
            }
        }
    }
    try std.testing.expect(witnesses > 100);
}
