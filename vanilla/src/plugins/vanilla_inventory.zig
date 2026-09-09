const lightning_rod = @import("lightning_rod");
const entity_store = lightning_rod.entities;
const input_store = lightning_rod.inputs;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const world_random = lightning_rod.random;
const std = @import("std");
const registry = lightning_rod.registry_data;
const vanilla_recipes = @import("vanilla_recipes.zig");
const vanilla_collision_projection = @import("vanilla_collision_projection.zig");
const Packets = lightning_rod.Packets;
const player_lifecycle = lightning_rod.player_lifecycle;
const container_menu = lightning_rod.container_menu;

const PreparedDrop = struct {
    reservation: entity_store.ItemEntities.Reservation,
    specification: entity_store.ItemEntities.Spawn,
};

const InventoryDrop = struct {
    source: *player_store.HotbarStack,
    stack: player_store.HotbarStack,
    single: bool,
};

const InventoryWork = struct {
    random: *world_random.Random,
    world: *block_store.Blocks,
    players: *player_store.Players,
    items: *entity_store.ItemEntities,
    inputs: *input_store.Inputs,
    containers: *player_store.Containers,
    recipes: *vanilla_recipes.Recipes,
    collision_projection: *vanilla_collision_projection.CollisionProjection,

    fn activePlayerSlots(self: *const InventoryWork) []const u16 {
        return self.players.active_slots[0..self.players.active_count];
    }

    fn takeSelectedItem(self: *InventoryWork, slot: u16, count: u8) ?player_store.HotbarStack {
        const player = &self.players.records[slot];
        const stack = &player.hotbar[player.selected_hotbar_slot];
        if (stack.isEmpty()) return null;
        const taken = @min(count, stack.count);
        var result = stack.*;
        result.count = taken;
        stack.count -= taken;
        if (stack.count == 0) stack.* = .{};
        return result;
    }

    fn spawnPlayerDroppedItem(self: *InventoryWork, player: *const player_store.CorePlayer, stack: player_store.HotbarStack) !usize {
        var prepared = try self.preparePlayerDroppedItem(player, stack);
        return self.commitPlayerDroppedItem(&prepared);
    }

    fn preparePlayerDroppedItem(self: *InventoryWork, player: *const player_store.CorePlayer, stack: player_store.HotbarStack) !PreparedDrop {
        const yaw = std.math.degreesToRadians(@as(f64, player.rotation.yaw));
        const pitch = std.math.degreesToRadians(@as(f64, player.rotation.pitch));
        const horizontal = std.math.cos(pitch) * 0.3;
        const specification = entity_store.ItemEntities.Spawn{
            .world = player.world,
            .position = .{
                .x = player.position.x,
                .y = player.position.y + 1.3,
                .z = player.position.z,
            },
            .velocity = .{
                .x = -std.math.sin(yaw) * horizontal,
                .y = -std.math.sin(pitch) * 0.3 + 0.1,
                .z = std.math.cos(yaw) * horizontal,
            },
            .stack = stack,
            .pickup_delay_ticks = entity_store.player_drop_pickup_delay_ticks,
        };
        try self.items.validateSpawn(self.world, specification);
        return .{ .reservation = try self.items.reserve(1), .specification = specification };
    }

    fn commitPlayerDroppedItem(self: *InventoryWork, prepared: *PreparedDrop) usize {
        var output: [1]usize = undefined;
        self.items.commitReserved(&prepared.reservation, self.random, &.{prepared.specification}, &output);
        return output[0];
    }
};

const InventoryRuntime = struct {
    deps: InventoryWork,
    outputs: *Packets,
};

fn makeWork(
    random: *world_random.Random,
    blocks: *block_store.Blocks,
    players: *player_store.Players,
    items: *entity_store.ItemEntities,
    inputs: *input_store.Inputs,
    containers: *player_store.Containers,
    recipes: *vanilla_recipes.Recipes,
    collision_projection: *vanilla_collision_projection.CollisionProjection,
    outputs: *Packets,
) InventoryRuntime {
    return .{
        .deps = .{
            .random = random,
            .world = blocks,
            .players = players,
            .items = items,
            .inputs = inputs,
            .containers = containers,
            .recipes = recipes,
            .collision_projection = collision_projection,
        },
        .outputs = outputs,
    };
}

