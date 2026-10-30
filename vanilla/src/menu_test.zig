const fuel = @import("fuel.zig");
const custom_data = @import("custom_data.zig");
const vanilla_content = @import("vanilla_content.zig");
const recipe_placement = @import("recipe_placement.zig");
const FuelConversionDefinition = @import("recipes.zig").FuelConversionDefinition;
const std = @import("std");
const storage = @import("storage");
const fault = @import("fault_disk");
const metrics = @import("metrics");
const packets = @import("minecraft_packets");
const sessions = @import("sessions");
const protocols = @import("protocols");
const game_data = @import("game_data");
const provider = @import("definition_provider.zig");
const Crafting = @import("crafting_registry.zig").Crafting;
const inventories = @import("inventories");
const menu_click = @import("menu_click.zig");
const InventoryFixture = @import("inventory_test_fixture.zig").InventoryFixture;
const item_data = @import("item_data.zig");
const ItemEntities = @import("item_entities.zig").ItemEntities;
const PlayerInventory = @import("player_inventory.zig").PlayerInventory;
const Experience = @import("experience.zig").Experience;
const ExperienceState = @import("experience_state.zig").State;
const Random = @import("random.zig").Random;
const Enchantments = @import("enchantments.zig").Enchantments;
const ItemPhysics = @import("item_physics.zig").ItemPhysics;
const InventoryCapacity = @import("inventory_capacity.zig").InventoryCapacity;
const records = @import("records");
const chunks = @import("chunks");
const BlockActions = @import("block_actions.zig").BlockActions;
const Containers = @import("containers.zig").Containers;
const ContainerKey = @import("containers.zig").Key;
const furnace = @import("furnace.zig");
const conservation = @import("menu_conservation_test.zig");

test {
    _ = conservation;
}

fn kind(name: []const u8) u32 {
    return @intCast(game_data.registry.itemId(name).?);
}

test "experience pickup consumes one merged count every two ticks and ignores spectators" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/experience-pickup", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const fixture = try InventoryFixture.init(bounded.allocator(), &store, &registry, &selected);
    defer fixture.service.deinit();
    const containers = try blockContainers(bounded.allocator(), &store, &registry, fixture);
    const experience = containers.deps.experience;
    bounded.fail_index = bounded.alloc_index;
    fixture.players.records[0].position = .{ .x = 0.5, .y = 8, .z = 0.5 };
    fixture.players.records[0].gamemode = .spectator;
    fixture.players.rebuildIndexes();
    try experience.award(fixture.players.records[0].world, .{ 0.5, 8, 0.5 }, 7);
    const index = experience.active.values()[0];
    experience.orbs[index].count = 3;
    try experience.tick();
    try std.testing.expectEqual(@as(i32, 0), fixture.players.records[0].experience.total);
    try std.testing.expectEqual(@as(i32, 3), experience.orbs[index].count);
    fixture.players.records[0].gamemode = .survival;
    for ([_]i32{ 7, 7, 14, 14, 21 }) |total| {
        try experience.tick();
        try std.testing.expectEqual(total, fixture.players.records[0].experience.total);
    }
    try std.testing.expect(!experience.orbs[index].alive);
    try experience.tick();
    try std.testing.expectEqual(@as(usize, 0), experience.active.values().len);
    const player = &fixture.players.records[0];
    player.health = 0;
    player.experience = .{ .level = 30, .total = 1500 };
    try experience.tick();
    try std.testing.expectEqual(@as(i32, 0), player.experience.total);
    try experience.tick();
    var reward: i32 = 0;
    for (experience.active.values()) |at| reward += experience.orbs[at].count * experience.orbs[at].value;
    try std.testing.expectEqual(@as(i32, 100), reward);
    player.life += 1;
    player.experience = .{ .level = 1, .total = 7 };
    experience.config.keep_inventory = true;
    try experience.tick();
    try std.testing.expectEqual(@as(i32, 7), player.experience.total);
    experience.config.keep_inventory = false;
    player.handle.?.generation += 1;
    player.life = 1;
    player.experience = .{ .level = 30, .total = 1500 };
    try experience.tick();
    try std.testing.expectEqual(@as(i32, 0), player.experience.total);
    reward = 0;
    for (experience.active.values()) |at| reward += experience.orbs[at].count * experience.orbs[at].value;
    try std.testing.expectEqual(@as(i32, 200), reward);
}

test "mending repairs only equipped damaged items and preserves vanilla odd damage rounding" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/mending", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const fixture = try InventoryFixture.init(arena.allocator(), &store, &registry, &selected);
    defer fixture.service.deinit();
    const containers = try blockContainers(arena.allocator(), &store, &registry, fixture);
    var enchantment: [128]u8 = undefined;
    var enchantments = [_]Enchantments.Entry{ .{ .name = "minecraft:mending", .level = 1 }, .{ .name = "removed:enchantment", .level = 1 } };
    const enchanted = try Enchantments.encode(&enchantments, &enchantment);
    const item = try item_data.define(fixture.ownership, kind("minecraft:diamond_pickaxe"), &.{
        .{ .key = item_data.key(.enchantments), .value = enchanted },
        .{ .key = item_data.key(.damage), .value = &.{5} },
    });
    const hand: inventories.Slot = .{ .owner = 1, .index = 36 };
    const backpack: inventories.Slot = .{ .owner = 1, .index = 9 };
    try std.testing.expect(try fixture.ownership.set(hand, 0, .{ .item = item, .count = 1 }));
    try std.testing.expect(try fixture.ownership.set(backpack, 0, .{ .item = item, .count = 1 }));
    try std.testing.expectEqual(@as(i32, 1), try containers.deps.experience.repair(0, 3));
    const repaired = (try fixture.ownership.get(hand)).stack.?;
    const lease = try fixture.ownership.acquireItem(repaired.item);
    try std.testing.expect((try item_data.View.parse(lease.read().?)).get(item_data.key(.damage)) == null);
    lease.release();
    try std.testing.expectEqual(try item_data.define(fixture.ownership, kind("minecraft:diamond_pickaxe"), &.{.{ .key = item_data.key(.enchantments), .value = enchanted }}), repaired.item);
    try std.testing.expectEqual(item, (try fixture.ownership.get(backpack)).stack.?.item);
    try std.testing.expectEqual(@as(i32, 7), try containers.deps.experience.repair(0, 7));

    const equipment = [_]u16{ 36, 45, 8, 7, 6, 5 };
    for (0..32) |seed| {
        containers.deps.experience.random.source = .init(seed);
        for (equipment) |index| {
            const slot: inventories.Slot = .{ .owner = 1, .index = index };
            const previous = try fixture.ownership.get(slot);
            try std.testing.expect(try fixture.ownership.set(slot, previous.revision, .{ .item = item, .count = 1 }));
        }
        try std.testing.expectEqual(@as(i32, 2), try containers.deps.experience.repair(0, 14));
        for (equipment) |index| {
            const stack = (try fixture.ownership.get(.{ .owner = 1, .index = index })).stack.?;
            try std.testing.expectEqual(repaired.item, stack.item);
        }
        try std.testing.expectEqual(item, (try fixture.ownership.get(backpack)).stack.?.item);
    }
}

test "competing experience collectors conserve every point under sustained bounded load" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/experience-competing", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const fixture = try InventoryFixture.init(bounded.allocator(), &store, &registry, &selected);
    defer fixture.service.deinit();
    const experience = (try blockContainers(bounded.allocator(), &store, &registry, fixture)).deps.experience;
    fixture.players.records[1] = fixture.players.records[0];
    fixture.players.records[1].handle = .{ .index = 1, .generation = 1 };
    fixture.players.records[1].uuid = 2;
    for (fixture.players.records) |*player| {
        player.gamemode = .survival;
        player.position = .{ .x = 0.5, .y = 8, .z = 0.5 };
    }
    fixture.players.rebuildIndexes();
    bounded.fail_index = bounded.alloc_index;
    var generated: i32 = 0;
    for (0..64) |_| {
        try experience.award(fixture.players.records[0].world, .{ 0.5, 8, 0.5 }, 73);
        const index = experience.active.values()[0];
        experience.orbs[index].count = 16;
        generated += 73 * 16;
        for (0..16) |_| {
            if (experience.orbs[index].alive) {
                experience.orbs[index].body.position = .{ 0.5, 8, 0.5 };
                experience.orbs[index].body.velocity = .{ 0, 0, 0 };
            }
            try experience.tick();
            var remaining: i32 = 0;
            for (experience.active.values()) |at| if (experience.orbs[at].alive) {
                remaining += experience.orbs[at].value * experience.orbs[at].count;
            };
            try std.testing.expectEqual(generated, remaining + fixture.players.records[0].experience.total + fixture.players.records[1].experience.total);
        }
        try std.testing.expectEqual(@as(usize, 0), experience.active.values().len);
    }
    for (fixture.players.records) |player| try std.testing.expectEqual(@divExact(generated, 2), player.experience.total);
}

test "spawn time orb merging uses the vanilla signed entity group and resets age" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/experience-spawn-merge", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const fixture = try InventoryFixture.init(arena.allocator(), &store, &registry, &selected);
    defer fixture.service.deinit();
    const experience = (try blockContainers(arena.allocator(), &store, &registry, fixture)).deps.experience;
    const world = fixture.players.records[0].world;
    try experience.award(world, .{ 0.5, 8, 0.5 }, 3);
    const index = experience.active.values()[0];
    const entity = experience.residents[index].id;
    try std.testing.expect(entity % 40 != 0 and entity % 40 != 20);
    var matched = false;
    for (0..4096) |seed| {
        var random: Random = .{ .source = .init(seed) };
        if (random.random().uintLessThan(u32, 40) != @mod(@as(i64, Experience.networkId(entity)), 40)) continue;
        experience.random.source = .init(seed);
        matched = true;
        break;
    }
    try std.testing.expect(matched);
    experience.orbs[index].age = 1234;
    try experience.award(world, .{ 0.5, 8, 0.5 }, 3);
    try std.testing.expectEqual(@as(usize, 1), experience.active.values().len);
    try std.testing.expectEqual(@as(i32, 2), experience.orbs[index].count);
    try std.testing.expectEqual(@as(u16, 0), experience.orbs[index].age);
}

test "experience pickup mending and remaining orbs commit atomically across interrupted checkpoints" {
    for ([_]fault.Disk.Mode{ .discard, .torn, .torn_inverse }) |mode| try verifyAtomicExperience(mode);
}

