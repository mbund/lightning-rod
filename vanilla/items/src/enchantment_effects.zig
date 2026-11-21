const behavior = @import("vanilla_content").behavior;
const minecraft = @import("minecraft_model");
const Player = @import("players").player_state.Player;
const std = @import("std");
const Registries = @import("vanilla_content").content_registries.Registries;
const Enchantments = @import("enchantments.zig").Enchantments;
const item_data = @import("item_data.zig");
const Tags = @import("vanilla_content").content_tags.Tags;
const ids = @import("vanilla_content").content_ids;
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
pub const Channel = enum { repair, block_experience, item_damage, damage_protection, damage, knockback, armor_effectiveness, smash_damage_per_fallen_block, ammo_use, projectile_count, projectile_spread, projectile_piercing, crossbow_charge_time, trident_return_acceleration, trident_spin_attack_strength };
/// The channels that change a number, by their names in an enchantment's effects.
pub const value_channels = [_][]const u8{ "repair", "block_experience", "item_damage", "damage_protection", "damage", "knockback", "armor_effectiveness", "smash_damage_per_fallen_block", "ammo_use", "projectile_count", "projectile_spread", "projectile_piercing", "crossbow_charge_time", "trident_return_acceleration", "trident_spin_attack_strength" };
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
    /// entity_properties by entity type alone, of the target or of what dealt the damage.
    entity_type: EntityType,
    /// damage_source_properties is_direct: whether the attacker dealt the damage itself.
    direct: bool,
    /// random_chance, by enchantment level.
    chance: LevelValue,
    /// A condition this build cannot test, in vanilla's own enchantments: it never holds.
    unsupported,

    fn matches(self: Condition, request: *const Request, level: u32) bool {
        return switch (self) {
            .all => |terms| for (terms) |term| {
                if (!term.matches(request, level)) break false;
            } else true,
            .any => |terms| for (terms) |term| {
                if (term.matches(request, level)) break true;
            } else false,
            .inverted => |term| !term.matches(request, level),
            .entity_type => |test_| test_.matches(request),
            .direct => |expected| request.direct == expected,
            .chance => |chance| request.random.float(f32) < chance.evaluate(level),
            .unsupported => false,
            .items => |items| std.mem.indexOfScalar(u32, items, request.toolKind()) != null,
            .item_tag => |name| if (request.item_tags) |tags| if (tags.find(name)) |tag| tags.contains(tag, request.toolKind()) else false else false,
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
    /// Whether every enchantment counts whatever slots it names, as runIterationOnItem walks an
    /// item held by nothing in particular.
    any_slot: bool = false,
    /// What match_tool tests instead of the enchanted item: the ammo, for ammo_use.
    tool: ?u32 = null,
    /// The entity type registry, for conditions on entity types.
    entity_types: ?*const Registries.Registry = null,
    /// What is attacked, by entity type.
    target_type: ?u32 = null,
    /// What dealt the damage, by entity type: the attacker, or its projectile.
    direct_type: ?u32 = null,
    /// Whether the attacker dealt the damage itself, rather than through a projectile.
    direct: bool = true,

    fn toolKind(self: *const Request) u32 {
        return self.tool orelse self.item.kind;
    }
};
/// entity_properties naming only a type: one entity type, or a tag of them.
pub const EntityType = struct {
    pub const Subject = enum { this, direct_attacker };
    subject: Subject,
    /// A tag name without its '#', or an entity type name.
    name: []const u8,
    tag: bool,

    fn matches(self: EntityType, request: *const Request) bool {
        const types = request.entity_types orelse return false;
        const kind = (switch (self.subject) {
            .this => request.target_type,
            .direct_attacker => request.direct_type,
        }) orelse return false;
        if (!self.tag) return types.id(self.name) == kind;
        const tag = types.tags.find(self.name) orelse return false;
        return types.tags.contains(tag, kind);
    }
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

/// An enchantment effect that acts on an entity after an attack, as post_attack lists them: which
/// holder's enchantment it is, who it acts on, and what it does.
pub const PostAttack = struct {
    pub const Holder = enum { attacker, victim };
    pub const Affected = enum { attacker, victim, damaging_entity };
    enchanted: Holder,
    affected: Affected,
    effect: EntityEffect,
    condition: ?Condition = null,
};

/// What an entity effect does. Kinds this build lacks compile to `unsupported` for vanilla's own
/// enchantments and are refused from datapacks.
pub const EntityEffect = union(enum) {
    /// Sets the entity alight for a number of seconds.
    ignite: LevelValue,
    damage_entity: struct { damage_type: []const u8, minimum: LevelValue, maximum: LevelValue },
    change_item_damage: LevelValue,
    all: []const EntityEffect,
    unsupported,

    fn consequences(self: EntityEffect, affected: PostAttack.Affected, level: u32, random: std.Random, output: []Consequence, start: usize) !usize {
        var count = start;
        switch (self) {
            .all => |effects| for (effects) |effect| {
                count = try effect.consequences(affected, level, random, output, count);
            },
            .unsupported => {},
            else => {
                if (count == output.len) return error.TooManyAttackConsequences;
                output[count] = .{ .affected = affected, .action = switch (self) {
                    .ignite => |seconds| .{ .ignite_seconds = seconds.evaluate(level) },
                    .damage_entity => |damage| blk: {
                        const minimum = damage.minimum.evaluate(level);
                        const maximum = damage.maximum.evaluate(level);
                        break :blk .{ .damage = .{ .damage_type = damage.damage_type, .amount = minimum + random.float(f32) * (maximum - minimum) } };
                    },
                    .change_item_damage => |amount| .{ .item_damage = @intFromFloat(amount.evaluate(level)) },
                    .all, .unsupported => unreachable,
                } };
                count += 1;
            },
        }
        return count;
    }
};

/// One thing a post_attack effect does to an entity, its randomness rolled.
pub const Consequence = struct {
    affected: PostAttack.Affected,
    action: union(enum) {
        ignite_seconds: f32,
        damage: struct { damage_type: []const u8, amount: f32 },
        item_damage: i32,
    },
};

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
            .conditional => |value| if (value.condition.matches(request, level)) try value.effect.apply(input, level, request) else input,
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
        damage: []const Effect = &.{},
        knockback: []const Effect = &.{},
        armor_effectiveness: []const Effect = &.{},
        smash_damage_per_fallen_block: []const Effect = &.{},
        ammo_use: []const Effect = &.{},
        projectile_count: []const Effect = &.{},
        projectile_spread: []const Effect = &.{},
        projectile_piercing: []const Effect = &.{},
        crossbow_charge_time: []const Effect = &.{},
        trident_return_acceleration: []const Effect = &.{},
        trident_spin_attack_strength: []const Effect = &.{},
        post_attack: []const PostAttack = &.{},
        /// What a projectile shot with the item starts with, as Flame's fire.
        projectile_spawned: []const EntityEffect = &.{},
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
            inline for (value_channels) |channel| {
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
            if (entry.level == 0 or !(request.any_slot or definition.slots.contains(request.slot))) continue;
            const effects = switch (request.channel) {
                inline else => |channel| @field(definition, @tagName(channel)),
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

    /// What an item's post_attack effects do after a hit, as EnchantmentHelper.doPostAttackEffects
    /// runs them for the item's holder in `role`: each consequence, its randomness rolled, for the
    /// caller to apply. Returns how many were written; more than fit is an error.
    pub fn postAttack(self: *const Effects, request: Request, role: PostAttack.Holder, output: []Consequence) !usize {
        std.debug.assert(request.channel == .damage);
        var count: usize = 0;
        var entries = try Enchantments.Iterator.init(request.item.value(.enchantments) orelse return 0);
        while (try entries.next()) |entry| {
            const index = self.registry.id(entry.name) orelse continue;
            const definition = self.values[index];
            if (entry.level == 0 or !definition.slots.contains(request.slot)) continue;
            for (definition.post_attack) |effect| {
                if (effect.enchanted != role) continue;
                if (effect.condition) |condition| if (!condition.matches(&request, entry.level)) continue;
                count = try effect.effect.consequences(effect.affected, entry.level, request.random, output, count);
            }
        }
        return count;
    }

    /// EnchantmentHelper.onProjectileSpawned: what the weapon's enchantments do to a projectile
    /// shot with it, their values evaluated.
    pub fn projectileSpawned(self: *const Effects, weapon: item_data.View, random: std.Random, output: []Consequence) !usize {
        var count: usize = 0;
        var entries = try Enchantments.Iterator.init(weapon.value(.enchantments) orelse return 0);
        while (try entries.next()) |entry| {
            const index = self.registry.id(entry.name) orelse continue;
            if (entry.level == 0) continue;
            for (self.values[index].projectile_spawned) |effect| count = try effect.consequences(.damaging_entity, entry.level, random, output, count);
        }
        return count;
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