fn playerCraftingResult(simulation: *const InventoryWork, slot: u16) player_store.HotbarStack {
    var grid = [_]i32{0} ** 4;
    for (simulation.players.records[slot].crafting_grid, 0..) |stack, index| {
        if (!stack.isEmpty()) grid[index] = stack.item_id;
    }
    const result = simulation.recipes.craft(&grid, 2, 2) orelse return .{};
    return player_store.stackForItem(result.item_id, result.count);
}

fn tableCraftingResult(simulation: *const InventoryWork, slot: u16) player_store.HotbarStack {
    const container = &simulation.containers.open[slot];
    if (container.kind != .crafting_table) return .{};
    var grid = [_]i32{0} ** 9;
    for (container.crafting_grid, 0..) |stack, index| {
        if (!stack.isEmpty()) grid[index] = stack.item_id;
    }
    const result = simulation.recipes.craft(&grid, 3, 3) orelse return .{};
    return player_store.stackForItem(result.item_id, result.count);
}

fn refreshCraftingResults(simulation: *InventoryWork, slot: u16) void {
    simulation.players.records[slot].crafting_result = playerCraftingResult(simulation, slot);
    simulation.containers.open[slot].crafting_result = tableCraftingResult(simulation, slot);
}

fn clickPlayerInventory(
    simulation: *InventoryWork,
    slot: u16,
    protocol_slot: i16,
    mouse_button: i8,
    mode: i32,
    outputs: *Packets,
) void {
    std.debug.assert(slot < simulation.players.records.len);
    const player = &simulation.players.records[slot];
    if (mode < 0 or mode > 6) return;
    if (mode == 0 and mouse_button != 0 and mouse_button != 1) return;
    if (mode == 5) {
        updateInventoryDrag(simulation, slot, 0, protocol_slot, mouse_button);
        return;
    }
    simulation.containers.drags[slot] = .{};
    if (mode == 6) {
        collectToCursor(simulation, slot, 0);
        return;
    }
    if (mode == 3) {
        cloneToCursor(simulation, slot, 0, protocol_slot);
        return;
    }
    if (mode == 4 or (mode == 0 and protocol_slot == -999)) return;
    if (protocol_slot == 0) {
        takePlayerCraftingResult(simulation, slot, mode, outputs);
        return;
    }
    const clicked = player_store.inventoryStack(player, protocol_slot) orelse return;
    if (mode == 1) {
        shiftPlayerStack(player, protocol_slot, clicked);
        return;
    }
    if (mode == 2 and mouse_button >= 0 and mouse_button < 9) {
        std.mem.swap(player_store.HotbarStack, clicked, &player.hotbar[@intCast(mouse_button)]);
        return;
    }
    clickStack(&player.cursor_stack, clicked, mouse_button);
}

fn clickCraftingTable(simulation: *InventoryWork, slot: u16, protocol_slot: i16, mouse_button: i8, mode: i32) void {
    const player = &simulation.players.records[slot];
    const container = &simulation.containers.open[slot];
    if (container.kind != .crafting_table or mode < 0 or mode > 6) return;
    if (mode == 5) {
        updateInventoryDrag(simulation, slot, container.id, protocol_slot, mouse_button);
        return;
    }
    simulation.containers.drags[slot] = .{};
    if (mode == 6) {
        collectToCursor(simulation, slot, container.id);
        return;
    }
    if (mode == 3) {
        cloneToCursor(simulation, slot, container.id, protocol_slot);
        return;
    }
    if (mode == 4 or (mode == 0 and protocol_slot == -999)) return;
    if (protocol_slot == 0) {
        takeTableCraftingResult(simulation, slot, mode);
        return;
    }
    const clicked = windowStack(simulation, slot, container.id, protocol_slot) orelse return;
    if (mode == 1) {
        shiftTableStack(player, container, protocol_slot, clicked);
        return;
    }
    if (mode == 2 and mouse_button >= 0 and mouse_button < 9) {
        std.mem.swap(player_store.HotbarStack, clicked, &player.hotbar[@intCast(mouse_button)]);
        return;
    }
    if (mode != 0 or (mouse_button != 0 and mouse_button != 1)) return;
    clickStack(&player.cursor_stack, clicked, mouse_button);
}