fn verifyAtomicExperience(mode: fault.Disk.Mode) !void {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/experience-atomic", .{directory.sub_path});
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    var entity: u64 = undefined;
    var repaired_item: inventories.ItemId = undefined;
    const options: storage.Store.Options = .{ .path = path, .io_mode = .standard };
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, options);
    var disk = fault.Disk.init(std.testing.allocator, std.testing.io, &.{ store.database, store.wal }, std.math.maxInt(usize), false) catch |err| {
        store.deinit();
        return err;
    };
    var opened = true;
    defer {
        if (opened) store.deinit();
        disk.deinit();
    }
    store.bindIo(disk.interface());
    for (0..4) |phase| {
        if (phase > 0) {
            store = try storage.Store.init(std.testing.allocator, disk.interface(), options);
            opened = true;
        }
        defer {
            store.deinit();
            opened = false;
            disk.detach();
            if (phase > 0) disk.crash(mode);
        }
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const fixture = try InventoryFixture.init(arena.allocator(), &store, &registry, &selected);
        defer fixture.service.deinit();
        const experience = (try blockContainers(arena.allocator(), &store, &registry, fixture)).deps.experience;
        const player = &fixture.players.records[0];
        player.position = .{ .x = 0.5, .y = 8, .z = 0.5 };
        player.gamemode = .survival;
        fixture.players.rebuildIndexes();
        const hand: inventories.Slot = .{ .owner = player.uuid, .index = 36 };
        if (phase == 0) {
            var bytes: [128]u8 = undefined;
            var entries = [_]Enchantments.Entry{.{ .name = "minecraft:mending", .level = 1 }};
            const enchanted = try Enchantments.encode(&entries, &bytes);
            repaired_item = try item_data.define(fixture.ownership, kind("minecraft:diamond_pickaxe"), &.{.{ .key = item_data.key(.enchantments), .value = enchanted }});
            const damaged = try item_data.define(fixture.ownership, kind("minecraft:diamond_pickaxe"), &.{
                .{ .key = item_data.key(.enchantments), .value = enchanted },
                .{ .key = item_data.key(.damage), .value = &.{5} },
            });
            try std.testing.expect(try fixture.ownership.set(hand, 0, .{ .item = damaged, .count = 1 }));
            try experience.award(player.world, .{ 0.5, 8, 0.5 }, 7);
            const index = experience.active.values()[0];
            entity = experience.residents[index].id;
            experience.orbs[index].count = 3;
        } else {
            const table = records.Table.init(fixture.players.deps.storage, fixture.players.deps.record_workspaces.resources);
            var key: [17]u8 = undefined;
            key[0] = 1;
            std.mem.writeInt(u128, key[1..17], player.uuid, .little);
            var bytes: [ExperienceState.encoded_size]u8 = undefined;
            const length = (try table.get(&key, &bytes)).?;
            player.experience = try ExperienceState.decode(bytes[0..length]);
            const expected: i32 = if (phase == 3) 12 else 5;
            try std.testing.expectEqual(expected, player.experience.total);
            try std.testing.expectEqual(expected, player.experience.score);
            try std.testing.expectEqual(repaired_item, (try fixture.ownership.get(hand)).stack.?.item);
            const index = experience.ids.get(entity).?;
            try std.testing.expectEqual(@as(i32, if (phase == 3) 1 else 2), experience.orbs[index].count);
            experience.orbs[index].body.position = .{ 0.5, 8, 0.5 };
            experience.orbs[index].body.velocity = .{ 0, 0, 0 };
            if (phase == 3) continue;
        }
        try experience.tick();
        try std.testing.expectEqual(@as(i32, if (phase == 0) 5 else 12), player.experience.total);
        try fixture.players.checkpoint(fixture.players.deps.storage);
        try fixture.ownership.checkpoint(fixture.ownership.deps.storage);
        try experience.checkpoint(experience.deps.storage);
        if (phase != 1) try store.waitDurable(try store.commit(if (phase == 0) 1 else 2));
    }
}

test "experience metadata bodies and random state survive reopen and discard interrupted saves" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/experience-save", .{directory.sub_path});
    var expected_random: [32]u8 = undefined;
    var entity: u64 = undefined;
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    for (0..3) |pass| {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
        defer store.deinit();
        var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
        defer registry.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const fixture = try InventoryFixture.init(arena.allocator(), &store, &registry, &selected);
        defer fixture.service.deinit();
        const containers = try blockContainers(arena.allocator(), &store, &registry, fixture);
        const experience = containers.deps.experience;
        if (pass == 0) {
            try experience.award(fixture.players.records[0].world, .{ 8.5, 8, 0.5 }, 73);
            const index = experience.active.values()[0];
            entity = experience.residents[index].id;
            experience.orbs[index].count = 5;
            experience.orbs[index].age = 1234;
            experience.orbs[index].fire = 80;
            try std.testing.expect(try experience.damage(entity, 1.5));
            expected_random = experience.random.encode();
            try fixture.bodies.checkpoint(fixture.bodies.deps.storage);
            try experience.checkpoint(experience.deps.storage);
            try store.waitDurable(try store.commit(1));
        } else {
            const index = experience.ids.get(entity).?;
            const orb = experience.orbs[index];
            try std.testing.expectEqual(@as(i32, 73), orb.value);
            try std.testing.expectEqual(@as(i32, 5), orb.count);
            try std.testing.expectEqual(@as(u16, 1234), orb.age);
            try std.testing.expectEqual(@as(i16, 3), orb.health);
            try std.testing.expectEqual(@as(i16, 80), orb.fire);
            try std.testing.expectEqualSlices(u8, &expected_random, &experience.random.encode());
            try std.testing.expectEqual(@as(f64, 8.5), (try fixture.bodies.get(entity)).?.position[0]);
            try std.testing.expect(try experience.damage(entity, 100));
            try experience.checkpoint(experience.deps.storage);
        }
    }
}

test "orb merges preserve denomination counts and minimum age and expiry removes the body" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/experience-merge", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const fixture = try InventoryFixture.init(arena.allocator(), &store, &registry, &selected);
    defer fixture.service.deinit();
    const containers = try blockContainers(arena.allocator(), &store, &registry, fixture);
    const experience = containers.deps.experience;
    fixture.players.records[0].position = .{ .x = 0, .y = 8, .z = 0 };
    fixture.players.records[0].gamemode = .spectator;
    fixture.players.rebuildIndexes();
    const world = fixture.players.records[0].world;
    try experience.award(world, .{ 8, 8, 0 }, 3);
    fixture.bodies.next_id += 39;
    try experience.award(world, .{ 10, 8, 0 }, 3);
    try std.testing.expectEqual(@as(usize, 2), experience.active.values().len);
    const first = experience.active.values()[0];
    const second = experience.active.values()[1];
    experience.orbs[first].age = 200;
    experience.orbs[first].count = 2;
    experience.orbs[second].age = 100;
    experience.orbs[second].count = 5;
    experience.orbs[second].body.position = experience.orbs[first].body.position;
    try experience.tick();
    try std.testing.expectEqual(@as(usize, 1), experience.active.values().len);
    try std.testing.expectEqual(@as(i32, 3), experience.orbs[first].value);
    try std.testing.expectEqual(@as(i32, 7), experience.orbs[first].count);
    try std.testing.expectEqual(@as(u16, 101), experience.orbs[first].age);
    const entity = experience.residents[first].id;
    experience.orbs[first].age = 5999;
    try experience.tick();
    try std.testing.expect(!experience.orbs[first].alive);
    try std.testing.expect((try fixture.bodies.get(entity)) == null);
}

test "orb placement fluid currents block effects and fire follow vanilla physics" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/experience-physics", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const fixture = try InventoryFixture.init(arena.allocator(), &store, &registry, &selected);
    defer fixture.service.deinit();
    const containers = try blockContainers(arena.allocator(), &store, &registry, fixture);
    const experience = containers.deps.experience;
    const world = fixture.players.records[0].world;
    fixture.players.records[0].gamemode = .spectator;
    fixture.players.records[0].position = .{ .x = 8, .y = 8, .z = 8 };
    fixture.players.rebuildIndexes();
    try containers.deps.chunks.setBlock(world, .{ .x = 0, .y = 8, .z = 0 }, @intCast(game_data.registry.blockStateId("minecraft:stone").?));
    try experience.award(world, .{ 1.1, 8, 0.5 }, 1);
    const first = experience.active.values()[0];
    try std.testing.expectEqual(@as(f64, 1.25), experience.orbs[first].body.position[0]);
    try std.testing.expectEqual(@as(f64, 8), experience.orbs[first].body.position[1]);
    const water: u16 = @intCast(game_data.registry.blockStateId("minecraft:water[level=0]").?);
    try containers.deps.chunks.setBlock(world, .{ .x = 4, .y = 8, .z = 4 }, water);
    try experience.award(world, .{ 4.5, 8, 4.5 }, 3);
    const second = experience.active.values()[1];
    experience.orbs[second].body.velocity = .{ 0.1, 0, 0.1 };
    try experience.tick();
    const body = experience.orbs[second].body;
    try std.testing.expectApproxEqAbs(@as(f64, 0.1) * @as(f64, @as(f32, 0.99)) * @as(f64, @as(f32, 0.98)), body.velocity[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, @as(f32, 0.0005)) * @as(f64, @as(f32, 0.98)), body.velocity[1], 1e-12);
    const stone: u16 = @intCast(game_data.registry.blockStateId("minecraft:stone").?);
    for ([_]chunks.Position{ .{ .x = 3, .y = 8, .z = 4 }, .{ .x = 4, .y = 8, .z = 3 }, .{ .x = 4, .y = 8, .z = 5 } }) |position| try containers.deps.chunks.setBlock(world, position, stone);
    try containers.deps.chunks.setBlock(world, .{ .x = 5, .y = 8, .z = 4 }, @intCast(game_data.registry.blockStateId("minecraft:water[level=4]").?));
    experience.orbs[second].body.position = .{ 4.5, 8, 4.5 };
    experience.orbs[second].body.velocity = .{ 0, 0, 0 };
    try experience.tick();
    try std.testing.expectApproxEqAbs(@as(f64, 0.014) * @as(f64, @as(f32, 0.99)) * @as(f64, @as(f32, 0.98)), experience.orbs[second].body.velocity[0], 1e-12);
    try std.testing.expectEqual(@as(f64, 0), experience.orbs[second].body.velocity[2]);
    const lava: u16 = @intCast(game_data.registry.blockStateId("minecraft:lava[level=0]").?);
    try containers.deps.chunks.setBlock(world, .{ .x = 10, .y = 8, .z = 4 }, lava);
    try experience.award(world, .{ 10.5, 8, 4.5 }, 7);
    const burning = experience.active.values()[2];
    experience.orbs[burning].body.velocity = .{ 0, 0, 0 };
    try experience.tick();
    try std.testing.expectEqual(@as(i16, 1), experience.orbs[burning].health);
    try std.testing.expectEqual(@as(i16, 300), experience.orbs[burning].fire);
    try experience.tick();
    try std.testing.expect(!experience.orbs[burning].alive);
    try containers.deps.chunks.setBlock(world, .{ .x = 12, .y = 8, .z = 4 }, @intCast(game_data.registry.blockStateId("minecraft:bubble_column[drag=false]").?));
    try containers.deps.chunks.setBlock(world, .{ .x = 14, .y = 8, .z = 4 }, @intCast(game_data.registry.blockStateId("minecraft:cobweb").?));
    var window = experience.deps.physics.readWindow();
    defer window.deinit();
    var moving = experience.orbs[second].body;
    moving.position = .{ 12.5, 8, 4.5 };
    moving.velocity = .{ 0, 0, 0 };
    const lifted = try experience.deps.physics.advanceOrb(&window, 1, 1, moving, false, .{ 0, 0, 0 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.1) * @as(f64, @as(f32, 0.98)), lifted.body.velocity[1], 1e-12);
    moving.position = .{ 14.5, 8.5, 4.5 };
    moving.velocity = .{ 0.1, -0.03, 0.1 };
    const stuck = try experience.deps.physics.advanceOrb(&window, 1, 1, moving, false, .{ 0.25, 0.05, 0.25 });
    try std.testing.expectEqual(@as([3]f64, .{ 0.25, 0.05, 0.25 }), stuck.effects.stuck);
    try std.testing.expectApproxEqAbs(@as(f64, 14.525), stuck.body.position[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 8.4985), stuck.body.position[1], 1e-12);
    try std.testing.expectEqual(@as([3]f64, .{ 0, 0, 0 }), stuck.body.velocity);
    window.deinit();
    try containers.deps.chunks.setBlock(world, .{ .x = 20, .y = 8, .z = 4 }, @intCast(game_data.registry.blockStateId("minecraft:honey_block").?));
    window = experience.deps.physics.readWindow();
    moving.position = .{ 21.2, 8.5, 4.5 };
    moving.velocity = .{ 0, -0.3, 0.1 };
    const sliding = try experience.deps.physics.advanceOrb(&window, 1, 1, moving, false, .{ 0, 0, 0 });
    const drag = @as(f64, @as(f32, 0.98));
    try std.testing.expect(sliding.effects.honey);
    try std.testing.expectApproxEqAbs((-0.05 - 0.08) * drag * drag, sliding.body.velocity[1], 1e-12);
}

