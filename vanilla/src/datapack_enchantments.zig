const std = @import("std");
const native = @import("enchantment_effects.zig");
const Effect = native.Effect;
const LevelValue = native.LevelValue;
const game_data = @import("game_data");
const ids = @import("content_ids.zig");
pub fn decode(allocator: std.mem.Allocator, json: std.json.Value, baseline: bool) !native.Effects.Definition {
    const slots = json.object.get("slots") orelse return error.InvalidEnchantment;
    if (slots != .array) return error.InvalidEnchantment;
    var mask: u8 = 0;
    for (slots.array.items) |slot| {
        if (slot != .string) return error.InvalidEnchantment;
        const names = [_][]const u8{ "mainhand", "offhand", "head", "chest", "legs", "feet", "body", "saddle" };
        if (std.mem.eql(u8, slot.string, "any")) {
            mask = 255;
            continue;
        }
        if (std.mem.eql(u8, slot.string, "hand")) {
            mask |= 3;
            continue;
        }
        if (std.mem.eql(u8, slot.string, "armor")) {
            mask |= 60;
            continue;
        }
        const known = for (names, 0..) |name, index| {
            if (std.mem.eql(u8, name, slot.string)) {
                mask |= @as(u8, 1) << @intCast(index);
                break true;
            }
        } else false;
        if (!known) return error.InvalidEnchantmentSlot;
    }
    const effects = json.object.get("effects") orelse {
        return .{ .slots = @bitCast(mask), .repair = &.{}, .block_experience = &.{} };
    };
    if (effects != .object) return error.InvalidEnchantment;
    if (!baseline) for (effects.object.keys()) |key| {
        const supported = [_][]const u8{ "minecraft:repair_with_xp", "minecraft:block_experience", "minecraft:item_damage", "minecraft:damage_protection", "minecraft:attributes", "minecraft:prevent_armor_change", "minecraft:prevent_equipment_drop" };
        if (!for (supported) |name| {
            if (std.mem.eql(u8, key, name)) break true;
        } else false) return error.UnsupportedEnchantmentEffect;
    };
    return .{
        .slots = @bitCast(mask),
        .repair = try channel(allocator, effects, "minecraft:repair_with_xp"),
        .block_experience = try channel(allocator, effects, "minecraft:block_experience"),
        .item_damage = try channel(allocator, effects, "minecraft:item_damage"),
        .damage_protection = try channel(allocator, effects, "minecraft:damage_protection"),
        .attributes = try attributes(allocator, effects),
        .prevent_armor_change = try marker(effects, "minecraft:prevent_armor_change"),
        .prevent_equipment_drop = try marker(effects, "minecraft:prevent_equipment_drop"),
    };
}

fn marker(object: std.json.Value, name: []const u8) !bool {
    const value = object.object.get(name) orelse return false;
    if (value != .object or value.object.count() != 0) return error.InvalidEnchantmentEffect;
    return true;
}

fn attributes(allocator: std.mem.Allocator, object: std.json.Value) ![]const native.Attribute {
    const values = object.object.get("minecraft:attributes") orelse return &.{};
    if (values != .array or values.array.items.len > 256) return error.InvalidEnchantmentEffect;
    const result = try allocator.alloc(native.Attribute, values.array.items.len);
    for (values.array.items, result, 0..) |value, *entry, index| {
        if (value != .object or value.object.count() != 4) return error.InvalidEnchantmentEffect;
        const id = try string(value, "id");
        const attribute = try string(value, "attribute");
        if (!ids.validName(id) or !ids.validName(attribute)) return error.InvalidEnchantmentEffect;
        for (result[0..index]) |previous| if (std.mem.eql(u8, previous.id, id) and std.mem.eql(u8, previous.attribute, attribute)) return error.DuplicateEnchantmentAttribute;
        entry.* = .{
            .id = try allocator.dupe(u8, id),
            .attribute = try allocator.dupe(u8, attribute),
            .amount = try decodeValue(allocator, value.object.get("amount") orelse return error.InvalidEnchantmentEffect, 0),
            .operation = std.meta.stringToEnum(native.Operation, try string(value, "operation")) orelse return error.InvalidEnchantmentEffect,
        };
    }
    return result;
}

