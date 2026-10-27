const std = @import("std");
const commands = @import("commands");

const Probe = struct {
    calls: usize = 0,
    allowed: bool = true,
    const permission: commands.Permission = .{ .name = "bench.use", .description = "Benchmark permission" };

    fn allows(self: *Probe, _: u128, requested: *const commands.Permission) bool {
        std.debug.assert(requested == &Probe.permission);
        self.calls += 1;
        return self.allowed;
    }

    const Args = struct {};

    fn execute(_: *Probe, _: commands.Context, _: Args) !void {}
};

pub fn benchmark() !void {
    var buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(std.testing.io, &buffer);
    try output.interface.writeAll("leaves | permitted | current policy calls | linear policy calls | visible nodes\n");
    for ([_]usize{ 1, 16, 64 }) |count| for ([_]bool{ true, false }) |allowed| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var probe: Probe = .{ .allowed = allowed };
        const tree = try commands.Commands.init(arena.allocator(), .{ .maximum_nodes = count * 2 + 8, .permission_policy = commands.Policy.init(&probe, Probe.allows) });
        const root = try tree.literal(.{ .name = "root", .permission = &Probe.permission });
        for (0..count) |index| {
            var name: [32]u8 = undefined;
            const branch = try root.literal(.{ .name = try std.fmt.bufPrint(&name, "leaf{d}", .{index}) });
            _ = try branch.add(&probe, commands.leaf(Probe, Probe.Args, .{
                .name = "run",
                .description = "Benchmark leaf",
                .handler = Probe.execute,
                .arguments = .{},
            }));
        }
        var edges: usize = 0;
        for (0..tree.count) |parent| {
            var children = tree.children(@intCast(parent));
            for (tree.nodes[1..tree.count], 1..) |child, index| {
                if (child.parent != parent) continue;
                try std.testing.expectEqual(@as(?u16, @intCast(index)), children.next());
                edges += 1;
            }
            try std.testing.expectEqual(null, children.next());
        }
        try std.testing.expectEqual(tree.count - 1, edges);
        var actual: [1024]bool = undefined;
        tree.visibility(1, actual[0..tree.count]);
        var packet: [16 * 1024]u8 = undefined;
        const capacity = packet[0..tree.packet_capacity];
        _ = try commands.wire.treePacket(.{ ._cursor = .{ .buffer = capacity, .rest = capacity } }, tree, actual[0..tree.count]);
        const current = probe.calls;
        probe.calls = 0;
        var expected: [1024]bool = undefined;
        expected[0] = true;
        for (tree.nodes[1..tree.count], 1..) |node, index| {
            expected[index] = expected[node.parent];
            if (expected[index]) if (node.permission) |permission| {
                expected[index] = tree.config.permission_policy.?.allows(1, permission);
            };
        }
        for (tree.nodes[1..tree.count], 1..) |node, index| expected[index] = expected[index] and node.vtable != null;
        var index: usize = tree.count;
        while (index > 1) {
            index -= 1;
            if (expected[index]) expected[tree.nodes[index].parent] = true;
        }
        try std.testing.expectEqualSlices(bool, actual[0..tree.count], expected[0..tree.count]);
        try std.testing.expectEqual(@as(usize, 1), current);
        try std.testing.expectEqual(@as(usize, 1), probe.calls);
        var visible: usize = 0;
        for (actual[0..tree.count]) |value| visible += @intFromBool(value);
        try output.interface.print("{d:6} | {any:9} | {d:20} | {d:19} | {d}\n", .{ count, allowed, current, probe.calls, visible });
    };
    try output.interface.flush();
}
