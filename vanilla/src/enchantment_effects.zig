const behavior = @import("behavior.zig");
const minecraft = @import("minecraft_model");
const Player = @import("player_state.zig").Player;
const std = @import("std");
const Registries = @import("content_registries.zig").Registries;
const Enchantments = @import("enchantments.zig").Enchantments;
const item_data = @import("item_data.zig");
const Tags = @import("content_tags.zig").Tags;
const ids = @import("content_ids.zig");
const item_actions = @import("item_actions.zig");

pub const Slots = packed struct(u8) {
    mainhand: bool = false,
    offhand: bool = false,
    head: bool = false,
    chest: bool = false,
    legs: bool = false,
    feet: bool = false,
    body: bool = false,
    saddle: bool = false,

    pub fn contains(self: Slots, slot: u3) bool {
        return @as(u8, @bitCast(self)) & (@as(u8, 1) << slot) != 0;
    }
    pub fn any(self: Slots) bool {
        return @as(u8, @bitCast(self)) != 0;
    }
};
pub const Channel = enum { repair, block_experience, item_damage, damage_protection };
pub const Operation = enum { add_value, add_multiplied_base, add_multiplied_total };
pub const Attribute = struct { id: []const u8, attribute: []const u8, amount: LevelValue, operation: Operation };
pub const DamageSource = struct { registry: *const Registries.Registry, id: u32 };
pub const DamageTag = struct { id: []const u8, expected: bool };
pub const Condition = union(enum) {
    all: []const Condition,
    any: []const Condition,
    inverted: *const Condition,
    items: []const u32,
    item_tag: []const u8,
    damage_tags: []const DamageTag,

    fn matches(self: Condition, request: *const Request) bool {
        return switch (self) {
            .all => |terms| for (terms) |term| {
                if (!term.matches(request)) break false;
            } else true,
            .any => |terms| for (terms) |term| {
                if (term.matches(request)) break true;
            } else false,
            .inverted => |term| !term.matches(request),
            .items => |items| std.mem.indexOfScalar(u32, items, request.item.kind) != null,
            .item_tag => |name| if (request.item_tags) |tags| if (tags.find(name)) |tag| tags.contains(tag, request.item.kind) else false else false,
            .damage_tags => |tags| for (tags) |tag| {
                var found = if (request.damage_source) |source| if (source.registry.tags.find(tag.id)) |id| source.registry.tags.contains(id, source.id) else false else false;
                for (request.damage_tags) |name| if (std.mem.eql(u8, name, tag.id)) {
                    found = true;
                    break;
                };
                if (found != tag.expected) break false;
            } else true,
        };
    }
};
pub const Location = struct { world: u32, position: minecraft.Position };
pub const Request = struct {
    item: item_data.View,
    slot: u3,
    amount: f32,
    channel: Channel,
    random: std.Random,
    player: ?u128 = null,
    actor: ?*const Player = null,
    location: ?Location = null,
    scratch: *std.heap.FixedBufferAllocator,
    item_tags: ?*const Tags = null,
    damage_tags: []const []const u8 = &.{},
    damage_source: ?DamageSource = null,
};
pub const Context = struct {
    item: item_data.View,
    slot: u3,
    level: u32,
    input: f32,
    channel: Channel,
    random: std.Random,
    player: ?u128,
    actor: ?*const Player,
    location: ?Location,
    scratch: *std.heap.FixedBufferAllocator,
    damage_tags: []const []const u8,
    damage_source: ?DamageSource,
};
pub const Binding = behavior.Binding(Context, f32);
pub const Handler = Binding.Handler;
pub const UseContext = struct { action: *const item_actions.Context, level: u32 };
pub const UseBinding = behavior.Binding(UseContext, item_actions.Result);
pub const UseHandler = UseBinding.Handler;

