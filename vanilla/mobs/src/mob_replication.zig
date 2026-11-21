//! Sends mobs to the players who track them, as vanilla's ChunkMap.TrackedEntity and
//! ServerEntity do: a mob is paired with players within its tracking range who can see it, and
//! every tick its movement, rotation, head, data and events go to them, positions as deltas from
//! the last position sent.

const std = @import("std");
const lightning_rod = @import("lightning_rod");
const audience = @import("players").audience;
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const wire = @import("wire_1_21_5");
const packed_wire = @import("wire_1_21_9");
const Players = @import("players").players.Players;
const Streaming = @import("terrain").streaming.Streaming;
const mth = @import("vanilla_bodies").mth;
const living = @import("living.zig");
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

    fn of(mob: *const Mob) Data {
        return .{
            .burning = mob.fire_ticks > 0,
            .air = mob.air_supply,
            .dying = !mob.alive(),
            .ticks_frozen = mob.ticks_frozen,
            .health = mob.health,
            .baby = mob.baby(),
            .variant = mob.variant,
        };
    }
};

/// What a send reads of a mob: from its Mob, or from the herd while it idles.
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
    /// Where the mob stood when its audience was last worked out, which holds while neither it nor
    /// any player or what players see changes.
    audience_at: ?[3]f64 = null,
};

/// What a player was, as audiences last saw them.
const PlayerMark = struct { position: [3]f64 = .{ 0, 0, 0 }, world: u32 = 0, ready: bool = false };

const Connection = struct { generation: u32 = 0, life: u32 = 0, world: u32 = 0, ready: bool = false };

