const std = @import("std");
const lightning_rod = @import("lightning_rod");
const spatial = @import("item_spatial.zig");
const Selection = @import("item_selection.zig").Selection;

test "batched item bounds match a point model through overlaps gaps worlds and closed edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = failing.allocator();
    var random = std.Random.DefaultPrng.init(0x90672963);
    const source = random.random();
    var residents: [257]spatial.Resident = undefined;
    for (&residents, 0..) |*resident, at| {
        const x = @as(f64, @floatFromInt(source.intRangeAtMost(i32, -256, 256))) / 4;
        const z = @as(f64, @floatFromInt(source.intRangeAtMost(i32, -256, 256))) / 4;
        resident.* = .{ .id = at + 1, .world = @intCast(at % 3), .x = @intFromFloat(@floor(x / 16)), .z = @intFromFloat(@floor(z / 16)), .y = @intCast(at % 24), .alive = true, .position = .{ x, z } };
    }
    var index = try spatial.Index.init(allocator, &residents);
    for (0..residents.len) |at| index.insert(@intCast(at));
    var selection = try Selection.init(allocator, 1024, residents.len);
    var selected = try lightning_rod.system.IndexSet.init(allocator, residents.len);
    failing.fail_index = failing.alloc_index;
    var bounds: [1024]Selection.Bounds = undefined;
    for (0..64) |round| {
        const count = ([_]usize{ 0, 1, 4, 64, 1024 })[round % 5];
        for (bounds[0..count], 0..) |*area, at| {
            const point = residents[at % residents.len];
            const x = @as(f64, @floatFromInt(source.intRangeAtMost(i32, -256, 256))) / 4;
            const z = @as(f64, @floatFromInt(source.intRangeAtMost(i32, -256, 256))) / 4;
            area.* = if (at % 4 == 0) .{ .world = point.world, .minimum = point.position, .maximum = point.position } else .{
                .world = source.intRangeAtMost(u32, 0, 3),
                .minimum = .{ x, z },
                .maximum = .{ x + @as(f64, @floatFromInt(source.intRangeAtMost(u8, 0, 128))) / 4, z + @as(f64, @floatFromInt(source.intRangeAtMost(u8, 0, 128))) / 4 },
            };
        }
        for ([_]bool{ false, true }) |reverse| {
            selected.clear();
            selected.insert(0);
            for (0..count) |at| {
                const area = bounds[if (reverse) count - at - 1 else at];
                selection.append(area.world, area.minimum, area.maximum);
            }
            const work = selection.select(&index, &selected);
            try std.testing.expectEqual(@as(usize, 0), selection.count);
            try std.testing.expect(work.candidates <= residents.len and work.matches <= work.candidates);
            var actual: [residents.len]bool = @splat(false);
            for (selected.values()) |at| {
                try std.testing.expect(!actual[at]);
                actual[at] = true;
            }
            for (residents, 0..) |resident, at| {
                const expected = at == 0 or for (bounds[0..count]) |area| {
                    if (resident.world == area.world and resident.position[0] >= area.minimum[0] and resident.position[0] <= area.maximum[0] and resident.position[1] >= area.minimum[1] and resident.position[1] <= area.maximum[1]) break true;
                } else false;
                try std.testing.expectEqual(expected, actual[at]);
            }
        }
    }
}
