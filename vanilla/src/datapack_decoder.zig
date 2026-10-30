const ItemProperties = @import("item_registry.zig").Properties;
const std = @import("std");
const datapacks = @import("datapacks");
const game_data = @import("game_data");
const definitions = @import("content_types.zig");
const dimension_types = @import("content_definitions.zig");
const tags = @import("content_tags.zig");
const recipes = @import("recipes.zig");
const loot = @import("loot.zig");
const enchantments = @import("enchantment_effects.zig");
const Registries = @import("content_registries.zig").Registries;
const Format = @import("datapack_formats.zig").Format;
const Components = @import("content_components.zig");
const recipe_decoder = @import("datapack_recipes.zig");
const loot_decoder = @import("datapack_loot.zig");
const enchantment_decoder = @import("datapack_enchantments.zig");
const unlock_decoder = @import("datapack_unlocks.zig");
const handlers = @import("datapack_handlers.zig");

pub const Options = struct {
    recipe_types: []const handlers.RecipeType = &.{},
    loot_types: []const handlers.LootType = &.{},
    baseline: bool = false,
};

pub fn decode(allocator: std.mem.Allocator, scratch: std.mem.Allocator, resources: *const datapacks.Resources, options: Options) !definitions.Definitions {
    if (!options.baseline) try validateResources(resources);
    var formats = resources.index.valueIterator();
    while (formats.next()) |index| _ = try Format.select(resources.entries[index.*].format);
    var result: definitions.Definitions = .{};
    var tag_definitions: std.ArrayList(tags.Definition) = .empty;
    var registry_definitions: std.ArrayList(Registries.Definition) = .empty;
    var dimensions: std.ArrayList(dimension_types.DimensionType) = .empty;
    var effects: std.ArrayList(enchantments.Effects.Entry) = .empty;
    var recipe_definitions: std.ArrayList(recipes.Entry) = .empty;
    var loot_definitions: std.ArrayList(loot.Definition) = .empty;
    tags_loop: for (resources.directory("tags")) |index| {
        const resource = &resources.entries[index];
        const colon = std.mem.indexOfScalar(u8, resource.name, ':').?;
        const path = resource.name[colon + 1 ..];
        if (!std.mem.endsWith(u8, path, ".json")) continue;
        // Registry names may contain slashes, so match the registry prefix first.
        var iterator = try game_data.snapshot.Iterator.init(game_data.registry_snapshot);
        const registry = while (try iterator.next()) |registry| {
            const name_colon = std.mem.indexOfScalar(u8, registry.name, ':').?;
            const prefix = try std.fmt.allocPrint(scratch, "tags/{s}/", .{registry.name[name_colon + 1 ..]});
            if (std.mem.startsWith(u8, path, prefix)) break .{ .name = registry.name, .start = prefix.len };
        } else {
            if (options.baseline) continue :tags_loop;
            return error.UnknownTagRegistry;
        };
        const name = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ resource.name[0..colon], path[registry.start .. path.len - 5] });
        var layers: std.ArrayList(*const datapacks.Resource) = .empty;
        var iterator_layers = resources.layers(resource.name);
        while (iterator_layers.next()) |layer| try layers.append(scratch, layer);
        for (0..layers.items.len) |offset| {
            const layer = layers.items[layers.items.len - offset - 1];
            const json = try parse(scratch, layer.bytes);
            const values = json.object.get("values") orelse return error.InvalidTag;
            if (values != .array) return error.InvalidTag;
            const entries = try allocator.alloc(tags.Definition.Value, values.array.items.len);
            for (values.array.items, entries) |value, *entry| {
                const id = if (value == .string) value.string else if (value == .object) try text(value, "id") else return error.InvalidTag;
                const is_tag = std.mem.startsWith(u8, id, "#");
                const resolved = try datapacks.identifier(allocator, id[@intFromBool(is_tag)..]);
                entry.* = .{ .id = if (is_tag) try std.fmt.allocPrint(allocator, "#{s}", .{resolved}) else resolved };
                if (value == .object) if (value.object.get("required")) |required| {
                    if (required != .bool) return error.InvalidTag;
                    entry.required = required.bool;
                };
            }
            var replace = false;
            if (json.object.get("replace")) |field| {
                if (field != .bool) return error.InvalidTag;
                replace = field.bool;
            }
            try tag_definitions.append(scratch, .{ .registry = registry.name, .name = name, .replace = replace, .values = entries });
        }
    }
    result.tags = try allocator.dupe(tags.Definition, tag_definitions.items);
    var iterator = try game_data.snapshot.Iterator.init(game_data.registry_snapshot);
    while (try iterator.next()) |registry| {
        if (!registry.synchronized) continue;
        const directory = registry.name[std.mem.indexOfScalar(u8, registry.name, ':').? + 1 ..];
        for (resources.directory(directory)) |index| {
            const resource = resources.entries[index];
            const name = try resourceName(allocator, resource.name, directory);
            const json = try parse(scratch, resource.bytes);
            try registry_definitions.append(scratch, .{ .registry = registry.name, .name = name, .nbt = try Components.encodeNbt(allocator, scratch, json) });
            if (std.mem.eql(u8, registry.name, "minecraft:dimension_type")) {
                const value = try decodeDimension(allocator, json);
                try dimension_types.DimensionType.validate(value);
                try dimensions.append(scratch, .{ .name = name, .definition = value });
            } else if (std.mem.eql(u8, registry.name, "minecraft:enchantment")) {
                try effects.append(scratch, .{ .name = name, .definition = try enchantment_decoder.decode(allocator, json, options.baseline) });
            }
        }
    }
    for (resources.directory("recipe")) |index| {
        const resource = resources.entries[index];
        const name = try resourceName(allocator, resource.name, "recipe");
        const json = try parse(scratch, resource.bytes);
        var definition = try recipe_decoder.decode(allocator, json, try Format.select(resource.format));
        if (definition == null) {
            const kind = try text(json, "type");
            for (options.recipe_types) |implementation| if (std.mem.eql(u8, implementation.name, kind)) {
                definition = .{ .algorithmic = try implementation.vtable.decode(implementation.context, allocator, scratch, json) };
                break;
            };
            if (definition == null) {
                if (options.baseline and recipe_decoder.unimplementedType(kind)) continue;
                return error.UnsupportedRecipeType;
            }
        }
        try recipe_definitions.append(scratch, .{ .name = name, .definition = definition.? });
    }
    var loot_compiler: loot_decoder.Compiler = .{ .allocator = allocator, .temporary = scratch, .types = options.loot_types };
    for (resources.directory("loot_table")) |index| {
        const resource = resources.entries[index];
        const name = try resourceName(allocator, resource.name, "loot_table");
        const path = name[std.mem.indexOfScalar(u8, name, ':').? + 1 ..];
        if (options.baseline and !std.mem.startsWith(u8, path, "blocks/")) continue;
        loot_compiler.format = try Format.select(resource.format);
        try loot_definitions.append(scratch, .{ .name = name, .table = (try loot_compiler.decode(resource.bytes)).* });
    }
    result.registries = try allocator.dupe(Registries.Definition, registry_definitions.items);
    result.dimension_types = try allocator.dupe(dimension_types.DimensionType, dimensions.items);
    result.enchantments = try allocator.dupe(enchantments.Effects.Entry, effects.items);
    result.recipes = try allocator.dupe(recipes.Entry, recipe_definitions.items);
    result.loot_tables = try allocator.dupe(loot.Definition, loot_definitions.items);
    if (resources.directory("advancement").len > 0) {
        var supported: ?recipes.Prepared = null;
        if (options.baseline) {
            const item_tags = try tags.Tags.prepare(scratch, scratch, result.tags, "minecraft:item", game_data.registry.item_names);
            const properties = try scratch.alloc(ItemProperties, game_data.registry.items.len);
            @memset(properties, .{ .stack_size = 99 });
            supported = try recipes.prepare(scratch, scratch, &item_tags, game_data.registry.item_names, .{ .properties = properties }, result.recipes);
        }
        result.recipe_unlocks = try unlock_decoder.decode(allocator, scratch, resources, .{ .baseline = options.baseline, .recipes = if (supported) |*table| table else null });
    }
    return result;
}