test "furnace recipe rewards survive reordered content and claim exactly once" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/furnace-experience", .{directory.sub_path});
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    var saved_recipe: u32 = undefined;
    for (0..2) |pass| {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
        defer store.deinit();
        var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
        defer registry.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const fixture = try InventoryFixture.init(arena.allocator(), &store, &registry, &selected);
        defer fixture.service.deinit();
        const containers = try blockContainers(arena.allocator(), &store, &registry, fixture);
        if (pass == 1) {
            _ = try provider.register(fixture.definitions, arena.allocator(), .{ .recipes = &.{.{ .name = "aaa:inserted", .definition = .{ .smelting = .{ .input = .{ .item = "minecraft:dirt" }, .result = .{ .item = "minecraft:diamond" }, .experience = 100 } } }} }, null);
            try std.testing.expectEqual(fixture.definitions.furnaces.table.cooking_names.len, containers.reward_ids.len);
            try std.testing.expectEqual(saved_recipe + 1, fixture.definitions.furnaces.table.recipes[kind("minecraft:raw_iron")].?.index);
        }
        const key: ContainerKey = .{ .world = fixture.players.records[0].world, .position = .{ .x = 2, .y = 1, .z = 0 } };
        const state = containers.states.furnaces[0][0];
        if (pass == 0) {
            try containers.deps.chunks.setBlock(key.world, key.position, state);
            const recipe = fixture.definitions.furnaces.table.recipes[kind("minecraft:raw_iron")].?;
            saved_recipe = recipe.index;
            for (0..7) |_| try containers.recordRecipe(key, recipe.index);
            try std.testing.expect(try fixture.ownership.set(Containers.slot(key.world, key.position, 2), 0, .{ .item = try fixture.items.define("minecraft:iron_ingot"), .count = 2 }));
            try containers.checkpoint(containers.deps.storage);
            try fixture.ownership.checkpoint(fixture.ownership.deps.storage);
            try containers.deps.chunks.checkpoint(try store.openSpace("chunks"));
            try store.waitDurable(try store.commit(1));
        } else {
            const player = &fixture.players.records[0];
            player.protocol = selected[0].number;
            player.position = .{ .x = 2, .y = 1, .z = 3 };
            try std.testing.expectEqual(BlockActions.Result.applied, try containers.deps.actions.apply(.{ .action = .use, .player = player, .position = key.position, .state = state }));
            const view = &containers.views[0];
            view.opened = true;
            try containers.click(player.handle.?, .{ .window_id = view.window, .state_id = 0, .slot = 2, .button = 1, .mode = 0 });
            try std.testing.expectEqual(@as(u16, 1), (try fixture.ownership.get(Containers.slot(key.world, key.position, 2))).stack.?.count);
            var total: i32 = 0;
            for (containers.deps.experience.active.values()) |index| {
                const orb = containers.deps.experience.orbs[index];
                total += orb.count * orb.value;
            }
            try std.testing.expect(total == 4 or total == 5);
            try containers.click(player.handle.?, .{ .window_id = view.window, .state_id = 0, .slot = 2, .button = 0, .mode = 0 });
            var after: i32 = 0;
            for (containers.deps.experience.active.values()) |index| {
                const orb = containers.deps.experience.orbs[index];
                after += orb.count * orb.value;
            }
            try std.testing.expectEqual(total, after);
        }
    }
}

test "baseline recipes include fuels remainders shaped mirrored and shapeless matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content = try vanilla_content.prepare(arena.allocator());
    const recipes = &content.crafting.table;
    const furnace_recipes = &content.furnaces.table;
    try std.testing.expectEqual(@as(u32, 1600), furnace_recipes.fuels[kind("minecraft:coal")].ticks);
    try std.testing.expectEqual(@as(u32, 20000), furnace_recipes.fuels[kind("minecraft:lava_bucket")].ticks);
    try std.testing.expectEqual(kind("minecraft:bucket"), recipes.remainders[kind("minecraft:lava_bucket")].?);
    const iron = furnace_recipes.recipes[kind("minecraft:raw_iron")].?;
    try std.testing.expectEqual(kind("minecraft:iron_ingot"), iron.output);
    try std.testing.expectEqual(@as(u32, 200), iron.ticks);
    var grid: [9]?u32 = @splat(null);
    grid[3] = kind("minecraft:oak_log");
    const planks = recipes.matches(grid[0..4], 2).?;
    try std.testing.expectEqual(kind("minecraft:oak_planks"), planks.output);
    try std.testing.expectEqual(@as(u16, 4), planks.amount);
    grid = @splat(kind("minecraft:cobblestone"));
    grid[4] = null;
    try std.testing.expectEqual(kind("minecraft:furnace"), recipes.matches(&grid, 3).?.output);
    try std.testing.expect(recipes.matches(grid[0..4], 2) == null);
    grid = .{ kind("minecraft:oak_planks"), kind("minecraft:oak_planks"), null, kind("minecraft:oak_planks"), kind("minecraft:stick"), null, null, kind("minecraft:stick"), null };
    try std.testing.expectEqual(kind("minecraft:wooden_axe"), recipes.matches(&grid, 3).?.output);
    for (0..3) |row| std.mem.swap(?u32, &grid[row * 3], &grid[row * 3 + 2]);
    try std.testing.expectEqual(kind("minecraft:wooden_axe"), recipes.matches(&grid, 3).?.output);
    grid[7] = null;
    try std.testing.expect(recipes.matches(&grid, 3) == null);
}

test "crafting consumes inputs once and cursor ownership survives durable restart" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/crafting", .{directory.sub_path});
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    for ([_]bool{ false, true }) |reopen| {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const fixture = try InventoryFixture.init(bounded.allocator(), &store, &registry, &selected);
        defer fixture.service.deinit();
        fixture.players.records[0].gamemode = .survival;
        bounded.fail_index = bounded.alloc_index;
        if (!reopen) {
            const log: inventories.Stack = .{ .item = try fixture.items.define("minecraft:oak_log"), .count = 2 };
            const initial = try fixture.ownership.get(.{ .owner = 1, .index = 1 });
            try std.testing.expect(try fixture.ownership.set(.{ .owner = 1, .index = 1 }, initial.revision, log));
            fixture.menu.states[0] = .{ .generation = 1, .life = fixture.players.records[0].life, .close = false, .gamemode = .survival };
            var slots: [47]inventories.Slot = undefined;
            var contents: [47]inventories.Contents = undefined;
            try fixture.menu.load(0, &slots, &contents);
            var next: [47]?inventories.Stack = undefined;
            for (contents, &next) |value, *stack| stack.* = value.stack;
            var drag: menu_click.Drag = .{};
            const menu: menu_click.Menu = .{ .inventory = fixture.menu, .player = fixture.players.records[0].uuid, .location = fixture.location(.player), .kind = .player, .container_slots = 0, .stacks = &next, .drag = &drag, .creative = false };
            const result = try menu.apply(.{ .window_id = 0, .state_id = 0, .slot = 0, .button = 0, .mode = 0 });
            try std.testing.expectEqual(@as(u16, 1), next[1].?.count);
            try std.testing.expectEqual(@as(u16, 4), next[46].?.count);
            try std.testing.expectEqual(@as(u16, 4), next[0].?.count);
            try std.testing.expect(try fixture.menu.apply(0, &slots, &contents, &next, result.drops[0..result.count]));
            try std.testing.expect((try fixture.ownership.get(.{ .owner = 1, .index = 0 })).stack == null);
            try fixture.ownership.checkpoint(fixture.ownership.deps.storage);
            try store.waitDurable(try store.commit(1));
        } else {
            var slots: [47]inventories.Slot = undefined;
            var contents: [47]inventories.Contents = undefined;
            try fixture.menu.load(0, &slots, &contents);
            try std.testing.expect(contents[46].stack == null);
            var logs: u32 = 0;
            var planks: u32 = 0;
            for (contents[9..46]) |value| if (value.stack) |stack| {
                switch (try fixture.items.kind(stack)) {
                    else => |item| {
                        if (item == kind("minecraft:oak_log")) logs += stack.count;
                        if (item == kind("minecraft:oak_planks")) planks += stack.count;
                    },
                }
            };
            try std.testing.expectEqual(@as(u32, 1), logs);
            try std.testing.expectEqual(@as(u32, 4), planks);
        }
    }
}

test "default item identity matches the serialized definition" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/identity", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const fixture = try InventoryFixture.init(arena.allocator(), &store, &registry, &selected);
    defer fixture.service.deinit();
    try std.testing.expectEqual(item_data.defaultId(kind("minecraft:iron_ingot")), try fixture.items.defineKind(kind("minecraft:iron_ingot")));
}

fn blockContainers(allocator: std.mem.Allocator, store: *storage.Store, registry: *metrics.Registry, fixture: InventoryFixture) !*Containers {
    const resources = try records.Workspaces.init(allocator, std.testing.io, .{});
    const terrain = try chunks.Chunks.init(allocator, std.testing.io, .{ .cache_sections = 16, .demand_sections = 4, .cache_tiles = 4 }, .{ .storage = try store.openSpace("chunks"), .metrics = registry, .record_workspaces = resources });
    const experience = try Experience.init(allocator, .{ .maximum_orbs = 16 }, .{
        .enchantments = fixture.definitions.enchantments,
        .dimensions = fixture.definitions.dimensions,
        .players = fixture.players,
        .entities = fixture.bodies,
        .physics = try ItemPhysics.init(allocator, .{ .blocks = fixture.definitions.blocks, .chunks = terrain }),
        .inventories = fixture.ownership,
        .inventory = fixture.menu,
        .storage = try store.openSpace("experience"),
        .record_workspaces = resources,
    });
    return Containers.init(allocator, std.testing.io, .{ .active_furnaces = 8 }, .{
        .definitions = fixture.definitions.blocks,
        .furnaces = fixture.definitions.furnaces,
        .experience = experience,
        .metrics = registry,
        .players = fixture.players,
        .inventory = fixture.menu,
        .inventories = fixture.ownership,
        .chunks = terrain,
        .actions = try BlockActions.init(allocator, .{}),
        .dropped = fixture.dropped,
        .sessions = fixture.service,
        .packets = try packets.Packets.init(allocator, .{ .sessions = fixture.service }),
        .storage = try store.openSpace("containers"),
        .record_workspaces = resources,
    });
}

