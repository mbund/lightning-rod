const std = @import("std");
const config = @import("../config.zig").value;

pub const Clock = struct {
    pub const id = "lightning_rod:clock";

    tick: u64 = 0,

    pub fn create(allocator: std.mem.Allocator) !*Clock {
        const self = try allocator.create(Clock);
        self.* = .{};
        return self;
    }

    pub fn now_ns(self: Clock) u64 {
        return self.tick * std.time.ns_per_s / config.ticks_per_second;
    }

    pub fn advance(self: *Clock) void {
        self.tick +%= 1;
    }
};
