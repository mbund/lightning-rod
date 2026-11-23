//! The world border's shape, as vanilla's WorldBorder works it out: a square around a center,
//! the same size in every world, its center divided by each world's coordinate scale as each
//! Level's border divides the overworld's. Bodies, items and projectiles collide with it, and
//! game rules ask it where players may build.

const std = @import("std");

/// WorldBorder.maxRadius: no edge goes further out than this.
pub const max_radius: f64 = 29_999_984;
/// The largest the border gets, and its size until something sets it: WorldBorder.STATIC_AREA_SIZE.
pub const max_size: f64 = 59_999_968;
/// Box.contains' and WorldBorder.clamp's step in from the east and south edges, a float's 1e-5.
const edge: f64 = 9.999999747378752e-6;

/// Where the border stands in one world: WorldBorder.getBoundWest and the others.
pub const Bounds = struct {
    west: f64,
    north: f64,
    east: f64,
    south: f64,

    /// The bounds of a border this wide around a center, no edge past the largest radius.
    pub fn around(center_x: f64, center_z: f64, size: f64) Bounds {
        const half = size / 2;
        return .{
            .west = std.math.clamp(center_x - half, -max_radius, max_radius),
            .north = std.math.clamp(center_z - half, -max_radius, max_radius),
            .east = std.math.clamp(center_x + half, -max_radius, max_radius),
            .south = std.math.clamp(center_z + half, -max_radius, max_radius),
        };
    }

    /// WorldBorder.contains(x, z): the west and north edges inside, the east and south outside.
    pub fn contains(self: Bounds, x: f64, z: f64) bool {
        return self.containsWithin(x, z, 0);
    }

    /// WorldBorder.contains(x, z, margin): inside the border pushed out this far.
    pub fn containsWithin(self: Bounds, x: f64, z: f64, margin: f64) bool {
        return x >= self.west - margin and x < self.east + margin and z >= self.north - margin and z < self.south + margin;
    }

    /// WorldBorder.contains(BlockPos): a block by its corner, as ServerLevel.mayInteract asks.
    pub fn containsBlock(self: Bounds, x: i32, z: i32) bool {
        return self.contains(@floatFromInt(x), @floatFromInt(z));
    }

    /// WorldBorder.isWithinBounds(AABB): both corners, the far one stepped in.
    pub fn containsBox(self: Bounds, min_x: f64, min_z: f64, max_x: f64, max_z: f64) bool {
        return self.contains(min_x, min_z) and self.contains(max_x - edge, max_z - edge);
    }

    /// WorldBorder.getDistanceToBorder: how far inside the nearest edge, below zero outside it.
    pub fn distanceInside(self: Bounds, x: f64, z: f64) f64 {
        return @min(@min(z - self.north, self.south - z), @min(x - self.west, self.east - x));
    }

    /// WorldBorder.clampToBounds of a horizontal position.
    pub fn clamp(self: Bounds, x: f64, z: f64) [2]f64 {
        return .{ std.math.clamp(x, self.west, self.east - edge), std.math.clamp(z, self.north, self.south - edge) };
    }

    /// WorldBorder.isInsideCloseToBorder: whether something at `x`, `z` with a box this long
    /// across is near enough to the border, and inside it, to collide with it.
    pub fn canCollide(self: Bounds, x: f64, z: f64, length_x: f64, length_z: f64) bool {
        const margin = @max(@max(@abs(length_x), @abs(length_z)), 1.0);
        return self.distanceInside(x, z) < margin * 2.0 and self.containsWithin(x, z, margin);
    }

    /// WorldBorder.getCollisionShape: all space but the inside, its edges floored and ceiled
    /// to whole blocks, as four boxes, each its low and high corner.
    pub fn outside(self: Bounds) [4][2][3]f64 {
        const far = 1.0e8;
        const west = @floor(self.west);
        const north = @floor(self.north);
        const east = @ceil(self.east);
        const south = @ceil(self.south);
        return .{
            .{ .{ -far, -far, -far }, .{ west, far, far } },
            .{ .{ east, -far, -far }, .{ far, far, far } },
            .{ .{ west, -far, -far }, .{ east, far, north } },
            .{ .{ west, -far, south }, .{ east, far, far } },
        };
    }
};

/// A world's coordinate scale, by its id.
pub const Scale = struct { world: u32, scale: f64 };

/// The border as every world has it: one center and one size, the center divided in each world
/// by its dimension's coordinate scale. The world border plugin keeps it up to date.
pub const Border = struct {
    center_x: f64 = 0,
    center_z: f64 = 0,
    size: f64 = max_size,
    /// Worlds whose scale is not one.
    scales: []const Scale = &.{},

    pub fn of(self: *const Border, world: u32) Bounds {
        if (self.center_x == 0 and self.center_z == 0) return .around(0, 0, self.size);
        const scale = for (self.scales) |known| {
            if (known.world == world) break known.scale;
        } else 1;
        return .around(self.center_x / scale, self.center_z / scale, self.size);
    }
};

test "a border's bounds hold their west and north edges and not their east and south" {
    const bounds: Bounds = .around(10, -4, 8);
    try std.testing.expectEqual(Bounds{ .west = 6, .north = -8, .east = 14, .south = 0 }, bounds);
    try std.testing.expect(bounds.contains(6, -8));
    try std.testing.expect(!bounds.contains(14, -1));
    try std.testing.expect(!bounds.contains(13, 0));
    try std.testing.expect(bounds.containsBlock(13, -1));
    try std.testing.expect(!bounds.containsBlock(5, -1));
    try std.testing.expect(bounds.containsBox(13.4, -1.6, 14, 0));
    try std.testing.expect(!bounds.containsBox(13.4, -1.6, 14.1, 0));
    try std.testing.expectEqual(@as(f64, 1), bounds.distanceInside(13, -3));
    try std.testing.expectEqual(@as(f64, -2), bounds.distanceInside(16, -3));
    const clamped = bounds.clamp(20, -20);
    try std.testing.expectEqual(@as(f64, -8), clamped[1]);
    try std.testing.expect(clamped[0] < 14 and bounds.contains(clamped[0], clamped[1]));
}

test "a border collides only near its edges and from inside, and never past the largest radius" {
    const bounds: Bounds = .around(0, 0, 16);
    try std.testing.expect(bounds.canCollide(7, 0, 0.6, 0.6));
    try std.testing.expect(!bounds.canCollide(0, 0, 0.6, 0.6));
    try std.testing.expect(bounds.canCollide(8.5, 0, 0.6, 0.6));
    try std.testing.expect(!bounds.canCollide(10, 0, 0.6, 0.6));
    const shape = Bounds.around(0.5, 0, 3).outside();
    try std.testing.expectEqual(@as(f64, -1), shape[0][1][0]);
    try std.testing.expectEqual(@as(f64, 2), shape[1][0][0]);
    const widest: Bounds = .around(29_999_990, 0, max_size);
    try std.testing.expectEqual(max_radius, widest.east);
}

test "each world's border has the center divided by its scale" {
    const scales = [_]Scale{.{ .world = 1, .scale = 8 }};
    const border: Border = .{ .center_x = 80, .center_z = -16, .size = 10, .scales = &scales };
    try std.testing.expectEqual(Bounds.around(80, -16, 10), border.of(0));
    try std.testing.expectEqual(Bounds.around(10, -2, 10), border.of(1));
}
