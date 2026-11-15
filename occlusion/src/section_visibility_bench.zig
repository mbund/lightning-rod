const std = @import("std");
const visibility = @import("section_visibility.zig");
const disclosure = @import("section_disclosure.zig");
const horizon = @import("chunk_horizon.zig");

test "cached bend traversal workload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const grid: visibility.Grid = .{ .minimum = .{ -1, 0, -1 }, .size = .{ 3, 1, 3 } };
    var sections: [9]visibility.Section = undefined;
    var workspace: visibility.Workspace = undefined;
    var prepared: [visibility.Section.prepared_bytes]u8 = undefined;
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
        section.build(&solid, &workspace, &prepared);
    }
    var query = try disclosure.Query.init(arena.allocator(), grid.size);
    for (query.topology) |*column| column.* = .{};
    for (&sections, 0..) |*section, index| query.topology[index].set(0, section.topology);
    var starts: [27]u6 = @splat(0);
    starts[13] = 63;
    const io = std.testing.io;
    const samples = 4096;
    const started = std.Io.Clock.cpu_thread.now(io);
    var operations: disclosure.Query.Statistics = undefined;
    for (0..samples) |_| operations = query.solve(grid, .{ -1, 0, 0 }, 1, 1 << 13, &starts, null);
    try std.testing.expect(query.masks[grid.index(.{ 0, 0, -1 }).?] == 0);
    std.debug.print("coarse bend: columns={d} visits={d} CPU_us={d:.3}\n", .{ operations.columns, operations.visits, @as(f64, @floatFromInt(started.untilNow(io, .cpu_thread).nanoseconds)) / (samples * std.time.ns_per_us) });
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
        var prepared: [visibility.Section.prepared_bytes]u8 = undefined;
        var section: visibility.Section = .{};
        section.build(&solid, &workspace, &prepared);
        const components = section.components;
        const samples = 512;
        const started = std.Io.Clock.cpu_thread.now(io);
        for (0..samples) |_| {
            section.build(&solid, &workspace, &prepared);
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
    try output.interface.writeAll("radius | scene  | sections | columns | scratch KiB | CPU us\n");
    for ([_]usize{ 1, 8, 32 }) |radius| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const side = 2 * radius + 1;
        const grid: visibility.Grid = .{ .minimum = .{ -@as(i32, @intCast(radius)), -4, -@as(i32, @intCast(radius)) }, .size = .{ side, 24, side } };
        var query = try disclosure.Query.init(bounded.allocator(), grid.size);
        for (query.topology) |*column| column.* = .{ .paths = @splat((1 << 24) - 1) };
        const bytes = std.mem.sliceAsBytes(query.topology).len + std.mem.sliceAsBytes(query.waves).len + std.mem.sliceAsBytes(query.incoming).len + std.mem.sliceAsBytes(query.known).len + std.mem.sliceAsBytes(query.masks).len;
        bounded.fail_index = bounded.alloc_index;
        bounded.resize_fail_index = bounded.resize_index;
        for ([_]bool{ false, true }) |sealed| {
            var starts: [27]u6 = @splat(0);
            starts[13] = if (sealed) 0 else 63;
            const samples = 16;
            const started = std.Io.Clock.cpu_thread.now(io);
            var operations: disclosure.Query.Statistics = undefined;
            for (0..samples) |_| operations = query.solve(grid, .{ 0, 4, 0 }, @intCast(radius), 1 << 13, &starts, null);
            const elapsed = started.untilNow(io, .cpu_thread).nanoseconds;
            for (query.masks, 0..) |mask, column| {
                const at = grid.position(column * 24);
                const visible = if (sealed) at[0] == 0 and at[2] == 0 else horizon.contains(@intCast(radius), .{ .x = 0, .z = 0 }, .{ .x = at[0], .z = at[2] });
                try std.testing.expectEqual(if (!visible) @as(u32, 0) else if (sealed) @as(u32, 1) << 8 else (1 << 24) - 1, mask);
            }
            try output.interface.print("{d:>6} | {s:<6} | {d:>8} | {d:>7} | {d:>11.1} | {d:>8.2}\n", .{ radius, if (sealed) "sealed" else "open", grid.count(), operations.columns, @as(f64, @floatFromInt(bytes)) / 1024, @as(f64, @floatFromInt(elapsed)) / (samples * std.time.ns_per_us) });
            try std.testing.expect(!bounded.has_induced_failure);
        }
    }
    try output.interface.flush();
}
