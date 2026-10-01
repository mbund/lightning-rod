const std = @import("std");
const sessions = @import("sessions");
const minecraft = @import("minecraft_model");
const Players = @import("players.zig").Players;

pub const FallDamage = struct {
    pub const id = "minecraft:fall_damage";

    pub const Configuration = struct {};

    pub const Dependencies = struct {
        players: *Players,
    };

    const Fall = struct {
        generation: u32 = 0,
        teleport_id: i32 = 0,
        y: f64 = 0,
        distance: f64 = 0,
    };

    deps: Dependencies,
    falls: []Fall,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*FallDamage {
        const self = try allocator.create(FallDamage);
        const falls = try allocator.alloc(Fall, deps.players.records.len);
        @memset(falls, .{});
        self.* = .{ .deps = deps, .falls = falls };
        try deps.players.observeMovement(self, onMovement);
        return self;
    }

    fn onMovement(self: *FallDamage, handle: sessions.Handle, movement: minecraft.Movement) void {
        const player = &self.deps.players.records[handle.index];
        const fall = &self.falls[handle.index];
        if (fall.generation != handle.generation or fall.teleport_id != player.teleport_id)
            fall.* = .{ .generation = handle.generation, .teleport_id = player.teleport_id, .y = player.position.y };

        const y = if (movement.position) |position| position.y else fall.y;
        if (!std.math.isFinite(y) or @abs(y) > 30_000_000) return;
        if (player.gamemode == .creative or player.gamemode == .spectator) {
            fall.distance = 0;
        } else if (y < fall.y) fall.distance += fall.y - y;
        fall.y = y;

        if (movement.on_ground) {
            const damage = @max(0, @ceil(fall.distance - 3));
            player.health = @max(0, player.health - @as(f32, @floatCast(damage)));
            fall.distance = 0;
        }
    }

    pub fn tick(self: *FallDamage) void {
        for (self.deps.players.records, self.falls) |*player, *fall| {
            const handle = player.handle orelse continue;
            if (fall.generation != handle.generation or fall.teleport_id != player.teleport_id) {
                fall.* = .{ .generation = handle.generation, .teleport_id = player.teleport_id, .y = player.position.y };
                continue;
            }

            if (player.stage != .ready) continue;

            if (player.stage != .ready or player.health == player.health_sent) continue;

            if (self.deps.players.sendHealth(player.protocol, &.{handle}, player.health))
                player.health_sent = player.health;
        }
    }

};