test "furnaces preserve exact cooking fuel and light transitions across durable restart" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/furnace", .{directory.sub_path});
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    var expected_burn: u32 = 0;
    var key: ContainerKey = undefined;
    for (0..3) |phase| {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const fixture = try InventoryFixture.init(bounded.allocator(), &store, &registry, &selected);
        defer fixture.service.deinit();
        const containers = try blockContainers(bounded.allocator(), &store, &registry, fixture);
        bounded.fail_index = bounded.alloc_index;
        key = .{ .world = fixture.players.records[0].world, .position = .{ .x = 2, .y = 1, .z = 0 } };
        const north = containers.states.furnaces[0];
        if (phase == 0) {
            const iron = try fixture.items.define("minecraft:raw_iron");
            const coal = try fixture.items.define("minecraft:coal");
            for (0..8) |index| {
                const next: ContainerKey = .{ .world = key.world, .position = .{ .x = @intCast(index + 2), .y = 1, .z = 0 } };
                try containers.deps.chunks.setBlock(next.world, next.position, north[0]);
                try std.testing.expect(try fixture.ownership.editMany(&.{
                    .{ .slot = .{ .owner = next.owner(), .index = 0 }, .revision = 0, .stack = .{ .item = iron, .count = 2 } },
                    .{ .slot = .{ .owner = next.owner(), .index = 1 }, .revision = 0, .stack = .{ .item = coal, .count = 1 } },
                }));
                try std.testing.expect(containers.activate(next));
            }
            for (0..73) |_| try furnace.tick(containers);
            const value = containers.furnaceState(key.world, key.position);
            try std.testing.expectEqual(@as(u32, 73), value.cook);
            try std.testing.expectEqual(@as(u32, 200), value.duration);
            expected_burn = value.burn_left;
            try std.testing.expectEqual(north[1], try containers.deps.chunks.getBlock(key.world, key.position));
            var encoded = key.encode();
            var bytes: [furnace.encoded_bytes]u8 = undefined;
            var lengths: [1]?usize = undefined;
            try containers.table.getBatch(&.{.{ .key = &encoded, .destination = &bytes }}, &lengths);
            try std.testing.expect(lengths[0] == null);
            try containers.checkpoint(containers.deps.storage);
            try fixture.ownership.checkpoint(fixture.ownership.deps.storage);
            try containers.deps.chunks.checkpoint(try store.openSpace("chunks"));
            try store.waitDurable(try store.commit(1));
        } else if (phase == 1) {
            try std.testing.expectEqual(@as(usize, 8), containers.active_count);
            const restored = containers.furnaceState(key.world, key.position);
            try std.testing.expectEqual(@as(u32, 73), restored.cook);
            try std.testing.expectEqual(expected_burn, restored.burn_left);
            for (0..127) |_| try furnace.tick(containers);
            const output = (try fixture.ownership.get(.{ .owner = key.owner(), .index = 2 })).stack.?;
            try std.testing.expectEqual(kind("minecraft:iron_ingot"), try fixture.items.kind(output));
            try std.testing.expectEqual(@as(u16, 1), output.count);
            try std.testing.expectEqual(@as(u16, 1), (try fixture.ownership.get(.{ .owner = key.owner(), .index = 0 })).stack.?.count);
            for (0..200) |_| try furnace.tick(containers);
            try std.testing.expectEqual(@as(u16, 2), (try fixture.ownership.get(.{ .owner = key.owner(), .index = 2 })).stack.?.count);
            try std.testing.expect((try fixture.ownership.get(.{ .owner = key.owner(), .index = 0 })).stack == null);
            for (0..1201) |_| try furnace.tick(containers);
            try std.testing.expectEqual(@as(usize, 0), containers.active_count);
            try std.testing.expectEqual(north[0], try containers.deps.chunks.getBlock(key.world, key.position));
            try containers.checkpoint(containers.deps.storage);
            try fixture.ownership.checkpoint(fixture.ownership.deps.storage);
            try containers.deps.chunks.checkpoint(try store.openSpace("chunks"));
            try store.waitDurable(try store.commit(2));
        } else {
            try std.testing.expectEqual(@as(usize, 0), containers.active_count);
            try std.testing.expectEqual(@as(u16, 2), (try fixture.ownership.get(.{ .owner = key.owner(), .index = 2 })).stack.?.count);
        }
    }
}

test "container clicks enforce output fuel stack and recipe remainder rules" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/clicks", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .capacity = 512 });
    defer registry.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const fixture = try InventoryFixture.init(bounded.allocator(), &store, &registry, &selected);
    defer fixture.service.deinit();
    const blocks = try blockContainers(bounded.allocator(), &store, &registry, fixture);
    bounded.fail_index = bounded.alloc_index;
    const bread: inventories.Stack = .{ .item = try fixture.items.define("minecraft:bread"), .count = 17 };
    const ingot: inventories.Stack = .{ .item = try fixture.items.define("minecraft:iron_ingot"), .count = 1 };
    {
        var next: [41]?inventories.Stack = @splat(null);
        var drag: menu_click.Drag = .{};
        const menu: menu_click.Menu = .{ .inventory = fixture.menu, .player = fixture.players.records[0].uuid, .location = fixture.location(.furnace), .kind = .furnace, .container_slots = 3, .stacks = &next, .drag = &drag, .creative = false };
        next[39] = bread;
        _ = try menu.apply(.{ .window_id = 1, .state_id = 0, .slot = 1, .button = 0, .mode = 0 });
        try std.testing.expect(next[1] == null);
        try std.testing.expectEqual(bread, next[39].?);
        _ = try menu.apply(.{ .window_id = 1, .state_id = 0, .slot = 0, .button = 0, .mode = 0 });
        try std.testing.expectEqual(bread, next[0].?);
        next[39] = ingot;
        _ = try menu.apply(.{ .window_id = 1, .state_id = 0, .slot = 2, .button = 0, .mode = 0 });
        try std.testing.expect(next[2] == null);
        next[2] = ingot;
        _ = try menu.apply(.{ .window_id = 1, .state_id = 0, .slot = 2, .button = 0, .mode = 0 });
        try std.testing.expectEqual(@as(u16, 2), next[39].?.count);
        try std.testing.expect(next[2] == null);
    }
    {
        var next: [48]?inventories.Stack = @splat(null);
        var drag: menu_click.Drag = .{};
        const menu: menu_click.Menu = .{ .inventory = fixture.menu, .player = fixture.players.records[0].uuid, .location = fixture.location(.crafting), .kind = .crafting, .container_slots = 10, .stacks = &next, .drag = &drag, .creative = false };
        const milk: inventories.Stack = .{ .item = try fixture.items.define("minecraft:milk_bucket"), .count = 1 };
        const sugar: inventories.Stack = .{ .item = try fixture.items.define("minecraft:sugar"), .count = 1 };
        const wheat: inventories.Stack = .{ .item = try fixture.items.define("minecraft:wheat"), .count = 1 };
        next[1] = milk;
        next[2] = milk;
        next[3] = milk;
        next[4] = sugar;
        next[5] = .{ .item = try fixture.items.define("minecraft:egg"), .count = 1 };
        next[6] = sugar;
        next[7] = wheat;
        next[8] = wheat;
        next[9] = wheat;
        _ = try menu.apply(.{ .window_id = 1, .state_id = 0, .slot = 0, .button = 0, .mode = 0 });
        try std.testing.expectEqual(kind("minecraft:cake"), try fixture.items.kind(next[46].?));
        for (next[1..4]) |stack| try std.testing.expectEqual(kind("minecraft:bucket"), try fixture.items.kind(stack.?));
        for (next[4..10]) |stack| try std.testing.expect(stack == null);
        try std.testing.expect(next[0] == null);
    }
    {
        var next: [47]?inventories.Stack = @splat(null);
        var drag: menu_click.Drag = .{};
        const menu: menu_click.Menu = .{ .inventory = fixture.menu, .player = fixture.players.records[0].uuid, .location = fixture.location(.player), .kind = .player, .container_slots = 0, .stacks = &next, .drag = &drag, .creative = false };
        const planks = try fixture.items.define("minecraft:oak_planks");
        next[1] = .{ .item = try fixture.items.define("minecraft:oak_log"), .count = 1 };
        for (next[9..45]) |*stack| stack.* = .{ .item = planks, .count = 64 };
        _ = try menu.apply(.{ .window_id = 0, .state_id = 0, .slot = 0, .button = 0, .mode = 1 });
        try std.testing.expectEqual(@as(u16, 1), next[1].?.count);
        next[44].?.count = 63;
        const result = try menu.apply(.{ .window_id = 0, .state_id = 0, .slot = 0, .button = 0, .mode = 1 });
        try std.testing.expect(next[1] == null);
        try std.testing.expectEqual(@as(u16, 64), next[44].?.count);
        try std.testing.expectEqual(@as(usize, 1), result.count);
        try std.testing.expectEqual(@as(u16, 3), result.drops[0].count);
        @memset(&next, null);
        next[1] = .{ .item = try fixture.items.define("minecraft:oak_log"), .count = 64 };
        const definitions_before = fixture.ownership.items.metrics.acquired.value();
        const shifted = try menu.apply(.{ .window_id = 0, .state_id = 0, .slot = 0, .button = 0, .mode = 1 });
        const definitions = fixture.ownership.items.metrics.acquired.value() - definitions_before;
        try std.testing.expect(definitions > 0 and definitions < 64);
        try std.testing.expectEqual(@as(usize, 0), shifted.count);
        try std.testing.expect(next[1] == null);
        var total: u32 = 0;
        for (next[9..45]) |stack| if (stack) |value| {
            total += value.count;
        };
        try std.testing.expectEqual(@as(u32, 256), total);
    }
    {
        const first: ContainerKey = .{ .world = fixture.players.records[0].world, .position = .{ .x = 2, .y = 1, .z = 0 } };
        const second: ContainerKey = .{ .world = first.world, .position = .{ .x = 3, .y = 1, .z = 0 } };
        for ([_]ContainerKey{ first, second }) |key| {
            try std.testing.expectEqual(BlockActions.Result.applied, try blocks.deps.actions.apply(.{ .action = .place, .player = &fixture.players.records[0], .position = key.position, .state = blocks.states.chests[0][0][0] }));
        }
        const state = try blocks.deps.chunks.getBlock(first.world, first.position);
        try std.testing.expectEqual(second.position, blocks.states.partner(state, first.position).?);
        try std.testing.expect(try fixture.ownership.set(Containers.slot(first.world, first.position, 0), 0, bread));
        try std.testing.expectEqual(BlockActions.Result.applied, try blocks.deps.actions.apply(.{ .action = .remove, .player = &fixture.players.records[0], .position = first.position, .state = state }));
        try std.testing.expect((try fixture.ownership.get(Containers.slot(first.world, first.position, 0))).stack == null);
        try std.testing.expectEqual(@as(u64, 0), (try fixture.ownership.get(Containers.slot(first.world, first.position, 1))).revision);
        try std.testing.expectEqual(@as(u16, 0), try blocks.deps.chunks.getBlock(first.world, first.position));
        try std.testing.expectEqual(blocks.states.chests[0][0][0], try blocks.deps.chunks.getBlock(second.world, second.position));
        var cursor: ItemEntities.Cursor = .{};
        const drops = try fixture.dropped.scan(&cursor);
        try std.testing.expectEqual(@as(usize, 1), drops.len);
        const body = (try fixture.bodies.get(drops[0].id)).?;
        const value = try fixture.ownership.get(ItemEntities.slot(body));
        try std.testing.expectEqual(bread, value.stack.?);
        const last: ContainerKey = .{ .world = first.world, .position = .{ .x = 5, .y = 1, .z = 0 } };
        const placed = try blocks.deps.actions.apply(.{ .action = .place, .player = &fixture.players.records[0], .position = last.position, .state = blocks.states.chests[0][0][0] });
        try std.testing.expectEqual(BlockActions.Result.applied, placed);
        try std.testing.expect(try fixture.ownership.set(Containers.slot(last.world, last.position, 0), 0, bread));
        const reserved = fixture.dropped.free_count;
        const denied = try blocks.deps.actions.apply(.{ .action = .remove, .player = &fixture.players.records[0], .position = last.position, .state = blocks.states.chests[0][0][0], .following_drops = reserved });
        try std.testing.expectEqual(BlockActions.Result.denied, denied);
        try std.testing.expectEqual(bread, (try fixture.ownership.get(Containers.slot(last.world, last.position, 0))).stack.?);
        try std.testing.expectEqual(reserved, fixture.dropped.free_count);
    }
}

