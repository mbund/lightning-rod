const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const sessions = @import("sessions");
const storage = lightning_rod.storage;

pub const Probe = struct {
    pub const id = "e2e:environment";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        time: *vanilla.Time,
        weather: *vanilla.Weather,
        environment: *vanilla.Environment,
        players: *vanilla.Players,
        worlds: *vanilla.VanillaWorlds,
        commands: *vanilla.CommandDispatch,
        reload_request: *vanilla.Reload,
        storage: storage.Namespace,
    };

    const Snapshot = extern struct {
        game_time: i64,
        day_time: i64,
        random: [4]u64,
        rain: f32,
        thunder: f32,
        clear_ticks: i32,
        rain_ticks: i32,
        thunder_ticks: i32,
        raining: u8,
        thundering: u8,
        daylight_cycle: u8,
        weather_cycle: u8,
    };

    deps: Dependencies,
    previous_age: i64,
    expiry: u8 = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps, .previous_age = deps.time.game_time };
        var bytes: [@sizeOf(Snapshot)]u8 = undefined;
        if (try deps.storage.get("expected", &bytes)) |length| {
            if (length != bytes.len or !std.meta.eql(self.snapshot(), std.mem.bytesToValue(Snapshot, &bytes))) return error.EnvironmentReloadMismatch;
            std.log.info("event=environment_restored age={d} day={d} rain={d} thunder={d}", .{ deps.time.game_time, deps.time.day_time, deps.weather.rain_level, deps.weather.thunder_level });
        }
        try deps.commands.observeCommand(self, onCommand);
        return self;
    }

    fn onCommand(self: *Probe, handle: sessions.Handle, command: []const u8) !void {
        const time = self.deps.time;
        const weather = self.deps.weather;
        if (std.mem.eql(u8, command, "environment freeze")) {
            time.set(6000);
            time.setDaylightCycle(false);
            weather.set(.thunder, 12000);
            weather.weather_cycle = false;
        } else if (std.mem.eql(u8, command, "environment clear")) {
            time.set(18000);
            weather.weather_cycle = true;
            weather.set(.clear, 12000);
        } else if (std.mem.eql(u8, command, "environment expiry")) {
            weather.clear_ticks = 0;
            weather.rain_ticks = 2;
            weather.thunder_ticks = 2;
            weather.raining = false;
            weather.thundering = false;
            self.expiry = 2;
        } else if (std.mem.eql(u8, command, "environment resume")) {
            time.set(0);
            time.setDaylightCycle(true);
            weather.set(.clear, 12000);
        } else if (std.mem.eql(u8, command, "environment reload")) {
            try self.deps.reload_request.stage("environment");
        } else if (std.mem.eql(u8, command, "environment nether") or std.mem.eql(u8, command, "environment overworld")) {
            const player = &self.deps.players.records[handle.index];
            const destination = if (std.mem.endsWith(u8, command, " nether")) self.deps.worlds.nether else self.deps.worlds.overworld;
            try self.deps.players.teleport(player, destination, .{ .x = 2.5, .y = 65, .z = 0.5 }, .{ .yaw = 0, .pitch = 0 });
        }
    }

    pub fn tick(self: *Probe) !void {
        const time = self.deps.time;
        const weather = self.deps.weather;
        if (time.game_time != self.previous_age + 1) return error.EnvironmentTickOrder;
        self.previous_age = time.game_time;
        if (self.expiry != 0) {
            switch (self.expiry) {
                2 => if (weather.rain_ticks != 1 or weather.raining) return error.WeatherExpiryEarly,
                3 => if (weather.rain_ticks != 0 or !weather.raining or !weather.thundering or weather.rain_level != 0.01) return error.WeatherExpiryLate,
                4 => {
                    if (weather.rain_ticks < 12000 or weather.rain_ticks > 24000 or weather.thunder_ticks < 3600 or weather.thunder_ticks > 15600) return error.WeatherDuration;
                    std.log.info("event=weather_expiry_verified rain_ticks={d} thunder_ticks={d}", .{ weather.rain_ticks, weather.thunder_ticks });
                },
                else => unreachable,
            }
            self.expiry = if (self.expiry == 4) 0 else self.expiry + 1;
        }
    }

    pub fn checkpoint(self: *Probe, namespace: storage.Namespace) !void {
        const value = self.snapshot();
        try namespace.put("expected", std.mem.asBytes(&value));
    }

    fn snapshot(self: *const Probe) Snapshot {
        const time = self.deps.time;
        const weather = self.deps.weather;
        return .{
            .game_time = time.game_time,
            .day_time = time.day_time,
            .random = weather.random.s,
            .rain = weather.rain_level,
            .thunder = weather.thunder_level,
            .clear_ticks = weather.clear_ticks,
            .rain_ticks = weather.rain_ticks,
            .thunder_ticks = weather.thunder_ticks,
            .raining = @intFromBool(weather.raining),
            .thundering = @intFromBool(weather.thundering),
            .daylight_cycle = @intFromBool(time.daylight_cycle),
            .weather_cycle = @intFromBool(weather.weather_cycle),
        };
    }
};