pub const LevelValue = union(enum) {
    constant: f32,
    linear: struct { base: f32, per_level: f32 },
    squared: struct { added: f32 },
    fraction: struct { numerator: *const LevelValue, denominator: *const LevelValue },
    clamped: struct { value: *const LevelValue, minimum: f32, maximum: f32 },
    lookup: struct { values: []const f32, fallback: *const LevelValue },

    fn validate(self: LevelValue, depth: usize) anyerror!void {
        if (depth >= 64) return error.InvalidEnchantmentValue;
        switch (self) {
            .constant => |value| if (!std.math.isFinite(value)) {
                return error.InvalidEnchantmentValue;
            },
            .linear => |value| if (!std.math.isFinite(value.base) or !std.math.isFinite(value.per_level)) {
                return error.InvalidEnchantmentValue;
            },
            .squared => |value| if (!std.math.isFinite(value.added)) {
                return error.InvalidEnchantmentValue;
            },
            .fraction => |value| {
                try value.numerator.validate(depth + 1);
                try value.denominator.validate(depth + 1);
            },
            .clamped => |value| {
                if (!std.math.isFinite(value.minimum) or !std.math.isFinite(value.maximum) or value.minimum > value.maximum) return error.InvalidEnchantmentValue;
                try value.value.validate(depth + 1);
            },
            .lookup => |value| {
                for (value.values) |entry| if (!std.math.isFinite(entry)) {
                    return error.InvalidEnchantmentValue;
                };
                try value.fallback.validate(depth + 1);
            },
        }
    }

    pub fn evaluate(self: LevelValue, level: u32) f32 {
        return switch (self) {
            .constant => |value| value,
            .linear => |value| value.base + value.per_level * @as(f32, @floatFromInt(@as(i64, level) - 1)),
            .squared => |value| @as(f32, @floatFromInt(level)) * @as(f32, @floatFromInt(level)) + value.added,
            .fraction => |value| value.numerator.evaluate(level) / value.denominator.evaluate(level),
            .clamped => |value| std.math.clamp(value.value.evaluate(level), value.minimum, value.maximum),
            .lookup => |value| if (level > 0 and level <= value.values.len) value.values[level - 1] else value.fallback.evaluate(level),
        };
    }
};

pub const Effect = union(enum) {
    add: LevelValue,
    multiply: LevelValue,
    set: LevelValue,
    all: []const Effect,
    remove_binomial: LevelValue,
    custom: Binding,
    conditional: struct { condition: Condition, effect: *const Effect },

    fn validate(self: Effect, depth: usize) anyerror!void {
        if (depth >= 64) return error.InvalidEnchantmentEffect;
        switch (self) {
            .add, .multiply, .set, .remove_binomial => |value| try value.validate(depth + 1),
            .all => |effects| for (effects) |effect| try effect.validate(depth + 1),
            .conditional => |value| try value.effect.validate(depth + 1),
            .custom => {},
        }
    }

    fn apply(self: Effect, input: f32, level: u32, request: *const Request) anyerror!f32 {
        const random = request.random;
        return switch (self) {
            .conditional => |value| if (value.condition.matches(request)) try value.effect.apply(input, level, request) else input,
            .add => |value| input + value.evaluate(level),
            .multiply => |value| input * value.evaluate(level),
            .set => |value| value.evaluate(level),
            .all => |values| blk: {
                var result = input;
                for (values) |value| result = try value.apply(result, level, request);
                break :blk result;
            },
            .custom => |callback| blk: {
                const value = try callback.call(&.{
                    .item = request.item,
                    .slot = request.slot,
                    .level = level,
                    .input = input,
                    .channel = request.channel,
                    .random = random,
                    .player = request.player,
                    .actor = request.actor,
                    .location = request.location,
                    .scratch = request.scratch,
                    .damage_tags = request.damage_tags,
                    .damage_source = request.damage_source,
                });
                if (std.math.isNan(value)) return error.InvalidEnchantmentEffect;
                break :blk value;
            },
            .remove_binomial => |chance| blk: {
                var result: f32 = 0;
                const probability = chance.evaluate(level);
                if (!std.math.isFinite(probability) or probability < 0 or probability > 1) return error.InvalidEnchantmentEffect;
                var index: i32 = 0;
                while (@as(f32, @floatFromInt(index)) < input and index < std.math.maxInt(i32)) : (index += 1) {
                    if (random.float(f32) >= probability) result += 1;
                }
                break :blk result;
            },
        };
    }
};

