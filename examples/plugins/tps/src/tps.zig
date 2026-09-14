const std = @import("std");
const rod = @import("lightning_rod");
const bossbars = @import("bossbars");

pub const Tps = struct {
    pub const id = "lightning_rod:tps";

    pub const Configuration = struct { update_interval_ms: u32 = 500 };

    pub const Dependencies = struct { bossbars: *bossbars.Bossbars };

    pub const windows = [_]u64{ 1, 10, 60 };
    const quantum = 100 * std.time.ns_per_ms;

    const Bucket = struct {
        stamp: u64 = std.math.maxInt(u64),
        started_ns: i96 = 0,
        ticks: u64 = 0,
        ns: u64 = 0,
    };

    deps: Dependencies,
    config: Configuration,
    bars: [3]bossbars.Handle,
    buckets: [601]Bucket = @splat(.{}),
    previous: u64 = 0,
    previous_ns: i96 = 0,
    updated_ns: i96 = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*Tps {
        if (config.update_interval_ms < 100 or config.update_interval_ms > 10_000) return error.InvalidConfiguration;

        const self = try allocator.create(Tps);
        self.* = .{ .deps = deps, .config = config, .bars = undefined };

        for (&self.bars, windows) |*bar, seconds| {
            var title: [80]u8 = undefined;
            bar.* = try deps.bossbars.create(.{
                .title = try std.fmt.bufPrint(&title, "{d}s | measuring TPS / MSPT", .{seconds}),
                .progress = 0,
                .color = .white,
            });
        }

        return self;
    }

    pub fn tick(self: *Tps) !void {
        const metrics = rod.metrics.snapshot() orelse return;
        const sample = metrics.completed_tick;
        if (sample.sequence == 0 or sample.sequence == self.previous) return;

        const started_ns = if (self.previous == 0) sample.ended_ns - sample.duration_ns else self.previous_ns;
        self.previous = sample.sequence;
        self.previous_ns = sample.ended_ns;
        const stamp: u64 = @intCast(@divTrunc(sample.ended_ns, quantum));
        const bucket = &self.buckets[stamp % self.buckets.len];

        if (bucket.stamp != stamp) bucket.* = .{ .stamp = stamp, .started_ns = started_ns };

        bucket.ticks += 1;
        bucket.ns += sample.duration_ns;
        if (sample.ended_ns - self.updated_ns < @as(i96, self.config.update_interval_ms) * std.time.ns_per_ms) return;
        self.updated_ns = sample.ended_ns;

        for (windows, self.bars) |seconds, bar| {
            var count: u64 = 0;
            var duration: u64 = 0;
            var oldest_ns = sample.ended_ns;

            for (self.buckets) |entry| {
                if (entry.stamp > stamp or stamp - entry.stamp >= seconds * 10) continue;
                count += entry.ticks;
                duration += entry.ns;
                oldest_ns = @min(oldest_ns, entry.started_ns);
            }

            const elapsed: f64 = @floatFromInt(@max(1, @min(sample.ended_ns - oldest_ns, @as(i96, seconds) * std.time.ns_per_s)));
            const tps = @min(20, @as(f64, @floatFromInt(count)) * std.time.ns_per_s / elapsed);
            const mspt = @as(f64, @floatFromInt(duration)) / @as(f64, @floatFromInt(@max(1, count))) / std.time.ns_per_ms;
            var title: [96]u8 = undefined;
            try self.deps.bossbars.update(bar, .{
                .title = try std.fmt.bufPrint(&title, "{d}s | {d:.1} TPS | {d:.2} MSPT", .{ seconds, tps, mspt }),
                .progress = @floatCast(tps / 20),
                .color = if (tps >= 18 and mspt < 40) .green else if (tps >= 15 and mspt < 50) .yellow else .red,
            });
        }
    }
};
