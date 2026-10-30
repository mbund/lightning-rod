const provider = @import("definition_provider.zig");
const vanilla_content = @import("vanilla_content.zig");
const std = @import("std");
const Datapacks = @import("datapacks.zig").Datapacks;
const crafting = @import("crafting.zig");
const recipes = @import("recipes.zig");
const loot = @import("loot.zig");
const protocols = @import("protocols");
const game_data = @import("game_data");

const Reward = struct {
    pub const id = "test:reward";
    pub const kind: loot.Kind = .function;
    pub const Parameters = struct { count: u16 };
    pub fn apply(_: *const Reward, parameters: *const Parameters, context: *const loot.Context, stack: *loot.Stack) !void {
        if (context.player != 7) return error.LootContextMissing;
        stack.count = parameters.count;
    }
};

const CustomRecipe = struct {
    pub const id = "test:custom";
    pub const Parameters = struct { label: []const u8 };
    pub fn prepare(_: *CustomRecipe, parameters: *const Parameters, _: *const crafting.Context) !?crafting.Implementation(CustomRecipe).Prepared {
        if (!std.mem.eql(u8, parameters.label, "owned")) return error.InvalidParameters;
        return null;
    }
};

test "optional datapack plugin registers files through native APIs and preserves ownership" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const io = std.testing.io;
    try directory.dir.writeFile(io, .{ .sub_path = "pack.mcmeta", .data = "{\"pack\":{\"pack_format\":81,\"description\":\"test\"}}" });
    try directory.dir.createDirPath(io, "data/test/recipe");
    try directory.dir.createDirPath(io, "data/test/tags/item");
    try directory.dir.createDirPath(io, "data/test/loot_table");
    try directory.dir.createDirPath(io, "data/test/dimension_type");
    try directory.dir.writeFile(io, .{ .sub_path = "data/test/recipe/custom.json", .data = "{\"type\":\"test:custom\",\"label\":\"owned\"}" });
    try directory.dir.writeFile(io, .{ .sub_path = "data/test/tags/item/ingredients.json", .data = "{\"values\":[\"minecraft:paper\",{\"id\":\"test:absent\",\"required\":false}]}" });
    try directory.dir.writeFile(io, .{ .sub_path = "data/test/loot_table/reward.json", .data = "{\"pools\":[{\"rolls\":1,\"entries\":[{\"type\":\"minecraft:item\",\"name\":\"minecraft:diamond\"}]}],\"functions\":[{\"function\":\"test:reward\",\"count\":128}]}" });
    try directory.dir.writeFile(io, .{ .sub_path = "data/test/dimension_type/sky.json", .data = "{\"min_y\":0,\"height\":256,\"logical_height\":256}" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{directory.sub_path});
    const content = try vanilla_content.prepare(allocator);
    const packs = try Datapacks.init(allocator, io, .{}, content);
    const reward: Reward = .{};
    var recipe: CustomRecipe = .{};
    try packs.add(.{ .sources = &.{.{ .directory = path }}, .recipe_types = &.{Datapacks.Recipe(CustomRecipe).register(&recipe)}, .loot_types = &.{Datapacks.Loot(Reward).register(&reward)} });
    const paper: u32 = @intCast(game_data.registry.itemId("minecraft:paper").?);
    try std.testing.expect(content.items.tags.contains(content.items.tags.find("test:ingredients").?, paper));
    try std.testing.expectEqual(@as(u16, 16), (try content.dimensions.dimension("test:sky")).section_count);
    _ = try provider.register(content, allocator, .{ .tags = &.{.{ .registry = "minecraft:item", .name = "test:ingredients", .replace = true, .values = &.{.{ .id = "minecraft:diamond" }} }} }, null);
    // Re-decoding the same files must not move their priority after native registrations.
    try packs.add(.{});
    try std.testing.expect(!content.items.tags.contains(content.items.tags.find("test:ingredients").?, paper));
    var random: std.Random.DefaultPrng = .init(7);
    var bytes: [8192]u8 = undefined;
    var scratch: std.heap.FixedBufferAllocator = .init(&bytes);
    var drops: [2]loot.Drop = undefined;
    const output = try content.loot.tables.get("test:reward").?.evaluate(&.{ .items = content.items, .player = 7, .random = random.random(), .scratch = &scratch }, &drops);
    try std.testing.expectEqual(@as(usize, 2), output.len);
    try std.testing.expectEqual(@as(u16, 64), output[1].count);
    var selected = try protocols.Default.init(allocator);
    try provider.configureProtocols(content, protocols.Default, allocator, &selected);
    for (&selected.values) |*version| _ = try version.registryId("minecraft:dimension_type", "test:sky");
    try directory.dir.writeFile(io, .{ .sub_path = "data/test/tags/item/ingredients.json", .data = "{\"values\":[{\"id\":17}]}" });
    const fresh = try Datapacks.init(allocator, io, .{}, content);
    const before = content.loot.tables.get("test:reward").?;
    const invalid = fresh.add(.{ .sources = &.{.{ .directory = path }} });
    try std.testing.expectError(error.InvalidDefinition, invalid);
    try std.testing.expectEqual(before, content.loot.tables.get("test:reward").?);
}

