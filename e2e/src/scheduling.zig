const std = @import("std");
const linux = std.os.linux;

pub const priority = 1;

pub fn enable() !void {
    const result = linux.sched_setscheduler(0, .{ .mode = .FIFO }, &.{ .priority = priority });
    switch (linux.errno(result)) {
        .SUCCESS => {},
        .PERM => return error.RealtimePermissionRequired,
        else => return error.SchedulerConfigurationFailed,
    }
}

pub fn preflight() !void {
    var limit: linux.rlimit = undefined;
    if (linux.errno(linux.getrlimit(.RTPRIO, &limit)) != .SUCCESS) return error.SchedulerConfigurationFailed;
    if (limit.cur < priority and limit.max >= priority) {
        limit.cur = priority;
        if (linux.errno(linux.setrlimit(.RTPRIO, &limit)) != .SUCCESS) return error.SchedulerConfigurationFailed;
    }
    const previous = linux.sched_getscheduler(0);
    if (linux.errno(previous) != .SUCCESS) return error.SchedulerConfigurationFailed;
    var parameter: linux.sched_param = undefined;
    if (linux.errno(linux.sched_getparam(0, &parameter)) != .SUCCESS) return error.SchedulerConfigurationFailed;
    try enable();
    if (linux.errno(linux.sched_setscheduler(0, @bitCast(@as(i32, @intCast(previous))), &parameter)) != .SUCCESS)
        return error.SchedulerRestoreFailed;
}

test "realtime permission probe preserves the runner scheduling policy" {
    const previous = linux.sched_getscheduler(0);
    var parameter: linux.sched_param = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.sched_getparam(0, &parameter)));
    preflight() catch |err| switch (err) {
        error.RealtimePermissionRequired => {},
        else => return err,
    };
    try std.testing.expectEqual(previous, linux.sched_getscheduler(0));
    var after: linux.sched_param = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.sched_getparam(0, &after)));
    try std.testing.expectEqual(parameter.priority, after.priority);
}

test "server threads inherit FIFO scheduling" {
    const previous = linux.sched_getscheduler(0);
    var parameter: linux.sched_param = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.sched_getparam(0, &parameter)));
    enable() catch |err| switch (err) {
        error.RealtimePermissionRequired => return error.SkipZigTest,
        else => return err,
    };
    defer std.debug.assert(linux.errno(linux.sched_setscheduler(0, @bitCast(@as(i32, @intCast(previous))), &parameter)) == .SUCCESS);
    const Child = struct {
        fn run(valid: *bool) void {
            var child: linux.sched_param = undefined;
            valid.* = linux.sched_getscheduler(0) == @as(u32, @bitCast(linux.SCHED{ .mode = .FIFO })) and
                linux.errno(linux.sched_getparam(0, &child)) == .SUCCESS and child.priority == priority;
        }
    };
    var valid = false;
    const thread = try std.Thread.spawn(.{}, Child.run, .{&valid});
    thread.join();
    try std.testing.expect(valid);
}
