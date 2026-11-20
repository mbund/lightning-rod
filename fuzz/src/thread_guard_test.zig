const std = @import("std");
const single_thread = @import("single_thread.zig");

pub fn main() !void {
    single_thread.initialize();
    const thread = try std.Thread.spawn(.{}, run, .{});
    thread.join();
    return error.ThreadCreationWasAllowed;
}

fn run() void {}