fn channel(allocator: std.mem.Allocator, object: std.json.Value, name: []const u8) ![]const Effect {
    const value = object.object.get(name) orelse return &.{};
    if (value != .array or value.array.items.len > 256) return error.InvalidEnchantmentEffect;
    const effects = try allocator.alloc(Effect, value.array.items.len);
    for (value.array.items, effects) |entry, *effect| {
        if (entry != .object) return error.InvalidEnchantmentEffect;
        const decoded = try decodeEffect(allocator, entry.object.get("effect") orelse return error.InvalidEnchantmentEffect, 0);
        effect.* = if (entry.object.get("requirements")) |requirements| blk: {
            const child = try allocator.create(Effect);
            child.* = decoded;
            break :blk .{ .conditional = .{ .condition = try condition(allocator, requirements, 0), .effect = child } };
        } else decoded;
    }
    return effects;
}

fn condition(allocator: std.mem.Allocator, json: std.json.Value, depth: usize) anyerror!native.Condition {
    if (depth >= 64 or json != .object) return error.InvalidEnchantmentRequirement;
    const name = try string(json, "condition");
    if (std.mem.eql(u8, name, "minecraft:inverted")) {
        const child = try allocator.create(native.Condition);
        child.* = try condition(allocator, json.object.get("term") orelse return error.InvalidEnchantmentRequirement, depth + 1);
        return .{ .inverted = child };
    }
    if (std.mem.eql(u8, name, "minecraft:all_of") or std.mem.eql(u8, name, "minecraft:any_of")) {
        const terms = json.object.get("terms") orelse return error.InvalidEnchantmentRequirement;
        if (terms != .array or terms.array.items.len > 256) return error.InvalidEnchantmentRequirement;
        const children = try allocator.alloc(native.Condition, terms.array.items.len);
        for (terms.array.items, children) |term, *child| child.* = try condition(allocator, term, depth + 1);
        return if (std.mem.eql(u8, name, "minecraft:all_of")) .{ .all = children } else .{ .any = children };
    }
    if (std.mem.eql(u8, name, "minecraft:match_tool")) {
        const predicate = json.object.get("predicate") orelse return error.InvalidEnchantmentRequirement;
        if (predicate != .object) return error.InvalidEnchantmentRequirement;
        if (predicate.object.count() == 0) return .{ .all = &.{} };
        if (predicate.object.count() != 1) return error.UnsupportedEnchantmentRequirement;
        const items = predicate.object.get("items") orelse return error.UnsupportedEnchantmentRequirement;
        if (items == .string and std.mem.startsWith(u8, items.string, "#")) {
            const tag = items.string[1..];
            if (!ids.validName(tag)) return error.InvalidEnchantmentRequirement;
            return .{ .item_tag = try allocator.dupe(u8, tag) };
        }
        const values: []const std.json.Value = if (items == .array) items.array.items else &.{items};
        const kinds = try allocator.alloc(u32, values.len);
        for (values, kinds) |item, *kind| {
            if (item != .string) return error.InvalidEnchantmentRequirement;
            kind.* = @intCast(game_data.registry.itemId(item.string) orelse return error.UnknownEnchantmentItem);
        }
        return .{ .items = kinds };
    }
    if (std.mem.eql(u8, name, "minecraft:damage_source_properties")) {
        const predicate = json.object.get("predicate") orelse return error.InvalidEnchantmentRequirement;
        if (predicate != .object or predicate.object.count() != 1) return error.UnsupportedEnchantmentRequirement;
        const tags = predicate.object.get("tags") orelse return error.UnsupportedEnchantmentRequirement;
        if (tags != .array or tags.array.items.len > 256) return error.InvalidEnchantmentRequirement;
        const result = try allocator.alloc(native.DamageTag, tags.array.items.len);
        for (tags.array.items, result) |tag, *target| {
            if (tag != .object or tag.object.count() != 2) return error.InvalidEnchantmentRequirement;
            const id = try string(tag, "id");
            const expected = tag.object.get("expected") orelse return error.InvalidEnchantmentRequirement;
            if (!ids.validName(id) or expected != .bool) return error.InvalidEnchantmentRequirement;
            target.* = .{ .id = try allocator.dupe(u8, id), .expected = expected.bool };
        }
        return .{ .damage_tags = result };
    }
    return error.UnsupportedEnchantmentRequirement;
}

