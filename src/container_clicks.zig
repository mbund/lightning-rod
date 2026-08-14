const input_store = @import("world/inputs.zig");
const player_store = @import("world/players.zig");
const std = @import("std");

pub const Result = struct {
    changed: bool = false,
    dropped: ?player_store.HotbarStack = null,
};

const ClickMode = enum {
    normal,
    shift,
    hotbar,
    creative_clone,
    drop,
    drag,
    collect,
};

const DragButton = enum(u2) {
    evenly,
    single,
    creative,
};

pub const Drag = struct {
    active: bool = false,
    window_id: i32 = 0,
    button: DragButton = .evenly,
    selected: [2]u64 = .{ 0, 0 },
};

pub const StorageRules = struct {
    pub fn canPlace(_: *const StorageRules, _: usize, _: player_store.HotbarStack) bool {
        return true;
    }

    pub fn moveFromPlayer(_: *const StorageRules, top: []player_store.HotbarStack, stack: *player_store.HotbarStack) void {
        player_store.moveStackInto(top, stack);
    }
};

pub fn apply(
    comptime Rules: type,
    rules: *const Rules,
    player: *player_store.CorePlayer,
    top: []player_store.HotbarStack,
    click: input_store.InventoryClick,
) Result {
    var drag: Drag = .{};
    return applyWithDrag(Rules, rules, player, top, click, &drag);
}

pub fn applyWithDrag(
    comptime Rules: type,
    rules: *const Rules,
    player: *player_store.CorePlayer,
    top: []player_store.HotbarStack,
    click: input_store.InventoryClick,
    drag: *Drag,
) Result {
    const mode: ClickMode = switch (click.mode) {
        0 => .normal,
        1 => .shift,
        2 => .hotbar,
        3 => .creative_clone,
        4 => .drop,
        5 => .drag,
        6 => .collect,
        else => return .{},
    };
    if (mode == .drag) return dragClick(Rules, rules, player, top, click, drag);
    drag.* = .{};
    return switch (mode) {
        .normal => normalPacketClick(Rules, rules, player, top, click),
        .shift => shiftClick(Rules, rules, player, top, click.protocol_slot),
        .hotbar => numberKey(Rules, rules, player, top, click.protocol_slot, click.mouse_button),
        .creative_clone => cloneStack(player, top, click.protocol_slot),
        .drop => dropFromSlot(player, top, click.protocol_slot, click.mouse_button),
        .collect => collectMatching(player, top),
        .drag => unreachable,
    };
}

fn normalPacketClick(
    comptime Rules: type,
    rules: *const Rules,
    player: *player_store.CorePlayer,
    top: []player_store.HotbarStack,
    click: input_store.InventoryClick,
) Result {
    if (click.mouse_button != 0 and click.mouse_button != 1) return .{};
    if (click.protocol_slot == -999) return dropCursor(player, click.mouse_button);
    const clicked = stackAt(player, top, click.protocol_slot) orelse return .{};
    const top_index = if (click.protocol_slot >= 0 and click.protocol_slot < top.len)
        @as(?usize, @intCast(click.protocol_slot))
    else
        null;
    return normalClick(Rules, rules, &player.cursor_stack, clicked, top_index, click.mouse_button);
}

fn cloneStack(player: *player_store.CorePlayer, top: []player_store.HotbarStack, protocol_slot: i16) Result {
    if (player.gamemode != .creative) return .{};
    const clicked = stackAt(player, top, protocol_slot) orelse return .{};
    if (clicked.isEmpty()) return .{};
    player.cursor_stack = clicked.*;
    player.cursor_stack.count = player_store.maxStackSize(clicked.item_id);
    return .{ .changed = true };
}

