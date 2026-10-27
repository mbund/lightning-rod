const std = @import("std");

pub const priority = 1;

pub fn enable() !void {
    const result = std.os.linux.sched_setscheduler(0, .{ .mode = .FIFO }, &.{ .priority = priority });
    switch (std.os.linux.errno(result)) {
        .SUCCESS => {},
        .PERM => return error.RealtimePermissionRequired,
        else => return error.SchedulerConfigurationFailed,
    }
}

pub fn preflight() !void {
    var limit: std.os.linux.rlimit = undefined;
    if (std.os.linux.errno(std.os.linux.getrlimit(.RTPRIO, &limit)) != .SUCCESS) return error.SchedulerConfigurationFailed;
    if (limit.cur < priority and limit.max >= priority) {
        limit.cur = priority;
        if (std.os.linux.errno(std.os.linux.setrlimit(.RTPRIO, &limit)) != .SUCCESS) return error.SchedulerConfigurationFailed;
    }
    const previous = std.os.linux.sched_getscheduler(0);
    if (std.os.linux.errno(previous) != .SUCCESS) return error.SchedulerConfigurationFailed;
    var parameter: std.os.linux.sched_param = undefined;
    if (std.os.linux.errno(std.os.linux.sched_getparam(0, &parameter)) != .SUCCESS) return error.SchedulerConfigurationFailed;
    try enable();
    if (std.os.linux.errno(std.os.linux.sched_setscheduler(0, @bitCast(@as(i32, @intCast(previous))), &parameter)) != .SUCCESS)
        return error.SchedulerRestoreFailed;
}

test "realtime permission probe preserves the runner scheduling policy" {
    const previous = std.os.linux.sched_getscheduler(0);
    var parameter: std.os.linux.sched_param = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.sched_getparam(0, &parameter)));
    preflight() catch |err| switch (err) {
        error.RealtimePermissionRequired => {},
        else => return err,
    };
    try std.testing.expectEqual(previous, std.os.linux.sched_getscheduler(0));
    var after: std.os.linux.sched_param = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.sched_getparam(0, &after)));
    try std.testing.expectEqual(parameter.priority, after.priority);
}

test "server threads inherit FIFO scheduling" {
    const previous = std.os.linux.sched_getscheduler(0);
    var parameter: std.os.linux.sched_param = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.sched_getparam(0, &parameter)));
    enable() catch |err| switch (err) {
        error.RealtimePermissionRequired => return error.SkipZigTest,
        else => return err,
    };
    defer std.debug.assert(std.os.linux.errno(std.os.linux.sched_setscheduler(0, @bitCast(@as(i32, @intCast(previous))), &parameter)) == .SUCCESS);
    const Child = struct {
        fn run(valid: *bool) void {
            var child: std.os.linux.sched_param = undefined;
            valid.* = std.os.linux.sched_getscheduler(0) == @as(u32, @bitCast(std.os.linux.SCHED{ .mode = .FIFO })) and
                std.os.linux.errno(std.os.linux.sched_getparam(0, &child)) == .SUCCESS and child.priority == priority;
        }
    };
    var valid = false;
    const thread = try std.Thread.spawn(.{}, Child.run, .{&valid});
    thread.join();
    try std.testing.expect(valid);
}
