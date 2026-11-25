//! Sends mobs to the players who track them, as vanilla's ChunkMap.TrackedEntity and
//! ServerEntity do: a mob is paired with players within its tracking range who can see it, and
//! every tick its movement, rotation, head, data and events go to them, positions as deltas from
//! the last position sent.

const std = @import("std");
const entities = @import("entities");
const lightning_rod = @import("lightning_rod");
const Tracking = @import("replication").tracking.Tracking;
const Delivery = @import("replication").delivery.Delivery;
/// Mobs' deltas, by the slot of the mob each is of: whom each missed is owed the mob whole.
const Batch = @import("replication").delivery.Batch(u32);
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const wire = @import("wire_1_21_5");
const packed_wire = @import("wire_1_21_9");
const Players = @import("players").players.Players;
const mth = @import("vanilla_bodies").mth;
const mob_state = @import("mob.zig");
const Mobs = @import("mobs.zig").Mobs;

const Mob = mob_state.Mob;
const assert = std.debug.assert;

/// The data vanilla synchronizes for a cow, as last sent.
const Data = struct {
    burning: bool = false,
    air: i32 = 300,
    dying: bool = false,
    ticks_frozen: i32 = 0,
    health: f32 = 1,
    baby: bool = false,
    variant: u8 = default_variant,

    fn of(mob: Mob) Data {
        return .{
            .burning = mob.entity.fire_ticks > 0,
            .air = mob.living.air_supply,
            .dying = !mob.alive(),
            .ticks_frozen = mob.entity.ticks_frozen,
            .health = mob.living.health,
            .baby = mob.baby(),
            .variant = mob.cow.variant,
        };
    }
};

/// What a send reads of a mob: from its Mob, or from its idle group while it idles.
const Subject = struct {
    network_id: i32,
    position: [3]f64,
    velocity: [3]f64,
    yaw: f32,
    pitch: f32,
    head_yaw: f32,
    on_ground: bool,
    has_impulse: bool,
    track_deltas: bool,
};

/// CowVariants.TEMPERATE, the variant a cow has unless it spawned elsewhere.
pub const default_variant: u8 = variant: {
    @setEvalBranchQuota(1_000_000);
    const game_data = @import("game_data");
    for (game_data.registry.named_registries) |named| {
        if (!std.mem.eql(u8, named.name, "minecraft:cow_variant")) continue;
        for (named.entries, 0..) |entry, index| if (std.mem.eql(u8, entry, "minecraft:temperate")) break :variant index;
    }
    unreachable;
};

/// ServerEntity's state for one mob.
const View = struct {
    id: u64 = 0,
    /// VecDeltaCodec's base, the position deltas are measured from.
    base: [3]f64 = .{ 0, 0, 0 },
    yaw: i8 = 0,
    pitch: i8 = 0,
    head_yaw: i8 = 0,
    velocity: [3]f64 = .{ 0, 0, 0 },
    /// The replication tick the view began, so ServerEntity.tickCount is the ticks since.
    started: u64 = 0,
    teleport_delay: u32 = 0,
    was_on_ground: bool = false,
    data: Data = .{},
};

