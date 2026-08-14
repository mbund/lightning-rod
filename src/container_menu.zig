const player_store = @import("world/players.zig");
const geometry = @import("world/geometry.zig");
const std = @import("std");

const maximum_window_id = 100;

pub fn close(players: *player_store.Players, containers: *player_store.Containers, slot: u16) void {
    std.debug.assert(slot < players.records.len);
    const container = &containers.open[slot];
    if (container.kind == .none) return;
    const player = &players.records[slot];
    if (container.kind == .crafting_table) {
        for (&container.crafting_grid) |*stack| {
            player_store.moveStackInto(&player.main_inventory, stack);
            player_store.moveStackInto(&player.hotbar, stack);
        }
    }
    player_store.moveStackInto(&player.main_inventory, &player.cursor_stack);
    player_store.moveStackInto(&player.hotbar, &player.cursor_stack);
    container.* = .{};
    containers.drags[slot] = .{};
}

pub fn open(
    players: *player_store.Players,
    containers: *player_store.Containers,
    slot: u16,
    kind: player_store.ContainerKind,
    position: geometry.BlockPos,
    secondary_position: ?geometry.BlockPos,
    menu_type: i32,
    top_slots: []const player_store.HotbarStack,
) void {
    std.debug.assert(kind == .chest or kind == .furnace);
    std.debug.assert(top_slots.len <= player_store.max_container_slots);
    const window_id = nextWindowId(players, containers, slot);
    const container = &containers.open[slot];
    container.* = .{
        .world = players.records[slot].world,
        .kind = kind,
        .id = window_id,
        .position = position,
        .secondary_position = secondary_position,
        .menu_type = menu_type,
        .top_slot_count = @intCast(top_slots.len),
    };
    @memcpy(container.top_slots[0..top_slots.len], top_slots);
}

pub fn project(containers: *player_store.Containers, slot: u16, top_slots: []const player_store.HotbarStack) void {
    const container = &containers.open[slot];
    std.debug.assert(container.kind == .chest or container.kind == .furnace);
    std.debug.assert(top_slots.len == container.top_slot_count);
    @memcpy(container.top_slots[0..top_slots.len], top_slots);
}

pub fn openCraftingTable(players: *player_store.Players, containers: *player_store.Containers, slot: u16, position: geometry.BlockPos) void {
    const window_id = nextWindowId(players, containers, slot);
    containers.open[slot] = .{
        .world = players.records[slot].world,
        .kind = .crafting_table,
        .id = window_id,
        .position = position,
    };
}

fn nextWindowId(players: *player_store.Players, containers: *player_store.Containers, slot: u16) i32 {
    close(players, containers, slot);
    const current = containers.counters[slot];
    const next = if (current == maximum_window_id) 1 else current + 1;
    containers.counters[slot] = next;
    return next;
}