fn updateInventoryDrag(simulation: *InventoryWork, slot: u16, window_id: i32, protocol_slot: i16, mouse_button: i8) void {
    const drag = &simulation.containers.drags[slot];
    const phase = @mod(mouse_button, 4);
    const button = @divTrunc(mouse_button, 4);
    if (button < 0 or button > 2 or phase > 2) {
        drag.* = .{};
    } else if (phase == 0) {
        drag.* = .{ .active = true, .button = @intCast(button), .window_id = window_id };
    } else if (!drag.active or drag.button != button or drag.window_id != window_id) {
        drag.* = .{};
    } else if (phase == 1) {
        if (protocol_slot >= 1 and protocol_slot <= 45)
            drag.slots |= @as(u64, 1) << @intCast(protocol_slot);
    } else {
        const selected = drag.slots;
        const drag_button = drag.button;
        drag.* = .{};
        finishInventoryDrag(simulation, slot, window_id, selected, drag_button);
    }
}

fn collectToCursor(simulation: *InventoryWork, slot: u16, window_id: i32) void {
    const cursor = &simulation.players.records[slot].cursor_stack;
    if (cursor.isEmpty()) return;
    var needed = player_store.maxStackSize(cursor.item_id) - cursor.count;
    for (1..46) |inventory_slot| {
        if (needed == 0) break;
        const candidate = windowStack(simulation, slot, window_id, @intCast(inventory_slot)) orelse continue;
        if (!player_store.sameStackKind(candidate.*, cursor.*)) continue;
        const moved = @min(needed, candidate.count);
        cursor.count += moved;
        candidate.count -= moved;
        needed -= moved;
        if (candidate.count == 0) candidate.* = .{};
    }
}

fn cloneToCursor(simulation: *InventoryWork, slot: u16, window_id: i32, protocol_slot: i16) void {
    const player = &simulation.players.records[slot];
    if (player.gamemode != .creative) return;
    const clicked = windowStack(simulation, slot, window_id, protocol_slot) orelse return;
    if (clicked.isEmpty()) return;
    player.cursor_stack = clicked.*;
    player.cursor_stack.count = player_store.maxStackSize(clicked.item_id);
}

fn takePlayerCraftingResult(simulation: *InventoryWork, slot: u16, mode: i32, outputs: *Packets) void {
    if (mode == 2) return;
    const player = &simulation.players.records[slot];
    const result = playerCraftingResult(simulation, slot);
    if (result.isEmpty()) return;
    if (mode == 1) {
        for (0..45 * std.math.maxInt(u8)) |_| {
            const next = playerCraftingResult(simulation, slot);
            if (next.isEmpty() or !player_store.storeCraftingResult(player, next)) break;
            consumeIngredients(&player.crafting_grid);
            player.crafting_result = playerCraftingResult(simulation, slot);
            outputs.player_screen_slot_changed(.{ .slot = slot, .screen_slot = 0 });
        }
        return;
    }
    if (!storeOnCursor(&player.cursor_stack, result)) return;
    consumeIngredients(&player.crafting_grid);
}

fn takeTableCraftingResult(simulation: *InventoryWork, slot: u16, mode: i32) void {
    const player = &simulation.players.records[slot];
    const container = &simulation.containers.open[slot];
    const result = tableCraftingResult(simulation, slot);
    if (result.isEmpty()) return;
    if (mode == 1) {
        for (0..45 * std.math.maxInt(u8)) |_| {
            const next = tableCraftingResult(simulation, slot);
            if (next.isEmpty() or !player_store.storeCraftingResult(player, next)) break;
            consumeIngredients(&container.crafting_grid);
        }
        return;
    }
    if (!storeOnCursor(&player.cursor_stack, result)) return;
    consumeIngredients(&container.crafting_grid);
}

fn consumeIngredients(grid: []player_store.HotbarStack) void {
    for (grid) |*ingredient| {
        if (ingredient.isEmpty()) continue;
        ingredient.count -= 1;
        if (ingredient.count == 0) ingredient.* = .{};
    }
}

fn storeOnCursor(cursor: *player_store.HotbarStack, result: player_store.HotbarStack) bool {
    if (!cursor.isEmpty() and (!player_store.sameStackKind(cursor.*, result) or
        cursor.count > player_store.maxStackSize(cursor.item_id) - result.count)) return false;
    if (cursor.isEmpty()) cursor.* = result else cursor.count += result.count;
    return true;
}

fn shiftPlayerStack(player: *player_store.CorePlayer, protocol_slot: i16, clicked: *player_store.HotbarStack) void {
    if (protocol_slot >= 9 and protocol_slot <= 35)
        player_store.moveStackInto(&player.hotbar, clicked)
    else if (protocol_slot >= 36 and protocol_slot <= 44)
        player_store.moveStackInto(&player.main_inventory, clicked)
    else {
        player_store.moveStackInto(&player.main_inventory, clicked);
        player_store.moveStackInto(&player.hotbar, clicked);
    }
}

