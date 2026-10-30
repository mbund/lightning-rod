const std = @import("std");
const inventories = @import("inventories");
const recipes = @import("recipes.zig");
const Items = @import("items.zig").Items;
const assert = std.debug.assert;

pub const Result = enum { placed, missing, blocked };
const Supply = struct { stack: inventories.Stack, kind: u32, count: u16, limit: u16 };

pub fn place(items: *Items, table: *const recipes.BookTable, recipe: *const recipes.BookEntry, stacks: []?inventories.Stack, grid: []const usize, width: usize, inventory_begin: usize, all: bool) !Result {
    assert(stacks.len <= 92 and inventory_begin + 36 <= stacks.len);
    assert((width == 1 and grid.len == 1) or ((width == 2 or width == 3) and grid.len == width * width));
    if ((recipe.furnace and width != 1) or (!recipe.furnace and width == 1) or recipe.width > width or recipe.height > width or recipe.ingredients.len > grid.len) return .blocked;
    var working: [92]?inventories.Stack = undefined;
    @memcpy(working[0..stacks.len], stacks);
    const next = working[0..stacks.len];
    var targets: [9]usize = undefined;
    var ingredients: [9]recipes.BookIngredient = undefined;
    var length: usize = 0;
    for (recipe.ingredients, 0..) |ingredient, index| {
        if (!ingredient.ingredient.required and ingredient.ingredient.count == 0) continue;
        const target = if (recipe.width == 0) index else (index / recipe.width + (width - recipe.height) / 2) * width + index % recipe.width + (width - recipe.width) / 2;
        targets[length] = grid[target];
        ingredients[length] = ingredient;
        length += 1;
    }
    if (length == 0) return .blocked;
    var current_minimum: u16 = 99;
    var current_matches = true;
    for (grid) |at| {
        const ingredient = for (targets[0..length], ingredients[0..length]) |target, value| {
            if (target == at) break value;
        } else null;
        if (ingredient) |value| {
            if (stacks[at]) |stack| {
                current_matches = current_matches and try accepts(items, table, value, stack);
                current_minimum = @min(current_minimum, stack.count);
            } else current_matches = false;
        } else if (stacks[at] != null) current_matches = false;
    }
    for (grid) |at| {
        const stack = next[at] orelse continue;
        var remaining = stack.count;
        const limit = try items.stackLimit(stack);
        for (0..2) |pass| for (next[inventory_begin..][0..36]) |*destination| {
            if (remaining == 0) break;
            const previous = if (destination.*) |value| value.count else 0;
            if (pass == 0) {
                if (destination.* == null or !inventories.Stack.sameItem(stack, destination.*.?)) continue;
            } else if (destination.* != null) continue;
            const amount = @min(remaining, limit -| previous);
            if (amount == 0) continue;
            destination.* = .{ .item = stack.item, .count = previous + amount };
            remaining -= amount;
        };
        if (remaining != 0) return .blocked;
        next[at] = null;
    }
    var supplies: [36]Supply = undefined;
    var supply_count: usize = 0;
    for (next[inventory_begin..][0..36]) |entry| {
        const stack = entry orelse continue;
        const existing = for (supplies[0..supply_count]) |*supply| {
            if (inventories.Stack.sameItem(stack, supply.stack)) break supply;
        } else null;
        if (existing) |supply| {
            supply.count += stack.count;
        } else {
            supplies[supply_count] = .{ .stack = stack, .kind = try items.kind(stack), .count = stack.count, .limit = try items.stackLimit(stack) };
            supply_count += 1;
        }
    }
    var edges: [9]u64 = @splat(0);
    for (ingredients[0..length], 0..) |ingredient, index| for (supplies[0..supply_count], 0..) |supply, candidate| {
        const choices = table.alternatives[ingredient.ingredient.offset..][0..ingredient.ingredient.count];
        if (std.mem.indexOfScalar(u32, choices, supply.kind) == null) continue;
        if (ingredient.components.len != 0 and !try accepts(items, table, ingredient, supply.stack)) continue;
        edges[index] |= @as(u64, 1) << @intCast(candidate);
    };
    var assignment: [9]usize = undefined;
    if (!assign(edges[0..length], supplies[0..supply_count], 1, &assignment)) {
        @memcpy(stacks, next);
        return .missing;
    }
    var amount: u16 = if (current_matches and !all) current_minimum + 1 else 1;
    if (all) {
        var low: u16 = 1;
        var high: u16 = 99;
        while (low < high) {
            const middle = low + (high - low + 1) / 2;
            if (assign(edges[0..length], supplies[0..supply_count], middle, &assignment)) low = middle else high = middle - 1;
        }
        amount = low;
    }
    if (!assign(edges[0..length], supplies[0..supply_count], amount, &assignment)) return .blocked;
    for (targets[0..length], assignment[0..length]) |target, source| {
        const stack = supplies[source].stack;
        var remaining = amount;
        for (next[inventory_begin..][0..36]) |*entry| {
            const held = entry.* orelse continue;
            if (!inventories.Stack.sameItem(stack, held)) continue;
            const moved = @min(held.count, remaining);
            entry.* = if (moved == held.count) null else .{ .item = held.item, .count = held.count - moved };
            remaining -= moved;
            if (remaining == 0) break;
        }
        assert(remaining == 0 and next[target] == null);
        next[target] = .{ .item = stack.item, .count = amount };
    }
    @memcpy(stacks, next);
    return .placed;
}

