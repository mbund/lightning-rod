//! Projectiles as players see them, through the shared entity sync: tracking says who is to have
//! each, and the sync sends their spawns, removals, motion and data as ServerEntity does, and
//! their pickups before they go. Projectiles say from their tick which changed or were pushed;
//! a sleeper is shown where its plan has it.

const std = @import("std");
const entities = @import("entities");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const replication = @import("replication");
const Players = @import("players").players.Players;
const Tracking = replication.tracking.Tracking;
const Projectiles = @import("projectiles.zig").Projectiles;

const entity_sync = replication.entity_sync;

/// AbstractArrow's entity data: its flags, how many it pierces, whether it is stuck, and a
/// trident's loyalty and glint.
const ArrowData = struct {
    critical: bool = false,
    pierce: u8 = 0,
    in_ground: bool = false,
    loyalty: u8 = 0,
    foil: bool = false,
};

const Sync = entity_sync.EntitySync(ArrowData, ProjectileReplication);

pub const ProjectileReplication = struct {
    pub const id = "minecraft:projectile_replication";
    pub const Configuration = struct {
        /// Keep a hash of every packet asked to be sent and whom to, for runs to be compared by.
        trace_sends: bool = false,
    };
    pub const Dependencies = struct { projectiles: *Projectiles, tracking: *Tracking, players: *Players, sessions: *sessions.Service, packets: *packets.Packets, entities: *entities.Entities };

    deps: Dependencies,
    sync: Sync,
    /// The projectile being sent, as its body and identity are read.
    reading: Projectiles.Shown = undefined,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*ProjectileReplication {
        const self = try allocator.create(ProjectileReplication);
        self.* = .{ .deps = deps, .sync = undefined };
        try deps.projectiles.track(deps.tracking);
        self.sync = try .init(allocator, .{ .trace_sends = config.trace_sends, .visits = true }, .{ .players = deps.players, .sessions = deps.sessions, .packets = deps.packets, .tracking = deps.tracking, .pool = &deps.entities.pool, .slots = deps.entities.directory.capacity() }, .{
            .kind = self,
            .write_data = writeData,
            .body = body,
            .identity = identity,
            .before = byId,
            .update_interval = Projectiles.update_interval,
        });
        return self;
    }

    /// A running hash of every packet asked to be sent and whom to, when tests trace it.
    pub fn traced(self: *const ProjectileReplication) u64 {
        return self.sync.traced;
    }

    pub fn tick(self: *ProjectileReplication) !void {
        const projectiles = self.deps.projectiles;
        const tracking = self.deps.tracking;
        errdefer self.sync.abandon();
        for (projectiles.pickups[0..projectiles.pickup_count]) |pickup| try self.sync.hold(pickup.slot, .{ .collect = .{ .collector = pickup.collector, .count = 1 } });
        projectiles.pickup_count = 0;
        try self.sync.begin();
        var changes = tracking.changesOf(projectiles.tracker);
        while (changes.next()) |change| if (change.gone) try self.sync.gone(change.slot);
        for (projectiles.replicated.values()) |slot| self.sync.mark(@intCast(slot));
        projectiles.replicated.clear();
        defer projectiles.impulses.clear();
        const directory = &self.deps.entities.directory;
        for (self.sync.collect(projectiles.tracker)) |slot| {
            const entry = directory.entry(slot);
            if (entry.id == 0 or entry.retired or !projectiles.holds(slot)) continue;
            const seen = (try projectiles.shown(slot)) orelse continue;
            self.reading = seen;
            try self.sync.update(slot, .{
                .id = entry.id,
                .has_impulse = projectiles.impulses.contains(slot),
                .data = .{
                    .critical = seen.data.critical,
                    .pierce = seen.data.pierce,
                    .in_ground = seen.data.in_ground,
                    .loyalty = if (seen.data.trident) |trident| trident.loyalty else 0,
                    .foil = if (seen.data.trident) |trident| trident.foil else false,
                },
                .changed = tracking.changed(slot) != null,
                .age = seen.age,
                // Stuck, it stays as it is until something knocks it loose, which marks it.
                .resting = seen.in_ground,
            });
        }
        try self.sync.finish();
    }

    /// Projectiles in id order, the order they were walked by.
    fn byId(self: *ProjectileReplication, a: u32, b: u32) bool {
        const directory = &self.deps.entities.directory;
        return directory.entry(a).id < directory.entry(b).id;
    }

    fn writeData(_: *ProjectileReplication, entries: *entity_sync.Entries, data: ArrowData, changes: Sync.DataChanges) !void {
        if (changes.contains(.critical)) try entries.putByte(8, @intFromBool(data.critical));
        if (changes.contains(.pierce)) try entries.putByte(9, @intCast(data.pierce));
        if (changes.contains(.in_ground)) try entries.putBoolean(10, data.in_ground);
        if (changes.contains(.loyalty)) try entries.putByte(11, @intCast(data.loyalty));
        if (changes.contains(.foil)) try entries.putBoolean(12, data.foil);
    }

    fn identity(self: *ProjectileReplication, _: u32) Sync.Identity {
        return .{ .uuid = self.reading.uuid, .entity_type = self.reading.entity_type, .object_data = self.reading.owner };
    }

    fn body(self: *ProjectileReplication, _: u32) Sync.Body {
        return .{
            .position = self.reading.position,
            .velocity = self.reading.velocity,
            .yaw = self.reading.yaw,
            .pitch = self.reading.pitch,
            .on_ground = self.reading.in_ground,
        };
    }
};
