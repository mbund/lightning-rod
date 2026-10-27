const std = @import("std");
const wire_1_21_5 = @import("wire_1_21_5");
const wire_1_21_6 = @import("wire_1_21_6");
const wire_1_21_9 = @import("wire_1_21_9");
const wire_1_21_11 = @import("wire_1_21_11");
const wire_26_1 = @import("wire_26_1");
const wire_26_2 = @import("wire_26_2");
const packets = @import("minecraft_packets");
const inventories = @import("inventories");
const sessions = @import("sessions");
const minecraft = @import("minecraft_model");
const item_data = @import("item_data.zig");
const item_packets = @import("item_packets.zig");
const PlayerInventory = @import("player_inventory.zig").PlayerInventory;
const Items = @import("items.zig").Items;
const Players = @import("players.zig").Players;
const Input = @import("input.zig").Input;
const lightning_rod = @import("lightning_rod");

const assert = std.debug.assert;

pub const CreativeInventory = struct {
    pub const id = "minecraft:creative_inventory";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        inventory: *PlayerInventory,
        input: *Input,
        players: *Players,
        sessions: *sessions.Service,
        packets: *packets.Packets,
        inventories: *inventories.Inventories,
        items: *Items,
    };
    const Action = union(enum) { creative_slot: struct { slot: i16, item: ?item_packets.Incoming }, dig: minecraft.Dig };
    const Balance = struct {
        item: inventories.ItemId,
        count: i32 = 0,
        origin: u16,
        order: usize = 0,
    };
    const Batch = struct {
        balances: [47]Balance,
        count: usize,
        revision: i32,
        order: usize = 0,
    };

    deps: Dependencies,
    batches: []?*Batch,
    batch_storage: []Batch,
    decode_scratch: []u8,
    decode_components: [item_data.maximum_components]item_data.Component = undefined,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*CreativeInventory {
        const self = try allocator.create(CreativeInventory);
        const count = deps.players.records.len;
        self.* = .{
            .deps = deps,
            .batches = try allocator.alloc(?*Batch, count),
            .batch_storage = try allocator.alloc(Batch, count),
            .decode_scratch = try allocator.alloc(u8, deps.inventories.config.max_item_bytes),
        };
        @memset(self.batches, null);
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
        if (player.handle == null or player.stage != .ready or player.gamemode != .creative) return;
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

    fn apply(self: *CreativeInventory, player_index: usize, action: ?Action) !void {
        const menu = self.deps.inventory;
        const service = self.deps.sessions;
        errdefer menu.fail();
        const player = &self.deps.players.records[player_index];
        const state = &menu.states[player_index];
        if (player.handle == null) return;
        if (player.stage != .ready or player.gamemode != .creative) return;
        state.selected = player.selected_slot;

        var slots: [47]inventories.Slot = undefined;
        var contents: [47]inventories.Contents = undefined;
        try menu.load(player_index, &slots, &contents);
        const dropping = if (action) |event| switch (event) {
            .creative_slot => |set| set.slot == -1 and set.item != null,
            .dig => |dig| dig.action == .drop_item or dig.action == .drop_stack,
        } else false;
        if (dropping and !menu.deps.dropped.canCreate(1)) {
            state.dirty = PlayerInventory.all_slots;
            return;
        }
        var next: [47]?inventories.Stack = undefined;
        for (&next, contents) |*stack, value| stack.* = value.stack;

        var key: [16]u8 = undefined;
        std.mem.writeInt(u128, &key, player.uuid, .big);
        const lease = try menu.recovery.acquire(&key);
        defer lease.release();
        var pending: ?inventories.Stack = null;
        var origin: u16 = 36;
        if (lease.read()) |bytes| {
            const recovery = try PlayerInventory.decodeRecovery(bytes);
            pending = recovery.stack;
            origin = recovery.origin;
        }
        if (next[PlayerInventory.cursor]) |held| {
            assert(pending == null);
            pending = held;
            origin = 36 + @as(u16, state.selected);
            next[PlayerInventory.cursor] = null;
        }
        state.close = false;

        var balances: [47]Balance = undefined;
        var count: usize = 0;
        var batch = self.batches[player_index];
        if (batch) |current| if (current.revision != state.revision) {
            batch = null;
            self.batches[player_index] = null;
        };
        if (batch) |current| {
            balances = current.balances;
            count = current.count;
        } else {
            if (pending) |held| {
                balances[0] = .{ .item = held.item, .count = held.count, .origin = origin };
                count = 1;
            }
            for (next[1..46], 1..) |stack, at| if (stack) |held| {
                var index: usize = 0;
                while (index < count and !std.mem.eql(u8, &balances[index].item, &held.item)) : (index += 1) {}
                if (index == count) {
                    assert(count < balances.len);
                    balances[count] = .{ .item = held.item, .origin = @intCast(at) };
                    count += 1;
                }
                balances[index].count += held.count;
            };
            if (action != null) {
                batch = &self.batch_storage[player_index];
                batch.?.* = .{ .balances = balances, .count = count, .revision = state.revision };
                self.batches[player_index] = batch;
            }
        }
        var accepted: u64 = 0;

        const events: []const Action = if (action) |value| &.{value} else &.{};
        for (events) |event| {
            if (batch) |current| current.order += 1;
            const order = if (batch) |current| current.order else 0;
            switch (event) {
                .creative_slot => |set| {
                    if (set.slot != -1 and (set.slot < 1 or set.slot > 45)) continue;
                    const target: usize = if (set.slot == -1) PlayerInventory.cursor else @intCast(set.slot);
                    if (set.slot != -1) {
                        state.dirty |= @as(u64, 1) << @intCast(target);
                        accepted &= ~(@as(u64, 1) << @intCast(target));
                    }
                    var stack: ?inventories.Stack = null;
                    if (set.item) |value| {
                        const amount = value.count;
                        if (amount <= 0 or amount > 99) continue;
                        if (value.encoded_bytes > self.deps.inventories.config.max_item_bytes or value.encoded_bytes + 256 > service.config.page_bytes) continue;
                        stack = .{ .item = try item_data.define(self.deps.inventories, value.kind, value.components), .count = @intCast(amount) };
                    }

                    if (set.slot == -1) {
                        if (stack) |held| {
                            try menu.drop(player.*, held);
                            for (balances[0..count]) |*balance| if (std.mem.eql(u8, &balance.item, &held.item)) {
                                balance.count -= held.count;
                            };
                            if (batch) |current| for (current.balances[0..count]) |*balance| {
                                if (std.mem.eql(u8, &balance.item, &held.item)) balance.count -= held.count;
                            };
                        }
                        continue;
                    }
                    if (next[target]) |before| {
                        const retained = if (stack) |after| if (inventories.Stack.sameItem(before, after)) after.count else 0 else 0;
                        if (retained < before.count) for (balances[0..count]) |*balance| if (std.mem.eql(u8, &balance.item, &before.item)) {
                            balance.origin = @intCast(target);
                            balance.order = order;
                        };
                        if (retained < before.count) if (batch) |current| for (current.balances[0..count]) |*balance| {
                            if (std.mem.eql(u8, &balance.item, &before.item)) {
                                balance.origin = @intCast(target);
                                balance.order = order;
                            }
                        };
                    }
                    next[target] = stack;
                    accepted |= @as(u64, 1) << @intCast(target);
                },
                .dig => |dig| {
                    if (player.health == 0) continue;
                    const at = 36 + @as(usize, state.selected);
                    if (dig.action == .swap_hands) {
                        std.mem.swap(?inventories.Stack, &next[at], &next[45]);
                        accepted &= ~((@as(u64, 1) << @intCast(at)) | (@as(u64, 1) << 45));
                    } else if (dig.action == .drop_item or dig.action == .drop_stack) {
                        const held = next[at] orelse continue;
                        const amount = if (dig.action == .drop_stack) held.count else 1;
                        try menu.drop(player.*, .{ .item = held.item, .count = amount });
                        next[at] = if (amount == held.count) null else .{ .item = held.item, .count = held.count - amount };
                        accepted &= ~(@as(u64, 1) << @intCast(at));
                        for (balances[0..count]) |*balance| if (std.mem.eql(u8, &balance.item, &held.item)) {
                            balance.count -= amount;
                        };
                        if (batch) |current| for (current.balances[0..count]) |*balance| {
                            if (std.mem.eql(u8, &balance.item, &held.item)) balance.count -= amount;
                        };
                    }
                },
            }
        }

        for (next[1..46]) |stack| if (stack) |held| {
            for (balances[0..count]) |*balance| if (std.mem.eql(u8, &balance.item, &held.item)) {
                balance.count -= held.count;
            };
        };
        var selected: ?usize = null;
        for (balances[0..count], 0..) |balance, index| {
            if (balance.count <= 0) continue;
            if (selected == null or balance.order >= balances[selected.?].order) selected = index;
        }
        if (selected) |index| {
            const balance = balances[index];
            const held: inventories.Stack = .{ .item = balance.item, .count = 1 };
            const amount: u16 = @intCast(@min(balance.count, try self.deps.items.stackLimit(held)));
            try menu.writeRecovery(lease, .{ .stack = .{ .item = balance.item, .count = amount }, .origin = balance.origin });
        } else try menu.writeRecovery(lease, null);
        try menu.commit(state, &slots, &contents, &next);
        if (batch) |current| current.revision = state.revision;
        // A computed presentation differs from the client's accepted proposal.
        if (!self.deps.items.components.has_presentation) state.dirty &= ~accepted;
    }

    pub fn tick(self: *CreativeInventory) !void {
        const menu = self.deps.inventory;
        const service = self.deps.sessions;
        connections: for (self.deps.players.activeSlots()) |player_index| {
            const player = &self.deps.players.records[player_index];
            const state = &menu.states[player_index];
            const handle = player.handle orelse {
                self.batches[player_index] = null;
                continue;
            };
            if (player.stage != .ready or !player.loaded or player.gamemode != .creative) {
                self.batches[player_index] = null;
                continue;
            }
            const pending_batch = self.batches[player_index] != null;
            if (state.presentation != self.deps.items.components.revision) {
                state.presentation = self.deps.items.components.revision;
                state.dirty = PlayerInventory.all_slots;
            }
            if (!pending_batch and state.dirty == 0 and state.generation == handle.generation and state.life == player.life and state.gamemode == player.gamemode) continue;
            try self.apply(player_index, null);
            self.batches[player_index] = null;
            menu.synchronize(player_index, self.deps.packets, service) catch |err| switch (err) {
                error.EndOfStream, error.UnsupportedItem, error.UnsupportedComponent => service.disconnect(handle),
                error.Backpressured, error.Closed => continue :connections,
                else => return err,
            };
        }
    }
};
