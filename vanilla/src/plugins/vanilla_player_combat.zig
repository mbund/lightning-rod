const lightning_rod = @import("lightning_rod");
const input_store = lightning_rod.inputs;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const block_queries = lightning_rod.block_queries;
const geometry = lightning_rod.geometry;
const std = @import("std");
const game_data = lightning_rod.game_data;
const Packets = lightning_rod.Packets;
const test_state = lightning_rod.test_support.state;

pub const PlayerCombat = struct {
    pub const id = "minecraft:player_combat";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        blocks: *block_store.Blocks,
        players: *player_store.Players,
        inputs: *input_store.Inputs,
        outputs: *Packets,
    };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*PlayerCombat {
        const self = try allocator.create(PlayerCombat);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *PlayerCombat, _: std.mem.Allocator) void {
        const blocks = self.deps.blocks;
        const players = self.deps.players;
        const inputs = self.deps.inputs;
        const outputs = self.deps.outputs;
        for (players.activeSlots()) |attacker_slot| {
            const pending = &inputs.player_attacks[attacker_slot];
            if (!pending.active) {
                @branchHint(.likely);
                continue;
            }
            const attack = pending.*;
            pending.* = .{};
            if (attack.target_slot == attacker_slot) continue;

            const attacker = &players.records[attacker_slot];
            const target = &players.records[attack.target_slot];
            if (attacker.state != .play or attacker.health <= 0 or attacker.gamemode == .spectator) continue;
            if (target.state != .play or target.entity_id != attack.target_entity_id or target.health <= 0) continue;
            if (target.gamemode == .creative or target.gamemode == .spectator) continue;
            if (targetDistanceSquared(attacker, target) >= 36) continue;

            const held = attacker.hotbar[attacker.selected_hotbar_slot];
            const raw_damage = game_data.cooldownScaledAttackDamage(held.item_id, attacker.last_attacked_ticks);
            attacker.last_attacked_ticks = 0;
            var accepted_damage = raw_damage;
            if (target.time_until_regen > 10) {
                if (raw_damage <= target.last_damage_taken) continue;
                accepted_damage -= target.last_damage_taken;
            } else target.time_until_regen = 20;
            target.last_damage_taken = raw_damage;
            accepted_damage = armorReduction(target, accepted_damage);
            if (accepted_damage <= 0) continue;

            target.health = @max(0, target.health - accepted_damage);
            outputs.player_damaged(.{
                .slot = attack.target_slot,
                .source = .{ .player = attacker_slot },
                .knockback = knockback(blocks, attacker, target),
                .fatal = target.health == 0,
            });
            if (attacker.gamemode == .survival) if (damageHeldItem(attacker)) |hotbar_slot|
                outputs.hotbar_changed(.{ .slot = attacker_slot, .hotbar_slot = hotbar_slot });
        }
    }

    fn armorReduction(player: *const player_store.CorePlayer, damage: f32) f32 {
        var armor: f32 = 0;
        var toughness: f32 = 0;
        for (player.armor) |stack| {
            armor += game_data.armor(stack.item_id);
            toughness += game_data.armorToughness(stack.item_id);
        }
        const reduction_points = @min(@as(f32, 20), @max(armor / 5, armor - damage / (2 + toughness / 4)));
        return damage * (1 - reduction_points / 25);
    }

    fn damageHeldItem(player: *player_store.CorePlayer) ?u4 {
        const hotbar_slot = player.selected_hotbar_slot;
        const stack = &player.hotbar[hotbar_slot];
        if (stack.isEmpty()) return null;
        const maximum = game_data.maxDurability(stack.item_id);
        if (maximum == 0) return null;
        stack.damage +|= 2;
        if (stack.damage >= maximum) stack.* = .{};
        return hotbar_slot;
    }

    fn targetDistanceSquared(attacker: *const player_store.CorePlayer, target: *const player_store.CorePlayer) f64 {
        const eye = geometry.Vec3{
            .x = attacker.position.x,
            .y = attacker.position.y + 1.62,
            .z = attacker.position.z,
        };
        const closest = geometry.Vec3{
            .x = std.math.clamp(eye.x, target.position.x - 0.3, target.position.x + 0.3),
            .y = std.math.clamp(eye.y, target.position.y, target.position.y + 1.8),
            .z = std.math.clamp(eye.z, target.position.z - 0.3, target.position.z + 0.3),
        };
        const dx = closest.x - eye.x;
        const dy = closest.y - eye.y;
        const dz = closest.z - eye.z;
        return dx * dx + dy * dy + dz * dz;
    }

    fn knockback(
        blocks: *block_store.Blocks,
        attacker: *const player_store.CorePlayer,
        target: *const player_store.CorePlayer,
    ) geometry.Vec3 {
        const dx = target.position.x - attacker.position.x;
        const dz = target.position.z - attacker.position.z;
        const length_squared = dx * dx + dz * dz;
        if (length_squared <= 1.0e-8) return .{};
        const scale = 0.4 / @sqrt(length_squared);
        return .{
            .x = dx * scale,
            .y = if (target.on_ground or block_queries.playerGroundSupported(blocks, target.world, target.position)) 0.4 else 0,
            .z = dz * scale,
        };
    }
};

test "one attack input is consumed exactly once" {
    const simulation = try std.testing.allocator.create(test_state.State);
    defer std.testing.allocator.destroy(simulation);
    try simulation.init(std.testing.allocator, 37);
    defer simulation.deinit();
    for (0..2) |slot| {
        simulation.players.beginConnection(&simulation.random, @intCast(slot));
        _ = try simulation.players.login(&simulation.random, @intCast(slot), if (slot == 0) "attacker" else "target", slot + 1);
        simulation.players.transition(@intCast(slot), .configuration);
        simulation.players.transition(@intCast(slot), .play);
    }
    simulation.players.records[0].position = .{ .x = 0, .y = 64, .z = 0 };
    simulation.players.records[1].position = .{ .x = 1, .y = 64, .z = 0 };
    simulation.players.records[0].last_attacked_ticks = 20;

    var sessions = lightning_rod.sessions.Sessions.init(lightning_rod.protocol_versions.all[0].protocol_number);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const outputs = try Packets.init(arena.allocator(), .{
        .inputs = &simulation.inputs,
        .blocks = &simulation.blocks,
        .players = &simulation.players,
        .containers = &simulation.containers,
        .living = &simulation.living,
        .items = &simulation.items,
        .worlds = simulation.worlds,
        .sessions = &sessions,
    }, .{});
    outputs.tick(arena.allocator());
    const combat = try PlayerCombat.init(arena.allocator(), .{
        .blocks = &simulation.blocks,
        .players = &simulation.players,
        .inputs = &simulation.inputs,
        .outputs = outputs,
    }, .{});
    try simulation.inputs.requestEntityAttack(&simulation.players, 0, simulation.players.records[1].entity_id);
    combat.tick(arena.allocator());
    const health = simulation.players.records[1].health;
    try std.testing.expect(health < 20);
    try std.testing.expect(!simulation.inputs.player_attacks[0].active);
    combat.tick(arena.allocator());
    try std.testing.expectEqual(health, simulation.players.records[1].health);
}
