const std = @import("std");
const sessions = @import("sessions");
const geometry = @import("bounds.zig");

pub const Status = enum {
    visible,
    retained,
    concealed,
    pending,

    pub fn classify(queued: bool, visible: bool, disclosed: bool, refresh: bool) Status {
        if (!queued or refresh) return .pending;
        if (visible) return .visible;
        return if (disclosed) .retained else .concealed;
    }

    pub fn color(self: Status) u32 {
        return switch (self) {
            .visible => 0x40ff60,
            .retained => 0xffcc30,
            .concealed => 0xff4050,
            .pending => 0xb0b0b0,
        };
    }
};

pub const Snapshot = struct {
    pub const side = 3;
    pub const capacity = side * side * side;
    pub const Section = struct { bounds: geometry.Box, status: Status };

    world: u32 = 0,
    life: u32 = 0,
    epoch: u64 = 0,
    revision: u64 = 0,
    cell: [3]i32 = .{ 0, 0, 0 },
    component: u12 = 0,
    source: ?geometry.Box = null,
    occlusion_active: bool = false,
    queued_columns: usize = 0,
    total_columns: usize = 0,
    sections: [capacity]Section = undefined,
    count: usize = 0,
};

// Requests and responses are protected by Streaming's publication mutex.
pub const Slot = struct {
    handle: ?sessions.Handle = null,
    world: u32 = 0,
    life: u32 = 0,
    requested: bool = false,
    ready: bool = false,
    snapshot: Snapshot = .{},
};

pub const Outline = struct {
    bounds: geometry.Box,
    color: u32,
};

pub const Edge = struct {
    position: [3]f64,
    scale: [3]f32,
    color: u32,

    pub fn at(outline: Outline, index: usize) Edge {
        std.debug.assert(index < 12);
        outline.bounds.validate();
        const axis = index / 4;
        const u = (axis + 1) % 3;
        const v = (axis + 2) % 3;
        var result: Edge = .{ .position = undefined, .scale = @splat(0.2), .color = outline.color };
        result.position[axis] = @floatFromInt(outline.bounds.minimum[axis]);
        result.position[u] = @as(f64, @floatFromInt(if (index & 1 == 0) outline.bounds.minimum[u] else outline.bounds.maximum[u])) - 0.1;
        result.position[v] = @as(f64, @floatFromInt(if (index & 2 == 0) outline.bounds.minimum[v] else outline.bounds.maximum[v])) - 0.1;
        result.scale[axis] = @floatFromInt(@as(i64, outline.bounds.maximum[axis]) - outline.bounds.minimum[axis]);
        return result;
    }
};

test "debug status distinguishes retained disclosure from current authorization" {
    try std.testing.expectEqual(Status.visible, Status.classify(true, true, true, false));
    try std.testing.expectEqual(Status.retained, Status.classify(true, false, true, false));
    try std.testing.expectEqual(Status.concealed, Status.classify(true, false, false, false));
    try std.testing.expectEqual(Status.pending, Status.classify(false, false, false, false));
    try std.testing.expectEqual(Status.pending, Status.classify(true, true, true, true));
}

test "persistent outlines have twelve thick edges at world coordinate limits" {
    const bounds: geometry.Box = .{ .minimum = .{ -30_000_000, -64, -30_000_000 }, .maximum = .{ 30_000_000, 320, 30_000_000 } };
    const outline: Outline = .{ .bounds = bounds, .color = 0 };
    for (0..12) |index| {
        const edge = Edge.at(outline, index);
        for (0..3) |axis| {
            try std.testing.expect(std.math.isFinite(edge.position[axis]) and std.math.isFinite(edge.scale[axis]));
            try std.testing.expect(edge.scale[axis] >= 0.2);
        }
        const axis = index / 4;
        try std.testing.expectEqual(@as(f32, @floatFromInt(@as(i64, bounds.maximum[axis]) - bounds.minimum[axis])), edge.scale[axis]);
    }
}
