const std = @import("std");
const native = @import("vanilla_items").enchantment_effects;
const Effect = native.Effect;
const LevelValue = native.LevelValue;
const game_data = @import("game_data");
const ids = @import("vanilla_content").content_ids;
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
        const supported = [_][]const u8{ "minecraft:repair_with_xp", "minecraft:block_experience", "minecraft:item_damage", "minecraft:damage_protection", "minecraft:damage", "minecraft:knockback", "minecraft:armor_effectiveness", "minecraft:smash_damage_per_fallen_block", "minecraft:ammo_use", "minecraft:projectile_count", "minecraft:projectile_spread", "minecraft:projectile_piercing", "minecraft:crossbow_charge_time", "minecraft:trident_return_acceleration", "minecraft:trident_spin_attack_strength", "minecraft:post_attack", "minecraft:projectile_spawned", "minecraft:attributes", "minecraft:prevent_armor_change", "minecraft:prevent_equipment_drop" };
        if (!for (supported) |name| {
            if (std.mem.eql(u8, key, name)) break true;
        } else false) return error.UnsupportedEnchantmentEffect;
    };
    return .{
        .slots = @bitCast(mask),
        .repair = try channel(allocator, effects, "minecraft:repair_with_xp", baseline),
        .block_experience = try channel(allocator, effects, "minecraft:block_experience", baseline),
        .item_damage = try channel(allocator, effects, "minecraft:item_damage", baseline),
        .damage_protection = try channel(allocator, effects, "minecraft:damage_protection", baseline),
        .damage = try channel(allocator, effects, "minecraft:damage", baseline),
        .knockback = try channel(allocator, effects, "minecraft:knockback", baseline),
        .armor_effectiveness = try channel(allocator, effects, "minecraft:armor_effectiveness", baseline),
        .smash_damage_per_fallen_block = try channel(allocator, effects, "minecraft:smash_damage_per_fallen_block", baseline),
        .ammo_use = try channel(allocator, effects, "minecraft:ammo_use", baseline),
        .projectile_count = try channel(allocator, effects, "minecraft:projectile_count", baseline),
        .projectile_spread = try channel(allocator, effects, "minecraft:projectile_spread", baseline),
        .projectile_piercing = try channel(allocator, effects, "minecraft:projectile_piercing", baseline),
        .crossbow_charge_time = try single(allocator, effects, "minecraft:crossbow_charge_time"),
        .trident_return_acceleration = try channel(allocator, effects, "minecraft:trident_return_acceleration", baseline),
        .trident_spin_attack_strength = try single(allocator, effects, "minecraft:trident_spin_attack_strength"),
        .post_attack = try postAttack(allocator, effects, baseline),
        .projectile_spawned = try spawned(allocator, effects, baseline),
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

/// post_attack: who holds the enchantment, who it acts on, and an entity effect. Vanilla's own
/// effects this build lacks compile to nothing; a datapack's are refused.
fn postAttack(allocator: std.mem.Allocator, object: std.json.Value, baseline: bool) ![]const native.PostAttack {
    const value = object.object.get("minecraft:post_attack") orelse return &.{};
    if (value != .array or value.array.items.len > 256) return error.InvalidEnchantmentEffect;
    const result = try allocator.alloc(native.PostAttack, value.array.items.len);
    for (value.array.items, result) |entry, *effect| {
        if (entry != .object) return error.InvalidEnchantmentEffect;
        effect.* = .{
            .enchanted = std.meta.stringToEnum(native.PostAttack.Holder, try string(entry, "enchanted")) orelse return error.InvalidEnchantmentEffect,
            .affected = std.meta.stringToEnum(native.PostAttack.Affected, try string(entry, "affected")) orelse return error.InvalidEnchantmentEffect,
            .effect = try entityEffect(allocator, entry.object.get("effect") orelse return error.InvalidEnchantmentEffect, baseline, 0),
            .condition = if (entry.object.get("requirements")) |requirements| try condition(allocator, requirements, baseline, 0) else null,
        };
    }
    return result;
}

/// A channel of one unconditional effect rather than a list, as crossbow_charge_time is.
fn single(allocator: std.mem.Allocator, object: std.json.Value, name: []const u8) ![]const Effect {
    const value = object.object.get(name) orelse return &.{};
    const effects = try allocator.alloc(Effect, 1);
    effects[0] = try decodeEffect(allocator, value, 0);
    return effects;
}

/// projectile_spawned: entity effects on each projectile the item shoots.
fn spawned(allocator: std.mem.Allocator, object: std.json.Value, baseline: bool) ![]const native.EntityEffect {
    const value = object.object.get("minecraft:projectile_spawned") orelse return &.{};
    if (value != .array or value.array.items.len > 256) return error.InvalidEnchantmentEffect;
    const result = try allocator.alloc(native.EntityEffect, value.array.items.len);
    for (value.array.items, result) |entry, *effect| {
        if (entry != .object) return error.InvalidEnchantmentEffect;
        if (entry.object.get("requirements") != null and !baseline) return error.UnsupportedEnchantmentRequirement;
        effect.* = try entityEffect(allocator, entry.object.get("effect") orelse return error.InvalidEnchantmentEffect, baseline, 0);
    }
    return result;
}

fn entityEffect(allocator: std.mem.Allocator, json: std.json.Value, baseline: bool, depth: usize) anyerror!native.EntityEffect {
    if (depth >= 64 or json != .object) return error.InvalidEnchantmentEffect;
    const name = try string(json, "type");
    if (std.mem.eql(u8, name, "minecraft:all_of")) {
        const values = json.object.get("effects") orelse return error.InvalidEnchantmentEffect;
        if (values != .array or values.array.items.len > 256) return error.InvalidEnchantmentEffect;
        const effects = try allocator.alloc(native.EntityEffect, values.array.items.len);
        for (values.array.items, effects) |value, *effect| effect.* = try entityEffect(allocator, value, baseline, depth + 1);
        return .{ .all = effects };
    }
    if (std.mem.eql(u8, name, "minecraft:ignite")) return .{ .ignite = try decodeValue(allocator, json.object.get("duration") orelse return error.InvalidEnchantmentEffect, depth + 1) };
    if (std.mem.eql(u8, name, "minecraft:change_item_damage")) return .{ .change_item_damage = try decodeValue(allocator, json.object.get("amount") orelse return error.InvalidEnchantmentEffect, depth + 1) };
    if (std.mem.eql(u8, name, "minecraft:damage_entity")) {
        const damage_type = try string(json, "damage_type");
        if (!ids.validName(damage_type)) return error.InvalidEnchantmentEffect;
        return .{ .damage_entity = .{
            .damage_type = try allocator.dupe(u8, damage_type),
            .minimum = try decodeValue(allocator, json.object.get("min_damage") orelse return error.InvalidEnchantmentEffect, depth + 1),
            .maximum = try decodeValue(allocator, json.object.get("max_damage") orelse return error.InvalidEnchantmentEffect, depth + 1),
        } };
    }
    if (baseline) return .unsupported;
    return error.UnsupportedEnchantmentEffect;
}

fn channel(allocator: std.mem.Allocator, object: std.json.Value, name: []const u8, baseline: bool) ![]const Effect {
    const value = object.object.get(name) orelse return &.{};
    if (value != .array or value.array.items.len > 256) return error.InvalidEnchantmentEffect;
    const effects = try allocator.alloc(Effect, value.array.items.len);
    for (value.array.items, effects) |entry, *effect| {
        if (entry != .object) return error.InvalidEnchantmentEffect;
        const decoded = try decodeEffect(allocator, entry.object.get("effect") orelse return error.InvalidEnchantmentEffect, 0);
        effect.* = if (entry.object.get("requirements")) |requirements| blk: {
            const child = try allocator.create(Effect);
            child.* = decoded;
            break :blk .{ .conditional = .{ .condition = try condition(allocator, requirements, baseline, 0), .effect = child } };
        } else decoded;
    }
    return effects;
}

fn condition(allocator: std.mem.Allocator, json: std.json.Value, baseline: bool, depth: usize) anyerror!native.Condition {
    if (depth >= 64 or json != .object) return error.InvalidEnchantmentRequirement;
    const name = try string(json, "condition");
    if (std.mem.eql(u8, name, "minecraft:inverted")) {
        const child = try allocator.create(native.Condition);
        child.* = try condition(allocator, json.object.get("term") orelse return error.InvalidEnchantmentRequirement, baseline, depth + 1);
        return .{ .inverted = child };
    }
    if (std.mem.eql(u8, name, "minecraft:all_of") or std.mem.eql(u8, name, "minecraft:any_of")) {
        const terms = json.object.get("terms") orelse return error.InvalidEnchantmentRequirement;
        if (terms != .array or terms.array.items.len > 256) return error.InvalidEnchantmentRequirement;
        const children = try allocator.alloc(native.Condition, terms.array.items.len);
        for (terms.array.items, children) |term, *child| child.* = try condition(allocator, term, baseline, depth + 1);
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
    if (std.mem.eql(u8, name, "minecraft:random_chance")) {
        const chance = json.object.get("chance") orelse return error.InvalidEnchantmentRequirement;
        if (chance == .object) if (chance.object.get("type")) |kind| if (kind == .string and std.mem.eql(u8, kind.string, "minecraft:enchantment_level")) {
            return .{ .chance = try decodeValue(allocator, chance.object.get("amount") orelse return error.InvalidEnchantmentRequirement, depth + 1) };
        };
        if (chance == .integer or chance == .float) return .{ .chance = .{ .constant = try number(chance) } };
        return unsupported(baseline);
    }
    if (std.mem.eql(u8, name, "minecraft:entity_properties")) return entityProperties(allocator, json, baseline);
    if (std.mem.eql(u8, name, "minecraft:damage_source_properties")) {
        const predicate = json.object.get("predicate") orelse return error.InvalidEnchantmentRequirement;
        if (predicate != .object or predicate.object.count() != 1) return unsupported(baseline);
        if (predicate.object.get("is_direct")) |direct| {
            if (direct != .bool) return error.InvalidEnchantmentRequirement;
            return .{ .direct = direct.bool };
        }
        const tags = predicate.object.get("tags") orelse return unsupported(baseline);
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
    return unsupported(baseline);
}

/// A requirement this build cannot test: in vanilla's own enchantments it never holds, so the
/// effect it guards stays off; a datapack's is refused.
fn unsupported(baseline: bool) !native.Condition {
    if (baseline) return .unsupported;
    return error.UnsupportedEnchantmentRequirement;
}

/// entity_properties whose predicate names only an entity type or a tag of them.
fn entityProperties(allocator: std.mem.Allocator, json: std.json.Value, baseline: bool) !native.Condition {
    const entity = json.object.get("entity") orelse return unsupported(baseline);
    if (entity != .string) return error.InvalidEnchantmentRequirement;
    const subject = std.meta.stringToEnum(native.EntityType.Subject, entity.string) orelse return unsupported(baseline);
    const predicate = json.object.get("predicate") orelse return error.InvalidEnchantmentRequirement;
    if (predicate != .object) return error.InvalidEnchantmentRequirement;
    if (predicate.object.count() != 1) return unsupported(baseline);
    const kind = predicate.object.get("type") orelse return unsupported(baseline);
    if (kind != .string) return unsupported(baseline);
    const tag = std.mem.startsWith(u8, kind.string, "#");
    const name = if (tag) kind.string[1..] else kind.string;
    if (!ids.validName(name)) return error.InvalidEnchantmentRequirement;
    return .{ .entity_type = .{ .subject = subject, .name = try allocator.dupe(u8, name), .tag = tag } };
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
        \\{"slots":["mainhand"],"effects":{"minecraft:tick":[]}}
    , .{});
    try std.testing.expectError(error.UnsupportedEnchantmentEffect, decode(allocator, value, false));
    _ = try decode(allocator, value, true);
}

test "vanilla's combat enchantments decode, and what this build lacks stays off only for vanilla" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const smite = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"slots":["mainhand"],"effects":{"minecraft:damage":[{"effect":{"type":"minecraft:add","value":{"type":"minecraft:linear","base":2.5,"per_level_above_first":2.5}},"requirements":{"condition":"minecraft:entity_properties","entity":"this","predicate":{"type":"#minecraft:sensitive_to_smite"}}}]}}
    , .{});
    const decoded = try decode(allocator, smite, false);
    try std.testing.expectEqual(@as(usize, 1), decoded.damage.len);
    const entity = decoded.damage[0].conditional.condition.entity_type;
    try std.testing.expectEqualStrings("minecraft:sensitive_to_smite", entity.name);
    try std.testing.expect(entity.tag and entity.subject == .this);

    const thorns = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"slots":["any"],"effects":{"minecraft:post_attack":[{"affected":"attacker","effect":{"type":"minecraft:all_of","effects":[{"type":"minecraft:damage_entity","damage_type":"minecraft:thorns","max_damage":5.0,"min_damage":1.0},{"type":"minecraft:change_item_damage","amount":2.0}]},"enchanted":"victim","requirements":{"chance":{"type":"minecraft:enchantment_level","amount":{"type":"minecraft:linear","base":0.15,"per_level_above_first":0.15}},"condition":"minecraft:random_chance"}}]}}
    , .{});
    const reflected = try decode(allocator, thorns, false);
    try std.testing.expectEqual(native.PostAttack.Holder.victim, reflected.post_attack[0].enchanted);
    try std.testing.expectEqual(@as(usize, 2), reflected.post_attack[0].effect.all.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.45), reflected.post_attack[0].condition.?.chance.evaluate(3), 1e-6);

    const channeling = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"slots":["mainhand"],"effects":{"minecraft:post_attack":[{"affected":"victim","effect":{"type":"minecraft:summon_entity","entity":"minecraft:lightning_bolt"},"enchanted":"attacker","requirements":{"condition":"minecraft:weather_check","thundering":true}}]}}
    , .{});
    try std.testing.expectError(error.UnsupportedEnchantmentEffect, decode(allocator, channeling, false));
    const off = try decode(allocator, channeling, true);
    try std.testing.expect(off.post_attack[0].effect == .unsupported and off.post_attack[0].condition.? == .unsupported);
}
