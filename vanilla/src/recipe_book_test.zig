const item_properties = @import("item_properties.zig");
const item_packets = @import("item_packets.zig");
const provider = @import("definition_provider.zig");
const vanilla_content = @import("vanilla_content.zig");
const worlds = @import("worlds");
const VanillaWorlds = @import("default_worlds.zig").VanillaWorlds;
const inventories = @import("inventories");
const recipes = @import("recipes.zig");
const custom_data = @import("custom_data.zig");
const item_data = @import("item_data.zig");
const game_data = @import("game_data");
const std = @import("std");
const storage = @import("storage");
const metrics = @import("metrics");
const sessions = @import("sessions");
const RecipeBook = @import("recipe_book.zig").RecipeBook;
const protocols = @import("protocols");
const chunks = @import("chunks");
const packets = @import("minecraft_packets");
const RecipeBookRegistry = @import("recipe_book_registry.zig").RecipeBookRegistry;
const ItemContent = @import("item_content.zig").ItemContent;
const InventoryFixture = @import("inventory_test_fixture.zig").InventoryFixture;
const book_packets = @import("recipe_book_packets.zig");
const placement = @import("recipe_placement.zig");
const wire = @import("wire_1_21_5");
const item_components = @import("item_components.zig");
const native_nbt = @import("native_nbt.zig");

const ComputedName = struct {
    const Text = wire.SlotComponent.cases.data.custom_name.Payload;
    bytes: []const u8,

    fn present(_: *ComputedName, _: item_data.View, _: u128, _: ?item_data.Component) item_components.Presentation {
        return .added;
    }
    fn write(packet: Text.Writer, self: *ComputedName, _: item_components.WriteContext) !Text.Writer.Done {
        return packet.value(self.bytes);
    }
    fn read(packet: Text.Reader, self: *ComputedName, context: item_components.ReadContext) !Text.Reader.Done {
        const value, const done = try packet.value();
        if (!std.mem.eql(u8, value, self.bytes)) return error.InvalidComponent;
        context.retain.* = false;
        return done;
    }
};

test {
    _ = placement;
}

test "recipe book packets encode loaded recipes for every selected protocol" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/book", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var catalog = try protocols.Default.init(allocator);
    defer catalog.deinit(allocator);
    const fixture = try InventoryFixture.init(allocator, &store, &registry, &catalog.values);
    defer fixture.service.deinit();
    const sender = try packets.Packets.init(allocator, .{ .sessions = fixture.service });
    _ = try ItemContent.init(allocator, .{ .items = fixture.items, .packets = sender });
    const content = fixture.definitions.book;
    const displays = try book_packets.prepare(allocator, &content.table, fixture.items);
    const context: book_packets.Context = .{ .table = &content.table, .displays = displays, .items = fixture.items, .recipient = 1 };
    var maximum: usize = 0;
    for (displays) |display| maximum = @max(maximum, display.base_bytes);
    _ = try RecipeBook.init(allocator, .{ .packet_bytes = maximum + 16 }, .{
        .definitions = fixture.definitions.book,
        .players = fixture.players,
        .inventory = fixture.menus,
        .inventories = fixture.ownership,
        .items = fixture.items,
        .chunks = try chunks.Chunks.init(allocator, std.testing.io, .{ .cache_sections = 1, .demand_sections = 0, .cache_tiles = 1 }, .{
            .metrics = &registry,
            .storage = try store.openSpace("recipe_chunks"),
            .record_workspaces = fixture.players.deps.record_workspaces,
        }),
        .input = fixture.input,
        .packets = sender,
        .storage = try store.openSpace("recipe_book"),
        .record_workspaces = fixture.players.deps.record_workspaces,
    });
    const label = try allocator.alloc(u8, 512);
    @memset(label, 'x');
    var computed: ComputedName = .{ .bytes = try native_nbt.encode(allocator, @as([]const u8, label)) };
    try fixture.items.components.on(.custom_name, &computed, .{
        .read = ComputedName.read,
        .write = ComputedName.write,
        .present = ComputedName.present,
        .maximum_extra_bytes = 1024,
    });
    try std.testing.expectError(error.RecipeDisplayTooLarge, content.registry.validate());
    maximum = 0;
    for (displays) |display| maximum = @max(maximum, try display.maximumBytes(fixture.items.components.extra_bytes));
    const buffer = try allocator.alloc(u8, maximum + 16);
    inline for (protocols.implementations) |Version| {
        for (content.table.book, 0..) |recipe, index| {
            if (!book_packets.available(displays[index], recipe, Version.Registry.canonical_item_to_wire, fixture.items, Version.protocol_number)) continue;
            const id: u32 = @intCast(index);
            const bound = (try displays[index].maximumBytes(fixture.items.components.extra_bytes)) + 16;
            const encoded = try sender.writePacket(book_packets.add, Version.protocol_number, buffer[0..bound], .{ context, &[_]u32{id}, &[_]u8{0}, false });
            const header = try Version.Protocol.play.toClient.readHeader(encoded);
            try (try (try Version.Protocol.play.toClient.readBody(.recipe_book_add, header)).scan()).finish();
        }
        _ = try sender.writePacket(book_packets.settings, Version.protocol_number, buffer, .{@as(u8, 0xa5)});
        _ = try sender.writePacket(book_packets.remove, Version.protocol_number, buffer, .{&[_]u32{0}});
        _ = try sender.writePacket(book_packets.properties, Version.protocol_number, buffer, .{&content.table});
        const ghost_bound = (try displays[0].maximumBytes(fixture.items.components.extra_bytes)) + 16;
        _ = try sender.writePacket(book_packets.ghost, Version.protocol_number, buffer[0..ghost_bound], .{ context, @as(i32, 0), @as(usize, 0) });
    }
}

