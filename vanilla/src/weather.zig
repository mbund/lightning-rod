const std = @import("std");
const lightning_rod = @import("lightning_rod");
const storage = lightning_rod.storage;

pub const Weather = struct {
    pub const id = "minecraft:weather";
    pub const Configuration = struct { seed: u64 = 0, weather_cycle: bool = true };
    pub const Dependencies = struct { storage: storage.Namespace };
    pub const Kind = enum { clear, rain, thunder };

    clear_ticks: i32 = 0,
    rain_ticks: i32 = 0,
    thunder_ticks: i32 = 0,
    raining: bool = false,
    thundering: bool = false,
    weather_cycle: bool,
    rain_level: f32 = 0,
    thunder_level: f32 = 0,
    random: std.Random.Xoshiro256,
    saved: [56]u8 = @splat(0),

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*Weather {
        const self = try allocator.create(Weather);
        self.* = .{ .weather_cycle = configuration.weather_cycle, .random = .init(configuration.seed) };
        if (try deps.storage.get("weather", &self.saved)) |length| {
            const bytes = &self.saved;
            if (length != bytes.len or bytes[0] != 1 or bytes[13] > 1 or bytes[14] > 1 or bytes[15] > 1) return error.CorruptWeather;
            self.clear_ticks = std.mem.readInt(i32, bytes[1..5], .little);
            self.rain_ticks = std.mem.readInt(i32, bytes[5..9], .little);
            self.thunder_ticks = std.mem.readInt(i32, bytes[9..13], .little);
            self.raining = bytes[13] != 0;
            self.thundering = bytes[14] != 0;
            self.weather_cycle = bytes[15] != 0;
            self.rain_level = @bitCast(std.mem.readInt(u32, bytes[16..20], .little));
            self.thunder_level = @bitCast(std.mem.readInt(u32, bytes[20..24], .little));
            for (&self.random.s, 0..) |*word, index| word.* = std.mem.readInt(u64, bytes[24 + index * 8 ..][0..8], .little);
            if (self.clear_ticks < 0 or self.rain_ticks < 0 or self.thunder_ticks < 0 or
                !std.math.isFinite(self.rain_level) or self.rain_level < 0 or self.rain_level > 1 or
                !std.math.isFinite(self.thunder_level) or self.thunder_level < 0 or self.thunder_level > 1 or
                self.random.s[0] | self.random.s[1] | self.random.s[2] | self.random.s[3] == 0) return error.CorruptWeather;
        }
        return self;
    }

    /// Duration is in simulation ticks. The visual levels still transition gradually.
    pub fn set(self: *Weather, kind: Kind, duration: i32) void {
        std.debug.assert(duration > 0);
        self.clear_ticks = if (kind == .clear) duration else 0;
        self.rain_ticks = if (kind == .clear) 0 else duration;
        self.thunder_ticks = if (kind == .clear) 0 else duration;
        self.raining = kind != .clear;
        self.thundering = kind == .thunder;
    }

    pub fn checkpoint(self: *Weather, namespace: storage.Namespace) !void {
        var bytes: [56]u8 = undefined;
        bytes[0] = 1;
        std.mem.writeInt(i32, bytes[1..5], self.clear_ticks, .little);
        std.mem.writeInt(i32, bytes[5..9], self.rain_ticks, .little);
        std.mem.writeInt(i32, bytes[9..13], self.thunder_ticks, .little);
        bytes[13] = @intFromBool(self.raining);
        bytes[14] = @intFromBool(self.thundering);
        bytes[15] = @intFromBool(self.weather_cycle);
        std.mem.writeInt(u32, bytes[16..20], @bitCast(self.rain_level), .little);
        std.mem.writeInt(u32, bytes[20..24], @bitCast(self.thunder_level), .little);
        for (self.random.s, 0..) |word, index| std.mem.writeInt(u64, bytes[24 + index * 8 ..][0..8], word, .little);
        if (std.mem.eql(u8, &bytes, &self.saved)) return;
        try namespace.put("weather", &bytes);
        self.saved = bytes;
    }
};
