const std = @import("std");

pub const Time = struct {
    pub const id = "minecraft:time";
    pub const Configuration = struct {};
    day_time: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, _: Configuration) !*Time {
        const self = try allocator.create(Time);
        self.* = .{};
        return self;
    }
};
