const std = @import("std");
const sessions = @import("sessions");
const minecraft = @import("minecraft_model");
const Players = @import("players").players.Players;
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const EquipmentAttributes = @import("vanilla_items").equipment_attributes.EquipmentAttributes;
const PlayerDamage = @import("player_damage.zig").PlayerDamage;

/// How far players fall, from what their clients say of their height and footing, and the
/// damage a landing deals, as LivingEntity.causeFallDamage works it out.
pub const FallDamage = struct {
    pub const id = "minecraft:fall_damage";

    pub const Configuration = struct {};

    pub const Dependencies = struct {
        players: *Players,
        player_states: *PlayerStates,
        attributes: *EquipmentAttributes,
        damage: *PlayerDamage,
    };

    const Fall = struct {
        generation: u32 = 0,
        life: u32 = 0,
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

    fn onMovement(self: *FallDamage, handle: sessions.Handle, movement: minecraft.Movement) !void {
        const player = &self.deps.players.records[handle.index];
        const fall = self.fallOf(handle.index);
        const y = if (movement.position) |position| position.y else fall.y;
        if (!std.math.isFinite(y) or @abs(y) > 30_000_000) return;
        const gamemode = self.deps.player_states.of(player).gamemode;
        if (gamemode == .creative or gamemode == .spectator) {
            fall.distance = 0;
        } else if (y < fall.y) fall.distance += fall.y - y;
        fall.y = y;

        if (movement.on_ground) {
            const safe_distance = try self.deps.attributes.value(handle.index, "minecraft:safe_fall_distance");
            const fall_damage = @max(0, @ceil((fall.distance - safe_distance) * try self.deps.attributes.value(handle.index, "minecraft:fall_damage_multiplier")));
            if (fall_damage > 0) try self.damage(handle.index, @floatCast(fall_damage));
            fall.distance = 0;
        }
    }

    /// The fall of the player in a slot, started over for a new connection, life or teleport.
    fn fallOf(self: *FallDamage, slot: usize) *Fall {
        const player = &self.deps.players.records[slot];
        const fall = &self.falls[slot];
        const generation = if (player.handle) |handle| handle.generation else 0;
        if (fall.generation != generation or fall.life != player.life or fall.teleport_id != player.teleport_id)
            fall.* = .{ .generation = generation, .life = player.life, .teleport_id = player.teleport_id, .y = player.position.y };
        return fall;
    }

    /// A landing's damage, as the fall damage type deals it.
    pub fn damage(self: *FallDamage, player_index: usize, amount: f32) !void {
        assert(std.math.isFinite(amount) and amount > 0);
        _ = try self.deps.damage.hurt(player_index, .{ .type = .fall }, amount);
    }

    /// Entity.resetFallDistance: the fall so far counts for nothing.
    pub fn reset(self: *FallDamage, slot: usize) void {
        self.fallOf(slot).distance = 0;
    }

    /// How far the player in a slot has fallen since it last stood.
    pub fn distance(self: *const FallDamage, slot: usize) f64 {
        return self.falls[slot].distance;
    }

    pub fn tick(self: *FallDamage) void {
        for (self.deps.players.activeSlots()) |index| _ = self.fallOf(index);
    }
};

const assert = std.debug.assert;