test "native gameplay registrations remain available when the datapack plugin is removed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const content = try vanilla_content.prepare(allocator);
    const table: loot.TableDefinition = .{ .pools = &.{.{ .entries = &.{.{ .kind = .{ .item = @intCast(game_data.registry.itemId("minecraft:diamond").?) } }} }} };
    _ = try provider.register(content, allocator, .{
        .tags = &.{.{ .registry = "minecraft:item", .name = "test:currency", .values = &.{.{ .id = "minecraft:emerald" }} }},
        .recipes = &.{.{ .name = "test:reward", .definition = .{ .shapeless = .{ .ingredients = &.{.{ .tag = "test:currency" }}, .result = .{ .item = "minecraft:diamond" } } } }},
        .dimension_types = &.{.{ .name = "test:sky", .definition = .{ .height = 256, .logical_height = 256 } }},
        .loot_tables = &.{.{ .name = "test:reward", .table = table }},
    }, null);
    try std.testing.expect(content.items.tags.find("test:currency") != null);
    try std.testing.expect(content.loot.tables.get("test:reward") != null);
    try std.testing.expectEqual(@as(u16, 16), (try content.dimensions.dimension("test:sky")).section_count);
    var selected = try protocols.Default.init(allocator);
    try provider.configureProtocols(content, protocols.Default, allocator, &selected);
}

test "empty datapack collections do not rebuild native content" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{directory.sub_path});
    const content = try vanilla_content.prepare(allocator);
    const original = content.book.table.book.ptr;
    const packs = try Datapacks.init(allocator, std.testing.io, .{ .sources = &.{.{ .collection = path }} }, content);
    try std.testing.expectEqual(original, content.book.table.book.ptr);
    try std.testing.expect(packs.source == null);
}

