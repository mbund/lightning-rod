const std = @import("std");
const lightning_rod = @import("lightning_rod");
const audience = @import("audience.zig");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const minecraft = @import("minecraft_model");
const entities = @import("entities");
const game_data = @import("game_data");
const wire = @import("wire_1_21_5");
const packed_wire = @import("wire_1_21_9");
const Experience = @import("experience.zig").Experience;
const State = @import("experience_state.zig").State;
const Players = @import("players.zig").Players;
const Streaming = @import("streaming.zig").Streaming;
const assert = std.debug.assert;

pub const ExperienceReplication = struct {
    pub const id = "minecraft:experience_replication";
    pub const Configuration = struct { audience_words: usize = 4096, pickup_events: usize = 1024 };
    pub const Dependencies = struct { experience: *Experience, players: *Players, streaming: *Streaming, sessions: *sessions.Service, packets: *packets.Packets };
    const View = struct { id: u64 = 0, revision: u64 = 0, burning: bool = false };
    const Connection = struct { generation: u32 = 0, life: u32 = 0, world: u32 = 0, ready: bool = false, sent: ?State = null };
    const Event = struct { entity: u64 = 0, collector: i32 = 0 };
    const Phase = enum { spawn, position, metadata, remove };
    deps: Dependencies,
    views: []View,
    connections: []Connection,
    tracked: lightning_rod.system.IndexSet,
    known: audience.Matrix,
    dirty: audience.Matrix,
    metadata: audience.Matrix,
    collecting: audience.Matrix,
    scratch: audience.Matrix,
    event_recipients: audience.Matrix,
    events: []Event,
    event_slots: lightning_rod.system.IndexSet,
    first_event: usize = 0,
    event_span: usize = 0,
    targets: []sessions.Service.Target,
    deliveries: []sessions.Service.Delivery,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*ExperienceReplication {
        if (config.pickup_events == 0) return error.InvalidExperienceCapacity;
        const self = try allocator.create(ExperienceReplication);
        const count = deps.experience.orbs.len;
        self.* = .{
            .deps = deps,
            .views = try allocator.alloc(View, count),
            .connections = try allocator.alloc(Connection, deps.players.records.len),
            .tracked = try .init(allocator, deps.players.records.len),
            .known = try .init(allocator, deps.players, count, config.audience_words, .recipients),
            .dirty = try .init(allocator, deps.players, count, config.audience_words, .recipients),
            .metadata = try .init(allocator, deps.players, count, config.audience_words, .recipients),
            .collecting = try .init(allocator, deps.players, count, config.audience_words, .recipients),
            .scratch = try .init(allocator, deps.players, 3, config.audience_words, .recipients),
            .event_recipients = try .init(allocator, deps.players, config.pickup_events, config.audience_words, .recipients),
            .events = try allocator.alloc(Event, config.pickup_events),
            .event_slots = try .init(allocator, config.pickup_events),
            .targets = try allocator.alloc(sessions.Service.Target, deps.players.records.len),
            .deliveries = try allocator.alloc(sessions.Service.Delivery, deps.players.records.len),
        };
        @memset(self.views, .{});
        @memset(self.connections, .{});
        @memset(self.events, .{});
        return self;
    }

    pub fn tick(self: *ExperienceReplication) !void {
        const experience = self.deps.experience;
        for (self.deps.players.activeSlots()) |at| self.tracked.insert(at);
        var tracked_offset: usize = 0;
        while (tracked_offset < self.tracked.values().len) {
            const at = self.tracked.values()[tracked_offset];
            const player = self.deps.players.records[at];
            const connection = &self.connections[at];
            const generation = if (player.handle) |handle| handle.generation else 0;
            if (connection.generation != generation or connection.life != player.life or connection.world != player.world or connection.ready != (player.stage == .ready and player.handle != null)) {
                for (experience.active.values()) |index| {
                    self.known.row(index).remove(at);
                    self.dirty.row(index).remove(at);
                    self.metadata.row(index).remove(at);
                }
                for (self.event_slots.values()) |index| self.event_recipients.row(index).remove(at);
                connection.* = .{ .generation = generation, .life = player.life, .world = player.world, .ready = player.stage == .ready and player.handle != null };
            }
            if (player.handle == null) {
                self.tracked.remove(at);
                continue;
            }
            tracked_offset += 1;
            const handle = player.handle.?;
            if (player.stage != .ready or !player.loaded) continue;
            if (connection.sent == null or !std.meta.eql(connection.sent.?, player.experience)) {
                self.deps.packets.sendPacket(writeExperience, player.protocol, handle, .{player.experience}, 32) catch |err| switch (err) {
                    error.Backpressured, error.Closed => continue,
                    else => return err,
                };
                connection.sent = player.experience;
            }
        }
        const visibility = self.deps.streaming.snapshotVisibility();
        for (experience.pickups[0..experience.pickup_count]) |pickup| {
            const index = experience.ids.get(pickup.entity) orelse continue;
            if (self.views[index].id != pickup.entity) {
                assert(!self.known.row(index).view().any());
                self.views[index] = .{ .id = pickup.entity };
                self.dirty.row(index).clear();
                self.metadata.row(index).clear();
            }
            const body = experience.snapshot(index);
            const desired = self.interest(index, body, visibility);
            const spawning = self.scratch.row(1);
            spawning.subtract(desired.view(), self.known.row(index).view());
            try self.deliver(.spawn, index, body, spawning);
            const known = self.known.row(index).view();
            if (!known.any()) continue;
            if (self.event_span == self.events.len) {
                const at = self.first_event;
                const recipients = self.event_recipients.row(at);
                var blocked = recipients.view().iterator();
                while (blocked.next()) |player| if (self.deps.players.records[player].handle) |handle| self.deps.sessions.disconnect(handle);
                self.event_slots.remove(at);
                self.first_event = (at + 1) % self.events.len;
                self.event_span -= 1;
            }
            const at = (self.first_event + self.event_span) % self.events.len;
            self.event_span += 1;
            const recipients = self.event_recipients.row(at);
            recipients.copy(known);
            self.events[at] = .{ .entity = pickup.entity, .collector = pickup.collector };
            self.event_slots.insert(at);
        }
        for (experience.active.values()) |index| self.collecting.row(index).clear();
        const blocked = self.scratch.row(2);
        blocked.clear();
        for (0..self.event_span) |event_offset| {
            const at = (self.first_event + event_offset) % self.events.len;
            if (!self.event_slots.contains(at)) continue;
            const event = self.events[at];
            const recipients = self.event_recipients.row(at);
            var count: usize = 0;
            var remaining = recipients.view().iterator();
            while (remaining.next()) |player| {
                if (blocked.view().contains(player)) continue;
                if (self.deps.players.records[player].handle) |handle| {
                    self.targets[count] = .{ .handle = handle, .protocol = self.deps.players.records[player].protocol };
                    count += 1;
                } else recipients.remove(player);
            }
            try self.deps.packets.fanout(writeCollect, self.targets[0..count], .{ Experience.networkId(event.entity), event.collector }, 32, self.deliveries[0..count]);
            for (self.targets[0..count], self.deliveries[0..count]) |target, delivery| switch (delivery) {
                .queued, .closed => recipients.remove(target.handle.index),
                .unsupported => {
                    self.deps.sessions.disconnect(target.handle);
                    recipients.remove(target.handle.index);
                },
                .backpressured => blocked.insert(target.handle.index),
            };
            if (!recipients.view().any()) {
                self.event_slots.remove(at);
                continue;
            }
            if (experience.ids.get(event.entity)) |index| self.collecting.row(index).unite(self.collecting.row(index).view(), recipients.view());
        }
        while (self.event_span > 0 and !self.event_slots.contains(self.first_event)) {
            self.first_event = (self.first_event + 1) % self.events.len;
            self.event_span -= 1;
        }
        for (experience.active.values()) |index| {
            const entity = experience.residents[index].id;
            const orb = &experience.orbs[index];
            const body = experience.snapshot(index);
            const view = &self.views[index];
            const known = self.known.row(index);
            const dirty = self.dirty.row(index);
            if (view.id != entity) {
                assert(!known.view().any());
                dirty.clear();
                self.metadata.row(index).clear();
                view.* = .{ .id = entity };
            }
            if (view.revision != orb.revision) {
                dirty.unite(dirty.view(), known.view());
                view.revision = orb.revision;
            }
            if (view.burning != (orb.fire > 0)) {
                self.metadata.row(index).unite(self.metadata.row(index).view(), known.view());
                view.burning = orb.fire > 0;
            }
            const desired = self.scratch.row(0);
            const pending = self.scratch.row(1);
            if (orb.alive) _ = self.interest(index, body, visibility) else desired.clear();
            pending.subtract(known.view(), desired.view());
            pending.subtract(pending.view(), self.collecting.row(index).view());
            try self.deliver(.remove, index, body, pending);
            pending.subtract(desired.view(), known.view());
            try self.deliver(.spawn, index, body, pending);
            pending.intersect(self.metadata.row(index).view(), desired.view());
            try self.deliver(.metadata, index, body, pending);
            pending.intersect(dirty.view(), desired.view());
            try self.deliver(.position, index, body, pending);
            orb.viewers = known.view().count();
        }
        for (self.deps.players.activeSlots()) |source| {
            const sound = experience.sounds[source];
            const volume = sound.volume orelse continue;
            const player = self.deps.players.records[source];
            var nearby = self.deps.players.nearby(player.world, player.position, 1);
            var count: usize = 0;
            while (nearby.next()) |at| {
                const recipient = self.deps.players.records[at];
                if (recipient.stage != .ready or recipient.handle == null) continue;
                const dx = recipient.position.x - player.position.x;
                const dy = recipient.position.y - player.position.y;
                const dz = recipient.position.z - player.position.z;
                if (dx * dx + dy * dy + dz * dz >= 256) continue;
                self.targets[count] = .{ .handle = recipient.handle.?, .protocol = recipient.protocol };
                count += 1;
            }
            try self.deps.packets.fanout(writeLevelSound, self.targets[0..count], .{ player.position, volume, sound.seed }, 64, self.deliveries[0..count]);
            experience.sounds[source].volume = null;
        }
    }

    fn interest(self: *ExperienceReplication, index: usize, body: entities.State, visibility: *const Streaming.Visibility) audience.Row {
        const desired = self.scratch.row(0);
        desired.clear();
        var nearby = self.deps.players.nearby(body.world, .{ .x = body.position[0], .y = body.position[1], .z = body.position[2] }, 6);
        while (nearby.next()) |at| {
            const player = self.deps.players.records[at];
            if (player.handle == null or player.stage != .ready) continue;
            if (@abs(player.position.x - body.position[0]) > 96 or @abs(player.position.z - body.position[2]) > 96) continue;
            if (visibility.visible(at, &player, body.world, self.deps.experience.residents[index].x, self.deps.experience.residents[index].z)) desired.insert(at);
        }
        return desired;
    }

    fn deliver(self: *ExperienceReplication, comptime phase: Phase, index: usize, body: entities.State, audience_row: audience.Row) !void {
        var recipients = audience_row.view().iterator();
        var count: usize = 0;
        while (recipients.next()) |player| {
            self.targets[count] = .{ .handle = self.deps.players.records[player].handle.?, .protocol = self.deps.players.records[player].protocol };
            count += 1;
        }
        if (count == 0) return;
        const entity = Experience.networkId(self.deps.experience.residents[index].id);
        switch (phase) {
            .spawn => try self.deps.packets.fanoutGroup(.{ .{ writeSpawnLegacy, writeSpawnPacked }, writeValue }, self.targets[0..count], .{ .{ entity, body }, .{ entity, self.deps.experience.orbs[index].value, self.deps.experience.orbs[index].fire > 0 } }, &.{ 128, 32 }, self.deliveries[0..count]),
            .position => try self.deps.packets.fanout(writePosition, self.targets[0..count], .{ entity, body, self.deps.experience.orbs[index].on_ground }, 128, self.deliveries[0..count]),
            .metadata => try self.deps.packets.fanout(writeValue, self.targets[0..count], .{ entity, self.deps.experience.orbs[index].value, self.deps.experience.orbs[index].fire > 0 }, 32, self.deliveries[0..count]),
            .remove => try self.deps.packets.fanout(writeRemove, self.targets[0..count], .{entity}, 32, self.deliveries[0..count]),
        }
        for (self.targets[0..count], self.deliveries[0..count]) |target, delivery| switch (delivery) {
            .queued => switch (phase) {
                .spawn => self.known.row(index).insert(target.handle.index),
                .position => self.dirty.row(index).remove(target.handle.index),
                .metadata => self.metadata.row(index).remove(target.handle.index),
                .remove => {
                    self.known.row(index).remove(target.handle.index);
                    self.dirty.row(index).remove(target.handle.index);
                    self.metadata.row(index).remove(target.handle.index);
                },
            },
            .unsupported => self.deps.sessions.disconnect(target.handle),
            .closed => {
                self.known.row(index).remove(target.handle.index);
                self.dirty.row(index).remove(target.handle.index);
                self.metadata.row(index).remove(target.handle.index);
            },
            .backpressured => {},
        };
    }
};

