const std = @import("std");

const Case = struct { scenario: []const u8, version: []const u8 };

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 3) return error.ExpectedMatrixAndZig;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .limited(1024 * 1024));
    const matrix = try std.json.parseFromSlice(struct { include: []const Case }, allocator, bytes, .{ .ignore_unknown_fields = true });
    const cases = matrix.value.include;
    if (cases.len == 0 or cases.len > 256) return error.InvalidMatrix;
    var failures: std.ArrayList(Case) = .empty;
    for (cases, 1..) |case, index| {
        std.debug.print("E2E [{d}/{d}] {s} / {s}\n", .{ index, cases.len, case.scenario, case.version });
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(allocator, &.{ "timeout", "--signal=INT", "--kill-after=10s", "900s", args[2], "build" });
        try argv.appendSlice(allocator, args[3..]);
        try argv.appendSlice(allocator, &.{ "e2e", try std.fmt.allocPrint(allocator, "-Dscenario={s}", .{case.scenario}), try std.fmt.allocPrint(allocator, "-Dclient-version={s}", .{case.version}) });
        var child = try std.process.spawn(init.io, .{ .argv = argv.items, .environ_map = init.environ_map });
        const term = try child.wait(init.io);
        if (term != .exited or term.exited != 0) try failures.append(allocator, case);
    }
    std.debug.print("E2E suite: {d}/{d} passed\n", .{ cases.len - failures.items.len, cases.len });
    for (failures.items) |case| std.debug.print("FAIL: {s} / {s}\n", .{ case.scenario, case.version });
    if (failures.items.len != 0) std.process.exit(1);
}
