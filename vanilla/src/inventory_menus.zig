const std = @import("std");
const menu_click = @import("menu_click.zig");
const Containers = @import("containers.zig").Containers;
const wire_1_21_5 = @import("wire_1_21_5");
const inventories = @import("inventories");
const sessions = @import("sessions");
const minecraft = @import("minecraft_model");
const packets = @import("minecraft_packets");
const PlayerInventory = @import("player_inventory.zig").PlayerInventory;
const Players = @import("players.zig").Players;
const Input = @import("input.zig").Input;
const Items = @import("items.zig").Items;

const cursor = PlayerInventory.cursor;
const all_slots = PlayerInventory.all_slots;

pub const InventoryMenus = struct {
    pub const id = "minecraft:inventory_menus";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        inventory: *PlayerInventory,
        containers: *Containers,
        input: *Input,
        players: *Players,
        inventories: *inventories.Inventories,
        items: *Items,
        packets: *packets.Packets,
        sessions: *sessions.Service,
    };
    const Action = union(enum) { inventory_click: minecraft.InventoryClick, dig: minecraft.Dig };
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*InventoryMenus {
        const self = try allocator.create(InventoryMenus);
        self.* = .{ .deps = deps };
        try deps.input.on(.window_click, self, onClick);
        try deps.input.on(.close_window, self, onClose);
        try deps.players.observeDig(self, onDig);
        return self;
    }

    fn onDig(self: *InventoryMenus, handle: sessions.Handle, dig: minecraft.Dig) !void {
        if (dig.action != .swap_hands and dig.action != .drop_item and dig.action != .drop_stack) return;
        try self.apply(handle.index, .{ .dig = dig });
    }

    fn onClose(self: *InventoryMenus, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_close_window.Reader) !void {
        const window, const done = body.windowId() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        if (window != 0) return self.deps.containers.closeWindow(handle, window);
        if (!self.deps.inventory.states[handle.index].external) try self.deps.inventory.closeMenu(handle.index);
    }

    fn onClick(self: *InventoryMenus, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_window_click.Reader) !void {
        const window, const a = body.windowId() catch return error.InvalidPacket;
        const state_id, const b = a.stateId() catch return error.InvalidPacket;
        const slot, const c = b.slot() catch return error.InvalidPacket;
        const button, const d = c.mouseButton() catch return error.InvalidPacket;
        const mode, const e = d.mode() catch return error.InvalidPacket;
        var changed = e.changedSlots() catch return error.InvalidPacket;
        _, const f = changed.encoded() catch return error.InvalidPacket;
        var cursor_item = f.cursorItem() catch return error.InvalidPacket;
        _, const done = cursor_item.encoded() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        const click: minecraft.InventoryClick = .{ .window_id = window, .state_id = state_id, .slot = slot, .button = button, .mode = mode };
        if (window != 0) return self.deps.containers.click(handle, click);
        if (!self.deps.inventory.states[handle.index].external) try self.apply(handle.index, .{ .inventory_click = click });
    }

    fn apply(self: *InventoryMenus, player_index: usize, event: Action) !void {
        const menu = self.deps.inventory;
        const player = &self.deps.players.records[player_index];
        const state = &menu.states[player_index];
        if (player.handle == null) return;
        if (player.gamemode == .creative or player.stage != .ready) return;
        state.selected = player.selected_slot;
        var slots: [47]inventories.Slot = undefined;
        var contents: [47]inventories.Contents = undefined;
        try menu.load(player_index, &slots, &contents);

        const before = state.*;
        action: {
            var drops: [10]inventories.Stack = undefined;
            var drop_count: usize = 0;
            var next: [47]?inventories.Stack = undefined;

            for (&next, contents) |*stack, value| stack.* = value.stack;

            switch (event) {
                .dig => |dig| {
                    if (player.gamemode == .spectator or player.health == 0) break :action;

                    const at = 36 + @as(usize, state.selected);

                    if (dig.action == .swap_hands) {
                        std.mem.swap(?inventories.Stack, &next[at], &next[45]);
                    } else if (dig.action == .drop_item or dig.action == .drop_stack) {
                        const held = next[at] orelse break :action;
                        const amount = if (dig.action == .drop_stack) held.count else 1;
                        drops[drop_count] = .{ .item = held.item, .count = amount };
                        drop_count += 1;
                        next[at] = if (amount == held.count) null else .{ .item = held.item, .count = held.count - amount };
                    } else break :action;
                },
                .inventory_click => |click| {
                    if (click.mode != 5) state.dirty = all_slots;
                    if (click.window_id != 0 or player.gamemode == .spectator) break :action;
                    const view: menu_click.Menu = .{ .inventory = menu, .kind = .player, .container_slots = 0, .stacks = &next, .drag = &state.drag, .creative = false };
                    const result = try view.apply(click);
                    @memcpy(drops[0..result.count], result.drops[0..result.count]);
                    drop_count = result.count;
                    try view.refresh();
                },
            }

            if (!try menu.apply(player_index, &slots, &contents, &next, drops[0..drop_count])) {
                state.* = before;
                state.dirty = all_slots;
                break :action;
            }
        }
    }

    pub fn tick(self: *InventoryMenus) !void {
        const menu = self.deps.inventory;
        const service = self.deps.sessions;
        connections: for (self.deps.players.activeSlots()) |player_index| {
            const player = &self.deps.players.records[player_index];
            const state = &menu.states[player_index];
            const handle = player.handle orelse continue;
            if (player.gamemode == .creative or player.stage != .ready or !player.loaded) continue;
            if (state.external) continue;
            if (state.presentation != self.deps.items.components.revision) {
                state.presentation = self.deps.items.components.revision;
                state.dirty = PlayerInventory.all_slots;
            }
            if (state.close) try menu.closeMenu(player_index);
            if (state.dirty == 0 and state.generation == handle.generation and state.life == player.life and state.gamemode == player.gamemode) continue;
            menu.synchronize(player_index, self.deps.packets, service) catch |err| switch (err) {
                error.EndOfStream, error.UnsupportedItem, error.UnsupportedComponent => service.disconnect(handle),
                error.Backpressured, error.Closed => continue :connections,
                else => return err,
            };
        }
    }
};