pub const MobReplication = struct {
    pub const id = "minecraft:mob_replication";
    pub const Configuration = struct {
        /// Keep a hash of every packet queued and of its viewers, for runs to be compared by.
        trace_sends: bool = false,
    };
    pub const Dependencies = struct { mobs: *Mobs, players: *Players, sessions: *sessions.Service, packets: *packets.Packets, tracking: *Tracking };

    deps: Dependencies,
    /// What each mob's viewers were last sent, by slot: held while it is sent, then let go.
    /// By mob slot, what each mob's viewers were last sent, in the pool, and not written out with
    /// the mob.
    views: entities.Array(View),
    /// Ticks replication has run.
    tick_count: u64 = 0,
    /// What went wrong sending events early, from inside the mobs' tick, told at the next tick.
    failure: ?anyerror = null,
    /// Ticks on which some mob's audience changed, for measuring.
    audience_changes: u64 = 0,
    /// Room for rows of players: those spawned, removed, behind, and sent a delta.
    rows: []usize,
    words: usize,
    /// Players a delivery could not be queued for, who then need the mob whole.
    missed: []usize,
    missed_any: bool = false,
    /// Room for those a queued delta could not go to at all.
    owed: []usize,
    /// How a mob's packets go out, as every kind's do: whom the last reached and missed.
    delivery: Delivery,
    /// Deltas of mobs that go to the same players, admitted for all of them at once. Whatever
    /// goes out alone sends them first, so each player has its packets in the order they came.
    batch: Batch,
    /// A running hash of every packet asked to be sent and whom to, when tests trace it.
    traced: u64 = 0,
    tracing: bool,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*MobReplication {
        const self = try allocator.create(MobReplication);
        const words = deps.tracking.row_words;
        self.* = .{
            .deps = deps,
            .views = try .init(allocator, &deps.mobs.deps.entities.pool),
            .rows = try allocator.alloc(usize, 4 * words),
            .words = words,
            .missed = try allocator.alloc(usize, words),
            .owed = try allocator.alloc(usize, words),
            .delivery = try .init(allocator, deps.players, deps.packets, deps.sessions),
            .batch = try .init(allocator, deps.players, deps.packets, deps.sessions, words),
            .tracing = config.trace_sends,
        };
        @memset(self.missed, 0);
        deps.mobs.events_full = .{ .context = self, .call = eventsFull };
        // A tracker for each range species track at, so every range is exact.
        const mobs = deps.mobs;
        var done: [256]bool = @splat(false);
        for (mobs.species, 0..) |traits, at| {
            if (done[traits.tracking_range]) continue;
            done[traits.tracking_range] = true;
            var kinds: entities.Kinds = .{};
            for (mobs.species[at..]) |other| if (other.tracking_range == traits.tracking_range) kinds.bits.set(other.entity_type);
            _ = try deps.tracking.register(.{ .kinds = kinds });
        }
        return self;
    }

    /// A mob's view, in memory until let go, made empty if it had none.
    fn viewOf(self: *MobReplication, index: u32) !*View {
        try self.views.ensureFilled(@as(usize, index) + 1, .{});
        return self.views.at(index);
    }

    fn row(self: *MobReplication, at: usize) []usize {
        return self.rows[at * self.words ..][0..self.words];
    }

    fn set(self: *const MobReplication, words: []const usize) lightning_rod.system.bit_sets.Set {
        return .{ .words = words, .capacity = self.deps.players.records.len };
    }

    fn put(words: []usize, player: usize) void {
        words[player / 64] |= @as(usize, 1) << @intCast(player % 64);
    }

    /// Who has the mob and is not behind: who its deltas go to.
    fn current(self: *MobReplication, index: u32) lightning_rod.system.bit_sets.Set {
        const known = self.deps.tracking.known(index);
        const stale = self.deps.tracking.stale(index);
        const words = self.row(3);
        for (words, 0..) |*word, at| word.* = known.wordAt(at) & ~stale.wordAt(at);
        return self.set(words);
    }

    /// Deltas some players could not take: they need the mob whole.
    fn noteMissed(self: *MobReplication, index: u32) void {
        if (!self.missed_any) return;
        self.deps.tracking.missed(index, self.set(self.missed));
        @memset(self.missed, 0);
        self.missed_any = false;
    }

    pub fn tick(self: *MobReplication) !void {
        const mobs = self.deps.mobs;
        const tracking = self.deps.tracking;
        defer self.tick_count += 1;
        errdefer self.batch.abandon();
        if (self.failure) |err| return err;
        // What befell mobs goes first, in order, to those who knew them as it did: a death's
        // puff arrives before the removal.
        try self.sendEvents();
        @memset(self.missed, 0);
        self.missed_any = false;
        // Only cows idle.
        const idle_interval = mobs.traits(.cow).update_interval;
        var changed = false;
        // Mobs in the tick order's order, then the rest by id, so packets leave in that order.
        const count = try mobs.collectOrder();
        for (0..count) |at_order| {
            const index = mobs.ordered.at(at_order).*;
            const mob_row = mobs.rows.ref(index);
            const state = mob_row.field("tracking");
            const change = tracking.changed(index);
            if (change != null) changed = true;

            // An idle mob that went through here once since it began idling changes nothing a viewer
            // sees but its head, nor do its viewers change, so it is sent from its idle group alone.
            if (change == null and state.idling and !state.fresh and !tracking.stale(index).any()) {
                // Between send ticks there is nothing to look at.
                if (self.tick_count % idle_interval != state.send_phase) continue;
                const motion = mob_row.field("motion");
                const idle_view = try self.viewOf(index);
                try self.sendDue(index, self.current(index), .{
                    .network_id = entities.Entities.networkOfSlot(index),
                    .position = motion.position,
                    .velocity = motion.velocity,
                    .yaw = motion.yaw,
                    .pitch = 0,
                    .head_yaw = mob_row.field("idle").head_yaw,
                    .on_ground = true,
                    .has_impulse = false,
                    .track_deltas = mobs.traits(.cow).track_deltas,
                }, idle_view, idle_view.data, .{});
                self.noteMissed(index);
                continue;
            }
            try self.send(index, change);
        }
        try self.flushQueued();
        if (changed) self.audience_changes += 1;
    }

    /// One mob's tick of ChunkMap.TrackedEntity and ServerEntity: who tracking says should see it
    /// and who no longer, and what changed.
    fn send(self: *MobReplication, index: u32, change: ?Tracking.Change) !void {
        const mobs = self.deps.mobs;
        const tracking = self.deps.tracking;
        const idle_interval = mobs.traits(.cow).update_interval;
        const mob = try mobs.inSlot(index);
        const view = try self.viewOf(index);
        if (view.id != mob.entity.id) {
            assert(!tracking.known(index).any());
            view.* = start(mob);
            view.started = self.tick_count;
        }
        if (change) |value| {
            const spawned = self.row(0);
            const removed = self.row(1);
            @memset(spawned, 0);
            @memset(removed, 0);
            try self.deliver(value.remove, .{ .remove = networkId(self.deps.mobs, mob) });
            for (self.targetsSent()) |player| put(removed, player);
            try self.pair(mob, view, value.spawn, spawned);
            tracking.confirm(index, self.set(spawned), self.set(removed));
            @memset(self.missed, 0);
            self.missed_any = false;
        }
        try self.sendChanges(index, mob, view, mob.idle.head_yaw);
        self.noteMissed(index);
        try self.catchUp(index, mob, view);
        const state = mobs.trackingOf(index);
        if (state.idling) {
            // From here its idle group alone sends it, on the ticks its count says.
            state.fresh = false;
            state.send_phase = @intCast(view.started % idle_interval);
        }
        if (mob.entity.removed and !tracking.known(index).any()) {
            // Its deltas settle by its slot, so they go before the slot does.
            try self.flushQueued();
            self.views.at(index).* = .{};
            try mobs.release(@intCast(index));
        }
    }

    /// Players that missed a delta get the mob as last sent to everyone: where it is, its data
    /// and its head.
    fn catchUp(self: *MobReplication, index: u32, mob: Mob, view: *const View) !void {
        const stale = self.deps.tracking.stale(index);
        if (!stale.any()) return;
        const id_value = networkId(self.deps.mobs, mob);
        try self.deliver(stale, .{ .sync = .{ .id = id_value, .position = view.base, .velocity = view.velocity, .yaw = unpack(view.yaw), .pitch = unpack(view.pitch), .on_ground = view.was_on_ground } });
        const caught = self.row(0);
        @memset(caught, 0);
        for (self.targetsSent()) |player| put(caught, player);
        const changes = Changes.between(.{}, view.data);
        if (changes.any()) try self.deliver(self.set(caught), .{ .metadata = .{ .id = id_value, .data = view.data, .changes = changes } });
        try self.deliver(self.set(caught), .{ .head = .{ .id = id_value, .yaw = view.head_yaw } });
        self.deps.tracking.caughtUp(index, self.set(caught));
        @memset(self.missed, 0);
        self.missed_any = false;
    }

    fn targetsSent(self: *const MobReplication) []const usize {
        return self.delivery.reachedPlayers();
    }

    fn start(mob: Mob) View {
        return .{
            .id = mob.entity.id,
            .base = mob.motion.position,
            .yaw = mth.packDegrees(mob.motion.yaw),
            .pitch = mth.packDegrees(mob.motion.pitch),
            .head_yaw = mth.packDegrees(mob.idle.head_yaw),
            .velocity = mob.motion.velocity,
            .was_on_ground = mob.motion.on_ground,
            .data = Data.of(mob),
        };
    }

    /// ServerEntity.sendPairingData: the mob as last sent, and its data that differs from the
    /// defaults. Those the spawn was queued for go into `spawned`.
    fn pair(self: *MobReplication, mob: Mob, view: *const View, recipients: lightning_rod.system.bit_sets.Set, spawned: []usize) !void {
        const entity_type = self.deps.mobs.traits(mob.entity.species).entity_type;
        const id_value = networkId(self.deps.mobs, mob);
        try self.deliver(recipients, .{ .spawn = .{ .id = id_value, .uuid = mob.entity.uuid, .kind = entity_type, .position = view.base, .velocity = view.velocity, .yaw = view.yaw, .pitch = view.pitch, .head_yaw = view.head_yaw } });
        for (self.targetsSent()) |player| put(spawned, player);
        const changes = Changes.between(.{}, view.data);
        if (changes.any()) try self.deliver(recipients, .{ .metadata = .{ .id = id_value, .data = view.data, .changes = changes } });
    }

    fn unpack(angle: i8) f32 {
        return @as(f32, @floatFromInt(angle)) * 360.0 / 256.0;
    }

    /// ServerEntity.sendChanges.
    fn sendChanges(self: *MobReplication, index: u32, mob: Mob, view: *View, head_yaw: f32) !void {
        const known = self.current(index);
        const now = Data.of(mob);
        const changes = Changes.between(view.data, now);
        const interval = self.deps.mobs.traits(mob.entity.species).update_interval;
        if ((self.tick_count - view.started) % interval == 0 or mob.entity.has_impulse or changes.any()) {
            try self.sendDue(index, known, .{
                .network_id = networkId(self.deps.mobs, mob),
                .position = mob.motion.position,
                .velocity = mob.motion.velocity,
                .yaw = mob.motion.yaw,
                .pitch = mob.motion.pitch,
                .head_yaw = head_yaw,
                .on_ground = mob.motion.on_ground,
                .has_impulse = mob.entity.has_impulse,
                .track_deltas = self.deps.mobs.traits(mob.entity.species).track_deltas,
            }, view, now, changes);
            mob.entity.has_impulse = false;
        }
        // A hurt mob's new motion goes out at once, whatever the interval.
        if (mob.entity.hurt_marked) {
            mob.entity.hurt_marked = false;
            try self.queue(index, known, .{ .velocity = .{ .id = networkId(self.deps.mobs, mob), .velocity = mob.motion.velocity } });
        }
    }

    /// What befell mobs since the events were last sent, in the order it did, each to those who
    /// know its mob. A mob's slot holds it until its viewers hear it went.
    fn sendEvents(self: *MobReplication) !void {
        const mobs = self.deps.mobs;
        for (mobs.takeEvents()) |event| {
            const mob = try mobs.inSlot(event.slot);
            assert(mob.entity.id == event.id);
            const known = self.deps.tracking.known(event.slot);
            if (!known.any()) continue;
            switch (event.what) {
                .status => |status| try self.deliver(known, .{ .status = .{ .id = networkId(self.deps.mobs, mob), .status = status } }),
                .damage => |dealt| {
                    // Players' network ids are their slots plus one, and the packet adds one more.
                    const cause: i32 = if (dealt.attacker) |slot| @as(i32, @intCast(slot)) + 2 else 0;
                    try self.deliver(known, .{ .damage = .{ .id = networkId(self.deps.mobs, mob), .type_id = mobs.damageTypeId(dealt.type), .cause = cause } });
                },
                .animation => |animation| try self.deliver(known, .{ .animation = .{ .id = networkId(self.deps.mobs, mob), .animation = animation } }),
            }
        }
    }

    /// More befell mobs in a tick than the mobs hold: what is held goes now, in order, as
    /// vanilla sends each as it happens.
    fn eventsFull(context: *anyopaque) void {
        const self: *MobReplication = @ptrCast(@alignCast(context));
        self.sendEvents() catch |err| {
            self.failure = err;
        };
    }

    fn sendDue(self: *MobReplication, index: u32, known: lightning_rod.system.bit_sets.Set, subject: Subject, view: *View, now: Data, changes: Changes) !void {
        const yaw = mth.packDegrees(subject.yaw);
        const pitch = mth.packDegrees(subject.pitch);
        const turned = @abs(@as(i32, yaw) - view.yaw) >= 1 or @abs(@as(i32, pitch) - view.pitch) >= 1;
        view.teleport_delay += 1;
        // A mob where it was last sent moved by nothing, which spares the rounding.
        const encoded: [3]i64 = if (std.meta.eql(subject.position, view.base)) .{ 0, 0, 0 } else .{ encode(subject.position[0]) - encode(view.base[0]), encode(subject.position[1]) - encode(view.base[1]), encode(subject.position[2]) - encode(view.base[2]) };
        const delta: [3]f64 = .{ @as(f64, @floatFromInt(encoded[0])) / 4096.0, @as(f64, @floatFromInt(encoded[1])) / 4096.0, @as(f64, @floatFromInt(encoded[2])) / 4096.0 };
        const moved = delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2] >= @as(f64, @as(f32, 7.6293945e-6));
        const position_due = moved or (self.tick_count - view.started) % 60 == 0;
        var sent_position = false;
        var sent_rotation = false;
        const far = for (encoded) |component| {
            if (component < -32768 or component > 32767) break true;
        } else false;
        const Movement = enum { none, sync, position, rotation, both };
        var movement: Movement = .none;
        if (far or view.teleport_delay > 400 or view.was_on_ground != subject.on_ground) {
            view.was_on_ground = subject.on_ground;
            view.teleport_delay = 0;
            movement = .sync;
            sent_position = true;
            sent_rotation = true;
        } else if (!position_due or !turned) {
            if (position_due) {
                movement = .position;
                sent_position = true;
            } else if (turned) {
                movement = .rotation;
                sent_rotation = true;
            }
        } else {
            movement = .both;
            sent_position = true;
            sent_rotation = true;
        }
        if (subject.has_impulse or subject.track_deltas) {
            const difference: [3]f64 = .{ subject.velocity[0] - view.velocity[0], subject.velocity[1] - view.velocity[1], subject.velocity[2] - view.velocity[2] };
            const squared = difference[0] * difference[0] + difference[1] * difference[1] + difference[2] * difference[2];
            const length = subject.velocity[0] * subject.velocity[0] + subject.velocity[1] * subject.velocity[1] + subject.velocity[2] * subject.velocity[2];
            if (squared > 1.0e-7 or (squared > 0 and length == 0)) {
                view.velocity = subject.velocity;
                try self.queue(index, known, .{ .velocity = .{ .id = subject.network_id, .velocity = view.velocity } });
            }
        }
        const id_value = subject.network_id;
        const short: [3]i16 = .{ @truncate(encoded[0]), @truncate(encoded[1]), @truncate(encoded[2]) };
        switch (movement) {
            .none => {},
            .sync => try self.queue(index, known, .{ .sync = .{ .id = id_value, .position = subject.position, .velocity = subject.velocity, .yaw = subject.yaw, .pitch = subject.pitch, .on_ground = subject.on_ground } }),
            .position => try self.queue(index, known, .{ .relative = .{ .id = id_value, .delta = short, .on_ground = subject.on_ground } }),
            .rotation => try self.queue(index, known, .{ .look = .{ .id = id_value, .yaw = yaw, .pitch = pitch, .on_ground = subject.on_ground } }),
            .both => try self.queue(index, known, .{ .move_look = .{ .id = id_value, .delta = short, .yaw = yaw, .pitch = pitch, .on_ground = subject.on_ground } }),
        }
        if (changes.any()) {
            try self.queue(index, known, .{ .metadata = .{ .id = id_value, .data = now, .changes = changes } });
            view.data = now;
        }
        if (sent_position) view.base = subject.position;
        if (sent_rotation) {
            view.yaw = yaw;
            view.pitch = pitch;
        }
        const head = mth.packDegrees(subject.head_yaw);
        if (@abs(@as(i32, head) - view.head_yaw) >= 1) {
            try self.queue(index, known, .{ .head = .{ .id = id_value, .yaw = head } });
            view.head_yaw = head;
        }
    }

    /// Sends a packet to a set of players now, noting who got it and who missed it: what was
    /// queued goes first.
    fn deliver(self: *MobReplication, recipients: lightning_rod.system.bit_sets.Set, outgoing: Outgoing) !void {
        try self.flushQueued();
        const delivery = &self.delivery;
        if (!recipients.any()) {
            delivery.reached_count = 0;
            delivery.missed_count = 0;
            return;
        }
        self.traceSend(recipients, outgoing);
        switch (outgoing) {
            .status => |value| try delivery.send(recipients, writeStatus, .{ value.id, value.status }, 32),
            .remove => |value| try delivery.send(recipients, writeRemove, .{value}, 32),
            .spawn => |value| try delivery.send(recipients, .{ spawnLegacy, spawnPacked }, .{value}, 128),
            .metadata => |value| try delivery.send(recipients, Metadata.write, .{ value.id, value.data, value.changes }, 128),
            .velocity => |value| try delivery.send(recipients, .{ writeVelocityLegacy, writeVelocityPacked }, .{ value.id, value.velocity }, 64),
            .sync => |value| try delivery.send(recipients, writeSync, .{ value.id, value.position, value.velocity, value.yaw, value.pitch, value.on_ground }, 128),
            .relative => |value| try delivery.send(recipients, writeRelative, .{ value.id, value.delta, value.on_ground }, 32),
            .look => |value| try delivery.send(recipients, writeLook, .{ value.id, value.yaw, value.pitch, value.on_ground }, 32),
            .move_look => |value| try delivery.send(recipients, writeMoveLook, .{ value.id, value.delta, value.yaw, value.pitch, value.on_ground }, 32),
            .head => |value| try delivery.send(recipients, writeHead, .{ value.id, value.yaw }, 32),
            .damage => |value| try delivery.send(recipients, writeDamage, .{ value.id, value.type_id, value.cause }, 32),
            .animation => |value| try delivery.send(recipients, writeAnimation, .{ value.id, value.animation }, 32),
        }
        for (delivery.missedPlayers()) |player| {
            put(self.missed, player);
            self.missed_any = true;
        }
    }

    /// Folds a packet asked to be sent, and whom to, into the trace when tests ask for one.
    fn traceSend(self: *MobReplication, recipients: lightning_rod.system.bit_sets.Set, outgoing: Outgoing) void {
        if (!self.tracing) return;
        var hasher = std.hash.Wyhash.init(self.traced);
        hasher.update(std.mem.asBytes(&self.tick_count));
        hasher.update(&.{@backingInt(outgoing)});
        switch (outgoing) {
            inline else => |value| trace(&hasher, value),
        }
        var who = recipients.iterator();
        while (who.next()) |player| hasher.update(std.mem.asBytes(&player));
        self.traced = hasher.final();
    }

    /// Queues a delta of the mob in a slot for a set of players, with others for the same players:
    /// whom it misses learn so when the batch goes, and are owed the mob whole.
    fn queue(self: *MobReplication, slot: u32, recipients: lightning_rod.system.bit_sets.Set, outgoing: Outgoing) !void {
        if (!recipients.any()) return;
        self.traceSend(recipients, outgoing);
        // Room the batch lacks sends what it holds; a second miss means its players have none.
        for (0..2) |_| {
            switch (try self.batch.prepare(recipients, 1, self, settleQueued)) {
                .ready => {},
                // None of them playing yet, or none with room: they are owed it all the same.
                .nobody, .backpressured => break,
            }
            const sent = switch (outgoing) {
                .metadata => |value| try self.batch.send(slot, Metadata.write, .{ value.id, value.data, value.changes }, 128),
                .velocity => |value| try self.batch.send(slot, .{ writeVelocityLegacy, writeVelocityPacked }, .{ value.id, value.velocity }, 64),
                .sync => |value| try self.batch.send(slot, writeSync, .{ value.id, value.position, value.velocity, value.yaw, value.pitch, value.on_ground }, 128),
                .relative => |value| try self.batch.send(slot, writeRelative, .{ value.id, value.delta, value.on_ground }, 32),
                .look => |value| try self.batch.send(slot, writeLook, .{ value.id, value.yaw, value.pitch, value.on_ground }, 32),
                .move_look => |value| try self.batch.send(slot, writeMoveLook, .{ value.id, value.delta, value.yaw, value.pitch, value.on_ground }, 32),
                .head => |value| try self.batch.send(slot, writeHead, .{ value.id, value.yaw }, 32),
                else => unreachable,
            };
            if (sent) return;
            try self.flushQueued();
        }
        // Nothing went: those in a session are owed the mob whole.
        @memset(self.owed, 0);
        var each = recipients.iterator();
        while (each.next()) |player| if (self.deps.players.records[player].handle != null) put(self.owed, player);
        self.deps.tracking.missed(slot, self.set(self.owed));
    }

    /// What a queued delta of the mob in a slot reached: whom it missed are behind.
    fn settleQueued(self: *MobReplication, slot: u32, accepted: lightning_rod.system.bit_sets.Set, _: usize) !void {
        const missed = self.batch.missedOf(accepted);
        if (missed.any()) self.deps.tracking.missed(slot, missed);
    }

    /// Sends what is queued.
    fn flushQueued(self: *MobReplication) !void {
        try self.batch.flush(self, settleQueued);
    }
};