test "shared chest clicks revalidate drag slots and preserve independent cursors" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/viewers", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const fixture = try InventoryFixture.init(bounded.allocator(), &store, &registry, &selected);
    defer fixture.service.deinit();
    const containers = try blockContainers(bounded.allocator(), &store, &registry, fixture);
    bounded.fail_index = bounded.alloc_index;
    const key: ContainerKey = .{ .world = fixture.players.records[0].world, .position = .{ .x = 2, .y = 1, .z = 0 } };
    const chest = containers.states.chests[0][0][0];
    try containers.deps.chunks.setBlock(key.world, key.position, chest);
    const bread: inventories.Stack = .{ .item = try fixture.items.define("minecraft:bread"), .count = 17 };
    const coal: inventories.Stack = .{ .item = try fixture.items.define("minecraft:coal"), .count = 6 };
    try std.testing.expect(try fixture.ownership.set(Containers.slot(key.world, key.position, 0), 0, bread));
    fixture.players.records[1] = fixture.players.records[0];
    fixture.players.records[1].uuid = 2;
    fixture.players.records[1].handle = .{ .index = 1, .generation = 1 };
    for (fixture.players.records) |*player| {
        player.gamemode = .survival;
        player.position = .{ .x = 2, .y = 1, .z = 3 };
        player.protocol = selected[0].number;
        try std.testing.expectEqual(BlockActions.Result.applied, try containers.deps.actions.apply(.{ .action = .use, .player = player, .position = key.position, .state = chest }));
        containers.views[player.handle.?.index].opened = true;
    }
    const alice = fixture.players.records[0].handle.?;
    const bob = fixture.players.records[1].handle.?;
    const alice_window = containers.views[0].window;
    const bob_window = containers.views[1].window;
    try std.testing.expectEqual(@as(usize, 3), containers.watch_index.count());
    const shared = containers.watch_index.get(key.owner()).?;
    try std.testing.expectEqual(@as(usize, 2), containers.watches[shared].users);
    const coal_slot: inventories.Slot = .{ .owner = 1, .index = std.math.maxInt(u16) };
    const bread_slot: inventories.Slot = .{ .owner = 2, .index = std.math.maxInt(u16) };
    const stored = try fixture.ownership.get(coal_slot);
    try std.testing.expect(try fixture.ownership.set(coal_slot, stored.revision, coal));
    try containers.click(alice, .{ .window_id = alice_window, .state_id = 0, .slot = -999, .button = 0, .mode = 5 });
    try containers.click(alice, .{ .window_id = alice_window, .state_id = 0, .slot = 1, .button = 1, .mode = 5 });
    try containers.click(bob, .{ .window_id = bob_window, .state_id = 0, .slot = 0, .button = 0, .mode = 0 });
    try containers.click(bob, .{ .window_id = bob_window, .state_id = 0, .slot = 1, .button = 0, .mode = 0 });
    try containers.click(alice, .{ .window_id = alice_window, .state_id = 0, .slot = -999, .button = 2, .mode = 5 });
    try std.testing.expectEqual(bread, (try fixture.ownership.get(Containers.slot(key.world, key.position, 1))).stack.?);
    try std.testing.expectEqual(coal, (try fixture.ownership.get(coal_slot)).stack.?);
    try containers.click(bob, .{ .window_id = bob_window, .state_id = 0, .slot = 1, .button = 0, .mode = 0 });
    try containers.click(alice, .{ .window_id = alice_window, .state_id = 0, .slot = 1, .button = 0, .mode = 1 });
    try std.testing.expectEqual(bread, (try fixture.ownership.get(bread_slot)).stack.?);
    try std.testing.expectEqual(coal, (try fixture.ownership.get(coal_slot)).stack.?);
    try containers.closeWindow(.{ .index = 0, .generation = 2 }, alice_window);
    try std.testing.expect(containers.opened.contains(0));
    try containers.closeWindow(alice, alice_window);
    try std.testing.expect(!containers.opened.contains(0));
    try std.testing.expect(containers.opened.contains(1));
    try std.testing.expectEqual(@as(usize, 1), containers.watches[shared].users);
    try std.testing.expectEqual(coal, (try fixture.ownership.get(coal_slot)).stack.?);
    try fixture.menu.closeMenu(0);
    try std.testing.expect((try fixture.ownership.get(coal_slot)).stack == null);
    try std.testing.expectEqual(coal, (try fixture.ownership.get(.{ .owner = 1, .index = 36 })).stack.?);
    try std.testing.expectEqual(bread, (try fixture.ownership.get(bread_slot)).stack.?);
    try containers.closeWindow(bob, bob_window);
    try fixture.menu.closeMenu(1);
    try std.testing.expect((try fixture.ownership.get(bread_slot)).stack == null);
    try std.testing.expectEqual(bread, (try fixture.ownership.get(.{ .owner = 2, .index = 36 })).stack.?);
    try std.testing.expectEqual(@as(usize, 0), containers.watch_index.count());

    try std.testing.expectEqual(BlockActions.Result.applied, try containers.deps.actions.apply(.{ .action = .use, .player = &fixture.players.records[1], .position = key.position, .state = chest }));
    fixture.players.records[1].handle = null;
    try containers.tick();
    try std.testing.expect(!containers.opened.contains(1));
    try std.testing.expect(!fixture.menu.states[1].external);
    try std.testing.expectEqual(@as(usize, 0), containers.watch_index.count());

    try std.testing.expectEqual(BlockActions.Result.applied, try containers.deps.actions.apply(.{ .action = .use, .player = &fixture.players.records[0], .position = key.position, .state = chest }));
    var edits: [37]inventories.Edit = undefined;
    for (&edits, 9..) |*edit, index| {
        const destination: inventories.Slot = .{ .owner = 1, .index = @intCast(index) };
        const previous = try fixture.ownership.get(destination);
        edit.* = .{ .slot = destination, .revision = previous.revision, .stack = .{ .item = bread.item, .count = 64 } };
    }
    try std.testing.expect(try fixture.ownership.editMany(&edits));
    const carried = try fixture.ownership.get(coal_slot);
    try std.testing.expect(try fixture.ownership.set(coal_slot, carried.revision, coal));
    const destination = Containers.slot(key.world, key.position, 0);
    const previous = try fixture.ownership.get(destination);
    try std.testing.expect(try fixture.ownership.set(destination, previous.revision, bread));
    while (fixture.dropped.free_count > 2) _ = try fixture.dropped.create(key.world, .{ 2, 1, 0 }, .{ 0, 0, 0 }, bread);
    try std.testing.expectEqual(BlockActions.Result.applied, try containers.deps.actions.apply(.{ .action = .remove, .player = &fixture.players.records[0], .position = key.position, .state = chest, .following_drops = 1 }));
    try std.testing.expect(!containers.opened.contains(0));
    try std.testing.expectEqual(@as(usize, 1), fixture.dropped.free_count);
    _ = try fixture.dropped.create(key.world, .{ 2, 1, 0 }, .{ 0, 0, 0 }, bread);
    try fixture.menu.closeMenu(0);
    try std.testing.expect(fixture.menu.states[0].close);
    try std.testing.expectEqual(coal, (try fixture.ownership.get(coal_slot)).stack.?);
}

fn checkpointMenus(fixture: InventoryFixture, containers: *Containers, store: *storage.Store) ![5]u64 {
    var ends: [5]u64 = undefined;
    try containers.deps.chunks.checkpoint(try store.openSpace("chunks"));
    ends[0] = store.end;
    try containers.checkpoint(containers.deps.storage);
    ends[1] = store.end;
    try fixture.bodies.checkpoint(fixture.bodies.deps.storage);
    ends[2] = store.end;
    try fixture.dropped.checkpoint(fixture.dropped.deps.storage);
    ends[3] = store.end;
    try fixture.ownership.checkpoint(fixture.ownership.deps.storage);
    ends[4] = store.end;
    return ends;
}

const conserved_names = [_][]const u8{ "minecraft:bread", "minecraft:coal", "minecraft:oak_log", "minecraft:raw_iron", "minecraft:iron_ingot" };

fn addOwned(totals: *[conserved_names.len]u64, contents: []const inventories.Contents) !void {
    for (contents) |entry| if (entry.stack) |stack| {
        try std.testing.expect(stack.count > 0 and stack.count <= 64);
        const index = for (conserved_names, 0..) |name, index| {
            const id = item_data.defaultId(kind(name));
            if (std.mem.eql(u8, &id, &stack.item)) break index;
        } else return error.UnexpectedOwnedItem;
        totals[index] += stack.count;
    };
}

fn countOwned(fixture: InventoryFixture, keys: []const ContainerKey) ![conserved_names.len]u64 {
    var totals: [conserved_names.len]u64 = @splat(0);
    var slots: [56]inventories.Slot = undefined;
    var contents: [56]inventories.Contents = undefined;
    for (fixture.players.records) |player| {
        for (&slots, 0..) |*slot, index| slot.* = .{ .owner = player.uuid, .index = if (index < 46) @intCast(index) else if (index == 46) std.math.maxInt(u16) else @intCast(PlayerInventory.table_grid_first + index - 47) };
        try fixture.ownership.getMany(&slots, &contents);
        try std.testing.expect(contents[0].stack == null);
        try addOwned(&totals, &contents);
    }
    for (keys) |key| {
        for (slots[0..27], 0..) |*slot, index| slot.* = Containers.slot(key.world, key.position, @intCast(index));
        try fixture.ownership.getMany(slots[0..27], contents[0..27]);
        try addOwned(&totals, contents[0..27]);
    }
    var cursor: ItemEntities.Cursor = .{};
    while (cursor.more) {
        const rows = try fixture.dropped.scan(&cursor);
        for (rows) |row| {
            if (!row.metadata.alive) continue;
            const body = (try fixture.bodies.get(row.id)) orelse return error.MissingDroppedBody;
            const owned = try fixture.ownership.get(ItemEntities.slot(body));
            try std.testing.expect(owned.stack != null);
            try addOwned(&totals, &.{owned});
        }
    }
    return totals;
}

