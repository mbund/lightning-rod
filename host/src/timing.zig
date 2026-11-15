const std = @import("std");

pub const tick_ns = 50 * std.time.ns_per_ms;
pub const shutdown_ns = 5 * std.time.ns_per_s;

pub const Startup = struct {
    wall_ns: i96,
    cpu_ns: i96,
    report: ?std.Io.File = null,

    pub const Report = struct {
        entered_ns: i96,
        ready_ns: i96,
        cpu_ns: u64,

        pub fn read(reader: *std.Io.Reader) !Report {
            if (!std.mem.eql(u8, try reader.takeArray(8), "LRSTART1")) return error.InvalidStartupReport;
            const entered = try reader.takeInt(i96, .little);
            const ready = try reader.takeInt(i96, .little);
            const cpu = try reader.takeInt(u64, .little);
            if (entered < 0 or ready < entered) return error.InvalidStartupReport;
            return .{ .entered_ns = entered, .ready_ns = ready, .cpu_ns = cpu };
        }
    };

    pub fn capture(io: std.Io) Startup {
        return .{ .wall_ns = std.Io.Clock.now(.awake, io).nanoseconds, .cpu_ns = std.Io.Clock.now(.cpu_thread, io).nanoseconds };
    }

    pub fn publish(self: Startup, io: std.Io, ready: Startup) !void {
        const file = self.report orelse return;
        var buffer: [64]u8 = undefined;
        var output = file.writer(io, &buffer);
        try output.interface.writeAll("LRSTART1");
        try output.interface.writeInt(i96, self.wall_ns, .little);
        try output.interface.writeInt(i96, ready.wall_ns, .little);
        try output.interface.writeInt(u64, @intCast(ready.cpu_ns - self.cpu_ns), .little);
        try output.interface.flush();
    }
};

/// The pause the next tick keeps from the end of one that overran. Terrain is published
/// only between ticks, so ticks back to back would leave it no moment to, and an
/// overloaded server would stop sending terrain altogether.
pub const overrun_gap_ns = tick_ns / 10;

pub fn nextTick(previous: i96, now: i96) i96 {
    return @max(previous + tick_ns, now + overrun_gap_ns);
}

test "a tick that overran is followed by a pause and one on time is not delayed" {
    const start: i96 = 1_000_000_000;
    // On time: the next tick keeps its place on the 50 ms grid.
    try std.testing.expectEqual(start + tick_ns, nextTick(start, start + 10 * std.time.ns_per_ms));
    try std.testing.expectEqual(start + tick_ns, nextTick(start, start + tick_ns - overrun_gap_ns));
    // Late: the next one starts a pause after this one ended, not at once.
    try std.testing.expectEqual(start + 48 * std.time.ns_per_ms + overrun_gap_ns, nextTick(start, start + 48 * std.time.ns_per_ms));
    try std.testing.expectEqual(start + 3 * tick_ns + overrun_gap_ns, nextTick(start, start + 3 * tick_ns));
}

pub fn shutdownDeadline(io: std.Io) std.Io.Clock.Timestamp {
    return .{ .clock = .awake, .raw = .{ .nanoseconds = std.Io.Clock.now(.awake, io).nanoseconds + shutdown_ns } };
}

pub fn closeSimulation(simulation: anytype, io: std.Io) !void {
    try simulation.close(shutdownDeadline(io));
}
