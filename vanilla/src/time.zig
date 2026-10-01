const std = @import("std");
const lightning_rod = @import("lightning_rod");
const storage = lightning_rod.storage;

/// Vanilla's dimensions share the simulation clock. This is not wall-clock time.
pub const Time = struct {
    pub const id = "minecraft:time";
    pub const Configuration = struct { day_time: i64 = 0, daylight_cycle: bool = true };
    pub const Dependencies = struct { storage: storage.Namespace };

    game_time: i64 = 0,
    day_time: i64,
    daylight_cycle: bool,
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*Time {
        const self = try allocator.create(Time);
        self.* = .{ .day_time = configuration.day_time, .daylight_cycle = configuration.daylight_cycle };
        var bytes: [18]u8 = undefined;
        if (try deps.storage.get("clock", &bytes)) |length| {
            if (length != bytes.len or bytes[0] != 1 or bytes[17] > 1) return error.CorruptClock;
            self.game_time = std.mem.readInt(i64, bytes[1..9], .little);
            self.day_time = std.mem.readInt(i64, bytes[9..17], .little);
            self.daylight_cycle = bytes[17] != 0;
        }
        return self;
    }

    pub fn set(self: *Time, day_time: i64) void {
        self.day_time = day_time;
        self.revision +%= 1;
    }

    pub fn setDaylightCycle(self: *Time, enabled: bool) void {
        self.daylight_cycle = enabled;
        self.revision +%= 1;
    }

    pub fn checkpoint(self: *Time, namespace: storage.Namespace) !void {
        var bytes: [18]u8 = undefined;
        bytes[0] = 1;
        std.mem.writeInt(i64, bytes[1..9], self.game_time, .little);
        std.mem.writeInt(i64, bytes[9..17], self.day_time, .little);
        bytes[17] = @intFromBool(self.daylight_cycle);
        try namespace.put("clock", &bytes);
    }
};