test "interrupted container saves recover a complete ownership snapshot" {
    const io = std.testing.io;
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    for ([_]@FieldType(storage.Store.Options, "io_mode"){ .standard, .uring }) |backend| {
        var directory = std.testing.tmpDir(.{});
        defer directory.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/ownership", .{directory.sub_path});
        var wal_buffer: [272]u8 = undefined;
        const wal_path = try std.fmt.bufPrint(&wal_buffer, "{s}.wal", .{path});
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
        defer registry.deinit();
        var image: []u8 = undefined;
        var cuts: [9]u64 = undefined;
        var furnace_key: ContainerKey = undefined;
        var chest_key: ContainerKey = undefined;
        var saved_burn: u32 = undefined;
        {
            var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .io_mode = backend });
            defer store.deinit();
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
            const fixture = try InventoryFixture.init(bounded.allocator(), &store, &registry, &selected);
            defer fixture.service.deinit();
            const containers = try blockContainers(bounded.allocator(), &store, &registry, fixture);
            bounded.fail_index = bounded.alloc_index;
            fixture.players.records[1] = fixture.players.records[0];
            fixture.players.records[1].uuid = 2;
            fixture.players.records[1].handle = .{ .index = 1, .generation = 1 };
            chest_key = .{ .world = fixture.players.records[0].world, .position = .{ .x = 2, .y = 1, .z = 0 } };
            furnace_key = .{ .world = chest_key.world, .position = .{ .x = 4, .y = 1, .z = 0 } };
            const chest = containers.states.chests[0][0][0];
            try containers.deps.chunks.setBlock(chest_key.world, chest_key.position, chest);
            try containers.deps.chunks.setBlock(furnace_key.world, furnace_key.position, containers.states.furnaces[0][0]);
            for (fixture.players.records) |*player| {
                player.gamemode = .survival;
                player.position = .{ .x = 2, .y = 1, .z = 3 };
                player.protocol = selected[0].number;
                try std.testing.expectEqual(BlockActions.Result.applied, try containers.deps.actions.apply(.{ .action = .use, .player = player, .position = chest_key.position, .state = chest }));
                containers.views[player.handle.?.index].opened = true;
            }
            const bread: inventories.Stack = .{ .item = try fixture.items.define(conserved_names[0]), .count = 17 };
            const coal: inventories.Stack = .{ .item = try fixture.items.define(conserved_names[1]), .count = 6 };
            const log: inventories.Stack = .{ .item = try fixture.items.define(conserved_names[2]), .count = 1 };
            const iron: inventories.Stack = .{ .item = try fixture.items.define(conserved_names[3]), .count = 2 };
            const initial_slots = [_]inventories.Slot{
                Containers.slot(chest_key.world, chest_key.position, 0),
                Containers.slot(furnace_key.world, furnace_key.position, 0),
                Containers.slot(furnace_key.world, furnace_key.position, 1),
                .{ .owner = 1, .index = 65535 },
                .{ .owner = 1, .index = 1 },
                .{ .owner = 1, .index = PlayerInventory.table_grid_first },
            };
            const stacks = [_]inventories.Stack{ bread, iron, .{ .item = coal.item, .count = 1 }, coal, log, .{ .item = log.item, .count = 2 } };
            var edits: [initial_slots.len]inventories.Edit = undefined;
            for (initial_slots, stacks, &edits) |slot, stack, *edit| edit.* = .{ .slot = slot, .revision = (try fixture.ownership.get(slot)).revision, .stack = stack };
            try std.testing.expect(try fixture.ownership.editMany(&edits));
            try std.testing.expect(containers.activate(furnace_key));
            for (0..73) |_| try furnace.tick(containers);
            saved_burn = containers.furnaceState(furnace_key.world, furnace_key.position).burn_left;
            _ = try checkpointMenus(fixture, containers, &store);
            try store.waitDurable(try store.commit(1));
            cuts[0] = store.end;
            const bob = fixture.players.records[1].handle.?;
            const window = containers.views[1].window;
            try containers.click(bob, .{ .window_id = window, .state_id = 0, .slot = 0, .button = 0, .mode = 0 });
            try containers.click(bob, .{ .window_id = window, .state_id = 0, .slot = -999, .button = 0, .mode = 0 });
            try containers.closeWindow(bob, window);
            try containers.closeWindow(fixture.players.records[0].handle.?, containers.views[0].window);
            try fixture.menu.closeMenu(0);
            try fixture.menu.closeMenu(1);
            try std.testing.expectEqual(BlockActions.Result.applied, try containers.deps.actions.apply(.{ .action = .remove, .player = &fixture.players.records[0], .position = chest_key.position, .state = chest }));
            for (0..127) |_| try furnace.tick(containers);
            const ends = try checkpointMenus(fixture, containers, &store);
            @memcpy(cuts[1..6], &ends);
            _ = try store.commit(2);
            cuts[6] = store.end - @sizeOf(storage.Page) / 2;
            cuts[7] = store.end - 1;
            cuts[8] = store.end;
            image = try std.testing.allocator.alloc(u8, @intCast(store.end));
            try std.testing.expectEqual(image.len, try store.wal.readPositionalAll(io, image, 0));
        }
        defer std.testing.allocator.free(image);
        for (cuts, 0..) |cut, index| {
            errdefer std.debug.print("container recovery backend={t} cut={d} bytes={d}\n", .{ backend, index, cut });
            {
                const file = try std.Io.Dir.cwd().createFile(io, wal_path, .{});
                defer file.close(io);
                try file.writePositionalAll(io, image[0..@intCast(cut)], 0);
            }
            var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .io_mode = backend });
            defer store.deinit();
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
            const fixture = try InventoryFixture.init(bounded.allocator(), &store, &registry, &selected);
            defer fixture.service.deinit();
            const containers = try blockContainers(bounded.allocator(), &store, &registry, fixture);
            fixture.players.records[1] = fixture.players.records[0];
            fixture.players.records[1].uuid = 2;
            fixture.players.records[1].handle = .{ .index = 1, .generation = 1 };
            fixture.players.records[0].gamemode = .survival;
            fixture.players.records[1].gamemode = .survival;
            bounded.fail_index = bounded.alloc_index;
            const complete = cut == image.len;
            try std.testing.expectEqual(@as(u64, if (complete) 2 else 1), store.lastTick());
            const totals = try countOwned(fixture, &.{ chest_key, furnace_key });
            try std.testing.expectEqualSlices(u64, &.{ 17, 6, 3, if (complete) 1 else 2, if (complete) 1 else 0 }, &totals);
            try std.testing.expectEqual(complete, (try containers.deps.chunks.getBlock(chest_key.world, chest_key.position)) == 0);
            try std.testing.expectEqual(@as(usize, if (complete) 7 else 8), fixture.dropped.free_count);
            const counters = containers.furnaceState(furnace_key.world, furnace_key.position);
            try std.testing.expectEqual(@as(u32, if (complete) 0 else 73), counters.cook);
            try std.testing.expectEqual(saved_burn - @as(u32, if (complete) 127 else 0), counters.burn_left);
            for (0..2) |player| {
                var slots: [47]inventories.Slot = undefined;
                var contents: [47]inventories.Contents = undefined;
                try fixture.menu.load(player, &slots, &contents);
                try std.testing.expect(contents[46].stack == null);
                for (contents[1..5]) |entry| try std.testing.expect(entry.stack == null);
            }
            const recovered = try countOwned(fixture, &.{ chest_key, furnace_key });
            try std.testing.expectEqualSlices(u64, &totals, &recovered);
        }
    }
}

test "inventory cache defaults follow player capacity and preserve explicit overrides" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/capacity", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const fixture = try InventoryFixture.init(arena.allocator(), &store, &registry, &selected);
    defer fixture.service.deinit();
    const capacity = try InventoryCapacity.init(arena.allocator(), .{ .players = fixture.players });
    var deps = fixture.ownership.deps;
    deps.capacity = capacity.provide(inventories.SlotCapacity);
    const automatic = try inventories.Inventories.init(arena.allocator(), std.testing.io, .{ .cache_items = 1, .max_item_bytes = 1024 }, deps);
    try std.testing.expectEqual(92 * fixture.players.config.maximum, automatic.cache.entries.len);
    const explicit = try inventories.Inventories.init(arena.allocator(), std.testing.io, .{ .cache_slots = 256, .cache_items = 1, .max_item_bytes = 1024 }, deps);
    try std.testing.expectEqual(@as(usize, 256), explicit.cache.entries.len);
    deps.capacity = null;
    const standalone = try inventories.Inventories.init(arena.allocator(), std.testing.io, .{ .cache_items = 1, .max_item_bytes = 1024 }, deps);
    try std.testing.expectEqual(@as(usize, 256), standalone.cache.entries.len);
}

const crafting = @import("crafting.zig");

const ChargedRecipe = struct {
    pub const id = "test:charged";
    pub const minimum_inputs = 1;
    pub const maximum_inputs = 1;
    pub const Parameters = struct { increment: i32 };
    pub const Completion = struct { cost: u32, player: u128 };
    const Implementation = crafting.Implementation(ChargedRecipe);
    allowed_player: u128 = 1,
    expected_location: ?crafting.Location = null,
    credits: u32 = 2,
    commits: usize = 0,

    pub fn prepare(self: *ChargedRecipe, parameters: *const Parameters, context: *const crafting.Context) !?Implementation.Prepared {
        if (self.expected_location) |expected| std.debug.assert(std.meta.eql(expected, context.location));
        if (context.player != self.allowed_player) return null;
        var reserved: u32 = 0;
        var pending = Implementation.pending(self, context);
        while (pending.next()) |completion| reserved += completion.cost;
        if (reserved >= self.credits) return null;
        for (context.input, 0..) |entry, index| {
            const input = entry orelse continue;
            const data = try input.customData() orelse return null;
            const charge = try data.getInt("charge") orelse return null;
            var editor = try data.edit(context.scratch.allocator());
            try editor.setInt("charge", try std.math.add(i32, charge, parameters.increment));
            var result = try context.result(kind("minecraft:diamond"), 1);
            try result.copyComponents(input.view);
            try result.set(.custom_data, try editor.finish());
            var plan: crafting.Plan = .{ .result = result.finish() };
            plan.consume[index] = 1;
            return .{ .plan = plan, .completion = .{ .cost = 1, .player = context.player } };
        }
        return null;
    }

    pub fn validate(self: *ChargedRecipe, completions: []const Completion) bool {
        var total: u32 = 0;
        for (completions) |completion| {
            if (completion.player != self.allowed_player) return false;
            total += completion.cost;
        }
        return total <= self.credits;
    }

    pub fn complete(self: *ChargedRecipe, completions: []const Completion) void {
        std.debug.assert(self.validate(completions));
        for (completions) |completion| self.credits -= completion.cost;
        self.commits += 1;
    }
};

test "algorithmic crafting derives NBT and commits effects only with the inventory batch" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/algorithmic", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = bounded.allocator();
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const fixture = try InventoryFixture.init(allocator, &store, &registry, &selected);
    defer fixture.service.deinit();
    var owner: ChargedRecipe = .{};
    const implementation = try ChargedRecipe.Implementation.define(allocator, &owner, .{ .increment = 5 });
    const content = try Crafting.init(allocator, .{ .definitions = .{ .recipes = &.{.{ .name = "test:charged", .definition = .{ .algorithmic = implementation } }} } }, .{ .items = fixture.definitions.items });
    fixture.players.records[0].gamemode = .survival;
    fixture.menu.states[0] = .{ .generation = 1, .life = fixture.players.records[0].life, .close = false, .gamemode = .survival };
    fixture.menu.recipes = &content.table;
    fixture.menu.deps.crafting = content;
    var data: custom_data.Editor = .{ .allocator = allocator };
    try data.setInt("charge", 7);
    try data.setString("owner", "test:player");
    const item = try item_data.define(fixture.ownership, kind("minecraft:paper"), &.{.{ .key = item_data.key(.custom_data), .value = try data.finish() }});
    const input_slot: inventories.Slot = .{ .owner = 1, .index = 1 };
    try std.testing.expect(try fixture.ownership.set(input_slot, 0, .{ .item = item, .count = 3 }));
    bounded.fail_index = bounded.alloc_index;
    const allowed_player: u128 = 0x123456789abcdef0_fedcba9876543210;
    owner.allowed_player = allowed_player;
    for ([_]menu_click.Kind{ .player, .crafting }) |menu_kind| {
        var next: [48]?inventories.Stack = @splat(null);
        next[1] = .{ .item = item, .count = 3 };
        var drag: menu_click.Drag = .{};
        var menu: menu_click.Menu = .{
            .inventory = fixture.menu,
            .player = allowed_player + 1,
            .location = fixture.location(menu_kind),
            .kind = menu_kind,
            .container_slots = if (menu_kind == .player) 0 else 10,
            .stacks = next[0..if (menu_kind == .player) 47 else 48],
            .drag = &drag,
            .creative = false,
        };
        owner.expected_location = menu.location;
        try menu.refresh();
        try std.testing.expect(next[0] == null);
        menu.player = allowed_player;
        try menu.refresh();
        try std.testing.expect(next[0] != null);
        owner.allowed_player = allowed_player + 1;
        const rejected = try menu.apply(.{ .window_id = 0, .state_id = 0, .slot = 0, .button = 0, .mode = 1 });
        try std.testing.expect(next[0] == null);
        try std.testing.expectEqual(@as(u16, 3), next[1].?.count);
        try std.testing.expect(menu.stacks[menu.cursor()] == null);
        try std.testing.expectEqual(@as(usize, 0), rejected.count);
        for (next[2..]) |stack| try std.testing.expect(stack == null);
        try std.testing.expectEqual(@as(usize, 0), owner.commits);
        try std.testing.expectEqual(@as(u32, 2), owner.credits);
        owner.allowed_player = allowed_player;
    }
    owner.allowed_player = fixture.players.records[0].uuid;
    owner.expected_location = fixture.location(.player);
    var slots: [47]inventories.Slot = undefined;
    var contents: [47]inventories.Contents = undefined;
    try fixture.menu.load(0, &slots, &contents);
    var next: [47]?inventories.Stack = undefined;
    for (&next, contents) |*stack, value| stack.* = value.stack;
    var drag: menu_click.Drag = .{};
    const menu: menu_click.Menu = .{ .inventory = fixture.menu, .player = fixture.players.records[0].uuid, .location = fixture.location(.player), .kind = .player, .container_slots = 0, .stacks = &next, .drag = &drag, .creative = false };
    const result = try menu.apply(.{ .window_id = 0, .state_id = 0, .slot = 0, .button = 0, .mode = 1 });
    try std.testing.expectEqual(@as(u16, 1), next[1].?.count);
    const output = next[44].?;
    try std.testing.expectEqual(@as(u16, 2), output.count);
    const lease = try fixture.ownership.acquireItem(output.item);
    const view = try item_data.View.parse(lease.read().?);
    const derived = (try (crafting.Input{ .stack = output, .view = view }).customData()).?;
    try std.testing.expectEqual(@as(i32, 12), (try derived.getInt("charge")).?);
    try std.testing.expectEqualStrings("test:player", (try derived.getString("owner", allocator)).?);
    lease.release();
    try std.testing.expectEqual(@as(u32, 2), owner.credits);
    const batch = result.craft_batch.?;
    owner.allowed_player = 2;
    try std.testing.expect(!fixture.menu.validateCraft(batch));
    try std.testing.expectEqual(@as(u16, 3), (try fixture.ownership.get(input_slot)).stack.?.count);
    owner.allowed_player = fixture.players.records[0].uuid;
    owner.credits = 1;
    try std.testing.expect(!fixture.menu.validateCraft(batch));
    try std.testing.expectEqual(@as(u16, 3), (try fixture.ownership.get(input_slot)).stack.?.count);
    try std.testing.expectEqual(@as(usize, 0), owner.commits);
    owner.credits = 2;
    try std.testing.expect(fixture.menu.validateCraft(batch));
    try std.testing.expect(try fixture.menu.apply(0, &slots, &contents, &next, result.drops[0..result.count]));
    fixture.menu.completeCraft(batch);
    try std.testing.expectEqual(@as(u32, 0), owner.credits);
    try std.testing.expectEqual(@as(usize, 1), owner.commits);
    try std.testing.expectEqual(@as(u16, 1), (try fixture.ownership.get(input_slot)).stack.?.count);
    const original = try fixture.ownership.acquireItem(item);
    defer original.release();
    const original_data = (try (crafting.Input{ .stack = .{ .item = item, .count = 1 }, .view = try item_data.View.parse(original.read().?) }).customData()).?;
    try std.testing.expectEqual(@as(i32, 7), (try original_data.getInt("charge")).?);
}

