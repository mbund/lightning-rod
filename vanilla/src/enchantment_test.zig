const std = @import("std");
const storage = @import("storage");
const metrics = @import("metrics");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const protocols = @import("minecraft_packets").protocols;
const game_data = @import("game_data");
const entities = @import("entities");
const inventories = @import("inventories");
const InventoryFixture = @import("inventory_test_fixture.zig").InventoryFixture;
const Enchantments = @import("vanilla_items").enchantments.Enchantments;
const effects = @import("vanilla_items").enchantment_effects;
const attack_effects = @import("vanilla_items").attack_effects;
const decoder = @import("vanilla_definitions").datapack_enchantments;
const item_data = @import("vanilla_items").item_data;
const Durability = @import("vanilla_items").item_properties.Durability;
const EquipmentAttributes = @import("vanilla_items").equipment_attributes.EquipmentAttributes;
const FallDamage = @import("vanilla_survival").fall_damage.FallDamage;
const PlayerDamage = @import("vanilla_survival").player_damage.PlayerDamage;
const DamageTypes = @import("vanilla_survival").damage_types.DamageTypes;
const ItemUsing = @import("vanilla_items").item_using.ItemUsing;
const ItemCooldowns = @import("vanilla_items").item_cooldowns.ItemCooldowns;
const ItemActions = @import("vanilla_items").item_actions.ItemActions;
const item_actions = @import("vanilla_items").item_actions;
const menu_click = @import("vanilla_inventory").menu_click;

