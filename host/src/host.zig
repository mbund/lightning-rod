const std = @import("std");
const execve = @import("reload_execve");

pub const Process = @import("process.zig").Process;

pub const timing = @import("timing.zig");
pub const Startup = timing.Startup;
pub const Shutdown = @import("shutdown.zig").Shutdown;
pub const Signals = @import("signals.zig").Signals;

pub fn elapsedMs(io: std.Io, started: i96) u64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.awake, io).nanoseconds - started, std.time.ns_per_ms));
}

pub fn inheritedListener(init: std.process.Init) !?i32 {
    if (init.environ_map.contains(execve.environment_key)) return null;
    const value = init.environ_map.get("LIGHTNING_ROD_LISTENER_FD") orelse return null;
    const fd = try std.fmt.parseInt(i32, value, 10);
    if (fd < 3) return error.InvalidListener;
    return fd;
}
