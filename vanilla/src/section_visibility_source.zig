const std = @import("std");
const visibility = @import("section_visibility.zig");
const assert = std.debug.assert;

pub const Components = struct {
    reached: [27][64]u64 = undefined,
    incoming: [27][64]u64 = undefined,
    touched: u27 = 0,
    cells: u27 = 0,
    faces: [27]u6 = @splat(0),
    visits: usize = 0,

    fn touch(self: *Components, index: usize) void {
        const bit = @as(u27, 1) << @intCast(index);
        if (self.touched & bit != 0) return;
        self.touched |= bit;
        self.reached[index] = @splat(0);
        self.incoming[index] = @splat(0);
    }

    pub fn solve(self: *Components, materials: *const [27]*const visibility.Section, voxel: u12, margin: usize, workspace: *visibility.Workspace) void {
        assert(margin > 0 and margin <= 16);
        self.touched = 0;
        self.cells = 0;
        self.faces = @splat(0);
        self.visits = 0;
        self.touch(13);
        self.incoming[13][voxel / 64] = @as(u64, 1) << @intCast(voxel % 64);
        var pending: u27 = 1 << 13;
        while (pending != 0) {
            const cell = @ctz(pending);
            pending &= pending - 1;
            const coordinates = [_]usize{ cell % 3, cell / 3 % 3, cell / 9 };
            const first = [_]usize{ if (coordinates[0] == 0) 16 - margin else 0, if (coordinates[1] == 0) 16 - margin else 0, if (coordinates[2] == 0) 16 - margin else 0 };
            const last = [_]usize{ if (coordinates[0] == 2) margin else 16, if (coordinates[1] == 2) margin else 16, if (coordinates[2] == 2) margin else 16 };
            const x_mask = (((@as(u64, 1) << @intCast(last[0] - first[0])) - 1) << @intCast(first[0]));
            var permitted: [64]u64 = @splat(0);
            for (first[1]..last[1]) |y| {
                for (first[2]..last[2]) |z| permitted[y * 4 + z / 4] |= x_mask << @intCast(z % 4 * 16);
            }
            const before = self.reached[cell];
            const faces = materials[cell].expandComponents(&self.incoming[cell], &permitted, &self.reached[cell], workspace);
            const added: [64]u64 = @as(@Vector(64, u64), self.reached[cell]) & ~@as(@Vector(64, u64), before);
            if (@reduce(.Or, @as(@Vector(64, u64), added)) == 0) continue;
            self.faces[cell] |= faces;
            self.cells |= @as(u27, 1) << cell;
            self.visits += 1;
            for (0..6) |face| {
                const axis = face / 2;
                const positive = face & 1 != 0;
                if ((positive and coordinates[axis] == 2) or (!positive and coordinates[axis] == 0)) continue;
                const stride = [_]usize{ 1, 3, 9 };
                const next = if (positive) cell + stride[axis] else cell - stride[axis];
                if (materials[next].kind == .solid) continue;
                self.touch(next);
                if (visibility.transportFace(&added, face, &self.incoming[next])) pending |= @as(u27, 1) << @intCast(next);
            }
        }
    }
};

fn Flood(comptime side: usize) type {
    assert(side > 0 and side <= 32 and side * side <= std.math.maxInt(u16));
    return struct {
        const Self = @This();
        const rows = side * side;
        const mask: u32 = @truncate((@as(u64, 1) << side) - 1);

        solid: [rows]u32 = undefined,
        reached: [rows]u32 = undefined,
        pending: [rows]u16 = undefined,
        queued: std.StaticBitSet(rows) = undefined,
        read: usize = 0,
        write: usize = 0,
        visits: usize = 0,

        pub fn solve(self: *Self, point: [3]usize) void {
            for (point) |coordinate| assert(coordinate < side);
            @memset(&self.reached, 0);
            self.queued = .empty;
            self.read = 0;
            self.write = 0;
            self.visits = 0;
            self.enqueue(point[1] * side + point[2], @as(u32, 1) << @intCast(point[0]));
            while (self.read != self.write) {
                const row = self.pending[self.read % rows];
                self.read += 1;
                self.queued.unset(row);
                const open = ~self.solid[row] & mask;
                var bits = self.reached[row];
                var left = open;
                var right = open;
                inline for (.{ 1, 2, 4, 8, 16 }) |shift| {
                    bits |= (bits << shift) & left;
                    bits |= (bits >> shift) & right;
                    left &= left << shift;
                    right &= right >> shift;
                }
                assert(bits & ~open == 0);
                self.reached[row] = bits;
                self.visits += 1;
                if (row >= side) self.enqueue(row - side, bits);
                if (row + side < rows) self.enqueue(row + side, bits);
                if (row % side != 0) self.enqueue(row - 1, bits);
                if (row % side + 1 < side) self.enqueue(row + 1, bits);
            }
        }

        fn enqueue(self: *Self, row: usize, incoming: u32) void {
            assert(row < rows and incoming & ~mask == 0);
            const added = incoming & ~self.solid[row] & ~self.reached[row];
            if (added == 0) return;
            self.reached[row] |= added;
            if (self.queued.isSet(row)) return;
            assert(self.write - self.read < rows);
            self.pending[self.write % rows] = @intCast(row);
            self.write += 1;
            self.queued.set(row);
        }
    };
}