/// PlayerDamage over the fixture, sending nothing: tests read what a hit leaves.
fn playerDamage(context: *Test, allocator: std.mem.Allocator) !*PlayerDamage {
    const fixture = context.fixture;
    const attributes = try EquipmentAttributes.init(allocator, .{}, .{ .players = fixture.players, .player_states = fixture.player_states, .items = fixture.items, .enchantments = fixture.definitions.enchantments, .client = fixture.definitions.client });
    const cooldowns = try ItemCooldowns.init(allocator, .{}, .{ .players = fixture.players });
    return PlayerDamage.init(allocator, .{}, .{
        .players = fixture.players,
        .player_states = fixture.player_states,
        .inventories = fixture.ownership,
        .menus = fixture.menu,
        .items = fixture.items,
        .enchantments = fixture.definitions.enchantments,
        .attributes = attributes,
        .durability = try Durability.init(allocator, .{ .items = fixture.items, .inventories = fixture.ownership, .enchantments = fixture.definitions.enchantments }),
        .client = fixture.definitions.client,
        .damage_types = try DamageTypes.init(allocator, .{ .client = fixture.definitions.client }),
        .replication = undefined,
        .using = try ItemUsing.init(allocator, .{ .players = fixture.players, .player_states = fixture.player_states, .inventories = fixture.ownership, .items = fixture.items, .actions = try ItemActions.init(allocator, .{}, .{ .player_states = fixture.player_states, .items = fixture.items }), .cooldowns = cooldowns }),
        .cooldowns = cooldowns,
    });
}

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
    const attributes = try EquipmentAttributes.init(arena.allocator(), .{}, .{ .players = fixture.players, .player_states = fixture.player_states, .items = fixture.items, .enchantments = fixture.definitions.enchantments, .client = fixture.definitions.client });
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
    const damage = try playerDamage(&context, arena.allocator());
    const fall = try FallDamage.init(arena.allocator(), .{ .players = fixture.players, .player_states = fixture.player_states, .attributes = damage.deps.attributes, .damage = damage });
    const state = &fixture.player_states.records[0];
    state.gamemode = .survival;
    const boots = try context.item("minecraft:iron_boots", &.{.{ .name = "minecraft:feather_falling", .level = 4 }});
    const helmet = try context.item("minecraft:iron_helmet", &.{.{ .name = "minecraft:protection", .level = 4 }});
    const chestplate = try context.item("minecraft:iron_chestplate", &.{.{ .name = "minecraft:protection", .level = 4 }});
    const leggings = try context.item("minecraft:iron_leggings", &.{.{ .name = "minecraft:protection", .level = 4 }});
    try context.equip(8, boots);
    try fall.damage(0, 10);
    try std.testing.expectApproxEqAbs(@as(f32, 14.8), state.health, 0.0001);
    state.health = 20;
    // A second hit soon after deals only what it has over the first.
    try fall.damage(0, 10);
    try std.testing.expectEqual(@as(f32, 20), state.health);
    damage.living[0].invulnerable_time = 0;
    try context.equip(5, helmet);
    try context.equip(6, chestplate);
    try context.equip(7, leggings);
    try fall.damage(0, 10);
    try std.testing.expectApproxEqAbs(@as(f32, 18), state.health, 0.0001);
    state.health = 20;
    damage.living[0].invulnerable_time = 0;
    state.gamemode = .creative;
    try fall.damage(0, 10);
    try std.testing.expectEqual(@as(f32, 20), state.health);
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
    const actions = try ItemActions.init(bounded.allocator(), .{}, .{ .player_states = fixture.player_states, .items = fixture.items });
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
    fixture.player_states.records[0].gamemode = .spectator;
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
    const attributes = try EquipmentAttributes.init(bounded.allocator(), .{}, .{ .players = fixture.players, .player_states = fixture.player_states, .items = fixture.items, .enchantments = fixture.definitions.enchantments, .client = fixture.definitions.client });
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
    fixture.player_states.records[0].selected_slot = 1;
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
    try std.testing.expectEqual(@as(usize, 0), restored.directory.count());
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
    fixture.service.credit[0].store(@as(u64, 1) << 32 | sessions.Service.active | fixture.service.config.credit_bytes, .release);
    const attributes = try EquipmentAttributes.init(arena.allocator(), .{ .bases = &.{.{ .name = "minecraft:mining_efficiency", .value = 5 }} }, .{ .players = fixture.players, .player_states = fixture.player_states, .items = fixture.items, .enchantments = fixture.definitions.enchantments, .client = fixture.definitions.client });
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
    const attributes = try EquipmentAttributes.init(bounded.allocator(), .{}, .{ .players = fixture.players, .player_states = fixture.player_states, .items = fixture.items, .enchantments = fixture.definitions.enchantments, .client = fixture.definitions.client });
    fixture.players.records[1] = fixture.players.records[0];
    fixture.players.records[1].uuid = 2;
    fixture.player_states.records[1] = .{ .uuid = 2 };
    fixture.players.records[1].handle = .{ .index = 1, .generation = 1 };
    fixture.players.rebuildIndexes();
    bounded.fail_index = bounded.alloc_index;
    _ = try attributes.value(0, "minecraft:mining_efficiency");
    _ = try attributes.value(1, "minecraft:mining_efficiency");
    for (0..3) |_| {
        std.mem.swap(@TypeOf(fixture.players.records[0]), &fixture.players.records[0], &fixture.players.records[1]);
        std.mem.swap(@TypeOf(fixture.player_states.records[0]), &fixture.player_states.records[0], &fixture.player_states.records[1]);
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

test "an item's own attribute modifiers apply in the slots its component names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var context = try Test.init(arena.allocator());
    defer context.deinit();
    const fixture = context.fixture;
    const attributes = try EquipmentAttributes.init(arena.allocator(), .{}, .{ .players = fixture.players, .player_states = fixture.player_states, .items = fixture.items, .enchantments = fixture.definitions.enchantments, .client = fixture.definitions.client });
    // An empty hand: vanilla's player defaults.
    try std.testing.expectEqual(@as(f64, 1), try attributes.value(0, "minecraft:attack_damage"));
    try std.testing.expectEqual(@as(f64, 4), try attributes.value(0, "minecraft:attack_speed"));
    // A diamond axe adds 8 damage and takes 3 from the speed, as its attribute_modifiers say.
    const axe = try context.item("minecraft:diamond_axe", &.{});
    try context.equip(36, axe);
    try std.testing.expectEqual(@as(f64, 9), try attributes.value(0, "minecraft:attack_damage"));
    try std.testing.expectEqual(@as(f64, 1), try attributes.value(0, "minecraft:attack_speed"));
    // Its modifiers are for the main hand only.
    try context.equip(36, null);
    try context.equip(45, axe);
    try std.testing.expectEqual(@as(f64, 1), try attributes.value(0, "minecraft:attack_damage"));
    try std.testing.expectEqual(@as(f64, 4), try attributes.value(0, "minecraft:attack_speed"));
    // A helmet's armor counts on the head, not in the hand.
    const helmet = try context.item("minecraft:diamond_helmet", &.{});
    try context.equip(36, helmet);
    try std.testing.expectEqual(@as(f64, 0), try attributes.value(0, "minecraft:armor"));
    try context.equip(36, null);
    try context.equip(5, helmet);
    try std.testing.expectEqual(@as(f64, 3), try attributes.value(0, "minecraft:armor"));
    try std.testing.expectEqual(@as(f64, 2), try attributes.value(0, "minecraft:armor_toughness"));
}