fn writeExperience(packet: wire.play.toClient.packet_experience.Writer, value: State) ![]u8 {
    return (try (try (try packet.experienceBar(value.progress)).level(value.level)).totalExperience(value.total)).finish();
}
fn writeSpawnLegacy(packet: wire.play.toClient.packet_spawn_entity.Writer, registry: packets.Registry, id: i32, body: entities.State) ![]u8 {
    const positioned = try (try (try (try (try (try packet.entityId(id)).objectUUID(body.uuid)).type(try registry.entityId(@intCast(body.kind)))).x(body.position[0])).y(body.position[1])).z(body.position[2]);
    const data = try (try (try (try positioned.pitch(angle(body.pitch))).yaw(angle(body.yaw))).headPitch(0)).objectData(0);
    var velocity = try data.velocity();
    return (try velocity.advance(try packets.nested(.{writeVelocity}).write(try velocity.begin(), body.velocity))).finish();
}
fn writeVelocity(packet: wire.vec3i16.Writer, motion: [3]f64) !wire.vec3i16.Writer.Done {
    return (try (try packet.x(@intFromFloat(std.math.clamp(motion[0], -3.9, 3.9) * 8000))).y(@intFromFloat(std.math.clamp(motion[1], -3.9, 3.9) * 8000))).z(@intFromFloat(std.math.clamp(motion[2], -3.9, 3.9) * 8000));
}
fn writeSpawnPacked(packet: packed_wire.play.toClient.packet_spawn_entity.Writer, registry: packets.Registry, id: i32, body: entities.State) ![]u8 {
    const positioned = try (try (try (try (try (try packet.entityId(id)).objectUUID(body.uuid)).type(try registry.entityId(@intCast(body.kind)))).x(body.position[0])).y(body.position[1])).z(body.position[2]);
    const rotated = try (try (try (try positioned.velocity(.{ .x = body.velocity[0], .y = body.velocity[1], .z = body.velocity[2] })).pitch(angle(body.pitch))).yaw(angle(body.yaw))).headPitch(0);
    return (try rotated.objectData(0)).finish();
}
fn writeValue(packet: wire.play.toClient.packet_entity_metadata.Writer, id: i32, value: i32, burning: bool) ![]u8 {
    var metadata = try (try packet.entityId(id)).metadata();
    const done = try packets.nested(.{writeMetadata}).write(try metadata.begin(), .{ .value = value, .burning = burning });
    return (try metadata.advance(done)).finish();
}
const Metadata = struct { value: i32, burning: bool };
fn writeMetadata(packet: wire.entityMetadata.Writer, state: Metadata) !wire.entityMetadata.Writer.Done {
    var entries = try packet.value(2);
    try entries.advance(try packets.nested(.{writeFlags}).write((try entries.next()).?, state.burning));
    try entries.advance(try packets.nested(.{writeEntry}).write((try entries.next()).?, state.value));
    return entries.finish();
}
fn writeFlags(packet: wire.entityMetadataEntry.cases.value.byte.Writer, burning: bool) !wire.entityMetadataEntry.cases.value.byte.Writer.Done {
    return (try (try packet.key(0)).type()).value(if (burning) 1 else 0);
}
fn writeEntry(packet: wire.entityMetadataEntry.cases.value.int.Writer, value: i32) !wire.entityMetadataEntry.cases.value.int.Writer.Done {
    return (try (try packet.key(8)).type()).value(value);
}
fn writePosition(packet: wire.play.toClient.packet_sync_entity_position.Writer, id: i32, body: entities.State, on_ground: bool) ![]u8 {
    const positioned = try (try (try (try packet.entityId(id)).x(body.position[0])).y(body.position[1])).z(body.position[2]);
    const moving = try (try (try positioned.dx(body.velocity[0])).dy(body.velocity[1])).dz(body.velocity[2]);
    return (try (try (try moving.yaw(body.yaw)).pitch(body.pitch)).onGround(on_ground)).finish();
}
fn writeCollect(packet: wire.play.toClient.packet_collect.Writer, id: i32, player: i32) ![]u8 {
    return (try (try (try packet.collectedEntityId(id)).collectorEntityId(player)).pickupItemCount(1)).finish();
}
fn writeRemove(packet: wire.play.toClient.packet_entity_destroy.Writer, id: i32) ![]u8 {
    const ids = try packet.entityIds(1);
    const entry = try ids.element(id);
    return (try entry.finish()).finish();
}