fn shiftTableStack(player: *player_store.CorePlayer, container: *player_store.OpenContainer, protocol_slot: i16, clicked: *player_store.HotbarStack) void {
    if (protocol_slot >= 10 and protocol_slot <= 45) {
        const count_before = clicked.count;
        player_store.moveStackInto(&container.crafting_grid, clicked);
        if (clicked.count != count_before) return;
    }
    if (protocol_slot >= 10 and protocol_slot <= 36)
        player_store.moveStackInto(&player.hotbar, clicked)
    else if (protocol_slot >= 37 and protocol_slot <= 45)
        player_store.moveStackInto(&player.main_inventory, clicked)
    else {
        player_store.moveStackInto(&player.main_inventory, clicked);
        player_store.moveStackInto(&player.hotbar, clicked);
    }
}

fn clickStack(cursor: *player_store.HotbarStack, clicked: *player_store.HotbarStack, mouse_button: i8) void {
    if (mouse_button == 0) {
        if (cursor.isEmpty() or clicked.isEmpty() or !player_store.sameStackKind(cursor.*, clicked.*)) {
            std.mem.swap(player_store.HotbarStack, cursor, clicked);
            return;
        }
        const moved = @min(player_store.maxStackSize(clicked.item_id) - clicked.count, cursor.count);
        clicked.count += moved;
        cursor.count -= moved;
    } else if (cursor.isEmpty()) {
        cursor.* = clicked.*;
        cursor.count = (clicked.count + 1) / 2;
        clicked.count -= cursor.count;
    } else if (clicked.isEmpty()) {
        clicked.* = cursor.*;
        clicked.count = 1;
        cursor.count -= 1;
    } else if (player_store.sameStackKind(cursor.*, clicked.*) and clicked.count < player_store.maxStackSize(clicked.item_id)) {
        clicked.count += 1;
        cursor.count -= 1;
    }
    if (cursor.count == 0) cursor.* = .{};
    if (clicked.count == 0) clicked.* = .{};
}

fn windowStack(simulation: *InventoryWork, slot: u16, window_id: i32, protocol_slot: i16) ?*player_store.HotbarStack {
    if (window_id == 0) return player_store.inventoryStack(&simulation.players.records[slot], protocol_slot);
    const container = &simulation.containers.open[slot];
    if (container.kind != .crafting_table or container.id != window_id) return null;
    return if (protocol_slot >= 1 and protocol_slot <= 9)
        &container.crafting_grid[@intCast(protocol_slot - 1)]
    else if (protocol_slot >= 10 and protocol_slot <= 36)
        &simulation.players.records[slot].main_inventory[@intCast(protocol_slot - 10)]
    else if (protocol_slot >= 37 and protocol_slot <= 45)
        &simulation.players.records[slot].hotbar[@intCast(protocol_slot - 37)]
    else
        null;
}

fn finishInventoryDrag(simulation: *InventoryWork, slot: u16, window_id: i32, selected: u64, button: u2) void {
    const player = &simulation.players.records[slot];
    const cursor = &player.cursor_stack;
    if (cursor.isEmpty()) return;
    if (button == 2) {
        if (player.gamemode != .creative) return;
        for (1..46) |protocol_slot| {
            if (selected & (@as(u64, 1) << @intCast(protocol_slot)) == 0) continue;
            const target = windowStack(simulation, slot, window_id, @intCast(protocol_slot)) orelse continue;
            if (!target.isEmpty() and !player_store.sameStackKind(target.*, cursor.*)) continue;
            target.* = cursor.*;
            target.count = player_store.maxStackSize(target.item_id);
        }
        return;
    }
    var eligible: u8 = 0;
    for (1..46) |protocol_slot| {
        if (selected & (@as(u64, 1) << @intCast(protocol_slot)) == 0) continue;
        const target = windowStack(simulation, slot, window_id, @intCast(protocol_slot)) orelse continue;
        if (target.isEmpty() or (player_store.sameStackKind(target.*, cursor.*) and target.count < player_store.maxStackSize(target.item_id))) eligible += 1;
    }
    if (eligible == 0) return;
    const each: u8 = if (button == 1) 1 else cursor.count / eligible;
    if (each == 0) return;
    for (1..46) |protocol_slot| {
        if (cursor.isEmpty()) break;
        if (selected & (@as(u64, 1) << @intCast(protocol_slot)) == 0) continue;
        const target = windowStack(simulation, slot, window_id, @intCast(protocol_slot)) orelse continue;
        if (!target.isEmpty() and !player_store.sameStackKind(target.*, cursor.*)) continue;
        const capacity = if (target.isEmpty()) player_store.maxStackSize(cursor.item_id) else player_store.maxStackSize(target.item_id) - target.count;
        const moved = @min(@min(each, capacity), cursor.count);
        if (moved == 0) continue;
        if (target.isEmpty()) {
            target.* = cursor.*;
            target.count = 0;
        }
        target.count += moved;
        cursor.count -= moved;
        if (cursor.count == 0) cursor.* = .{};
    }
}

