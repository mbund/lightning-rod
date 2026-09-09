const lightning_rod = @import("lightning_rod");
const vanilla_time = lightning_rod.time;
const game_rules = lightning_rod.game_rules;
const world_clock = lightning_rod.clock;
const std = @import("std");
const Packets = lightning_rod.Packets;
const lifecycle = lightning_rod.player_lifecycle;

pub const EndTick = struct {
    pub const id = "lightning_rod:end_tick";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        clock: *world_clock.Clock,
        time: *vanilla_time.Time,
        rules: *game_rules.GameRules,
    };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*EndTick {
        const self = try allocator.create(EndTick);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *EndTick, _: std.mem.Allocator) void {
        const clock = self.deps.clock;
        const time = self.deps.time;
        const rules = self.deps.rules;
        if (rules.do_daylight_cycle) time.day_time +%= 1;
        clock.advance();
    }
};

pub const TimeSync = struct {
    pub const id = "minecraft:time_sync";
    pub const Configuration = struct {};
    pub const Dependencies = struct { clock: *world_clock.Clock, time: *vanilla_time.Time, outputs: *Packets, lifecycle: *lifecycle.Events };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*TimeSync {
        const self = try allocator.create(TimeSync);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *TimeSync, _: std.mem.Allocator) void {
        const clock = self.deps.clock;
        const time = self.deps.time;
        const outputs = self.deps.outputs;
        if (clock.tick % 20 == 0 and self.deps.lifecycle.joined.values.len == 0)
            outputs.emitTime(clock.tick, time.day_time);
    }
};
