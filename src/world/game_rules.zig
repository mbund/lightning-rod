const std = @import("std");
const config = @import("../config.zig").value;

pub const Difficulty = enum(u8) { peaceful, easy, normal, hard };

pub const GameRules = struct {
    pub const id = "minecraft:game_rules";
    do_daylight_cycle: bool = true,
    difficulty: Difficulty = .normal,
    do_mob_spawning: bool = true,
    natural_regeneration: bool = true,
    mob_griefing: bool = true,
    do_random_ticks: bool = true,
    random_tick_speed: u16 = config.random_tick_speed,

    pub fn create(allocator: std.mem.Allocator) !*GameRules {
        const self = try allocator.create(GameRules);
        self.* = .{};
        return self;
    }
};
