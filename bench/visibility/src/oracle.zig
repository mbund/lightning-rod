const std = @import("std");
const assert = std.debug.assert;

const Vector = [3]i256;
const maximum_vertices = 64;

fn cross(a: Vector, b: Vector) Vector {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn dot(a: Vector, b: Vector) i256 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn normalized(value: Vector) Vector {
    var divisor: u256 = 0;
    for (value) |coordinate| if (coordinate != 0) {
        divisor = if (divisor == 0) @abs(coordinate) else std.math.gcd(divisor, @abs(coordinate));
    };
    if (divisor == 0) return value;
    var result = value;
    for (&result) |*coordinate| coordinate.* = @divExact(coordinate.*, @as(i256, @intCast(divisor)));
    return result;
}

const Polygon = struct {
    vertices: [maximum_vertices]Vector = undefined,
    count: usize = 0,

    fn square() Polygon {
        var result: Polygon = .{};
        result.vertices[0..4].* = .{ .{ -1, -1, 1 }, .{ 1, -1, 1 }, .{ 1, 1, 1 }, .{ -1, 1, 1 } };
        result.count = 4;
        return result;
    }

    fn append(self: *Polygon, value: Vector) !void {
        assert(value[2] > 0);
        if (self.count != 0 and std.meta.eql(self.vertices[self.count - 1], value)) return;
        if (self.count == maximum_vertices) return error.ReferencePolygonTooComplex;
        self.vertices[self.count] = value;
        self.count += 1;
    }

    fn area(self: *const Polygon) bool {
        if (self.count < 3) return false;
        for (2..self.count) |index| {
            const orientation = dot(cross(self.vertices[0], self.vertices[1]), self.vertices[index]);
            if (orientation == 0) continue;
            assert(orientation > 0);
            return true;
        }
        return false;
    }

    fn clip(self: *const Polygon, line: Vector, output: *Polygon) !void {
        output.count = 0;
        if (self.count == 0) return;
        var previous = self.vertices[self.count - 1];
        var previous_side = dot(line, previous);
        for (self.vertices[0..self.count]) |current| {
            const side = dot(line, current);
            if ((side < 0 and previous_side > 0) or (side > 0 and previous_side < 0)) {
                // Intersections stay on original supporting lines, so arithmetic does not accumulate denominators.
                var point = normalized(cross(normalized(cross(previous, current)), line));
                if (point[2] < 0) {
                    for (&point) |*coordinate| coordinate.* = -coordinate.*;
                }
                try output.append(point);
            }
            if (side >= 0) try output.append(current);
            previous = current;
            previous_side = side;
        }
        if (output.count > 1 and std.meta.eql(output.vertices[0], output.vertices[output.count - 1])) output.count -= 1;
        if (!output.area()) output.count = 0;
    }
};

pub const Box = struct { minimum: [3]i32, maximum: [3]i32 };

pub const Eye = struct {
    pub const scale = 1000;
    coordinates: [3]i64,

    pub fn block(self: Eye) [3]i32 {
        var result: [3]i32 = undefined;
        for (&result, self.coordinates) |*coordinate, value| coordinate.* = @intCast(@divFloor(value, scale));
        return result;
    }
};

const Cone = struct {
    planes: [12]Vector = undefined,
    count: usize = 0,

    fn init(box: Box, eye: Eye) !Cone {
        var corners: [8]Vector = undefined;
        for (&corners, 0..) |*point, index| for (0..3) |axis| {
            const coordinate = if (index & (@as(usize, 1) << @intCast(axis)) == 0) box.minimum[axis] else box.maximum[axis];
            point[axis] = @as(i64, coordinate) * Eye.scale - eye.coordinates[axis];
            if (@abs(point[axis]) > 1 << 20) return error.ReferenceCoordinateTooLarge;
        };
        var result: Cone = .{};
        for (0..8) |a| for (a + 1..8) |b| {
            var plane = normalized(cross(corners[a], corners[b]));
            var positive = false;
            var negative = false;
            for (corners) |corner| {
                const side = dot(plane, corner);
                positive = positive or side > 0;
                negative = negative or side < 0;
            }
            if (positive == negative) continue;
            if (negative) {
                for (&plane) |*coordinate| coordinate.* = -coordinate.*;
            }
            var duplicate = false;
            for (result.planes[0..result.count]) |previous| duplicate = duplicate or std.meta.eql(previous, plane);
            if (duplicate) continue;
            assert(result.count < result.planes.len);
            result.planes[result.count] = plane;
            result.count += 1;
        };
        return result;
    }

    fn project(self: *const Cone, face: usize, result: *Polygon) !void {
        const axis = face / 2;
        const sign: i256 = if (face % 2 == 0) 1 else -1;
        result.* = .square();
        var temporary: Polygon = undefined;
        for (self.planes[0..self.count]) |plane| {
            try result.clip(.{ plane[(axis + 1) % 3], plane[(axis + 2) % 3], plane[axis] * sign }, &temporary);
            result.* = temporary;
            if (result.count == 0) break;
        }
    }
};

const Node = struct {
    kind: enum { open, closed, branch } = .open,
    line: Vector = undefined,
    children: [2]usize = undefined,
};

pub const Coverage = struct {
    allocator: std.mem.Allocator,
    nodes: []Node,
    scratch: []Polygon,
    maximum_depth: usize,
    used: usize = 6,
    visits: u64 = 0,
    boxes: u64 = 0,
    domain: ?[]Polygon = null,

    pub fn init(allocator: std.mem.Allocator, maximum_nodes: usize, maximum_depth: usize) !Coverage {
        if (maximum_nodes < 6 or maximum_depth == 0 or maximum_depth > maximum_nodes) return error.InvalidReferenceCapacity;
        const nodes = try allocator.alloc(Node, maximum_nodes);
        errdefer allocator.free(nodes);
        @memset(nodes[0..6], .{});
        return .{ .allocator = allocator, .nodes = nodes, .scratch = try allocator.alloc(Polygon, try std.math.mul(usize, maximum_depth, 6)), .maximum_depth = maximum_depth };
    }

    pub fn deinit(self: *Coverage) void {
        if (self.domain) |domain| self.allocator.free(domain);
        self.allocator.free(self.nodes);
        self.allocator.free(self.scratch);
        self.* = undefined;
    }

    pub fn reset(self: *Coverage) void {
        self.used = 6;
        self.visits = 0;
        self.boxes = 0;
        @memset(self.nodes[0..6], .{});
        if (self.domain) |domain| for (domain, 0..) |polygon, face| {
            if (polygon.count == 0) self.nodes[face].kind = .closed;
        };
    }

    pub fn restrict(self: *Coverage, bounds: Box, eye: Eye) !void {
        if (self.domain == null) self.domain = try self.allocator.alloc(Polygon, 6);
        const cone = try Cone.init(bounds, eye);
        for (self.domain.?, 0..) |*polygon, face| try cone.project(face, polygon);
        self.reset();
    }

    fn leaf(self: *Coverage, node_index: usize, polygon: *const Polygon, cell: *const Polygon, depth: usize) !void {
        const region = &self.scratch[depth * 6 + 4];
        const inside = &self.scratch[depth * 6];
        const outside = &self.scratch[depth * 6 + 1];
        region.* = cell.*;
        var index = node_index;
        var added_depth: usize = 0;
        for (0..polygon.count) |edge| {
            const line = normalized(cross(polygon.vertices[edge], polygon.vertices[(edge + 1) % polygon.count]));
            try region.clip(line, inside);
            try region.clip(.{ -line[0], -line[1], -line[2] }, outside);
            assert(inside.count != 0);
            if (outside.count == 0) continue;
            if (depth + added_depth + 1 >= self.maximum_depth) return error.ReferenceTreeTooDeep;
            added_depth += 1;
            if (self.used + 2 > self.nodes.len) return error.ReferenceNodesExhausted;
            const children: [2]usize = .{ self.used, self.used + 1 };
            self.used += 2;
            self.nodes[index] = .{ .kind = .branch, .line = line, .children = children };
            self.nodes[children[0]] = .{};
            self.nodes[children[1]] = .{};
            index = children[0];
            region.* = inside.*;
        }
        self.nodes[index] = .{ .kind = .closed };
    }

    fn visit(self: *Coverage, index: usize, polygon: *const Polygon, cell: *const Polygon, insert: bool, depth: usize) error{ ReferenceTreeTooDeep, ReferenceNodesExhausted, ReferencePolygonTooComplex }!bool {
        if (polygon.count == 0) return false;
        if (depth == self.maximum_depth) return error.ReferenceTreeTooDeep;
        self.visits += 1;
        const node = self.nodes[index];
        switch (node.kind) {
            .closed => return false,
            .open => {
                if (insert) try self.leaf(index, polygon, cell, depth);
                return true;
            },
            .branch => {},
        }
        const positive = &self.scratch[depth * 6];
        const negative = &self.scratch[depth * 6 + 1];
        const positive_cell = &self.scratch[depth * 6 + 2];
        const negative_cell = &self.scratch[depth * 6 + 3];
        const inverse: Vector = .{ -node.line[0], -node.line[1], -node.line[2] };
        try polygon.clip(node.line, positive);
        try polygon.clip(inverse, negative);
        try cell.clip(node.line, positive_cell);
        try cell.clip(inverse, negative_cell);
        const a = try self.visit(node.children[0], positive, positive_cell, insert, depth + 1);
        if (a and !insert) return true;
        const b = try self.visit(node.children[1], negative, negative_cell, insert, depth + 1);
        if (insert and self.nodes[node.children[0]].kind == .closed and self.nodes[node.children[1]].kind == .closed) self.nodes[index].kind = .closed;
        return a or b;
    }

    pub fn box(self: *Coverage, bounds: Box, eye: Eye, insert: bool) !bool {
        self.boxes += 1;
        var closed = true;
        for (self.nodes[0..6]) |node| closed = closed and node.kind == .closed;
        if (closed) return false;
        const cone = try Cone.init(bounds, eye);
        var polygon: Polygon = undefined;
        var visible = false;
        for (0..6) |face| {
            if (self.nodes[face].kind == .closed) continue;
            const cell: Polygon = if (self.domain) |domain| domain[face] else .square();
            if (cell.count == 0) continue;
            try cone.project(face, &polygon);
            if (self.domain != null) {
                var temporary: Polygon = undefined;
                for (0..cell.count) |edge| {
                    try polygon.clip(normalized(cross(cell.vertices[edge], cell.vertices[(edge + 1) % cell.count])), &temporary);
                    polygon = temporary;
                    if (polygon.count == 0) break;
                }
            }
            visible = (try self.visit(face, &polygon, &cell, insert, 0)) or visible;
            if (visible and !insert) return true;
        }
        return visible;
    }
};

pub const Section = struct {
    position: [3]i32,
    occluders: [64]u64 = @splat(0),

    pub fn bounds(self: *const Section) Box {
        var result: Box = undefined;
        for (0..3) |axis| {
            result.minimum[axis] = self.position[axis] * 16;
            result.maximum[axis] = result.minimum[axis] + 16;
        }
        return result;
    }
};

const Order = struct {
    sections: []const Section,
    eye: [3]i32,

    fn less(self: Order, a: usize, b: usize) bool {
        var da: u64 = 0;
        var db: u64 = 0;
        for (0..3) |axis| {
            da += @abs(@as(i64, self.sections[a].position[axis]) - @divFloor(self.eye[axis], 16));
            db += @abs(@as(i64, self.sections[b].position[axis]) - @divFloor(self.eye[axis], 16));
        }
        return da < db;
    }
};

const Voxels = struct {
    minimum: [3]i32,
    eye: [3]i32,

    fn position(self: Voxels, index: u16) [3]i32 {
        return .{ self.minimum[0] + index % 16, self.minimum[1] + index / 256, self.minimum[2] + index / 16 % 16 };
    }

    fn less(self: Voxels, a: u16, b: u16) bool {
        var da: u64 = 0;
        var db: u64 = 0;
        for (self.position(a), self.position(b), self.eye) |x, y, eye| {
            da += @abs(@as(i64, x) - eye);
            db += @abs(@as(i64, y) - eye);
        }
        return da < db;
    }
};

/// Exact positive-area visibility of section volumes through full opaque voxel cubes.
pub fn classify(allocator: std.mem.Allocator, coverage: *Coverage, sections: []const Section, eye: Eye, visible: []bool) !void {
    assert(sections.len == visible.len);
    const order = try allocator.alloc(usize, sections.len);
    defer allocator.free(order);
    for (order, 0..) |*index, i| index.* = i;
    const eye_block = eye.block();
    std.mem.sort(usize, order, Order{ .sections = sections, .eye = eye_block }, Order.less);
    coverage.reset();
    // A ray only moves outward through grid cells, so Manhattan shells give an exact depth order.
    for (order) |index| {
        const section = &sections[index];
        const bounds = section.bounds();
        visible[index] = try coverage.box(bounds, eye, false);
        if (!visible[index]) continue;
        var full = true;
        var empty = true;
        for (section.occluders) |word| {
            full = full and word == std.math.maxInt(u64);
            empty = empty and word == 0;
        }
        if (empty) continue;
        if (full) {
            var contains_eye = true;
            for (0..3) |axis| contains_eye = contains_eye and eye_block[axis] >= bounds.minimum[axis] and eye_block[axis] < bounds.maximum[axis];
            if (contains_eye) return error.ObserverInsideOccluder;
            _ = try coverage.box(bounds, eye, true);
            continue;
        }
        var indices: [4096]u16 = undefined;
        var count: usize = 0;
        for (section.occluders, 0..) |word, group| {
            var remaining = word;
            while (remaining != 0) {
                const bit = @ctz(remaining);
                indices[count] = @intCast(group * 64 + bit);
                count += 1;
                remaining &= remaining - 1;
            }
        }
        const voxels: Voxels = .{ .minimum = bounds.minimum, .eye = eye_block };
        std.mem.sort(u16, indices[0..count], voxels, Voxels.less);
        for (indices[0..count]) |voxel| {
            const minimum = voxels.position(voxel);
            if (std.meta.eql(minimum, eye_block)) return error.ObserverInsideOccluder;
            const maximum = [3]i32{ minimum[0] + 1, minimum[1] + 1, minimum[2] + 1 };
            _ = try coverage.box(.{ .minimum = minimum, .maximum = maximum }, eye, true);
        }
    }
}

test "exact angular coverage preserves a narrow slit and closes it by union" {
    var coverage = try Coverage.init(std.testing.allocator, 4096, 64);
    defer coverage.deinit();
    const eye: Eye = .{ .coordinates = .{ 500, 500, 500 } };
    const target: Box = .{ .minimum = .{ 10, -1, -1 }, .maximum = .{ 11, 2, 2 } };
    _ = try coverage.box(.{ .minimum = .{ 3, -100, -100 }, .maximum = .{ 4, 0, 100 } }, eye, true);
    _ = try coverage.box(.{ .minimum = .{ 3, 1, -100 }, .maximum = .{ 4, 100, 100 } }, eye, true);
    try std.testing.expect(try coverage.box(target, eye, false));
    _ = try coverage.box(.{ .minimum = .{ 3, 0, -100 }, .maximum = .{ 4, 1, 100 } }, eye, true);
    try std.testing.expect(!try coverage.box(target, eye, false));
}

test "opaque enclosure covers every direction without a sampling resolution" {
    var coverage = try Coverage.init(std.testing.allocator, 4096, 64);
    defer coverage.deinit();
    const eye: Eye = .{ .coordinates = .{ 500, 500, 500 } };
    for (0..3) |axis| for ([_]i32{ -2, 2 }) |side| {
        var box: Box = .{ .minimum = .{ -3, -3, -3 }, .maximum = .{ 4, 4, 4 } };
        box.minimum[axis] = side;
        box.maximum[axis] = side + 1;
        _ = try coverage.box(box, eye, true);
    };
    for (coverage.nodes[0..6]) |node| try std.testing.expectEqual(.closed, node.kind);
}

test "restricted angular coverage retains the complete target silhouette" {
    var coverage = try Coverage.init(std.testing.allocator, 4096, 64);
    defer coverage.deinit();
    const eye: Eye = .{ .coordinates = .{ 500, 500, 500 } };
    const target: Box = .{ .minimum = .{ 10, -1, -1 }, .maximum = .{ 11, 2, 2 } };
    try coverage.restrict(target, eye);
    try std.testing.expect(!try coverage.box(.{ .minimum = .{ -11, -1, -1 }, .maximum = .{ -10, 2, 2 } }, eye, false));
    _ = try coverage.box(.{ .minimum = .{ 3, -100, -100 }, .maximum = .{ 4, 0, 100 } }, eye, true);
    _ = try coverage.box(.{ .minimum = .{ 3, 1, -100 }, .maximum = .{ 4, 100, 100 } }, eye, true);
    try std.testing.expect(try coverage.box(target, eye, false));
    _ = try coverage.box(.{ .minimum = .{ 3, 0, -100 }, .maximum = .{ 4, 1, 100 } }, eye, true);
    try std.testing.expect(!try coverage.box(target, eye, false));
    coverage.reset();
    try std.testing.expect(try coverage.box(target, eye, false));
}

test "grid depth ordering exposes the room and only its six boundary sections" {
    var coverage = try Coverage.init(std.testing.allocator, 16384, 128);
    defer coverage.deinit();
    var sections: [27]Section = undefined;
    var expected: [27]bool = undefined;
    for (&sections, &expected, 0..) |*section, *visible, index| {
        const x = @as(i32, @intCast(index % 3)) - 1;
        const y = @as(i32, @intCast(index / 3 % 3)) - 1;
        const z = @as(i32, @intCast(index / 9)) - 1;
        section.* = .{ .position = .{ x, y, z }, .occluders = @splat(if (x == 0 and y == 0 and z == 0) 0 else std.math.maxInt(u64)) };
        visible.* = @abs(x) + @abs(y) + @abs(z) <= 1;
    }
    var visible: [27]bool = undefined;
    try classify(std.testing.allocator, &coverage, &sections, .{ .coordinates = .{ 8500, 8500, 8500 } }, &visible);
    try std.testing.expectEqualSlices(bool, &expected, &visible);
}

test "off-center face visibility survives when the block-center ray is obstructed" {
    var coverage = try Coverage.init(std.testing.allocator, 4096, 64);
    defer coverage.deinit();
    const eye: Eye = .{ .coordinates = .{ 500, 500, 500 } };
    _ = try coverage.box(.{ .minimum = .{ 3, -100, -100 }, .maximum = .{ 4, 0, 100 } }, eye, true);
    _ = try coverage.box(.{ .minimum = .{ 3, 1, -100 }, .maximum = .{ 4, 100, 100 } }, eye, true);
    _ = try coverage.box(.{ .minimum = .{ 3, 0, -100 }, .maximum = .{ 4, 1, 0 } }, eye, true);
    _ = try coverage.box(.{ .minimum = .{ 3, 0, 1 }, .maximum = .{ 4, 1, 100 } }, eye, true);
    const target: Box = .{ .minimum = .{ 100, 8, 0 }, .maximum = .{ 116, 24, 16 } };
    try std.testing.expect(try coverage.box(target, eye, false));
    // At the far wall the center ray has y = 216/215, outside the one-block opening.
    _ = try coverage.box(.{ .minimum = .{ 3, 0, 0 }, .maximum = .{ 4, 1, 1 } }, eye, true);
    try std.testing.expect(!try coverage.box(target, eye, false));
}

pub fn rayWitness(sections: []const Section, eye: Eye, target: [3]i64, target_section: usize) bool {
    var cell = eye.block();
    var direction: [3]i64 = undefined;
    var numerator: [3]i64 = undefined;
    var denominator: [3]i64 = undefined;
    for (0..3) |axis| {
        direction[axis] = target[axis] - eye.coordinates[axis];
        denominator[axis] = @intCast(@abs(direction[axis]));
        numerator[axis] = if (direction[axis] > 0) (@as(i64, cell[axis]) + 1) * Eye.scale - eye.coordinates[axis] else eye.coordinates[axis] - @as(i64, cell[axis]) * Eye.scale;
    }
    for (0..256) |_| {
        const at = [3]i32{ @divFloor(cell[0], 16), @divFloor(cell[1], 16), @divFloor(cell[2], 16) };
        for (sections, 0..) |section, index| if (std.meta.eql(section.position, at)) {
            if (index == target_section) return true;
            const local: usize = @intCast(@mod(cell[1], 16) * 256 + @mod(cell[2], 16) * 16 + @mod(cell[0], 16));
            if (section.occluders[local / 64] & (@as(u64, 1) << @intCast(local % 64)) != 0) return false;
            break;
        };
        var first: ?usize = null;
        for (0..3) |axis| {
            if (denominator[axis] == 0) continue;
            if (first == null or @as(i128, numerator[axis]) * denominator[first.?] < @as(i128, numerator[first.?]) * denominator[axis]) first = axis;
        }
        const chosen = first orelse return false;
        // Grazing grid edges are discarded as witnesses rather than assigned an epsilon.
        for (0..3) |axis| if (axis != chosen and denominator[axis] != 0 and @as(i128, numerator[axis]) * denominator[chosen] == @as(i128, numerator[chosen]) * denominator[axis]) return false;
        cell[chosen] += if (direction[chosen] > 0) @as(i32, 1) else -1;
        numerator[chosen] += Eye.scale;
    }
    return false;
}

test "analytical classification preserves independent exact rational ray witnesses" {
    var coverage = try Coverage.init(std.testing.allocator, 65536, 512);
    defer coverage.deinit();
    const eye: Eye = .{ .coordinates = .{ 8270, 8630, 8910 } };
    var random: std.Random.DefaultPrng = .init(0x7c618af);
    var sections: [27]Section = undefined;
    var visible: [27]bool = undefined;
    var witnesses: usize = 0;
    for (0..4) |_| {
        for (&sections, 0..) |*section, index| {
            section.* = .{ .position = .{ @as(i32, @intCast(index % 3)) - 1, @as(i32, @intCast(index / 3 % 3)) - 1, @as(i32, @intCast(index / 9)) - 1 } };
            if (index == 13) continue;
            const axis = random.random().uintLessThan(usize, 3);
            const plane = random.random().uintLessThan(usize, 16);
            for (0..4096) |local| {
                const coordinates = [3]usize{ local % 16, local / 256, local / 16 % 16 };
                if (coordinates[axis] == plane) section.occluders[local / 64] |= @as(u64, 1) << @intCast(local % 64);
            }
        }
        try classify(std.testing.allocator, &coverage, &sections, eye, &visible);
        for (sections, 0..) |section, index| for (0..27) |sample| {
            var target: [3]i64 = undefined;
            var divisor: usize = 1;
            for (0..3) |axis| {
                target[axis] = @as(i64, section.position[axis]) * (16 * Eye.scale) + @as(i64, @intCast(sample / divisor % 3)) * (5 * Eye.scale) + Eye.scale * 5 / 2;
                divisor *= 3;
            }
            if (rayWitness(&sections, eye, target, index)) {
                witnesses += 1;
                try std.testing.expect(visible[index]);
            }
        };
    }
    try std.testing.expect(witnesses > 100);
}
