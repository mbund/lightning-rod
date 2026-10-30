const std = @import("std");
const ids = @import("content_ids.zig");
const Tags = @import("content_tags.zig").Tags;
const game_data = @import("game_data");
const recipes = @import("recipes.zig");

pub const Range = struct {
    minimum: u16 = 0,
    maximum: u16 = std.math.maxInt(u16),
    pub fn contains(self: Range, value: usize) bool {
        return value >= self.minimum and value <= self.maximum;
    }
};
pub const Predicate = struct { choices: []const []const u8 = &.{}, kinds: ?[]const u32 = null, count: Range = .{}, components: []const recipes.Component = &.{} };
pub const Inventory = struct { items: []const Predicate, occupied: Range = .{}, empty: Range = .{}, full: Range = .{} };
pub const Criterion = struct {
    identity: [32]u8,
    trigger: union(enum) { inventory: Inventory, block: u16, tick, recipe: u32, impossible },
};
pub const Rule = struct { identity: [32]u8, requirements: []const []const u32, recipes: []const u32 };
pub const CriterionDefinition = struct {
    name: []const u8,
    trigger: union(enum) { inventory: Inventory, block: u16, tick, recipe: []const u8, impossible },
};
pub const Definition = struct {
    name: []const u8,
    criteria: []const CriterionDefinition,
    requirements: []const []const u32,
    recipes: []const []const u8,
};
pub const Rules = struct {
    criteria: []const Criterion,
    rules: []const Rule,
    by_item: []const []const u32,
    inventory: []const u32,
    blocks: []const u32,
    ticks: []const u32,
    known: []const u32,

    pub fn prepare(allocator: std.mem.Allocator, temporary: std.mem.Allocator, definitions: []const Definition, entries: []const recipes.BookEntry, tags: *const Tags) !Rules {
        var names: std.StringHashMapUnmanaged(u32) = .empty;
        for (entries, 0..) |entry, index| try names.put(temporary, entry.name, @intCast(index));
        var selected: std.StringHashMapUnmanaged(*const Definition) = .empty;
        for (definitions) |*definition| {
            if (!ids.validName(definition.name)) return error.InvalidRecipeAdvancement;
            try selected.put(temporary, definition.name, definition);
        }
        var criteria: std.ArrayList(Criterion) = .empty;
        var rules: std.ArrayList(Rule) = .empty;
        for (definitions) |*definition| {
            if (selected.get(definition.name).? != definition) continue;
            var rewards: std.ArrayList(u32) = .empty;
            // An advancement can remain after its rewarded recipes are removed.
            for (definition.recipes) |name| if (names.get(name)) |index| try rewards.append(temporary, index);
            if (rewards.items.len == 0) continue;
            if (definition.criteria.len == 0 or definition.requirements.len == 0) return error.InvalidRecipeAdvancement;
            var criterion_names: std.StringHashMapUnmanaged(void) = .empty;
            const base: u32 = @intCast(criteria.items.len);
            for (definition.criteria) |source| {
                if (source.name.len == 0 or source.name.len > 1024 or criterion_names.contains(source.name)) return error.InvalidRecipeAdvancement;
                try criterion_names.put(temporary, source.name, {});
                var criterion: Criterion = .{ .identity = undefined, .trigger = .impossible };
                var identity = std.crypto.hash.Blake3.init(.{});
                identity.update(definition.name);
                identity.update(&.{0});
                identity.update(source.name);
                identity.final(&criterion.identity);
                switch (source.trigger) {
                    .inventory => |inventory_value| {
                        var resolved = inventory_value;
                        const predicates = try allocator.dupe(Predicate, inventory_value.items);
                        for (predicates) |*predicate| if (predicate.choices.len > 0) {
                            var kinds: std.ArrayList(u32) = .empty;
                            for (predicate.choices) |name| {
                                if (std.mem.startsWith(u8, name, "#")) {
                                    try kinds.appendSlice(temporary, tags.members(tags.find(name[1..]) orelse return error.UnknownRecipeUnlockTag));
                                } else try kinds.append(temporary, @intCast(game_data.registry.itemId(name) orelse return error.UnknownRecipeUnlockItem));
                            }
                            predicate.kinds = try allocator.dupe(u32, kinds.items);
                        };
                        resolved.items = predicates;
                        criterion.trigger = .{ .inventory = resolved };
                    },
                    .block => |block| criterion.trigger = .{ .block = block },
                    .tick => criterion.trigger = .tick,
                    .recipe => |name| criterion.trigger = if (names.get(name)) |index| .{ .recipe = index } else .impossible,
                    .impossible => {},
                }
                try criteria.append(temporary, criterion);
            }
            const groups = try allocator.alloc([]const u32, definition.requirements.len);
            for (definition.requirements, groups) |source, *group| {
                if (source.len == 0) return error.InvalidRecipeAdvancement;
                const values = try allocator.alloc(u32, source.len);
                for (source, values) |id, *value| {
                    if (id >= definition.criteria.len) return error.InvalidRecipeAdvancement;
                    value.* = try std.math.add(u32, base, id);
                }
                group.* = values;
            }
            var identity: [32]u8 = undefined;
            std.crypto.hash.Blake3.hash(definition.name, &identity, .{});
            try rules.append(temporary, .{ .identity = identity, .requirements = groups, .recipes = try allocator.dupe(u32, rewards.items) });
        }
        const by_item = try temporary.alloc(std.ArrayList(u32), game_data.registry.items.len);
        @memset(by_item, .empty);
        var inventory: std.ArrayList(u32) = .empty;
        var blocks: std.ArrayList(u32) = .empty;
        var ticks: std.ArrayList(u32) = .empty;
        var known: std.ArrayList(u32) = .empty;
        for (criteria.items, 0..) |criterion, index| {
            const id: u32 = @intCast(index);
            switch (criterion.trigger) {
                .inventory => |value| {
                    var general = value.items.len == 0;
                    for (value.items) |predicate| {
                        if (predicate.kinds) |kinds| {
                            for (kinds) |kind| {
                                if (kind >= by_item.len) return error.UnknownRecipeUnlockItem;
                                const list = &by_item[kind];
                                if (list.items.len == 0 or list.items[list.items.len - 1] != id) try list.append(temporary, id);
                            }
                        } else general = true;
                    }
                    if (general) try inventory.append(temporary, id);
                },
                .block => try blocks.append(temporary, id),
                .tick => try ticks.append(temporary, id),
                .recipe => try known.append(temporary, id),
                .impossible => {},
            }
        }
        const indexed = try allocator.alloc([]const u32, by_item.len);
        for (by_item, indexed) |list, *values| values.* = try allocator.dupe(u32, list.items);
        return .{ .criteria = try allocator.dupe(Criterion, criteria.items), .rules = try allocator.dupe(Rule, rules.items), .by_item = indexed, .inventory = try allocator.dupe(u32, inventory.items), .blocks = try allocator.dupe(u32, blocks.items), .ticks = try allocator.dupe(u32, ticks.items), .known = try allocator.dupe(u32, known.items) };
    }
};
