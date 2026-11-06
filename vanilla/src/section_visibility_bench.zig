const std = @import("std");
const visibility = @import("section_visibility.zig");

test "cached bend traversal workload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const grid: visibility.Grid = .{ .minimum = .{ -1, 0, -1 }, .size = .{ 3, 1, 3 } };
    var sections: [9]visibility.Section = undefined;
    var workspace: visibility.Workspace = undefined;
    for (&sections, 0..) |*section, index| {
        var solid: [64]u64 = @splat(std.math.maxInt(u64));
        const at = grid.position(index);
        if (std.meta.eql(at, [3]i32{ -1, 0, 0 }) or std.meta.eql(at, [3]i32{ 0, 0, -1 })) solid = @splat(0);
        if (std.meta.eql(at, [3]i32{ 0, 0, 0 })) for (0..4096) |local| {
            const x = local % 16;
            const y = local / 256;
            const z = local / 16 % 16;
            if (y >= 8 and y < 10 and x < 13 and z < 10 and (z >= 8 or x >= 11)) solid[local / 64] &= ~(@as(u64, 1) << @intCast(local % 64));
        };
        section.* = .{};
        section.build(&solid, &workspace);
    }
    var traversal = try visibility.Traversal.init(arena.allocator(), grid.size);
    const io = std.testing.io;
    const samples = 4096;
    var visits: usize = 0;
    var far_visible = false;
    const started = std.Io.Clock.cpu_thread.now(io);
    for (0..samples) |_| {
        far_visible = false;
        for (0..8) |octant| {
            traversal.begin(grid, .{ -1, 0, 0 }, 63, @intCast(octant));
            while (traversal.pending()) |index| {
                const at = grid.position(index);
                var neighbors: [6]?*const visibility.Section = @splat(null);
                for (0..6) |face| {
                    var next = at;
                    next[face / 2] += if (face % 2 == 0) @as(i32, -1) else 1;
                    if (grid.index(next)) |neighbor| neighbors[face] = &sections[neighbor];
                }
                traversal.advance(&sections[index], neighbors);
            }
            visits += traversal.visits;
            far_visible = far_visible or traversal.visible(grid.index(.{ 0, 0, -1 }).?);
        }
    }
    const elapsed = started.untilNow(io, .cpu_thread).nanoseconds;
    try std.testing.expect(!far_visible);
    std.debug.print("cached bend: visits={d} far_visible={} CPU_us={d:.3} section_bytes={d}\n", .{ visits / samples, far_visible, @as(f64, @floatFromInt(elapsed)) / (samples * std.time.ns_per_us), @sizeOf(visibility.Section) });
}

test "section topology workloads" {
    const io = std.testing.io;
    var output_buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(io, &output_buffer);
    try output.interface.writeAll("section | components | build CPU us\n");
    var random = std.Random.DefaultPrng.init(0x41d9e30);
    for ([_][]const u8{ "surface", "split", "layers", "irregular" }) |name| {
        var solid: [64]u64 = @splat(0);
        for (0..4096) |index| {
            const x = index % 16;
            const y = index / 256;
            const blocked = if (std.mem.eql(u8, name, "surface")) y < 8 else if (std.mem.eql(u8, name, "split")) x == 8 else if (std.mem.eql(u8, name, "layers")) y == 3 or y == 8 or y == 13 else random.random().uintLessThan(u8, 100) < 35;
            if (blocked) solid[index / 64] |= @as(u64, 1) << @intCast(index % 64);
        }
        var workspace: visibility.Workspace = undefined;
        var section: visibility.Section = .{};
        section.build(&solid, &workspace);
        const components = section.components;
        const samples = 512;
        const started = std.Io.Clock.cpu_thread.now(io);
        for (0..samples) |_| {
            section.build(&solid, &workspace);
            try std.testing.expectEqual(components, section.components);
        }
        const elapsed = started.untilNow(io, .cpu_thread).nanoseconds;
        try output.interface.print("{s:<9} | {d:>10} | {d:>12.2}\n", .{ name, components, @as(f64, @floatFromInt(elapsed)) / (samples * std.time.ns_per_us) });
    }
    try output.interface.flush();
}

test "shared section visibility workloads" {
    const io = std.testing.io;
    var buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(io, &buffer);
    try output.interface.writeAll("radius | scene  | sections | visits | edges | scratch KiB | CPU us\n");
    for ([_]usize{ 1, 8, 32 }) |radius| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const side = 2 * radius + 1;
        const grid: visibility.Grid = .{ .minimum = .{ -@as(i32, @intCast(radius)), -4, -@as(i32, @intCast(radius)) }, .size = .{ side, 24, side } };
        var traversal = try visibility.Traversal.init(bounded.allocator(), grid.size);
        const seen = try bounded.allocator().alloc(bool, grid.count());
        bounded.fail_index = bounded.alloc_index;
        const air: visibility.Section = .{};
        const samples = 8;
        const bytes = traversal.nodes.len * @sizeOf(@TypeOf(traversal.nodes[0])) + (traversal.buckets.len + traversal.disclosed.len) * @sizeOf(usize);
        for ([_]bool{ false, true }) |sealed| {
            var visits: usize = 0;
            var edges: usize = 0;
            const started = std.Io.Clock.cpu_thread.now(io);
            for (0..samples) |_| {
                @memset(seen, false);
                visits = 0;
                edges = 0;
                for (0..8) |octant| {
                    traversal.begin(grid, .{ 0, 4, 0 }, if (sealed) 0 else 63, @intCast(octant));
                    while (traversal.pending()) |_| traversal.advance(&air, @splat(&air));
                    visits += traversal.visits;
                    edges += traversal.edges;
                    for (traversal.disclosed[0..traversal.disclosed_count]) |index| seen[index] = true;
                }
                if (sealed) {
                    try std.testing.expectEqual(@as(usize, 0), visits);
                    try std.testing.expectEqual(@as(usize, 0), edges);
                    try std.testing.expectEqual(@as(usize, 1), traversal.disclosed_count);
                } else {
                    try std.testing.expect(visits <= 8 * grid.count());
                    try std.testing.expect(edges <= 24 * grid.count());
                    for (seen) |disclosed| try std.testing.expect(disclosed);
                }
            }
            const elapsed = started.untilNow(io, .cpu_thread).nanoseconds;
            try output.interface.print("{d:>6} | {s:<6} | {d:>8} | {d:>6} | {d:>6} | {d:>11.1} | {d:>8.2}\n", .{ radius, if (sealed) "sealed" else "open", grid.count(), visits, edges, @as(f64, @floatFromInt(bytes)) / 1024, @as(f64, @floatFromInt(elapsed)) / (samples * std.time.ns_per_us) });
        }
    }
    try output.interface.flush();
}
