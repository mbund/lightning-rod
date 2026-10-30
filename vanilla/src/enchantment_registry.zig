const std = @import("std");
const lightning_rod = @import("lightning_rod");
const registry = @import("registry.zig");
const Registries = @import("content_registries.zig").Registries;
const Tag = @import("content_tags.zig").Definition;
const Effects = @import("enchantment_effects.zig").Effects;
const native_nbt = @import("native_nbt.zig");
const ids = @import("content_ids.zig");
const game_data = @import("game_data");
pub const EnchantmentRegistry = struct {
    pub const id = "minecraft:enchantment_definitions";
    pub const Slot = enum { mainhand, offhand, head, chest, legs, feet, body, saddle };
    pub const Cost = struct { base: i32 = 1, per_level_above_first: i32 = 0 };
    pub const Definition = struct {
        name: []const u8,
        description: []const u8,
        supported_items: []const []const u8,
        maximum_level: u8 = 1,
        weight: u16 = 1,
        minimum_cost: Cost = .{},
        maximum_cost: Cost = .{ .base = 50 },
        anvil_cost: u16 = 1,
        exclusive: []const []const u8 = &.{},
        effects: Effects.Definition,
    };
    pub const Definitions = struct { entries: []const Registries.Definition = &.{}, tags: []const Tag = &.{}, effects: []const Effects.Entry = &.{} };
    pub const Data = struct { client: Registries, effects: Effects };
    pub const Configuration = registry.Registry(EnchantmentRegistry).Configuration;
    registry: registry.Registry(EnchantmentRegistry),
    client: Registries,
    effects: Effects,
    pub fn init(allocator: std.mem.Allocator, configuration: Configuration) !*EnchantmentRegistry {
        const self = try allocator.create(EnchantmentRegistry);
        try registry.Registry(EnchantmentRegistry).init(self, allocator, configuration);
        return self;
    }
    pub fn addEnchantments(self: *EnchantmentRegistry, declarations: []const Definition) !void {
        var scratch = std.heap.ArenaAllocator.init(self.registry.allocator);
        defer scratch.deinit();
        const allocator = scratch.allocator();
        const entries = try allocator.alloc(Registries.Definition, declarations.len);
        const effects = try allocator.alloc(Effects.Entry, declarations.len);
        for (declarations, entries, effects) |declaration, *entry, *effect| {
            if (!ids.validName(declaration.name) or declaration.supported_items.len == 0 or declaration.maximum_level == 0 or declaration.weight == 0 or declaration.weight > 1024 or !declaration.effects.slots.any()) return error.InvalidEnchantment;
            if (declaration.minimum_cost.base < 0 or declaration.minimum_cost.per_level_above_first < 0 or declaration.maximum_cost.base < 0 or declaration.maximum_cost.per_level_above_first < 0) return error.InvalidEnchantment;
            for (declaration.supported_items) |name| if (game_data.registry.itemId(name) == null) return error.UnknownEnchantmentItem;
            for (declaration.exclusive) |name| if (!ids.validName(name)) return error.InvalidEnchantment;
            var slots: [8]Slot = undefined;
            var count: usize = 0;
            for (0..8) |index| if (declaration.effects.slots.contains(@intCast(index))) {
                slots[count] = @enumFromInt(index);
                count += 1;
            };
            entry.* = .{ .registry = "minecraft:enchantment", .name = declaration.name, .nbt = try native_nbt.encode(allocator, .{
                .description = declaration.description,
                .supported_items = declaration.supported_items,
                .max_level = @as(i32, declaration.maximum_level),
                .weight = @as(i32, declaration.weight),
                .min_cost = declaration.minimum_cost,
                .max_cost = declaration.maximum_cost,
                .anvil_cost = @as(i32, declaration.anvil_cost),
                .exclusive_set = declaration.exclusive,
                .slots = @as([]const Slot, slots[0..count]),
            }) };
            effect.* = .{ .name = declaration.name, .definition = declaration.effects };
        }
        try self.addDefinitions(.{ .entries = entries, .effects = effects });
    }

    pub fn addDefinitions(self: *EnchantmentRegistry, definitions: Definitions) !void {
        try self.registry.add(definitions);
    }
    pub fn compile(_: *EnchantmentRegistry, allocator: std.mem.Allocator, scratch: std.mem.Allocator, definitions: Definitions) !Data {
        const client = try Registries.prepareSubset(allocator, scratch, &.{"minecraft:enchantment"}, definitions.entries, definitions.tags);
        return .{ .client = client, .effects = try Effects.prepare(allocator, &client, definitions.effects) };
    }
    pub fn close(self: *EnchantmentRegistry, _: *lightning_rod.Closing) void {
        self.registry.close();
    }
};