/// Hashes a value field by field, so padding and an empty optional's payload are left out.
fn trace(hasher: *std.hash.Wyhash, value: anytype) void {
    switch (@typeInfo(@TypeOf(value))) {
        .@"struct" => |info| inline for (info.field_names) |name| trace(hasher, @field(value, name)),
        .array => for (value) |item| trace(hasher, item),
        .optional => if (value) |inner| {
            hasher.update(&.{1});
            trace(hasher, inner);
        } else hasher.update(&.{0}),
        .@"union" => switch (value) {
            inline else => |inner, tag| {
                hasher.update(&.{@backingInt(tag)});
                trace(hasher, inner);
            },
        },
        .bool => hasher.update(&.{@intFromBool(value)}),
        else => hasher.update(std.mem.asBytes(&value)),
    }
}

/// A packet to some of a mob's viewers.
const Outgoing = union(enum) {
    status: struct { id: i32, status: u8 },
    remove: i32,
    spawn: Spawn,
    metadata: struct { id: i32, data: Data, changes: Changes },
    velocity: struct { id: i32, velocity: [3]f64 },
    sync: struct { id: i32, position: [3]f64, velocity: [3]f64, yaw: f32, pitch: f32, on_ground: bool },
    relative: struct { id: i32, delta: [3]i16, on_ground: bool },
    look: struct { id: i32, yaw: i8, pitch: i8, on_ground: bool },
    move_look: struct { id: i32, delta: [3]i16, yaw: i8, pitch: i8, on_ground: bool },
    head: struct { id: i32, yaw: i8 },
    damage: struct { id: i32, type_id: i32, cause: i32 },
    animation: struct { id: i32, animation: u8 },
};

