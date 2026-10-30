const std = @import("std");

pub fn add(b: *std.Build) void {
    b.step("clean", "Remove generated Zig caches and package directories").makeFn = make;
}

fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
    const b = step.owner;
    const directory = try b.build_root.handle.openDir(b.graph.io, ".", .{ .iterate = true });
    defer directory.close(b.graph.io);
    try clean(b.graph.io, directory);
}

fn clean(io: std.Io, directory: std.Io.Dir) anyerror!void {
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, ".zig-cache") or std.mem.eql(u8, entry.name, "zig-pkg")) {
            if (std.mem.eql(u8, entry.name, "zig-pkg")) {
                try directory.deleteTree(io, entry.name);
            } else {
                const cache = try directory.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                defer cache.close(io);
                var contents = cache.iterate();
                while (try contents.next(io)) |artifact| {
                    try cache.deleteTree(io, artifact.name);
                }
            }
            continue;
        }
        const preserved = [_][]const u8{ ".git", ".gradle", "zig-out", "lightning-rod-data", "artifacts", "build" };
        if (for (preserved) |name| {
            if (std.mem.eql(u8, entry.name, name)) break true;
        } else false) continue;
        const child = try directory.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
        defer child.close(io);
        try clean(io, child);
    }
}

test "cache cleanup preserves sources worlds installed binaries reports and symlink targets" {
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    const io = std.testing.io;
    for ([_][]const u8{ ".zig-cache/o/old", "plugin/.zig-cache/o/old", "plugin/zig-pkg/dependency", "lightning-rod-data/.zig-cache/keep", "zig-out/.zig-cache/keep", "artifacts/.zig-cache/keep", ".zig-cache/h/manifest" }) |path| try temporary.dir.createDirPath(io, path);
    try temporary.dir.writeFile(io, .{ .sub_path = "plugin/source.zig", .data = "source" });
    var external = std.testing.tmpDir(.{});
    defer external.cleanup();
    try external.dir.createDirPath(io, ".zig-cache/keep");
    const target = try std.fmt.allocPrint(std.testing.allocator, "../{s}", .{external.sub_path});
    defer std.testing.allocator.free(target);
    try temporary.dir.symLink(io, target, "linked", .{ .is_directory = true });
    try clean(io, temporary.dir);
    for ([_][]const u8{ ".zig-cache/o", ".zig-cache/h", "plugin/.zig-cache/o", "plugin/zig-pkg" }) |path| try std.testing.expectError(error.FileNotFound, temporary.dir.access(io, path, .{}));
    for ([_][]const u8{ "plugin/source.zig", "lightning-rod-data/.zig-cache/keep", "zig-out/.zig-cache/keep", "artifacts/.zig-cache/keep", "linked/.zig-cache/keep" }) |path| try temporary.dir.access(io, path, .{});
}
