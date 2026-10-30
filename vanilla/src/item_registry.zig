const std = @import("std");
const game_data = @import("game_data");
const lightning_rod = @import("lightning_rod");
const registry = @import("registry.zig");
const data = @import("item_data.zig");
const recipes = @import("recipes.zig");
const inputs = @import("item_inputs.zig");
const Tags = @import("content_tags.zig").Tags;
const Tag = @import("content_tags.zig").Definition;
const Registries = @import("content_registries.zig").Registries;

pub const Properties = struct { stack_size: u16 = 64, durability: u32 = 0, equipment: u8 = 0 };
pub const Definition = struct { name: []const u8, stack_size: ?u16 = null, durability: ?u32 = null, equipment: ?u8 = null };
pub const ItemRegistry = struct {
    pub const id = "minecraft:item_definitions";
    pub const Definitions = struct { items: []const Definition = &.{}, tags: []const Tag = &.{}, remainders: []const recipes.RemainderDefinition = &.{} };
    pub const Data = struct { properties: []const Properties, tags: Tags, remainders: []const ?u32, client: Registries };
    pub const Configuration = registry.Registry(ItemRegistry).Configuration;
    registry: registry.Registry(ItemRegistry),
    properties: []const Properties,
    tags: Tags,
    remainders: []const ?u32,
    client: Registries,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration) !*ItemRegistry {
        const self = try allocator.create(ItemRegistry);
        try registry.Registry(ItemRegistry).init(self, allocator, configuration);
        return self;
    }
    pub fn addDefinitions(self: *ItemRegistry, definitions: Definitions) !void {
        try self.registry.add(definitions);
    }
    pub fn compile(_: *ItemRegistry, allocator: std.mem.Allocator, scratch: std.mem.Allocator, definitions: Definitions) !Data {
        const client = try Registries.prepareSubset(allocator, scratch, &.{"minecraft:item"}, &.{}, definitions.tags);
        const tags = client.get("minecraft:item").?.tags;
        const resolver = try inputs.Resolver.init(scratch, &tags);
        const properties = try allocator.alloc(Properties, game_data.registry.items.len);
        const remainders = try allocator.alloc(?u32, properties.len);
        @memset(properties, .{});
        @memset(remainders, null);
        for (definitions.items) |definition| {
            const index: usize = @intCast(resolver.names.get(definition.name) orelse return error.UnknownItem);
            const value = &properties[index];
            if (definition.stack_size) |limit| {
                if (limit == 0 or limit > 99) return error.InvalidStackLimit;
                value.stack_size = limit;
            }
            if (definition.durability) |limit| {
                if (limit > std.math.maxInt(i32)) return error.InvalidDurability;
                value.durability = limit;
            }
            if (definition.equipment) |slot| {
                if (slot > 5) return error.InvalidEquipmentSlot;
                value.equipment = slot;
            }
        }
        for (definitions.remainders) |rule| {
            const remainder = if (rule.item) |name| @as(?u32, @intCast(resolver.names.get(name) orelse return error.UnknownItem)) else null;
            for (try resolver.resolve(rule.input)) |kind| remainders[kind] = remainder;
        }
        return .{ .properties = properties, .tags = tags, .remainders = remainders, .client = client };
    }
    pub fn maximumDefinition(self: *const ItemRegistry, kind: u32, components: []const data.Component) !u16 {
        return maximum(self.properties, kind, components);
    }
    pub fn close(self: *ItemRegistry, _: *lightning_rod.Closing) void {
        self.registry.close();
    }
};

pub fn maximum(properties: []const Properties, kind: u32, components: []const data.Component) !u16 {
    if (kind >= properties.len) return error.UnknownItem;
    for (components) |component| if (component.key == data.key(.max_stack_size)) {
        const count, const rest = try game_data.encoding.read_varint(component.value orelse return error.InvalidStackLimit);
        if (rest.len != 0 or count <= 0 or count > 99) return error.InvalidStackLimit;
        return @intCast(count);
    };
    return properties[kind].stack_size;
}
