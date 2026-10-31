const std = @import("std");
const storage = @import("storage");
const metrics = @import("metrics");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const protocols = @import("protocols");
const game_data = @import("game_data");
const entities = @import("entities");
const inventories = @import("inventories");
const InventoryFixture = @import("inventory_test_fixture.zig").InventoryFixture;
const Enchantments = @import("enchantments.zig").Enchantments;
const effects = @import("enchantment_effects.zig");
const decoder = @import("datapack_enchantments.zig");
const item_data = @import("item_data.zig");
const Durability = @import("item_properties.zig").Durability;
const EquipmentAttributes = @import("equipment_attributes.zig").EquipmentAttributes;
const FallDamage = @import("fall_damage.zig").FallDamage;
const ItemActions = @import("item_actions.zig").ItemActions;
const item_actions = @import("item_actions.zig");
const menu_click = @import("menu_click.zig");

const Test = struct {
    directory: std.testing.TmpDir,
    store: *storage.Store,
    metrics: *metrics.Registry,
    fixture: InventoryFixture,

    fn init(allocator: std.mem.Allocator) !Test {
        var directory = std.testing.tmpDir(.{});
        errdefer directory.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/enchantments", .{directory.sub_path});
        const store = try std.testing.allocator.create(storage.Store);
        errdefer std.testing.allocator.destroy(store);
        store.* = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
        errdefer store.deinit();
        const registry = try std.testing.allocator.create(metrics.Registry);
        errdefer std.testing.allocator.destroy(registry);
        registry.* = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
        errdefer registry.deinit();
        const selected = try allocator.dupe(sessions.Protocol, &.{.{ .number = protocols.implementations[0].protocol_number }});
        const fixture = try InventoryFixture.init(allocator, store, registry, selected);
        return .{ .directory = directory, .store = store, .metrics = registry, .fixture = fixture };
    }

    fn deinit(self: *Test) void {
        self.fixture.service.deinit();
        self.metrics.deinit();
        std.testing.allocator.destroy(self.metrics);
        self.store.deinit();
        std.testing.allocator.destroy(self.store);
        self.directory.cleanup();
    }

    fn equip(self: *Test, index: u16, stack: ?inventories.Stack) !void {
        const slot: inventories.Slot = .{ .owner = 1, .index = index };
        const previous = try self.fixture.ownership.get(slot);
        try std.testing.expect(try self.fixture.ownership.set(slot, previous.revision, stack));
    }

    fn item(self: *Test, name: []const u8, entries: []const Enchantments.Entry) !inventories.Stack {
        var copied: [8]Enchantments.Entry = undefined;
        @memcpy(copied[0..entries.len], entries);
        var buffer: [1024]u8 = undefined;
        const encoded = try Enchantments.encode(copied[0..entries.len], &buffer);
        return .{ .item = try item_data.define(self.fixture.ownership, @intCast(game_data.registry.itemId(name).?), &.{.{ .key = item_data.key(.enchantments), .value = encoded }}), .count = 1 };
    }
};

test "unbreaking follows vanilla tool and armor probabilities without runtime allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sealed = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var context = try Test.init(sealed.allocator());
    defer context.deinit();
    const fixture = context.fixture;
    const durability = try Durability.init(sealed.allocator(), .{ .items = fixture.items, .inventories = fixture.ownership, .enchantments = fixture.definitions.enchantments });
    var scratch_bytes: [1024]u8 = undefined;
    var scratch: std.heap.FixedBufferAllocator = .init(&scratch_bytes);
    const cases = [_]struct { name: []const u8, slot: u3 }{
        .{ .name = "minecraft:iron_pickaxe", .slot = 0 },
        .{ .name = "minecraft:iron_chestplate", .slot = 3 },
    };
    var stacks: [cases.len][3]inventories.Stack = undefined;
    for (cases, &stacks) |case, *levels| for (levels, 1..) |*stack, level| {
        stack.* = try context.item(case.name, &.{.{ .name = "minecraft:unbreaking", .level = @intCast(level) }});
    };
    sealed.fail_index = sealed.alloc_index;
    for (cases, stacks) |case, levels| for (levels, 1..) |stack, level| {
        var random = std.Random.Xoshiro256.init(42);
        var oracle = random;
        const probability: f32 = if (case.slot == 0) @as(f32, @floatFromInt(level)) / @as(f32, @floatFromInt(level + 1)) else @as(f32, @floatFromInt(2 * level)) / @as(f32, @floatFromInt(5 * level + 5));
        var prevented: usize = 0;
        for (0..1000) |_| {
            const expected = oracle.random().float(f32) < probability;
            const worn = (try durability.wear(stack, .{ .amount = 1, .slot = case.slot, .actor = &fixture.players.records[0], .random = random.random(), .scratch = &scratch })).?;
            const unchanged = inventories.Stack.sameItem(stack, worn);
            try std.testing.expectEqual(expected, unchanged);
            prevented += @intFromBool(unchanged);
            try std.testing.expectEqual(@as(usize, 0), scratch.end_index);
        }
        try std.testing.expect(prevented > 100 and prevented < 900);
    };
}

