const lightning_rod = @import("lightning_rod");
const std = @import("std");
const entity_store = lightning_rod.entities;
const living_entities = lightning_rod.living_entities;
const player_store = lightning_rod.players;
const Packets = lightning_rod.Packets;

const love_duration = 600;

pub fn heldStack(player: *player_store.CorePlayer, hand: i32) *player_store.HotbarStack {
    return if (hand == 1) &player.offhand else &player.hotbar[player.selected_hotbar_slot];
}

pub fn inReach(
    player: *const player_store.CorePlayer,
    entities: *const living_entities.Pool,
    index: usize,
) bool {
    const dx = player.position.x - entities.position_x[index];
    const dy = player.position.y + 1.62 -
        (entities.position_y[index] + living_entities.height(entities.entity_types[index], entities.baby[index]) * 0.5);
    const dz = player.position.z - entities.position_z[index];
    return dx * dx + dy * dy + dz * dz < 36;
}

pub fn consume(
    players: *player_store.Players,
    outputs: *Packets,
    slot: u16,
    hand: i32,
) void {
    const player = &players.records[slot];
    if (player.gamemode == .creative) return;
    const stack = heldStack(player, hand);
    if (stack.count > 1) stack.count -= 1 else stack.* = .{};
    emitHeldStack(players, outputs, slot, hand);
}

pub fn feed(
    players: *player_store.Players,
    living: *entity_store.LivingEntities,
    outputs: *Packets,
    slot: u16,
    index: usize,
    hand: i32,
) void {
    const entities = &living.entities;
    if (entities.breeding_age[index] == 0 and entities.love_ticks[index] == 0) {
        entities.love_ticks[index] = love_duration;
        entities.loving_player[index] = slot;
        consume(players, outputs, slot, hand);
        outputs.living_status(.{ .index = @intCast(index), .status = 18 });
        return;
    }
    if (entities.breeding_age[index] >= 0) return;
    const remaining: f32 = @floatFromInt(-entities.breeding_age[index]);
    const growth_seconds: i32 = @intFromFloat(@floor(remaining * 0.1 / 20.0));
    entities.breeding_age[index] = @min(0, entities.breeding_age[index] + @max(1, growth_seconds) * 20);
    consume(players, outputs, slot, hand);
}

pub fn emitHeldStack(
    players: *const player_store.Players,
    outputs: *Packets,
    slot: u16,
    hand: i32,
) void {
    const player = &players.records[slot];
    if (hand == 1)
        outputs.player_screen_slot_changed(.{ .slot = slot, .screen_slot = 45 })
    else
        outputs.hotbar_changed(.{ .slot = slot, .hotbar_slot = player.selected_hotbar_slot });
}
