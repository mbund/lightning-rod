const std = @import("std");
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

pub const SurvivalInventory = struct {
    pub const id = "minecraft:survival_inventory";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        inventory: *PlayerInventory,
        input: *Input,
        players: *Players,
        inventories: *inventories.Inventories,
        items: *Items,
        packets: *packets.Packets,
        sessions: *sessions.Service,
    };
    const Action = union(enum) { inventory_close: i32, inventory_click: minecraft.InventoryClick, dig: minecraft.Dig };
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*SurvivalInventory {
        const self = try allocator.create(SurvivalInventory);
        self.* = .{ .deps = deps };
        try deps.input.on(.window_click, self, onClick);
        try deps.input.on(.close_window, self, onClose);
        try deps.players.observeDig(self, onDig);
        return self;
    }

    fn onDig(self: *SurvivalInventory, handle: sessions.Handle, dig: minecraft.Dig) !void {
        if (dig.action != .swap_hands and dig.action != .drop_item and dig.action != .drop_stack) return;
        try self.apply(handle.index, .{ .dig = dig });
    }

    fn onClose(self: *SurvivalInventory, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_close_window.Reader) !void {
        const window, const done = body.windowId() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        try self.apply(handle.index, .{ .inventory_close = window });
    }

    fn onClick(self: *SurvivalInventory, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_window_click.Reader) !void {
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
        try self.apply(handle.index, .{ .inventory_click = .{ .window_id = window, .state_id = state_id, .slot = slot, .button = button, .mode = mode } });
    }

    fn apply(self: *SurvivalInventory, player_index: usize, event: Action) !void {
        const menu = self.deps.inventory;
        const player = &self.deps.players.records[player_index];
        const state = &menu.states[player_index];
        if (player.handle == null) return;
        if (player.gamemode == .creative or player.stage != .ready) return;
        state.selected = player.selected_slot;
        var slots: [47]inventories.Slot = undefined;
        var contents: [47]inventories.Contents = undefined;
        try menu.load(player_index, &slots, &contents);

        for (0..1) |_| {
            var next: [47]?inventories.Stack = undefined;

            for (&next, contents) |*stack, value| stack.* = value.stack;

            switch (event) {
                .inventory_close => |window| {
                    if (window != 0) continue;
                    state.close = false;
                    state.drag = 0;
                    state.drag_button = null;
                    for ([_]usize{ cursor, 1, 2, 3, 4 }) |source| {
                        const held = next[source] orelse continue;
                        var remaining = held.count;
                        const maximum = try self.deps.items.stackLimit(held);
                        for (0..2) |pass| for (0..38) |offset| {
                            const target: usize = if (offset == 0) 36 + @as(usize, state.selected) else if (offset == 1) 45 else if (offset < 11) offset + 34 else offset - 2;
                            if (remaining == 0) break;
                            const previous = if (next[target]) |stack| stack.count else 0;
                            if (pass == 0) {
                                if (next[target] == null or !inventories.Stack.sameItem(held, next[target].?)) continue;
                            } else if (next[target] != null or offset < 2) continue;
                            const amount = @min(remaining, maximum -| previous);
                            if (amount == 0) continue;
                            next[target] = .{ .item = held.item, .count = previous + amount };
                            remaining -= amount;
                        };
                        if (remaining != 0) try menu.drop(player.*, .{ .item = held.item, .count = remaining });
                        next[source] = null;
                    }
                },
                .dig => |dig| {
                    if (player.gamemode == .spectator or player.health == 0) continue;

                    const at = 36 + @as(usize, state.selected);

                    if (dig.action == .swap_hands) {
                        std.mem.swap(?inventories.Stack, &next[at], &next[45]);
                    } else if (dig.action == .drop_item or dig.action == .drop_stack) {
                        const held = next[at] orelse continue;
                        const amount = if (dig.action == .drop_stack) held.count else 1;
                        try menu.drop(player.*, .{ .item = held.item, .count = amount });
                        next[at] = if (amount == held.count) null else .{ .item = held.item, .count = held.count - amount };
                    } else continue;
                },
                .inventory_click => |click| {
                    if (click.mode != 5) state.dirty = all_slots;
                    if (click.window_id != 0 or player.gamemode == .spectator) continue;

                    if (click.mode == 5) {
                        if (click.button < 0 or click.button > 6) continue;

                        const button = @divTrunc(click.button, 4);
                        const phase = @mod(click.button, 4);
                        const held = next[cursor] orelse continue;
                        if (phase == 0) {
                            state.drag = 0;
                            state.drag_button = button;
                            continue;
                        }

                        if (state.drag_button == null or state.drag_button.? != button) continue;
                        if (phase == 1) {
                            if (click.slot < 1 or click.slot > 45) continue;
                            if (@popCount(state.drag) >= held.count) continue;

                            const target = next[@intCast(click.slot)];
                            const maximum = try menu.slotLimit(@intCast(click.slot), held);
                            if (target != null and !inventories.Stack.sameItem(held, target.?)) continue;
                            if (maximum == 0 or (target != null and target.?.count >= maximum)) continue;
                            state.drag |= @as(u64, 1) << @intCast(click.slot);
                            continue;
                        }

                        const count = @popCount(state.drag);
                        if (phase != 2 or count == 0) continue;

                        const each = if (button == 0) held.count / count else @as(u16, 1);
                        var remaining = held.count;

                        for (1..46) |index| {
                            if (state.drag & (@as(u64, 1) << @intCast(index)) == 0) continue;
                            if (next[index]) |target| if (!inventories.Stack.sameItem(held, target)) continue;

                            const previous = if (next[index]) |stack| stack.count else 0;
                            const limit = try menu.slotLimit(index, held);
                            const amount = @min(each, limit -| previous, remaining);
                            if (amount == 0) continue;
                            next[index] = .{ .item = held.item, .count = previous + amount };

                            remaining -= amount;
                        }

                        next[cursor] = if (remaining == 0) null else .{ .item = held.item, .count = remaining };
                        state.drag = 0;
                        state.drag_button = null;
                    } else {
                        if (click.slot == -999 and click.mode == 0 and (click.button == 0 or click.button == 1)) {
                            const held = next[cursor] orelse continue;
                            const amount = if (click.button == 0) held.count else 1;
                            try menu.drop(player.*, .{ .item = held.item, .count = amount });
                            next[cursor] = if (amount == held.count) null else .{ .item = held.item, .count = held.count - amount };
                        } else {
                            if (click.slot < 0 or click.slot > 45) continue;

                            const at: usize = @intCast(click.slot);
                            if (at == 0) continue;

                            switch (click.mode) {
                                0 => {
                                    if (click.button != 0 and click.button != 1) continue;

                                    if (next[cursor]) |held| {
                                        const maximum = try menu.slotLimit(at, held);
                                        if (maximum == 0) continue;

                                        if (next[at]) |target| {
                                            if (inventories.Stack.sameItem(held, target)) {
                                                const amount = @min(if (click.button == 1) @as(u16, 1) else held.count, maximum -| target.count);
                                                next[at].?.count += amount;
                                                next[cursor] = if (amount == held.count) null else .{ .item = held.item, .count = held.count - amount };
                                            } else if (held.count <= maximum) std.mem.swap(?inventories.Stack, &next[cursor], &next[at]);
                                        } else {
                                            const amount = @min(maximum, if (click.button == 1) @as(u16, 1) else held.count);
                                            next[at] = .{ .item = held.item, .count = amount };
                                            next[cursor] = if (amount == held.count) null else .{ .item = held.item, .count = held.count - amount };
                                        }
                                    } else if (next[at]) |target| {
                                        const amount = if (click.button == 1) (target.count + 1) / 2 else target.count;
                                        next[cursor] = .{ .item = target.item, .count = amount };
                                        next[at] = if (amount == target.count) null else .{ .item = target.item, .count = target.count - amount };
                                    }
                                },
                                1 => {
                                    const source = next[at] orelse continue;
                                    var remaining = source.count;
                                    const maximum = try self.deps.items.stackLimit(source);
                                    const equipment = try menu.deps.equipment.slot(source);
                                    const armor: ?usize = if (equipment >= 2 and equipment <= 5) 10 - @as(usize, equipment) else if (equipment == 1) 45 else null;
                                    const equip = at >= 9 and armor != null and next[armor.?] == null;
                                    for (0..if (equip) @as(usize, 2) else 1) |destination| {
                                        const first: usize = if (equip and destination == 0) armor.? else if (at >= 9 and at < 36) 36 else 9;
                                        const end: usize = if (equip and destination == 0) armor.? + 1 else if (at >= 36 and at < 45) 36 else 45;
                                        for (0..2) |pass| for (first..end) |to| {
                                            if (remaining == 0) break;

                                            if (next[to]) |target| {
                                                if (pass != 0 or !inventories.Stack.sameItem(source, target)) continue;

                                                const amount = @min(remaining, maximum -| target.count);
                                                next[to].?.count += amount;
                                                remaining -= amount;
                                            } else if (pass == 1) {
                                                const amount = @min(remaining, try menu.slotLimit(to, source));
                                                next[to] = .{ .item = source.item, .count = amount };
                                                remaining -= amount;
                                            }
                                        };
                                    }

                                    next[at] = if (remaining == 0) null else .{ .item = source.item, .count = remaining };
                                },
                                2 => {
                                    if (click.button < 0 or (click.button > 8 and click.button != 40)) continue;

                                    const to: usize = if (click.button == 40) 45 else 36 + @as(usize, @intCast(click.button));
                                    var split = false;
                                    if (next[to]) |stack| {
                                        const maximum = try menu.slotLimit(at, stack);
                                        if (maximum == 0) continue;
                                        if (stack.count > maximum) {
                                            const displaced = next[at];
                                            next[at] = .{ .item = stack.item, .count = maximum };
                                            next[to].?.count -= maximum;
                                            if (displaced) |held| {
                                                var remaining = held.count;
                                                const limit = try self.deps.items.stackLimit(held);
                                                for (0..2) |pass| for (0..38) |offset| {
                                                    const target: usize = if (offset == 0) 36 + @as(usize, state.selected) else if (offset == 1) 45 else if (offset < 11) offset + 34 else offset - 2;
                                                    if (remaining == 0) break;
                                                    const previous = if (next[target]) |value| value.count else 0;
                                                    if (pass == 0) {
                                                        if (next[target] == null or !inventories.Stack.sameItem(held, next[target].?)) continue;
                                                    } else if (next[target] != null or offset < 2) continue;
                                                    const amount = @min(remaining, limit -| previous);
                                                    if (amount == 0) continue;
                                                    next[target] = .{ .item = held.item, .count = previous + amount };
                                                    remaining -= amount;
                                                };
                                                if (remaining != 0) try menu.drop(player.*, .{ .item = held.item, .count = remaining });
                                            }
                                            split = true;
                                        }
                                    }
                                    if (!split) std.mem.swap(?inventories.Stack, &next[at], &next[to]);
                                },
                                4 => {
                                    if ((click.button != 0 and click.button != 1) or next[cursor] != null) continue;

                                    const held = next[at] orelse continue;
                                    const amount = if (click.button == 1) held.count else 1;
                                    try menu.drop(player.*, .{ .item = held.item, .count = amount });
                                    next[at] = if (amount == held.count) null else .{ .item = held.item, .count = held.count - amount };
                                },
                                6 => {
                                    if (click.button != 0 and click.button != 1 or next[at] != null) continue;
                                    const held = next[cursor] orelse continue;
                                    const maximum = try self.deps.items.stackLimit(held);

                                    for (0..2) |pass| for (1..46) |offset| {
                                        const index = if (click.button == 0) offset else 46 - offset;
                                        const source = &next[index];
                                        const stack = source.* orelse continue;
                                        if (!inventories.Stack.sameItem(held, stack)) continue;
                                        if (pass == 0 and stack.count == maximum) continue;

                                        const amount = @min(stack.count, maximum -| next[cursor].?.count);
                                        next[cursor].?.count += amount;
                                        source.* = if (amount == stack.count) null else .{ .item = stack.item, .count = stack.count - amount };
                                    };
                                },
                                else => continue,
                            }
                        }
                    }
                },
            }

            try menu.commit(state, &slots, &contents, &next);
        }
    }

    pub fn tick(self: *SurvivalInventory) !void {
        const menu = self.deps.inventory;
        const service = self.deps.sessions;
        connections: for (self.deps.players.records, menu.states, 0..) |*player, *state, player_index| {
            const handle = player.handle orelse continue;
            if (player.gamemode == .creative or player.stage != .ready or !player.loaded) continue;
            if (state.presentation != self.deps.items.components.revision) {
                state.presentation = self.deps.items.components.revision;
                state.dirty = PlayerInventory.all_slots;
            }
            if (state.close) try self.apply(player_index, .{ .inventory_close = 0 });
            if (state.dirty == 0 and state.generation == handle.generation and state.life == player.life and state.gamemode == player.gamemode) continue;
            var slots: [47]inventories.Slot = undefined;
            var contents: [47]inventories.Contents = undefined;
            try menu.load(player_index, &slots, &contents);
            if (state.dirty == 0) continue;

            self.deps.packets.sendPacketRetrying(PlayerInventory.writeInventory, player.protocol, &.{handle}, .{
                self.deps.items, state.revision, &contents, player.uuid,
            }, service.config.page_bytes) catch |err| switch (err) {
                error.EndOfStream, error.UnsupportedItem, error.UnsupportedComponent => {
                    service.disconnect(handle);
                    continue :connections;
                },
                error.Backpressured, error.Closed => continue :connections,
                else => return err,
            };
            state.dirty = 0;
        }
    }
};