test "vanilla's weapon enchantments shape a hit by the target's type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var context = try Test.init(arena.allocator());
    defer context.deinit();
    const fixture = context.fixture;
    var scratch_bytes: [4096]u8 = undefined;
    var scratch: std.heap.FixedBufferAllocator = .init(&scratch_bytes);
    var random: std.Random.DefaultPrng = .init(1);
    const attack = try attack_effects.Attack.start(.{
        .effects = &fixture.definitions.enchantments.effects,
        .item_tags = &fixture.items.deps.definitions.tags,
        .registries = &fixture.definitions.client.client,
        .damage_type = "minecraft:player_attack",
        .attacker = &fixture.players.records[0],
        .direct_type = @intCast(game_data.registry.entityId("minecraft:player").?),
        .random = random.random(),
        .scratch = &scratch,
    });
    const cow: u32 = @intCast(game_data.registry.entityId("minecraft:cow").?);
    const zombie: u32 = @intCast(game_data.registry.entityId("minecraft:zombie").?);
    const sword = try context.item("minecraft:diamond_sword", &.{ .{ .name = "minecraft:sharpness", .level = 5 }, .{ .name = "minecraft:knockback", .level = 2 }, .{ .name = "minecraft:fire_aspect", .level = 2 } });
    const pinned = try fixture.items.acquire(sword);
    defer pinned.release();
    // Sharpness V: 0.5 a level and 0.5 more.
    try std.testing.expectEqual(@as(f32, 10), try attack.damage(pinned.view, cow, 7));
    try std.testing.expectEqual(@as(f32, 2), try attack.knockback(pinned.view, cow, 0));
    // Fire Aspect II sets the victim alight for 8 seconds.
    var consequences: [4]effects.Consequence = undefined;
    const count = try attack.postAttack(pinned.view, 0, .attacker, cow, &consequences);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(effects.PostAttack.Affected.victim, consequences[0].affected);
    try std.testing.expectEqual(@as(f32, 8), consequences[0].action.ignite_seconds);
    // Smite counts against the undead only.
    const holy = try context.item("minecraft:diamond_sword", &.{.{ .name = "minecraft:smite", .level = 2 }});
    const smite = try fixture.items.acquire(holy);
    defer smite.release();
    try std.testing.expectEqual(@as(f32, 7), try attack.damage(smite.view, cow, 7));
    try std.testing.expectEqual(@as(f32, 12), try attack.damage(smite.view, zombie, 7));
    // No weapon, no change.
    try std.testing.expectEqual(@as(f32, 1), try attack.damage(null, zombie, 1));
}