pub const Effects = struct {
    pub const Definition = struct {
        slots: Slots,
        repair: []const Effect = &.{},
        block_experience: []const Effect = &.{},
        item_damage: []const Effect = &.{},
        damage_protection: []const Effect = &.{},
        attributes: []const Attribute = &.{},
        prevent_armor_change: bool = false,
        prevent_equipment_drop: bool = false,
        on_use: []const UseBinding = &.{},
    };
    registry: *const Registries.Registry,
    values: []const Definition,
    attribute_count: usize = 0,

    pub const Entry = struct { name: []const u8, definition: Definition };
    pub fn prepare(allocator: std.mem.Allocator, registries: *const Registries, definitions: []const Entry) !Effects {
        const registry = registries.get("minecraft:enchantment") orelse return error.MissingEnchantmentRegistry;
        const values = try allocator.alloc(Definition, registry.entries.len);
        @memset(values, .{ .slots = .{} });
        for (definitions) |entry| {
            const definition = entry.definition;
            inline for (.{ "repair", "block_experience", "item_damage", "damage_protection" }) |channel| {
                for (@field(definition, channel)) |effect| try effect.validate(0);
            }
            for (definition.attributes, 0..) |modifier, index| {
                if (!ids.validName(modifier.id) or !ids.validName(modifier.attribute)) return error.InvalidEnchantmentAttribute;
                try modifier.amount.validate(0);
                for (definition.attributes[0..index]) |previous| if (std.mem.eql(u8, previous.id, modifier.id) and std.mem.eql(u8, previous.attribute, modifier.attribute)) return error.DuplicateEnchantmentAttribute;
            }
            values[registry.id(entry.name) orelse return error.UnknownEnchantment] = definition;
        }
        var attribute_count: usize = 0;
        for (values) |value| attribute_count = try std.math.add(usize, attribute_count, value.attributes.len);
        return .{ .registry = registry, .values = values, .attribute_count = attribute_count };
    }

    pub fn hasRepair(self: *const Effects, item: item_data.View, slot: u3) !bool {
        var entries = try Enchantments.Iterator.init(item.value(.enchantments) orelse return false);
        while (try entries.next()) |entry| {
            const index = self.registry.id(entry.name) orelse continue;
            const definition = self.values[index];
            if (entry.level > 0 and definition.slots.contains(slot) and definition.repair.len > 0) return true;
        }
        return false;
    }

    pub fn modify(self: *const Effects, request: Request) !i32 {
        const value = try self.modifyFloat(request);
        if (value >= 2147483648) return std.math.maxInt(i32);
        if (value <= -2147483648) return std.math.minInt(i32);
        return @intFromFloat(value);
    }

    pub fn modifyFloat(self: *const Effects, request: Request) !f32 {
        std.debug.assert(std.math.isFinite(request.amount));
        const start = request.scratch.end_index;
        defer request.scratch.end_index = start;
        var entries = try Enchantments.Iterator.init(request.item.value(.enchantments) orelse return request.amount);
        var value = request.amount;
        while (try entries.next()) |entry| {
            const index = self.registry.id(entry.name) orelse continue;
            const definition = self.values[index];
            if (entry.level == 0 or !definition.slots.contains(request.slot)) continue;
            const effects = switch (request.channel) {
                .repair => definition.repair,
                .block_experience => definition.block_experience,
                .item_damage => definition.item_damage,
                .damage_protection => definition.damage_protection,
            };
            for (effects) |effect| value = try effect.apply(value, entry.level, &request);
        }
        if (!std.math.isFinite(value)) return error.InvalidEnchantmentEffect;
        return value;
    }

    pub fn use(self: *const Effects, context: *const item_actions.Context) !item_actions.Result {
        const start = context.scratch.end_index;
        defer context.scratch.end_index = start;
        var entries = try Enchantments.Iterator.init(context.item.value(.enchantments) orelse return .pass);
        const slot: u3 = if (context.hand == .main) 0 else 1;
        while (try entries.next()) |entry| {
            const index = self.registry.id(entry.name) orelse continue;
            const definition = self.values[index];
            if (entry.level == 0 or !definition.slots.contains(slot)) continue;
            for (definition.on_use) |callback| {
                defer context.scratch.end_index = start;
                const applied = try callback.call(&.{ .action = context, .level = entry.level });
                if (applied != .pass) return applied;
            }
        }
        return .pass;
    }

    pub fn prevents(self: *const Effects, item: item_data.View, slot: u3, action: enum { armor_change, equipment_drop }) !bool {
        var entries = try Enchantments.Iterator.init(item.value(.enchantments) orelse return false);
        while (try entries.next()) |entry| {
            const index = self.registry.id(entry.name) orelse continue;
            const definition = self.values[index];
            if (entry.level == 0 or !definition.slots.contains(slot)) continue;
            if (switch (action) {
                .armor_change => definition.prevent_armor_change,
                .equipment_drop => definition.prevent_equipment_drop,
            }) return true;
        }
        return false;
    }
};