fn dragClick(
    comptime Rules: type,
    rules: *const Rules,
    player: *player_store.CorePlayer,
    top: []player_store.HotbarStack,
    click: input_store.InventoryClick,
    drag: *Drag,
) Result {
    if (click.mouse_button < 0) {
        drag.* = .{};
        return .{};
    }
    const encoded: u8 = @intCast(click.mouse_button);
    const phase = encoded & 3;
    const button: DragButton = switch (encoded >> 2) {
        0 => .evenly,
        1 => .single,
        2 => .creative,
        else => {
            drag.* = .{};
            return .{};
        },
    };
    if (phase > 2) {
        drag.* = .{};
        return .{};
    }
    if (phase == 0) {
        drag.* = .{
            .active = true,
            .window_id = click.window_id,
            .button = button,
        };
        return .{};
    }
    if (!drag.active or drag.window_id != click.window_id or drag.button != button) {
        drag.* = .{};
        return .{};
    }
    if (phase == 1) {
        if (click.protocol_slot < 0) return .{};
        const slot: usize = @intCast(click.protocol_slot);
        if (slot >= top.len + player.main_inventory.len + player.hotbar.len) return .{};
        if (slot < top.len and !rules.canPlace(slot, player.cursor_stack)) return .{};
        drag.selected[slot / 64] |= @as(u64, 1) << @intCast(slot & 63);
        return .{};
    }
    const selected = drag.selected;
    const drag_button = drag.button;
    drag.* = .{};
    return finishDrag(Rules, rules, player, top, selected, drag_button);
}

fn finishDrag(
    comptime Rules: type,
    rules: *const Rules,
    player: *player_store.CorePlayer,
    top: []player_store.HotbarStack,
    selected: [2]u64,
    button: DragButton,
) Result {
    const cursor = &player.cursor_stack;
    if (cursor.isEmpty()) return .{};
    const slot_count = top.len + player.main_inventory.len + player.hotbar.len;
    if (button == .creative) {
        if (player.gamemode != .creative) return .{};
        var changed = false;
        for (0..slot_count) |slot| {
            if (!dragContains(selected, slot)) continue;
            const target = stackAt(player, top, @intCast(slot)) orelse continue;
            if (slot < top.len and !rules.canPlace(slot, cursor.*)) continue;
            if (!target.isEmpty() and !player_store.sameStackKind(target.*, cursor.*)) continue;
            target.* = cursor.*;
            target.count = player_store.maxStackSize(target.item_id);
            changed = true;
        }
        return .{ .changed = changed };
    }
    var eligible: u8 = 0;
    for (0..slot_count) |slot| {
        if (!dragContains(selected, slot)) continue;
        const target = stackAt(player, top, @intCast(slot)) orelse continue;
        if (slot < top.len and !rules.canPlace(slot, cursor.*)) continue;
        if (target.isEmpty() or
            (player_store.sameStackKind(target.*, cursor.*) and target.count < player_store.maxStackSize(target.item_id))) eligible += 1;
    }
    if (eligible == 0) return .{};
    const each: u8 = if (button == .single) 1 else cursor.count / eligible;
    if (each == 0) return .{};
    var changed = false;
    for (0..slot_count) |slot| {
        if (cursor.isEmpty()) break;
        if (!dragContains(selected, slot)) continue;
        const target = stackAt(player, top, @intCast(slot)) orelse continue;
        if (slot < top.len and !rules.canPlace(slot, cursor.*)) continue;
        if (!target.isEmpty() and !player_store.sameStackKind(target.*, cursor.*)) continue;
        const capacity = if (target.isEmpty())
            player_store.maxStackSize(cursor.item_id)
        else
            player_store.maxStackSize(target.item_id) - target.count;
        const moved = @min(@min(each, capacity), cursor.count);
        if (moved == 0) continue;
        if (target.isEmpty()) {
            target.* = cursor.*;
            target.count = 0;
        }
        target.count += moved;
        cursor.count -= moved;
        if (cursor.count == 0) cursor.* = .{};
        changed = true;
    }
    return .{ .changed = changed };
}

fn dragContains(selected: [2]u64, slot: usize) bool {
    return selected[slot / 64] & (@as(u64, 1) << @intCast(slot & 63)) != 0;
}