/// The id clients know a mob in memory by.
pub fn networkId(mobs: *const Mobs, mob: Mob) i32 {
    return mobs.deps.entities.networkOf(mob.entity.id).?;
}

/// VecDeltaCodec.encode.
fn encode(value: f64) i64 {
    return @intFromFloat(@round(value * 4096.0));
}

const Changes = packed struct {
    burning: bool = false,
    air: bool = false,
    dying: bool = false,
    ticks_frozen: bool = false,
    health: bool = false,
    baby: bool = false,
    variant: bool = false,

    fn any(self: Changes) bool {
        return @as(u7, @bitCast(self)) != 0;
    }

    fn between(before: Data, after: Data) Changes {
        return .{
            .burning = before.burning != after.burning,
            .air = before.air != after.air,
            .dying = before.dying != after.dying,
            .ticks_frozen = before.ticks_frozen != after.ticks_frozen,
            .health = before.health != after.health,
            .baby = before.baby != after.baby,
            .variant = before.variant != after.variant,
        };
    }

    fn count(self: Changes) usize {
        return @popCount(@as(u7, @bitCast(self)));
    }
};

const Spawn = struct {
    id: i32,
    uuid: u128,
    kind: u32,
    position: [3]f64,
    velocity: [3]f64,
    yaw: i8,
    pitch: i8,
    head_yaw: i8,
};

