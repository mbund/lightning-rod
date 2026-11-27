//! Sends boats to the players who track them through the shared entity sync, as vanilla's
//! ServerEntity does: on EntityType's default interval of three ticks with deltas, as clients ease
//! a boat toward what they are sent, and its data as it changes.

const std = @import("std");
const entities = @import("entities");
const replication = @import("replication");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const Players = @import("players").players.Players;
const Boats = @import("boats.zig").Boats;

const Tracking = replication.tracking.Tracking;
const entity_sync = replication.entity_sync;

/// What vanilla synchronizes for a boat, in its entries' order: Entity's flags and frost,
/// VehicleEntity's wobble, AbstractBoat's paddles and bubble time.
const BoatData = struct {
    burning: bool = false,
    ticks_frozen: i32 = 0,
    hurt_time: i32 = 0,
    hurt_dir: i32 = 1,
    damage: f32 = 0,
    paddle_left: bool = false,
    paddle_right: bool = false,
    bubble_time: i32 = 0,
};

const Sync = entity_sync.EntitySync(BoatData, BoatReplication);

/// EntityType.Builder's default updateInterval, which boats keep.
const update_interval = 3;

pub const BoatReplication = struct {
    pub const id = "minecraft:boat_replication";
    pub const Configuration = struct {
        /// Keep a hash of every packet queued and of its viewers, for runs to be compared by.
        trace_sends: bool = false,
    };
    pub const Dependencies = struct { boats: *Boats, players: *Players, sessions: *sessions.Service, packets: *packets.Packets, tracking: *Tracking };

    deps: Dependencies,
    tracker: Tracking.TrackerId,
    sync: Sync,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*BoatReplication {
        const self = try allocator.create(BoatReplication);
        const owned = deps.boats.deps.entities;
        self.* = .{ .deps = deps, .tracker = try deps.tracking.register(.{ .kinds = deps.boats.kinds }), .sync = undefined };
        self.sync = try .init(allocator, .{ .trace_sends = config.trace_sends, .visits = true }, .{ .players = deps.players, .sessions = deps.sessions, .packets = deps.packets, .tracking = deps.tracking, .tracker = self.tracker, .pool = &owned.pool, .slots = owned.directory.capacity() }, .{
            .kind = self,
            .write_data = writeData,
            .body = body,
            .identity = identity,
            .before = byId,
            // A client eases a boat toward what it is sent: InterpolationHandler.
            .client = .{ .unpredictable = .{ .update_interval = update_interval } },
        });
        return self;
    }

    /// A running hash of every packet asked to be sent and whom to, when tests trace it.
    pub fn traced(self: *const BoatReplication) u64 {
        return self.sync.traced;
    }

    pub fn tick(self: *BoatReplication) !void {
        const boats = self.deps.boats;
        errdefer self.sync.abandon();
        // A crit's sparks go to whoever has the boat, before anything that could remove it.
        for (boats.animations[0..boats.animation_count]) |held| try self.sync.hold(held.slot, .{ .animation = held.animation });
        boats.animation_count = 0;
        try self.sync.begin();
        var changes = self.deps.tracking.changesOf(self.tracker);
        while (changes.next()) |change| if (change.gone) try self.sync.gone(change.slot);
        for (boats.replicated.values()) |slot| self.sync.mark(@intCast(slot));
        boats.replicated.clear();
        const directory = &boats.deps.entities.directory;
        for (self.sync.collect()) |slot| {
            const entry = directory.entry(slot);
            if (boats.boats.slotOf(entry.id) != slot) continue;
            const stored = boats.boats.ptr(slot);
            const boat = &stored.boat;
            if (boat.removed) continue;
            try self.sync.update(slot, .{
                .id = entry.id,
                .impulse = boat.impulse,
                .hurt_marked = boat.hurt_marked,
                .data = .{
                    .burning = boat.fire_ticks > 0,
                    .ticks_frozen = boat.ticks_frozen,
                    .hurt_time = boat.hurt_time,
                    .hurt_dir = boat.hurt_dir,
                    .damage = boat.damage,
                    .bubble_time = boat.bubble_time,
                },
                .changed = self.deps.tracking.changed(slot) != null,
            });
            boat.impulse = false;
            boat.hurt_marked = false;
        }
        try self.sync.finish();
    }

    /// Boats by id, the order they are walked in.
    fn byId(self: *BoatReplication, a: u32, b: u32) bool {
        const directory = &self.deps.boats.deps.entities.directory;
        return directory.entry(a).id < directory.entry(b).id;
    }
};

/// The entity data packet's entries for a boat, the same in every release.
fn writeData(_: *BoatReplication, entries: *entity_sync.Entries, data: BoatData, changes: Sync.DataChanges) !void {
    if (changes.contains(.burning)) try entries.putByte(0, if (data.burning) 1 else 0);
    if (changes.contains(.ticks_frozen)) try entries.putInt(7, data.ticks_frozen);
    if (changes.contains(.hurt_time)) try entries.putInt(8, data.hurt_time);
    if (changes.contains(.hurt_dir)) try entries.putInt(9, data.hurt_dir);
    if (changes.contains(.damage)) try entries.putFloat(10, data.damage);
    if (changes.contains(.paddle_left)) try entries.putBoolean(11, data.paddle_left);
    if (changes.contains(.paddle_right)) try entries.putBoolean(12, data.paddle_right);
    if (changes.contains(.bubble_time)) try entries.putInt(13, data.bubble_time);
}

fn identity(self: *BoatReplication, slot: u32) Sync.Identity {
    const state = self.deps.boats.deps.entities.body(slot).?;
    return .{ .uuid = state.uuid, .entity_type = state.kind };
}

fn body(self: *BoatReplication, slot: u32) Sync.Body {
    const state = self.deps.boats.deps.entities.body(slot).?;
    return .{
        .position = state.position,
        .velocity = state.velocity,
        .yaw = state.yaw,
        .pitch = state.pitch,
        .on_ground = self.deps.boats.boats.ptr(slot).boat.on_ground,
    };
}
