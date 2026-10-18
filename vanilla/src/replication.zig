const std = @import("std");
const protocols = @import("protocols");
const sessions = @import("sessions");
const Players = @import("players.zig").Players;
const game_data = @import("game_data");
const minecraft = @import("minecraft_model");
const packets = @import("minecraft_packets");
const wire_1_21_5 = @import("wire_1_21_5");
const wire_1_21_9 = @import("wire_1_21_9");

const assert = std.debug.assert;

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
        spawned: u256 = 0,
        pending: u256 = 0,
    };

    deps: Dependencies,
    seen: []Seen,
    observers: []Observer,
    subjects: []Subject,
    viewer_masks: []u256,

    const Subject = struct { generation: u32 = 0, gamemode: minecraft.GameMode = .survival };

    const Group = struct { protocol: i32, absolute: bool, baseline: [3]i64 };
    const Target = struct {
        group: Group,
        handle: sessions.Handle,

        fn less(_: void, a: Target, b: Target) bool {
            const protocol = std.math.order(a.group.protocol, b.group.protocol);
            const absolute = std.math.order(@intFromBool(a.group.absolute), @intFromBool(b.group.absolute));
            const baseline = std.mem.order(i64, &a.group.baseline, &b.group.baseline);
            return protocol == .lt or (protocol == .eq and (absolute == .lt or (absolute == .eq and baseline == .lt)));
        }
    };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Replication {
        const self = try allocator.create(Replication);
        const seen = try allocator.alloc(Seen, deps.players.records.len * deps.players.records.len);
        @memset(seen, .{});
        const observers = try allocator.alloc(Observer, deps.players.records.len);
        @memset(observers, .{});
        const subjects = try allocator.alloc(Subject, deps.players.records.len);
        @memset(subjects, .{});
        const viewer_masks = try allocator.alloc(u256, deps.players.records.len);
        @memset(viewer_masks, 0);
        self.* = .{ .deps = deps, .seen = seen, .observers = observers, .subjects = subjects, .viewer_masks = viewer_masks };
        return self;
    }

    pub fn tick(self: *Replication) void {
        const players = self.deps.players;
        players.refreshSpatial();
        var changed: u256 = 0;
        var connected: u256 = 0;
        for (players.records, self.subjects, 0..) |player, *subject, index| {
            const generation = if (player.handle) |handle| handle.generation else 0;
            if (generation != 0) connected |= @as(u256, 1) << @intCast(index);
            if (generation != subject.generation or player.gamemode != subject.gamemode) changed |= @as(u256, 1) << @intCast(index);
            subject.* = .{ .generation = generation, .gamemode = player.gamemode };
        }
        @memset(self.viewer_masks, 0);
        var updates: [256]u256 = @splat(0);

        for (players.records, 0..) |observer, observer_index| {
            const row = self.seen[observer_index * players.records.len ..][0..players.records.len];
            const recipient = observer.handle orelse {
                @memset(row, .{});
                self.observers[observer_index] = .{};
                continue;
            };

            if (self.observers[observer_index].generation != recipient.generation) {
                @memset(row, .{});
                self.observers[observer_index] = .{ .generation = recipient.generation, .world = observer.world, .pending = connected };
            }

            self.observers[observer_index].pending |= changed;
            if (observer.stage != .ready) continue;

            if (self.observers[observer_index].world != observer.world) {
                for (row) |*seen| if (seen.stage == .spawned) {
                    seen.stage = .listed;
                    seen.flags = null;
                    seen.head = null;
                };

                self.observers[observer_index].world = observer.world;
            }

            const watching = &self.observers[observer_index];
            const interested = players.nearby(observer.world, observer.position, players.config.render_distance);
            var candidates = watching.pending | interested | watching.spawned | (@as(u256, 1) << @intCast(observer_index));
            while (candidates != 0) {
                const index: usize = @intCast(@ctz(candidates));
                const flag = @as(u256, 1) << @intCast(index);
                candidates &= ~flag;
                watching.pending &= ~flag;
                const subject = players.records[index];
                const seen = &row[index];
                var listed_complete = false;
                defer {
                    if (!listed_complete) watching.pending |= flag;
                    if (seen.stage == .spawned) {
                        watching.spawned |= flag;
                        self.viewer_masks[index] |= @as(u256, 1) << @intCast(observer_index);
                    } else watching.spawned &= ~flag;
                }
                if (index == observer_index) {
                    if (seen.gamemode != subject.gamemode and players.sendPacket(writeMode, observer.protocol, &.{recipient}, .{ subject.uuid, subject.gamemode }))
                        seen.gamemode = subject.gamemode;
                    listed_complete = seen.gamemode == subject.gamemode;
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

                if (subject.handle == null) {
                    listed_complete = true;
                    continue;
                }
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

                listed_complete = true;
                if (interested & flag == 0) {
                    if (seen.stage == .spawned) {
                        if (!players.sendPacket(writeRemove, observer.protocol, &.{recipient}, .{entity_id})) continue;
                        seen.stage = .listed;
                        seen.flags = null;
                        seen.head = null;
                    }

                    continue;
                }

                if (!subject.inWorld()) continue;
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
                updates[index] |= @as(u256, 1) << @intCast(observer_index);
            }
        }

        for (players.records, updates[0..players.records.len], 0..) |subject, watching, index| {
            if (watching == 0) continue;
            const position: [3]i64 = .{ fixed(subject.position.x), fixed(subject.position.y), fixed(subject.position.z) };
            const yaw = angle(subject.rotation.yaw);
            const pitch = angle(subject.rotation.pitch);
            const entity_id: i32 = @intCast(index + 1);
            var eligible = watching;
            inline for (std.enums.values(enum { movement, head, flags })) |phase| {
                var targets: [256]Target = undefined;
                var target_count: usize = 0;
                var uniform = true;
                var candidates = eligible;
                while (candidates != 0) {
                    const other: usize = @intCast(@ctz(candidates));
                    candidates &= candidates - 1;
                    const observer = players.records[other];
                    const seen = self.seen[other * players.records.len + index];
                    const needed = switch (phase) {
                        .movement => !std.meta.eql(position, seen.position) or yaw != seen.yaw or pitch != seen.pitch or subject.on_ground != seen.on_ground,
                        .head => seen.head == null or seen.head.? != yaw,
                        .flags => seen.flags == null or !std.meta.eql(seen.flags.?, subject.flags),
                    };
                    if (!needed) continue;
                    const absolute = phase == .movement and !relative(position, seen.position);
                    const group: Group = .{ .protocol = observer.protocol, .absolute = absolute, .baseline = if (phase == .movement and !absolute) seen.position else @splat(0) };
                    if (target_count != 0) uniform = uniform and std.meta.eql(targets[0].group, group);
                    targets[target_count] = .{ .group = group, .handle = observer.handle.? };
                    target_count += 1;
                }
                if (!uniform) std.mem.sort(Target, targets[0..target_count], {}, Target.less);
                var start: usize = 0;
                while (start < target_count) {
                    const key = targets[start].group;
                    const protocol = key.protocol;
                    const absolute = key.absolute;
                    var stop = start + 1;
                    while (stop < target_count and std.meta.eql(targets[stop].group, key)) : (stop += 1) {}
                    var recipients: [256]sessions.Handle = undefined;
                    const count = stop - start;
                    var group: u256 = 0;
                    for (targets[start..stop], recipients[0..count]) |target, *recipient| {
                        recipient.* = target.handle;
                        group |= @as(u256, 1) << @intCast(target.handle.index);
                    }
                    start = stop;
                    var packet = players.deps.sessions.reserve(2048) catch |err| switch (err) {
                        error.Closed, error.Backpressured => {
                            eligible &= ~group;
                            continue;
                        },
                        else => std.debug.panic("invalid server packet: {s}", .{@errorName(err)}),
                    };
                    defer packet.cancel();
                    const bytes = switch (phase) {
                        .movement => if (absolute)
                            players.deps.packets.writePacket(writePosition, protocol, packet.bytes, .{ entity_id, subject.position, minecraft.Position{ .x = 0, .y = 0, .z = 0 }, subject.rotation, subject.on_ground })
                        else
                            players.deps.packets.writePacket(writeMove, protocol, packet.bytes, .{
                                entity_id, @as(i16, @intCast(position[0] - key.baseline[0])), @as(i16, @intCast(position[1] - key.baseline[1])), @as(i16, @intCast(position[2] - key.baseline[2])), yaw, pitch, subject.on_ground,
                            }),
                        .head => players.deps.packets.writePacket(writeHeadRotation, protocol, packet.bytes, .{ entity_id, yaw }),
                        .flags => players.deps.packets.writePacket(writeFlags, protocol, packet.bytes, .{ entity_id, subject.flags }),
                    } catch |err| std.debug.panic("invalid server packet: {s}", .{@errorName(err)});
                    var delivered: u256 = 0;
                    for (packet.publishReady(bytes.len, recipients[0..count])) |handle| {
                        delivered |= @as(u256, 1) << @intCast(handle.index);
                        const seen = &self.seen[handle.index * players.records.len + index];
                        switch (phase) {
                            .movement => {
                                seen.position = position;
                                seen.yaw = yaw;
                                seen.pitch = pitch;
                                seen.on_ground = subject.on_ground;
                            },
                            .head => seen.head = yaw,
                            .flags => seen.flags = subject.flags,
                        }
                    }
                    eligible &= ~(group & ~delivered);
                }
            }
        }
    }

    pub fn viewers(self: *const Replication, subject: usize) u256 {
        return self.viewer_masks[subject];
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

fn relative(position: [3]i64, baseline: [3]i64) bool {
    const dx = position[0] - baseline[0];
    const dy = position[1] - baseline[1];
    const dz = position[2] - baseline[2];
    return dx >= -32768 and dx <= 32767 and dy >= -32768 and dy <= 32767 and dz >= -32768 and dz <= 32767;
}

fn fixed(value: f64) i64 {
    return @intFromFloat(@floor(value * 4096.0));
}

test "movement fanout preserves independent admission and observer baselines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const selected = comptime definitions: {
        var result: [protocols.implementations.len]sessions.Protocol = undefined;
        for (protocols.implementations, 0..) |Version, i| result[i] = .{ .number = Version.protocol_number };
        break :definitions result;
    };
    const service = try sessions.Service.init(allocator, std.testing.io, undefined, .{
        .connections = 3,
        .pages = 128,
        .page_bytes = 4096,
        .buffer_bytes = 32768,
        .protocols = &selected,
    });
    const packet_service = try packets.Packets.init(allocator, .{ .sessions = service });
    var records: [3]Players.Player = undefined;
    for (&records, 0..) |*player, i| {
        player.* = .{ .handle = .{ .index = @intCast(i), .generation = 1 }, .uuid = i + 1, .protocol = selected[0].number, .name = @splat(0), .name_len = 1, .stage = .ready };
        player.name[0] = @intCast('a' + i);
        service.credit[i].store(@as(u64, 1) << 32 | sessions.Service.active | service.config.buffer_bytes, .release);
    }
    var players: Players = .{
        .deps = .{ .sessions = service, .packets = packet_service, .input = undefined, .storage = undefined, .worlds = undefined, .vanilla_worlds = undefined },
        .config = .{ .maximum = 3, .render_distance = 2 },
        .spawn_world = 0,
        .records = &records,
        .dig_handlers = &.{},
    };
    const replication = try Replication.init(allocator, .{ .players = &players });
    const Drain = struct {
        fn run(endpoint: *sessions.Service, recipients: usize) !usize {
            var count: usize = 0;
            while (endpoint.output.takeReady()) |packet| {
                if (recipients != 0) try std.testing.expectEqual(recipients, packet.recipients.len);
                try std.testing.expect(endpoint.output.releaseReady(packet.page, packet.generation));
                _ = endpoint.preparing.fetchSub(1, .release);
                count += 1;
            }
            return count;
        }
    };
    replication.tick();
    _ = try Drain.run(service, 0);
    records[0].position.x += 1;
    replication.tick();
    try std.testing.expectEqual(@as(usize, 1), try Drain.run(service, 2));
    service.credit[2].store(@as(u64, 1) << 32 | sessions.Service.active, .release);
    records[0].position.x += 1;
    replication.tick();
    try std.testing.expectEqual(@as(usize, 1), try Drain.run(service, 1));
    try std.testing.expect(replication.seen[3].position[0] != replication.seen[6].position[0]);
    service.credit[2].store(@as(u64, 1) << 32 | sessions.Service.active | service.config.buffer_bytes, .release);
    records[0].position.x += 1;
    replication.tick();
    try std.testing.expectEqual(@as(usize, 2), try Drain.run(service, 1));
    try std.testing.expectEqual(replication.seen[3].position[0], replication.seen[6].position[0]);
    records[0].position.x += 16;
    replication.tick();
    try std.testing.expectEqual(@as(usize, 1), try Drain.run(service, 2));
    if (comptime selected.len > 1) {
        records[2].protocol = selected[1].number;
        records[0].position.x += 1;
        replication.tick();
        try std.testing.expectEqual(@as(usize, 2), try Drain.run(service, 1));
    }
}
