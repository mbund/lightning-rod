const std = @import("std");
const entities = @import("entities");
const packets = @import("minecraft_packets");
const wire = @import("wire_1_21_5");
const packed_wire = @import("wire_1_21_9");

pub const spawn = .{ spawnLegacy, spawnPacked };

fn spawnLegacy(packet: wire.play.toClient.packet_spawn_entity.Writer, registry: packets.Registry, id: i32, body: entities.State) ![]u8 {
    const positioned = try (try (try (try (try (try packet.entityId(id)).objectUUID(body.uuid)).type(try registry.entityId(@intCast(body.kind)))).x(body.position[0])).y(body.position[1])).z(body.position[2]);
    const data = try (try (try (try positioned.pitch(angle(body.pitch))).yaw(angle(body.yaw))).headPitch(0)).objectData(0);
    var velocity = try data.velocity();
    return (try velocity.advance(try packets.nested(.{writeVelocity}).write(try velocity.begin(), body.velocity))).finish();
}

fn writeVelocity(packet: wire.vec3i16.Writer, motion: [3]f64) !wire.vec3i16.Writer.Done {
    return (try (try packet.x(@intFromFloat(std.math.clamp(motion[0], -3.9, 3.9) * 8000))).y(@intFromFloat(std.math.clamp(motion[1], -3.9, 3.9) * 8000))).z(@intFromFloat(std.math.clamp(motion[2], -3.9, 3.9) * 8000));
}

fn spawnPacked(packet: packed_wire.play.toClient.packet_spawn_entity.Writer, registry: packets.Registry, id: i32, body: entities.State) ![]u8 {
    const positioned = try (try (try (try (try (try packet.entityId(id)).objectUUID(body.uuid)).type(try registry.entityId(@intCast(body.kind)))).x(body.position[0])).y(body.position[1])).z(body.position[2]);
    const rotated = try (try (try (try positioned.velocity(.{ .x = body.velocity[0], .y = body.velocity[1], .z = body.velocity[2] })).pitch(angle(body.pitch))).yaw(angle(body.yaw))).headPitch(0);
    return (try rotated.objectData(0)).finish();
}

fn angle(degrees: f32) i8 {
    return @bitCast(@as(u8, @intFromFloat(@mod(degrees, 360) * (256.0 / 360.0))));
}
