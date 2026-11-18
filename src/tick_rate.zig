//! Ticks back to back, as vanilla's /tick sprint runs them: a sprint asks for some ticks, and the
//! host starts each as soon as the one before ends, without waiting out the rest of its 50 ms,
//! until they ran. Then the host keeps time again. A server without this plugin never sprints.

const std = @import("std");

pub const TickRate = struct {
    pub const id = "lightning_rod:tick_rate";
    pub const Configuration = struct {};
    pub const Dependencies = struct {};

    /// Ticks of the sprint still to run.
    remaining: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, _: Configuration, _: Dependencies) !*TickRate {
        const self = try allocator.create(TickRate);
        self.* = .{};
        return self;
    }

    /// Runs the next `ticks` ticks back to back, replacing a sprint still running, as vanilla's
    /// does. The tick that asks counts as none of them.
    pub fn sprint(self: *TickRate, ticks: u64) void {
        // A plugin that asks depends on this one, which so ticks before it, and the count starts
        // with the next tick.
        self.remaining = ticks;
    }

    pub fn sprinting(self: *const TickRate) bool {
        return self.remaining != 0;
    }

    pub fn tick(self: *TickRate) void {
        if (self.remaining != 0) self.remaining -= 1;
    }
};

test "a sprint runs as many ticks as it asked for, then ends" {
    var rate: TickRate = .{};
    try std.testing.expect(!rate.sprinting());
    rate.sprint(3);
    var ran: u64 = 0;
    while (rate.sprinting()) : (ran += 1) rate.tick();
    try std.testing.expectEqual(@as(u64, 3), ran);
    rate.tick();
    try std.testing.expect(!rate.sprinting());
}