test "efficiency and curse behavior follow equipment slots and inventory ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var context = try Test.init(arena.allocator());
    defer context.deinit();
    const fixture = context.fixture;
    const tool = try context.item("minecraft:iron_pickaxe", &.{.{ .name = "minecraft:efficiency", .level = 5 }});
    const attributes = try EquipmentAttributes.init(arena.allocator(), .{}, .{ .players = fixture.players, .items = fixture.items, .enchantments = fixture.definitions.enchantments, .client = fixture.definitions.client });
    try context.equip(36, tool);
    try std.testing.expectEqual(@as(f64, 26), try attributes.value(0, "minecraft:mining_efficiency"));
    try context.equip(36, null);
    try context.equip(45, tool);
    try std.testing.expectEqual(@as(f64, 0), try attributes.value(0, "minecraft:mining_efficiency"));
    const helmet = try context.item("minecraft:iron_helmet", &.{.{ .name = "minecraft:binding_curse", .level = 1 }});
    var stacks: [47]?inventories.Stack = @splat(null);
    var drag: menu_click.Drag = .{};
    var menu: menu_click.Menu = .{ .inventory = fixture.menu, .player = 1, .location = .{ .player = .{ .world = 1, .position = .{ .x = 0, .y = 0, .z = 0 } } }, .kind = .player, .container_slots = 0, .stacks = &stacks, .drag = &drag, .creative = false };
    for ([_]i32{ 0, 1, 2, 4 }) |mode| {
        stacks = @splat(null);
        stacks[5] = helmet;
        const result = try menu.apply(.{ .window_id = 0, .state_id = 0, .slot = 5, .button = 0, .mode = mode });
        try std.testing.expectEqual(@as(usize, 0), result.count);
        try std.testing.expectEqual(helmet, stacks[5].?);
        try std.testing.expect(stacks[46] == null);
    }
    menu.creative = true;
    _ = try menu.apply(.{ .window_id = 0, .state_id = 0, .slot = 5, .button = 0, .mode = 0 });
    try std.testing.expect(stacks[5] == null);
    try std.testing.expectEqual(helmet, stacks[46].?);
}

test "fall damage combines armor protection caps it and excludes unrelated sources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var context = try Test.init(arena.allocator());
    defer context.deinit();
    const fixture = context.fixture;
    const fall = try FallDamage.init(arena.allocator(), .{}, .{ .players = fixture.players, .inventories = fixture.ownership, .items = fixture.items, .enchantments = fixture.definitions.enchantments, .client = fixture.definitions.client, .attributes = try EquipmentAttributes.init(arena.allocator(), .{}, .{ .players = fixture.players, .items = fixture.items, .enchantments = fixture.definitions.enchantments, .client = fixture.definitions.client }), .storage = try context.store.openSpace("fall") });
    const player = &fixture.players.records[0];
    player.gamemode = .survival;
    const boots = try context.item("minecraft:iron_boots", &.{.{ .name = "minecraft:feather_falling", .level = 4 }});
    const helmet = try context.item("minecraft:iron_helmet", &.{.{ .name = "minecraft:protection", .level = 4 }});
    const chestplate = try context.item("minecraft:iron_chestplate", &.{.{ .name = "minecraft:protection", .level = 4 }});
    const leggings = try context.item("minecraft:iron_leggings", &.{.{ .name = "minecraft:protection", .level = 4 }});
    try context.equip(8, boots);
    try fall.damage(0, 10);
    try std.testing.expectApproxEqAbs(@as(f32, 14.8), player.health, 0.0001);
    player.health = 20;
    try context.equip(5, helmet);
    try context.equip(6, chestplate);
    try context.equip(7, leggings);
    try fall.damage(0, 10);
    try std.testing.expectApproxEqAbs(@as(f32, 18), player.health, 0.0001);
    player.health = 20;
    player.gamemode = .creative;
    try fall.damage(0, 10);
    try std.testing.expectEqual(@as(f32, 20), player.health);
}

