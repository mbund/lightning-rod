const std = @import("std");

pub const Fluid = enum(u8) { none, water, lava };
pub const State = struct {
    friction: f32,
    speed: f32,
    water_block: bool,
    fluid: Fluid,
    amount: u8,
    blocks_motion: bool,
    falling: bool,
    ice: bool,
    sturdy: u8,

    pub fn height(self: State) f32 {
        return @as(f32, @floatFromInt(self.amount)) / 9;
    }
};

pub const Experience = struct {
    minimum: u8 = 0,
    bound: u8 = 0,
    rolls: u8 = 0,
    silk_touch: bool = false,
    silk_only: bool = false,
    silk_drop: i32 = -1,

    pub fn maximum(self: Experience) i32 {
        std.debug.assert(self.rolls == 0 or self.bound > 0);
        return @as(i32, self.minimum) + @as(i32, self.rolls) * (@as(i32, self.bound) - 1);
    }

    pub fn sample(self: Experience, random: std.Random) i32 {
        std.debug.assert(self.rolls == 0 or self.bound > 0);
        var value: i32 = self.minimum;
        for (0..self.rolls) |_| value += @intCast(random.uintLessThan(u32, self.bound));
        std.debug.assert(value >= self.minimum and value <= self.maximum());
        return value;
    }
};

pub fn Data(comptime expected_states: usize, comptime expected_blocks: usize, comptime bytes: []const u8) type {
    std.debug.assert(bytes.len == 16 + expected_states * 12 + expected_blocks * 8);
    std.debug.assert(std.mem.eql(u8, bytes[0..8], "LRPHYS02"));
    std.debug.assert(std.mem.readInt(u32, bytes[8..12], .big) == expected_states);
    std.debug.assert(std.mem.readInt(u32, bytes[12 + expected_states * 12 ..][0..4], .big) == expected_blocks);
    return struct {
        pub fn experience(block: u16) Experience {
            std.debug.assert(block < expected_blocks);
            const entry = bytes[16 + expected_states * 12 + @as(usize, block) * 8 ..][0..8];
            return .{ .minimum = entry[0], .bound = entry[1], .rolls = entry[2], .silk_touch = entry[3] & 1 != 0, .silk_only = entry[3] & 2 != 0, .silk_drop = std.mem.readInt(i32, entry[4..8], .little) };
        }

        pub fn get(state: u16) State {
            std.debug.assert(state < expected_states);
            const entry = bytes[12 + @as(usize, state) * 12 ..][0..12];
            return .{ .friction = @bitCast(std.mem.readInt(u32, entry[0..4], .little)), .speed = @bitCast(std.mem.readInt(u32, entry[4..8], .little)), .fluid = @enumFromInt(entry[8]), .amount = entry[9], .blocks_motion = entry[10] & 1 != 0, .falling = entry[10] & 2 != 0, .ice = entry[10] & 4 != 0, .water_block = entry[10] & 8 != 0, .sturdy = entry[11] };
        }
    };
}
