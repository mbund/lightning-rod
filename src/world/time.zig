const std = @import("std");

pub const Time = struct {
    pub const id = "minecraft:time";
    day_time: u64 = 0,

    pub fn create(allocator: std.mem.Allocator) !*Time {
        const self = try allocator.create(Time);
        self.* = .{};
        return self;
    }
};
