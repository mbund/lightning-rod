const std = @import("std");
const lightning_rod = @import("lightning_rod");
const audience = @import("players").audience;
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const minecraft = @import("minecraft_model");
const entities = @import("entities");
const records = @import("records");
const game_data = @import("game_data");
const wire = @import("wire_1_21_5");
const entity_packets = @import("replication").entity_packets;
const bit_sets = lightning_rod.system.bit_sets;
const Experience = @import("experience.zig").Experience;
const State = @import("vanilla_player").experience_state.State;
const Players = @import("players").players.Players;
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const Streaming = @import("terrain").streaming.Streaming;
const assert = std.debug.assert;

/// What clients know of experience orbs: each orb's view is a record beside it, of who has it
/// spawned and who is owed its motion or its value, looked at every tick as every orb is.
pub const ExperienceReplication = struct {
    pub const id = "minecraft:experience_replication";
    pub const Configuration = struct {
        audience_words: usize = 4096,
        pickup_events: usize = 1024,
        /// Orbs clients are shown at once.
        views: usize = 16384,
        /// Keep a hash of every packet queued and whom to, for runs to be compared by.
        trace_sends: bool = false,
    };
    pub const Dependencies = struct { experience: *Experience, players: *Players, player_states: *PlayerStates, streaming: *Streaming, sessions: *sessions.Service, packets: *packets.Packets };

    /// At the head of a view record; the rows of who knows the orb, who is owed its motion and
    /// who its value follow.
    const Header = extern struct {
        revision: u64 = 0,
        burning: bool = false,
        padding: [7]u8 = @splat(0),
    };
    const row_count = 3;

    const View = struct {
        entity: entities.Id,
        header: *Header,
        known: bit_sets.Row,
        dirty: bit_sets.Row,
        metadata: bit_sets.Row,
        /// Gone, and no client knows of it: its view goes once let go.
        forget: bool = false,

        fn holds(self: *const View) bool {
            return self.known.view().any() or self.dirty.view().any() or self.metadata.view().any();
        }
    };

    const Connection = struct { generation: u32 = 0, life: u32 = 0, world: u32 = 0, ready: bool = false, sent: ?State = null };
    const Event = struct { entity: u64 = 0, collector: i32 = 0 };
    const Phase = enum { spawn, position, metadata, remove };
    deps: Dependencies,
    /// A running hash of every packet asked to be sent and whom to, when tests trace it.
    traced: u64 = 0,
    tracing: bool,
    /// Room to copy the orbs' ids into, as looking at them may forget some.
    orbs: []entities.Id,
    /// Views by orb id: an orb no client knows of has none.
    views: entities.Slab,
    record_bytes: usize,
    row_words: usize,
    connections: []Connection,
    tracked: lightning_rod.system.IndexSet,
    /// Players whose connection was replaced this tick: no view knows them any more.
    reset: audience.Row,
    scratch: audience.Matrix,
    event_recipients: audience.Matrix,
    events: []Event,
    event_slots: lightning_rod.system.IndexSet,
    first_event: usize = 0,
    event_span: usize = 0,
    targets: []sessions.Service.Target,
    deliveries: []sessions.Service.Delivery,
    reset_matrix: audience.Matrix,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*ExperienceReplication {
        if (config.pickup_events == 0) return error.InvalidExperienceCapacity;
        const self = try allocator.create(ExperienceReplication);
        const players = deps.players.records.len;
        const row_words = std.math.divCeil(usize, players, @bitSizeOf(usize)) catch unreachable;
        const record_bytes = @sizeOf(Header) + row_count * row_words * @sizeOf(usize);
        const experience = deps.experience;
        const reset_matrix = try audience.Matrix.init(allocator, deps.players, 1, config.audience_words, .recipients);
        self.* = .{
            .deps = deps,
            .tracing = config.trace_sends,
            .views = try .init(allocator, &deps.experience.deps.entities.pool, record_bytes, config.views),
            .orbs = try allocator.alloc(entities.Id, experience.orbs.bound()),
            .record_bytes = record_bytes,
            .row_words = row_words,
            .connections = try allocator.alloc(Connection, players),
            .tracked = try .init(allocator, players),
            .reset = reset_matrix.row(0),
            .reset_matrix = reset_matrix,
            .scratch = try .init(allocator, deps.players, 4, config.audience_words, .recipients),
            .event_recipients = try .init(allocator, deps.players, config.pickup_events, config.audience_words, .recipients),
            .events = try allocator.alloc(Event, config.pickup_events),
            .event_slots = try .init(allocator, config.pickup_events),
            .targets = try allocator.alloc(sessions.Service.Target, players),
            .deliveries = try allocator.alloc(sessions.Service.Delivery, players),
        };
        @memset(self.connections, .{});
        @memset(self.events, .{});
        experience.leaving = .{ .context = self, .function = orbLeaving };
        return self;
    }

    /// An orb left memory, far from every player: no client keeps it, and its view goes.
    fn orbLeaving(context: *anyopaque, entity: entities.Id) void {
        const self: *ExperienceReplication = @ptrCast(@alignCast(context));
        self.views.remove(entity);
    }

    fn holdViews(self: *ExperienceReplication, ids: []const entities.Id, output: []View) !void {
        assert(ids.len == output.len and ids.len <= 16);
        for (ids, output) |entity, *view| {
            const bytes = try self.views.getOrCreate(entity);
            const words: []usize = @alignCast(std.mem.bytesAsSlice(usize, bytes[@sizeOf(Header)..]));
            const capacity = self.connections.len;
            view.* = .{
                .entity = entity,
                .header = @ptrCast(bytes[0..@sizeOf(Header)]),
                .known = .{ .words = words[0..self.row_words], .capacity = capacity },
                .dirty = .{ .words = words[self.row_words..][0..self.row_words], .capacity = capacity },
                .metadata = .{ .words = words[self.row_words * 2 ..][0..self.row_words], .capacity = capacity },
            };
        }
    }

    fn letGo(self: *ExperienceReplication, view: *View) void {
        if (!view.holds() or view.forget) self.views.remove(view.entity);
    }

    /// How many clients have an orb spawned, for tests.
    pub fn knownBy(self: *ExperienceReplication, entity: entities.Id) !usize {
        const bytes = self.views.get(entity) orelse return 0;
        const words: []const usize = @alignCast(std.mem.bytesAsSlice(usize, bytes[@sizeOf(Header)..]));
        return (bit_sets.Set{ .words = words[0..self.row_words], .capacity = self.connections.len }).count();
    }

    pub fn tick(self: *ExperienceReplication) !void {
        const experience = self.deps.experience;
        self.reset.clear();
        for (self.deps.players.activeSlots()) |at| self.tracked.insert(at);
        var tracked_offset: usize = 0;
        while (tracked_offset < self.tracked.values().len) {
            const at = self.tracked.values()[tracked_offset];
            const player = self.deps.players.records[at];
            const connection = &self.connections[at];
            const generation = if (player.handle) |handle| handle.generation else 0;
            if (connection.generation != generation or connection.life != player.life or connection.world != player.world or connection.ready != (player.stage == .ready and player.handle != null)) {
                // Every view is looked at below this tick, which forgets this player in each.
                self.reset.insert(at);
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
            const points = self.deps.player_states.of(&player).experience;
            if (connection.sent == null or !std.meta.eql(connection.sent.?, points)) {
                self.deps.packets.sendPacket(writeExperience, player.protocol, handle, .{points}, 32) catch |err| switch (err) {
                    error.Backpressured, error.Closed => continue,
                    else => return err,
                };
                connection.sent = points;
            }
        }
        const visibility = self.deps.streaming.snapshotVisibility();
        for (experience.pickups[0..experience.pickup_count]) |pickup| {
            var views: [1]View = undefined;
            try self.holdViews(&.{pickup.entity}, &views);
            defer self.letGo(&views[0]);
            const view = &views[0];
            self.forgetReset(view);
            const desired = self.interest(pickup.body, visibility);
            const spawning = self.scratch.row(1);
            spawning.subtract(desired.view(), view.known.view());
            try self.deliver(.spawn, view, pickup.body, pickup.value, false, spawning);
            const known = view.known.view();
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
            try self.deps.packets.fanout(writeCollect, self.targets[0..count], .{ self.deps.experience.networkId(event.entity), event.collector }, 32, self.deliveries[0..count]);
            for (self.targets[0..count], self.deliveries[0..count]) |target, delivery| switch (delivery) {
                .queued, .closed => recipients.remove(target.handle.index),
                .unsupported => {
                    self.deps.sessions.disconnect(target.handle);
                    recipients.remove(target.handle.index);
                },
                .backpressured => blocked.insert(target.handle.index),
            };
            if (!recipients.view().any()) self.event_slots.remove(at);
        }
        while (self.event_span > 0 and !self.event_slots.contains(self.first_event)) {
            self.first_event = (self.first_event + 1) % self.events.len;
            self.event_span -= 1;
        }
        // Every orb, by id, a batch at a time: the ids come sorted.
        const ids = experience.ids();
        const orbs = self.orbs[0..ids.len];
        @memcpy(orbs, ids);
        var next: usize = 0;
        while (next < orbs.len) {
            const count = @min(16, orbs.len - next);
            try self.lookAt(orbs[next..][0..count], visibility);
            next += count;
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
                if (at != source and !visibility.boundsVisible(at, &recipient, player.world, .{
                    .minimum = .{ @intFromFloat(@floor(player.position.x - 0.3)), @intFromFloat(@floor(player.position.y)), @intFromFloat(@floor(player.position.z - 0.3)) },
                    .maximum = .{ @intFromFloat(@ceil(player.position.x + 0.3)), @intFromFloat(@ceil(player.position.y + 1.8)), @intFromFloat(@ceil(player.position.z + 0.3)) },
                })) continue;
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

    /// A replaced connection's player knows none of an orb any more.
    fn forgetReset(self: *ExperienceReplication, view: *View) void {
        if (!self.reset.view().any()) return;
        view.known.subtract(view.known.view(), self.reset.view());
        view.dirty.subtract(view.dirty.view(), self.reset.view());
        view.metadata.subtract(view.metadata.view(), self.reset.view());
    }

    fn lookAt(self: *ExperienceReplication, ids: []const entities.Id, visibility: *const Streaming.Visibility) !void {
        const experience = self.deps.experience;
        var views: [16]View = undefined;
        try self.holdViews(ids, views[0..ids.len]);
        var let_go: usize = 0;
        defer for (views[let_go..ids.len]) |*view| self.letGo(view);
        var forgotten: [16]entities.Id = undefined;
        var forgotten_count: usize = 0;
        for (ids, views[0..ids.len]) |entity, *view| {
            const found = (try experience.get(entity)) orelse return error.Corrupt;
            const orb = found.orb;
            const body = found.body orelse entities.State{ .uuid = 0, .kind = 0, .world = 0, .position = .{ 0, 0, 0 } };
            self.forgetReset(view);
            if (view.header.revision != orb.revision) {
                view.dirty.unite(view.dirty.view(), view.known.view());
                view.header.revision = orb.revision;
            }
            if (view.header.burning != (orb.fire > 0)) {
                view.metadata.unite(view.metadata.view(), view.known.view());
                view.header.burning = orb.fire > 0;
            }
            const desired = self.scratch.row(0);
            const pending = self.scratch.row(1);
            if (orb.alive) _ = self.interest(body, visibility) else desired.clear();
            const collecting = self.scratch.row(3);
            collecting.clear();
            for (0..self.event_span) |event_offset| {
                const at = (self.first_event + event_offset) % self.events.len;
                if (!self.event_slots.contains(at) or self.events[at].entity != entity) continue;
                collecting.unite(collecting.view(), self.event_recipients.row(at).view());
            }
            pending.subtract(view.known.view(), desired.view());
            pending.subtract(pending.view(), collecting.view());
            try self.deliver(.remove, view, body, orb.value, orb.on_ground, pending);
            pending.subtract(desired.view(), view.known.view());
            try self.deliver(.spawn, view, body, orb.value, orb.on_ground, pending);
            pending.intersect(view.metadata.view(), desired.view());
            try self.deliver(.metadata, view, body, orb.value, orb.on_ground, pending);
            pending.intersect(view.dirty.view(), desired.view());
            try self.deliver(.position, view, body, orb.value, orb.on_ground, pending);
            if (!orb.alive and !view.known.view().any() and !collecting.view().any()) {
                view.forget = true;
                forgotten[forgotten_count] = entity;
                forgotten_count += 1;
            }
        }
        for (views[0..ids.len]) |*view| {
            self.letGo(view);
            let_go += 1;
        }
        for (forgotten[0..forgotten_count]) |entity| try experience.forget(entity);
    }

    fn interest(self: *ExperienceReplication, body: entities.State, visibility: *const Streaming.Visibility) audience.Row {
        const desired = self.scratch.row(0);
        desired.clear();
        var nearby = self.deps.players.nearby(body.world, .{ .x = body.position[0], .y = body.position[1], .z = body.position[2] }, 6);
        while (nearby.next()) |at| {
            const player = self.deps.players.records[at];
            if (player.handle == null or player.stage != .ready) continue;
            if (@abs(player.position.x - body.position[0]) > 96 or @abs(player.position.z - body.position[2]) > 96) continue;
            if (visibility.boundsVisible(at, &player, body.world, .{
                .minimum = .{ @intFromFloat(@floor(body.position[0] - 1)), @intFromFloat(@floor(body.position[1] - 1)), @intFromFloat(@floor(body.position[2] - 1)) },
                .maximum = .{ @intFromFloat(@ceil(body.position[0] + 1)), @intFromFloat(@ceil(body.position[1] + 1)), @intFromFloat(@ceil(body.position[2] + 1)) },
            })) desired.insert(at);
        }
        return desired;
    }

    fn deliver(self: *ExperienceReplication, comptime phase: Phase, view: *View, body: entities.State, value: i32, on_ground: bool, audience_row: audience.Row) !void {
        var recipients = audience_row.view().iterator();
        var count: usize = 0;
        while (recipients.next()) |player| {
            self.targets[count] = .{ .handle = self.deps.players.records[player].handle.?, .protocol = self.deps.players.records[player].protocol };
            count += 1;
        }
        if (count == 0) return;
        const entity = self.deps.experience.networkId(view.entity);
        if (self.tracing) {
            var hasher = std.hash.Wyhash.init(self.traced);
            hasher.update(std.mem.asBytes(&entity));
            hasher.update(&.{@backingInt(phase)});
            hasher.update(std.mem.asBytes(&value));
            for (self.targets[0..count]) |target| hasher.update(std.mem.asBytes(&target.handle.index));
            self.traced = hasher.final();
        }
        switch (phase) {
            .spawn => try self.deps.packets.fanoutGroup(.{ entity_packets.spawn, writeValue }, self.targets[0..count], .{ .{ entity, body }, .{ entity, value, view.header.burning } }, &.{ 128, 32 }, self.deliveries[0..count]),
            .position => try self.deps.packets.fanout(writePosition, self.targets[0..count], .{ entity, body, on_ground }, 128, self.deliveries[0..count]),
            .metadata => try self.deps.packets.fanout(writeValue, self.targets[0..count], .{ entity, value, view.header.burning }, 32, self.deliveries[0..count]),
            .remove => try self.deps.packets.fanout(writeRemove, self.targets[0..count], .{entity}, 32, self.deliveries[0..count]),
        }
        for (self.targets[0..count], self.deliveries[0..count]) |target, delivery| switch (delivery) {
            .queued => switch (phase) {
                .spawn => view.known.insert(target.handle.index),
                .position => view.dirty.remove(target.handle.index),
                .metadata => view.metadata.remove(target.handle.index),
                .remove => {
                    view.known.remove(target.handle.index);
                    view.dirty.remove(target.handle.index);
                    view.metadata.remove(target.handle.index);
                },
            },
            .unsupported => self.deps.sessions.disconnect(target.handle),
            .closed => {
                view.known.remove(target.handle.index);
                view.dirty.remove(target.handle.index);
                view.metadata.remove(target.handle.index);
            },
            .backpressured => {},
        };
    }
};
fn writeExperience(packet: wire.play.toClient.packet_experience.Writer, value: State) ![]u8 {
    return (try (try (try packet.experienceBar(value.progress)).level(value.level)).totalExperience(value.total)).finish();
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
