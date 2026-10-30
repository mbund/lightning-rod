const registry = @import("registry.zig");
const lightning_rod = @import("lightning_rod");
const std = @import("std");
const types = @import("content_types.zig");
const recipes = @import("recipes.zig");
const tags = @import("content_tags.zig");
const Registries = @import("content_registries.zig").Registries;
const protocols = @import("content_protocols.zig");
const ItemRegistry = @import("item_registry.zig").ItemRegistry;
const Blocks = @import("blocks.zig").Blocks;
const Dimensions = @import("dimensions.zig").Dimensions;
const EnchantmentRegistry = @import("enchantment_registry.zig").EnchantmentRegistry;
const ClientRegistries = @import("client_registries.zig").ClientRegistries;
const Crafting = @import("crafting_registry.zig").Crafting;
const Furnaces = @import("furnaces.zig").Furnaces;
const Loot = @import("loot_registry.zig").Loot;
const MiningRegistry = @import("mining_registry.zig").MiningRegistry;
const PlacementRegistry = @import("placement_registry.zig").PlacementRegistry;
const RecipeBookRegistry = @import("recipe_book_registry.zig").RecipeBookRegistry;

pub const Dependencies = struct {
    items: *ItemRegistry,
    blocks: *Blocks,
    dimensions: *Dimensions,
    enchantments: *EnchantmentRegistry,
    client: *ClientRegistries,
    crafting: *Crafting,
    furnaces: *Furnaces,
    loot: *Loot,
    mining: *MiningRegistry,
    placement: *PlacementRegistry,
    book: *RecipeBookRegistry,
};
pub const Sources = struct {
    items: registry.Registry(ItemRegistry).Source,
    blocks: registry.Registry(Blocks).Source,
    dimensions: registry.Registry(Dimensions).Source,
    enchantments: registry.Registry(EnchantmentRegistry).Source,
    client: registry.Registry(ClientRegistries).Source,
    crafting: registry.Registry(Crafting).Source,
    furnaces: registry.Registry(Furnaces).Source,
    loot: registry.Registry(Loot).Source,
    mining: registry.Registry(MiningRegistry).Source,
    placement: registry.Registry(PlacementRegistry).Source,
    book: registry.Registry(RecipeBookRegistry).Source,
};

pub const Exclusions = struct {
    items: []const registry.Registry(ItemRegistry).Exclusion = &.{},
    blocks: []const registry.Registry(Blocks).Exclusion = &.{},
    dimensions: []const registry.Registry(Dimensions).Exclusion = &.{},
    enchantments: []const registry.Registry(EnchantmentRegistry).Exclusion = &.{},
    client: []const registry.Registry(ClientRegistries).Exclusion = &.{},
    crafting: []const registry.Registry(Crafting).Exclusion = &.{},
    furnaces: []const registry.Registry(Furnaces).Exclusion = &.{},
    loot: []const registry.Registry(Loot).Exclusion = &.{},
    mining: []const registry.Registry(MiningRegistry).Exclusion = &.{},
    placement: []const registry.Registry(PlacementRegistry).Exclusion = &.{},
    book: []const registry.Registry(RecipeBookRegistry).Exclusion = &.{},
};

fn selectedTags(allocator: std.mem.Allocator, declarations: []const tags.Definition, name: ?[]const u8) ![]const tags.Definition {
    var result: std.ArrayList(tags.Definition) = .empty;
    for (declarations) |entry| {
        const matched = if (name) |value| std.mem.eql(u8, entry.registry, value) else !owned(entry.registry);
        if (matched) try result.append(allocator, entry);
    }
    return result.items;
}
fn owned(name: []const u8) bool {
    for ([_][]const u8{ "minecraft:item", "minecraft:block", "minecraft:dimension_type", "minecraft:enchantment" }) |entry| if (std.mem.eql(u8, entry, name)) return true;
    return false;
}
fn selectedEntries(allocator: std.mem.Allocator, declarations: []const Registries.Definition, name: ?[]const u8) ![]const Registries.Definition {
    var result: std.ArrayList(Registries.Definition) = .empty;
    for (declarations) |entry| {
        const matched = if (name) |value| std.mem.eql(u8, entry.registry, value) else !owned(entry.registry);
        if (matched) try result.append(allocator, entry);
    }
    return result.items;
}
pub fn register(deps: Dependencies, allocator: std.mem.Allocator, definitions: types.Definitions, previous: ?Sources) !Sources {
    return registerExcluded(deps, allocator, definitions, previous, .{});
}

