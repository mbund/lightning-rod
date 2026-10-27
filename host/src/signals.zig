const std = @import("std");
const builtin = @import("builtin");
const Shutdown = @import("shutdown.zig").Shutdown;

pub const Signals = if (builtin.os.tag == .windows) struct {
    shutdown: *Shutdown,
    reload_requested: ?*std.atomic.Value(bool) = null,
    var active = std.atomic.Value(?*@This()).init(null);

    pub fn install(self: *@This()) !void {
        const previous = active.swap(self, .acq_rel);
        std.debug.assert(previous == null);
        errdefer active.store(null, .release);
        if (SetConsoleCtrlHandler(handler, 1) == 0)
            return error.SignalHandlerFailed;
    }

    pub fn restore(_: *@This()) void {
        _ = SetConsoleCtrlHandler(handler, 0);
        active.store(null, .release);
    }

    fn handler(code: u32) callconv(.winapi) i32 {
        if (code != 0 and code != 1 and code != 2 and code != 6)
            return 0;

        const self = active.load(.acquire) orelse return 0;
        self.shutdown.request();
        return 1;
    }

    extern "kernel32" fn SetConsoleCtrlHandler(?*const fn (u32) callconv(.winapi) i32, i32) callconv(.winapi) i32;
} else struct {
    shutdown: *Shutdown,
    reload_requested: ?*std.atomic.Value(bool) = null,
    old_int: std.posix.Sigaction = undefined,
    old_term: std.posix.Sigaction = undefined,
    old_usr1: std.posix.Sigaction = undefined,
    var active = std.atomic.Value(?*@This()).init(null);

    pub fn install(self: *@This()) !void {
        const previous = active.swap(self, .acq_rel);
        std.debug.assert(previous == null);
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = handler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &action, &self.old_int);
        std.posix.sigaction(.TERM, &action, &self.old_term);
        std.posix.sigaction(.USR1, &action, &self.old_usr1);
    }

    pub fn restore(self: *@This()) void {
        std.posix.sigaction(.INT, &self.old_int, null);
        std.posix.sigaction(.TERM, &self.old_term, null);
        std.posix.sigaction(.USR1, &self.old_usr1, null);
        active.store(null, .release);
    }

    fn handler(signal: std.posix.SIG) callconv(.c) void {
        const self = active.load(.acquire) orelse return;
        if (signal == .USR1) {
            if (self.reload_requested) |request| request.store(true, .release);
        } else {
            self.shutdown.request();
        }
    }
};
