//! The packets that show projectiles: their spawn with the owner in its data, where they are,
//! their arrow flags, their pickup, and their removal.

const std = @import("std");
const packets = @import("minecraft_packets");
const wire = @import("wire_1_21_5");
const packed_wire = @import("wire_1_21_9");

pub const Spawn = struct {
    id: i32,
    uuid: u128,
    kind: u32,
    position: [3]f64,
    velocity: [3]f64,
    yaw: i8,
    pitch: i8,
    /// Projectile.getAddEntityPacket: the owner's network id, or zero.
    owner: i32,
};

/// AbstractArrow's entity data: its flags, how many it pierces, whether it is stuck, and a
/// trident's loyalty and glint.
pub const Data = struct {
    critical: bool,
    pierce: u8,
    in_ground: bool,
    trident: ?struct { loyalty: u8, foil: bool } = null,
};

pub fn spawnLegacy(packet: wire.play.toClient.packet_spawn_entity.Writer, registry: packets.Registry, spawn: Spawn) ![]u8 {
    const positioned = try (try (try (try (try (try packet.entityId(spawn.id)).objectUUID(spawn.uuid)).type(try registry.entityId(@intCast(spawn.kind)))).x(spawn.position[0])).y(spawn.position[1])).z(spawn.position[2]);
    const data = try (try (try (try positioned.pitch(spawn.pitch)).yaw(spawn.yaw)).headPitch(0)).objectData(spawn.owner);
    var velocity = try data.velocity();
    return (try velocity.advance(try packets.nested(.{writeShortVelocity}).write(try velocity.begin(), spawn.velocity))).finish();
}

pub fn spawnPacked(packet: packed_wire.play.toClient.packet_spawn_entity.Writer, registry: packets.Registry, spawn: Spawn) ![]u8 {
    const positioned = try (try (try (try (try (try packet.entityId(spawn.id)).objectUUID(spawn.uuid)).type(try registry.entityId(@intCast(spawn.kind)))).x(spawn.position[0])).y(spawn.position[1])).z(spawn.position[2]);
    const rotated = try (try (try (try positioned.velocity(.{ .x = spawn.velocity[0], .y = spawn.velocity[1], .z = spawn.velocity[2] })).pitch(spawn.pitch)).yaw(spawn.yaw)).headPitch(0);
    return (try rotated.objectData(spawn.owner)).finish();
}

fn writeShortVelocity(packet: wire.vec3i16.Writer, motion: [3]f64) !wire.vec3i16.Writer.Done {
    return (try (try packet.x(shortVelocity(motion[0]))).y(shortVelocity(motion[1]))).z(shortVelocity(motion[2]));
}

fn shortVelocity(value: f64) i16 {
    return @intFromFloat(std.math.clamp(value, -3.9, 3.9) * 8000);
}

/// ClientboundEntityPositionSyncPacket: where it is and how it moves.
pub fn writeSync(packet: wire.play.toClient.packet_sync_entity_position.Writer, id: i32, position: [3]f64, velocity: [3]f64, yaw: f32, pitch: f32, on_ground: bool) ![]u8 {
    const positioned = try (try (try (try packet.entityId(id)).x(position[0])).y(position[1])).z(position[2]);
    const moving = try (try (try positioned.dx(velocity[0])).dy(velocity[1])).dz(velocity[2]);
    return (try (try (try moving.yaw(yaw)).pitch(pitch)).onGround(on_ground)).finish();
}

/// AbstractArrow's entity data: 8 its flags, 9 pierce, 10 in ground; a trident's 11 loyalty
/// and 12 glint.
pub fn writeData(packet: wire.play.toClient.packet_entity_metadata.Writer, id: i32, data: Data) ![]u8 {
    var metadata = try (try packet.entityId(id)).metadata();
    return (try metadata.advance(try packets.nested(.{entries}).write(try metadata.begin(), data))).finish();
}

fn entries(packet: wire.entityMetadata.Writer, data: Data) !wire.entityMetadata.Writer.Done {
    var list = try packet.value(if (data.trident != null) 5 else 3);
    try list.advance(try packets.nested(.{byteEntry}).write((try list.next()).?, .{ 8, @as(i8, @intFromBool(data.critical)) }));
    try list.advance(try packets.nested(.{byteEntry}).write((try list.next()).?, .{ 9, @as(i8, @intCast(data.pierce)) }));
    try list.advance(try packets.nested(.{booleanEntry}).write((try list.next()).?, .{ 10, data.in_ground }));
    if (data.trident) |trident| {
        try list.advance(try packets.nested(.{byteEntry}).write((try list.next()).?, .{ 11, @as(i8, @intCast(trident.loyalty)) }));
        try list.advance(try packets.nested(.{booleanEntry}).write((try list.next()).?, .{ 12, trident.foil }));
    }
    return list.finish();
}

fn byteEntry(packet: wire.entityMetadataEntry.cases.value.byte.Writer, entry: struct { u8, i8 }) !wire.entityMetadataEntry.cases.value.byte.Writer.Done {
    return (try (try packet.key(entry[0])).type()).value(entry[1]);
}

fn booleanEntry(packet: wire.entityMetadataEntry.cases.value.boolean.Writer, entry: struct { u8, bool }) !wire.entityMetadataEntry.cases.value.boolean.Writer.Done {
    return (try (try packet.key(entry[0])).type()).value(entry[1]);
}

/// ClientboundTakeItemEntityPacket: the pickup animation.
pub fn writeCollect(packet: wire.play.toClient.packet_collect.Writer, item: i32, player: i32, count: i32) ![]u8 {
    return (try (try (try packet.collectedEntityId(item)).collectorEntityId(player)).pickupItemCount(count)).finish();
}

pub fn writeRemove(packet: wire.play.toClient.packet_entity_destroy.Writer, id: i32) ![]u8 {
    const ids = try packet.entityIds(1);
    const entry = try ids.element(id);
    return (try entry.finish()).finish();
}
