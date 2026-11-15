//! Compiles a test's Java fixtures against one client bundle.
//! Usage: e2e-fixtures <bundle> <version> <sources> <output>

const std = @import("std");
const Bundle = @import("client_bundle.zig").Bundle;

const maximum_sources = 1024;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 5) return error.ExpectedBundleVersionSourcesAndOutput;
    const bundle = try Bundle.open(init, args[1], args[2]);
    const sources = args[3];
    const output = args[4];

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{
        "javac",
        "--release",
        try std.fmt.allocPrint(allocator, "{d}", .{bundle.manifest.java_release}),
        "-proc:none",
        "-nowarn",
        "-encoding",
        "UTF-8",
        "-cp",
        try bundle.classpath(allocator),
        "-d",
        output,
    });
    const first = argv.items.len;
    var directory = try std.Io.Dir.cwd().openDir(init.io, sources, .{ .iterate = true });
    defer directory.close(init.io);
    var walker = try directory.walk(allocator);
    defer walker.deinit();
    while (try walker.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".java")) continue;
        if (argv.items.len - first == maximum_sources) return error.TooManyFixtureSources;
        try argv.append(allocator, try std.fs.path.join(allocator, &.{ sources, entry.path }));
    }
    if (argv.items.len == first) return error.NoFixtureSources;
    // Sorted so javac sees the same command for the same sources.
    std.mem.sort([]const u8, argv.items[first..], {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);

    var child = try std.process.spawn(init.io, .{ .argv = argv.items, .environ_map = init.environ_map });
    const term = try child.wait(init.io);
    if (term != .exited or term.exited != 0) return error.FixtureCompilationFailed;
}
