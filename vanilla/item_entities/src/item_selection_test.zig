const std = @import("std");
const entities = @import("entities");
const Selection = @import("item_selection.zig").Selection;

test "selected items match a point model through overlaps gaps worlds and closed edges" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var pool = try entities.Pool.init(arena.allocator(), 64 * entities.pool.page_bytes);
    var directory = try entities.Directory.init(arena.allocator(), &pool, 512);
    var area = try entities.Space.init(arena.allocator(), &pool, &directory);
    var random = std.Random.DefaultPrng.init(0x90672963);
    const source = random.random();
    const Point = struct { world: u32, position: [3]f64 };
    var points: [257]Point = undefined;
    for (&points, 0..) |*point, at| {
        const x = @as(f64, @floatFromInt(source.intRangeAtMost(i32, -256, 256))) / 4;
        const z = @as(f64, @floatFromInt(source.intRangeAtMost(i32, -256, 256))) / 4;
        point.* = .{ .world = @intCast(at % 3), .position = .{ x, @floatFromInt(at % 24), z } };
        _ = try directory.add(at + 1, 0);
        try area.insert(at + 1, point.world, point.position, .{ .kind = 0, .half_width = 0.125, .height = 0.25 });
    }
    var selection = try Selection.init(arena.allocator(), 1024);
    var selected = try entities.IdSet.init(arena.allocator(), &pool, points.len + 1);
    var bounds: [1024]Selection.Bounds = undefined;
    for (0..32) |round| {
        const count = ([_]usize{ 0, 1, 4, 64, 256 })[round % 5];
        for (bounds[0..count], 0..) |*bound, at| {
            const point = points[at % points.len];
            const x = @as(f64, @floatFromInt(source.intRangeAtMost(i32, -256, 256))) / 4;
            const z = @as(f64, @floatFromInt(source.intRangeAtMost(i32, -256, 256))) / 4;
            bound.* = if (at % 4 == 0) .{ .world = point.world, .minimum = .{ point.position[0], point.position[2] }, .maximum = .{ point.position[0], point.position[2] } } else .{
                .world = source.intRangeAtMost(u32, 0, 3),
                .minimum = .{ x, z },
                .maximum = .{ x + @as(f64, @floatFromInt(source.intRangeAtMost(u8, 0, 128))) / 4, z + @as(f64, @floatFromInt(source.intRangeAtMost(u8, 0, 128))) / 4 },
            };
        }
        for ([_]bool{ false, true }) |reverse| {
            selected.clear();
            for (0..count) |at| {
                const bound = bounds[if (reverse) count - at - 1 else at];
                selection.append(bound.world, bound.minimum, bound.maximum);
            }
            const work = try selection.select(&area, .all, &selected);
            try std.testing.expectEqual(@as(usize, 0), selection.count);
            try std.testing.expect(work.matches <= work.candidates and !selected.overflowed);
            for (points, 1..) |point, entity| {
                const expected = for (bounds[0..count]) |bound| {
                    if (point.world == bound.world and point.position[0] >= bound.minimum[0] and point.position[0] <= bound.maximum[0] and point.position[2] >= bound.minimum[1] and point.position[2] <= bound.maximum[1]) break true;
                } else false;
                try std.testing.expectEqual(expected, selected.contains(entity));
            }
        }
    }
}