pub fn registerExcluded(deps: Dependencies, allocator: std.mem.Allocator, definitions: types.Definitions, previous: ?Sources, exclusions: Exclusions) !Sources {
    var crafting_entries: std.ArrayList(recipes.Entry) = .empty;
    var furnace_entries: std.ArrayList(recipes.Entry) = .empty;
    for (definitions.recipes) |entry| {
        if (entry.definition == .smelting) try furnace_entries.append(allocator, entry) else try crafting_entries.append(allocator, entry);
    }
    var items = try deps.items.registry.stageExcluded(if (previous) |value| value.items else null, .{ .items = definitions.items, .tags = try selectedTags(allocator, definitions.tags, "minecraft:item"), .remainders = definitions.remainders }, exclusions.items);
    errdefer items.cancel();
    var blocks = try deps.blocks.registry.stageExcluded(if (previous) |value| value.blocks else null, .{ .visibility = definitions.visibility, .states = definitions.block_states, .physics = definitions.physics, .lighting = definitions.lighting, .tags = try selectedTags(allocator, definitions.tags, "minecraft:block") }, exclusions.blocks);
    errdefer blocks.cancel();
    var dimensions = try deps.dimensions.registry.stageExcluded(if (previous) |value| value.dimensions else null, .{ .dimensions = definitions.dimension_types, .tags = try selectedTags(allocator, definitions.tags, "minecraft:dimension_type") }, exclusions.dimensions);
    errdefer dimensions.cancel();
    var enchantments = try deps.enchantments.registry.stageExcluded(if (previous) |value| value.enchantments else null, .{ .entries = try selectedEntries(allocator, definitions.registries, "minecraft:enchantment"), .tags = try selectedTags(allocator, definitions.tags, "minecraft:enchantment"), .effects = definitions.enchantments }, exclusions.enchantments);
    errdefer enchantments.cancel();
    var client = try deps.client.registry.stageExcluded(if (previous) |value| value.client else null, .{ .entries = try selectedEntries(allocator, definitions.registries, null), .tags = try selectedTags(allocator, definitions.tags, null), .presentations = definitions.client_registries }, exclusions.client);
    errdefer client.cancel();
    var crafting = try deps.crafting.registry.stageExcluded(if (previous) |value| value.crafting else null, .{ .recipes = crafting_entries.items }, exclusions.crafting);
    errdefer crafting.cancel();
    var furnaces = try deps.furnaces.registry.stageExcluded(if (previous) |value| value.furnaces else null, .{ .recipes = furnace_entries.items, .fuels = definitions.fuels, .fuel_conversions = definitions.fuel_conversions }, exclusions.furnaces);
    errdefer furnaces.cancel();
    var loot = try deps.loot.registry.stageExcluded(if (previous) |value| value.loot else null, .{ .tables = definitions.loot_tables }, exclusions.loot);
    errdefer loot.cancel();
    var mining = try deps.mining.registry.stageExcluded(if (previous) |value| value.mining else null, .{ .blocks = definitions.mining }, exclusions.mining);
    errdefer mining.cancel();
    var placement = try deps.placement.registry.stageExcluded(if (previous) |value| value.placement else null, .{ .items = definitions.placement }, exclusions.placement);
    errdefer placement.cancel();
    var book = try deps.book.registry.stageExcluded(if (previous) |value| value.book else null, .{ .unlocks = definitions.recipe_unlocks }, exclusions.book);
    errdefer book.cancel();
    try items.commit();
    try blocks.commit();
    try dimensions.commit();
    try enchantments.commit();
    try client.commit();
    try crafting.commit();
    try furnaces.commit();
    try loot.commit();
    try mining.commit();
    try placement.commit();
    try book.commit();
    return .{
        .items = items.source,
        .blocks = blocks.source,
        .dimensions = dimensions.source,
        .enchantments = enchantments.source,
        .client = client.source,
        .crafting = crafting.source,
        .furnaces = furnaces.source,
        .loot = loot.source,
        .mining = mining.source,
        .placement = placement.source,
        .book = book.source,
    };
}

