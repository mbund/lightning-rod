const std = @import("std");
const lightning_rod = @import("lightning_rod");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const minecraft = @import("minecraft_model");
const entities = @import("entities");
const wire = @import("wire_1_21_5");
const replication = @import("replication");
const entity_packets = replication.entity_packets;
const Delivery = replication.delivery.Delivery;
const Visit = replication.visit.Visit;
const Tracking = replication.tracking.Tracking;
const bit_sets = lightning_rod.system.bit_sets;
const Experience = @import("experience.zig").Experience;
const State = @import("vanilla_player").experience_state.State;
const Players = @import("players").players.Players;
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const Streaming = @import("terrain").streaming.Streaming;
const assert = std.debug.assert;

/// What clients know of experience orbs. Tracking says who is to have each orb; this sends the
/// spawns and removals it asks for, and to whoever has an orb, its motion and value as they
/// change and its pickups before it goes.
pub const ExperienceReplication = struct {
    pub const id = "minecraft:experience_replication";
    pub const Configuration = struct {
        /// Pickups owed to clients at once; past it the oldest is let go, its clients seeing the
        /// orb go without it.
        pickup_events: usize = 1024,
        /// Keep a hash of every packet queued and whom to, for runs to be compared by.
        trace_sends: bool = false,
    };
    pub const Dependencies = struct { experience: *Experience, players: *Players, player_states: *PlayerStates, streaming: *Streaming, sessions: *sessions.Service, packets: *packets.Packets, tracking: *Tracking };

    /// What clients that have an orb were last sent of it.
    const Sent = struct { entity: entities.Id = 0, revision: u64 = 0, burning: bool = false };
    const Connection = struct { generation: u32 = 0, life: u32 = 0, world: u32 = 0, ready: bool = false, sent: ?State = null };
    const Event = struct { slot: u32 = 0, collector: i32 = 0 };
    const Phase = enum { spawn, position, metadata, whole, remove };
    /// An orb as it stands, for those that are not gone.
    const Live = struct { entity: entities.Id, orb: Experience.Orb, body: entities.State };

    deps: Dependencies,
    tracker: Tracking.TrackerId,
    /// A running hash of every packet asked to be sent and whom to, when tests trace it.
    traced: u64 = 0,
    tracing: bool,
    sent: entities.Array(Sent),
    words: usize,
    connections: []Connection,
    tracked: lightning_rod.system.IndexSet,
    events: []Event,
    /// Each event's clients still owed it, a row of words each.
    event_rows: []usize,
    event_slots: lightning_rod.system.IndexSet,
    first_event: usize = 0,
    event_span: usize = 0,
    rows: []usize,
    /// How an orb's packets go out to its audience, as every kind's do.
    delivery: Delivery,
    /// The orbs with anything to send this tick, as every kind finds them.
    visit: Visit,
    targets: []sessions.Service.Target,
    deliveries: []sessions.Service.Delivery,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*ExperienceReplication {
        if (config.pickup_events == 0) return error.InvalidExperienceCapacity;
        const self = try allocator.create(ExperienceReplication);
        const players = deps.players.records.len;
        const words = deps.tracking.row_words;
        self.* = .{
            .deps = deps,
            .tracker = undefined,
            .tracing = config.trace_sends,
            .sent = try .init(allocator, &deps.experience.deps.entities.pool),
            .words = words,
            .connections = try allocator.alloc(Connection, players),
            .tracked = try .init(allocator, players),
            .events = try allocator.alloc(Event, config.pickup_events),
            .event_rows = try allocator.alloc(usize, config.pickup_events * words),
            .event_slots = try .init(allocator, config.pickup_events),
            .rows = try allocator.alloc(usize, 5 * words),
            .targets = try allocator.alloc(sessions.Service.Target, players),
            .deliveries = try allocator.alloc(sessions.Service.Delivery, players),
            .delivery = undefined,
            .visit = try .init(allocator, deps.experience.deps.entities.directory.capacity()),
        };
        self.delivery = try .init(allocator, deps.players, deps.packets, deps.sessions);
        @memset(self.connections, .{});
        @memset(self.events, .{});
        @memset(self.event_rows, 0);
        self.tracker = try deps.tracking.register(.{ .kinds = Experience.kinds });
        return self;
    }

    fn row(self: *ExperienceReplication, index: usize) []usize {
        return self.rows[index * self.words ..][0..self.words];
    }

    fn set(self: *const ExperienceReplication, words: []const usize) bit_sets.Set {
        return .{ .words = words, .capacity = self.connections.len };
    }

    fn eventRow(self: *ExperienceReplication, at: usize) []usize {
        return self.event_rows[at * self.words ..][0..self.words];
    }

    fn put(words: []usize, player: usize, value: bool) void {
        const bit = @as(usize, 1) << @intCast(player % 64);
        if (value) words[player / 64] |= bit else words[player / 64] &= ~bit;
    }

    /// How many clients have an orb spawned, for tests.
    pub fn knownBy(self: *ExperienceReplication, entity: entities.Id) !usize {
        const slot = self.deps.experience.deps.entities.directory.slotOf(entity) orelse return 0;
        return self.deps.tracking.known(slot).count();
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
            const ready = player.stage == .ready and player.handle != null;
            if (connection.generation != generation or connection.life != player.life or connection.world != player.world or connection.ready != ready) {
                // A client that forgot what it was shown is owed no pickups.
                for (self.event_slots.values()) |index| put(self.eventRow(index), at, false);
                connection.* = .{ .generation = generation, .life = player.life, .world = player.world, .ready = ready };
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
        // Pickups, owed to whoever has the orb, before it goes for them.
        for (experience.pickups[0..experience.pickup_count]) |pickup| {
            const known = self.deps.tracking.known(pickup.slot);
            if (!known.any()) continue;
            if (self.event_span == self.events.len) {
                self.event_slots.remove(self.first_event);
                self.first_event = (self.first_event + 1) % self.events.len;
                self.event_span -= 1;
            }
            const at = (self.first_event + self.event_span) % self.events.len;
            self.event_span += 1;
            for (self.eventRow(at), 0..) |*word, index| word.* = known.wordAt(index);
            self.events[at] = .{ .slot = pickup.slot, .collector = pickup.collector };
            self.event_slots.insert(at);
        }
        try self.sendPickups();
        // Orbs gone, then those with anything to send, by id: an audience changed, their state
        // changed, or a viewer owed it whole. The rest have nothing to send, and are not looked at.
        var changes = self.deps.tracking.changesOf(self.tracker);
        while (changes.next()) |change| if (change.gone) try self.update(change.slot, null, change);
        for (experience.replicated.values()) |slot| self.visit.mark(@intCast(slot));
        experience.replicated.clear();
        const directory = &experience.deps.entities.directory;
        for (self.visit.collect(self.deps.tracking, self.tracker, directory, byId)) |slot| {
            const entry = directory.entry(slot);
            if (experience.orbs.slotOf(entry.id) != slot) continue;
            const stored = experience.orbs.ptr(slot);
            if (!stored.orb.alive) continue;
            const body = experience.deps.entities.body(slot) orelse return error.Corrupt;
            try self.update(slot, .{ .entity = entry.id, .orb = stored.orb, .body = body.* }, self.deps.tracking.changed(slot));
        }
        try self.sendSounds();
    }

    /// Orbs in the order they were walked by, their ids.
    fn byId(directory: *const entities.Directory, a: u32, b: u32) bool {
        return directory.entry(a).id < directory.entry(b).id;
    }

    fn sendPickups(self: *ExperienceReplication) !void {
        const blocked = self.row(0);
        @memset(blocked, 0);
        for (0..self.event_span) |event_offset| {
            const at = (self.first_event + event_offset) % self.events.len;
            if (!self.event_slots.contains(at)) continue;
            const event = self.events[at];
            const recipients = self.eventRow(at);
            var count: usize = 0;
            var remaining = self.set(recipients).iterator();
            while (remaining.next()) |player| {
                if (self.set(blocked).contains(player)) continue;
                if (self.deps.players.records[player].handle) |handle| {
                    self.targets[count] = .{ .handle = handle, .protocol = self.deps.players.records[player].protocol };
                    count += 1;
                } else put(recipients, player, false);
            }
            try self.deps.packets.fanout(writeCollect, self.targets[0..count], .{ entities.Entities.networkOfSlot(event.slot), event.collector }, 32, self.deliveries[0..count]);
            for (self.targets[0..count], self.deliveries[0..count]) |target, delivery| switch (delivery) {
                .queued, .closed => put(recipients, target.handle.index, false),
                .unsupported => {
                    self.deps.sessions.disconnect(target.handle);
                    put(recipients, target.handle.index, false);
                },
                .backpressured => put(blocked, target.handle.index, true),
            };
            if (!self.set(recipients).any()) self.event_slots.remove(at);
        }
        while (self.event_span > 0 and !self.event_slots.contains(self.first_event)) {
            self.first_event = (self.first_event + 1) % self.events.len;
            self.event_span -= 1;
        }
    }

    /// One orb: its removals, but not before a pickup a client is owed; its motion and value to
    /// whoever has it, whole to whoever missed some; then its spawns.
    fn update(self: *ExperienceReplication, slot: u32, live: ?Live, change: ?Tracking.Change) !void {
        const tracking = self.deps.tracking;
        const spawned = self.row(1);
        const removed = self.row(2);
        const pending = self.row(3);
        @memset(spawned, 0);
        @memset(removed, 0);
        if (change) |value| {
            // Whoever is still owed a pickup of the orb keeps it until then.
            for (pending, 0..) |*word, index| word.* = value.remove.wordAt(index);
            for (0..self.event_span) |event_offset| {
                const at = (self.first_event + event_offset) % self.events.len;
                if (!self.event_slots.contains(at) or self.events[at].slot != slot) continue;
                for (pending, self.eventRow(at)) |*word, owed| word.* &= ~owed;
            }
            try self.deliver(.remove, slot, live, pending, removed);
        }
        if (live) |orb| {
            try self.sent.ensureFilled(@as(usize, slot) + 1, .{});
            const sent = self.sent.at(slot);
            if (sent.entity != orb.entity) sent.* = .{ .entity = orb.entity, .revision = orb.orb.revision, .burning = orb.orb.fire > 0 };
            const known = tracking.known(slot);
            if (known.any()) {
                const stale = tracking.stale(slot);
                const missed = self.row(4);
                @memset(missed, 0);
                if (sent.revision != orb.orb.revision) {
                    for (pending, 0..) |*word, index| word.* = known.wordAt(index) & ~stale.wordAt(index) & ~removed[index];
                    try self.deliver(.position, slot, live, pending, missed);
                }
                if (sent.burning != (orb.orb.fire > 0)) {
                    for (pending, 0..) |*word, index| word.* = known.wordAt(index) & ~stale.wordAt(index) & ~removed[index];
                    try self.deliver(.metadata, slot, live, pending, missed);
                }
                if (any(missed)) tracking.missed(slot, self.set(missed));
                if (stale.any()) {
                    for (pending, 0..) |*word, index| word.* = stale.wordAt(index) & ~removed[index];
                    @memset(missed, 0);
                    try self.deliver(.whole, slot, live, pending, missed);
                    tracking.caughtUp(slot, self.set(missed));
                }
            }
            sent.revision = orb.orb.revision;
            sent.burning = orb.orb.fire > 0;
            if (change) |value| {
                for (pending, 0..) |*word, index| word.* = value.spawn.wordAt(index);
                try self.deliver(.spawn, slot, live, pending, spawned);
            }
        }
        if (change != null) tracking.confirm(slot, self.set(spawned), self.set(removed));
        // A viewer still owed it whole brings it back next tick.
        if (live != null and tracking.stale(slot).any()) self.visit.owe(slot) else self.visit.settle(slot);
    }

    fn any(words: []const usize) bool {
        for (words) |word| if (word != 0) return true;
        return false;
    }

    /// Sends one phase to the players in `audience_words`; those it was queued for, or whose
    /// session closed, go into `done`, but for a position or metadata, where `done` takes those
    /// it could not be queued for.
    fn deliver(self: *ExperienceReplication, comptime phase: Phase, slot: u32, live: ?Live, audience_words: []const usize, done: []usize) !void {
        const audience = self.set(audience_words);
        if (!audience.any()) return;
        const entity = entities.Entities.networkOfSlot(slot);
        const value = if (live) |orb| orb.orb.value else 0;
        if (self.tracing) {
            var hasher = std.hash.Wyhash.init(self.traced);
            hasher.update(std.mem.asBytes(&entity));
            hasher.update(&.{@backingInt(phase)});
            hasher.update(std.mem.asBytes(&value));
            var each = audience.iterator();
            while (each.next()) |player| if (self.deps.players.records[player].handle != null) hasher.update(std.mem.asBytes(&player));
            self.traced = hasher.final();
        }
        const delivery = &self.delivery;
        switch (phase) {
            .remove => try delivery.send(audience, writeRemove, .{entity}, 32),
            .spawn => {
                const orb = live.?;
                try delivery.sendGroup(audience, .{ entity_packets.spawn, writeValue }, .{ .{ entity, orb.body }, .{ entity, value, orb.orb.fire > 0 } }, &.{ 128, 32 });
            },
            .position => try delivery.send(audience, writePosition, .{ entity, live.?.body, live.?.orb.on_ground }, 128),
            .metadata => try delivery.send(audience, writeValue, .{ entity, value, live.?.orb.fire > 0 }, 32),
            .whole => {
                const orb = live.?;
                try delivery.sendGroup(audience, .{ writePosition, writeValue }, .{ .{ entity, orb.body, orb.orb.on_ground }, .{ entity, value, orb.orb.fire > 0 } }, &.{ 128, 32 });
            },
        }
        // A change's phases count whom they reached; a delta's, whom it missed.
        switch (phase) {
            .position, .metadata => delivery.markMissed(done),
            else => delivery.markReached(done),
        }
    }

    /// The level-up sounds players earned this tick, to those around who can see them.
    fn sendSounds(self: *ExperienceReplication) !void {
        const experience = self.deps.experience;
        const visibility = self.deps.streaming.snapshotVisibility();
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