test "recipe unlocks settings and revocation persist by name across recipe insertion" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/book-state", .{directory.sub_path});
    for (0..2) |pass| {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
        defer store.deinit();
        var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
        defer registry.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
        const fixture = try InventoryFixture.init(allocator, &store, &registry, &selected);
        defer fixture.service.deinit();
        fixture.players.records[1] = fixture.players.records[0];
        fixture.players.records[1].uuid = 2;
        fixture.players.records[1].handle = .{ .index = 1, .generation = 1 };
        const content = fixture.definitions.book;
        const sender = try packets.Packets.init(allocator, .{ .sessions = fixture.service });
        const book = try RecipeBook.init(allocator, .{}, .{
            .definitions = content,
            .players = fixture.players,
            .inventory = fixture.menus,
            .inventories = fixture.ownership,
            .items = fixture.items,
            .chunks = try chunks.Chunks.init(allocator, std.testing.io, .{ .cache_sections = 1, .demand_sections = 0, .cache_tiles = 1 }, .{
                .metrics = &registry,
                .storage = try store.openSpace("recipe_chunks"),
                .record_workspaces = fixture.players.deps.record_workspaces,
            }),
            .input = fixture.input,
            .packets = sender,
            .storage = try store.openSpace("recipe_book"),
            .record_workspaces = fixture.players.deps.record_workspaces,
        });
        if (pass == 1) {
            const previous_count = book.identities.len;
            _ = try provider.register(fixture.definitions, allocator, .{ .recipes = &.{.{ .name = "aaa:first", .definition = .{ .shapeless = .{ .ingredients = &.{.{ .item = "minecraft:stone" }}, .result = .{ .item = "minecraft:diamond" } } } }} }, null);
            try std.testing.expectEqual(previous_count + 1, book.identities.len);
            try std.testing.expectEqual(fixture.players.records.len * book.identities.len, book.flags.len);
        }
        const planks = book.recipeId("minecraft:oak_planks").?;
        const pickaxe = book.recipeId("minecraft:iron_pickaxe").?;
        if (pass == 0) {
            try book.grantMany(0, &.{ planks, pickaxe });
            try book.revokeMany(0, &.{pickaxe});
            try book.grantMany(1, &.{pickaxe});
            try book.configure(0, .crafting, .{ .open = true, .craftable = true });
            try book.configure(0, .furnace, .{ .open = false, .craftable = true });
            try book.checkpoint(book.deps.storage);
            try store.waitDurable(try store.commit(1));
        } else {
            try std.testing.expect(try book.knows(0, planks));
            try std.testing.expect(!try book.knows(0, pickaxe));
            try std.testing.expect(!try book.knows(1, planks));
            try std.testing.expect(try book.knows(1, pickaxe));
            try std.testing.expectEqual(RecipeBook.Setting{ .open = true, .craftable = true }, try book.setting(0, .crafting));
            try std.testing.expectEqual(RecipeBook.Setting{ .open = false, .craftable = true }, try book.setting(0, .furnace));
            try std.testing.expectEqual(RecipeBook.Setting{}, try book.setting(1, .crafting));
            try std.testing.expect(book.recipeId("aaa:first").? < planks);
        }
    }
}