pub fn configureProtocols(deps: Dependencies, comptime Catalog: type, allocator: std.mem.Allocator, catalog: *Catalog) !void {
    try deps.items.registry.validate();
    try deps.blocks.registry.validate();
    try deps.dimensions.registry.validate();
    try deps.enchantments.registry.validate();
    try deps.client.registry.validate();
    try deps.crafting.registry.validate();
    try deps.furnaces.registry.validate();
    try deps.loot.registry.validate();
    try deps.mining.registry.validate();
    try deps.placement.registry.validate();
    try deps.book.registry.validate();
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const temporary = scratch.allocator();
    var entries: std.ArrayList(Registries.Registry) = .empty;
    inline for (.{ deps.items.client, deps.blocks.client, deps.dimensions.client, deps.enchantments.client, deps.client.client }) |client| try entries.appendSlice(temporary, client.values);
    var names: std.StringHashMapUnmanaged(usize) = .empty;
    try names.ensureTotalCapacity(temporary, @intCast(entries.items.len));
    for (entries.items, 0..) |entry, index| names.putAssumeCapacityNoClobber(entry.name, index);
    const view: Registries = .{ .values = entries.items, .names = names };
    try view.validatePresentations(deps.client.presentations);
    try protocols.configure(&view, deps.client.presentations, Catalog, allocator, catalog);
}

pub fn from(comptime Simulation: type, simulation: *Simulation) Dependencies {
    var result: Dependencies = undefined;
    inline for (@typeInfo(Dependencies).@"struct".fields) |field| @field(result, field.name) = simulation.get(@typeInfo(field.type).pointer.child);
    return result;
}

pub fn prepare(allocator: std.mem.Allocator) !Dependencies {
    const items = try ItemRegistry.init(allocator, .{});
    const crafting = try Crafting.init(allocator, .{}, .{ .items = items });
    const furnaces = try Furnaces.init(allocator, .{}, .{ .items = items });
    return .{
        .items = items,
        .blocks = try Blocks.init(allocator, .{}),
        .dimensions = try Dimensions.init(allocator, .{}),
        .enchantments = try EnchantmentRegistry.init(allocator, .{}),
        .client = try ClientRegistries.init(allocator, .{}),
        .crafting = crafting,
        .furnaces = furnaces,
        .loot = try Loot.init(allocator, .{}, .{ .items = items }),
        .mining = try MiningRegistry.init(allocator, .{}, .{ .items = items }),
        .placement = try PlacementRegistry.init(allocator, .{}),
        .book = try RecipeBookRegistry.init(allocator, .{}, .{ .items = items, .crafting = crafting, .furnaces = furnaces }),
    };
}

pub const Selections = lightning_rod.plugin.Compose(std.meta.Tuple(&.{
    lightning_rod.plugin.Selection(ItemRegistry),
    lightning_rod.plugin.Selection(Blocks),
    lightning_rod.plugin.Selection(Dimensions),
    lightning_rod.plugin.Selection(EnchantmentRegistry),
    lightning_rod.plugin.Selection(ClientRegistries),
    lightning_rod.plugin.Selection(Crafting),
    lightning_rod.plugin.Selection(Furnaces),
    lightning_rod.plugin.Selection(Loot),
    lightning_rod.plugin.Selection(MiningRegistry),
    lightning_rod.plugin.Selection(PlacementRegistry),
    lightning_rod.plugin.Selection(RecipeBookRegistry),
}));
pub fn selections(prepared: Dependencies) Selections {
    return lightning_rod.plugin.compose(.{
        lightning_rod.plugin.configured(ItemRegistry, .{ .prepared = prepared.items }),
        lightning_rod.plugin.configured(Blocks, .{ .prepared = prepared.blocks }),
        lightning_rod.plugin.configured(Dimensions, .{ .prepared = prepared.dimensions }),
        lightning_rod.plugin.configured(EnchantmentRegistry, .{ .prepared = prepared.enchantments }),
        lightning_rod.plugin.configured(ClientRegistries, .{ .prepared = prepared.client }),
        lightning_rod.plugin.configured(Crafting, .{ .prepared = prepared.crafting }),
        lightning_rod.plugin.configured(Furnaces, .{ .prepared = prepared.furnaces }),
        lightning_rod.plugin.configured(Loot, .{ .prepared = prepared.loot }),
        lightning_rod.plugin.configured(MiningRegistry, .{ .prepared = prepared.mining }),
        lightning_rod.plugin.configured(PlacementRegistry, .{ .prepared = prepared.placement }),
        lightning_rod.plugin.configured(RecipeBookRegistry, .{ .prepared = prepared.book }),
    });
}
