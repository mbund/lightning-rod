const std = @import("std");
const environment = @import("environment.zig");

pub fn main() !void {
    environment.initialize();
    const thread = try std.Thread.spawn(.{}, run, .{});
    thread.join();
    return error.ThreadCreationWasAllowed;
}

fn run() void {}