const Custom = struct {
    calls: usize = 0,
    const Parameters = struct { player: u128, amount: f32, label: []const u8 };
    fn apply(self: *Custom, parameters: *const Parameters, context: *const effects.Context) !f32 {
        try std.testing.expectEqualStrings("owned", parameters.label);
        try std.testing.expectEqual(@as(u32, 3), context.level);
        try std.testing.expectEqual(@as(usize, 7), context.scratch.end_index);
        _ = try context.scratch.allocator().alloc(u8, 32);
        self.calls += 1;
        return if (context.player == parameters.player) parameters.amount else context.input;
    }
};

test "custom enchantments own callback parameters restore scratch and roll back invalid effects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var context = try Test.init(arena.allocator());
    defer context.deinit();
    const fixture = context.fixture;
    var owner: Custom = .{};
    var label = "owned".*;
    const binding = try effects.Handler(Custom, Custom.Parameters, Custom.apply).define(arena.allocator(), &owner, .{ .player = 1, .amount = 17.5, .label = &label });
    try fixture.definitions.enchantments.addEnchantments(&.{.{
        .name = "test:custom",
        .description = "Custom Enchantment",
        .supported_items = &.{"minecraft:iron_pickaxe"},
        .maximum_level = 3,
        .effects = .{ .slots = .{ .mainhand = true }, .item_damage = &.{.{ .custom = binding }} },
    }});
    @memset(&label, 'x');
    const stack = try context.item("minecraft:iron_pickaxe", &.{.{ .name = "test:custom", .level = 3 }});
    const pinned = try fixture.items.acquire(stack);
    defer pinned.release();
    var bytes: [1024]u8 = undefined;
    var scratch: std.heap.FixedBufferAllocator = .init(&bytes);
    _ = try scratch.allocator().alloc(u8, 7);
    var random = std.Random.Xoshiro256.init(0);
    var request: effects.Request = .{ .item = pinned.view, .slot = 0, .amount = 2, .channel = .item_damage, .random = random.random(), .scratch = &scratch, .player = 1 };
    try std.testing.expectEqual(@as(f32, 17.5), try fixture.definitions.enchantments.effects.modifyFloat(request));
    try std.testing.expectEqual(@as(usize, 7), scratch.end_index);
    request.player = 2;
    try std.testing.expectEqual(@as(f32, 2), try fixture.definitions.enchantments.effects.modifyFloat(request));
    try std.testing.expectEqual(@as(usize, 2), owner.calls);
    try std.testing.expectError(error.InvalidEnchantmentValue, fixture.definitions.enchantments.addDefinitions(.{ .effects = &.{.{ .name = "test:custom", .definition = .{ .slots = .{ .mainhand = true }, .item_damage = &.{.{ .set = .{ .constant = std.math.nan(f32) } }} } }} }));
    request.player = 1;
    try std.testing.expectEqual(@as(f32, 17.5), try fixture.definitions.enchantments.effects.modifyFloat(request));
}

test "datapack enchantments reject unsupported conditions instead of applying unconditional effects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"slots":["any"],"effects":{"minecraft:item_damage":[{"effect":{"type":"minecraft:set","value":0},"requirements":{"condition":"minecraft:entity_properties"}}]}}
    , .{});
    try std.testing.expectError(error.UnsupportedEnchantmentRequirement, decoder.decode(arena.allocator(), value, false));
}

const Use = struct {
    calls: usize = 0,
    fn activate(self: *Use, context: *const effects.UseContext) !item_actions.Result {
        if (context.action.item.kind != game_data.registry.itemId("minecraft:stick").?) return .pass;
        try std.testing.expectEqual(@as(u32, 1), context.level);
        try std.testing.expectEqual(@as(u128, 1), context.action.player.uuid);
        _ = try context.action.scratch.allocator().alloc(u8, 32);
        self.calls += 1;
        return .applied;
    }
};