fn decodeEffect(allocator: std.mem.Allocator, json: std.json.Value, depth: usize) anyerror!Effect {
    if (depth >= 64 or json != .object) return error.InvalidEnchantmentEffect;
    const name = try string(json, "type");
    if (std.mem.eql(u8, name, "minecraft:all_of")) {
        const values = json.object.get("effects") orelse return error.InvalidEnchantmentEffect;
        if (values != .array) return error.InvalidEnchantmentEffect;
        const effects = try allocator.alloc(Effect, values.array.items.len);
        for (values.array.items, effects) |value, *effect| effect.* = try decodeEffect(allocator, value, depth + 1);
        return .{ .all = effects };
    }
    if (std.mem.eql(u8, name, "minecraft:add")) return .{ .add = try decodeValue(allocator, json.object.get("value") orelse return error.InvalidEnchantmentEffect, depth + 1) };
    if (std.mem.eql(u8, name, "minecraft:multiply")) return .{ .multiply = try decodeValue(allocator, json.object.get("factor") orelse return error.InvalidEnchantmentEffect, depth + 1) };
    if (std.mem.eql(u8, name, "minecraft:set")) return .{ .set = try decodeValue(allocator, json.object.get("value") orelse return error.InvalidEnchantmentEffect, depth + 1) };
    if (std.mem.eql(u8, name, "minecraft:remove_binomial")) return .{ .remove_binomial = try decodeValue(allocator, json.object.get("chance") orelse return error.InvalidEnchantmentEffect, depth + 1) };
    return error.UnsupportedEnchantmentEffect;
}

fn number(json: std.json.Value) !f32 {
    const value: f32 = switch (json) {
        .integer => @floatFromInt(json.integer),
        .float => @floatCast(json.float),
        else => return error.InvalidEnchantmentValue,
    };
    if (!std.math.isFinite(value)) return error.InvalidEnchantmentValue;
    return value;
}

fn string(json: std.json.Value, key: []const u8) ![]const u8 {
    const value = json.object.get(key) orelse return error.InvalidEnchantmentValue;
    if (value != .string) return error.InvalidEnchantmentValue;
    return value.string;
}

fn decodeValue(allocator: std.mem.Allocator, json: std.json.Value, depth: usize) anyerror!LevelValue {
    if (depth >= 64) return error.InvalidEnchantmentValue;
    if (json == .integer or json == .float) return .{ .constant = try number(json) };
    if (json != .object) return error.InvalidEnchantmentValue;
    const name = try string(json, "type");
    if (std.mem.eql(u8, name, "minecraft:linear")) return .{ .linear = .{ .base = try number(json.object.get("base") orelse return error.InvalidEnchantmentValue), .per_level = try number(json.object.get("per_level_above_first") orelse return error.InvalidEnchantmentValue) } };
    if (std.mem.eql(u8, name, "minecraft:levels_squared")) return .{ .squared = .{ .added = try number(json.object.get("added") orelse return error.InvalidEnchantmentValue) } };
    if (std.mem.eql(u8, name, "minecraft:fraction")) {
        const numerator = try allocator.create(LevelValue);
        const denominator = try allocator.create(LevelValue);
        numerator.* = try decodeValue(allocator, json.object.get("numerator") orelse return error.InvalidEnchantmentValue, depth + 1);
        denominator.* = try decodeValue(allocator, json.object.get("denominator") orelse return error.InvalidEnchantmentValue, depth + 1);
        return .{ .fraction = .{ .numerator = numerator, .denominator = denominator } };
    }
    if (std.mem.eql(u8, name, "minecraft:clamped")) {
        const value = try allocator.create(LevelValue);
        value.* = try decodeValue(allocator, json.object.get("value") orelse return error.InvalidEnchantmentValue, depth + 1);
        const minimum = try number(json.object.get("min") orelse return error.InvalidEnchantmentValue);
        const maximum = try number(json.object.get("max") orelse return error.InvalidEnchantmentValue);
        if (minimum > maximum) return error.InvalidEnchantmentValue;
        return .{ .clamped = .{ .value = value, .minimum = minimum, .maximum = maximum } };
    }
    if (std.mem.eql(u8, name, "minecraft:lookup")) {
        const list = json.object.get("values") orelse return error.InvalidEnchantmentValue;
        if (list != .array) return error.InvalidEnchantmentValue;
        const values = try allocator.alloc(f32, list.array.items.len);
        for (list.array.items, values) |entry, *value| value.* = try number(entry);
        const fallback = try allocator.create(LevelValue);
        fallback.* = try decodeValue(allocator, json.object.get("fallback") orelse return error.InvalidEnchantmentValue, depth + 1);
        return .{ .lookup = .{ .values = values, .fallback = fallback } };
    }
    return error.UnsupportedEnchantmentValue;
}

test "unsupported enchantment channels fail external registration without changing vanilla extraction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"slots":["mainhand"],"effects":{"minecraft:damage":[]}}
    , .{});
    try std.testing.expectError(error.UnsupportedEnchantmentEffect, decode(allocator, value, false));
    _ = try decode(allocator, value, true);
}
