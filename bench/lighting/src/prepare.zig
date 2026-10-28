const std = @import("std");
const baseline = @import("baseline");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 5 and args.len != 6) return error.ExpectedOptionalClientBundle;
    const root = if (args.len == 6) args[5] else if (init.environ_map.get("LIGHTNING_ROD_E2E_CLIENTS")) |clients|
        try std.fs.path.join(allocator, &.{ clients, baseline.version })
    else
        try std.fs.path.join(allocator, &.{ "../../e2e/client/build/clients", baseline.version, "build/runtime" });
    const path = try std.fs.path.join(allocator, &.{ root, "runtime.json" });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(4 * 1024 * 1024));
    const manifest = try std.json.parseFromSlice(struct { version: []const u8, test_classpath: []const []const u8 }, allocator, bytes, .{ .ignore_unknown_fields = true });
    if (!std.mem.eql(u8, manifest.value.version, baseline.version)) return error.ExpectedCanonicalMinecraftVersion;
    const entries = try allocator.alloc([]const u8, manifest.value.test_classpath.len);
    for (manifest.value.test_classpath, entries) |entry, *destination| destination.* = try std.fs.path.join(allocator, &.{ root, entry });
    try std.Io.Dir.cwd().createDirPath(init.io, std.fs.path.dirname(args[3]).?);
    try std.Io.Dir.cwd().createDirPath(init.io, args[4]);
    const classpath = try std.mem.join(allocator, ":", entries);
    var compiler = try std.process.spawn(init.io, .{
        .argv = &.{ "javac", "-cp", classpath, "-d", args[4], args[1], args[2] },
        .environ_map = init.environ_map,
    });
    const compiled = try compiler.wait(init.io);
    if (compiled != .exited or compiled.exited != 0) return error.VanillaOracleCompilationFailed;
    var child = try std.process.spawn(init.io, .{
        .argv = &.{ "java", "-Xbatch", "-Xmx1G", "-XX:ActiveProcessorCount=2", "-cp", try std.mem.join(allocator, ":", &.{ args[4], classpath }), "LightingOracle", args[3] },
        .environ_map = init.environ_map,
    });
    const term = try child.wait(init.io);
    if (term != .exited or term.exited != 0) return error.VanillaOracleFailed;
}