test "recipe placement conserves stacks across grid sizes capacity and NBT restrictions" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/placement", .{directory.sub_path});
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
    const table = &fixture.definitions.book.table;
    const planks = for (table.book) |*entry| {
        if (std.mem.eql(u8, entry.name, "minecraft:oak_planks")) break entry;
    } else unreachable;
    const crafting_table = for (table.book) |*entry| {
        if (std.mem.eql(u8, entry.name, "minecraft:crafting_table")) break entry;
    } else unreachable;
    const iron = for (table.book) |*entry| {
        if (std.mem.eql(u8, entry.name, "minecraft:iron_ingot_from_smelting_iron_ore")) break entry;
    } else unreachable;
    const log_item = try fixture.items.define("minecraft:oak_log");
    const plank_item = try fixture.items.define("minecraft:oak_planks");
    const bread = try fixture.items.define("minecraft:bread");
    const iron_ore = try fixture.items.define("minecraft:iron_ore");
    const coal = try fixture.items.define("minecraft:coal");
    const paper = try fixture.items.define("minecraft:paper");
    var charged: custom_data.Editor = .{ .allocator = allocator };
    try charged.setInt("charge", 7);
    const charged_bytes = try charged.finish();
    const component = [_]recipes.Component{.{ .key = item_data.key(.custom_data), .value = charged_bytes }};
    const charged_item = try item_data.define(fixture.ownership, @intCast(game_data.registry.itemId("minecraft:paper").?), &component);
    try charged.setInt("charge", 6);
    const wrong_item = try item_data.define(fixture.ownership, @intCast(game_data.registry.itemId("minecraft:paper").?), &.{.{ .key = item_data.key(.custom_data), .value = try charged.finish() }});
    bounded.fail_index = bounded.alloc_index;
    var stacks: [48]?inventories.Stack = @splat(null);
    stacks[36] = .{ .item = log_item, .count = 5 };
    try std.testing.expectEqual(placement.Result.placed, try placement.place(fixture.items, table, planks, stacks[0..47], &.{ 1, 2, 3, 4 }, 2, 9, true));
    try std.testing.expectEqual(@as(u16, 5), stacks[1].?.count);
    try std.testing.expect(stacks[36] == null);
    const full_grid = stacks;
    try std.testing.expectEqual(placement.Result.blocked, try placement.place(fixture.items, table, planks, stacks[0..47], &.{ 1, 2, 3, 4 }, 2, 9, false));
    try std.testing.expectEqualDeep(full_grid, stacks);
    @memset(&stacks, null);
    stacks[10] = .{ .item = plank_item, .count = 12 };
    try std.testing.expectEqual(placement.Result.placed, try placement.place(fixture.items, table, crafting_table, &stacks, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, 3, 10, true));
    for ([_]usize{ 1, 2, 4, 5 }) |index| try std.testing.expectEqual(@as(u16, 3), stacks[index].?.count);
    for ([_]usize{ 3, 6, 7, 8, 9, 10 }) |index| try std.testing.expect(stacks[index] == null);
    @memset(&stacks, null);
    stacks[9] = .{ .item = bread, .count = 2 };
    stacks[1] = .{ .item = log_item, .count = 3 };
    try std.testing.expectEqual(placement.Result.missing, try placement.place(fixture.items, table, crafting_table, stacks[0..47], &.{ 1, 2, 3, 4 }, 2, 9, false));
    for (stacks[1..5]) |value| try std.testing.expect(value == null);
    var returned: u16 = 0;
    for (stacks[9..45]) |value| if (value) |stack| {
        if (std.mem.eql(u8, &stack.item, &log_item)) returned += stack.count;
    };
    try std.testing.expectEqual(@as(u16, 3), returned);
    @memset(&stacks, null);
    for (stacks[9..45]) |*value| value.* = .{ .item = bread, .count = 64 };
    stacks[1] = .{ .item = log_item, .count = 1 };
    const blocked = stacks;
    try std.testing.expectEqual(placement.Result.blocked, try placement.place(fixture.items, table, planks, stacks[0..47], &.{ 1, 2, 3, 4 }, 2, 9, false));
    try std.testing.expectEqualDeep(blocked, stacks);
    @memset(&stacks, null);
    stacks[3] = .{ .item = iron_ore, .count = 12 };
    stacks[1] = .{ .item = coal, .count = 8 };
    stacks[2] = .{ .item = bread, .count = 1 };
    try std.testing.expectEqual(placement.Result.placed, try placement.place(fixture.items, table, iron, stacks[0..41], &.{0}, 1, 3, true));
    try std.testing.expectEqual(@as(u16, 12), stacks[0].?.count);
    try std.testing.expectEqual(@as(u16, 8), stacks[1].?.count);
    try std.testing.expectEqual(@as(u16, 1), stacks[2].?.count);
    @memset(&stacks, null);
    var custom_table = table.*;
    custom_table.alternatives = &.{@intCast(game_data.registry.itemId("minecraft:paper").?)};
    const custom: recipes.BookEntry = .{
        .name = "test:charged",
        .ingredients = &.{.{ .ingredient = .{ .required = true, .offset = 0, .count = 1 }, .components = &component }},
        .result = .{ .kind = @intCast(game_data.registry.itemId("minecraft:diamond").?), .count = 1 },
    };
    stacks[9] = .{ .item = paper, .count = 2 };
    stacks[10] = .{ .item = wrong_item, .count = 2 };
    stacks[11] = .{ .item = charged_item, .count = 3 };
    try std.testing.expectEqual(placement.Result.placed, try placement.place(fixture.items, &custom_table, &custom, stacks[0..47], &.{ 1, 2, 3, 4 }, 2, 9, true));
    try std.testing.expectEqual(charged_item, stacks[1].?.item);
    try std.testing.expectEqual(@as(u16, 3), stacks[1].?.count);
    try std.testing.expectEqual(@as(u16, 2), stacks[9].?.count);
    try std.testing.expectEqual(@as(u16, 2), stacks[10].?.count);
    try std.testing.expect(stacks[11] == null);
}