fn normalClick(
    comptime Rules: type,
    rules: *const Rules,
    cursor: *player_store.HotbarStack,
    clicked: *player_store.HotbarStack,
    top_index: ?usize,
    button: i8,
) Result {
    const may_place = top_index == null or rules.canPlace(top_index.?, cursor.*);
    if (button == 0) {
        if (cursor.isEmpty()) {
            if (clicked.isEmpty()) return .{};
            std.mem.swap(player_store.HotbarStack, cursor, clicked);
            return .{ .changed = true };
        }
        if (clicked.isEmpty()) {
            if (!may_place) return .{};
            std.mem.swap(player_store.HotbarStack, cursor, clicked);
            return .{ .changed = true };
        }
        if (player_store.sameStackKind(cursor.*, clicked.*)) {
            if (may_place) {
                const moved = @min(player_store.maxStackSize(clicked.item_id) - clicked.count, cursor.count);
                if (moved == 0) return .{};
                clicked.count += moved;
                cursor.count -= moved;
                if (cursor.count == 0) cursor.* = .{};
            } else {
                const moved = @min(player_store.maxStackSize(cursor.item_id) - cursor.count, clicked.count);
                if (moved == 0) return .{};
                cursor.count += moved;
                clicked.count -= moved;
                if (clicked.count == 0) clicked.* = .{};
            }
            return .{ .changed = true };
        }
        if (!may_place) return .{};
        std.mem.swap(player_store.HotbarStack, cursor, clicked);
        return .{ .changed = true };
    }

    if (cursor.isEmpty()) {
        if (clicked.isEmpty()) return .{};
        cursor.* = clicked.*;
        cursor.count = (clicked.count + 1) / 2;
        clicked.count -= cursor.count;
        if (clicked.count == 0) clicked.* = .{};
        return .{ .changed = true };
    }
    if (clicked.isEmpty()) {
        if (!may_place) return .{};
        clicked.* = cursor.*;
        clicked.count = 1;
        cursor.count -= 1;
        if (cursor.count == 0) cursor.* = .{};
        return .{ .changed = true };
    }
    if (!may_place or !player_store.sameStackKind(cursor.*, clicked.*) or clicked.count == player_store.maxStackSize(clicked.item_id))
        return .{};
    clicked.count += 1;
    cursor.count -= 1;
    if (cursor.count == 0) cursor.* = .{};
    return .{ .changed = true };
}

fn shiftClick(
    comptime Rules: type,
    rules: *const Rules,
    player: *player_store.CorePlayer,
    top: []player_store.HotbarStack,
    protocol_slot: i16,
) Result {
    const clicked = stackAt(player, top, protocol_slot) orelse return .{};
    if (clicked.isEmpty()) return .{};
    const before = clicked.*;
    if (protocol_slot >= 0 and protocol_slot < top.len) {
        player_store.moveStackInto(&player.main_inventory, clicked);
        player_store.moveStackInto(&player.hotbar, clicked);
    } else {
        rules.moveFromPlayer(top, clicked);
    }
    return .{ .changed = !std.meta.eql(before, clicked.*) };
}

fn numberKey(
    comptime Rules: type,
    rules: *const Rules,
    player: *player_store.CorePlayer,
    top: []player_store.HotbarStack,
    protocol_slot: i16,
    button: i8,
) Result {
    if (button < 0 or button >= player.hotbar.len) return .{};
    const clicked = stackAt(player, top, protocol_slot) orelse return .{};
    const top_index = if (protocol_slot >= 0 and protocol_slot < top.len)
        @as(?usize, @intCast(protocol_slot))
    else
        null;
    const hotbar = &player.hotbar[@intCast(button)];
    if (top_index) |index| if (!hotbar.isEmpty() and !rules.canPlace(index, hotbar.*)) return .{};
    std.mem.swap(player_store.HotbarStack, clicked, hotbar);
    return .{ .changed = true };
}

fn dropFromSlot(player: *player_store.CorePlayer, top: []player_store.HotbarStack, protocol_slot: i16, button: i8) Result {
    if (button != 0 and button != 1) return .{};
    const source = stackAt(player, top, protocol_slot) orelse return .{};
    if (source.isEmpty()) return .{};
    var dropped = source.*;
    if (button == 0) {
        dropped.count = 1;
        source.count -= 1;
        if (source.count == 0) source.* = .{};
    } else {
        source.* = .{};
    }
    return .{ .changed = true, .dropped = dropped };
}

