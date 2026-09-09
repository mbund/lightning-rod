const std = @import("std");
const shutdown = @import("shutdown.zig");

pub const Signals = struct {
    requested_flag: std.atomic.Value(bool) = .init(false),
    old_int: std.posix.Sigaction = undefined,
    old_term: std.posix.Sigaction = undefined,
    installed: bool = false,

    pub fn init(self: *Signals) !void {
        comptime if (std.posix.Sigaction == void) @compileError("POSIX signals are unavailable on this target");
        if (active.load(.acquire) != 0) return error.SignalSourceAlreadyInstalled;
        var mask = std.posix.sigemptyset();
        std.posix.sigaddset(&mask, .INT);
        std.posix.sigaddset(&mask, .TERM);
        var previous_mask: std.posix.sigset_t = undefined;
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &mask, &previous_mask);
        defer std.posix.sigprocmask(std.posix.SIG.SETMASK, &previous_mask, null);
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = handle },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        active.store(@intFromPtr(self), .release);
        std.posix.sigaction(.INT, &action, &self.old_int);
        std.posix.sigaction(.TERM, &action, &self.old_term);
        self.installed = true;
    }

    pub fn deinit(self: *Signals) void {
        if (!self.installed) return;
        std.debug.assert(active.load(.acquire) == @intFromPtr(self));
        active.store(0, .release);
        std.posix.sigaction(.INT, &self.old_int, null);
        std.posix.sigaction(.TERM, &self.old_term, null);
        self.installed = false;
    }

    pub fn interface(self: *Signals) shutdown.Interface {
        return .{
            .context = self,
            .vtable = &vtable,
        };
    }

    fn requested(context: *anyopaque) bool {
        const self: *Signals = @ptrCast(@alignCast(context));
        return self.requested_flag.load(.acquire);
    }

    fn begin(_: *anyopaque) shutdown.Outcome {
        return .ok;
    }
};

var active: std.atomic.Value(usize) = .init(0);

fn handle(_: std.posix.SIG) callconv(.c) void {
    const address = active.load(.monotonic);
    if (address == 0) return;
    const self: *Signals = @ptrFromInt(address);
    self.requested_flag.store(true, .release);
}

const vtable: shutdown.Interface.VTable = .{
    .requested = Signals.requested,
    .begin = Signals.begin,
};

test "signal source exposes the standard shutdown interface" {
    var source: Signals = .{};
    try source.init();
    defer source.deinit();
    try std.testing.expect(!source.interface().requested());
    handle(.TERM);
    try std.testing.expect(source.interface().requested());
}