test "inventory discovery unlocks recipes without retaining definition leases or allocations" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/discovery", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = bounded.allocator();
    var catalog = try protocols.Default.init(allocator);
    defer catalog.deinit(allocator);
    const fixture = try InventoryFixture.init(allocator, &store, &registry, &catalog.values);
    defer fixture.service.deinit();
    fixture.players.records[0].protocol = catalog.values[0].number;
    const sender = try packets.Packets.init(allocator, .{ .sessions = fixture.service });
    const content = try RecipeBookRegistry.init(allocator, .{ .prepared = fixture.definitions.book }, fixture.definitions.book.deps);
    content.unlocks.blocks = &.{};
    const book = try RecipeBook.init(allocator, .{}, .{
        .definitions = content,
        .players = fixture.players,
        .inventory = fixture.menus,
        .inventories = fixture.ownership,
        .items = fixture.items,
        .chunks = try chunks.Chunks.init(allocator, std.testing.io, .{ .cache_sections = 1, .demand_sections = 0, .cache_tiles = 1 }, .{
            .metrics = &registry,
            .storage = try store.openSpace("recipe_chunks"),
            .record_workspaces = fixture.players.deps.record_workspaces,
        }),
        .input = fixture.input,
        .packets = sender,
        .storage = try store.openSpace("recipe_book"),
        .record_workspaces = fixture.players.deps.record_workspaces,
    });
    const log_item = try fixture.items.define("minecraft:oak_log");
    try std.testing.expect(try fixture.ownership.set(.{ .owner = 1, .index = 36 }, 0, .{ .item = log_item, .count = 2 }));
    bounded.fail_index = bounded.alloc_index;
    try book.tick();
    const planks = book.recipeId("minecraft:oak_planks").?;
    try std.testing.expect(try book.knows(0, planks));
    for (fixture.ownership.items.entries) |entry| try std.testing.expectEqual(@as(u32, 0), entry.pins);
    try book.revokeMany(0, &.{planks});
    try std.testing.expect(!try book.knows(0, planks));
    const slot: inventories.Slot = .{ .owner = 1, .index = 36 };
    const previous = try fixture.ownership.get(slot);
    try std.testing.expect(try fixture.ownership.set(slot, previous.revision, .{ .item = log_item, .count = 3 }));
    try book.tick();
    try std.testing.expect(!try book.knows(0, planks));
    try fixture.ownership.checkpoint(fixture.ownership.deps.storage);
    try book.checkpoint(book.deps.storage);
    try store.waitDurable(try store.commit(1));
}

