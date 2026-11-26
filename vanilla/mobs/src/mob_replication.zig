//! Sends mobs to the players who track them, as vanilla's ChunkMap.TrackedEntity and
//! ServerEntity do, through the shared entity sync: mobs say what they synchronize and what each
//! is now, in the tick order, and an idle one only on the ticks its interval falls.

const std = @import("std");
const entities = @import("entities");
const replication = @import("replication");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const Players = @import("players").players.Players;
const mob_state = @import("mob.zig");
const mobs_module = @import("mobs.zig");
const Mobs = mobs_module.Mobs;

const Tracking = replication.tracking.Tracking;
const Mob = mob_state.Mob;

/// The data vanilla synchronizes for a cow, in its entries' order.
const CowData = struct {
    burning: bool = false,
    air: i32 = 300,
    dying: bool = false,
    ticks_frozen: i32 = 0,
    health: f32 = 1,
    baby: bool = false,
    variant: u8 = default_variant,

    fn of(mob: Mob) CowData {
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

const entity_sync = replication.entity_sync;
const Sync = entity_sync.EntitySync(CowData, MobReplication);

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

pub const MobReplication = struct {
    pub const id = "minecraft:mob_replication";
    pub const Configuration = struct {
        /// Keep a hash of every packet queued and of its viewers, for runs to be compared by.
        trace_sends: bool = false,
    };
    pub const Dependencies = struct { mobs: *Mobs, players: *Players, sessions: *sessions.Service, packets: *packets.Packets, tracking: *Tracking };

    deps: Dependencies,
    sync: Sync,
    /// The mob being sent, as its body and identity are read: whole, or an idle cow from its row.
    reading: Reading = .{ .idle = undefined },
    /// What went wrong holding events early, from inside the mobs' tick, told at the next tick.
    failure: ?anyerror = null,
    /// Ticks on which some mob's audience changed, for measuring.
    audience_changes: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*MobReplication {
        const self = try allocator.create(MobReplication);
        self.* = .{
            .deps = deps,
            .sync = undefined,
        };
        // Cows are the one species: their interval and deltas stand for every mob.
        const cow = deps.mobs.traits(.cow);
        self.sync = try .init(allocator, .{ .trace_sends = config.trace_sends }, .{ .players = deps.players, .sessions = deps.sessions, .packets = deps.packets, .tracking = deps.tracking, .pool = &deps.mobs.deps.entities.pool }, .{
            .kind = self,
            .write_data = writeData,
            .body = body,
            .identity = identity,
            // A client eases a mob toward what it is sent, and its AI is the server's alone.
            .client = .{ .unpredictable = .{ .update_interval = cow.update_interval, .track_deltas = cow.track_deltas } },
        });
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

    /// A running hash of every packet asked to be sent and whom to, when tests trace it.
    pub fn traced(self: *const MobReplication) u64 {
        return self.sync.traced;
    }

    pub fn tick(self: *MobReplication) !void {
        const mobs = self.deps.mobs;
        const tracking = self.deps.tracking;
        errdefer self.sync.abandon();
        if (self.failure) |err| return err;
        // What befell mobs goes first, in order, to those who knew them as it did: a death's
        // puff arrives before the removal.
        try self.holdEvents();
        try self.sync.begin();
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
                if (self.sync.tick_count % idle_interval != state.send_phase) continue;
                self.reading = .{ .idle = mob_row };
                try self.sync.update(index, .{ .id = mob_row.field("entity").id, .data = null, .changed = false });
                continue;
            }
            try self.send(index, change != null);
        }
        try self.sync.finish();
        if (changed) self.audience_changes += 1;
    }

    /// One mob's tick of ChunkMap.TrackedEntity and ServerEntity.
    fn send(self: *MobReplication, index: u32, changed: bool) !void {
        const mobs = self.deps.mobs;
        const mob = try mobs.inSlot(index);
        self.reading = .{ .whole = mob };
        try self.sync.update(index, .{
            .id = mob.entity.id,
            .impulse = mob.entity.has_impulse,
            .hurt_marked = mob.entity.hurt_marked,
            .data = CowData.of(mob),
            .changed = changed,
        });
        mob.entity.has_impulse = false;
        mob.entity.hurt_marked = false;
        const state = mobs.trackingOf(index);
        if (state.idling) {
            // From here its idle group alone sends it, on the ticks its count says.
            state.fresh = false;
            state.send_phase = @intCast(self.sync.started(index) % mobs.traits(.cow).update_interval);
        }
        if (mob.entity.removed and !self.deps.tracking.known(index).any()) {
            try self.sync.forget(index);
            try mobs.release(@intCast(index));
        }
    }

    /// What befell mobs since the events were last taken, held for those who know each mob now.
    fn holdEvents(self: *MobReplication) !void {
        const mobs = self.deps.mobs;
        for (mobs.takeEvents()) |event| {
            std.debug.assert(mobs.rows.ref(event.slot).field("entity").id == event.id);
            try self.sync.hold(event.slot, switch (event.what) {
                .status => |status| .{ .status = status },
                // Players' network ids are their slots plus one, and the packet adds one more.
                .damage => |dealt| .{ .damage = .{ .type_id = mobs.damageTypeId(dealt.type), .cause = if (dealt.attacker) |slot| @as(i32, @intCast(slot)) + 2 else 0 } },
                .animation => |animation| .{ .animation = animation },
            });
        }
    }

    /// More befell mobs in a tick than the mobs hold: what is held moves to the sync now.
    fn eventsFull(context: *anyopaque) void {
        const self: *MobReplication = @ptrCast(@alignCast(context));
        self.holdEvents() catch |err| {
            self.failure = err;
        };
    }
};

/// How the mob being sent is read: a mob in full, or an idle cow from its idle group alone, on
/// the ground and looking level.
const Reading = union(enum) {
    whole: Mob,
    idle: mobs_module.Table.Ref,
};

/// The entity data packet's entries for a cow. 26.1 put age_locked before the variant, which
/// moved it from index 17 to 18.
fn writeData(_: *MobReplication, entries: *entity_sync.Entries, data: CowData, changes: Sync.DataChanges) !void {
    if (changes.contains(.burning)) try entries.putByte(0, if (data.burning) 1 else 0);
    if (changes.contains(.air)) try entries.putInt(1, data.air);
    if (changes.contains(.dying)) try entries.putPose(6, if (data.dying) 7 else 0);
    if (changes.contains(.ticks_frozen)) try entries.putInt(7, data.ticks_frozen);
    if (changes.contains(.health)) try entries.putFloat(9, data.health);
    if (changes.contains(.baby)) try entries.putBoolean(16, data.baby);
    if (changes.contains(.variant)) try entries.putCowVariant(if (entries.protocol >= 775) 18 else 17, data.variant);
}

fn identity(self: *MobReplication, _: u32) Sync.Identity {
    return switch (self.reading) {
        .whole => |mob| .{ .uuid = mob.entity.uuid, .entity_type = self.deps.mobs.traits(mob.entity.species).entity_type },
        .idle => |row| .{ .uuid = row.field("entity").uuid, .entity_type = self.deps.mobs.traits(.cow).entity_type },
    };
}

fn body(self: *MobReplication, _: u32) Sync.Body {
    return switch (self.reading) {
        .whole => |mob| .{
            .position = mob.motion.position,
            .velocity = mob.motion.velocity,
            .yaw = mob.motion.yaw,
            .pitch = mob.motion.pitch,
            .head_yaw = mob.idle.head_yaw,
            .on_ground = mob.motion.on_ground,
        },
        .idle => |row| .{
            .position = row.field("motion").position,
            .velocity = row.field("motion").velocity,
            .yaw = row.field("motion").yaw,
            .pitch = 0,
            .head_yaw = row.field("idle").head_yaw,
            .on_ground = true,
        },
    };
}
