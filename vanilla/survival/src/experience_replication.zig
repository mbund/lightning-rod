const std = @import("std");
const lightning_rod = @import("lightning_rod");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const minecraft = @import("minecraft_model");
const entities = @import("entities");
const wire = @import("wire_1_21_5");
const replication = @import("replication");
const Tracking = replication.tracking.Tracking;
const Experience = @import("experience.zig").Experience;
const State = @import("vanilla_player").experience_state.State;
const Players = @import("players").players.Players;
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const Streaming = @import("terrain").streaming.Streaming;

const entity_sync = replication.entity_sync;

/// What an orb synchronizes: its flags, of which only burning changes, and its value.
const OrbData = struct {
    burning: bool = false,
    value: i32 = 0,
};

const Sync = entity_sync.EntitySync(OrbData, ExperienceReplication);

/// EntityType.EXPERIENCE_ORB's trackingTickInterval.
const update_interval = 20;

/// What clients know of experience orbs, through the shared entity sync: tracking says who is to
/// have each orb, and the sync sends its spawns, removals, motion and value as ServerEntity does,
/// and its pickups before it goes. Players' own experience bars and level-up sounds go out here
/// too.
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

    /// What a client was last sent of its own experience, as of which connection.
    const Connection = struct { generation: u32 = 0, life: u32 = 0, world: u32 = 0, ready: bool = false, sent: ?State = null };

    deps: Dependencies,
    tracker: Tracking.TrackerId,
    sync: Sync,
    connections: []Connection,
    tracked: lightning_rod.system.IndexSet,
    targets: []sessions.Service.Target,
    deliveries: []sessions.Service.Delivery,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*ExperienceReplication {
        const self = try allocator.create(ExperienceReplication);
        const players = deps.players.records.len;
        const owned = deps.experience.deps.entities;
        self.* = .{
            .deps = deps,
            .tracker = try deps.tracking.register(.{ .kinds = Experience.kinds }),
            .sync = undefined,
            .connections = try allocator.alloc(Connection, players),
            .tracked = try .init(allocator, players),
            .targets = try allocator.alloc(sessions.Service.Target, players),
            .deliveries = try allocator.alloc(sessions.Service.Delivery, players),
        };
        self.sync = try .init(allocator, .{ .events = config.pickup_events, .trace_sends = config.trace_sends, .visits = true }, .{ .players = deps.players, .sessions = deps.sessions, .packets = deps.packets, .tracking = deps.tracking, .pool = &owned.pool, .slots = owned.directory.capacity() }, .{
            .kind = self,
            .write_data = writeData,
            .body = body,
            .identity = identity,
            .before = byId,
            .update_interval = update_interval,
        });
        @memset(self.connections, .{});
        return self;
    }

    /// A running hash of every packet asked to be sent and whom to, when tests trace it.
    pub fn traced(self: *const ExperienceReplication) u64 {
        return self.sync.traced;
    }

    /// How many clients have an orb spawned, for tests.
    pub fn knownBy(self: *ExperienceReplication, entity: entities.Id) !usize {
        const slot = self.deps.experience.deps.entities.directory.slotOf(entity) orelse return 0;
        return self.deps.tracking.known(slot).count();
    }

    pub fn tick(self: *ExperienceReplication) !void {
        const experience = self.deps.experience;
        errdefer self.sync.abandon();
        try self.sendExperience();
        // Pickups, owed to whoever has the orb, before it goes for them.
        for (experience.pickups[0..experience.pickup_count]) |pickup| try self.sync.hold(pickup.slot, .{ .collect = .{ .collector = pickup.collector, .count = 1 } });
        try self.sync.begin();
        // Orbs gone, then those with anything to send, by id.
        var changes = self.deps.tracking.changesOf(self.tracker);
        while (changes.next()) |change| if (change.gone) try self.sync.gone(change.slot);
        for (experience.replicated.values()) |slot| self.sync.mark(@intCast(slot));
        experience.replicated.clear();
        const directory = &experience.deps.entities.directory;
        for (self.sync.collect(self.tracker)) |slot| {
            const entry = directory.entry(slot);
            if (experience.orbs.slotOf(entry.id) != slot) continue;
            const stored = experience.orbs.ptr(slot);
            if (!stored.orb.alive) continue;
            try self.sync.update(slot, .{
                .id = entry.id,
                .data = .{ .burning = stored.orb.fire > 0, .value = stored.orb.value },
                .changed = self.deps.tracking.changed(slot) != null,
            });
        }
        try self.sync.finish();
        try self.sendSounds();
    }

    fn writeData(_: *ExperienceReplication, entries: *entity_sync.Entries, data: OrbData, changes: Sync.DataChanges) !void {
        if (changes.contains(.burning)) try entries.putByte(0, if (data.burning) 1 else 0);
        if (changes.contains(.value)) try entries.putInt(8, data.value);
    }

    fn identity(self: *ExperienceReplication, slot: u32) Sync.Identity {
        const state = self.deps.experience.deps.entities.body(slot).?;
        return .{ .uuid = state.uuid, .entity_type = state.kind };
    }

    fn body(self: *ExperienceReplication, slot: u32) Sync.Body {
        const state = self.deps.experience.deps.entities.body(slot).?;
        return .{
            .position = state.position,
            .velocity = state.velocity,
            .yaw = state.yaw,
            .pitch = state.pitch,
            .on_ground = self.deps.experience.orbs.ptr(slot).orb.on_ground,
        };
    }

    /// Orbs in the order they were walked by, their ids.
    fn byId(self: *ExperienceReplication, a: u32, b: u32) bool {
        const directory = &self.deps.experience.deps.entities.directory;
        return directory.entry(a).id < directory.entry(b).id;
    }

    /// Each player's experience bar, when it changed or the client is new to it.
    fn sendExperience(self: *ExperienceReplication) !void {
        for (self.deps.players.activeSlots()) |at| self.tracked.insert(at);
        var tracked_offset: usize = 0;
        while (tracked_offset < self.tracked.values().len) {
            const at = self.tracked.values()[tracked_offset];
            const player = self.deps.players.records[at];
            const connection = &self.connections[at];
            const generation = if (player.handle) |handle| handle.generation else 0;
            const ready = player.stage == .ready and player.handle != null;
            if (connection.generation != generation or connection.life != player.life or connection.world != player.world or connection.ready != ready) {
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