test "mixed pack formats share native compilation and preserve layer formats after registration" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_]u32{ 48, 71, 81 }) |format| {
        const root = try std.fmt.allocPrint(allocator, "{d}", .{format});
        try directory.dir.createDirPath(io, try std.fmt.allocPrint(allocator, "{s}/data/test/recipe", .{root}));
        try directory.dir.createDirPath(io, try std.fmt.allocPrint(allocator, "{s}/data/test/tags/item", .{root}));
        try directory.dir.createDirPath(io, try std.fmt.allocPrint(allocator, "{s}/data/test/loot_table", .{root}));
        try directory.dir.createDirPath(io, try std.fmt.allocPrint(allocator, "{s}/data/test/dimension_type", .{root}));
        try directory.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/pack.mcmeta", .{root}), .data = try std.fmt.allocPrint(allocator, "{{\"pack\":{{\"pack_format\":{d},\"description\":\"test\"}}}}", .{format}) });
        const ingredient = if (format == 48) "{\"tag\":\"test:ingredients\"}" else "\"#test:ingredients\"";
        const components = if (format == 48)
            \\"minecraft:custom_name":"{\"text\":\"Reward\"}","minecraft:enchantments":{"levels":{"minecraft:mending":1}}
        else
            \\"minecraft:custom_name":{"text":"Reward"},"minecraft:enchantments":{"minecraft:mending":1}
        ;
        const recipe = try std.fmt.allocPrint(allocator, "{{\"type\":\"minecraft:crafting_shapeless\",\"ingredients\":[{s}],\"result\":{{\"id\":\"minecraft:diamond\",\"components\":{{{s}}}}}}}", .{ ingredient, components });
        try directory.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/data/test/recipe/reward_{d}.json", .{ root, format }), .data = recipe });
        try directory.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/data/test/tags/item/ingredients.json", .{root}), .data = "{\"values\":[\"minecraft:paper\"]}" });
        try directory.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/data/test/loot_table/reward_{d}.json", .{ root, format }), .data = "{\"pools\":[{\"rolls\":1,\"entries\":[{\"type\":\"minecraft:item\",\"name\":\"minecraft:diamond\"}]}]}" });
        try directory.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/data/test/dimension_type/sky_{d}.json", .{ root, format }), .data = "{\"min_y\":0,\"height\":256,\"logical_height\":256}" });
    }
    const content = try vanilla_content.prepare(allocator);
    const packs = try Datapacks.init(allocator, io, .{}, content);
    // A later add re-decodes inherited files after releasing the previous loader arena.
    for ([_]u32{ 81, 48, 71 }) |format| {
        const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{d}", .{ directory.sub_path, format });
        try packs.add(.{ .sources = &.{.{ .directory = path }} });
    }
    var first: ?[]const recipes.Component = null;
    var count: usize = 0;
    for (content.book.table.book) |recipe| {
        if (!std.mem.startsWith(u8, recipe.name, "test:reward_")) continue;
        if (first) |components| {
            try std.testing.expectEqual(components.len, recipe.result.components.len);
            for (components, recipe.result.components) |a, b| {
                try std.testing.expectEqual(a.key, b.key);
                try std.testing.expectEqualSlices(u8, a.value.?, b.value.?);
            }
        } else first = recipe.result.components;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    for ([_]u32{ 48, 71, 81 }) |format| {
        try std.testing.expect(content.loot.tables.get(try std.fmt.allocPrint(allocator, "test:reward_{d}", .{format})) != null);
        try std.testing.expectEqual(@as(u16, 16), (try content.dimensions.dimension(try std.fmt.allocPrint(allocator, "test:sky_{d}", .{format}))).section_count);
    }
    const original = content.book.table.book.ptr;
    try directory.dir.createDirPath(io, "unsupported");
    try directory.dir.writeFile(io, .{ .sub_path = "unsupported/pack.mcmeta", .data = "{\"pack\":{\"pack_format\":999,\"description\":\"test\"}}" });
    const unsupported = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/unsupported", .{directory.sub_path});
    try std.testing.expectError(error.IncompatiblePackFormat, packs.add(.{ .sources = &.{.{ .directory = unsupported }} }));
    try std.testing.expectEqual(original, content.book.table.book.ptr);
    var selected = try protocols.Default.init(allocator);
    try provider.configureProtocols(content, protocols.Default, allocator, &selected);
}

