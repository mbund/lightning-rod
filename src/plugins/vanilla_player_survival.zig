const lightning_rod = @import("lightning_rod");
const player_store = lightning_rod.players;
const game_rules = lightning_rod.game_rules;
const Packets = lightning_rod.Packets;
const std = @import("std");

pub const Survival = struct {
    pub const id = "minecraft:player_survival";

    rules: *game_rules.GameRules,
    players: *player_store.Players,
    outputs: *Packets,

    pub fn create(allocator: std.mem.Allocator, rules: *game_rules.GameRules, players: *player_store.Players, outputs: *Packets) !*Survival {
        const self = try allocator.create(Survival);
        self.* = .{ .rules = rules, .players = players, .outputs = outputs };
        return self;
    }

    pub fn tick(self: *Survival, _: std.mem.Allocator) void {
        const rules = self.rules;
        const players = self.players;
        const outputs = self.outputs;
        for (players.activeSlots()) |slot| {
            const player = &players.records[slot];
            if (player.state != .play) continue;
            const selected_item_id = player.hotbar[player.selected_hotbar_slot].item_id;
            if (selected_item_id != player.last_attack_item_id) {
                player.last_attack_item_id = selected_item_id;
                player.last_attacked_ticks = 0;
            } else player.last_attacked_ticks +|= 1;
            if (player.time_until_regen > 0) player.time_until_regen -= 1;
            if (!rules.natural_regeneration or player.gamemode != .survival or
                player.health <= 0 or player.health >= 20 or player.food < 20 or
                player.saturation <= 0)
            {
                player.food_tick_timer = 0;
                continue;
            }
            player.food_tick_timer += 1;
            if (player.food_tick_timer < 10) continue;
            const saturation_used = @min(player.saturation, @as(f32, 6));
            player.health = @min(@as(f32, 20), player.health + saturation_used / 6);
            player.exhaustion += saturation_used;
            player.food_tick_timer = 0;
            for (0..5) |_| {
                if (player.exhaustion <= 4) break;
                player.exhaustion -= 4;
                if (player.saturation > 0)
                    player.saturation = @max(0, player.saturation - 1)
                else if (player.food > 0)
                    player.food -= 1;
            } else @panic("player exhaustion exceeded its per-tick bound");
            outputs.player_health_changed(@intCast(slot));
        }
    }
};