test "row propagation matches independent voxel flood through disconnected and winding volumes" {
    const side = 26;
    const volume = side * side * side;
    var random = std.Random.DefaultPrng.init(0x7a50228b);
    var flood: Flood(side) = undefined;
    var expected: [side * side]u32 = undefined;
    var pending: [volume]u16 = undefined;
    for (0..100) |pass| {
        for (&flood.solid) |*row| row.* = if (pass == 0) 0 else random.random().int(u32) & random.random().int(u32);
        const point: [3]usize = .{ pass % side, pass / side % side, pass * 7 % side };
        flood.solve(point);
        @memset(&expected, 0);
        var length: usize = 0;
        const seed = point[1] * side * side + point[2] * side + point[0];
        if (flood.solid[seed / side] & (@as(u32, 1) << @intCast(seed % side)) == 0) {
            expected[seed / side] |= @as(u32, 1) << @intCast(seed % side);
            pending[0] = @intCast(seed);
            length = 1;
        }
        var head: usize = 0;
        while (head < length) : (head += 1) {
            const voxel: usize = pending[head];
            const coordinates = [_]usize{ voxel % side, voxel / (side * side), voxel / side % side };
            for ([_]usize{ 1, side * side, side }, coordinates) |stride, coordinate| {
                for ([_]bool{ false, true }) |positive| {
                    if (if (positive) coordinate + 1 == side else coordinate == 0) continue;
                    const next = if (positive) voxel + stride else voxel - stride;
                    const bit = @as(u32, 1) << @intCast(next % side);
                    if ((flood.solid[next / side] | expected[next / side]) & bit != 0) continue;
                    expected[next / side] |= bit;
                    pending[length] = @intCast(next);
                    length += 1;
                }
            }
        }
        try std.testing.expectEqualSlices(u32, &expected, &flood.reached);
        if (pass == 0) try std.testing.expect(flood.visits < volume / 8);
    }
}

test "baked source components conservatively contain an independent clipped voxel flood" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sections = try arena.allocator().alloc(visibility.Section, 27);
    const bytes = try arena.allocator().alloc([visibility.Section.prepared_bytes]u8, 27);
    var materials: [27]*const visibility.Section = undefined;
    var work: visibility.Workspace = undefined;
    var graph: Components = .{};
    var flood: Flood(26) = undefined;
    var random = std.Random.DefaultPrng.init(0x8ac37);
    for (0..24) |pass| {
        for (sections, bytes, &materials) |*section, *output, *material| {
            var solid: [64]u64 = undefined;
            for (&solid) |*word| word.* = switch (pass % 4) {
                0 => 0,
                1 => random.random().int(u64) & random.random().int(u64),
                2 => random.random().int(u64),
                else => random.random().int(u64) | random.random().int(u64),
            };
            section.build(&solid, &work, output);
            material.* = section;
        }
        for (0..26) |y| for (0..26) |z| {
            var row: u32 = 0;
            for (0..26) |x| {
                const at = [_]usize{ x + 11, y + 11, z + 11 };
                const cell = at[0] / 16 + at[1] / 16 * 3 + at[2] / 16 * 9;
                const voxel: u12 = @intCast(at[0] % 16 + at[1] % 16 * 256 + at[2] % 16 * 16);
                row |= @as(u32, @intFromBool(materials[cell].blocked(voxel))) << @intCast(x);
            }
            flood.solid[y * 26 + z] = row;
        };
        const point = [_]usize{ pass % 16, pass * 7 % 16, pass * 3 % 16 };
        const voxel: u12 = @intCast(point[0] + point[1] * 256 + point[2] * 16);
        graph.solve(&materials, voxel, 5, &work);
        flood.solve(.{ point[0] + 5, point[1] + 5, point[2] + 5 });
        for (0..26) |y| for (0..26) |z| {
            var reached = flood.reached[y * 26 + z];
            while (reached != 0) : (reached &= reached - 1) {
                const x = @ctz(reached);
                const at = [_]usize{ x + 11, y + 11, z + 11 };
                const cell = at[0] / 16 + at[1] / 16 * 3 + at[2] / 16 * 9;
                const local = at[0] % 16 + at[1] % 16 * 256 + at[2] % 16 * 16;
                try std.testing.expect(graph.cells & (@as(u27, 1) << @intCast(cell)) != 0);
                try std.testing.expect(graph.reached[cell][local / 64] & (@as(u64, 1) << @intCast(local % 64)) != 0);
            }
        };
    }
}