test "item actions dispatch custom enchantments only for the actual held hand and eligible players" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var context = try Test.init(bounded.allocator());
    defer context.deinit();
    const fixture = context.fixture;
    var owner: Use = .{};
    const callback = effects.UseBinding.bind(Use, &owner, Use.activate);
    try fixture.definitions.enchantments.addEnchantments(&.{.{ .name = "test:wand", .description = "Wand", .supported_items = &.{"minecraft:stick"}, .effects = .{ .slots = .{ .mainhand = true, .offhand = true }, .on_use = &.{callback} } }});
    const actions = try ItemActions.init(bounded.allocator(), .{}, .{ .items = fixture.items });
    _ = try Enchantments.init(bounded.allocator(), .{ .items = fixture.items, .packets = undefined, .actions = actions, .definitions = fixture.definitions.enchantments });
    const ordinary = try context.item("minecraft:stick", &.{});
    const enchanted = try context.item("minecraft:stick", &.{.{ .name = "test:wand", .level = 1 }});
    const unrelated = try context.item("minecraft:paper", &.{.{ .name = "test:wand", .level = 1 }});
    try context.equip(36, ordinary);
    try context.equip(45, enchanted);
    bounded.fail_index = bounded.alloc_index;
    const player = &fixture.players.records[0];
    try std.testing.expectEqual(.pass, try actions.apply(player, 0, null));
    try std.testing.expectEqual(.applied, try actions.apply(player, 1, null));
    try context.equip(36, unrelated);
    try std.testing.expectEqual(.pass, try actions.apply(player, 0, null));
    player.gamemode = .spectator;
    try std.testing.expectEqual(.denied, try actions.apply(player, 1, null));
    try std.testing.expectEqual(@as(usize, 1), owner.calls);
    try std.testing.expectEqual(@as(usize, 0), actions.scratch.end_index);
}

test "equipment attributes combine operations distinguish slots and replace duplicate modifier identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var context = try Test.init(bounded.allocator());
    defer context.deinit();
    const fixture = context.fixture;
    const attributes = try EquipmentAttributes.init(bounded.allocator(), .{}, .{ .players = fixture.players, .items = fixture.items, .enchantments = fixture.definitions.enchantments, .client = fixture.definitions.client });
    try fixture.definitions.enchantments.addEnchantments(&.{
        .{ .name = "test:first", .description = "First", .supported_items = &.{"minecraft:stick"}, .effects = .{ .slots = .{ .mainhand = true, .offhand = true }, .attributes = &.{
            .{ .id = "test:shared", .attribute = "minecraft:mining_efficiency", .amount = .{ .constant = 5 }, .operation = .add_value },
            .{ .id = "test:add", .attribute = "minecraft:block_break_speed", .amount = .{ .constant = 5 }, .operation = .add_value },
            .{ .id = "test:base", .attribute = "minecraft:block_break_speed", .amount = .{ .constant = 0.5 }, .operation = .add_multiplied_base },
            .{ .id = "test:total", .attribute = "minecraft:block_break_speed", .amount = .{ .constant = 1 }, .operation = .add_multiplied_total },
        } } },
        .{ .name = "test:second", .description = "Second", .supported_items = &.{"minecraft:stick"}, .effects = .{ .slots = .{ .mainhand = true, .offhand = true }, .attributes = &.{.{ .id = "test:shared", .attribute = "minecraft:mining_efficiency", .amount = .{ .constant = 9 }, .operation = .add_value }} } },
    });
    const main = try context.item("minecraft:stick", &.{ .{ .name = "test:first", .level = 1 }, .{ .name = "test:second", .level = 1 } });
    const off = try context.item("minecraft:stick", &.{.{ .name = "test:first", .level = 1 }});
    try context.equip(36, main);
    const songs = fixture.definitions.client.client.get("minecraft:jukebox_song").?;
    try fixture.definitions.client.addDefinitions(.{ .entries = &.{.{ .registry = "minecraft:jukebox_song", .name = "test:extra_song", .nbt = songs.entries[0].nbt }} });
    bounded.fail_index = bounded.alloc_index;
    try std.testing.expectEqual(@as(f64, 9), try attributes.value(0, "minecraft:mining_efficiency"));
    try std.testing.expectEqual(@as(f64, 18), try attributes.value(0, "minecraft:block_break_speed"));
    try context.equip(45, off);
    try std.testing.expectEqual(@as(f64, 14), try attributes.value(0, "minecraft:mining_efficiency"));
    try std.testing.expectEqual(@as(f64, 88), try attributes.value(0, "minecraft:block_break_speed"));
    fixture.players.records[0].selected_slot = 1;
    try std.testing.expectEqual(@as(f64, 5), try attributes.value(0, "minecraft:mining_efficiency"));
    try context.equip(45, null);
    try std.testing.expectEqual(@as(f64, 0), try attributes.value(0, "minecraft:mining_efficiency"));
    try std.testing.expectEqual(@as(f64, 1), try attributes.value(0, "minecraft:block_break_speed"));
}