test "recipe book placement validates real crafting table and furnace views before atomic edits" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    for (0..2) |station| {
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/book-{d}", .{ directory.sub_path, station });
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
        defer store.deinit();
        var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
        defer registry.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
        const fixture = try InventoryFixture.init(bounded.allocator(), &store, &registry, &selected);
        defer fixture.service.deinit();
        const containers = try blockContainers(bounded.allocator(), &store, &registry, fixture);
        const player = &fixture.players.records[0];
        player.position = .{ .x = 0.5, .y = 2, .z = 0.5 };
        player.gamemode = .survival;
        const key: ContainerKey = .{ .world = player.world, .position = .{ .x = 2, .y = 1, .z = 0 } };
        const source: inventories.Slot = .{ .owner = player.uuid, .index = 9 };
        const item = try fixture.items.define(if (station == 0) "minecraft:oak_planks" else "minecraft:iron_ore");
        try std.testing.expect(try fixture.ownership.set(source, 0, .{ .item = item, .count = 12 }));
        if (station == 1) {
            const coal = try fixture.items.define("minecraft:coal");
            try std.testing.expect(try fixture.ownership.set(Containers.slot(key.world, key.position, 1), 0, .{ .item = coal, .count = 8 }));
        }
        const name = if (station == 0) "minecraft:crafting_table" else "minecraft:iron_ingot_from_smelting_iron_ore";
        const recipe = for (fixture.definitions.book.table.book) |*entry| {
            if (std.mem.eql(u8, name, entry.name)) break entry;
        } else unreachable;
        containers.views[0] = .{
            .opened = true,
            .generation = 1,
            .life = player.life,
            .key = key,
            .owners = .{ key.owner(), 0 },
            .kind = if (station == 0) .crafting else .furnace,
            .container_slots = if (station == 0) 10 else 3,
            .window = 4,
        };
        bounded.fail_index = bounded.alloc_index;
        try std.testing.expectEqual(recipe_placement.Result.blocked, try containers.placeRecipe(player.handle.?, 3, &fixture.definitions.book.table, recipe, true));
        try std.testing.expectEqual(@as(u16, 12), (try fixture.ownership.get(source)).stack.?.count);
        player.position.x = 100;
        try std.testing.expectEqual(recipe_placement.Result.blocked, try containers.placeRecipe(player.handle.?, 4, &fixture.definitions.book.table, recipe, true));
        try std.testing.expectEqual(@as(u16, 12), (try fixture.ownership.get(source)).stack.?.count);
        player.position.x = 0.5;
        try std.testing.expectEqual(recipe_placement.Result.placed, try containers.placeRecipe(player.handle.?, 4, &fixture.definitions.book.table, recipe, true));
        try std.testing.expect((try fixture.ownership.get(source)).stack == null);
        if (station == 0) {
            for ([_]u16{ 0, 1, 3, 4 }) |index| {
                const stack = (try fixture.ownership.get(.{ .owner = player.uuid, .index = PlayerInventory.table_grid_first + index })).stack.?;
                try std.testing.expectEqual(item, stack.item);
                try std.testing.expectEqual(@as(u16, 3), stack.count);
            }
        } else {
            const stack = (try fixture.ownership.get(Containers.slot(key.world, key.position, 0))).stack.?;
            try std.testing.expectEqual(item, stack.item);
            try std.testing.expectEqual(@as(u16, 12), stack.count);
            try std.testing.expectEqual(@as(u16, 8), (try fixture.ownership.get(Containers.slot(key.world, key.position, 1))).stack.?.count);
            try std.testing.expectEqual(@as(usize, 1), containers.active_count);
        }
    }
}

test "component smelting preserves identity stack limits and blocked inventories across durable restart" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/component-furnace", .{directory.sub_path});
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    for (0..3) |phase| {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const allocator = bounded.allocator();
        const fixture = try InventoryFixture.init(allocator, &store, &registry, &selected);
        defer fixture.service.deinit();
        var data: custom_data.Editor = .{ .allocator = allocator };
        try data.setInt("charge", 7);
        const components = [_]item_data.Component{
            .{ .key = item_data.key(.custom_data), .value = try data.finish() },
            .{ .key = item_data.key(.max_stack_size), .value = &.{3} },
        };
        _ = try provider.register(fixture.definitions, allocator, .{ .recipes = &.{.{
            .name = "minecraft:iron_ingot_from_smelting_raw_iron",
            .definition = .{ .smelting = .{
                .input = .{ .item = "minecraft:raw_iron" },
                .result = .{ .item = "minecraft:iron_ingot", .count = 2, .components = &components },
                .ticks = 3,
            } },
        }} }, null);
        const installed = fixture.definitions.furnaces.table.recipes.ptr;
        try std.testing.expectError(error.InvalidRecipeResult, provider.register(fixture.definitions, allocator, .{ .recipes = &.{.{
            .name = "test:oversized_smelting",
            .definition = .{ .smelting = .{
                .input = .{ .item = "minecraft:raw_iron" },
                .result = .{ .item = "minecraft:iron_ingot", .count = 4, .components = &components },
            } },
        }} }, null));
        try std.testing.expectEqual(installed, fixture.definitions.furnaces.table.recipes.ptr);
        const containers = try blockContainers(allocator, &store, &registry, fixture);
        const recipe = fixture.definitions.furnaces.table.recipes[kind("minecraft:raw_iron")].?;
        try std.testing.expectEqual(@as(u16, 3), recipe.stack_limit);
        const custom = recipe.item_id;
        const plain = item_data.defaultId(kind("minecraft:iron_ingot"));
        try std.testing.expect(!std.mem.eql(u8, &custom, &plain));
        var keys: [5]ContainerKey = undefined;
        for (&keys, 0..) |*key, index| key.* = .{ .world = fixture.players.records[0].world, .position = .{ .x = @intCast(index + 2), .y = 1, .z = 0 } };
        if (phase == 0) {
            const raw = try fixture.items.define("minecraft:raw_iron");
            const coal = try fixture.items.define("minecraft:coal");
            try std.testing.expectEqual(custom, try item_data.define(fixture.ownership, kind("minecraft:iron_ingot"), &components));
            try std.testing.expectEqual(plain, try fixture.items.define("minecraft:iron_ingot"));
            var different_data: custom_data.Editor = .{ .allocator = allocator };
            try different_data.setInt("charge", 8);
            var different_components = components;
            different_components[0].value = try different_data.finish();
            const different = try item_data.define(fixture.ownership, kind("minecraft:iron_ingot"), &different_components);
            const outputs: [5]?inventories.Stack = .{
                null,
                .{ .item = custom, .count = 1 },
                .{ .item = plain, .count = 1 },
                .{ .item = different, .count = 1 },
                .{ .item = custom, .count = 3 },
            };
            const inputs = [_]u16{ 3, 2, 1, 1, 1 };
            var edits: [15]inventories.Edit = undefined;
            for (keys, outputs, inputs, 0..) |key, output, input, index| {
                try containers.deps.chunks.setBlock(key.world, key.position, containers.states.furnaces[0][0]);
                edits[index * 3] = .{ .slot = Containers.slot(key.world, key.position, 0), .revision = 0, .stack = .{ .item = raw, .count = input } };
                edits[index * 3 + 1] = .{ .slot = Containers.slot(key.world, key.position, 1), .revision = 0, .stack = .{ .item = coal, .count = 1 } };
                edits[index * 3 + 2] = .{ .slot = Containers.slot(key.world, key.position, 2), .revision = 0, .stack = output };
            }
            try std.testing.expect(try fixture.ownership.editMany(&edits));
            for (keys) |key| try std.testing.expect(containers.activate(key));
        }
        bounded.fail_index = bounded.alloc_index;
        if (phase == 0) {
            try furnace.tick(containers);
            for (keys[0..2]) |key| try std.testing.expectEqual(@as(u32, 1), containers.furnaceState(key.world, key.position).cook);
        } else {
            if (phase == 1) {
                for (keys[0..2]) |key| try std.testing.expectEqual(@as(u32, 1), containers.furnaceState(key.world, key.position).cook);
                for (0..10) |_| try furnace.tick(containers);
            }
            for (keys[0..2], 0..) |key, index| {
                const output = (try fixture.ownership.get(Containers.slot(key.world, key.position, 2))).stack.?;
                try std.testing.expectEqual(custom, output.item);
                try std.testing.expectEqual(@as(u16, @intCast(2 + index)), output.count);
                try std.testing.expectEqual(@as(u16, @intCast(2 - index)), (try fixture.ownership.get(Containers.slot(key.world, key.position, 0))).stack.?.count);
                const prepared = try fixture.items.acquire(output);
                defer prepared.release();
                const saved = try custom_data.Compound.init(prepared.view.value(.custom_data).?);
                try std.testing.expectEqual(@as(?i32, 7), try saved.getInt("charge"));
            }
        }
        for (keys[2..], 0..) |key, index| {
            try std.testing.expectEqual(@as(u16, 1), (try fixture.ownership.get(Containers.slot(key.world, key.position, 0))).stack.?.count);
            try std.testing.expectEqual(@as(u16, 1), (try fixture.ownership.get(Containers.slot(key.world, key.position, 1))).stack.?.count);
            const output = (try fixture.ownership.get(Containers.slot(key.world, key.position, 2))).stack.?;
            try std.testing.expectEqual(@as(u16, if (index == 2) 3 else 1), output.count);
            if (index == 0) try std.testing.expectEqual(plain, output.item);
            if (index == 1) {
                const prepared = try fixture.items.acquire(output);
                defer prepared.release();
                const saved = try custom_data.Compound.init(prepared.view.value(.custom_data).?);
                try std.testing.expectEqual(@as(?i32, 8), try saved.getInt("charge"));
            }
            try std.testing.expectEqual(@as(u32, 0), containers.furnaceState(key.world, key.position).burn_left);
        }
        if (phase < 2) {
            try containers.checkpoint(containers.deps.storage);
            try fixture.ownership.checkpoint(fixture.ownership.deps.storage);
            try containers.deps.chunks.checkpoint(try store.openSpace("chunks"));
            try store.waitDurable(try store.commit(phase + 1));
        }
    }
}