pub const MobReplication = struct {
    pub const id = "minecraft:mob_replication";
    pub const Configuration = struct { audience_words: usize = 4096 };
    pub const Dependencies = struct { mobs: *Mobs, players: *Players, streaming: *Streaming, sessions: *sessions.Service, packets: *packets.Packets };

    deps: Dependencies,
    views: []View,
    connections: []Connection,
    tracked: lightning_rod.system.IndexSet,
    marks: []PlayerMark,
    mark_count: usize = 0,
    /// A player's connection or world changed since audiences were last worked out.
    connections_changed: bool = false,
    /// Ticks replication has run.
    tick_count: u64 = 0,
    /// Ticks on which audiences had to be worked out again, for measuring.
    audience_changes: u64 = 0,
    known: audience.Matrix,
    scratch: audience.Matrix,
    targets: []sessions.Service.Target,
    deliveries: []sessions.Service.Delivery,
    /// Players the last delivery reached, by slot.
    sent: []usize,
    sent_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*MobReplication {
        const self = try allocator.create(MobReplication);
        const count = deps.mobs.mobs.len;
        self.* = .{
            .deps = deps,
            .views = try allocator.alloc(View, count),
            .connections = try allocator.alloc(Connection, deps.players.records.len),
            .tracked = try .init(allocator, deps.players.records.len),
            .marks = try allocator.alloc(PlayerMark, deps.players.records.len),
            .known = try .init(allocator, deps.players, count, config.audience_words, .recipients),
            .scratch = try .init(allocator, deps.players, 2, config.audience_words, .recipients),
            .targets = try allocator.alloc(sessions.Service.Target, deps.players.records.len),
            .deliveries = try allocator.alloc(sessions.Service.Delivery, deps.players.records.len),
            .sent = try allocator.alloc(usize, deps.players.records.len),
        };
        @memset(self.views, .{});
        @memset(self.connections, .{});
        @memset(self.marks, .{});
        return self;
    }

    pub fn tick(self: *MobReplication) !void {
        const mobs = self.deps.mobs;
        defer self.tick_count += 1;
        self.forgetChangedConnections();
        const visibility = self.deps.streaming.snapshotVisibility();
        const audience_changed = self.audienceChanged(visibility);
        if (audience_changed) self.audience_changes += 1;
        // Only cows idle.
        const idle_interval = mobs.traits(.cow).update_interval;
        // ChunkMap.tick goes through tracked entities by id, so packets leave in that order.
        for (0..mobs.herd.count) |place| {
            const index = mobs.herd.slots[place];
            if (index == @import("herd.zig").no_place) continue;
            // An idle mob that went through here once since it began idling changes nothing a viewer
            // sees but its head, nor do its viewers change, so it is sent from the herd alone.
            if (!audience_changed and mobs.herd.idling[place] and !mobs.herd.hot.fresh[place]) {
                const idle_view = &self.views[index];
                {
                    // Between send ticks there is nothing to look at.
                    if (self.tick_count % idle_interval != mobs.herd.still.send_phase[place]) continue;
                    const at = idle_view.audience_at.?;
                    assert(std.meta.eql(at, mobs.herd.still.position[place]));
                    try self.sendDue(self.known.row(index).view(), .{
                        .network_id = -@as(i32, @intCast(mobs.herd.still.id[place])),
                        .position = at,
                        .velocity = mobs.herd.still.velocity[place],
                        .yaw = mobs.herd.still.yaw[place],
                        .pitch = 0,
                        .head_yaw = mobs.herd.hot.head_yaw[place],
                        .on_ground = true,
                        .has_impulse = false,
                        .track_deltas = mobs.traits(.cow).track_deltas,
                    }, idle_view, idle_view.data, .{});
                    continue;
                }
            }
            const mob = &mobs.mobs[index];
            const view = &self.views[index];
            const known = self.known.row(index);
            if (view.id != mob.id) {
                assert(!known.view().any());
                view.* = start(mob);
                view.started = self.tick_count;
            }
            // Events first, so a death's puff arrives before the removal.
            if (mob.event_count > 0) {
                for (mob.events[0..mob.event_count]) |event| try self.deliver(known.view(), .{ .status = .{ .id = networkId(mob), .status = event } });
                mob.event_count = 0;
            }
            for (mob.damage_events[0..mob.damage_event_count]) |dealt| {
                // Players' network ids are their slots plus one, and the packet adds one more.
                const cause: i32 = if (dealt.attacker) |slot| @as(i32, @intCast(slot)) + 2 else 0;
                try self.deliver(known.view(), .{ .damage = .{ .id = networkId(mob), .type_id = mobs.damageTypeId(dealt.type), .cause = cause } });
            }
            mob.damage_event_count = 0;
            for (mob.animations[0..mob.animation_count]) |animation| try self.deliver(known.view(), .{ .animation = .{ .id = networkId(mob), .animation = animation } });
            mob.animation_count = 0;
            // The audience holds while neither the mob nor any player or what they see changed.
            const settled = !audience_changed and !mob.removed and view.audience_at != null and std.meta.eql(view.audience_at.?, mob.position);
            if (!settled) {
                const desired = self.scratch.row(0);
                if (mob.removed) desired.clear() else self.interest(mob, visibility, desired);
                const pending = self.scratch.row(1);
                pending.subtract(known.view(), desired.view());
                try self.deliver(pending.view(), .{ .remove = networkId(mob) });
                for (self.targetsSent()) |player| known.remove(player);
                pending.subtract(desired.view(), known.view());
                try self.pair(index, mob, view, pending);
                view.audience_at = mob.position;
            }
            // An idle mob's head turns in the herd.
            const head_yaw = if (mobs.idles(index)) mobs.herd.hot.head_yaw[mobs.herd.place_of[index]] else mob.head_yaw;
            try self.sendChanges(index, mob, view, head_yaw);
            if (mobs.idles(index)) {
                // From here the herd alone sends it, on the ticks its count says.
                mobs.herd.hot.fresh[place] = false;
                mobs.herd.still.send_phase[place] = @intCast(view.started % idle_interval);
            }
            if (mob.removed and !known.view().any()) {
                view.* = .{};
                mobs.release(@intCast(index));
            }
        }
    }

    /// Whether anything an audience depends on changed since last tick: a connection, a player's
    /// place or readiness, the set of players, or the columns any player sees.
    fn audienceChanged(self: *MobReplication, visibility: *const Streaming.Visibility) bool {
        var changed = self.connections_changed;
        self.connections_changed = false;
        if (visibility.reset.values().len != 0 or visibility.changed_words.values().len != 0) changed = true;
        const active = self.deps.players.activeSlots();
        if (active.len != self.mark_count) changed = true;
        self.mark_count = active.len;
        for (active) |slot| {
            const player = self.deps.players.records[slot];
            const mark: PlayerMark = .{ .position = .{ player.position.x, player.position.y, player.position.z }, .world = player.world, .ready = player.stage == .ready and player.handle != null };
            if (std.meta.eql(self.marks[slot], mark)) continue;
            self.marks[slot] = mark;
            changed = true;
        }
        return changed;
    }

    fn targetsSent(self: *const MobReplication) []const usize {
        return self.sent[0..self.sent_count];
    }

    /// Players whose connection or world changed forget every mob they were shown.
    fn forgetChangedConnections(self: *MobReplication) void {
        const mobs = self.deps.mobs;
        for (self.deps.players.activeSlots()) |at| self.tracked.insert(at);
        var cursor: usize = 0;
        while (cursor < self.tracked.values().len) {
            const at = self.tracked.values()[cursor];
            const player = self.deps.players.records[at];
            const connection = &self.connections[at];
            const generation = if (player.handle) |handle| handle.generation else 0;
            const ready = player.stage == .ready and player.handle != null;
            if (connection.generation != generation or connection.life != player.life or connection.world != player.world or connection.ready != ready) {
                for (mobs.active.values()) |index| self.known.row(index).remove(at);
                self.connections_changed = true;
                connection.* = .{ .generation = generation, .life = player.life, .world = player.world, .ready = ready };
            }
            if (player.handle == null) {
                self.tracked.remove(at);
                self.connections_changed = true;
                continue;
            }
            cursor += 1;
        }
    }

    /// ChunkMap.TrackedEntity.updatePlayer: players in the same world within the tracking range,
    /// measured horizontally, who can see the mob.
    fn interest(self: *MobReplication, mob: *const Mob, visibility: *const Streaming.Visibility, desired: audience.Row) void {
        desired.clear();
        const mobs = self.deps.mobs;
        const range: f64 = @floatFromInt(@as(u32, mobs.traits(mob.species).tracking_range) * 16);
        const view_range: f64 = @floatFromInt(self.deps.players.config.render_distance * 16);
        // Found at the farthest anyone sees, then narrowed to each player's own view distance.
        const farthest = @min(range, view_range);
        var nearby = self.deps.players.nearby(mob.world, .{ .x = mob.position[0], .y = mob.position[1], .z = mob.position[2] }, @intFromFloat(@ceil(farthest / 16) + 1));
        const own = living.box(mobs, mob);
        while (nearby.next()) |at| {
            const player = self.deps.players.records[at];
            if (player.handle == null or player.stage != .ready or player.world != mob.world) continue;
            const dx = player.position.x - mob.position[0];
            const dz = player.position.z - mob.position[2];
            const reach = @min(range, @as(f64, @floatFromInt(self.deps.players.viewDistanceOf(player) * 16)));
            if (dx * dx + dz * dz > reach * reach) continue;
            if (!visibility.boundsVisible(at, &player, mob.world, .{
                .minimum = .{ @intFromFloat(@floor(own.min[0])), @intFromFloat(@floor(own.min[1])), @intFromFloat(@floor(own.min[2])) },
                .maximum = .{ @intFromFloat(@ceil(own.max[0])), @intFromFloat(@ceil(own.max[1])), @intFromFloat(@ceil(own.max[2])) },
            })) continue;
            desired.insert(at);
        }
    }

    fn start(mob: *const Mob) View {
        return .{
            .id = mob.id,
            .base = mob.position,
            .yaw = mth.packDegrees(mob.yaw),
            .pitch = mth.packDegrees(mob.pitch),
            .head_yaw = mth.packDegrees(mob.head_yaw),
            .velocity = mob.velocity,
            .was_on_ground = mob.on_ground,
            .data = Data.of(mob),
        };
    }

    /// ServerEntity.sendPairingData: the mob as last sent, and its data that differs from the
    /// defaults.
    fn pair(self: *MobReplication, index: usize, mob: *const Mob, view: *const View, recipients: audience.Row) !void {
        const entity_type = self.deps.mobs.traits(mob.species).entity_type;
        try self.deliver(recipients.view(), .{ .spawn = .{ .id = networkId(mob), .uuid = mob.uuid, .kind = entity_type, .position = view.base, .velocity = view.velocity, .yaw = view.yaw, .pitch = view.pitch, .head_yaw = view.head_yaw } });
        const known = self.known.row(index);
        for (self.targetsSent()) |player| known.insert(player);
        const defaults: Data = .{};
        const data = view.data;
        var changes: Changes = .{};
        changes.burning = data.burning != defaults.burning;
        changes.air = data.air != defaults.air;
        changes.dying = data.dying != defaults.dying;
        changes.ticks_frozen = data.ticks_frozen != defaults.ticks_frozen;
        changes.health = data.health != defaults.health;
        changes.baby = data.baby != defaults.baby;
        changes.variant = data.variant != defaults.variant;
        if (changes.any()) try self.deliver(recipients.view(), .{ .metadata = .{ .id = networkId(mob), .data = data, .changes = changes } });
    }

    /// ServerEntity.sendChanges.
    fn sendChanges(self: *MobReplication, index: usize, mob: *Mob, view: *View, head_yaw: f32) !void {
        const known = self.known.row(index).view();
        const now = Data.of(mob);
        const changes = Changes.between(view.data, now);
        const interval = self.deps.mobs.traits(mob.species).update_interval;
        if ((self.tick_count - view.started) % interval == 0 or mob.has_impulse or changes.any()) {
            try self.sendDue(known, .{
                .network_id = networkId(mob),
                .position = mob.position,
                .velocity = mob.velocity,
                .yaw = mob.yaw,
                .pitch = mob.pitch,
                .head_yaw = head_yaw,
                .on_ground = mob.on_ground,
                .has_impulse = mob.has_impulse,
                .track_deltas = self.deps.mobs.traits(mob.species).track_deltas,
            }, view, now, changes);
            mob.has_impulse = false;
        }
        // A hurt mob's new motion goes out at once, whatever the interval.
        if (mob.hurt_marked) {
            mob.hurt_marked = false;
            try self.deliver(known, .{ .velocity = .{ .id = networkId(mob), .velocity = mob.velocity } });
        }
    }

    fn sendDue(self: *MobReplication, known: lightning_rod.system.bit_sets.Set, subject: Subject, view: *View, now: Data, changes: Changes) !void {
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
                try self.deliver(known, .{ .velocity = .{ .id = subject.network_id, .velocity = view.velocity } });
            }
        }
        const id_value = subject.network_id;
        const short: [3]i16 = .{ @truncate(encoded[0]), @truncate(encoded[1]), @truncate(encoded[2]) };
        switch (movement) {
            .none => {},
            .sync => try self.deliver(known, .{ .sync = .{ .id = id_value, .position = subject.position, .velocity = subject.velocity, .yaw = subject.yaw, .pitch = subject.pitch, .on_ground = subject.on_ground } }),
            .position => try self.deliver(known, .{ .relative = .{ .id = id_value, .delta = short, .on_ground = subject.on_ground } }),
            .rotation => try self.deliver(known, .{ .look = .{ .id = id_value, .yaw = yaw, .pitch = pitch, .on_ground = subject.on_ground } }),
            .both => try self.deliver(known, .{ .move_look = .{ .id = id_value, .delta = short, .yaw = yaw, .pitch = pitch, .on_ground = subject.on_ground } }),
        }
        if (changes.any()) {
            try self.deliver(known, .{ .metadata = .{ .id = id_value, .data = now, .changes = changes } });
            view.data = now;
        }
        if (sent_position) view.base = subject.position;
        if (sent_rotation) {
            view.yaw = yaw;
            view.pitch = pitch;
        }
        const head = mth.packDegrees(subject.head_yaw);
        if (@abs(@as(i32, head) - view.head_yaw) >= 1) {
            try self.deliver(known, .{ .head = .{ .id = id_value, .yaw = head } });
            view.head_yaw = head;
        }
    }

    /// Sends a packet to a set of players, noting in `sent` who got it.
    fn deliver(self: *MobReplication, recipients: lightning_rod.system.bit_sets.Set, outgoing: Outgoing) !void {
        var iterator = recipients.iterator();
        var count: usize = 0;
        while (iterator.next()) |player| {
            const handle = self.deps.players.records[player].handle orelse continue;
            self.targets[count] = .{ .handle = handle, .protocol = self.deps.players.records[player].protocol };
            count += 1;
        }
        self.sent_count = 0;
        if (count == 0) return;
        const targets = self.targets[0..count];
        const deliveries = self.deliveries[0..count];
        const encoder = self.deps.packets;
        switch (outgoing) {
            .status => |value| try encoder.fanout(writeStatus, targets, .{ value.id, value.status }, 32, deliveries),
            .remove => |value| try encoder.fanout(writeRemove, targets, .{value}, 32, deliveries),
            .spawn => |value| try encoder.fanout(.{ spawnLegacy, spawnPacked }, targets, .{value}, 128, deliveries),
            .metadata => |value| try encoder.fanout(Metadata.write, targets, .{ value.id, value.data, value.changes }, 128, deliveries),
            .velocity => |value| try encoder.fanout(.{ writeVelocityLegacy, writeVelocityPacked }, targets, .{ value.id, value.velocity }, 64, deliveries),
            .sync => |value| try encoder.fanout(writeSync, targets, .{ value.id, value.position, value.velocity, value.yaw, value.pitch, value.on_ground }, 128, deliveries),
            .relative => |value| try encoder.fanout(writeRelative, targets, .{ value.id, value.delta, value.on_ground }, 32, deliveries),
            .look => |value| try encoder.fanout(writeLook, targets, .{ value.id, value.yaw, value.pitch, value.on_ground }, 32, deliveries),
            .move_look => |value| try encoder.fanout(writeMoveLook, targets, .{ value.id, value.delta, value.yaw, value.pitch, value.on_ground }, 32, deliveries),
            .head => |value| try encoder.fanout(writeHead, targets, .{ value.id, value.yaw }, 32, deliveries),
            .damage => |value| try encoder.fanout(writeDamage, targets, .{ value.id, value.type_id, value.cause }, 32, deliveries),
            .animation => |value| try encoder.fanout(writeAnimation, targets, .{ value.id, value.animation }, 32, deliveries),
        }
        for (targets, deliveries) |target, delivery| switch (delivery) {
            .queued, .closed => {
                self.sent[self.sent_count] = target.handle.index;
                self.sent_count += 1;
            },
            .unsupported => self.deps.sessions.disconnect(target.handle),
            .backpressured => {},
        };
    }
};

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

/// Negative entity ids, as items and orbs use, since players take the small positive ones.
pub fn networkId(mob: *const Mob) i32 {
    return -@as(i32, @intCast(mob.id));
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
