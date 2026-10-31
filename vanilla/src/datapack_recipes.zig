const std = @import("std");
const recipes = @import("recipes.zig");
const Format = @import("datapack_formats.zig").Format;
const Definition = recipes.Definition;
const Input = recipes.Input;
const Result = recipes.Result;
const Key = recipes.Key;
const Book = recipes.Book;
const Smelting = recipes.Smelting;
pub fn unimplementedType(name: []const u8) bool {
    const known = .{
        "blasting",                          "campfire_cooking",                 "crafting_decorated_pot",
        "crafting_special_armordye",         "crafting_special_bannerduplicate", "crafting_special_bookcloning",
        "crafting_special_firework_rocket",  "crafting_special_firework_star",   "crafting_special_firework_star_fade",
        "crafting_special_mapcloning",       "crafting_special_mapextending",    "crafting_special_repairitem",
        "crafting_special_shielddecoration", "crafting_special_tippedarrow",     "crafting_transmute",
        "smithing_transform",                "smithing_trim",                    "smoking",
        "stonecutting",
    };
    inline for (known) |kind| if (std.mem.eql(u8, name, "minecraft:" ++ kind)) return true;
    return false;
}

pub fn decode(allocator: std.mem.Allocator, json: std.json.Value, format: Format) !?Definition {
    if (json != .object) return error.InvalidRecipe;
    const kind = try stringField(json, "type");
    if (std.mem.eql(u8, kind, "minecraft:crafting_shaped")) {
        const pattern_value = json.object.get("pattern") orelse return error.InvalidRecipe;
        const keys_value = json.object.get("key") orelse return error.InvalidRecipe;
        if (pattern_value != .array or keys_value != .object) return error.InvalidRecipe;
        const pattern = try allocator.alloc([]const u8, pattern_value.array.items.len);
        for (pattern_value.array.items, pattern) |row, *value| {
            if (row != .string) return error.InvalidRecipe;
            value.* = row.string;
        }
        const keys = try allocator.alloc(Key, keys_value.object.count());
        var entries = keys_value.object.iterator();
        var index: usize = 0;
        while (entries.next()) |entry| {
            if (entry.key_ptr.len == 0 or entry.key_ptr.len > 3) return error.InvalidRecipe;
            const symbol = std.unicode.utf8Decode(entry.key_ptr.*) catch return error.InvalidRecipe;
            keys[index] = .{ .symbol = symbol, .input = try decodeInput(allocator, entry.value_ptr.*, format) };
            index += 1;
        }
        return .{ .shaped = .{ .book = try decodeBook(json, false), .pattern = pattern, .keys = keys, .result = try decodeResult(allocator, json.object.get("result") orelse return error.InvalidRecipe, format) } };
    }
    if (std.mem.eql(u8, kind, "minecraft:crafting_shapeless")) {
        const values = json.object.get("ingredients") orelse return error.InvalidRecipe;
        if (values != .array) return error.InvalidRecipe;
        const inputs = try allocator.alloc(Input, values.array.items.len);
        for (values.array.items, inputs) |value, *input| input.* = try decodeInput(allocator, value, format);
        return .{ .shapeless = .{ .book = try decodeBook(json, false), .ingredients = inputs, .result = try decodeResult(allocator, json.object.get("result") orelse return error.InvalidRecipe, format) } };
    }
    if (std.mem.eql(u8, kind, "minecraft:smelting")) {
        var value: Smelting = .{ .book = try decodeBook(json, true), .input = try decodeInput(allocator, json.object.get("ingredient") orelse return error.InvalidRecipe, format), .result = try decodeResult(allocator, json.object.get("result") orelse return error.InvalidRecipe, format) };
        if (json.object.get("cookingtime")) |ticks| {
            if (ticks != .integer or ticks.integer <= 0 or ticks.integer > std.math.maxInt(i32)) return error.InvalidRecipe;
            value.ticks = @intCast(ticks.integer);
        }
        if (json.object.get("experience")) |experience| value.experience = switch (experience) {
            .integer => @floatFromInt(experience.integer),
            .float => @floatCast(experience.float),
            else => return error.InvalidRecipe,
        };
        return .{ .smelting = value };
    }
    return null;
}

fn decodeInput(allocator: std.mem.Allocator, json: std.json.Value, format: Format) !Input {
    if (json == .array) {
        if (json.array.items.len == 0) return error.InvalidRecipe;
        const values = try allocator.alloc(Input, json.array.items.len);
        for (json.array.items, values) |value, *input| {
            input.* = try decodeIngredient(value, format);
            if (format != .v1_21 and input.* == .tag) return error.InvalidRecipe;
        }
        return .{ .alternatives = values };
    }
    return decodeIngredient(json, format);
}

