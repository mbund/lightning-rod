const std = @import("std");

pub const Clock = struct {
    pub const id = "lightning_rod:clock";

    pub const Configuration = struct { ticks_per_second: u64 = 20 };

    tick: u64 = 0,
    ticks_per_second: u64 = 20,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration) !*Clock {
        if (configuration.ticks_per_second == 0) return error.InvalidTicksPerSecond;
        const self = try allocator.create(Clock);
        self.* = .{ .ticks_per_second = configuration.ticks_per_second };
        return self;
    }

    pub fn now_ns(self: *const Clock) u64 {
        return self.tick * std.time.ns_per_s / self.ticks_per_second;
    }

    pub fn advance(self: *Clock) void {
        self.tick +%= 1;
    }
};