fn spawnLegacy(packet: wire.play.toClient.packet_spawn_entity.Writer, registry: packets.Registry, spawn: Spawn) ![]u8 {
    const positioned = try (try (try (try (try (try packet.entityId(spawn.id)).objectUUID(spawn.uuid)).type(try registry.entityId(@intCast(spawn.kind)))).x(spawn.position[0])).y(spawn.position[1])).z(spawn.position[2]);
    const data = try (try (try (try positioned.pitch(spawn.pitch)).yaw(spawn.yaw)).headPitch(spawn.head_yaw)).objectData(0);
    var velocity = try data.velocity();
    return (try velocity.advance(try packets.nested(.{writeShortVelocity}).write(try velocity.begin(), spawn.velocity))).finish();
}

fn writeShortVelocity(packet: wire.vec3i16.Writer, motion: [3]f64) !wire.vec3i16.Writer.Done {
    return (try (try packet.x(shortVelocity(motion[0]))).y(shortVelocity(motion[1]))).z(shortVelocity(motion[2]));
}

fn shortVelocity(value: f64) i16 {
    return @intFromFloat(std.math.clamp(value, -3.9, 3.9) * 8000);
}

fn spawnPacked(packet: packed_wire.play.toClient.packet_spawn_entity.Writer, registry: packets.Registry, spawn: Spawn) ![]u8 {
    const positioned = try (try (try (try (try (try packet.entityId(spawn.id)).objectUUID(spawn.uuid)).type(try registry.entityId(@intCast(spawn.kind)))).x(spawn.position[0])).y(spawn.position[1])).z(spawn.position[2]);
    const rotated = try (try (try (try positioned.velocity(.{ .x = spawn.velocity[0], .y = spawn.velocity[1], .z = spawn.velocity[2] })).pitch(spawn.pitch)).yaw(spawn.yaw)).headPitch(spawn.head_yaw);
    return (try rotated.objectData(0)).finish();
}