fn inventoryDrop(simulation: *InventoryWork, slot: u16, window_id: i32, protocol_slot: i16, mouse_button: i8, mode: i32) ?InventoryDrop {
    const player = &simulation.players.records[slot];
    const source = if (mode == 4)
        windowStack(simulation, slot, window_id, protocol_slot) orelse return null
    else if (mode == 0 and protocol_slot == -999)
        &player.cursor_stack
    else
        return null;
    if (source.isEmpty() or (mouse_button != 0 and mouse_button != 1)) return null;
    var dropped = source.*;
    const single = (mouse_button == 0 and mode == 4) or (mouse_button == 1 and mode == 0);
    if (single) {
        dropped.count = 1;
    }
    return .{ .source = source, .stack = dropped, .single = single };
}

fn commitInventoryDrop(drop: InventoryDrop) void {
    if (drop.single) {
        std.debug.assert(drop.source.count >= drop.stack.count);
        drop.source.count -= drop.stack.count;
        if (drop.source.count == 0) drop.source.* = .{};
        return;
    }
    drop.source.* = .{};
}

fn returnPlayerCraftingGrid(simulation: *InventoryWork, slot: u16, outputs: *Packets) void {
    const player = &simulation.players.records[slot];
    const old_hotbar = player.hotbar;
    const old_main_inventory = player.main_inventory;
    player_store.returnCraftingGridToInventory(player);
    for (player.hotbar, old_hotbar, 0..) |new, old, inventory_slot| {
        if (!std.meta.eql(new, old)) outputs.inventory_slot_changed(.{ .slot = slot, .inventory_slot = @as(i32, @intCast(inventory_slot)) });
    }
    for (player.main_inventory, old_main_inventory, 0..) |new, old, main_slot| {
        if (!std.meta.eql(new, old)) outputs.inventory_slot_changed(.{ .slot = slot, .inventory_slot = @as(i32, @intCast(9 + main_slot)) });
    }
    for (&player.crafting_grid) |*stack| {
        if (stack.isEmpty()) continue;
        const dropped = stack.*;
        const index = simulation.spawnPlayerDroppedItem(player, dropped) catch continue;
        stack.* = .{};
        outputs.item_spawned(@as(u16, @intCast(index)));
    }
    player.crafting_result = .{};

    outputs.player_screen_slot_changed(.{ .slot = slot, .screen_slot = @as(i16, 0) });
    for (player.hotbar, old_hotbar, 0..) |new, old, hotbar_slot| {
        if (!std.meta.eql(new, old)) outputs.player_screen_slot_changed(.{ .slot = slot, .screen_slot = @as(i16, @intCast(36 + hotbar_slot)) });
    }
    for (player.main_inventory, old_main_inventory, 0..) |new, old, main_slot| {
        if (!std.meta.eql(new, old)) outputs.player_screen_slot_changed(.{ .slot = slot, .screen_slot = @as(i16, @intCast(9 + main_slot)) });
    }
}

fn dropRequestedItems(simulation: *InventoryWork, outputs: *Packets) void {
    for (simulation.activePlayerSlots()) |active_slot| {
        const slot: usize = active_slot;
        const pending = &simulation.inputs.item_drops[slot];
        const count = pending.count;
        pending.* = .{};
        if (count == 0 or simulation.players.records[slot].state != .play) continue;
        const player = &simulation.players.records[slot];
        const hotbar_slot = player.selected_hotbar_slot;
        const selected = player.hotbar[hotbar_slot];
        if (selected.isEmpty()) continue;
        var stack = selected;
        stack.count = @min(count, stack.count);
        var prepared = simulation.preparePlayerDroppedItem(player, stack) catch {
            outputs.input_failed(error.ItemEntityCapacity);
            continue;
        };
        const removed = simulation.takeSelectedItem(@intCast(slot), count) orelse unreachable;
        std.debug.assert(std.meta.eql(removed, stack));
        const item_index = simulation.commitPlayerDroppedItem(&prepared);
        outputs.hotbar_changed(.{ .slot = active_slot, .hotbar_slot = hotbar_slot });
        outputs.item_spawned(@intCast(item_index));
    }
}

