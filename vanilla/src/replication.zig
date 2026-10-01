const std = @import("std");

const assert = std.debug.assert;
const Players = @import("players.zig").Players;
const game_data = @import("game_data");
const minecraft = @import("minecraft_model");
const packets = @import("minecraft_packets");
const wire_1_21_5 = @import("wire_1_21_5");
const wire_1_21_9 = @import("wire_1_21_9");

pub const Replication = struct {
    pub const id = "minecraft:player_replication";

    pub const Configuration = struct {};

    pub const Dependencies = struct { players: *Players };

    const Spawn = struct {
        entity_id: i32,
        uuid: u128,
        position: minecraft.Position,
        pitch: i8,
        yaw: i8,
        head_yaw: i8,
    };

    const Seen = struct {
        uuid: u128 = 0,
        generation: u32 = 0,
        stage: enum { absent, listed, spawned } = .absent,
        position: [3]i64 = @splat(0),
        yaw: i8 = 0,
        pitch: i8 = 0,
        head: ?i8 = null,
        flags: ?minecraft.EntityFlags = null,
        on_ground: bool = false,
        gamemode: ?minecraft.GameMode = null,
    };

    const Observer = struct {
        generation: u32 = 0,
        world: u32 = 0,
    };

    deps: Dependencies,
    seen: []Seen,
    observers: []Observer,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Replication {
        const self = try allocator.create(Replication);
        const seen = try allocator.alloc(Seen, deps.players.records.len * deps.players.records.len);
        @memset(seen, .{});
        const observers = try allocator.alloc(Observer, deps.players.records.len);
        @memset(observers, .{});
        self.* = .{ .deps = deps, .seen = seen, .observers = observers };
        return self;
    }

    pub fn tick(self: *Replication) void {
        const players = self.deps.players;

        for (players.records, 0..) |observer, observer_index| {
            const row = self.seen[observer_index * players.records.len ..][0..players.records.len];
            const recipient = observer.handle orelse {
                @memset(row, .{});
                continue;
            };

            if (self.observers[observer_index].generation != recipient.generation) {
                @memset(row, .{});
                self.observers[observer_index] = .{ .generation = recipient.generation, .world = observer.world };
            }

            if (observer.stage != .ready) continue;

            if (self.observers[observer_index].world != observer.world) {
                for (row) |*seen| if (seen.stage == .spawned) {
                    seen.stage = .listed;
                    seen.flags = null;
                    seen.head = null;
                };

                self.observers[observer_index].world = observer.world;
            }

            for (players.records, row, 0..) |subject, *seen, index| {
                if (index == observer_index) {
                    if (seen.gamemode != subject.gamemode and players.sendPacket(writeMode, observer.protocol, &.{recipient}, .{ subject.uuid, subject.gamemode }))
                        seen.gamemode = subject.gamemode;
                    continue;
                }
                const entity_id: i32 = @intCast(index + 1);
                const generation = if (subject.handle) |handle| handle.generation else 0;
                if (seen.generation != generation) {
                    if (seen.stage == .spawned) {
                        if (!players.sendPacket(writeRemove, observer.protocol, &.{recipient}, .{entity_id})) continue;
                        seen.stage = .listed;
                    }

                    if (seen.stage == .listed) {
                        if (!players.sendPacket(writePlayerRemove, observer.protocol, &.{recipient}, .{seen.uuid})) continue;
                    }

                    seen.* = .{ .generation = generation, .uuid = subject.uuid };
                }

                if (subject.handle == null) continue;
                assert(generation != 0);
                const position: [3]i64 = .{ fixed(subject.position.x), fixed(subject.position.y), fixed(subject.position.z) };
                const yaw = angle(subject.rotation.yaw);
                const pitch = angle(subject.rotation.pitch);
                if (seen.stage == .absent) {
                    if (!players.sendPlayerAdd(observer.protocol, &.{recipient}, subject.uuid, subject.name[0..subject.name_len], subject.gamemode))
                        continue;
                    seen.stage = .listed;
                    seen.gamemode = subject.gamemode;
                }

                if (seen.gamemode != subject.gamemode) {
                    if (!players.sendPacket(writeMode, observer.protocol, &.{recipient}, .{ subject.uuid, subject.gamemode })) continue;
                    seen.gamemode = subject.gamemode;
                }

                if (subject.world != observer.world) {
                    if (seen.stage == .spawned) {
                        if (!players.sendPacket(writeRemove, observer.protocol, &.{recipient}, .{entity_id})) continue;
                        seen.stage = .listed;
                        seen.flags = null;
                        seen.head = null;
                    }

                    continue;
                }

                if (subject.stage != .ready) continue;
                if (seen.stage == .listed) {
                    if (!players.sendPacket(.{ writeSpawnLegacy, writeSpawnPacked }, observer.protocol, &.{recipient}, .{Spawn{
                        .entity_id = entity_id,
                        .uuid = subject.uuid,
                        .position = subject.position,
                        .pitch = pitch,
                        .yaw = yaw,
                        .head_yaw = yaw,
                    }}))
                        continue;
                    seen.stage = .spawned;
                    seen.position = position;
                    seen.yaw = yaw;
                    seen.pitch = pitch;
                }

                assert(seen.stage == .spawned);
                if (!std.meta.eql(position, seen.position) or yaw != seen.yaw or pitch != seen.pitch or subject.on_ground != seen.on_ground) {
                    const dx = position[0] - seen.position[0];
                    const dy = position[1] - seen.position[1];
                    const dz = position[2] - seen.position[2];

                    if (dx < -32768 or dx > 32767 or dy < -32768 or dy > 32767 or dz < -32768 or dz > 32767) {
                        if (!players.sendPacket(writePosition, observer.protocol, &.{recipient}, .{
                            entity_id, subject.position, minecraft.Position{ .x = 0, .y = 0, .z = 0 }, subject.rotation, subject.on_ground,
                        }))
                            continue;
                    } else {
                        if (!players.sendPacket(writeMove, observer.protocol, &.{recipient}, .{
                            entity_id, @as(i16, @intCast(dx)), @as(i16, @intCast(dy)), @as(i16, @intCast(dz)),
                            yaw,       pitch,                  subject.on_ground,
                        }))
                            continue;
                    }

                    seen.position = position;
                    seen.yaw = yaw;
                    seen.pitch = pitch;
                    seen.on_ground = subject.on_ground;
                }

                if (seen.head == null or seen.head.? != yaw) {
                    if (!players.sendPacket(writeHeadRotation, observer.protocol, &.{recipient}, .{ entity_id, yaw })) continue;
                    seen.head = yaw;
                }

                if (seen.flags == null or !std.meta.eql(seen.flags.?, subject.flags)) {
                    if (!players.sendPacket(writeFlags, observer.protocol, &.{recipient}, .{ entity_id, subject.flags })) continue;
                    seen.flags = subject.flags;
                }
            }
        }
    }

    fn writeSpawnLegacy(packet: wire_1_21_5.play.toClient.packet_spawn_entity.Writer, registry: packets.Registry, value: Spawn) ![]u8 {
        const entity = try packet.entityId(value.entity_id);
        const uuid = try entity.objectUUID(value.uuid);
        const kind = try uuid.type(try registry.entityId(game_data.entities.player));
        const x = try kind.x(value.position.x);
        const y = try x.y(value.position.y);
        const z = try y.z(value.position.z);

        const pitch = try z.pitch(value.pitch);
        const yaw = try pitch.yaw(value.yaw);
        const head = try yaw.headPitch(value.head_yaw);
        const data = try head.objectData(0);
        var velocity = try data.velocity();
        return (try velocity.advance(try packets.nested(.{writeVelocity}).write(try velocity.begin(), {}))).finish();
    }

    fn writeVelocity(packet: wire_1_21_5.vec3i16.Writer, _: void) !wire_1_21_5.vec3i16.Writer.Done {
        return (try (try packet.x(0)).y(0)).z(0);
    }

    fn writeSpawnPacked(packet: wire_1_21_9.play.toClient.packet_spawn_entity.Writer, registry: packets.Registry, value: Spawn) ![]u8 {
        const entity = try packet.entityId(value.entity_id);
        const uuid = try entity.objectUUID(value.uuid);
        const kind = try uuid.type(try registry.entityId(game_data.entities.player));
        const x = try kind.x(value.position.x);
        const y = try x.y(value.position.y);
        const z = try y.z(value.position.z);
        const velocity = try z.velocity(.{
            .x = 0,
            .y = 0,
            .z = 0,
        });
        const pitch = try velocity.pitch(value.pitch);
        const yaw = try pitch.yaw(value.yaw);
        const head = try yaw.headPitch(value.head_yaw);
        return (try head.objectData(0)).finish();
    }

    fn writeRemove(packet: wire_1_21_5.play.toClient.packet_entity_destroy.Writer, entity_id: i32) ![]u8 {
        const ids = try packet.entityIds(1);
        const entry = try ids.element(entity_id);
        return (try entry.finish()).finish();
    }

    fn writePosition(packet: wire_1_21_5.play.toClient.packet_sync_entity_position.Writer, entity_id: i32, at: minecraft.Position, motion: minecraft.Position, rotation: minecraft.Rotation, on_ground: bool) ![]u8 {
        const entity = try packet.entityId(entity_id);
        const x = try entity.x(at.x);
        const y = try x.y(at.y);
        const z = try y.z(at.z);
        const vx = try z.dx(motion.x);
        const vy = try vx.dy(motion.y);
        const vz = try vy.dz(motion.z);
        const yaw = try vz.yaw(rotation.yaw);
        return (try (try yaw.pitch(rotation.pitch)).onGround(on_ground)).finish();
    }

    fn writeMode(packet: wire_1_21_5.play.toClient.packet_player_info.Writer, uuid: u128, mode: minecraft.GameMode) ![]u8 {
        const action = try packet.action(.{ .update_game_mode = true });
        var entries = try action.data(1);
        const entry = (try entries.next()).?;
        var player = try (try entry.uuid(uuid)).player();
        const absent_player = try player.advance(try (try player.begin()).case_default());
        var chat = try absent_player.chatSession();
        const absent_chat = try chat.advance(try (try chat.begin()).case_default());
        var gamemode = try absent_chat.gamemode();
        const selected = try gamemode.advance(try (try gamemode.begin()).case_true(@intFromEnum(mode)));
        var listed = try selected.listed();
        const absent_listed = try listed.advance(try (try listed.begin()).case_default());
        var latency = try absent_listed.latency();
        const absent_latency = try latency.advance(try (try latency.begin()).case_default());
        var display = try absent_latency.displayName();
        const absent_display = try display.advance(try (try display.begin()).case_default());
        var priority = try absent_display.listPriority();
        const absent_priority = try priority.advance(try (try priority.begin()).case_default());
        var hat = try absent_priority.showHat();
        try entries.advance(try hat.advance(try (try hat.begin()).case_default()));
        return (try entries.finish()).finish();
    }

    fn writePlayerRemove(packet: wire_1_21_5.play.toClient.packet_player_remove.Writer, uuid: u128) ![]u8 {
        const players = try packet.players(1);
        const entry = try players.element(uuid);
        return (try entry.finish()).finish();
    }

    fn writeMove(packet: wire_1_21_5.play.toClient.packet_entity_move_look.Writer, entity_id: i32, dx: i16, dy: i16, dz: i16, yaw: i8, pitch: i8, on_ground: bool) ![]u8 {
        const entity = try packet.entityId(entity_id);
        const x = try entity.dX(dx);
        const y = try x.dY(dy);
        const z = try y.dZ(dz);
        const facing = try z.yaw(yaw);
        return (try (try facing.pitch(pitch)).onGround(on_ground)).finish();
    }

    fn writeHeadRotation(packet: wire_1_21_5.play.toClient.packet_entity_head_rotation.Writer, entity_id: i32, yaw: i8) ![]u8 {
        return (try (try packet.entityId(entity_id)).headYaw(yaw)).finish();
    }

    fn writeFlags(packet: wire_1_21_5.play.toClient.packet_entity_metadata.Writer, entity_id: i32, flags: minecraft.EntityFlags) ![]u8 {
        const entity = try packet.entityId(entity_id);
        var metadata = try entity.metadata();
        return (try metadata.advance(try packets.nested(.{writeFlagMetadata}).write(try metadata.begin(), flags))).finish();
    }

    fn writeFlagMetadata(packet: wire_1_21_5.entityMetadata.Writer, flags: minecraft.EntityFlags) !wire_1_21_5.entityMetadata.Writer.Done {
        var entries = try packet.value(2);
        try entries.advance(try packets.nested(.{writeFlagEntry}).write((try entries.next()).?, flags));
        try entries.advance(try packets.nested(.{writePoseEntry}).write((try entries.next()).?, flags));
        return entries.finish();
    }

    const FlagEntry = wire_1_21_5.entityMetadataEntry.cases.value.byte.Writer;
    const PoseEntry = wire_1_21_5.entityMetadataEntry.cases.value.pose.Writer;

    fn writeFlagEntry(packet: FlagEntry, flags: minecraft.EntityFlags) !FlagEntry.Done {
        return (try (try packet.key(0)).type()).value(@bitCast(flags));
    }

    fn writePoseEntry(packet: PoseEntry, flags: minecraft.EntityFlags) !PoseEntry.Done {
        return (try (try packet.key(6)).type()).value(if (flags.sneaking) 5 else 0);
    }
};

fn angle(value: f32) i8 {
    return @bitCast(@as(u8, @intFromFloat(@mod(@floor(@as(f64, value) * 256.0 / 360.0), 256.0))));
}

fn fixed(value: f64) i64 {
    return @intFromFloat(@floor(value * 4096.0));
}