/// The entity data packet for a cow. 26.1 put age_locked before the variant, which moved it from
/// index 17 to 18.
const Metadata = struct {
    const Values = struct { data: Data, changes: Changes, variant_key: u8 };

    fn Entry(comptime Value: type) type {
        return struct { key: u8, value: Value };
    }

    fn write(packet: wire.play.toClient.packet_entity_metadata.Writer, id_value: i32, data: Data, changes: Changes) ![]u8 {
        var metadata = try (try packet.entityId(id_value)).metadata();
        const variant_key: u8 = if (packet.layoutProtocol() >= 775) 18 else 17;
        const done = try packets.nested(.{entries}).write(try metadata.begin(), .{ .data = data, .changes = changes, .variant_key = variant_key });
        return (try metadata.advance(done)).finish();
    }

    fn entries(packet: wire.entityMetadata.Writer, values: Values) !wire.entityMetadata.Writer.Done {
        const data = values.data;
        const changes = values.changes;
        const variant_key = values.variant_key;
        var list = try packet.value(changes.count());
        if (changes.burning) try list.advance(try packets.nested(.{byteEntry}).write((try list.next()).?, .{ .key = 0, .value = @as(i8, if (data.burning) 1 else 0) }));
        if (changes.air) try list.advance(try packets.nested(.{intEntry}).write((try list.next()).?, .{ .key = 1, .value = data.air }));
        if (changes.dying) try list.advance(try packets.nested(.{poseEntry}).write((try list.next()).?, .{ .key = 6, .value = @as(i32, if (data.dying) 7 else 0) }));
        if (changes.ticks_frozen) try list.advance(try packets.nested(.{intEntry}).write((try list.next()).?, .{ .key = 7, .value = data.ticks_frozen }));
        if (changes.health) try list.advance(try packets.nested(.{floatEntry}).write((try list.next()).?, .{ .key = 9, .value = data.health }));
        if (changes.baby) try list.advance(try packets.nested(.{booleanEntry}).write((try list.next()).?, .{ .key = 16, .value = data.baby }));
        if (changes.variant) try list.advance(try packets.nested(.{variantEntry}).write((try list.next()).?, .{ .key = variant_key, .value = @as(i32, data.variant) }));
        return list.finish();
    }

    fn byteEntry(packet: wire.entityMetadataEntry.cases.value.byte.Writer, entry: Entry(i8)) !wire.entityMetadataEntry.cases.value.byte.Writer.Done {
        return (try (try packet.key(entry.key)).type()).value(entry.value);
    }
    fn intEntry(packet: wire.entityMetadataEntry.cases.value.int.Writer, entry: Entry(i32)) !wire.entityMetadataEntry.cases.value.int.Writer.Done {
        return (try (try packet.key(entry.key)).type()).value(entry.value);
    }
    fn floatEntry(packet: wire.entityMetadataEntry.cases.value.float.Writer, entry: Entry(f32)) !wire.entityMetadataEntry.cases.value.float.Writer.Done {
        return (try (try packet.key(entry.key)).type()).value(entry.value);
    }
    fn booleanEntry(packet: wire.entityMetadataEntry.cases.value.boolean.Writer, entry: Entry(bool)) !wire.entityMetadataEntry.cases.value.boolean.Writer.Done {
        return (try (try packet.key(entry.key)).type()).value(entry.value);
    }
    fn poseEntry(packet: wire.entityMetadataEntry.cases.value.pose.Writer, entry: Entry(i32)) !wire.entityMetadataEntry.cases.value.pose.Writer.Done {
        return (try (try packet.key(entry.key)).type()).value(entry.value);
    }
    fn variantEntry(packet: wire.entityMetadataEntry.cases.value.cow_variant.Writer, entry: Entry(i32)) !wire.entityMetadataEntry.cases.value.cow_variant.Writer.Done {
        return (try (try packet.key(entry.key)).type()).value(entry.value);
    }
};

