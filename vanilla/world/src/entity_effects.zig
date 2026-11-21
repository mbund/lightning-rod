//! Packets about one entity for the players who see it, and for the entity itself when it is a
//! player: its motion after a hit, a damage event, the hurt tilt, an animation, an entity event.
//! Whoever knows the audience passes it; this sends.

const std = @import("std");
const lightning_rod = @import("lightning_rod");
const packets = @import("minecraft_packets");
const sessions = @import("sessions");
const wire = @import("wire_1_21_5");
const packed_wire = @import("wire_1_21_9");
const Players = @import("players").players.Players;

const bit_sets = lightning_rod.system.bit_sets;
const assert = std.debug.assert;

pub const Packet = union(enum) {
    /// ClientboundSetEntityMotionPacket.
    velocity: struct { id: i32, velocity: [3]f64 },
    /// ClientboundDamageEventPacket. Causes are network ids plus one, zero for none.
    damage: Damage,
    /// ClientboundHurtAnimationPacket: which way the entity tilts.
    hurt_animation: struct { id: i32, yaw: f32 },
    /// ClientboundAnimatePacket.
    animation: struct { id: i32, animation: u8 },
    /// ClientboundEntityEventPacket.
    status: struct { id: i32, status: u8 },
};

pub const Damage = struct { id: i32, type_id: i32, cause: i32, direct: i32, source: ?[3]f64 = null };

pub const EntityEffects = struct {
    players: *Players,
    targets: []sessions.Service.Target,
    deliveries: []sessions.Service.Delivery,

    pub fn init(allocator: std.mem.Allocator, players: *Players) !EntityEffects {
        return .{
            .players = players,
            .targets = try allocator.alloc(sessions.Service.Target, players.records.len),
            .deliveries = try allocator.alloc(sessions.Service.Delivery, players.records.len),
        };
    }

    /// Sends to each ready player in `viewers`, and to `also` as well.
    pub fn send(self: *EntityEffects, viewers: bit_sets.Set, also: ?usize, packet: Packet) void {
        var count: usize = 0;
        var iterator = viewers.iterator();
        while (iterator.next()) |index| {
            if (index == also) continue;
            count += self.target(index, count);
        }
        if (also) |index| count += self.target(index, count);
        if (count == 0) return;
        const targets = self.targets[0..count];
        const deliveries = self.deliveries[0..count];
        const encoder = self.players.deps.packets;
        (switch (packet) {
            .velocity => |value| encoder.fanout(.{ writeVelocityLegacy, writeVelocityPacked }, targets, .{ value.id, value.velocity }, 64, deliveries),
            .damage => |value| encoder.fanout(writeDamage, targets, .{value}, 64, deliveries),
            .hurt_animation => |value| encoder.fanout(writeHurtAnimation, targets, .{ value.id, value.yaw }, 32, deliveries),
            .animation => |value| encoder.fanout(writeAnimation, targets, .{ value.id, value.animation }, 32, deliveries),
            .status => |value| encoder.fanout(writeStatus, targets, .{ value.id, value.status }, 32, deliveries),
        }) catch |err| std.debug.panic("invalid server packet: {s}", .{@errorName(err)});
    }

    /// Sends to the player in a slot alone.
    pub fn toPlayer(self: *EntityEffects, slot: usize, packet: Packet) void {
        self.send(.{ .words = &.{}, .capacity = 0 }, slot, packet);
    }

    /// Adds the player in a slot to the targets if it can be sent to. Returns how many it added.
    fn target(self: *EntityEffects, index: usize, at: usize) usize {
        const player = &self.players.records[index];
        const handle = player.handle orelse return 0;
        if (player.stage != .ready) return 0;
        assert(at < self.targets.len);
        self.targets[at] = .{ .handle = handle, .protocol = player.protocol };
        return 1;
    }
};

/// Players' network ids are their slots plus one.
pub fn playerId(slot: usize) i32 {
    return @intCast(slot + 1);
}

fn writeVelocityLegacy(packet: wire.play.toClient.packet_entity_velocity.Writer, id: i32, velocity: [3]f64) ![]u8 {
    var value = try (try packet.entityId(id)).velocity();
    return (try value.advance(try packets.nested(.{writeShortVelocity}).write(try value.begin(), velocity))).finish();
}

fn writeShortVelocity(packet: wire.vec3i16.Writer, motion: [3]f64) !wire.vec3i16.Writer.Done {
    return (try (try packet.x(shortVelocity(motion[0]))).y(shortVelocity(motion[1]))).z(shortVelocity(motion[2]));
}

/// ClientboundSetEntityMotionPacket's shorts before 1.21.9: eighths of a thousandth of a block.
fn shortVelocity(value: f64) i16 {
    return @intFromFloat(std.math.clamp(value, -3.9, 3.9) * 8000);
}

fn writeVelocityPacked(packet: packed_wire.play.toClient.packet_entity_velocity.Writer, id: i32, velocity: [3]f64) ![]u8 {
    return (try (try packet.entityId(id)).velocity(.{ .x = velocity[0], .y = velocity[1], .z = velocity[2] })).finish();
}

fn writeDamage(packet: wire.play.toClient.packet_damage_event.Writer, value: Damage) ![]u8 {
    const typed = try (try (try (try packet.entityId(value.id)).sourceTypeId(value.type_id)).sourceCauseId(value.cause)).sourceDirectId(value.direct);
    var position = try typed.sourcePosition();
    const source = value.source orelse return (try position.advance(try (try position.begin()).none())).finish();
    var present = try (try position.begin()).some();
    const located = try packets.nested(.{writeVec3}).write(try present.begin(), source);
    return (try position.advance(try present.advance(located))).finish();
}

fn writeVec3(packet: wire.vec3f64.Writer, at: [3]f64) !wire.vec3f64.Writer.Done {
    return (try (try packet.x(at[0])).y(at[1])).z(at[2]);
}

fn writeHurtAnimation(packet: wire.play.toClient.packet_hurt_animation.Writer, id: i32, yaw: f32) ![]u8 {
    return (try (try packet.entityId(id)).yaw(yaw)).finish();
}

fn writeAnimation(packet: wire.play.toClient.packet_animation.Writer, id: i32, animation: u8) ![]u8 {
    return (try (try packet.entityId(id)).animation(animation)).finish();
}

fn writeStatus(packet: wire.play.toClient.packet_entity_status.Writer, id: i32, status: u8) ![]u8 {
    return (try (try packet.entityId(id)).entityStatus(@bitCast(status))).finish();
}
