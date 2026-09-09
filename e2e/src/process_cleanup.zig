const std = @import("std");
const linux = std.os.linux;

pub fn enable() !void {
    if (linux.errno(linux.prctl(@intFromEnum(linux.PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0)) != .SUCCESS)
        return error.SubreaperUnavailable;
}

pub fn finish(io: std.Io) !usize {
    const deadline = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + 2 * std.time.ns_per_s;
    var killed: usize = 0;
    while (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds < deadline) {
        var tasks = try std.Io.Dir.openDirAbsolute(io, "/proc/self/task", .{ .iterate = true });
        defer tasks.close(io);
        var iterator = tasks.iterate();
        var found: usize = 0;
        while (try iterator.next(io)) |entry| {
            var path_buffer: [64]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buffer, "{s}/children", .{entry.name});
            var bytes: [64 * 1024]u8 = undefined;
            const children = tasks.readFile(io, path, &bytes) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            var words = std.mem.tokenizeAny(u8, children, " \n");
            while (words.next()) |word| {
                const pid = try std.fmt.parseInt(linux.pid_t, word, 10);
                if (pid <= 1) return error.InvalidChildPid;
                found += 1;
                const result = linux.kill(pid, .KILL);
                if (linux.errno(result) == .SUCCESS) killed += 1;
                var status: u32 = 0;
                _ = linux.waitpid(pid, &status, linux.W.NOHANG);
            }
        }
        if (found == 0) return killed;
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    return error.TestDescendantsStillRunning;
}

test "cleanup reaps a detached descendant after its launcher exits" {
    try enable();
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "setsid sleep 60 & exit 0" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io);
    defer _ = finish(io) catch {};
    _ = try child.wait(io);
    try std.testing.expect(try finish(io) > 0);
    try std.testing.expectEqual(@as(usize, 0), try finish(io));
}
