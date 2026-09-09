const std = @import("std");
const geometry = @import("world/geometry.zig");
const identity = @import("world/identity.zig");

pub const format: u8 = 1;
pub const encoded_bytes = 28;

pub const Key = struct {
    world: identity.Key,
    chunk: geometry.ChunkPos,
};

pub fn encode(destination: *[encoded_bytes]u8, value: Key) []const u8 {
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
    if (bytes.len != encoded_bytes or bytes[0] != format) return error.InvalidKey;
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