test "furnace mechanics use configured fuels remainders and completion rules" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const cooking_ticks = 2;
    for ([_]bool{ false, true }) |disable_conversion| {
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/configured-furnace-{d}", .{ directory.sub_path, @intFromBool(disable_conversion) });
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
        defer store.deinit();
        var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
        defer registry.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const allocator = bounded.allocator();
        const fixture = try InventoryFixture.init(allocator, &store, &registry, &selected);
        defer fixture.service.deinit();
        const conversions = [_]FuelConversionDefinition{
            .{ .input = "minecraft:dirt", .fuel = "minecraft:glass_bottle", .result = "minecraft:emerald" },
            .{ .input = "minecraft:wet_sponge", .fuel = "minecraft:bucket", .result = null },
        };
        _ = try provider.register(fixture.definitions, allocator, .{
            .fuels = &.{.{ .input = .{ .item = "minecraft:charcoal" }, .ticks = cooking_ticks }},
            .remainders = &.{.{ .input = .{ .item = "minecraft:charcoal" }, .item = "minecraft:glass_bottle" }},
            .fuel_conversions = conversions[0..if (disable_conversion) 2 else 1],
            .recipes = &.{
                .{ .name = "aaa:dirt", .definition = .{ .smelting = .{ .input = .{ .item = "minecraft:dirt" }, .result = .{ .item = "minecraft:diamond" }, .ticks = cooking_ticks } } },
                .{ .name = "aaa:sponge", .definition = .{ .smelting = .{ .input = .{ .item = "minecraft:wet_sponge" }, .result = .{ .item = "minecraft:sponge" }, .ticks = cooking_ticks } } },
            },
        }, null);
        const containers = try blockContainers(allocator, &store, &registry, fixture);
        const keys = [_]ContainerKey{
            .{ .world = fixture.players.records[0].world, .position = .{ .x = 2, .y = 1, .z = 0 } },
            .{ .world = fixture.players.records[0].world, .position = .{ .x = 3, .y = 1, .z = 0 } },
        };
        const inputs = [_][]const u8{ "minecraft:dirt", "minecraft:wet_sponge" };
        const fuels = [_][]const u8{ "minecraft:charcoal", "minecraft:lava_bucket" };
        var edits: [4]inventories.Edit = undefined;
        for (keys, inputs, fuels, 0..) |key, input, fuel_name, index| {
            try containers.deps.chunks.setBlock(key.world, key.position, containers.states.furnaces[0][0]);
            edits[index * 2] = .{ .slot = Containers.slot(key.world, key.position, 0), .revision = 0, .stack = .{ .item = try fixture.items.define(input), .count = if (index == 0) 2 else 1 } };
            edits[index * 2 + 1] = .{ .slot = Containers.slot(key.world, key.position, 1), .revision = 0, .stack = .{ .item = try fixture.items.define(fuel_name), .count = 1 } };
        }
        try std.testing.expect(try fixture.ownership.editMany(&edits));
        for (keys) |key| try std.testing.expect(containers.activate(key));
        bounded.fail_index = bounded.alloc_index;
        for (0..cooking_ticks * 2) |_| try furnace.tick(containers);
        const custom_fuel = (try fixture.ownership.get(Containers.slot(keys[0].world, keys[0].position, 1))).stack.?;
        try std.testing.expectEqual(kind("minecraft:emerald"), try fixture.items.kind(custom_fuel));
        try std.testing.expectEqual(@as(u16, 1), (try fixture.ownership.get(Containers.slot(keys[0].world, keys[0].position, 0))).stack.?.count);
        const custom_output = (try fixture.ownership.get(Containers.slot(keys[0].world, keys[0].position, 2))).stack.?;
        try std.testing.expectEqual(kind("minecraft:diamond"), try fixture.items.kind(custom_output));
        try std.testing.expectEqual(@as(u16, 1), custom_output.count);
        try std.testing.expectEqual(@as(u32, 0), containers.furnaceState(keys[0].world, keys[0].position).burn_left);
        const sponge_fuel = (try fixture.ownership.get(Containers.slot(keys[1].world, keys[1].position, 1))).stack.?;
        try std.testing.expectEqual(if (disable_conversion) kind("minecraft:bucket") else kind("minecraft:water_bucket"), try fixture.items.kind(sponge_fuel));
        const sponge_output = (try fixture.ownership.get(Containers.slot(keys[1].world, keys[1].position, 2))).stack.?;
        try std.testing.expectEqual(kind("minecraft:sponge"), try fixture.items.kind(sponge_output));
    }
}

const ContextualFuel = struct {
    pub const Parameters = struct { label: []const u8, player: u128, x: i32 };

    pub fn prepare(_: *ContextualFuel, parameters: *const Parameters, context: *const fuel.Context) !?fuel.Plan {
        if (!std.mem.eql(u8, parameters.label, "owned")) return error.BorrowedFuelParameters;
        if (context.location.position.x != parameters.x) return null;
        const data = try context.fuel.customData() orelse return null;
        if ((try data.getInt("charge") orelse return null) != 7) return null;
        const properties: fuel.Properties = .{ .ticks = 2, .slot_limit = 4 };
        if (context.phase != .burn and context.player != parameters.player) return null;
        if (context.phase == .admission) return .{ .properties = properties };
        var editor = try data.edit(context.scratch.allocator());
        var text: [32]u8 = undefined;
        const identity = try std.fmt.bufPrint(&text, "{x:0>32}", .{parameters.player});
        if (context.phase == .insertion) {
            try editor.setString("actor", identity);
        } else {
            if (context.player != null) return error.InventedFuelActor;
            const source = context.input orelse return error.MissingFuelInput;
            if (source.view.kind != kind("minecraft:dirt")) return error.WrongFuelInput;
            const saved = try data.getString("actor", context.scratch.allocator()) orelse return null;
            if (!std.mem.eql(u8, saved, identity)) return null;
            try editor.setInt("charge", 12);
        }
        var replacement = try context.result(if (context.phase == .insertion) context.fuel.view.kind else kind("minecraft:diamond"), context.fuel.stack.count);
        try replacement.copyComponents(context.fuel.view);
        try replacement.set(.custom_data, try editor.finish());
        return .{ .properties = properties, .replacement = .{ .stack = replacement.finish() } };
    }
};

test "fuel callbacks receive actor position and NBT and preserve plugin provenance across restart" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/callback-fuel", .{directory.sub_path});
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    for (0..2) |pass| {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const allocator = bounded.allocator();
        const fixture = try InventoryFixture.init(allocator, &store, &registry, &selected);
        defer fixture.service.deinit();
        var policy: ContextualFuel = .{};
        var label = "owned".*;
        try fixture.definitions.furnaces.addDefinitions(.{
            .fuels = &.{.{ .input = .{ .item = "minecraft:paper" }, .callback = try fuel.Handler(ContextualFuel, ContextualFuel.Parameters, ContextualFuel.prepare).define(allocator, &policy, .{ .label = &label, .player = 1, .x = 2 }) }},
            .recipes = &.{.{ .name = "test:fuel_input", .definition = .{ .smelting = .{ .input = .{ .item = "minecraft:dirt" }, .result = .{ .item = "minecraft:iron_ingot" }, .ticks = 2 } } }},
        });
        @memset(&label, 'x');
        const containers = try blockContainers(allocator, &store, &registry, fixture);
        const player = &fixture.players.records[0];
        player.protocol = selected[0].number;
        player.position = .{ .x = 2, .y = 1, .z = 3 };
        player.gamemode = .survival;
        const key: ContainerKey = .{ .world = player.world, .position = .{ .x = 2, .y = 1, .z = 0 } };
        bounded.fail_index = bounded.alloc_index;
        if (pass == 0) {
            const nbt = &[_]u8{ 10, 3, 0, 6, 'c', 'h', 'a', 'r', 'g', 'e', 0, 0, 0, 7, 0 };
            const item = try item_data.define(fixture.ownership, kind("minecraft:paper"), &.{.{ .key = item_data.key(.custom_data), .value = nbt }});
            var wrong = nbt.*;
            wrong[wrong.len - 2] = 6;
            const wrong_item = try item_data.define(fixture.ownership, kind("minecraft:paper"), &.{.{ .key = item_data.key(.custom_data), .value = &wrong }});
            for (0..4) |attempt| {
                var stacks: [41]?inventories.Stack = @splat(null);
                stacks[3] = .{ .item = if (attempt == 2) wrong_item else item, .count = 1 };
                var drag: menu_click.Drag = .{};
                const menu: menu_click.Menu = .{
                    .inventory = fixture.menu,
                    .player = if (attempt == 1) 2 else 1,
                    .location = .{ .block = .{ .world = key.world, .position = .{ .x = if (attempt == 3) 3 else 2, .y = 1, .z = 0 } } },
                    .kind = .furnace,
                    .container_slots = 3,
                    .stacks = &stacks,
                    .drag = &drag,
                    .creative = false,
                };
                _ = try menu.apply(.{ .window_id = 1, .state_id = 0, .slot = 3, .button = 0, .mode = 1 });
                try std.testing.expectEqual(attempt == 0, stacks[1] != null);
                var remaining: u16 = 0;
                for (stacks[3..39]) |stack| if (stack) |value| {
                    try std.testing.expectEqual(if (attempt == 2) wrong_item else item, value.item);
                    remaining += value.count;
                };
                try std.testing.expectEqual(@as(u16, @intFromBool(attempt != 0)), remaining);
            }
            try containers.deps.chunks.setBlock(key.world, key.position, containers.states.furnaces[0][0]);
            try std.testing.expect(try fixture.ownership.set(.{ .owner = player.uuid, .index = 9 }, 0, .{ .item = item, .count = 1 }));
            try std.testing.expect(try fixture.ownership.set(Containers.slot(key.world, key.position, 0), 0, .{ .item = try fixture.items.define("minecraft:dirt"), .count = 2 }));
            try std.testing.expectEqual(BlockActions.Result.applied, try containers.deps.actions.apply(.{ .action = .use, .player = player, .position = key.position, .state = containers.states.furnaces[0][0] }));
            containers.views[0].opened = true;
            try containers.click(player.handle.?, .{ .window_id = containers.views[0].window, .state_id = 0, .slot = 3, .button = 0, .mode = 1 });
            try std.testing.expect((try fixture.ownership.get(.{ .owner = player.uuid, .index = 9 })).stack == null);
            try std.testing.expectEqual(@as(usize, 1), containers.active_count);
            const stamped = (try fixture.ownership.get(Containers.slot(key.world, key.position, 1))).stack.?;
            try std.testing.expect(!std.mem.eql(u8, &stamped.item, &item));
            try containers.checkpoint(containers.deps.storage);
            try fixture.ownership.checkpoint(fixture.ownership.deps.storage);
            try containers.deps.chunks.checkpoint(try store.openSpace("chunks"));
            try store.waitDurable(try store.commit(1));
        } else {
            player.uuid = 2;
            for (0..2) |_| try furnace.tick(containers);
            try std.testing.expectEqual(@as(u32, 2), containers.furnaceState(key.world, key.position).burn_total);
            const output = (try fixture.ownership.get(Containers.slot(key.world, key.position, 2))).stack.?;
            try std.testing.expectEqual(kind("minecraft:iron_ingot"), try fixture.items.kind(output));
            const transformed = (try fixture.ownership.get(Containers.slot(key.world, key.position, 1))).stack.?;
            const pinned = try fixture.items.acquire(transformed);
            defer pinned.release();
            try std.testing.expectEqual(kind("minecraft:diamond"), pinned.view.kind);
            const data = try custom_data.Compound.init(pinned.view.value(.custom_data).?);
            try std.testing.expectEqual(@as(?i32, 12), try data.getInt("charge"));
            var bytes: [64]u8 = undefined;
            var scratch = std.heap.FixedBufferAllocator.init(&bytes);
            try std.testing.expectEqualStrings("00000000000000000000000000000001", (try data.getString("actor", scratch.allocator())).?);
        }
    }
}
