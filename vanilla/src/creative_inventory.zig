const std = @import("std");
const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const worlds = @import("worlds");
const entities = @import("entities");
const ItemEntities = @import("item_entities.zig").ItemEntities;
const InventoryFixture = @import("inventory_test_fixture.zig").InventoryFixture;
const protocols = @import("protocols");
const wire_1_21_5 = @import("wire_1_21_5");
const packets = @import("minecraft_packets");
const inventories = @import("inventories");
const sessions = @import("sessions");
const minecraft = @import("minecraft_model");
const item_data = @import("item_data.zig");
const ItemProperties = @import("item_properties.zig").ItemProperties;
const item_packets = @import("item_packets.zig");
const PlayerInventory = @import("player_inventory.zig").PlayerInventory;
const Items = @import("items.zig").Items;
const Players = @import("players.zig").Players;
const Input = @import("input.zig").Input;

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

    fn apply(self: *CreativeInventory, player_index: usize, action: Action) !void {
        const menu = self.deps.inventory;
        const service = self.deps.sessions;
        errdefer menu.fail();
        const player = &self.deps.players.records[player_index];
        const state = &menu.states[player_index];
        if (player.handle == null) return;
        if (player.stage != .ready or player.gamemode != .creative or state.external) return;
        state.selected = player.selected_slot;

        var slots: [47]inventories.Slot = undefined;
        var contents: [47]inventories.Contents = undefined;
        try menu.load(player_index, &slots, &contents);
        const dropping = switch (action) {
            .creative_slot => |set| set.slot == -1 and set.item != null,
            .dig => |dig| dig.action == .drop_item or dig.action == .drop_stack,
        };
        if (dropping and !menu.deps.dropped.canCreate(1)) {
            state.dirty = PlayerInventory.all_slots;
            return;
        }
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
                if (player.health == 0) break :dig_action;
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
            if (player.stage != .ready or !player.loaded or player.gamemode != .creative) continue;
            if (state.external) continue;
            if (state.close) try menu.closeMenu(player_index);
            if (state.presentation != self.deps.items.components.revision) {
                state.presentation = self.deps.items.components.revision;
                state.dirty = PlayerInventory.all_slots;
            }
            if (state.dirty == 0 and state.generation == handle.generation and state.life == player.life and state.gamemode == player.gamemode) continue;
            menu.synchronize(player_index, self.deps.packets, service) catch |err| switch (err) {
                error.EndOfStream, error.UnsupportedItem, error.UnsupportedComponent => service.disconnect(handle),
                error.Backpressured, error.Closed => continue :connections,
                else => return err,
            };
        }
    }
};

