//! Projectiles as players see them: tracking says who is to have each, this sends the spawns and
//! removals once every entity ticked and tracking looked, while projectiles send their updates
//! and pickups from their own tick to whoever has them.

const std = @import("std");
const Tracking = @import("replication").tracking.Tracking;
const Projectiles = @import("projectiles.zig").Projectiles;

pub const ProjectileReplication = struct {
    pub const id = "minecraft:projectile_replication";
    pub const Configuration = struct {};
    pub const Dependencies = struct { projectiles: *Projectiles, tracking: *Tracking };

    projectiles: *Projectiles,

    pub fn init(allocator: std.mem.Allocator, _: Configuration, deps: Dependencies) !*ProjectileReplication {
        const self = try allocator.create(ProjectileReplication);
        self.* = .{ .projectiles = deps.projectiles };
        try deps.projectiles.track(deps.tracking);
        return self;
    }

    pub fn tick(self: *ProjectileReplication) !void {
        try self.projectiles.replicateChanges();
    }
};