fn writeLevelSound(packet: wire.play.toClient.packet_sound_effect.Writer, position: minecraft.Position, volume: f32, seed: i64) ![]u8 {
    var sound = try packet.sound();
    const selected = try packets.nested(.{writeSoundHolder}).write(try sound.begin(), {});
    const category = try (try sound.advance(selected)).soundCategory(7);
    const located = try (try (try category.x(@intFromFloat(position.x * 8))).y(@intFromFloat(position.y * 8))).z(@intFromFloat(position.z * 8));
    return (try (try (try located.volume(volume)).pitch(1)).seed(seed)).finish();
}

fn writeSoundHolder(packet: wire.ItemSoundHolder.Writer, _: void) !wire.ItemSoundHolder.Writer.Done {
    var data = try packet.data();
    return data.advance(try packets.nested(.{writeSoundEvent}).write(try data.begin(), {}));
}

fn writeSoundEvent(packet: wire.ItemSoundEvent.Writer, _: void) !wire.ItemSoundEvent.Writer.Done {
    var range = try (try packet.soundName("minecraft:entity.player.levelup")).fixedRange();
    return range.advance(try (try range.begin()).none());
}

fn angle(degrees: f32) i8 {
    return @bitCast(@as(u8, @intFromFloat(@mod(@floor(degrees * 256 / 360), 256))));
}