test "late dimension overrides update fresh worlds and validate persisted geometry after initialization" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/late-dimension", .{directory.sub_path});
    for (0..2) |pass| {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const content = (try vanilla_content.prepare(allocator)).dimensions;
        const space = try store.openSpace("worlds");
        const catalog = try worlds.Worlds.init(allocator, .{ .maximum = 3 }, .{ .storage = space });
        const defaults = try VanillaWorlds.init(allocator, .{ .registry_identity = undefined, .worlds = catalog, .dimensions = content });
        if (pass == 1) try std.testing.expectError(error.DimensionIdentityChanged, content.registry.validate());
        try content.addDefinitions(.{ .dimensions = &.{.{ .name = "minecraft:overworld", .definition = .{ .min_y = 0, .height = 256, .logical_height = 256 } }} });
        try content.registry.validate();
        const overworld = catalog.get(defaults.overworld).?;
        try std.testing.expectEqual(@as(i32, 0), overworld.dimension.minimum_section);
        try std.testing.expectEqual(@as(u16, 16), overworld.dimension.section_count);
        if (pass == 0) {
            try catalog.checkpoint(space);
            try store.waitDurable(try store.commit(1));
        }
    }
}

test "native item defaults reach every client while explicit components take precedence" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/item-defaults", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var catalog = try protocols.Default.init(allocator);
    defer catalog.deinit(allocator);
    const fixture = try InventoryFixture.init(allocator, &store, &registry, &catalog.values);
    defer fixture.service.deinit();
    _ = try item_properties.ItemProperties.init(allocator, .{ .items = fixture.items });
    _ = try item_properties.Durability.init(allocator, .{ .items = fixture.items, .inventories = fixture.ownership, .enchantments = fixture.definitions.enchantments });
    try fixture.definitions.items.addDefinitions(.{ .items = &.{
        .{ .name = "minecraft:paper", .stack_size = 8 },
        .{ .name = "minecraft:iron_pickaxe", .durability = 40 },
        .{ .name = "minecraft:diamond_pickaxe", .durability = 0 },
    } });
    const Case = struct {
        name: []const u8,
        components: []const item_data.Component = &.{},
        stack_size: ?i32 = null,
        durability: ?i32 = null,
        removed: bool = false,
    };
    const cases = [_]Case{
        .{ .name = "minecraft:paper", .stack_size = 8 },
        .{ .name = "minecraft:diamond" },
        .{ .name = "minecraft:iron_pickaxe", .durability = 40 },
        .{ .name = "minecraft:diamond_pickaxe", .removed = true },
        .{ .name = "minecraft:paper", .components = &.{.{ .key = item_data.key(.max_stack_size), .value = &.{16} }}, .stack_size = 16 },
        .{ .name = "minecraft:iron_pickaxe", .components = &.{.{ .key = item_data.key(.max_damage), .value = &.{72} }}, .durability = 72 },
        .{ .name = "minecraft:diamond_pickaxe", .components = &.{.{ .key = item_data.key(.max_damage), .value = &.{99} }}, .durability = 99 },
        .{ .name = "minecraft:iron_pickaxe", .components = &.{.{ .key = item_data.key(.max_damage), .value = null }}, .removed = true },
    };
    for (cases) |case| {
        const kind: u32 = @intCast(game_data.registry.itemId(case.name).?);
        const item = try item_data.define(fixture.ownership, kind, case.components);
        const pinned = try fixture.ownership.acquireItem(item);
        defer pinned.release();
        const view = try item_data.View.parse(pinned.read().?);
        const expected_limit = case.stack_size orelse game_data.registry.items[kind].stack_size;
        try std.testing.expectEqual(@as(u16, @intCast(expected_limit)), try fixture.items.maximum(view));
        inline for (protocols.Default.versions) |Version| {
            var bytes: [256]u8 = undefined;
            const packet = try Version.Protocol.play.toClient.write(&bytes).set_slot();
            const position = try (try (try packet.windowId(0)).stateId(1)).slot(0);
            var output = try position.item();
            const destination = try output.begin();
            const start = destination._cursor.rest;
            const done = try item_packets.writeSlot(destination, .{
                .registry = .{ .entities = &.{}, .items = Version.Registry.canonical_item_to_wire, .blocks = &.{}, .block_states = &.{}, .block_state_bits = 0, .sounds = &.{}, .effects = &.{}, .attributes = &.{} },
                .items = fixture.items,
                .stack = .{ .item = item, .count = 1 },
                .recipient = 1,
                .view = view,
            });
            const length = start.len - done._cursor.rest.len;
            _ = (try output.advance(done)).finish();
            var reader = std.Io.Reader.fixed(start[0..length]);
            try std.testing.expectEqual(@as(u32, 1), try reader.takeLeb128(u32));
            try std.testing.expectEqual(@as(u32, @intCast(Version.Registry.canonical_item_to_wire[kind])), try reader.takeLeb128(u32));
            const added = try reader.takeLeb128(u32);
            const removed = try reader.takeLeb128(u32);
            try std.testing.expectEqual(@as(u32, @intFromBool(case.stack_size != null)) + @intFromBool(case.durability != null), added);
            try std.testing.expectEqual(@as(u32, @intFromBool(case.removed)), removed);
            for (0..added) |_| {
                const key = try fixture.items.components.dispatch.keyForTag(Version.protocol_number, try reader.takeLeb128(u32));
                const payload = reader.buffered();
                const value = try reader.takeLeb128(u32);
                try std.testing.expectEqual(case.components.len != 0, try fixture.items.components.retain(.{
                    .kind = kind,
                    .recipient = 1,
                    .component = .{ .key = key, .value = payload[0 .. payload.len - reader.bufferedLen()] },
                }));
                if (key == item_data.key(.max_stack_size)) {
                    try std.testing.expectEqual(@as(u32, @intCast(case.stack_size.?)), value);
                } else {
                    try std.testing.expectEqual(item_data.key(.max_damage), key);
                    try std.testing.expectEqual(@as(u32, @intCast(case.durability.?)), value);
                }
            }
            if (case.removed) {
                const key = try fixture.items.components.dispatch.keyForTag(Version.protocol_number, try reader.takeLeb128(u32));
                try std.testing.expectEqual(item_data.key(.max_damage), key);
                try std.testing.expectEqual(case.components.len != 0, try fixture.items.components.retain(.{
                    .kind = kind,
                    .recipient = 1,
                    .component = .{ .key = key, .value = null },
                }));
            }
            try std.testing.expectEqual(@as(usize, 0), reader.bufferedLen());
        }
    }
}