fn decodeIngredient(json: std.json.Value, format: Format) !Input {
    if (format == .v1_21) {
        if (json != .object or json.object.count() != 1) return error.InvalidRecipe;
        if (json.object.get("item")) |item| {
            if (item != .string) return error.InvalidRecipe;
            return itemInput(item.string);
        }
        if (json.object.get("tag")) |tag| {
            if (tag != .string or tag.string.len == 0) return error.InvalidRecipe;
            return .{ .tag = tag.string };
        }
        return error.InvalidRecipe;
    }
    if (json != .string or json.string.len == 0) return error.InvalidRecipe;
    if (json.string[0] == '#') {
        if (json.string.len == 1) return error.InvalidRecipe;
        return .{ .tag = json.string[1..] };
    }
    return itemInput(json.string);
}

fn itemInput(name: []const u8) !Input {
    if (name.len == 0 or std.mem.eql(u8, name, "minecraft:air") or std.mem.eql(u8, name, "air")) return error.InvalidRecipe;
    return .{ .item = name };
}

fn decodeResult(allocator: std.mem.Allocator, json: std.json.Value, format: Format) !Result {
    if (json != .object) return error.InvalidRecipe;
    var result: Result = .{ .item = try stringField(json, "id") };
    if (json.object.get("count")) |count| {
        if (count != .integer or count.integer <= 0 or count.integer > 99) return error.InvalidRecipe;
        result.count = @intCast(count.integer);
    }
    if (json.object.get("components")) |components| result.components = try format.components(allocator, components);
    return result;
}

fn stringField(json: std.json.Value, key: []const u8) ![]const u8 {
    const value = json.object.get(key) orelse return error.InvalidRecipe;
    if (value != .string) return error.InvalidRecipe;
    return value.string;
}

fn decodeBook(json: std.json.Value, furnace: bool) !Book {
    var metadata: Book = .{ .category = if (furnace) .furnace_misc else .crafting_misc };
    if (json.object.get("group")) |group| {
        if (group != .string) return error.InvalidRecipe;
        metadata.group = group.string;
    }
    if (json.object.get("show_notification")) |notification| {
        if (notification != .bool) return error.InvalidRecipe;
        metadata.show_notification = notification.bool;
    }
    if (json.object.get("category")) |category| {
        if (category != .string) return error.InvalidRecipe;
        if (furnace) {
            metadata.category = if (std.mem.eql(u8, category.string, "food")) .furnace_food else if (std.mem.eql(u8, category.string, "blocks")) .furnace_blocks else if (std.mem.eql(u8, category.string, "misc")) .furnace_misc else return error.InvalidRecipe;
        } else metadata.category = if (std.mem.eql(u8, category.string, "building")) .crafting_building_blocks else if (std.mem.eql(u8, category.string, "redstone")) .crafting_redstone else if (std.mem.eql(u8, category.string, "equipment")) .crafting_equipment else if (std.mem.eql(u8, category.string, "misc")) .crafting_misc else return error.InvalidRecipe;
    }
    return metadata;
}

test "format adapters reject ingredients from a different schema and empty alternatives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const legacy = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"type":"minecraft:crafting_shapeless","ingredients":[{"item":"minecraft:paper"}],"result":{"id":"minecraft:diamond"}}
    , .{});
    const modern = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"type":"minecraft:crafting_shapeless","ingredients":["minecraft:paper"],"result":{"id":"minecraft:diamond"}}
    , .{});
    try std.testing.expect((try decode(allocator, legacy, .v1_21)).? == .shapeless);
    try std.testing.expectError(error.InvalidRecipe, decode(allocator, modern, .v1_21));
    for ([_]Format{ .v1_21_5, .v1_21_8, .v1_21_9 }) |format| {
        try std.testing.expect((try decode(allocator, modern, format)).? == .shapeless);
        try std.testing.expectError(error.InvalidRecipe, decode(allocator, legacy, format));
        for ([_][]const u8{ "[]", "[\"#minecraft:logs\"]", "\"minecraft:air\"", "\"#\"", "\"\"" }) |invalid| {
            const json = try std.json.parseFromSliceLeaky(std.json.Value, allocator, invalid, .{});
            try std.testing.expectError(error.InvalidRecipe, decodeInput(allocator, json, format));
        }
    }
}
