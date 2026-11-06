const std = @import("std");

pub const Rendering = struct {
    occluder: bool,
    block_entity: bool,
    beacon: bool,
    gateway: bool,
    debug_bounds: bool,
};

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
    collision_top_full: bool = false,
    air: bool = false,
    liquid_block: bool = false,

    pub fn height(self: State) f32 {
        return @as(f32, @floatFromInt(self.amount)) / 9;
    }
};

pub const Experience = struct {
    minimum: u8 = 0,
    bound: u8 = 0,
    rolls: u8 = 0,
    enchantments: bool = false,

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
    const shape_count = std.mem.readInt(u32, bytes[12..16], .big);
    const box_count = std.mem.readInt(u32, bytes[16..20], .big);
    const shapes_offset = 20 + expected_states * 26;
    const boxes_offset = shapes_offset + shape_count * 6;
    const experience_offset = boxes_offset + box_count * 48;
    const rendering_offset = experience_offset + 4 + expected_blocks * 4;
    std.debug.assert(bytes.len == rendering_offset + expected_states);
    std.debug.assert(std.mem.eql(u8, bytes[0..8], "LRPHYS05"));
    std.debug.assert(std.mem.readInt(u32, bytes[8..12], .big) == expected_states);
    std.debug.assert(std.mem.readInt(u32, bytes[experience_offset..][0..4], .big) == expected_blocks);
    return struct {
        pub const Boxes = struct {
            offset: u32,
            count: u16,
            translation: [3]f64,
            pub fn get(self: Boxes, index: usize) [6]f64 {
                std.debug.assert(index < self.count);
                const entry = bytes[boxes_offset + (@as(usize, self.offset) + index) * 48 ..][0..48];
                var result: [6]f64 = undefined;
                for (&result, 0..) |*coordinate, axis| {
                    const value: f64 = @bitCast(std.mem.readInt(u64, entry[axis * 8 ..][0..8], .little));
                    coordinate.* = value + self.translation[axis % 3];
                }
                return result;
            }
        };
        pub fn spawnCollision(state: u16, x: i32, y: i32, z: i32) Boxes {
            std.debug.assert(state < expected_states);
            const context: usize = if (y < -1) 0 else if (y == -1) 1 else 2;
            const shape = std.mem.readInt(u16, bytes[20 + @as(usize, state) * 26 + 12 + context * 2 ..][0..2], .little);
            std.debug.assert(shape < shape_count);
            const entry = bytes[shapes_offset + @as(usize, shape) * 6 ..][0..6];
            const offset_entry = bytes[20 + @as(usize, state) * 26 + 18 ..][0..8];
            const horizontal: f32 = @bitCast(std.mem.readInt(u32, offset_entry[0..4], .little));
            const vertical: f32 = @bitCast(std.mem.readInt(u32, offset_entry[4..8], .little));
            const result: Boxes = .{ .offset = std.mem.readInt(u32, entry[0..4], .little), .count = std.mem.readInt(u16, entry[4..6], .little), .translation = offset(x, z, horizontal, vertical) };
            std.debug.assert(@as(usize, result.offset) + result.count <= box_count);
            return result;
        }
        pub fn experience(block: u16) Experience {
            std.debug.assert(block < expected_blocks);
            const entry = bytes[experience_offset + 4 + @as(usize, block) * 4 ..][0..4];
            return .{ .minimum = entry[0], .bound = entry[1], .rolls = entry[2], .enchantments = entry[3] & 1 != 0 };
        }

        pub fn rendering(state: u16) Rendering {
            std.debug.assert(state < expected_states);
            const flags = bytes[rendering_offset + state];
            return .{ .occluder = flags & 1 != 0, .block_entity = flags & 2 != 0, .beacon = flags & 4 != 0, .gateway = flags & 8 != 0, .debug_bounds = flags & 16 != 0 };
        }

        pub fn get(state: u16) State {
            std.debug.assert(state < expected_states);
            const entry = bytes[20 + @as(usize, state) * 26 ..][0..12];
            return .{ .friction = @bitCast(std.mem.readInt(u32, entry[0..4], .little)), .speed = @bitCast(std.mem.readInt(u32, entry[4..8], .little)), .fluid = @fromBackingInt(@intCast(entry[8])), .amount = entry[9], .blocks_motion = entry[10] & 1 != 0, .falling = entry[10] & 2 != 0, .ice = entry[10] & 4 != 0, .water_block = entry[10] & 8 != 0, .sturdy = entry[11], .collision_top_full = entry[10] & 16 != 0, .air = entry[10] & 32 != 0, .liquid_block = entry[10] & 64 != 0 };
        }
    };
}

pub fn offset(x: i32, z: i32, horizontal: f32, vertical: f32) [3]f64 {
    if (horizontal == 0 and vertical == 0) return @splat(0);
    var seed: i64 = @as(i64, x *% 3129871) ^ (@as(i64, z) *% 116129781);
    seed = (seed *% seed *% 42317861 +% seed *% 11) >> 16;
    const nx = @as(f64, @as(f32, @floatFromInt(seed & 15)) / 15);
    const ny = @as(f64, @as(f32, @floatFromInt((seed >> 4) & 15)) / 15);
    const nz = @as(f64, @as(f32, @floatFromInt((seed >> 8) & 15)) / 15);
    return .{ std.math.clamp((nx - 0.5) * 0.5, -@as(f64, horizontal), horizontal), (ny - 1) * vertical, std.math.clamp((nz - 0.5) * 0.5, -@as(f64, horizontal), horizontal) };
}
