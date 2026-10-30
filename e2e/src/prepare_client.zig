const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 7) return error.InvalidArguments;
    const client = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[1], allocator);
    const tests = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[2], allocator);
    const version = args[3];
    const project = try std.fs.path.join(allocator, &.{ client, "build/clients", version });
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(init.io, project);
    for ([_][]const u8{ "build.gradle", "settings.gradle", "gradle.properties" }) |name| {
        try cwd.copyFile(try std.fs.path.join(allocator, &.{ client, name }), .cwd(), try std.fs.path.join(allocator, &.{ project, name }), init.io, .{});
    }
    try cwd.createDirPath(init.io, args[6]);
    const output = try cwd.realPathFileAlloc(init.io, args[6], allocator);
    try init.environ_map.put("LIGHTNING_ROD_E2E_CLIENT_SOURCE", client);
    try init.environ_map.put("LIGHTNING_ROD_E2E_TEST_ROOT", tests);
    var child = try std.process.spawn(init.io, .{
        .argv = &.{
            try std.fs.path.join(allocator, &.{ client, "gradlew" }),
            "--no-daemon",
            "-p",
            project,
            try std.fmt.allocPrint(allocator, "-Pminecraft_version={s}", .{version}),
            try std.fmt.allocPrint(allocator, "-Pclient_api={s}", .{args[4]}),
            try std.fmt.allocPrint(allocator, "-Pfabric_api_version={s}", .{args[5]}),
            try std.fmt.allocPrint(allocator, "-PruntimeOutput={s}/{s}", .{ output, version }),
            "exportRuntime",
        },
        .environ_map = init.environ_map,
    });
    const result = try child.wait(init.io);
    if (result != .exited or result.exited != 0) return error.ClientBuildFailed;
}
