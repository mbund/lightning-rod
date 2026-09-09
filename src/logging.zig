const std = @import("std");

pub const Queue = @import("logging/queue.zig").Queue;

var installed_queue: std.atomic.Value(usize) = .init(0);

pub fn install(queue: *Queue) void {
    const address = @intFromPtr(queue);
    std.debug.assert(address != 0);
    const previous = installed_queue.cmpxchgStrong(0, address, .acq_rel, .acquire);
    std.debug.assert(previous == null);
}

pub fn uninstall(queue: *Queue) void {
    const address = @intFromPtr(queue);
    const previous = installed_queue.cmpxchgStrong(address, 0, .acq_rel, .acquire);
    std.debug.assert(previous == null);
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const address = installed_queue.load(.acquire);
    if (address == 0) return;
    const queue: *Queue = @ptrFromInt(address);
    queue.write(level, @tagName(scope), format, args);
}

test "the selected std.log backend has no implicit terminal fallback" {
    try std.testing.expectEqual(@as(usize, 0), installed_queue.load(.acquire));
    logFn(.info, .test_scope, "ignored {}", .{1});
}