fn text(value: std.json.Value, name: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidDefinition;
    const field = value.object.get(name) orelse return error.InvalidDefinition;
    return if (field == .string) field.string else error.InvalidDefinition;
}

fn validateResources(resources: *const datapacks.Resources) !void {
    var iterator = resources.index.valueIterator();
    while (iterator.next()) |index| {
        const resource = resources.entries[index.*];
        const colon = std.mem.indexOfScalar(u8, resource.name, ':').?;
        const path = resource.name[colon + 1 ..];
        if (std.mem.startsWith(u8, path, "structure/") and std.mem.endsWith(u8, path, ".nbt")) return error.UnsupportedDatapackResource;
        if (!std.mem.endsWith(u8, path, ".json") and !std.mem.endsWith(u8, path, ".mcfunction")) continue;
        const ordinary = .{ "recipe/", "loot_table/", "tags/", "advancement/" };
        const recognized = inline for (ordinary) |directory| {
            if (std.mem.startsWith(u8, path, directory)) break true;
        } else false;
        if (recognized) continue;
        var registries = try game_data.snapshot.Iterator.init(game_data.registry_snapshot);
        const known = while (try registries.next()) |registry| {
            if (!registry.synchronized) continue;
            const directory = registry.name[std.mem.indexOfScalar(u8, registry.name, ':').? + 1 ..];
            if (path.len > directory.len and std.mem.startsWith(u8, path, directory) and path[directory.len] == '/') break true;
        } else false;
        if (!known) {
            return error.UnsupportedDatapackResource;
        }
    }
}

fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always });
    if (value != .object) return error.InvalidDefinition;
    return value;
}

fn resourceName(allocator: std.mem.Allocator, path: []const u8, directory: []const u8) ![]const u8 {
    const colon = std.mem.indexOfScalar(u8, path, ':').?;
    if (!std.mem.endsWith(u8, path, ".json") or path.len <= colon + directory.len + 7) return error.InvalidResourceName;
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ path[0..colon], path[colon + directory.len + 2 .. path.len - 5] });
}

fn decodeDimension(allocator: std.mem.Allocator, json: std.json.Value) !dimension_types.DimensionType.Definition {
    var fields: std.json.ObjectMap = .empty;
    var iterator = json.object.iterator();
    while (iterator.next()) |entry| if (!std.mem.eql(u8, entry.key_ptr.*, "monster_spawn_light_level")) try fields.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    var result = try std.json.parseFromValueLeaky(dimension_types.DimensionType.Definition, allocator, .{ .object = fields }, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    if (json.object.get("monster_spawn_light_level")) |light| {
        if (light == .integer) result.monster_spawn_light_level = .{ .constant = std.math.cast(u4, light.integer) orelse return error.InvalidDimension } else if (light == .object) {
            const kind = try text(light, "type");
            if (!std.mem.eql(u8, kind, "minecraft:uniform")) return error.UnsupportedLightProvider;
            const minimum = light.object.get("min_inclusive") orelse return error.InvalidDimension;
            const maximum = light.object.get("max_inclusive") orelse return error.InvalidDimension;
            if (minimum != .integer or maximum != .integer) return error.InvalidDimension;
            result.monster_spawn_light_level = .{ .uniform = .{ .min_inclusive = std.math.cast(u4, minimum.integer) orelse return error.InvalidDimension, .max_inclusive = std.math.cast(u4, maximum.integer) orelse return error.InvalidDimension } };
        } else return error.InvalidDimension;
    }
    return result;
}

test "unsupported dimension providers and structure data are never silently approximated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json = try parse(allocator,
        \\{"monster_spawn_light_level":{"type":"minecraft:biased_to_bottom","min_inclusive":0,"max_inclusive":7}}
    );
    try std.testing.expectError(error.UnsupportedLightProvider, decodeDimension(allocator, json));
    var builder = datapacks.Builder.init(allocator, allocator, .{});
    try builder.begin("test");
    try builder.add("test:structure/house.nbt", "unsupported");
    const resources = try builder.finish();
    try std.testing.expectError(error.UnsupportedDatapackResource, validateResources(&resources));
}