test "creative replacements persist exact packet prefixes without inventing a cursor" {
    const io = std.testing.io;
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    for ([_]bool{ false, true }) |reverse| for (0..4) |received| {
        var directory = std.testing.tmpDir(.{});
        defer directory.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/creative", .{directory.sub_path});
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
        defer registry.deinit();
        {
            var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
            defer store.deinit();
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const fixture = try InventoryFixture.init(arena.allocator(), &store, &registry, &selected);
            defer fixture.service.deinit();
            const bread: inventories.Stack = .{ .item = try fixture.items.define("minecraft:bread"), .count = 17 };
            const stone: inventories.Stack = .{ .item = try fixture.items.define("minecraft:stone"), .count = 9 };
            try std.testing.expect(try fixture.ownership.editMany(&.{
                .{ .slot = .{ .owner = 1, .index = 36 }, .revision = 0, .stack = bread },
                .{ .slot = .{ .owner = 1, .index = 45 }, .revision = 0, .stack = stone },
            }));
            const actions = [_]CreativeInventory.Action{
                .{ .creative_slot = .{ .slot = 36, .item = .{ .count = stone.count, .kind = try fixture.items.kind(stone), .components = &.{}, .encoded_bytes = 10 } } },
                .{ .creative_slot = .{ .slot = 45, .item = .{ .count = bread.count, .kind = try fixture.items.kind(bread), .components = &.{}, .encoded_bytes = 10 } } },
            };
            for (0..@min(received, 2)) |index| {
                try fixture.creative.apply(0, actions[index ^ @intFromBool(reverse)]);
                try fixture.creative.tick();
            }
            if (received == 3) {
                try fixture.creative.apply(0, .{ .creative_slot = .{ .slot = 36, .item = null } });
                try fixture.menu.closeMenu(0);
                try std.testing.expect((try fixture.ownership.get(.{ .owner = 1, .index = 36 })).stack == null);
            }
            try fixture.ownership.checkpoint(fixture.ownership.deps.storage);
            _ = try store.commit(1);
            try store.waitDurable(store.lastCommit());
        }
        {
            var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
            defer store.deinit();
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const fixture = try InventoryFixture.init(arena.allocator(), &store, &registry, &selected);
            defer fixture.service.deinit();
            var slots: [47]inventories.Slot = undefined;
            var contents: [47]inventories.Contents = undefined;
            try fixture.menu.load(0, &slots, &contents);
            const source_changed = received >= 2 or (received == 1 and !reverse);
            const offhand_changed = received >= 2 or (received == 1 and reverse);
            if (received == 3) {
                try std.testing.expect(contents[36].stack == null);
            } else {
                try std.testing.expectEqualStrings(if (source_changed) "minecraft:stone" else "minecraft:bread", protocols.registry.itemName(@intCast(try fixture.items.kind(contents[36].stack.?))).?);
                try std.testing.expectEqual(@as(u16, if (source_changed) 9 else 17), contents[36].stack.?.count);
            }
            try std.testing.expectEqualStrings(if (offhand_changed) "minecraft:bread" else "minecraft:stone", protocols.registry.itemName(@intCast(try fixture.items.kind(contents[45].stack.?))).?);
            try std.testing.expectEqual(@as(u16, if (offhand_changed) 17 else 9), contents[45].stack.?.count);
            try std.testing.expect(contents[PlayerInventory.cursor].stack == null);
            const once = contents;
            try fixture.menu.load(0, &slots, &contents);
            try std.testing.expectEqualDeep(once, contents);
        }
    };
}

