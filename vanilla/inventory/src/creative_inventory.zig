const std = @import("std");
const records = @import("records");
const wire_1_21_5 = @import("wire_1_21_5");
const packets = @import("minecraft_packets");
const inventories = @import("inventories");
const sessions = @import("sessions");
const minecraft = @import("minecraft_model");
const item_data = @import("vanilla_items").item_data;
const item_packets = @import("vanilla_items").item_packets;
const PlayerInventory = @import("player_inventory.zig").PlayerInventory;
const Items = @import("vanilla_items").items.Items;
const Players = @import("players").players.Players;
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const Input = @import("players").input.Input;

const assert = std.debug.assert;

pub const CreativeInventory = struct {
    pub const id = "minecraft:creative_inventory";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        inventory: *PlayerInventory,
        input: *Input,
        players: *Players,
        player_states: *PlayerStates,
        sessions: *sessions.Service,
        packets: *packets.Packets,
        inventories: *inventories.Inventories,
        items: *Items,
    };
    pub const Action = union(enum) { creative_slot: struct { slot: i16, item: ?item_packets.Incoming }, dig: minecraft.Dig };
    deps: Dependencies,
    decode_scratch: []u8,
    decode_components: [item_data.maximum_components]item_data.Component = undefined,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*CreativeInventory {
        const self = try allocator.create(CreativeInventory);
        self.* = .{
            .deps = deps,
            .decode_scratch = try allocator.alloc(u8, deps.inventories.config.max_item_bytes),
        };
        try deps.input.on(.set_creative_slot, self, onCreativeSlot);
        try deps.players.observeDig(self, onDig);
        return self;
    }

    fn onDig(self: *CreativeInventory, handle: sessions.Handle, dig: minecraft.Dig) !void {
        if (dig.action != .swap_hands and dig.action != .drop_item and dig.action != .drop_stack) return;
        try self.apply(handle.index, .{ .dig = dig });
    }

    fn onCreativeSlot(self: *CreativeInventory, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_set_creative_slot.Reader) !void {
        const player = self.deps.players.records[handle.index];
        if (player.handle == null or player.stage != .ready or self.deps.player_states.of(&player).gamemode != .creative) return;
        const slot, const next = body.slot() catch return error.InvalidPacket;
        if (slot != -1 and (slot < 1 or slot > 45)) return;
        const selected = try self.deps.packets.definition(body.protocolNumber());
        const value = item_packets.readStack(self.deps.items, self.decode_scratch, &self.decode_components, next._cursor.rest, selected, self.deps.players.records[handle.index].uuid) catch |err| {
            std.log.warn("event=creative_item_rejected protocol={d} error={s}", .{ selected.number, @errorName(err) });
            self.deps.inventory.states[handle.index].dirty = PlayerInventory.all_slots;
            return;
        };
        try self.apply(handle.index, .{ .creative_slot = .{ .slot = slot, .item = value } });
    }

    /// Applies a creative slot packet or a hand action from the player in a slot. Input
    /// handlers decode packets into these.
    pub fn apply(self: *CreativeInventory, player_index: usize, action: Action) !void {
        const menu = self.deps.inventory;
        const service = self.deps.sessions;
        errdefer menu.fail();
        const player = &self.deps.players.records[player_index];
        const state = &menu.states[player_index];
        if (player.handle == null) return;
        const status = self.deps.player_states.of(player);
        if (player.stage != .ready or status.gamemode != .creative or state.external) return;
        state.selected = status.selected_slot;

        var slots: [47]inventories.Slot = undefined;
        var contents: [47]inventories.Contents = undefined;
        try menu.load(player_index, &slots, &contents);
        var next: [47]?inventories.Stack = undefined;
        for (&next, contents) |*stack, value| stack.* = value.stack;

        if (state.close) return;
        // Creative packets replace slots. The client does not report its cursor.
        assert(next[PlayerInventory.cursor] == null);
        var accepted: u64 = 0;
        var drops: [1]inventories.Stack = undefined;
        var drop_count: usize = 0;
        switch (action) {
            .creative_slot => |set| set_action: {
                if (set.slot != -1 and (set.slot < 1 or set.slot > 45)) break :set_action;
                const target: usize = if (set.slot == -1) PlayerInventory.cursor else @intCast(set.slot);
                if (set.slot != -1) {
                    state.dirty |= @as(u64, 1) << @intCast(target);
                    accepted &= ~(@as(u64, 1) << @intCast(target));
                }
                var stack: ?inventories.Stack = null;
                if (set.item) |value| {
                    const amount = value.count;
                    if (amount <= 0 or amount > 99) break :set_action;
                    if (value.encoded_bytes > self.deps.inventories.config.max_item_bytes or value.encoded_bytes + 256 > service.config.page_bytes) break :set_action;
                    stack = .{ .item = try item_data.define(self.deps.inventories, value.kind, value.components), .count = @intCast(amount) };
                }

                if (set.slot == -1) {
                    if (stack) |held| {
                        drops[0] = held;
                        drop_count = 1;
                    }
                    break :set_action;
                }
                next[target] = stack;
                accepted |= @as(u64, 1) << @intCast(target);
                if (stack) |value| {
                    const prepared = try self.deps.items.acquire(value);
                    defer prepared.release();
                    if (try self.deps.items.components.requiresCorrection(prepared.view, player.uuid)) accepted &= ~(@as(u64, 1) << @intCast(target));
                }
            },
            .dig => |dig| dig_action: {
                if (status.health == 0) break :dig_action;
                const at = 36 + @as(usize, state.selected);
                if (dig.action == .swap_hands) {
                    std.mem.swap(?inventories.Stack, &next[at], &next[45]);
                    accepted &= ~((@as(u64, 1) << @intCast(at)) | (@as(u64, 1) << 45));
                } else if (dig.action == .drop_item or dig.action == .drop_stack) {
                    const held = next[at] orelse break :dig_action;
                    const amount = if (dig.action == .drop_stack) held.count else 1;
                    drops[0] = .{ .item = held.item, .count = amount };
                    drop_count = 1;
                    next[at] = if (amount == held.count) null else .{ .item = held.item, .count = held.count - amount };
                    accepted &= ~(@as(u64, 1) << @intCast(at));
                }
            },
        }

        if (!try menu.apply(player_index, &slots, &contents, &next, drops[0..drop_count])) {
            state.dirty = PlayerInventory.all_slots;
            return;
        }
        state.dirty &= ~accepted;
    }

    pub fn tick(self: *CreativeInventory) !void {
        const menu = self.deps.inventory;
        const service = self.deps.sessions;
        connections: for (self.deps.players.activeSlots()) |player_index| {
            const player = &self.deps.players.records[player_index];
            const state = &menu.states[player_index];
            const handle = player.handle orelse continue;
            const gamemode = self.deps.player_states.of(player).gamemode;
            // The inventory goes out once the position is confirmed, before the client can act on
            // it. Waiting until the client has loaded lets the first full inventory cross its first
            // creative edit and erase that edit on the client.
            if (player.stage != .ready or gamemode != .creative) continue;
            if (state.external) continue;
            if (state.close) try menu.closeMenu(player_index);
            if (state.presentation != self.deps.items.components.revision) {
                state.presentation = self.deps.items.components.revision;
                state.dirty = PlayerInventory.all_slots;
            }
            if (state.dirty == 0 and state.generation == handle.generation and state.life == player.life and state.gamemode == gamemode) continue;
            menu.synchronize(player_index, self.deps.packets, service) catch |err| switch (err) {
                error.EndOfStream, error.UnsupportedItem, error.UnsupportedComponent => service.disconnect(handle),
                error.Backpressured, error.Closed => continue :connections,
                else => return err,
            };
        }
    }
};
