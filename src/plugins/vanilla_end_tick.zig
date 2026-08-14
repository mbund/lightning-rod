const lightning_rod = @import("lightning_rod");
const vanilla_time = lightning_rod.time;
const game_rules = lightning_rod.game_rules;
const world_clock = lightning_rod.clock;
const std = @import("std");
const Packets = lightning_rod.Packets;

pub const EndTick = struct {
    pub const id = "lightning_rod:end_tick";

    clock: *world_clock.Clock,
    time: *vanilla_time.Time,
    rules: *game_rules.GameRules,

    pub fn create(allocator: std.mem.Allocator, clock: *world_clock.Clock, time: *vanilla_time.Time, rules: *game_rules.GameRules) !*EndTick {
        const self = try allocator.create(EndTick);
        self.* = .{ .clock = clock, .time = time, .rules = rules };
        return self;
    }

    pub fn tick(self: *EndTick, _: std.mem.Allocator) void {
        const clock = self.clock;
        const time = self.time;
        const rules = self.rules;
        if (rules.do_daylight_cycle) time.day_time +%= 1;
        clock.advance();
    }
};

pub const TimeSync = struct {
    pub const id = "minecraft:time_sync";

    clock: *world_clock.Clock,
    outputs: *Packets,

    pub fn create(allocator: std.mem.Allocator, clock: *world_clock.Clock, outputs: *Packets) !*TimeSync {
        const self = try allocator.create(TimeSync);
        self.* = .{ .clock = clock, .outputs = outputs };
        return self;
    }

    pub fn tick(self: *TimeSync, _: std.mem.Allocator) void {
        const clock = self.clock;
        const outputs = self.outputs;
        if (clock.tick % 20 == 0) outputs.time_changed();
    }
};

test "day time advances independently from monotonic game time" {
    var clock: world_clock.Clock = .{};
    var time: vanilla_time.Time = .{};
    var rules: game_rules.GameRules = .{};
    var plugin: EndTick = .{};
    plugin.tick(&clock, &time, &rules);
    try std.testing.expectEqual(@as(u64, 1), clock.tick);
    try std.testing.expectEqual(@as(u64, 1), time.day_time);
    rules.do_daylight_cycle = false;
    plugin.tick(&clock, &time, &rules);
    try std.testing.expectEqual(@as(u64, 2), clock.tick);
    try std.testing.expectEqual(@as(u64, 1), time.day_time);
}
