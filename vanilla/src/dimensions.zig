const std = @import("std");
const lightning_rod = @import("lightning_rod");
const Worlds = @import("worlds").Worlds;
const registry = @import("registry.zig");
const types = @import("content_definitions.zig");
const Registries = @import("content_registries.zig").Registries;
const nbt = @import("native_nbt.zig");

pub const Dimensions = struct {
    pub const id = "minecraft:dimensions";
    pub const Definitions = struct { dimensions: []const types.DimensionType = &.{}, tags: []const types.Tag = &.{} };
    pub const Entry = struct { dimension: Worlds.Dimension, ultrawarm: bool };
    pub const Data = struct { entries: []const ?Entry, client: Registries };
    pub const Configuration = registry.Registry(Dimensions).Configuration;
    registry: registry.Registry(Dimensions),
    entries: []const ?Entry,
    client: Registries,
    pub fn init(allocator: std.mem.Allocator, configuration: Configuration) !*Dimensions {
        const self = try allocator.create(Dimensions);
        try registry.Registry(Dimensions).init(self, allocator, configuration);
        return self;
    }
    pub fn addDefinitions(self: *Dimensions, definitions: Definitions) !void {
        try self.registry.add(definitions);
    }
    pub fn compile(_: *Dimensions, allocator: std.mem.Allocator, scratch: std.mem.Allocator, definitions: Definitions) !Data {
        const metadata = try scratch.alloc(Registries.Definition, definitions.dimensions.len);
        for (definitions.dimensions, metadata) |entry, *value| {
            try types.DimensionType.validate(entry.definition);
            value.* = .{ .registry = "minecraft:dimension_type", .name = entry.name, .nbt = try nbt.encode(allocator, entry.definition) };
        }
        const client = try Registries.prepareSubset(allocator, scratch, &.{"minecraft:dimension_type"}, metadata, definitions.tags);
        const values = client.get("minecraft:dimension_type").?;
        const entries = try allocator.alloc(?Entry, values.entries.len);
        @memset(entries, null);
        for (definitions.dimensions) |entry| entries[values.id(entry.name).?] = .{
            .dimension = .{ .name = values.get(entry.name).?.name, .minimum_section = @divExact(entry.definition.min_y, 16), .section_count = @intCast(@divExact(entry.definition.height, 16)), .skylight = entry.definition.has_skylight },
            .ultrawarm = entry.definition.ultrawarm,
        };
        return .{ .entries = entries, .client = client };
    }
    pub fn get(self: *const Dimensions, name: []const u8) ?Entry {
        const index = self.client.get("minecraft:dimension_type").?.id(name) orelse return null;
        return self.entries[index];
    }
    pub fn dimension(self: *const Dimensions, name: []const u8) !Worlds.Dimension {
        return (self.get(name) orelse return error.UnknownDimension).dimension;
    }
    pub fn close(self: *Dimensions, _: *lightning_rod.Closing) void {
        self.registry.close();
    }
};
