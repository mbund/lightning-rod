const std = @import("std");
const wire_1_21_5 = @import("wire_1_21_5");
const packets = @import("minecraft_packets");
const item_entities = @import("item_entities.zig");
const inventories = @import("inventories");
const game_data = @import("game_data");
const minecraft = @import("minecraft_model");
const records = @import("records");
const lightning_rod = @import("lightning_rod");
const Players = @import("players.zig").Players;
const Input = @import("input.zig").Input;
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
        input: *Input,
        inventories: *inventories.Inventories,
        items: *Items,
        equipment: *EquipmentSlots,
        dropped: *item_entities.ItemEntities,
        storage: lightning_rod.storage.Namespace,
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
        gamemode: minecraft.GameMode = .survival,
    };

    pub const cursor = 46;
    pub const all_slots = (@as(u64, 1) << 47) - 1;

    pub fn writeInventory(packet: wire_1_21_5.play.toClient.packet_window_items.Writer, registry: packets.Registry, store: *Items, revision: i32, contents: []const inventories.Contents, recipient: u128) ![]u8 {
        assert(contents.len == 47);
        const body = try (try packet.windowId(0)).stateId(revision);
        var items = try body.items(46);
        for (contents[0..46]) |entry| {
            const item = (try items.next()).?;
            try items.advance(try item_packets.writeSlot(item, .{
                .registry = registry,
                .items = store,
                .stack = entry.stack,
                .recipient = recipient,
            }));
        }
        const carried = try items.finish();
        var item = try carried.carriedItem();
        const done = try item_packets.writeSlot(try item.begin(), .{
            .registry = registry,
            .items = store,
            .stack = contents[46].stack,
            .recipient = recipient,
        });
        return (try item.advance(done)).finish();
    }

    deps: Dependencies,
    states: []State,
    recovery: records.Cache,

    pub fn fail(self: *PlayerInventory) void {
        self.deps.storage.fail();
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io, deps: Dependencies) !*PlayerInventory {
        if (deps.inventories.cache.entries.len < 47) return error.InventoryCacheTooSmall;

        const self = try allocator.create(PlayerInventory);
        const states = try allocator.alloc(State, deps.players.records.len);
        @memset(states, .{});
        self.* = .{
            .deps = deps,
            .states = states,
            .recovery = try records.Cache.init(allocator, io, deps.storage, .{
                .slots = @max(1, states.len),
                .key_bytes = 16,
                .value_bytes = 36,
            }),
        };
        return self;
    }

    pub fn load(self: *PlayerInventory, index: usize, slots: *[47]inventories.Slot, contents: *[47]inventories.Contents) !void {
        const player = &self.deps.players.records[index];
        const handle = player.handle.?;
        const state = &self.states[index];
        if (state.generation != handle.generation or state.life != player.life or state.gamemode != player.gamemode)
            state.* = .{ .generation = handle.generation, .life = player.life, .selected = player.selected_slot, .gamemode = player.gamemode };
        for (slots, 0..) |*slot, at| slot.* = .{
            .owner = player.uuid,
            .index = if (at == cursor) std.math.maxInt(u16) else @intCast(at),
        };
        try self.deps.inventories.getMany(slots, contents);
        if (!state.close) return;
        errdefer self.deps.storage.fail();
        var key: [16]u8 = undefined;
        std.mem.writeInt(u128, &key, player.uuid, .big);
        const lease = try self.recovery.acquire(&key);
        defer lease.release();
        const bytes = lease.read() orelse return;
        const pending = try decodeRecovery(bytes);
        const held = pending.stack;
        const maximum = try self.deps.items.stackLimit(held);
        if (held.count > maximum) return error.Corrupt;
        var next: [47]?inventories.Stack = undefined;
        for (&next, contents) |*stack, value| stack.* = value.stack;
        var remaining = held.count;

        for (0..3) |pass| for (0..36) |offset| {
            if (remaining == 0) break;
            if (pass == 0 and offset != 0) break;
            const target: usize = if (pass == 0) pending.origin else if (offset < 9) offset + 36 else offset;
            const previous = if (next[target]) |stack| stack.count else 0;
            if (next[target]) |stack| {
                if (pass == 2 or !inventories.Stack.sameItem(held, stack)) continue;
            } else if (pass == 1) continue;
            const limit = if (pass == 0) try self.slotLimit(target, held) else maximum;
            const amount = @min(remaining, limit -| previous);
            if (amount == 0) continue;
            next[target] = .{ .item = held.item, .count = previous + amount };
            remaining -= amount;
        };
        if (remaining != 0) try self.drop(player.*, .{ .item = held.item, .count = remaining });
        try self.commit(state, slots, contents, &next);
        lease.remove();
    }

    pub const Recovery = struct { stack: inventories.Stack, origin: u16 };

    pub fn decodeRecovery(bytes: []const u8) !Recovery {
        if (bytes.len != 36) return error.Corrupt;
        const result: Recovery = .{
            .stack = .{ .item = bytes[0..32].*, .count = std.mem.readInt(u16, bytes[32..34], .little) },
            .origin = std.mem.readInt(u16, bytes[34..36], .little),
        };
        if (result.origin == 0 or result.origin > 45 or result.stack.count == 0) return error.Corrupt;
        return result;
    }

    pub fn checkpoint(self: *PlayerInventory, _: lightning_rod.storage.Namespace) !void {
        try self.recovery.flush();
    }

    pub fn commit(self: *PlayerInventory, state: *State, slots: *const [47]inventories.Slot, contents: *[47]inventories.Contents, next: *const [47]?inventories.Stack) !void {
        var edits: [47]inventories.Edit = undefined;
        var count: usize = 0;
        for (next, contents, slots, 0..) |stack, old, slot, index| {
            if (std.meta.eql(stack, old.stack)) continue;
            edits[count] = .{ .slot = slot, .revision = old.revision, .stack = stack };
            count += 1;
            state.dirty |= @as(u64, 1) << @intCast(index);
        }
        const committed = try self.deps.inventories.editMany(edits[0..count]);
        assert(committed);
        for (contents, next) |*old, stack| {
            old.revision += @intFromBool(!std.meta.eql(old.stack, stack));
            old.stack = stack;
        }
        state.revision = (state.revision + 1) & 32767;
    }

    pub fn slotLimit(self: *PlayerInventory, slot: usize, stack: inventories.Stack) !u16 {
        return if (slot == 0) 0 else if (slot >= 5 and slot < 9) @intFromBool(try self.deps.equipment.slot(stack) == 10 - slot) else self.deps.items.stackLimit(stack);
    }

    pub fn drop(self: *PlayerInventory, player: Players.Player, stack: inventories.Stack) !void {
        const yaw = @as(f64, player.rotation.yaw) * std.math.pi / 180;
        const pitch = @as(f64, player.rotation.pitch) * std.math.pi / 180;
        const entity = try self.deps.dropped.create(player.world, .{ player.position.x, player.position.y + 1.32, player.position.z }, .{ -@sin(yaw) * @cos(pitch) * 0.3, -@sin(pitch) * 0.3 + 0.1, @cos(yaw) * @cos(pitch) * 0.3 }, stack);
        var metadata = try self.deps.dropped.get(entity);
        metadata.pickup_delay = 40;
        try self.deps.dropped.put(entity, metadata);
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
        self.states[player].dirty = all_slots;
        return true;
    }

    pub fn changed(self: *PlayerInventory, player: usize) void {
        assert(player < self.states.len);
        self.states[player].dirty = all_slots;
        self.states[player].revision = (self.states[player].revision + 1) & 32767;
    }
};