test "survival cursor placements drops and close preserve ownership across restart" {
    const io = std.testing.io;
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const Cut = enum { picked, placed, dropped, closed };
    for (std.enums.values(Cut)) |cut| {
        var directory = std.testing.tmpDir(.{});
        defer directory.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/cursor", .{directory.sub_path});
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
        defer registry.deinit();
        {
            var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
            defer store.deinit();
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const fixture = try InventoryFixture.init(arena.allocator(), &store, &registry, &selected);
            defer fixture.service.deinit();
            fixture.players.records[0].gamemode = .survival;
            const bread: inventories.Stack = .{ .item = try fixture.items.define("minecraft:bread"), .count = 17 };
            try std.testing.expect(try fixture.ownership.set(.{ .owner = 1, .index = 36 }, 0, bread));
            var slots: [47]inventories.Slot = undefined;
            var contents: [47]inventories.Contents = undefined;
            try fixture.menu.load(0, &slots, &contents);
            var next: [47]?inventories.Stack = undefined;
            for (&next, contents) |*stack, entry| stack.* = entry.stack;
            next[36] = null;
            next[PlayerInventory.cursor] = bread;
            try std.testing.expect(try fixture.menu.apply(0, &slots, &contents, &next, &.{}));
            try std.testing.expect((try fixture.ownership.get(slots[36])).stack == null);
            try std.testing.expectEqual(bread, (try fixture.ownership.get(slots[PlayerInventory.cursor])).stack.?);
            if (cut != .picked) {
                next[38] = .{ .item = bread.item, .count = 1 };
                next[PlayerInventory.cursor].?.count = 16;
                try std.testing.expect(try fixture.menu.apply(0, &slots, &contents, &next, &.{}));
                try std.testing.expectEqual(@as(u16, 1), (try fixture.ownership.get(slots[38])).stack.?.count);
            }
            if (cut == .dropped or cut == .closed) {
                next[PlayerInventory.cursor].?.count = 15;
                try std.testing.expect(try fixture.menu.apply(0, &slots, &contents, &next, &.{.{ .item = bread.item, .count = 1 }}));
                try std.testing.expectEqual(@as(usize, 7), fixture.dropped.free_count);
            }
            if (cut == .closed) {
                var buffer: [16]u8 = undefined;
                const packet = try protocols.implementations[0].Protocol.play.toServer.write(&buffer).close_window();
                const incoming = [_][]const u8{(try packet.windowId(0)).finish()};
                const events = [_]sessions.Event{.{ .input = .{ .handle = fixture.players.records[0].handle.?, .protocol = selected[0].number, .packets = .{ .packets = &incoming } } }};
                fixture.service.input_events = &events;
                try fixture.input.tick(std.testing.failing_allocator);
                fixture.service.input_events = &.{};
                try std.testing.expect((try fixture.ownership.get(slots[PlayerInventory.cursor])).stack == null);
            }
            try fixture.ownership.checkpoint(fixture.ownership.deps.storage);
            try fixture.bodies.checkpoint(fixture.bodies.deps.storage);
            try fixture.dropped.checkpoint(fixture.dropped.deps.storage);
            _ = try store.commit(1);
            try store.waitDurable(store.lastCommit());
        }
        {
            var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
            defer store.deinit();
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const fixture = try InventoryFixture.init(arena.allocator(), &store, &registry, &selected);
            defer fixture.service.deinit();
            var slots: [47]inventories.Slot = undefined;
            var contents: [47]inventories.Contents = undefined;
            try fixture.menu.load(0, &slots, &contents);
            try std.testing.expect(contents[PlayerInventory.cursor].stack == null);
            if (cut == .picked) {
                try std.testing.expectEqual(@as(u16, 17), contents[36].stack.?.count);
                try std.testing.expect(contents[38].stack == null);
            } else {
                try std.testing.expect(contents[36].stack == null);
                try std.testing.expectEqual(@as(u16, if (cut == .placed) 17 else 16), contents[38].stack.?.count);
            }
            var total: u32 = 0;
            for (contents) |entry| if (entry.stack) |stack| {
                total += stack.count;
            };
            for (fixture.dropped.residents) |resident| {
                if (resident.id == 0 or !resident.alive) continue;
                const body = (try fixture.bodies.get(resident.id)).?;
                const stack = (try fixture.ownership.get(ItemEntities.slot(body))).stack.?;
                try std.testing.expectEqual(@as(u16, 1), stack.count);
                total += stack.count;
            }
            try std.testing.expectEqual(@as(u32, 17), total);
        }
    }
}

test "creative proposals only echo computed corrections" {
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/creative", .{directory.sub_path});
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
    defer registry.deinit();
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const fixture = try InventoryFixture.init(arena.allocator(), &store, &registry, &selected);
    defer fixture.service.deinit();
    _ = try ItemProperties.init(arena.allocator(), .{ .items = fixture.items });
    const diamond = try fixture.items.kind(.{ .item = try fixture.items.define("minecraft:diamond"), .count = 1 });
    var slots: [47]inventories.Slot = undefined;
    var contents: [47]inventories.Contents = undefined;
    try fixture.menu.load(0, &slots, &contents);
    const mask = @as(u64, 1) << 9;
    for ([_]?item_packets.Incoming{
        .{ .count = 13, .kind = diamond, .components = &.{}, .encoded_bytes = 10 },
        null,
        .{ .count = 1, .kind = diamond, .components = &.{.{ .key = item_data.key(.max_stack_size), .value = &.{3} }}, .encoded_bytes = 12 },
    }) |proposal| {
        fixture.menu.states[0].dirty = 0;
        try fixture.creative.apply(0, .{ .creative_slot = .{ .slot = 9, .item = proposal } });
        try std.testing.expectEqual(@as(u64, 0), fixture.menu.states[0].dirty & mask);
    }
    try fixture.definitions.items.addDefinitions(.{ .items = &.{.{ .name = "minecraft:diamond", .stack_size = 32 }} });
    fixture.menu.states[0].dirty = 0;
    try fixture.creative.apply(0, .{ .creative_slot = .{ .slot = 9, .item = .{ .count = 1, .kind = diamond, .components = &.{}, .encoded_bytes = 10 } } });
    try std.testing.expectEqual(mask, fixture.menu.states[0].dirty & mask);
}
