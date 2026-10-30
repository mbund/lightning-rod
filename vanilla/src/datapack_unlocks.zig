const std = @import("std");
const datapacks = @import("datapacks");
const game_data = @import("game_data");
const recipes = @import("recipes.zig");
const unlocks = @import("recipe_unlocks.zig");
const Format = @import("datapack_formats.zig").Format;
const Criterion = unlocks.CriterionDefinition;
const Predicate = unlocks.Predicate;
const Inventory = unlocks.Inventory;
const Range = unlocks.Range;
pub const Options = struct { baseline: bool = false, recipes: ?*const recipes.Prepared = null };

pub fn decode(allocator: std.mem.Allocator, temporary: std.mem.Allocator, resources: *const datapacks.Resources, options: Options) ![]const unlocks.Definition {
    const table = options.recipes;
    var names: std.StringHashMapUnmanaged(u32) = .empty;
    if (table) |supported| for (supported.book, 0..) |entry, index| try names.put(temporary, entry.name, @intCast(index));
    var declarations: std.ArrayList(unlocks.Definition) = .empty;
    for (resources.directory("advancement")) |resource_index| {
        const resource = resources.entries[resource_index];
        const format = try Format.select(resource.format);
        const colon = std.mem.indexOfScalar(u8, resource.name, ':').?;
        const advancement_name = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ resource.name[0..colon], resource.name[colon + 1 + "advancement/".len .. resource.name.len - 5] });
        const parsed = try std.json.parseFromSlice(std.json.Value, temporary, resource.bytes, .{});
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return error.InvalidRecipeAdvancement;
        if (!options.baseline and root.object.contains("display")) return error.UnsupportedAdvancementDisplay;
        const rewards = root.object.get("rewards") orelse {
            if (options.baseline) continue;
            return error.UnsupportedAdvancement;
        };
        if (rewards != .object) return error.InvalidRecipeAdvancement;
        if (!options.baseline) for (rewards.object.keys()) |key| {
            if (!std.mem.eql(u8, key, "recipes")) return error.UnsupportedAdvancementReward;
        };
        const rewarded = rewards.object.get("recipes") orelse {
            if (options.baseline) continue;
            return error.UnsupportedAdvancement;
        };
        if (rewarded != .array) return error.InvalidRecipeAdvancement;
        var outputs: std.ArrayList([]const u8) = .empty;
        for (rewarded.array.items) |name| {
            if (name != .string) return error.InvalidRecipeAdvancement;
            const recipe_name = try datapacks.identifier(allocator, name.string);
            if (table != null and !names.contains(recipe_name)) continue;
            try outputs.append(temporary, recipe_name);
        }
        if (outputs.items.len == 0) {
            if (options.baseline) continue;
            return error.UnsupportedAdvancement;
        }
        const conditions = root.object.get("criteria") orelse return error.InvalidRecipeAdvancement;
        if (conditions != .object or conditions.object.count() == 0) return error.InvalidRecipeAdvancement;
        var criteria: std.ArrayList(Criterion) = .empty;
        var local: std.StringHashMapUnmanaged(u32) = .empty;
        var iterator = conditions.object.iterator();
        while (iterator.next()) |condition| {
            const json = condition.value_ptr.*;
            if (json != .object) return error.InvalidRecipeAdvancement;
            const trigger = try text(json, "trigger");
            const properties: std.json.Value = json.object.get("conditions") orelse .{ .object = .empty };
            if (properties != .object) return error.InvalidRecipeAdvancement;
            if (properties.object.contains("player")) return error.UnsupportedRecipeUnlockPredicate;
            const id: u32 = @intCast(criteria.items.len);
            try local.put(temporary, condition.key_ptr.*, id);
            var criterion: Criterion = .{ .name = condition.key_ptr.*, .trigger = .impossible };
            if (std.mem.eql(u8, trigger, "minecraft:inventory_changed")) {
                const items = properties.object.get("items");
                const values: []const std.json.Value = if (items) |value| if (value == .array) value.array.items else return error.InvalidRecipeAdvancement else &.{};
                const predicates = try allocator.alloc(Predicate, values.len);
                for (values, predicates) |value, *predicate| {
                    if (value != .object) return error.InvalidRecipeAdvancement;
                    var actual: Predicate = .{};
                    if (value.object.get("items")) |choices| {
                        if (choices != .string and choices != .array) return error.InvalidRecipeAdvancement;
                        const alternatives: []const std.json.Value = if (choices == .array) choices.array.items else &.{choices};
                        const selected = try allocator.alloc([]const u8, alternatives.len);
                        for (alternatives, selected) |choice, *name| {
                            if (choice != .string) return error.InvalidRecipeAdvancement;
                            const tag = std.mem.startsWith(u8, choice.string, "#");
                            const resolved_name = try datapacks.identifier(allocator, choice.string[@intFromBool(tag)..]);
                            name.* = if (tag) try std.fmt.allocPrint(allocator, "#{s}", .{resolved_name}) else resolved_name;
                        }
                        actual.choices = selected;
                    }
                    if (value.object.get("count")) |count| actual.count = try range(count);
                    if (value.object.get("components")) |components| actual.components = try format.components(allocator, components);
                    if (value.object.contains("predicates")) return error.UnsupportedRecipeUnlockPredicate;
                    predicate.* = actual;
                }
                var inventory: Inventory = .{ .items = predicates };
                if (properties.object.get("slots")) |slots| {
                    if (slots != .object) return error.InvalidRecipeAdvancement;
                    if (slots.object.get("occupied")) |value| inventory.occupied = try range(value);
                    if (slots.object.get("empty")) |value| inventory.empty = try range(value);
                    if (slots.object.get("full")) |value| inventory.full = try range(value);
                }
                criterion.trigger = .{ .inventory = inventory };
            } else if (std.mem.eql(u8, trigger, "minecraft:tick")) {
                criterion.trigger = .tick;
            } else if (std.mem.eql(u8, trigger, "minecraft:enter_block")) {
                const name = try text(properties, "block");
                const id_block = for (game_data.registry.blocks, 0..) |_, index| {
                    const state = game_data.registry.blocks[index].default_state;
                    const state_name = game_data.registry.blockStateName(@intCast(state)).?;
                    const end = std.mem.indexOfScalar(u8, state_name, '[') orelse state_name.len;
                    if (std.mem.eql(u8, state_name[0..end], name)) break index;
                } else return error.UnknownRecipeUnlockBlock;
                if (properties.object.contains("state")) return error.UnsupportedRecipeUnlockPredicate;
                criterion.trigger = .{ .block = @intCast(id_block) };
            } else if (std.mem.eql(u8, trigger, "minecraft:recipe_unlocked")) {
                const name = try text(properties, "recipe");
                if (table == null or names.contains(try datapacks.identifier(temporary, name))) criterion.trigger = .{ .recipe = try datapacks.identifier(allocator, name) };
            } else if (!std.mem.eql(u8, trigger, "minecraft:impossible")) return error.UnsupportedRecipeUnlockTrigger;
            try criteria.append(temporary, criterion);
        }
        var groups: std.ArrayList([]const u32) = .empty;
        if (root.object.get("requirements")) |requirements| {
            if (requirements != .array or requirements.array.items.len == 0) return error.InvalidRecipeAdvancement;
            for (requirements.array.items) |requirement| {
                if (requirement != .array or requirement.array.items.len == 0) return error.InvalidRecipeAdvancement;
                const values = try allocator.alloc(u32, requirement.array.items.len);
                for (requirement.array.items, values) |value, *id| {
                    if (value != .string) return error.InvalidRecipeAdvancement;
                    id.* = local.get(value.string) orelse return error.InvalidRecipeAdvancement;
                }
                try groups.append(temporary, values);
            }
        } else {
            var ids = local.valueIterator();
            while (ids.next()) |id| {
                const values = try allocator.alloc(u32, 1);
                values[0] = id.*;
                try groups.append(temporary, values);
            }
        }
        try declarations.append(temporary, .{ .name = advancement_name, .criteria = try allocator.dupe(Criterion, criteria.items), .requirements = try allocator.dupe([]const u32, groups.items), .recipes = try allocator.dupe([]const u8, outputs.items) });
    }
    return allocator.dupe(unlocks.Definition, declarations.items);
}

fn text(value: std.json.Value, key: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidRecipeAdvancement;
    const field = value.object.get(key) orelse return error.InvalidRecipeAdvancement;
    return if (field == .string) field.string else error.InvalidRecipeAdvancement;
}
fn range(value: std.json.Value) !Range {
    var result: Range = .{};
    if (value == .integer) {
        const count = std.math.cast(u16, value.integer) orelse return error.InvalidRecipeAdvancement;
        return .{ .minimum = count, .maximum = count };
    }
    if (value != .object) return error.InvalidRecipeAdvancement;
    if (value.object.get("min")) |minimum| {
        if (minimum != .integer) return error.InvalidRecipeAdvancement;
        result.minimum = std.math.cast(u16, minimum.integer) orelse return error.InvalidRecipeAdvancement;
    }
    if (value.object.get("max")) |maximum| {
        if (maximum != .integer) return error.InvalidRecipeAdvancement;
        result.maximum = std.math.cast(u16, maximum.integer) orelse return error.InvalidRecipeAdvancement;
    }
    if (result.minimum > result.maximum) return error.InvalidRecipeAdvancement;
    return result;
}