test "block discovery batches samples and invalidates only occupied edits without allocation" {
    const Source = struct {
        generated: usize = 0,
        fn read(self: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests) |*request| {
                self.generated += 1;
                request.result = chunks.uniform(game_data.registry.block_air_default_state, request.output);
            }
        }
    };
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/block-discovery", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .capacity = 1024 });
    defer registry.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = bounded.allocator();
    var catalog = try protocols.Default.init(allocator);
    defer catalog.deinit(allocator);
    const fixture = try InventoryFixture.init(allocator, &store, &registry, &catalog.values);
    defer fixture.service.deinit();
    fixture.players.records[0].protocol = catalog.values[0].number;
    fixture.players.records[0].position = .{ .x = 0.25, .y = 0, .z = 0.25 };
    fixture.players.records[1] = fixture.players.records[0];
    fixture.players.records[1].uuid = 2;
    fixture.players.records[1].handle = .{ .index = 1, .generation = 1 };
    fixture.players.rebuildIndexes();
    const terrain = try chunks.Chunks.init(allocator, std.testing.io, .{ .cache_sections = 1, .demand_sections = 0, .cache_tiles = 1 }, .{
        .metrics = &registry,
        .storage = try store.openSpace("recipe_chunks"),
        .record_workspaces = fixture.players.deps.record_workspaces,
    });
    var source: Source = .{};
    terrain.setSource(chunks.Source.init(&source, Source.read));
    const content = try RecipeBookRegistry.init(allocator, .{}, fixture.definitions.book.deps);
    try content.addDefinitions(&.{
        .{ .name = "test:stone", .criteria = &.{.{ .name = "entered", .trigger = .{ .block = game_data.registry.block_state_to_block[game_data.registry.block_stone_default_state] } }}, .requirements = &.{&.{0}}, .recipes = &.{"minecraft:oak_planks"} },
        .{ .name = "test:honey", .criteria = &.{.{ .name = "entered", .trigger = .{ .block = game_data.registry.block_state_to_block[game_data.registry.block_honey_block_default_state] } }}, .requirements = &.{&.{0}}, .recipes = &.{"minecraft:iron_pickaxe"} },
    });
    const book = try RecipeBook.init(allocator, .{ .packet_bytes = fixture.service.config.page_bytes }, .{
        .definitions = content,
        .players = fixture.players,
        .inventory = fixture.menus,
        .inventories = fixture.ownership,
        .items = fixture.items,
        .chunks = terrain,
        .input = fixture.input,
        .packets = try packets.Packets.init(allocator, .{ .sessions = fixture.service }),
        .storage = try store.openSpace("recipe_book"),
        .record_workspaces = fixture.players.deps.record_workspaces,
    });
    const planks = book.recipeId("minecraft:oak_planks").?;
    const pickaxe = book.recipeId("minecraft:iron_pickaxe").?;
    const initial = terrain.cache.metrics.acquired.value();
    bounded.fail_index = bounded.alloc_index;
    try book.tick();
    try std.testing.expectEqual(initial + 1, terrain.cache.metrics.acquired.value());
    const stable = terrain.cache.metrics.acquired.value();
    for (0..8) |_| try book.tick();
    fixture.players.records[0].position.x = 0.75;
    try book.tick();
    try std.testing.expectEqual(stable, terrain.cache.metrics.acquired.value());
    const generated = source.generated;
    fixture.players.records[0].position.x = 32.25;
    fixture.players.records[1].position.x = 64.25;
    try book.tick();
    try std.testing.expectEqual(generated + 2, source.generated);
    const separated = terrain.cache.metrics.acquired.value();
    try book.tick();
    try std.testing.expectEqual(separated, terrain.cache.metrics.acquired.value());
    fixture.players.records[0].position.x = 0.25;
    fixture.players.records[1].position.x = 0.25;
    try book.tick();
    const reunited = terrain.cache.metrics.acquired.value();
    try book.tick();
    try std.testing.expectEqual(reunited, terrain.cache.metrics.acquired.value());
    try terrain.setBlock(fixture.players.records[0].world, .{ .x = 1, .y = 0, .z = 0 }, game_data.registry.block_stone_default_state);
    const unrelated = terrain.cache.metrics.acquired.value();
    try book.tick();
    try std.testing.expectEqual(unrelated, terrain.cache.metrics.acquired.value());
    try std.testing.expect(!try book.knows(0, planks));
    fixture.players.records[0].position.x = 1.25;
    try book.tick();
    try std.testing.expectEqual(unrelated + 1, terrain.cache.metrics.acquired.value());
    try std.testing.expect(try book.knows(0, planks));
    try std.testing.expect(!try book.knows(1, planks));
    fixture.players.records[1].position.x = 128.25;
    fixture.players.rebuildIndexes();
    try terrain.setBlock(fixture.players.records[1].world, .{ .x = 0, .y = 0, .z = 0 }, game_data.registry.block_stone_default_state);
    fixture.players.records[1].position.x = 0.25;
    fixture.players.rebuildIndexes();
    const occupied = terrain.cache.metrics.acquired.value();
    try book.tick();
    try std.testing.expectEqual(occupied + 1, terrain.cache.metrics.acquired.value());
    try std.testing.expect(try book.knows(1, planks));
    try terrain.setBlock(111, .{ .x = 1, .y = 0, .z = 0 }, game_data.registry.block_honey_block_default_state);
    const other_world = terrain.cache.metrics.acquired.value();
    try book.tick();
    try std.testing.expectEqual(other_world, terrain.cache.metrics.acquired.value());
    try std.testing.expect(!try book.knows(0, pickaxe));
    fixture.players.records[0].world = 111;
    try book.tick();
    try std.testing.expectEqual(other_world + 1, terrain.cache.metrics.acquired.value());
    try std.testing.expect(try book.knows(0, pickaxe));
    fixture.players.records[1].position.x = -0.5;
    try book.tick();
    try std.testing.expect(!try book.knows(1, pickaxe));
    fixture.players.records[1].handle = null;
    fixture.players.rebuildIndexes();
    try book.tick();
    try std.testing.expectEqual(@as(usize, 0), book.block_watches.count());
    fixture.players.records[1].handle = .{ .index = 1, .generation = 2 };
    fixture.players.rebuildIndexes();
    const reconnect = terrain.cache.metrics.acquired.value();
    try book.tick();
    try std.testing.expectEqual(reconnect + 1, terrain.cache.metrics.acquired.value());
    try terrain.setBlock(fixture.players.records[1].world, .{ .x = -1, .y = 0, .z = 0 }, game_data.registry.block_honey_block_default_state);
    const negative = terrain.cache.metrics.acquired.value();
    try book.tick();
    try std.testing.expectEqual(negative + 1, terrain.cache.metrics.acquired.value());
    try std.testing.expect(try book.knows(1, pickaxe));
    try std.testing.expectEqual(@as(usize, 0), book.block_watches.count());
    try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
    try book.tick();
    try std.testing.expectEqual(negative + 1, terrain.cache.metrics.acquired.value());
    fixture.players.records[1].uuid = 3;
    fixture.players.rebuildIndexes();
    try book.tick();
    try std.testing.expect(!try book.knows(1, planks));
    try std.testing.expect(try book.knows(1, pickaxe));
    try std.testing.expectEqual(@as(usize, 1), book.block_watches.count());
    fixture.players.records[1].uuid = 2;
    fixture.players.rebuildIndexes();
    const restored = terrain.cache.metrics.acquired.value();
    try book.tick();
    try std.testing.expect(try book.knows(1, planks));
    try std.testing.expect(try book.knows(1, pickaxe));
    try std.testing.expectEqual(restored, terrain.cache.metrics.acquired.value());
    try std.testing.expectEqual(@as(usize, 0), book.block_watches.count());
    for (fixture.players.records) |*player| player.handle = null;
    fixture.players.rebuildIndexes();
    try book.tick();
    try std.testing.expectEqual(@as(usize, 0), book.block_watches.count());
    try std.testing.expectEqual(bounded.fail_index, bounded.alloc_index);
}