fn accepts(items: *Items, table: *const recipes.BookTable, ingredient: recipes.BookIngredient, stack: inventories.Stack) !bool {
    const choices = table.alternatives[ingredient.ingredient.offset..][0..ingredient.ingredient.count];
    if (std.mem.indexOfScalar(u32, choices, try items.kind(stack)) == null) return false;
    if (ingredient.components.len == 0) return true;
    const prepared = try items.acquire(stack);
    defer prepared.release();
    for (ingredient.components) |component| {
        const actual = prepared.view.get(component.key) orelse return false;
        if ((actual.value == null) != (component.value == null)) return false;
        if (component.value) |value| if (!std.mem.eql(u8, value, actual.value.?)) return false;
    }
    return true;
}

fn assign(edges: []const u64, supplies: []const Supply, amount: u16, assignment: *[9]usize) bool {
    var counts: [36]u16 = @splat(0);
    var assigned: [9]?usize = @splat(null);
    for (edges, 0..) |_, index| {
        var visited: u64 = 0;
        if (!augment(edges, supplies, amount, index, &visited, &counts, &assigned)) return false;
    }
    for (assigned[0..edges.len], assignment[0..edges.len]) |value, *target| target.* = value.?;
    return true;
}

fn augment(edges: []const u64, supplies: []const Supply, amount: u16, input: usize, visited: *u64, counts: *[36]u16, assigned: *[9]?usize) bool {
    var candidates = edges[input] & ~visited.*;
    while (candidates != 0) {
        const candidate: usize = @intCast(@ctz(candidates));
        const mask = @as(u64, 1) << @intCast(candidate);
        candidates &= ~mask;
        if (visited.* & mask != 0) continue;
        if (amount > supplies[candidate].limit) continue;
        visited.* |= mask;
        if (counts[candidate] < supplies[candidate].count / amount) {
            counts[candidate] += 1;
            assigned[input] = candidate;
            return true;
        }
        for (assigned[0..edges.len], 0..) |previous, index| {
            if (previous == null or previous.? != candidate) continue;
            if (augment(edges, supplies, amount, index, visited, counts, assigned)) {
                assigned[input] = candidate;
                return true;
            }
        }
    }
    return false;
}

test "recipe placement assignment handles overlapping ingredients and distinct item identities" {
    const supplies = [_]Supply{ .{ .stack = .{ .item = @splat(1), .count = 1 }, .kind = 0, .count = 1, .limit = 64 }, .{ .stack = .{ .item = @splat(2), .count = 2 }, .kind = 1, .count = 2, .limit = 64 } };
    var assignment: [9]usize = undefined;
    try std.testing.expect(assign(&.{ 3, 1 }, &supplies, 1, &assignment));
    try std.testing.expectEqual(@as(usize, 1), assignment[0]);
    try std.testing.expectEqual(@as(usize, 0), assignment[1]);
    try std.testing.expect(!assign(&.{ 1, 1 }, &supplies, 1, &assignment));
    try std.testing.expect(assign(&.{ 2, 2 }, &supplies, 1, &assignment));
    try std.testing.expect(!assign(&.{ 2, 2 }, &supplies, 2, &assignment));
}
