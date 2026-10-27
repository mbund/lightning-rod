const std = @import("std");
const spatial = @import("item_spatial.zig");

fn inspect(index: *const spatial.Index, root: ?u32, parent: ?u32, lower: ?spatial.Resident, upper: ?spatial.Resident, depth: usize) !usize {
    const at = root orelse return 0;
    try std.testing.expect(at < index.nodes.len and depth < 32);
    const node = index.nodes[at];
    const resident = index.residents[at];
    try std.testing.expect(node.indexed and resident.alive and node.parent == parent);
    if (lower) |bound| try std.testing.expect(spatial.Index.less(bound, resident));
    if (upper) |bound| try std.testing.expect(spatial.Index.less(resident, bound));
    const left = try inspect(index, node.children[0], at, lower, resident, depth + 1);
    const right = try inspect(index, node.children[1], at, resident, upper, depth + 1);
    const left_height = if (node.children[0]) |child| index.nodes[child].height else 0;
    const right_height = if (node.children[1]) |child| index.nodes[child].height else 0;
    try std.testing.expectEqual(1 + @max(left_height, right_height), node.height);
    try std.testing.expect(@max(left_height, right_height) - @min(left_height, right_height) <= 1);
    return left + right + 1;
}

fn check(index: *const spatial.Index) !void {
    try std.testing.expectEqual(index.count, try inspect(index, index.root, null, null, null, 0));
    var ordered: [257]u32 = undefined;
    var count: usize = 0;
    for (index.residents, 0..) |resident, at| {
        try std.testing.expectEqual(resident.alive, index.nodes[at].indexed);
        if (!resident.alive) continue;
        ordered[count] = @intCast(at);
        count += 1;
    }
    std.mem.sort(u32, ordered[0..count], index.residents, struct {
        fn less(residents: []const spatial.Resident, a: u32, b: u32) bool {
            return spatial.Index.less(residents[a], residents[b]);
        }
    }.less);
    var next = index.lowerBound(.{ .x = std.math.minInt(i32), .z = std.math.minInt(i32), .y = std.math.minInt(i32) });
    for (ordered[0..count]) |expected| {
        try std.testing.expectEqual(@as(?u32, expected), next);
        try std.testing.expectEqual(@as(?u32, expected), index.lowerBound(index.residents[expected]));
        next = index.next(next.?);
    }
    try std.testing.expectEqual(null, next);
}

test "spatial index matches sorted residents through movement retirement and slot reuse" {
    var residents: [257]spatial.Resident = @splat(.{});
    var memory: [16 * 1024]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&memory);
    var index = try spatial.Index.init(allocator.allocator(), &residents);
    const assigned = allocator.end_index;
    var prng = std.Random.DefaultPrng.init(0x6974656d73706174);
    for (0..3000) |step| {
        const at = prng.random().uintLessThan(u32, residents.len);
        if (residents[at].alive) index.remove(at);
        if (step % 3 == 0) {
            residents[at] = .{};
        } else {
            residents[at] = .{
                .id = step + 1,
                .world = prng.random().uintLessThan(u32, 3),
                .x = prng.random().intRangeAtMost(i32, -4, 4),
                .z = prng.random().intRangeAtMost(i32, -4, 4),
                .y = prng.random().intRangeAtMost(i32, -4, 4),
                .alive = true,
            };
            index.insert(at);
        }
        try check(&index);
        const query: spatial.Resident = .{
            .world = prng.random().uintLessThan(u32, 4),
            .x = prng.random().intRangeAtMost(i32, -5, 5),
            .z = prng.random().intRangeAtMost(i32, -5, 5),
            .y = prng.random().intRangeAtMost(i32, -5, 5),
            .id = prng.random().uintLessThan(u64, step + 2),
        };
        var expected: ?u32 = null;
        for (residents, 0..) |resident, slot| {
            if (!resident.alive or spatial.Index.less(resident, query)) continue;
            if (expected == null or spatial.Index.less(resident, residents[expected.?])) expected = @intCast(slot);
        }
        try std.testing.expectEqual(expected, index.lowerBound(query));
    }
    try std.testing.expectEqual(assigned, allocator.end_index);
}

test "spatial index stays balanced through monotonic insertion and complete deletion at capacity" {
    for ([_]usize{ 1, 2, 257, 65536 }) |capacity| {
        const residents = try std.testing.allocator.alloc(spatial.Resident, capacity);
        defer std.testing.allocator.free(residents);
        var index = try spatial.Index.init(std.testing.allocator, residents);
        defer std.testing.allocator.free(index.nodes);
        for (residents, 0..) |*resident, at| {
            resident.* = .{ .id = at + 1, .alive = true };
            index.insert(@intCast(at));
        }
        try std.testing.expectEqual(capacity, try inspect(&index, index.root, null, null, null, 0));
        for (0..capacity) |offset| {
            const at: u32 = @intCast((offset * 40503) % capacity);
            index.remove(at);
            residents[at].alive = false;
        }
        try std.testing.expectEqual(@as(usize, 0), index.count);
        try std.testing.expectEqual(null, index.lowerBound(.{}));
        try std.testing.expectEqual(null, index.root);
    }
}

test "rectangle queries match a direct model across gaps worlds and movement" {
    var residents: [257]spatial.Resident = @splat(.{});
    var index = try spatial.Index.init(std.testing.allocator, &residents);
    defer std.testing.allocator.free(index.nodes);
    var random = std.Random.DefaultPrng.init(0x72656374616e676c);
    for (0..2048) |step| {
        const slot = random.random().uintLessThan(u32, residents.len);
        if (residents[slot].alive) index.remove(slot);
        residents[slot] = .{
            .id = step + 1,
            .world = random.random().uintLessThan(u32, 3),
            .x = random.random().intRangeAtMost(i32, -32, 32) * 100,
            .z = random.random().intRangeAtMost(i32, -32, 32) * 100,
            .alive = step % 7 != 0,
        };
        if (residents[slot].alive) index.insert(slot);
        const world = random.random().uintLessThan(u32, 4);
        const minimum: [2]i32 = .{ random.random().intRangeAtMost(i32, -4000, 0), random.random().intRangeAtMost(i32, -4000, 0) };
        const maximum: [2]i32 = .{ random.random().intRangeAtMost(i32, 0, 4000), random.random().intRangeAtMost(i32, 0, 4000) };
        var selected: [257]bool = @splat(false);
        var query = index.rectangle(world, minimum, maximum);
        while (query.next()) |at| {
            try std.testing.expect(!selected[at]);
            selected[at] = true;
        }
        for (residents, selected) |resident, found| {
            const expected = resident.alive and resident.world == world and resident.x >= minimum[0] and resident.x <= maximum[0] and resident.z >= minimum[1] and resident.z <= maximum[1];
            try std.testing.expectEqual(expected, found);
        }
    }
    var all = index.rectangle(0, @splat(std.math.minInt(i32)), @splat(std.math.maxInt(i32)));
    var count: usize = 0;
    while (all.next()) |_| count += 1;
    var expected: usize = 0;
    for (residents) |resident| expected += @intFromBool(resident.alive and resident.world == 0);
    try std.testing.expectEqual(expected, count);
}
