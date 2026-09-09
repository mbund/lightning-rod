const lightning_rod = @import("lightning_rod");
const std = @import("std");

pub const KeepAlive = struct {
    pub const id = "minecraft:keep_alive";
    pub const Configuration = struct {
        interval_seconds: u64 = 10,

        pub fn validate(self: Configuration) !void {
            if (self.interval_seconds == 0) return error.InvalidKeepAliveInterval;
        }
    };
    pub const Dependencies = struct {
        clock: *lightning_rod.clock.Clock,
        inputs: *lightning_rod.inputs.Inputs,
        players: *lightning_rod.players.Players,
        outputs: *lightning_rod.Packets,
    };

    const State = struct {
        next_tick: u64 = 0,
        sent_tick: u64 = 0,
        id: i64 = 0,
        awaiting: bool = false,
        latency_ms: i32 = 0,
        latency_dirty: bool = false,
    };

    deps: Dependencies,
    interval_ticks: u64,
    states: []State = &.{},

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, configuration: Configuration) !*KeepAlive {
        try configuration.validate();
        const self = try allocator.create(KeepAlive);
        const states = try allocator.alloc(State, deps.players.records.len);
        @memset(states, .{});
        self.* = .{
            .deps = deps,
            .interval_ticks = try std.math.mul(u64, deps.clock.ticks_per_second, configuration.interval_seconds),
            .states = states,
        };
        return self;
    }

    pub fn tick(self: *KeepAlive, _: std.mem.Allocator) void {
        self.acceptResponses();
        self.sendDue();
        self.broadcastLatency();
    }

    fn acceptResponses(self: *KeepAlive) void {
        const absent = std.math.minInt(i64);
        for (self.deps.players.activeSlots()) |slot| {
            const response = self.deps.inputs.keep_alive_responses[slot];
            self.deps.inputs.keep_alive_responses[slot] = absent;
            if (response == absent) continue;
            self.acceptResponse(slot, response);
        }
    }

    fn acceptResponse(self: *KeepAlive, slot: u16, response: i64) void {
        const state = &self.states[slot];
        if (!state.awaiting or state.id != response) return;
        state.awaiting = false;
        const elapsed = self.deps.clock.tick -% state.sent_tick;
        const milliseconds = elapsed *| std.time.ms_per_s / self.deps.clock.ticks_per_second;
        state.latency_ms = @intCast(@min(milliseconds, @as(u64, std.math.maxInt(i32))));
        state.latency_dirty = true;
    }

    fn sendDue(self: *KeepAlive) void {
        const now = self.deps.clock.tick;
        for (self.deps.players.activeSlots()) |slot| {
            const state = &self.states[slot];
            if (now < state.next_tick) continue;
            state.id +%= 1;
            state.sent_tick = now;
            state.next_tick = now + self.interval_ticks;
            state.awaiting = true;
            _ = self.deps.outputs.keepAlive(slot, state.id);
        }
    }

    fn broadcastLatency(self: *KeepAlive) void {
        for (self.deps.players.activeSlots()) |slot| {
            const state = &self.states[slot];
            if (!state.latency_dirty) continue;
            state.latency_dirty = false;
            self.deps.outputs.playerLatency(slot, state.latency_ms);
        }
    }
};
