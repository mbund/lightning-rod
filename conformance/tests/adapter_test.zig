const std = @import("std");
const mcc = @import("minecraft_conformance");
const LightningRodAdapter = @import("conformance_adapter").LightningRodAdapter;
const scenarios = @import("scenarios.zig");

fn monotonicNanoseconds() u64 {
    var now: std.os.linux.timespec = undefined;
    if (std.os.linux.errno(std.os.linux.clock_gettime(.MONOTONIC, &now)) != .SUCCESS) return 0;
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

pub fn main() !void {
    try LightningRodAdapter.targetInfo().require(mcc.black_box_capabilities);
    try LightningRodAdapter.targetInfo().require(mcc.persistent_restart_capability);
    var target = LightningRodAdapter.init(std.heap.page_allocator);
    defer target.deinit();
    const suite_started = monotonicNanoseconds();
    var total_ticks: u64 = 0;
    var scenarios_run: usize = 0;
    for (scenarios.all) |scenario| {
        scenarios_run += 1;
        total_ticks += runScenario(&target, scenario) catch |err| {
            std.debug.print("scenario '{s}' failed: {s}\n", .{ scenario.name, @errorName(err) });
            return err;
        };
    }
    const suite_elapsed = monotonicNanoseconds() -| suite_started;
    std.debug.print("Lightning Rod conformance total: {d:.3} ms, {d} scenarios, {d} ticks\n", .{
        @as(f64, @floatFromInt(suite_elapsed)) / std.time.ns_per_ms,
        scenarios_run,
        total_ticks,
    });
}

fn runScenario(target: *LightningRodAdapter, scenario: scenarios.Scenario) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    try scenario.run(target.adapter(), arena.allocator());
    return target.step_count;
}