test "transient entity IDs survive a checkpoint without storing transient entity bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var context = try Test.init(arena.allocator());
    defer context.deinit();
    const bodies = context.fixture.bodies;
    const first = bodies.next_id;
    try std.testing.expectEqual(first, try bodies.reserveIds(8));
    try bodies.checkpoint(bodies.deps.storage);
    try context.store.waitDurable(try context.store.commit(1));
    const restored = try entities.Entities.init(arena.allocator(), std.testing.io, .{}, bodies.deps);
    try std.testing.expectEqual(first + 8, try restored.reserveIds(2));
    var cursor: entities.Cursor = .{};
    try std.testing.expectEqual(@as(usize, 0), (try restored.scan(&cursor)).len);
    const before = restored.next_id;
    try std.testing.expectError(error.IdExhausted, restored.reserveIds(std.math.maxInt(usize)));
    try std.testing.expectEqual(before, restored.next_id);
}

fn drain(service: *sessions.Service) usize {
    var count: usize = 0;
    while (service.output.takeReady()) |packet| {
        std.debug.assert(service.output.releaseReady(packet.page, packet.generation));
        _ = service.preparing.fetchSub(1, .release);
        count += 1;
    }
    return count;
}

test "attribute synchronization sends configured bases updates changes and skips unchanged equipment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var context = try Test.init(arena.allocator());
    defer context.deinit();
    const fixture = context.fixture;
    fixture.players.deps.packets = try packets.Packets.init(arena.allocator(), .{ .sessions = fixture.service });
    fixture.players.records[0].protocol = protocols.implementations[0].protocol_number;
    fixture.service.credit[0].store(@as(u64, 1) << 32 | sessions.Service.active | fixture.service.config.buffer_bytes, .release);
    const attributes = try EquipmentAttributes.init(arena.allocator(), .{ .bases = &.{.{ .name = "minecraft:mining_efficiency", .value = 5 }} }, .{ .players = fixture.players, .items = fixture.items, .enchantments = fixture.definitions.enchantments, .client = fixture.definitions.client });
    try attributes.tick();
    try std.testing.expectEqual(@as(usize, 1), drain(fixture.service));
    try std.testing.expectEqual(@as(f64, 5), try attributes.value(0, "minecraft:mining_efficiency"));
    try attributes.tick();
    try std.testing.expectEqual(@as(usize, 0), drain(fixture.service));
    const tool = try context.item("minecraft:iron_pickaxe", &.{.{ .name = "minecraft:efficiency", .level = 1 }});
    try context.equip(36, tool);
    try attributes.tick();
    try std.testing.expectEqual(@as(usize, 1), drain(fixture.service));
    try std.testing.expectEqual(@as(f64, 7), try attributes.value(0, "minecraft:mining_efficiency"));
    try context.equip(36, null);
    try attributes.tick();
    try std.testing.expectEqual(@as(usize, 1), drain(fixture.service));
    try std.testing.expectEqual(@as(f64, 5), try attributes.value(0, "minecraft:mining_efficiency"));
}

test "equipment watches follow player identities when connection slots are reassigned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var context = try Test.init(bounded.allocator());
    defer context.deinit();
    const fixture = context.fixture;
    const attributes = try EquipmentAttributes.init(bounded.allocator(), .{}, .{ .players = fixture.players, .items = fixture.items, .enchantments = fixture.definitions.enchantments, .client = fixture.definitions.client });
    fixture.players.records[1] = fixture.players.records[0];
    fixture.players.records[1].uuid = 2;
    fixture.players.records[1].handle = .{ .index = 1, .generation = 1 };
    fixture.players.rebuildIndexes();
    bounded.fail_index = bounded.alloc_index;
    _ = try attributes.value(0, "minecraft:mining_efficiency");
    _ = try attributes.value(1, "minecraft:mining_efficiency");
    for (0..3) |_| {
        std.mem.swap(@TypeOf(fixture.players.records[0]), &fixture.players.records[0], &fixture.players.records[1]);
        for (fixture.players.records, 0..) |*player, index| {
            player.handle.?.index = index;
            player.handle.?.generation += 1;
            _ = try attributes.value(index, "minecraft:mining_efficiency");
        }
        for (fixture.players.records, 0..) |player, index| {
            try std.testing.expectEqual(index, attributes.owners.get(player.uuid).?);
            try std.testing.expectEqual(&attributes.states[index].invalid, attributes.observer.owners.get(player.uuid).?.target.dirty);
        }
        try std.testing.expectEqual(@as(usize, 2), attributes.owners.count());
    }
    for (fixture.players.records) |*player| player.handle = null;
    fixture.players.rebuildIndexes();
    try attributes.tick();
    try std.testing.expectEqual(@as(usize, 0), attributes.owners.count());
    try std.testing.expectEqual(@as(usize, 0), attributes.observer.owners.count());
}