test "unsupported advancement behavior rejects the whole registration and preserves installed content" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const io = std.testing.io;
    try directory.dir.createDirPath(io, "data/test/advancement");
    try directory.dir.createDirPath(io, "data/test/tags/item");
    try directory.dir.writeFile(io, .{ .sub_path = "pack.mcmeta", .data = "{\"pack\":{\"pack_format\":81,\"description\":\"test\"}}" });
    try directory.dir.writeFile(io, .{ .sub_path = "data/test/tags/item/paper.json", .data = "{\"values\":[\"minecraft:paper\"]}" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{directory.sub_path});
    const content = try vanilla_content.prepare(allocator);
    const packs = try Datapacks.init(allocator, io, .{}, content);
    const original = content.book.table.book.ptr;
    const Case = struct { bytes: []const u8, failure: anyerror };
    for ([_]Case{
        .{ .bytes =
        \\{"criteria":{"tick":{"trigger":"minecraft:tick"}},"rewards":{"recipes":["minecraft:oak_planks"],"experience":5}}
        , .failure = error.UnsupportedAdvancementReward },
        .{ .bytes =
        \\{"criteria":{"tick":{"trigger":"minecraft:tick"}},"rewards":{"function":"test:reward"}}
        , .failure = error.UnsupportedAdvancementReward },
        .{ .bytes =
        \\{"criteria":{"tick":{"trigger":"minecraft:tick"}}}
        , .failure = error.UnsupportedAdvancement },
        .{ .bytes =
        \\{"display":{},"criteria":{"tick":{"trigger":"minecraft:tick"}},"rewards":{"recipes":["minecraft:oak_planks"]}}
        , .failure = error.UnsupportedAdvancementDisplay },
    }) |case| {
        try directory.dir.writeFile(io, .{ .sub_path = "data/test/advancement/reward.json", .data = case.bytes });
        try std.testing.expectError(case.failure, packs.add(.{ .sources = &.{.{ .directory = path }} }));
        try std.testing.expectEqual(original, content.book.table.book.ptr);
        try std.testing.expect(content.items.tags.find("test:paper") == null);
        try std.testing.expect(packs.state == null and packs.source == null);
    }
    try directory.dir.writeFile(io, .{ .sub_path = "data/test/advancement/reward.json", .data = "{\"criteria\":{\"tick\":{\"trigger\":\"minecraft:tick\"}},\"rewards\":{\"recipes\":[\"minecraft:oak_planks\"]}}" });
    try packs.add(.{ .sources = &.{.{ .directory = path }} });
    try std.testing.expect(content.items.tags.find("test:paper") != null);
}

test "pack filters suppress earlier native definitions and survive subsequent registrations" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const io = std.testing.io;
    try directory.dir.writeFile(io, .{ .sub_path = "pack.mcmeta", .data =
        \\{"pack":{"pack_format":81,"description":"filters"},"filter":{"block":[{"namespace":"minecraft","path":"recipe/oak_planks\\.json"},{"namespace":"minecraft","path":"loot_table/blocks/stone\\.json"},{"namespace":"test","path":"tags/item/hidden\\.json"},{"namespace":"minecraft","path":"dimension_type/overworld_caves\\.json"}]}}
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const content = try vanilla_content.prepare(allocator);
    try content.items.addDefinitions(.{ .tags = &.{.{ .registry = "minecraft:item", .name = "test:hidden", .values = &.{.{ .id = "minecraft:paper" }} }} });
    try std.testing.expect(content.loot.tables.get("minecraft:blocks/stone") != null);
    try std.testing.expect(content.dimensions.get("minecraft:overworld_caves") != null);
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{directory.sub_path});
    const packs = try Datapacks.init(allocator, io, .{ .sources = &.{.{ .directory = path }} }, content);
    for (0..2) |_| {
        for (content.crafting.table.book) |entry| try std.testing.expect(!std.mem.eql(u8, entry.name, "minecraft:oak_planks"));
        try std.testing.expect(content.loot.tables.get("minecraft:blocks/stone") == null);
        try std.testing.expect(content.items.tags.find("test:hidden") == null);
        try std.testing.expect(content.dimensions.get("minecraft:overworld_caves") == null);
        try std.testing.expect(content.dimensions.client.get("minecraft:dimension_type").?.get("minecraft:overworld_caves") == null);
        try packs.add(.{});
    }
    var selected = try protocols.Default.init(allocator);
    try provider.configureProtocols(content, protocols.Default, allocator, &selected);
    for (&selected.values) |*version| try std.testing.expectError(error.UnknownRegistryEntry, version.registryId("minecraft:dimension_type", "minecraft:overworld_caves"));
    try content.crafting.addRecipes(&.{.{ .name = "minecraft:oak_planks", .definition = .{ .shapeless = .{
        .ingredients = &.{.{ .item = "minecraft:paper" }},
        .result = .{ .item = "minecraft:diamond" },
    } } }});
    try packs.add(.{});
    const result = for (content.crafting.table.book) |entry| {
        if (std.mem.eql(u8, entry.name, "minecraft:oak_planks")) break entry.result;
    } else return error.MissingRecipe;
    try std.testing.expectEqual(@as(u32, @intCast(game_data.registry.itemId("minecraft:diamond").?)), result.kind);
}