fn closeInvalidContainers(simulation: *InventoryWork, outputs: *Packets) void {
    for (simulation.activePlayerSlots()) |active_slot| {
        const slot: usize = active_slot;
        const container = &simulation.containers.open[slot];
        if (container.kind == .none) continue;
        const expected = switch (container.kind) {
            .crafting_table => registry.block_crafting_table_id,
            .chest => registry.block_chest_id,
            .furnace => registry.block_furnace_id,
            .none => unreachable,
        };
        const block_state = simulation.collision_projection.blockState(container.world, container.position) orelse continue;
        const present = block_state >= 0 and block_state < registry.block_state_to_block.len and
            registry.block_state_to_block[@intCast(block_state)] == expected;
        if (present and player_store.playerCanReachBlock(&simulation.players.records[slot], container.position)) continue;
        const window_id = container.id;
        container_menu.close(simulation.players, simulation.containers, active_slot);
        outputs.container_closed(.{ .slot = active_slot, .window_id = window_id });
    }
}

fn applyCreativeSlots(simulation: *InventoryWork, outputs: *Packets, changed: []u64) void {
    for (simulation.inputs.creative_slot_changes[0..simulation.inputs.creative_slot_change_count]) |request| {
        const slot = request.slot;
        const player = &simulation.players.records[slot];
        if (player.state != .play or player.gamemode != .creative) continue;
        const target = player_store.inventoryStack(player, request.inventory_slot) orelse continue;
        target.* = request.stack;
        changed[slot / 64] |= @as(u64, 1) << @intCast(slot % 64);
        if (request.inventory_slot == 36 + @as(i16, player.selected_hotbar_slot))
            outputs.hotbar_changed(.{ .slot = slot, .hotbar_slot = player.selected_hotbar_slot });
    }
    simulation.inputs.creative_slot_change_count = 0;
}

fn applyInventoryClicks(simulation: *InventoryWork, outputs: *Packets, changed: []u64) void {
    for (simulation.inputs.inventory_clicks[0..simulation.inputs.inventory_click_count]) |click| {
        if (click.handled or simulation.players.records[click.slot].state != .play) continue;
        const open = &simulation.containers.open[click.slot];
        if (click.window_id != 0 and (open.kind == .none or click.window_id != open.id)) continue;
        if (inventoryDrop(simulation, click.slot, click.window_id, click.protocol_slot, click.mouse_button, click.mode)) |drop| {
            const player = &simulation.players.records[click.slot];
            var prepared = simulation.preparePlayerDroppedItem(player, drop.stack) catch {
                changed[click.slot / 64] |= @as(u64, 1) << @intCast(click.slot % 64);
                continue;
            };
            commitInventoryDrop(drop);
            const index = simulation.commitPlayerDroppedItem(&prepared);
            outputs.item_spawned(@intCast(index));
        } else if (click.window_id == 0) {
            clickPlayerInventory(simulation, click.slot, click.protocol_slot, click.mouse_button, click.mode, outputs);
        } else if (open.kind == .crafting_table) {
            clickCraftingTable(simulation, click.slot, click.protocol_slot, click.mouse_button, click.mode);
        }
        changed[click.slot / 64] |= @as(u64, 1) << @intCast(click.slot % 64);
    }
    simulation.inputs.inventory_click_count = 0;
}

fn applyContainerCloses(simulation: *InventoryWork, outputs: *Packets, changed: []u64) void {
    for (simulation.activePlayerSlots()) |active_slot| {
        const slot: usize = active_slot;
        const pending = &simulation.inputs.container_closes[slot];
        if (pending.* < 0) continue;
        const window_id = pending.*;
        pending.* = -1;
        if (window_id == 0) {
            returnPlayerCraftingGrid(simulation, active_slot, outputs);
        } else if (simulation.containers.open[slot].id == window_id) {
            container_menu.close(simulation.players, simulation.containers, active_slot);
            changed[slot / 64] |= @as(u64, 1) << @intCast(slot % 64);
        }
    }
}