test "armor and its toughness take a player's hurt, wear for it, and Breach pierces them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var context = try Test.init(arena.allocator());
    defer context.deinit();
    const fixture = context.fixture;
    const damage = try playerDamage(&context, arena.allocator());
    const state = &fixture.player_states.records[0];
    state.gamemode = .survival;
    for ([_][]const u8{ "minecraft:diamond_helmet", "minecraft:diamond_chestplate", "minecraft:diamond_leggings", "minecraft:diamond_boots" }, 5..) |name, index| try context.equip(@intCast(index), try context.item(name, &.{}));
    // Armor 20 and toughness 8 keep 70% of a 10 point hit off.
    try std.testing.expect(try damage.hurt(0, .{ .type = .player_attack, .position = .{ 0, 65, 0 } }, 10));
    try std.testing.expectApproxEqAbs(@as(f32, 17), state.health, 0.0001);
    // Each piece wears by a quarter of the hit.
    for (5..9) |index| {
        const worn = (try fixture.ownership.get(.{ .owner = 1, .index = @intCast(index) })).stack.?;
        const pinned = try fixture.items.acquire(worn);
        defer pinned.release();
        try std.testing.expectEqual(@as(i32, 2), (try @import("protocol_support").read_varint(pinned.view.value(.damage).?))[0]);
    }
    // The hit knocks the player back, as the tick sends.
    try std.testing.expect(damage.living[0].marked);
    // Breach IV takes 60% of the armor's effectiveness away.
    damage.living[0].invulnerable_time = 0;
    state.health = 20;
    var scratch_bytes: [4096]u8 = undefined;
    var scratch: std.heap.FixedBufferAllocator = .init(&scratch_bytes);
    var random: std.Random.DefaultPrng = .init(1);
    const attack = try attack_effects.Attack.start(.{
        .effects = &fixture.definitions.enchantments.effects,
        .item_tags = &fixture.items.deps.definitions.tags,
        .registries = &fixture.definitions.client.client,
        .damage_type = "minecraft:player_attack",
        .attacker = &fixture.players.records[1],
        .direct_type = @intCast(game_data.registry.entityId("minecraft:player").?),
        .random = random.random(),
        .scratch = &scratch,
    });
    const mace = try fixture.items.acquire(try context.item("minecraft:mace", &.{.{ .name = "minecraft:breach", .level = 4 }}));
    defer mace.release();
    try std.testing.expect(try damage.hurt(0, .{ .type = .player_attack, .attack = &attack, .weapon = mace.view }, 10));
    try std.testing.expectApproxEqAbs(@as(f32, 11), state.health, 0.0001);
    // Creative players take nothing.
    damage.living[0].invulnerable_time = 0;
    state.gamemode = .creative;
    try std.testing.expect(!try damage.hurt(0, .{ .type = .player_attack }, 10));
}

test "a raised shield blocks a hit from in front once raised long enough, and wears for it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var context = try Test.init(arena.allocator());
    defer context.deinit();
    const fixture = context.fixture;
    const damage = try playerDamage(&context, arena.allocator());
    const state = &fixture.player_states.records[0];
    state.gamemode = .survival;
    const shield = try context.item("minecraft:shield", &.{});
    try context.equip(45, shield);
    const kind: u32 = @intCast(game_data.registry.itemId("minecraft:shield").?);
    damage.deps.using.start(0, .off, shield, kind, 72000);
    // Facing south, the attacker two blocks ahead. A shield raised for less than its quarter
    // second of delay does nothing.
    const ahead: PlayerDamage.Source = .{ .type = .player_attack, .position = .{ 0.5, 65, 2.5 } };
    damage.deps.using.uses[0].?.ticks = 4;
    try std.testing.expect(try damage.hurt(0, ahead, 4));
    try std.testing.expectEqual(@as(f32, 16), state.health);
    // Raised long enough, it takes the whole hit and wears by one more than the hit.
    damage.living[0].invulnerable_time = 0;
    damage.deps.using.uses[0].?.ticks = 5;
    try std.testing.expect(!try damage.hurt(0, ahead, 10));
    try std.testing.expectEqual(@as(f32, 16), state.health);
    const worn = (try fixture.ownership.get(.{ .owner = 1, .index = 45 })).stack.?;
    const pinned = try fixture.items.acquire(worn);
    defer pinned.release();
    try std.testing.expectEqual(@as(i32, 11), (try @import("protocol_support").read_varint(pinned.view.value(.damage).?))[0]);
    // From behind it blocks nothing.
    damage.living[0].invulnerable_time = 0;
    try std.testing.expect(try damage.hurt(0, .{ .type = .player_attack, .position = .{ 0.5, 65, -1.5 } }, 4));
    try std.testing.expectEqual(@as(f32, 12), state.health);
}
