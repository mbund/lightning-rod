const std = @import("std");
const world_identity = @import("identity.zig");

pub const Vec3 = extern struct {
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,
};

pub const Rotation = struct {
    yaw: f32 = 0,
    pitch: f32 = 0,
};

pub const BlockPos = struct {
    x: i32,
    y: i16,
    z: i32,
};

pub const BlockMutation = struct {
    world: world_identity.Handle,
    pos: BlockPos,
    previous_state: i32,
    block_state: i32,
};

pub const ChunkPos = struct {
    x: i32,
    z: i32,
};

pub const WorldChunk = struct {
    world: world_identity.Handle,
    pos: ChunkPos,

    pub inline fn eql(a: WorldChunk, b: WorldChunk) bool {
        return a.world.eql(b.world) and sameChunk(a.pos, b.pos);
    }
};

pub inline fn chunkCoord(block_coord: i32) i32 {
    return @divFloor(block_coord, 16);
}

pub inline fn chunkForBlock(pos: BlockPos) ChunkPos {
    return .{ .x = chunkCoord(pos.x), .z = chunkCoord(pos.z) };
}

pub inline fn sameChunk(a: ChunkPos, b: ChunkPos) bool {
    return a.x == b.x and a.z == b.z;
}

pub inline fn sameBlock(a: BlockPos, b: BlockPos) bool {
    return a.x == b.x and a.y == b.y and a.z == b.z;
}

pub fn blockCoord(value: f64) i32 {
    if (!std.math.isFinite(value)) return 0;
    const floored = @floor(value);
    if (floored <= std.math.minInt(i32)) return std.math.minInt(i32);
    if (floored >= std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intFromFloat(floored);
}
