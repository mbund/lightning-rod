const Format = @import("datapack_formats.zig").Format;
const std = @import("std");
const datapacks = @import("datapacks");
const game_data = @import("game_data");
const loot = @import("loot.zig");
const item_data = @import("item_data.zig");
const handlers = @import("datapack_handlers.zig");
const assert = std.debug.assert;
const Number = loot.Number;
const Condition = loot.ConditionDefinition;
const Function = loot.FunctionDefinition;
const Entry = loot.EntryDefinition;
const Pool = loot.PoolDefinition;
const Table = loot.TableDefinition;
const Offset = loot.Offset;
const Definition = loot.Definition;
const Binding = loot.Binding;
const Stack = loot.Stack;
const Type = handlers.LootType;
const Kind = loot.Kind;
const State = loot.State;
const Tool = loot.ToolDefinition;
const Enchantment = loot.Enchantment;
pub const Compiler = struct {
    allocator: std.mem.Allocator,
    temporary: std.mem.Allocator,
    types: []const Type = &.{},
    format: Format = .v1_21_8,
    offsets: std.ArrayList(Offset) = .empty,

    pub fn decode(self: *Compiler, bytes: []const u8) !*const Table {
        const json = try std.json.parseFromSliceLeaky(std.json.Value, self.temporary, bytes, .{ .allocate = .alloc_always });
        if (json != .object) return error.InvalidLootTable;
        self.offsets = .empty;
        const table_functions = try self.functions(json, 0);
        const pools_json = optionalArray(json, "pools") orelse return error.InvalidLootTable;
        const pools = try self.allocator.alloc(Pool, pools_json.len);
        for (pools_json, pools) |pool, *compiled| {
            const rolls = try number(field(pool, "rolls") orelse .{ .float = 1 });
            if (rolls.maximum() > 1024) return error.LootRollLimit;
            compiled.* = .{ .conditions = try self.conditions(pool, 0), .functions = try self.functions(pool, 0), .entries = try self.entries(optionalArray(pool, "entries") orelse return error.InvalidLootTable, 0), .rolls = rolls };
        }
        const table = try self.allocator.create(Table);
        table.* = .{ .pools = pools, .functions = table_functions, .offsets = try self.allocator.dupe(Offset, self.offsets.items) };
        return table;
    }
    fn entries(self: *Compiler, values: []const std.json.Value, depth: usize) anyerror![]const Entry {
        if (depth >= 64) return error.LootDepthLimit;
        const result = try self.allocator.alloc(Entry, values.len);
        for (values, result) |json, *entry| {
            const kind = try text(json, "type");
            entry.* = .{ .conditions = try self.conditions(json, depth + 1), .functions = try self.functions(json, depth + 1), .kind = .empty };
            if (field(json, "weight")) |weight| {
                if (weight != .integer or weight.integer < 0 or weight.integer > std.math.maxInt(u32)) return error.InvalidLootWeight;
                entry.weight = @intCast(weight.integer);
            }
            if (std.mem.eql(u8, kind, "minecraft:item")) {
                entry.kind = .{ .item = try self.item(try text(json, "name")) };
            } else if (std.mem.eql(u8, kind, "minecraft:alternatives") or std.mem.eql(u8, kind, "minecraft:group") or std.mem.eql(u8, kind, "minecraft:sequence")) {
                const children = try self.entries(optionalArray(json, "children") orelse return error.InvalidLootEntry, depth + 1);
                entry.kind = if (std.mem.eql(u8, kind, "minecraft:alternatives")) .{ .alternatives = children } else if (std.mem.eql(u8, kind, "minecraft:group")) .{ .group = children } else .{ .sequence = children };
            } else if (std.mem.eql(u8, kind, "minecraft:tag")) {
                const name = try datapacks.identifier(self.temporary, try text(json, "name"));
                entry.kind = .{ .tag = .{ .name = name, .expand = try boolean(json, "expand", false) } };
            } else if (std.mem.eql(u8, kind, "minecraft:loot_table")) {
                entry.kind = .{ .table = try datapacks.identifier(self.allocator, try text(json, "value")) };
            } else if (std.mem.eql(u8, kind, "minecraft:dynamic")) {
                entry.kind = .dynamic;
            } else if (!std.mem.eql(u8, kind, "minecraft:empty")) {
                entry.kind = .{ .custom = (try self.extension(json, .entry) orelse return error.UnsupportedLootEntry).entry };
            }
        }
        return result;
    }
    fn conditions(self: *Compiler, json: std.json.Value, depth: usize) anyerror![]const Condition {
        const values = optionalArray(json, "conditions") orelse return error.InvalidLootCondition;
        return self.conditionArray(values, depth);
    }
    fn conditionArray(self: *Compiler, values: []const std.json.Value, depth: usize) anyerror![]const Condition {
        if (depth >= 64) return error.LootDepthLimit;
        const result = try self.allocator.alloc(Condition, values.len);
        for (values, result) |json, *compiled| compiled.* = try self.condition(json, depth + 1);
        return result;
    }
    fn condition(self: *Compiler, json: std.json.Value, depth: usize) anyerror!Condition {
        if (depth >= 64) return error.LootDepthLimit;
        const kind = try text(json, "condition");
        if (std.mem.eql(u8, kind, "minecraft:survives_explosion")) return .explosion;
        if (std.mem.eql(u8, kind, "minecraft:any_of") or std.mem.eql(u8, kind, "minecraft:all_of")) {
            const terms = try self.conditionArray(optionalArray(json, "terms") orelse return error.InvalidLootCondition, depth + 1);
            return if (std.mem.eql(u8, kind, "minecraft:any_of")) .{ .any = terms } else .{ .all = terms };
        }
        if (std.mem.eql(u8, kind, "minecraft:inverted")) {
            const term = try self.allocator.create(Condition);
            term.* = try self.condition(field(json, "term") orelse return error.InvalidLootCondition, depth + 1);
            return .{ .inverted = term };
        }
        if (std.mem.eql(u8, kind, "minecraft:block_state_property")) return .{ .state = try self.state(try text(json, "block"), field(json, "properties")) };
        if (std.mem.eql(u8, kind, "minecraft:match_tool")) {
            const predicate = field(json, "predicate") orelse return error.InvalidLootCondition;
            var tool: Tool = .{};
            if (field(predicate, "items")) |items| {
                const values: []const std.json.Value = if (items == .array) items.array.items else &.{items};
                const choices = try self.allocator.alloc([]const u8, values.len);
                for (values, choices) |value, *choice| {
                    if (value != .string) return error.InvalidLootPredicate;
                    const is_tag = std.mem.startsWith(u8, value.string, "#");
                    const name = try datapacks.identifier(self.allocator, value.string[@intFromBool(is_tag)..]);
                    choice.* = if (is_tag) try std.fmt.allocPrint(self.allocator, "#{s}", .{name}) else name;
                }
                tool.choices = choices;
            }
            if (field(predicate, "components")) |components| tool.components = try self.format.components(self.allocator, components);
            if (field(predicate, "predicates")) |predicates| {
                if (predicates != .object) return error.InvalidLootPredicate;
                var iterator = predicates.object.iterator();
                while (iterator.next()) |pair| {
                    if (!std.mem.eql(u8, pair.key_ptr.*, "minecraft:enchantments")) return error.UnsupportedLootPredicate;
                    if (pair.value_ptr.* != .array) return error.InvalidLootPredicate;
                    const enchantments = try self.allocator.alloc(Enchantment, pair.value_ptr.array.items.len);
                    for (pair.value_ptr.array.items, enchantments) |value, *enchantment| {
                        const enchantment_names = field(value, "enchantments") orelse return error.InvalidLootPredicate;
                        enchantment.* = .{ .names = try self.names(enchantment_names) };
                        if (field(value, "levels")) |levels| {
                            if (levels == .integer) {
                                if (levels.integer < 0 or levels.integer > 255) return error.InvalidLootPredicate;
                                enchantment.minimum = @intCast(levels.integer);
                                enchantment.maximum = enchantment.minimum;
                            } else {
                                if (field(levels, "min")) |minimum| enchantment.minimum = try level(minimum);
                                if (field(levels, "max")) |maximum| enchantment.maximum = try level(maximum);
                            }
                        }
                    }
                    tool.enchantments = enchantments;
                }
            }
            return .{ .tool = tool };
        }
        if (std.mem.eql(u8, kind, "minecraft:random_chance")) return .{ .chance = try probability(field(json, "chance") orelse return error.InvalidLootCondition) };
        if (std.mem.eql(u8, kind, "minecraft:table_bonus")) {
            const chances_json = optionalArray(json, "chances") orelse return error.InvalidLootCondition;
            if (chances_json.len == 0) return error.InvalidLootCondition;
            const chances = try self.allocator.alloc(f32, chances_json.len);
            for (chances_json, chances) |chance, *value| value.* = try probability(chance);
            return .{ .table_bonus = .{ .enchantment = try self.allocator.dupe(u8, try text(json, "enchantment")), .chances = chances } };
        }
        if (std.mem.eql(u8, kind, "minecraft:entity_properties")) {
            if (!std.mem.eql(u8, try text(json, "entity"), "this")) return error.UnsupportedLootPredicate;
            const predicate = field(json, "predicate") orelse return error.InvalidLootCondition;
            if (predicate != .object or predicate.object.count() != 0) return error.UnsupportedLootPredicate;
            return .entity;
        }
        if (std.mem.eql(u8, kind, "minecraft:location_check")) {
            const predicate = field(json, "predicate") orelse return error.InvalidLootCondition;
            const block = field(predicate, "block") orelse return error.UnsupportedLootPredicate;
            const blocks = try text(block, "blocks");
            const offset: Offset = .{ .x = try intField(json, "offsetX", 0), .y = try intField(json, "offsetY", 0), .z = try intField(json, "offsetZ", 0) };
            try self.addOffset(offset);
            return .{ .location = .{ .offset = offset, .state = try self.state(blocks, field(block, "state")) } };
        }
        if (try self.extension(json, .condition)) |binding| return .{ .custom = binding.condition };
        return error.UnsupportedLootCondition;
    }
    fn functions(self: *Compiler, json: std.json.Value, depth: usize) anyerror![]const Function {
        if (depth >= 64) return error.LootDepthLimit;
        const values = optionalArray(json, "functions") orelse return error.InvalidLootFunction;
        const result = try self.allocator.alloc(Function, values.len);
        for (values, result) |value, *function| {
            const kind = try text(value, "function");
            function.* = .{ .conditions = try self.conditions(value, depth + 1), .operation = .explosion };
            if (std.mem.eql(u8, kind, "minecraft:set_count")) {
                function.operation = .{ .count = .{ .value = try number(field(value, "count") orelse return error.InvalidLootFunction), .add = try boolean(value, "add", false) } };
            } else if (std.mem.eql(u8, kind, "minecraft:explosion_decay")) {
                function.operation = .explosion;
            } else if (std.mem.eql(u8, kind, "minecraft:limit_count")) {
                const limit = field(value, "limit") orelse return error.InvalidLootFunction;
                function.operation = if (limit == .object) .{ .limit = .{ .minimum = if (field(limit, "min")) |minimum| try number(minimum) else null, .maximum = if (field(limit, "max")) |maximum| try number(maximum) else null } } else .{ .limit = .{ .minimum = try number(limit), .maximum = try number(limit) } };
            } else if (std.mem.eql(u8, kind, "minecraft:apply_bonus")) {
                const formula = try text(value, "formula");
                var bonus: @FieldType(@FieldType(Function, "operation"), "bonus") = .{ .name = try self.allocator.dupe(u8, try text(value, "enchantment")), .formula = undefined };
                const parameters = field(value, "parameters") orelse .null;
                if (std.mem.eql(u8, formula, "minecraft:ore_drops")) bonus.formula = .ore else if (std.mem.eql(u8, formula, "minecraft:uniform_bonus_count")) {
                    bonus.formula = .uniform;
                    const multiplier = try intField(parameters, "bonusMultiplier", 1);
                    if (multiplier < 0 or multiplier > 4096) return error.InvalidLootFunction;
                    bonus.multiplier = @intCast(multiplier);
                } else if (std.mem.eql(u8, formula, "minecraft:binomial_with_bonus_count")) {
                    bonus.formula = .binomial;
                    const extra = try intField(parameters, "extra", 0);
                    if (extra < 0 or extra > 4096) return error.InvalidLootFunction;
                    bonus.extra = @intCast(extra);
                    bonus.probability = try probability(field(parameters, "probability") orelse return error.InvalidLootFunction);
                } else return error.UnsupportedLootFormula;
                function.operation = .{ .bonus = bonus };
            } else if (std.mem.eql(u8, kind, "minecraft:set_components")) {
                function.operation = .{ .components = try self.format.components(self.allocator, field(value, "components") orelse return error.InvalidLootFunction) };
            } else if (std.mem.eql(u8, kind, "minecraft:copy_components")) {
                if (!std.mem.eql(u8, try text(value, "source"), "block_entity")) return error.UnsupportedLootFunction;
                function.operation = .{ .copy_components = .{
                    .include = if (field(value, "include") != null) try self.componentKeys(value, "include") else null,
                    .exclude = try self.componentKeys(value, "exclude"),
                } };
            } else if (std.mem.eql(u8, kind, "minecraft:copy_state")) {
                const block_name = try text(value, "block");
                const block_id = blockId(block_name) orelse return error.UnknownLootBlock;
                const block = game_data.registry.blocks[@intCast(block_id)];
                const properties = optionalArray(value, "properties") orelse return error.InvalidLootFunction;
                if (properties.len > 64) return error.InvalidLootFunction;
                const property_names = try self.temporary.alloc([]const u8, properties.len);
                for (properties, property_names) |property, *name| {
                    if (property != .string) return error.InvalidLootFunction;
                    name.* = property.string;
                }
                std.mem.sort([]const u8, property_names, {}, struct {
                    fn less(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.lessThan(u8, a, b);
                    }
                }.less);
                for (property_names, 0..) |name, index| if (index != 0 and std.mem.eql(u8, property_names[index - 1], name)) return error.InvalidLootFunction;
                const states = try self.allocator.alloc(@typeInfo(@FieldType(@FieldType(Function, "operation"), "copy_state")).pointer.child, @intCast(block.max_state - block.min_state + 1));
                for (states, 0..) |*state_value, index| {
                    const state_id: u16 = @intCast(block.min_state + @as(i32, @intCast(index)));
                    const state_name = game_data.registry.blockStateName(state_id).?;
                    var writer: std.Io.Writer.Allocating = .init(self.allocator);
                    try writeVarint(&writer.writer, @intCast(properties.len));
                    for (property_names) |name| {
                        const property_value = stateProperty(state_name, name) orelse return error.UnknownBlockProperty;
                        try writeString(&writer.writer, name);
                        try writeString(&writer.writer, property_value);
                    }
                    state_value.* = .{ .state = state_id, .value = writer.written() };
                }
                function.operation = .{ .copy_state = states };
            } else {
                function.operation = .{ .custom = (try self.extension(value, .function) orelse return error.UnsupportedLootFunction).function };
            }
        }
        return result;
    }
    fn extension(self: *Compiler, json: std.json.Value, kind: Kind) !?Binding {
        const name = try text(json, switch (kind) {
            .condition => "condition",
            .function => "function",
            .entry => "type",
        });
        for (self.types) |implementation| {
            if (implementation.kind == kind and std.mem.eql(u8, implementation.name, name)) {
                const binding = try implementation.vtable.decode(implementation.context, self.allocator, self.temporary, json);
                assert(std.meta.activeTag(binding) == kind);
                const offsets = switch (binding) {
                    inline else => |handler| handler.offsets,
                };
                for (offsets) |offset| try self.addOffset(offset);
                return binding;
            }
        }
        return null;
    }
    fn componentKeys(self: *Compiler, value: std.json.Value, name: []const u8) ![]const u64 {
        const values = optionalArray(value, name) orelse return error.InvalidLootFunction;
        const keys = try self.allocator.alloc(u64, values.len);
        for (values, keys) |entry, *key| {
            if (entry != .string or !std.mem.startsWith(u8, entry.string, "minecraft:")) return error.InvalidLootFunction;
            key.* = componentKey(entry.string[10..]);
        }
        return keys;
    }
    fn addOffset(self: *Compiler, offset: Offset) !void {
        for (self.offsets.items) |previous| if (std.meta.eql(previous, offset)) return;
        if (self.offsets.items.len == 16) return error.LootContextLimit;
        try self.offsets.append(self.temporary, offset);
    }
    fn names(self: *Compiler, json: std.json.Value) ![]const []const u8 {
        const values = if (json == .array) json.array.items else &[_]std.json.Value{json};
        const result = try self.allocator.alloc([]const u8, values.len);
        for (values, result) |value, *name| {
            if (value != .string) return error.InvalidLootPredicate;
            name.* = try self.allocator.dupe(u8, try datapacks.identifier(self.temporary, value.string));
        }
        return result;
    }
    fn item(self: *Compiler, name: []const u8) !u32 {
        return @intCast(game_data.registry.itemId(try datapacks.identifier(self.temporary, name)) orelse return error.UnknownLootItem);
    }
    fn state(self: *Compiler, name: []const u8, properties: ?std.json.Value) !State {
        const block_id = blockId(name) orelse return error.UnknownLootBlock;
        const block = game_data.registry.blocks[@intCast(block_id)];
        var states: std.ArrayList(u16) = .empty;
        for (@intCast(block.min_state)..@intCast(block.max_state + 1)) |index| {
            const state_name = game_data.registry.blockStateName(@intCast(index)).?;
            var accepted = true;
            if (properties) |object| {
                if (object != .object) return error.InvalidLootPredicate;
                var iterator = object.object.iterator();
                while (iterator.next()) |entry| {
                    const actual = stateProperty(state_name, entry.key_ptr.*) orelse return error.UnknownBlockProperty;
                    const expected = entry.value_ptr.*;
                    if (expected == .string) {
                        accepted = accepted and std.mem.eql(u8, actual, expected.string);
                    } else if (expected == .object) {
                        const numeric = std.fmt.parseInt(i32, actual, 10) catch return error.InvalidBlockProperty;
                        if (field(expected, "min")) |minimum| accepted = accepted and numeric >= try propertyInt(minimum);
                        if (field(expected, "max")) |maximum| accepted = accepted and numeric <= try propertyInt(maximum);
                    } else return error.InvalidLootPredicate;
                }
            }
            if (accepted) try states.append(self.temporary, @intCast(index));
        }
        return .{ .states = try self.allocator.dupe(u16, states.items) };
    }
};
fn stateProperty(state: []const u8, name: []const u8) ?[]const u8 {
    const begin = std.mem.indexOfScalar(u8, state, '[') orelse return null;
    var properties = std.mem.splitScalar(u8, state[begin + 1 .. state.len - 1], ',');
    while (properties.next()) |property| {
        const separator = std.mem.indexOfScalar(u8, property, '=') orelse continue;
        if (std.mem.eql(u8, property[0..separator], name)) return property[separator + 1 ..];
    }
    return null;
}
fn field(json: std.json.Value, name: []const u8) ?std.json.Value {
    return if (json == .object) json.object.get(name) else null;
}
fn optionalArray(json: std.json.Value, name: []const u8) ?[]const std.json.Value {
    const value = field(json, name) orelse return &.{};
    return if (value == .array) value.array.items else null;
}
fn text(json: std.json.Value, name: []const u8) ![]const u8 {
    const value = field(json, name) orelse return error.InvalidLootTable;
    return if (value == .string) value.string else error.InvalidLootTable;
}
fn boolean(json: std.json.Value, name: []const u8, fallback: bool) !bool {
    const value = field(json, name) orelse return fallback;
    return if (value == .bool) value.bool else error.InvalidLootTable;
}
fn intField(json: std.json.Value, name: []const u8, fallback: i32) !i32 {
    const value = field(json, name) orelse return fallback;
    if (value != .integer or value.integer < std.math.minInt(i32) or value.integer > std.math.maxInt(i32)) return error.InvalidLootNumber;
    return @intCast(value.integer);
}
fn propertyInt(json: std.json.Value) !i32 {
    return switch (json) {
        .string => try std.fmt.parseInt(i32, json.string, 10),
        .integer => std.math.cast(i32, json.integer) orelse error.InvalidBlockProperty,
        else => error.InvalidBlockProperty,
    };
}
fn level(json: std.json.Value) !u32 {
    if (json != .integer or json.integer < 0 or json.integer > 255) return error.InvalidLootPredicate;
    return @intCast(json.integer);
}
fn real(json: std.json.Value) !f32 {
    const value: f32 = switch (json) {
        .integer => @floatFromInt(json.integer),
        .float => @floatCast(json.float),
        else => return error.InvalidLootNumber,
    };
    if (!std.math.isFinite(value) or @abs(value) > 1000000) return error.InvalidLootNumber;
    return value;
}
fn probability(json: std.json.Value) !f32 {
    const value = try real(json);
    if (value < 0 or value > 1) return error.InvalidLootNumber;
    return value;
}
fn number(json: std.json.Value) !Number {
    if (json != .object) return .{ .constant = try real(json) };
    const kind = try text(json, "type");
    if (std.mem.eql(u8, kind, "minecraft:constant")) return .{ .constant = try real(field(json, "value") orelse return error.InvalidLootNumber) };
    if (std.mem.eql(u8, kind, "minecraft:uniform")) {
        const minimum = try real(field(json, "min") orelse return error.InvalidLootNumber);
        const maximum = try real(field(json, "max") orelse return error.InvalidLootNumber);
        if (minimum > maximum) return error.InvalidLootNumber;
        return .{ .uniform = .{ .minimum = minimum, .maximum = maximum } };
    }
    if (std.mem.eql(u8, kind, "minecraft:binomial")) {
        const n = try real(field(json, "n") orelse return error.InvalidLootNumber);
        if (n < 0 or n > 4096 or n != @floor(n)) return error.InvalidLootNumber;
        return .{ .binomial = .{ .trials = @intFromFloat(n), .probability = try probability(field(json, "p") orelse return error.InvalidLootNumber) } };
    }
    return error.UnsupportedLootNumber;
}
fn componentKey(name: []const u8) u64 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(name, &digest, .{});
    return std.mem.readInt(u64, digest[0..8], .little);
}
fn blockId(name: []const u8) ?usize {
    for (game_data.registry.blocks, 0..) |block, index| {
        const state = game_data.registry.blockStateName(@intCast(block.default_state)).?;
        if (std.mem.eql(u8, state[0 .. std.mem.indexOfScalar(u8, state, '[') orelse state.len], name)) return index;
    }
    return null;
}

fn writeVarint(writer: *std.Io.Writer, value: i32) !void {
    var bytes: [5]u8 = undefined;
    const rest = try game_data.encoding.write_varint(&bytes, value);
    try writer.writeAll(bytes[0 .. bytes.len - rest.len]);
}
fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    try writeVarint(writer, @intCast(value.len));
    try writer.writeAll(value);
}
