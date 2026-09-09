const std = @import("std");
const geometry = @import("world/geometry.zig");
const identity = @import("world/identity.zig");

pub const format: u8 = 1;
pub const key_bytes = 28;

pub const Key = struct {
    world: identity.Key,
    chunk: geometry.ChunkPos,
};

pub fn encode(destination: *[key_bytes]u8, value: Key) []const u8 {
    destination[0] = format;
    destination[1] = @sizeOf(u128);
    std.mem.writeInt(u128, destination[2..18], value.world.value, .little);
    destination[18] = @sizeOf(i32);
    std.mem.writeInt(i32, destination[19..23], value.chunk.x, .little);
    destination[23] = @sizeOf(i32);
    std.mem.writeInt(i32, destination[24..28], value.chunk.z, .little);
    return destination;
}

pub fn decode(bytes: []const u8) !Key {
    if (bytes.len != key_bytes or bytes[0] != format) return error.InvalidKey;
    if (bytes[1] != @sizeOf(u128) or bytes[18] != @sizeOf(i32) or bytes[23] != @sizeOf(i32))
        return error.InvalidKey;
    return .{
        .world = .{ .value = std.mem.readInt(u128, bytes[2..18], .little) },
        .chunk = .{
            .x = std.mem.readInt(i32, bytes[19..23], .little),
            .z = std.mem.readInt(i32, bytes[24..28], .little),
        },
    };
}

test "chunk keys round trip without separator ambiguity" {
    const input = Key{ .world = .{ .value = 0x12003400560078009a00bc00de00f0 }, .chunk = .{ .x = -1, .z = 42 } };
    var bytes: [key_bytes]u8 = undefined;
    const output = try decode(encode(&bytes, input));
    try std.testing.expectEqual(input.world.value, output.world.value);
    try std.testing.expectEqual(input.chunk.x, output.chunk.x);
    try std.testing.expectEqual(input.chunk.z, output.chunk.z);
}

test "chunk keys distinguish coordinates" {
    var left: [key_bytes]u8 = undefined;
    var right: [key_bytes]u8 = undefined;
    const world = identity.Key{ .value = 1 };
    try std.testing.expect(!std.mem.eql(u8, encode(&left, .{ .world = world, .chunk = .{ .x = 1, .z = 2 } }), encode(&right, .{ .world = world, .chunk = .{ .x = 2, .z = 1 } })));
}
