const std = @import("std");
const sessions = @import("sessions");
const wire_1_21_5 = @import("wire_1_21_5");
const wire_26_1 = @import("wire_26_1");
const Players = @import("players.zig").Players;
const Time = @import("time.zig").Time;
const Weather = @import("weather.zig").Weather;

/// Runs before block and entity simulation. State plugins remain usable without networking.
pub const Environment = struct {
    pub const id = "minecraft:environment";
    pub const Configuration = struct {};
    pub const Dependencies = struct { players: *Players, time: *Time, weather: *Weather };

    const View = struct {
        generation: u32 = 0,
        life: u32 = 0,
        world: u32 = 0,
        time_pending: bool = true,
        time_revision: u64 = 0,
        raining: ?bool = null,
        rain: ?f32 = null,
        thunder: ?f32 = null,
    };

    deps: Dependencies,
    views: []View,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Environment {
        const self = try allocator.create(Environment);
        const views = try allocator.alloc(View, deps.players.records.len);
        @memset(views, .{});
        self.* = .{ .deps = deps, .views = views };
        return self;
    }

    pub fn tick(self: *Environment) !void {
        const players = self.deps.players;
        const time = self.deps.time;
        const weather = self.deps.weather;
        var targets: [256]sessions.Handle = undefined;
        std.debug.assert(players.records.len <= targets.len);

        // MinecraftServer sends periodic time updates before ServerLevel advances the clock.
        for (players.records, self.views) |player, *view| {
            const handle = player.handle orelse continue;
            if (view.generation != handle.generation or view.life != player.life or view.world != player.world)
                view.* = .{ .generation = handle.generation, .life = player.life, .world = player.world };
            if (@mod(time.game_time, 20) == 0 or view.time_revision != time.revision) view.time_pending = true;
        }
        for (players.deps.sessions.config.protocols) |*protocol| {
            var count: usize = 0;
            for (players.records, self.views) |player, view| {
                if (player.stage != .ready or player.protocol != protocol.number or !view.time_pending) continue;
                targets[count] = player.handle orelse continue;
                count += 1;
            }
            if (count == 0 or !players.sendPacket(.{ writeTime, writeClocks }, protocol.number, targets[0..count], .{ time, protocol })) continue;
            for (targets[0..count]) |handle| {
                self.views[handle.index].time_pending = false;
                self.views[handle.index].time_revision = time.revision;
            }
        }

        // ServerLevel advances thunder before rain. Timer expiry toggles the state before resampling next tick.
        if (weather.weather_cycle) {
            if (weather.clear_ticks > 0) {
                weather.clear_ticks -= 1;
                weather.thunder_ticks = if (weather.thundering) 0 else 1;
                weather.rain_ticks = if (weather.raining) 0 else 1;
                weather.thundering = false;
                weather.raining = false;
            } else {
                if (weather.thunder_ticks > 0) {
                    weather.thunder_ticks -= 1;
                    if (weather.thunder_ticks == 0) weather.thundering = !weather.thundering;
                } else {
                    weather.thunder_ticks = if (weather.thundering)
                        weather.random.random().intRangeAtMost(i32, 3600, 15600)
                    else
                        weather.random.random().intRangeAtMost(i32, 12000, 180000);
                }
                if (weather.rain_ticks > 0) {
                    weather.rain_ticks -= 1;
                    if (weather.rain_ticks == 0) weather.raining = !weather.raining;
                } else {
                    weather.rain_ticks = if (weather.raining)
                        weather.random.random().intRangeAtMost(i32, 12000, 24000)
                    else
                        weather.random.random().intRangeAtMost(i32, 12000, 180000);
                }
            }
        }
        weather.thunder_level = std.math.clamp(weather.thunder_level + (if (weather.thundering) @as(f32, 0.01) else -0.01), 0, 1);
        weather.rain_level = std.math.clamp(weather.rain_level + (if (weather.raining) @as(f32, 0.01) else -0.01), 0, 1);

        // Retries retain each client's last accepted state. A full output buffer cannot lose a transition.
        for (players.deps.sessions.config.protocols) |protocol| {
            for ([_]bool{ true, false }) |skylight| {
                const rain: f32 = if (skylight) weather.rain_level else 0;
                const thunder: f32 = if (skylight) weather.thunder_level else 0;
                const raining = rain > 0.2;
                for (0..5) |stage| {
                    var count: usize = 0;
                    for (players.records, self.views) |player, view| {
                        if (player.stage != .ready or player.protocol != protocol.number) continue;
                        const handle = player.handle orelse continue;
                        if (players.deps.worlds.get(player.world).?.dimension.skylight != skylight) continue;
                        const changed = switch (stage) {
                            0, 3 => view.rain == null or view.rain.? != rain,
                            1, 4 => view.thunder == null or view.thunder.? != thunder,
                            2 => view.raining == null or view.raining.? != raining,
                            else => unreachable,
                        };
                        if (!changed) continue;
                        targets[count] = handle;
                        count += 1;
                    }
                    // Java's event IDs are 1 = stop rain and 2 = start rain, despite Prismarine's reversed labels.
                    const reason: u8 = switch (stage) {
                        0, 3 => 7,
                        1, 4 => 8,
                        2 => if (raining) 2 else 1,
                        else => unreachable,
                    };
                    const value: f32 = switch (stage) {
                        0, 3 => rain,
                        1, 4 => thunder,
                        2 => 0,
                        else => unreachable,
                    };
                    if (count == 0) continue;
                    if (!players.sendPacket(writeWeather, protocol.number, targets[0..count], .{ reason, value })) break;
                    for (targets[0..count]) |handle| switch (stage) {
                        2 => {
                            self.views[handle.index].raining = raining;
                            // Start/stop events reset the client's rain level. Always restore it afterward.
                            self.views[handle.index].rain = null;
                            self.views[handle.index].thunder = null;
                        },
                        0, 3 => self.views[handle.index].rain = rain,
                        1, 4 => self.views[handle.index].thunder = thunder,
                        else => unreachable,
                    };
                }
            }
        }

        // ServerLevel.tickTime precedes scheduled block ticks, chunk ticks, and entities.
        time.game_time +%= 1;
        if (time.daylight_cycle) time.day_time +%= 1;
    }

    fn writeTime(packet: wire_1_21_5.play.toClient.packet_update_time.Writer, time: *const Time, _: *const sessions.Protocol) ![]u8 {
        return (try (try (try packet.age(time.game_time)).time(time.day_time)).tickDayTime(time.daylight_cycle)).finish();
    }

    fn writeClocks(packet: wire_26_1.play.toClient.packet_update_time.Writer, time: *const Time, protocol: *const sessions.Protocol) ![]u8 {
        var clocks = try (try packet.age(time.game_time)).clockUpdates(2);
        for ([_][]const u8{ "minecraft:overworld", "minecraft:the_end" }) |name| {
            const entry = (try clocks.next()).?;
            const clock = try entry.id(try protocol.registryId("minecraft:world_clock", name));
            const ticks = try clock.totalTicks(time.day_time);
            const fraction = try ticks.partialTick(0);
            try clocks.advance(try fraction.rate(if (time.daylight_cycle) 1 else 0));
        }
        return (try clocks.finish()).finish();
    }

    fn writeWeather(packet: wire_1_21_5.play.toClient.packet_game_state_change.Writer, reason: u8, value: f32) ![]u8 {
        return (try (try packet.reason(reason)).gameMode(value)).finish();
    }
};
