const std = @import("std");
const entities = @import("entities");
const wire_1_21_5 = @import("wire_1_21_5");
const packets = @import("minecraft_packets");
const item_entities = @import("item_entities.zig");
const inventories = @import("inventories");
const game_data = @import("game_data");
const minecraft = @import("minecraft_model");
const Players = @import("players.zig").Players;
const Items = @import("items.zig").Items;
const EquipmentSlots = @import("item_properties.zig").EquipmentSlots;
const sessions = @import("sessions");
const item_packets = @import("item_packets.zig");

const assert = std.debug.assert;

pub const PlayerInventory = struct {
    pub const id = "minecraft:player_inventory";

    pub const Configuration = struct {};

    pub const Dependencies = struct {
        players: *Players,
        inventories: *inventories.Inventories,
        items: *Items,
        equipment: *EquipmentSlots,
        dropped: *item_entities.ItemEntities,
    };

    pub const State = struct {
        generation: u32 = 0,
        life: u32 = 0,
        revision: i32 = 0,
        presentation: u64 = 0,
        dirty: u64 = all_slots,
        drag: u64 = 0,
        drag_button: ?i8 = null,
        selected: u4 = 0,
        close: bool = true,
        synchronized: bool = false,
        gamemode: minecraft.GameMode = .survival,
    };

    pub const cursor = 46;
    pub const all_slots = (@as(u64, 1) << 47) - 1;

    pub fn writeInventory(packet: wire_1_21_5.play.toClient.packet_window_items.Writer, registry: packets.Registry, store: *Items, revision: i32, contents: []const inventories.Contents, recipient: u128) ![]u8 {
        assert(contents.len == 47);
        const body = try (try packet.windowId(0)).stateId(revision);
        var items = try body.items(46);
        var base: usize = 0;
        while (base < 46) {
            const count = @min(16, store.views.len, 46 - base);
            var stacks: [16]inventories.Stack = undefined;
            var prepared: [16]Items.Prepared = undefined;
            var occupied: usize = 0;
            for (contents[base..][0..count]) |entry| if (entry.stack) |stack| {
                stacks[occupied] = stack;
                occupied += 1;
            };
            try store.acquireMany(stacks[0..occupied], prepared[0..occupied]);
            defer for (prepared[0..occupied]) |held| held.release();
            var index: usize = 0;
            for (contents[base..][0..count]) |entry| {
                const view = if (entry.stack != null) prepared[index].view else null;
                index += @intFromBool(entry.stack != null);
                const item = (try items.next()).?;
                try items.advance(try item_packets.writeSlot(item, .{
                    .registry = registry,
                    .items = store,
                    .stack = entry.stack,
                    .recipient = recipient,
                    .view = view,
                }));
            }
            base += count;
        }
        const prepared_cursor = if (contents[46].stack) |stack| try store.acquire(stack) else null;
        defer if (prepared_cursor) |prepared| prepared.release();
        const carried = try items.finish();
        var item = try carried.carriedItem();
        const done = try item_packets.writeSlot(try item.begin(), .{
            .registry = registry,
            .items = store,
            .stack = contents[46].stack,
            .view = if (prepared_cursor) |prepared| prepared.view else null,
            .recipient = recipient,
        });
        return (try item.advance(done)).finish();
    }

    deps: Dependencies,
    states: []State,
    const maximum_drops = 128;

    pub fn fail(self: *PlayerInventory) void {
        self.deps.inventories.deps.storage.fail();
    }

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*PlayerInventory {
        if (deps.inventories.cache.entries.len < 47) return error.InventoryCacheTooSmall;

        const self = try allocator.create(PlayerInventory);
        const states = try allocator.alloc(State, deps.players.records.len);
        @memset(states, .{});
        self.* = .{
            .deps = deps,
            .states = states,
        };
        return self;
    }

    pub const allocate = init;

    pub fn load(self: *PlayerInventory, index: usize, slots: *[47]inventories.Slot, contents: *[47]inventories.Contents) !void {
        const player = &self.deps.players.records[index];
        const handle = player.handle.?;
        const state = &self.states[index];
        if (state.generation != handle.generation or state.life != player.life or state.gamemode != player.gamemode) {
            state.* = .{ .generation = handle.generation, .life = player.life, .selected = player.selected_slot, .gamemode = player.gamemode };
        }
        for (slots, 0..) |*slot, at| slot.* = .{
            .owner = player.uuid,
            .index = if (at == cursor) std.math.maxInt(u16) else @intCast(at),
        };
        try self.deps.inventories.getMany(slots, contents);
        if (!state.close) return;
        var next: [47]?inventories.Stack = undefined;
        for (&next, contents) |*stack, entry| stack.* = entry.stack;
        var drops: [5]inventories.Stack = undefined;
        var count: usize = 0;
        for ([_]usize{ cursor, 1, 2, 3, 4 }) |source| {
            if (try self.returnStack(state.selected, source, &next)) |overflow| {
                drops[count] = overflow;
                count += 1;
            }
        }
        if (try self.apply(index, slots, contents, &next, drops[0..count])) state.close = false;
    }

    pub fn closeMenu(self: *PlayerInventory, index: usize) !void {
        const state = &self.states[index];
        state.close = true;
        state.selected = self.deps.players.records[index].selected_slot;
        state.drag = 0;
        state.drag_button = null;
        var slots: [47]inventories.Slot = undefined;
        var contents: [47]inventories.Contents = undefined;
        try self.load(index, &slots, &contents);
    }

    pub fn synchronize(self: *PlayerInventory, index: usize, encoding: *packets.Packets, service: *sessions.Service) !void {
        const player = self.deps.players.records[index];
        const handle = player.handle.?;
        const state = &self.states[index];
        assert(player.stage == .ready and player.loaded);
        if (service.outputCredit(handle) == 0) return error.Backpressured;
        const full = if (player.gamemode == .creative) all_slots & ~(@as(u64, 1) << cursor) else all_slots;
        const initial = !state.synchronized or state.generation != handle.generation or state.life != player.life or state.gamemode != player.gamemode;
        if (initial or (player.gamemode != .creative and state.dirty & full == full)) {
            var slots: [47]inventories.Slot = undefined;
            var contents: [47]inventories.Contents = undefined;
            try self.load(index, &slots, &contents);
            try encoding.sendPacket(writeInventory, player.protocol, handle, .{
                self.deps.items, state.revision, &contents, player.uuid,
            }, service.config.page_bytes);
            state.dirty = 0;
            state.synchronized = true;
            return;
        }
        // A creative inventory refresh must not overwrite the client's unreported cursor.
        if (player.gamemode == .creative) state.dirty &= ~(@as(u64, 1) << cursor);
        assert(state.dirty & ~all_slots == 0);
        var slots: [47]inventories.Slot = undefined;
        var contents: [47]inventories.Contents = undefined;
        var indices: [47]u6 = undefined;
        var count: usize = 0;
        var dirty = state.dirty;
        while (dirty != 0) {
            const slot = @ctz(dirty);
            indices[count] = @intCast(slot);
            slots[count] = .{ .owner = player.uuid, .index = if (slot == cursor) std.math.maxInt(u16) else @intCast(slot) };
            count += 1;
            dirty &= dirty - 1;
        }
        if (count == 0) return;
        try self.deps.inventories.getMany(slots[0..count], contents[0..count]);
        var base: usize = 0;
        while (base < count) {
            if (service.outputCredit(handle) == 0) return error.Backpressured;
            const length = @min(16, self.deps.items.views.len, count - base);
            assert(length > 0);
            var stacks: [16]inventories.Stack = undefined;
            var prepared: [16]Items.Prepared = undefined;
            var occupied: usize = 0;
            for (contents[base..][0..length]) |entry| if (entry.stack) |stack| {
                stacks[occupied] = stack;
                occupied += 1;
            };
            try self.deps.items.acquireMany(stacks[0..occupied], prepared[0..occupied]);
            defer for (prepared[0..occupied]) |held| held.release();
            var at: usize = 0;
            for (contents[base..][0..length], indices[base..][0..length]) |entry, slot| {
                const view = if (entry.stack != null) prepared[at].view else null;
                at += @intFromBool(entry.stack != null);
                if (slot == cursor) {
                    try encoding.sendPacketRetrying(writeCursor, player.protocol, handle, .{
                        self.deps.items, entry.stack, player.uuid, view,
                    }, service.config.page_bytes);
                } else {
                    try encoding.sendPacketRetrying(writeSlot, player.protocol, handle, .{
                        self.deps.items, state.revision, @as(i16, slot), entry.stack, player.uuid, view,
                    }, service.config.page_bytes);
                }
                state.dirty &= ~(@as(u64, 1) << slot);
            }
            base += length;
        }
        assert(state.dirty == 0);
    }

    pub fn writeSlot(packet: wire_1_21_5.play.toClient.packet_set_slot.Writer, registry: packets.Registry, store: *Items, revision: i32, slot: i16, stack: ?inventories.Stack, recipient: u128, view: ?Items.View) ![]u8 {
        assert(slot >= 0 and slot < 46);
        assert((stack == null) == (view == null));
        const window = try packet.windowId(0);
        const state = try window.stateId(revision);
        const position = try state.slot(slot);
        var item = try position.item();
        const done = try item_packets.writeSlot(try item.begin(), .{
            .registry = registry,
            .items = store,
            .stack = stack,
            .recipient = recipient,
            .view = view,
        });
        return (try item.advance(done)).finish();
    }

    pub fn writeCursor(packet: wire_1_21_5.play.toClient.packet_set_cursor_item.Writer, registry: packets.Registry, store: *Items, stack: ?inventories.Stack, recipient: u128, view: ?Items.View) ![]u8 {
        assert((stack == null) == (view == null));
        var item = try packet.contents();
        const done = try item_packets.writeSlot(try item.begin(), .{
            .registry = registry,
            .items = store,
            .stack = stack,
            .recipient = recipient,
            .view = view,
        });
        return (try item.advance(done)).finish();
    }

    pub fn apply(self: *PlayerInventory, index: usize, slots: *const [47]inventories.Slot, contents: *[47]inventories.Contents, next: *const [47]?inventories.Stack, drops: []const inventories.Stack) !bool {
        const state = &self.states[index];
        assert(state.generation == self.deps.players.records[index].handle.?.generation);
        assert(slots[cursor].index == std.math.maxInt(u16));
        if (drops.len > maximum_drops) return false;
        if (drops.len != 0 and !self.deps.dropped.canCreate(drops.len)) return false;
        errdefer self.fail();
        if (!try self.dropMany(self.deps.players.records[index], drops)) return false;
        var edits: [47]inventories.Edit = undefined;
        var count: usize = 0;
        for (next, contents, slots, 0..) |stack, old, slot, at| {
            if (std.meta.eql(stack, old.stack)) continue;
            edits[count] = .{ .slot = slot, .revision = old.revision, .stack = stack };
            count += 1;
            state.dirty |= @as(u64, 1) << @intCast(at);
        }
        const committed = try self.deps.inventories.editMany(edits[0..count]);
        assert(committed);
        for (contents, next) |*old, stack| {
            old.revision += @intFromBool(!std.meta.eql(old.stack, stack));
            old.stack = stack;
        }
        state.revision = (state.revision + 1) & 32767;
        return true;
    }

    pub fn returnStack(self: *PlayerInventory, selected: u4, source: usize, next: *[47]?inventories.Stack) !?inventories.Stack {
        assert(selected <= 8);
        assert(source == cursor or (source >= 1 and source <= 4));
        const held = next[source] orelse return null;
        const maximum = try self.deps.items.stackLimit(held);
        var remaining = held.count;
        for (0..2) |pass| for (0..38) |offset| {
            const target: usize = if (offset == 0) 36 + @as(usize, selected) else if (offset == 1) 45 else if (offset < 11) offset + 34 else offset - 2;
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
        next[source] = null;
        return if (remaining == 0) null else .{ .item = held.item, .count = remaining };
    }

    pub fn slotLimit(self: *PlayerInventory, slot: usize, stack: inventories.Stack) !u16 {
        return if (slot == 0) 0 else if (slot >= 5 and slot < 9) @intFromBool(try self.deps.equipment.slot(stack) == 10 - slot) else self.deps.items.stackLimit(stack);
    }

    /// All drops in an action are admitted together. No other producer interleaves on this owner.
    pub fn dropMany(self: *PlayerInventory, player: Players.Player, stacks: []const inventories.Stack) !bool {
        if (stacks.len == 0) return true;
        if (stacks.len > maximum_drops) return error.WorkingSetTooLarge;
        if (!self.deps.dropped.canCreate(stacks.len)) return false;
        const yaw = @as(f64, player.rotation.yaw) * std.math.pi / 180;
        const pitch = @as(f64, player.rotation.pitch) * std.math.pi / 180;
        const velocity: [3]f64 = .{ -@sin(yaw) * @cos(pitch) * 0.3, -@sin(pitch) * 0.3 + 0.1, @cos(yaw) * @cos(pitch) * 0.3 };
        var requests: [maximum_drops]item_entities.ItemEntities.Spawn = undefined;
        var ids: [maximum_drops]entities.Id = undefined;
        for (stacks, requests[0..stacks.len]) |stack, *request| request.* = .{ .world = player.world, .position = .{ player.position.x, player.position.y + 1.32, player.position.z }, .velocity = velocity, .stack = stack, .metadata = .{ .pickup_delay = 40 } };
        try self.deps.dropped.createMany(requests[0..stacks.len], ids[0..stacks.len]);
        return true;
    }

    pub fn give(self: *PlayerInventory, player: usize, name: []const u8, count: u16) !bool {
        return self.trade(player, name, count, true);
    }

    /// Plans the complete ownership change before mutating any slot.
    pub fn trade(self: *PlayerInventory, player: usize, name: []const u8, count: u16, buying: bool) !bool {
        const item = game_data.registry.itemId(name) orelse return error.UnknownItem;
        if (count == 0) return error.InvalidCount;

        const maximum = game_data.registry.items[@intCast(item)].stack_size;
        const owner = self.deps.players.records[player].uuid;
        const definition_id = try self.deps.items.define(name);
        var slots: [36]inventories.Slot = undefined;

        for (&slots, 0..) |*slot, index| slot.* = .{ .owner = owner, .index = @intCast(if (index < 9) index + 36 else index) };

        var contents: [36]inventories.Contents = undefined;
        try self.deps.inventories.getMany(&slots, &contents);
        var edits: [36]inventories.Edit = undefined;
        var edited: usize = 0;
        var remaining = count;

        for (0..if (buying) @as(usize, 2) else 1) |pass| for (slots, contents) |slot, value| {
            if (remaining == 0) break;

            const previous = if (value.stack) |stack| stack.count else 0;

            if (value.stack) |stack| {
                if (pass != 0 or !std.mem.eql(u8, &stack.item, &definition_id)) continue;
            } else if (!buying or pass == 0) continue;
            const amount = @min(remaining, if (buying) maximum -| previous else previous);
            if (amount == 0) continue;

            const after = if (buying) previous + amount else previous - amount;
            edits[edited] = .{
                .slot = slot,
                .revision = value.revision,
                .stack = if (after == 0) null else .{ .item = definition_id, .count = after },
            };
            edited += 1;
            remaining -= amount;
        };

        if (remaining != 0) return false;

        const committed = try self.deps.inventories.editMany(edits[0..edited]);
        assert(committed);
        self.changed(player);
        return true;
    }

    pub fn changed(self: *PlayerInventory, player: usize) void {
        assert(player < self.states.len);
        self.states[player].dirty = all_slots;
        self.states[player].revision = (self.states[player].revision + 1) & 32767;
    }
};