fn writeRelative(packet: wire.play.toClient.packet_rel_entity_move.Writer, id_value: i32, delta: [3]i16, on_ground: bool) ![]u8 {
    return (try (try (try (try (try packet.entityId(id_value)).dX(delta[0])).dY(delta[1])).dZ(delta[2])).onGround(on_ground)).finish();
}

fn writeLook(packet: wire.play.toClient.packet_entity_look.Writer, id_value: i32, yaw: i8, pitch: i8, on_ground: bool) ![]u8 {
    return (try (try (try (try packet.entityId(id_value)).yaw(yaw)).pitch(pitch)).onGround(on_ground)).finish();
}

fn writeMoveLook(packet: wire.play.toClient.packet_entity_move_look.Writer, id_value: i32, delta: [3]i16, yaw: i8, pitch: i8, on_ground: bool) ![]u8 {
    return (try (try (try (try (try (try (try packet.entityId(id_value)).dX(delta[0])).dY(delta[1])).dZ(delta[2])).yaw(yaw)).pitch(pitch)).onGround(on_ground)).finish();
}

fn writeSync(packet: wire.play.toClient.packet_sync_entity_position.Writer, id_value: i32, position: [3]f64, velocity: [3]f64, yaw: f32, pitch: f32, on_ground: bool) ![]u8 {
    const positioned = try (try (try (try packet.entityId(id_value)).x(position[0])).y(position[1])).z(position[2]);
    const moving = try (try (try positioned.dx(velocity[0])).dy(velocity[1])).dz(velocity[2]);
    return (try (try (try moving.yaw(yaw)).pitch(pitch)).onGround(on_ground)).finish();
}

