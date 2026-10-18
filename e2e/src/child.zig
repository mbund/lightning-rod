const std = @import("std");

pub const ManagedChild = struct {
    child: std.process.Child,
    group: std.posix.pid_t,
    termination: ?std.process.Child.Term = null,

    fn waitUntil(self: *ManagedChild, io: std.Io, deadline: i96) !std.process.Child.Term {
        while (true) {
            var info: std.os.linux.siginfo_t = std.mem.zeroes(std.os.linux.siginfo_t);
            switch (std.os.linux.errno(std.os.linux.waitid(.PID, self.group, &info, std.os.linux.W.EXITED | std.os.linux.W.NOHANG | std.os.linux.W.NOWAIT, null))) {
                .SUCCESS => if (info.code != 0) {
                    // Kill descendants while the zombie still reserves this process-group ID.
                    std.posix.kill(-self.group, .KILL) catch {};
                    const term = try self.child.wait(io);
                    self.termination = term;
                    return term;
                },
                .INTR => continue,
                else => return error.ChildWaitFailed,
            }
            if (std.Io.Clock.now(.awake, io).nanoseconds >= deadline) return error.ChildShutdownTimeout;
            try std.Io.sleep(io, .fromMilliseconds(10), .awake);
        }
    }

    pub fn shutdown(self: *ManagedChild, io: std.Io, crash: bool, timeout: std.Io.Duration) !void {
        std.debug.assert(self.child.id != null);
        std.debug.assert(self.child.id.? == self.group);
        std.posix.kill(-self.group, if (crash) .KILL else .TERM) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => return err,
        };
        const term = try self.waitUntil(io, std.Io.Clock.now(.awake, io).nanoseconds + timeout.toNanoseconds());
        const passed = if (crash) term == .signal and term.signal == .KILL else term == .exited and term.exited == 0;
        if (!passed) return error.ChildShutdownFailed;
    }

    pub fn stop(self: *ManagedChild, io: std.Io) void {
        if (self.child.id == null) return;
        std.posix.kill(-self.group, .TERM) catch {};
        _ = self.waitUntil(io, std.Io.Clock.now(.awake, io).nanoseconds + std.time.ns_per_s) catch {
            std.posix.kill(-self.group, .KILL) catch {};
            self.child.kill(io);
        };
    }
};

fn spawnTest(io: std.Io, script: []const u8) !ManagedChild {
    var child = try std.process.spawn(io, .{ .argv = &.{ "sh", "-c", script }, .stdout = .pipe, .stderr = .ignore, .pgid = 0 });
    errdefer child.kill(io);
    var buffer: [32]u8 = undefined;
    var reader = child.stdout.?.reader(io, &buffer);
    if (try reader.interface.takeByte() != 'r') return error.ChildNotReady;
    child.stdout.?.close(io);
    child.stdout = null;
    return .{ .child = child, .group = child.id.? };
}

test "graceful shutdown checks status and permits cleanup delays" {
    const io = std.testing.io;
    var child = try spawnTest(io, "trap 'sleep 0.05; exit 0' TERM; printf r; while :; do sleep 1; done");
    defer child.stop(io);
    try child.shutdown(io, false, .fromSeconds(2));
    try std.testing.expect(child.child.id == null);
}

test "failed shutdown and timeout cannot become passing scenarios" {
    const io = std.testing.io;
    var failed = try spawnTest(io, "trap 'exit 7' TERM; printf r; while :; do sleep 1; done");
    defer failed.stop(io);
    try std.testing.expectError(error.ChildShutdownFailed, failed.shutdown(io, false, .fromSeconds(2)));
    var stalled = try spawnTest(io, "trap '' TERM; printf r; while :; do sleep 1; done");
    defer stalled.stop(io);
    try std.testing.expectError(error.ChildShutdownTimeout, stalled.shutdown(io, false, .fromMilliseconds(30)));
}

test "intentional crashes require SIGKILL" {
    const io = std.testing.io;
    var child = try spawnTest(io, "printf r; while :; do sleep 1; done");
    defer child.stop(io);
    try child.shutdown(io, true, .fromSeconds(2));
}