fn emitInventoryChanges(simulation: *InventoryWork, outputs: *Packets, changed: []const u64) void {
    for (simulation.activePlayerSlots()) |slot| {
        if (changed[slot / 64] & (@as(u64, 1) << @intCast(slot % 64)) == 0) continue;
        refreshCraftingResults(simulation, slot);
        outputs.inventory_changed(slot);
    }
}

pub const Inventory = struct {
    pub const id = "minecraft:inventory";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        random: *world_random.Random,
        blocks: *block_store.Blocks,
        players: *player_store.Players,
        items: *entity_store.ItemEntities,
        inputs: *input_store.Inputs,
        containers: *player_store.Containers,
        recipes: *vanilla_recipes.Recipes,
        collision_projection: *vanilla_collision_projection.CollisionProjection,
        outputs: *Packets,
        events: *player_lifecycle.Events,
    };

    deps: Dependencies,
    changed: []u64 = &.{},

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*Inventory {
        const self = try allocator.create(Inventory);
        self.* = .{ .deps = deps, .changed = try allocator.alloc(u64, (deps.players.records.len + 63) / 64) };
        return self;
    }

    pub fn tick(self: *Inventory, _: std.mem.Allocator) lightning_rod.plugin_lifecycle.FatalError!void {
        const random = self.deps.random;
        const blocks = self.deps.blocks;
        const players = self.deps.players;
        const items = self.deps.items;
        const inputs = self.deps.inputs;
        const containers = self.deps.containers;
        const recipes = self.deps.recipes;
        const outputs = self.deps.outputs;
        var runtime = makeWork(random, blocks, players, items, inputs, containers, recipes, self.deps.collision_projection, outputs);
        for (self.deps.events.left.values) |event| try disconnectPlayer(&runtime, event);
        @memset(self.changed, 0);
        dropRequestedItems(&runtime.deps, outputs);
        closeInvalidContainers(&runtime.deps, outputs);
        applyCreativeSlots(&runtime.deps, outputs, self.changed);
        applyInventoryClicks(&runtime.deps, outputs, self.changed);
        applyContainerCloses(&runtime.deps, outputs, self.changed);
        emitInventoryChanges(&runtime.deps, outputs, self.changed);
    }

};

fn disconnectPlayer(
    work: *InventoryRuntime,
    event: player_lifecycle.PlayerLeft,
) lightning_rod.plugin_lifecycle.FatalError!void {
    const slot = event.slot;
    const player = &work.deps.players.records[slot];
    const container = &work.deps.containers.open[slot];
    if (container.kind != .none) {
        for (&container.crafting_grid) |*stack|
            if (!moveOrDrop(work, player, stack)) return error.WorkingMemoryExceeded;
        container.* = .{};
        work.deps.containers.drags[slot] = .{};
    }
    if (!moveOrDrop(work, player, &player.cursor_stack)) return error.WorkingMemoryExceeded;
    for (&player.crafting_grid) |*stack|
        if (!moveOrDrop(work, player, stack)) return error.WorkingMemoryExceeded;
    player.crafting_result = .{};
}

fn moveOrDrop(
    work: *InventoryRuntime,
    player: *player_store.CorePlayer,
    stack: *player_store.HotbarStack,
) bool {
    if (stack.isEmpty()) return true;
    var staged_main_inventory = player.main_inventory;
    var staged_hotbar = player.hotbar;
    var staged_stack = stack.*;
    player_store.moveStackInto(&staged_main_inventory, &staged_stack);
    player_store.moveStackInto(&staged_hotbar, &staged_stack);
    var prepared: ?PreparedDrop = null;
    if (!staged_stack.isEmpty())
        prepared = work.deps.preparePlayerDroppedItem(player, staged_stack) catch return false;
    player.main_inventory = staged_main_inventory;
    player.hotbar = staged_hotbar;
    stack.* = .{};
    if (prepared) |*drop| {
        const index = work.deps.commitPlayerDroppedItem(drop);
        work.outputs.item_spawned(@intCast(index));
    }
    return true;
}

