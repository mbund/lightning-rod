const std = @import("std");

pub const Difficulty = enum(u8) { peaceful, easy, normal, hard };

pub const GameRules = struct {
    pub const id = "minecraft:game_rules";
    pub const Configuration = struct { random_tick_speed: u16 = 3 };

    do_daylight_cycle: bool = true,
    difficulty: Difficulty = .normal,
    do_mob_spawning: bool = true,
    natural_regeneration: bool = true,
    mob_griefing: bool = true,
    do_random_ticks: bool = true,
    random_tick_speed: u16 = 3,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration) !*GameRules {
        const self = try allocator.create(GameRules);
        self.* = .{ .random_tick_speed = configuration.random_tick_speed };
        return self;
    }
};