fn dropCursor(player: *player_store.CorePlayer, button: i8) Result {
    if (player.cursor_stack.isEmpty() or (button != 0 and button != 1)) return .{};
    var dropped = player.cursor_stack;
    if (button == 1) {
        dropped.count = 1;
        player.cursor_stack.count -= 1;
        if (player.cursor_stack.count == 0) player.cursor_stack = .{};
    } else {
        player.cursor_stack = .{};
    }
    return .{ .changed = true, .dropped = dropped };
}

fn collectMatching(player: *player_store.CorePlayer, top: []player_store.HotbarStack) Result {
    const cursor = &player.cursor_stack;
    if (cursor.isEmpty()) return .{};
    var changed = false;
    collectFromSlice(cursor, top, &changed);
    collectFromSlice(cursor, &player.main_inventory, &changed);
    collectFromSlice(cursor, &player.hotbar, &changed);
    return .{ .changed = changed };
}

fn collectFromSlice(cursor: *player_store.HotbarStack, stacks: []player_store.HotbarStack, changed: *bool) void {
    for (stacks) |*candidate| {
        if (cursor.count == player_store.maxStackSize(cursor.item_id)) return;
        if (!player_store.sameStackKind(cursor.*, candidate.*)) continue;
        const moved = @min(player_store.maxStackSize(cursor.item_id) - cursor.count, candidate.count);
        cursor.count += moved;
        candidate.count -= moved;
        if (candidate.count == 0) candidate.* = .{};
        changed.* = changed.* or moved != 0;
    }
}

fn stackAt(player: *player_store.CorePlayer, top: []player_store.HotbarStack, protocol_slot: i16) ?*player_store.HotbarStack {
    if (protocol_slot < 0) return null;
    const index: usize = @intCast(protocol_slot);
    if (index < top.len) return &top[index];
    const player_index = index - top.len;
    if (player_index < player.main_inventory.len) return &player.main_inventory[player_index];
    const hotbar_index = player_index - player.main_inventory.len;
    if (hotbar_index < player.hotbar.len) return &player.hotbar[hotbar_index];
    return null;
}

test "storage clicks move stacks between a menu and the player" {
    var player: player_store.CorePlayer = .{};
    player.main_inventory[0] = player_store.stackForItem(7, 4);
    var top = [_]player_store.HotbarStack{.{}} ** 27;
    const rules: StorageRules = .{};
    const result = apply(StorageRules, &rules, &player, &top, .{
        .slot = 0,
        .window_id = 1,
        .state_id = 0,
        .protocol_slot = 27,
        .mouse_button = 0,
        .mode = 1,
    });
    try std.testing.expect(result.changed);
    try std.testing.expectEqual(@as(u8, 4), top[0].count);
    try std.testing.expect(player.main_inventory[0].isEmpty());
}

test "container drag distributes the cursor over selected slots" {
    var player: player_store.CorePlayer = .{};
    player.cursor_stack = player_store.stackForItem(7, 12);
    var top = [_]player_store.HotbarStack{.{}} ** 27;
    var drag: Drag = .{};
    const rules: StorageRules = .{};
    inline for (.{ @as(i8, 0), @as(i8, 1), @as(i8, 1), @as(i8, 2) }, 0..) |button, index| {
        const result = applyWithDrag(StorageRules, &rules, &player, &top, .{
            .slot = 0,
            .window_id = 1,
            .state_id = 0,
            .protocol_slot = switch (index) {
                1 => 0,
                2 => 1,
                else => -999,
            },
            .mouse_button = button,
            .mode = 5,
        }, &drag);
        if (index != 3) try std.testing.expect(!result.changed) else try std.testing.expect(result.changed);
    }
    try std.testing.expectEqual(@as(u8, 6), top[0].count);
    try std.testing.expectEqual(@as(u8, 6), top[1].count);
    try std.testing.expect(player.cursor_stack.isEmpty());
}