test "disconnect preserves unresolved cursor and container crafting stacks" {
    var state: lightning_rod.test_support.state.State = undefined;
    try state.init(std.testing.allocator, 0x51a7);
    defer state.deinit();

    state.players.beginConnection(&state.random, 0);
    _ = try state.players.login(&state.random, 0, "full-inventory", 91);
    const player = &state.players.records[0];
    const full = player_store.stackForItem(registry.item_oak_planks_id, 64);
    for (&player.hotbar) |*stack| stack.* = full;
    for (&player.main_inventory) |*stack| stack.* = full;
    player.cursor_stack = player_store.stackForItem(registry.item_diamond_shovel_id, 1);

    const container = &state.containers.open[0];
    container.kind = .crafting_table;
    container.crafting_grid[0] = player_store.stackForItem(registry.item_diamond_pickaxe_id, 1);
    const expected_cursor = player.cursor_stack;
    const expected_crafting = container.crafting_grid[0];
    const before = playerItemCount(player) + containerItemCount(container);

    _ = state.blocks.materializeGeneratedChunk(state.world, .{ .x = 0, .z = 0 }, 0);
    var held = try state.items.reserve(state.items.active.len);
    defer state.items.cancelReservation(&held);
    var recipes: vanilla_recipes.Recipes = .{};
    var runtime = InventoryRuntime{
        .deps = .{
            .random = &state.random,
            .world = &state.blocks,
            .players = &state.players,
            .items = &state.items,
            .inputs = &state.inputs,
            .containers = &state.containers,
            .recipes = &recipes,
            .collision_projection = undefined,
        },
        .outputs = undefined,
    };

    try std.testing.expectError(error.WorkingMemoryExceeded, disconnectPlayer(&runtime, .{
        .slot = 0,
        .connection = .{ .index = 0, .generation = 1 },
        .reason = .peer_closed,
    }));
    try std.testing.expectEqualDeep(expected_cursor, player.cursor_stack);
    try std.testing.expectEqualDeep(expected_crafting, container.crafting_grid[0]);
    try std.testing.expectEqual(container.kind, .crafting_table);
    try std.testing.expectEqual(before, playerItemCount(player) + containerItemCount(container));
    try std.testing.expectEqual(@as(usize, 0), state.items.active_count);
}

test "disconnect normalizes inventory before canonical save and relogin" {
    var state: lightning_rod.test_support.state.State = undefined;
    try state.init(std.testing.allocator, 0x9c31);
    defer state.deinit();

    state.players.beginConnection(&state.random, 0);
    _ = try state.players.login(&state.random, 0, "saved-inventory", 0x91);
    state.players.transition(0, .configuration);
    state.players.transition(0, .play);
    const player = &state.players.records[0];
    player.cursor_stack = player_store.stackForItem(registry.item_diamond_shovel_id, 1);
    const container = &state.containers.open[0];
    container.kind = .crafting_table;
    container.crafting_grid[0] = player_store.stackForItem(registry.item_diamond_pickaxe_id, 1);

    var recipes: vanilla_recipes.Recipes = .{};
    var runtime = InventoryRuntime{
        .deps = .{
            .random = &state.random,
            .world = &state.blocks,
            .players = &state.players,
            .items = &state.items,
            .inputs = &state.inputs,
            .containers = &state.containers,
            .recipes = &recipes,
            .collision_projection = undefined,
        },
        .outputs = undefined,
    };
    try disconnectPlayer(&runtime, .{
        .slot = 0,
        .connection = .{ .index = 0, .generation = 1 },
        .reason = .peer_closed,
    });
    try std.testing.expect(player.cursor_stack.isEmpty());
    try std.testing.expect(container.crafting_grid[0].isEmpty());
    try std.testing.expectEqual(@as(u32, 2), playerItemCount(player));

    state.players.beginDisconnect(0);
    try state.players.persistDisconnect(std.testing.io, 0);
    state.players.releaseDisconnected(0);
    state.containers.releaseDisconnected(0);
    state.players.beginConnection(&state.random, 1);
    try std.testing.expectEqual(
        player_store.LoginDisposition.restored_player,
        try state.players.login(&state.random, 1, "saved-inventory", 0x91),
    );
    try std.testing.expectEqual(@as(u32, 2), playerItemCount(&state.players.records[1]));
    try std.testing.expect(state.players.records[1].cursor_stack.isEmpty());
}

fn playerItemCount(player: *const player_store.CorePlayer) u32 {
    var count: u32 = player.cursor_stack.count;
    for (player.hotbar) |stack| count += stack.count;
    for (player.main_inventory) |stack| count += stack.count;
    for (player.crafting_grid) |stack| count += stack.count;
    return count;
}

fn containerItemCount(container: *const player_store.OpenContainer) u32 {
    var count: u32 = 0;
    for (container.crafting_grid) |stack| count += stack.count;
    return count;
}