fn writeVelocityLegacy(packet: wire.play.toClient.packet_entity_velocity.Writer, id_value: i32, velocity: [3]f64) ![]u8 {
    var value = try (try packet.entityId(id_value)).velocity();
    return (try value.advance(try packets.nested(.{writeShortVelocity}).write(try value.begin(), velocity))).finish();
}

fn writeVelocityPacked(packet: packed_wire.play.toClient.packet_entity_velocity.Writer, id_value: i32, velocity: [3]f64) ![]u8 {
    return (try (try packet.entityId(id_value)).velocity(.{ .x = velocity[0], .y = velocity[1], .z = velocity[2] })).finish();
}

fn writeHead(packet: wire.play.toClient.packet_entity_head_rotation.Writer, id_value: i32, head: i8) ![]u8 {
    return (try (try packet.entityId(id_value)).headYaw(head)).finish();
}

fn writeAnimation(packet: wire.play.toClient.packet_animation.Writer, id_value: i32, animation: u8) ![]u8 {
    return (try (try packet.entityId(id_value)).animation(animation)).finish();
}

fn writeStatus(packet: wire.play.toClient.packet_entity_status.Writer, id_value: i32, status: u8) ![]u8 {
    return (try (try packet.entityId(id_value)).entityStatus(@bitCast(status))).finish();
}

fn writeRemove(packet: wire.play.toClient.packet_entity_destroy.Writer, id_value: i32) ![]u8 {
    const ids = try packet.entityIds(1);
    const entry = try ids.element(id_value);
    return (try entry.finish()).finish();
}

/// ClientboundDamageEventPacket. The cause and the direct cause are the same here, and no
/// damage mobs take has a position of its own.
fn writeDamage(packet: wire.play.toClient.packet_damage_event.Writer, id_value: i32, type_id: i32, cause: i32) ![]u8 {
    const typed = try (try (try (try packet.entityId(id_value)).sourceTypeId(type_id)).sourceCauseId(cause)).sourceDirectId(cause);
    var position = try typed.sourcePosition();
    return (try position.advance(try (try position.begin()).none())).finish();
}
