const std = @import("std");
const BlackBox = @import("black_box").BlackBox;

const warmup_ticks = 1_000;
const measured_ticks = 10_000;

pub fn main(_: std.process.Init) !void {
    var server = try BlackBox.init(
        std.heap.page_allocator,
        0x6c69_6768_746e_696e,
    );
    defer server.deinit();
    try server.connectPlayer(0, "benchmark");

    for (0..warmup_ticks) |_| _ = try server.tick();
    const started = now();
    for (0..measured_ticks) |_| _ = try server.tick();
    const elapsed = now() - started;
    std.debug.print(
        "ticks={} total_ns={} ns_per_tick={d:.2}\n",
        .{
            measured_ticks,
            elapsed,
            @as(f64, @floatFromInt(elapsed)) / measured_ticks,
        },
    );
}

fn now() u64 {
    var value: std.os.linux.timespec = undefined;
    const result = std.os.linux.clock_gettime(.MONOTONIC, &value);
    if (std.os.linux.errno(result) != .SUCCESS) @panic("clock_gettime failed");
    return @as(u64, @intCast(value.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(value.nsec));
}
