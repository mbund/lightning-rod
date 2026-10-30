const std = @import("std");
const game_data = @import("game_data");
const lightning_rod = @import("lightning_rod");
const registry = @import("registry.zig");
const Registries = @import("content_registries.zig").Registries;
const Tag = @import("content_tags.zig").Definition;
pub const ClientRegistries = struct {
    pub const id = "minecraft:client_registries";
    pub const Definitions = struct { entries: []const Registries.Definition = &.{}, tags: []const Tag = &.{}, presentations: []const Registries.Presentation = &.{} };
    pub const Data = struct { client: Registries, presentations: []const Registries.Presentation };
    pub const Configuration = registry.Registry(ClientRegistries).Configuration;
    registry: registry.Registry(ClientRegistries),
    client: Registries,
    presentations: []const Registries.Presentation,
    pub fn init(allocator: std.mem.Allocator, configuration: Configuration) !*ClientRegistries {
        const self = try allocator.create(ClientRegistries);
        try registry.Registry(ClientRegistries).init(self, allocator, configuration);
        return self;
    }
    pub fn addDefinitions(self: *ClientRegistries, definitions: Definitions) !void {
        try self.registry.add(definitions);
    }
    pub fn compile(_: *ClientRegistries, allocator: std.mem.Allocator, scratch: std.mem.Allocator, definitions: Definitions) !Data {
        var names: std.ArrayList([]const u8) = .empty;
        var iterator = try game_data.snapshot.Iterator.init(game_data.registry_snapshot);
        while (try iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.name, "minecraft:item") or std.mem.eql(u8, entry.name, "minecraft:block") or std.mem.eql(u8, entry.name, "minecraft:dimension_type") or std.mem.eql(u8, entry.name, "minecraft:enchantment")) continue;
            try names.append(scratch, entry.name);
        }
        const client = try Registries.prepareSubset(allocator, scratch, names.items, definitions.entries, definitions.tags);
        for (definitions.presentations) |presentation| {
            if (client.get(presentation.registry) != null) try client.validatePresentations(&.{presentation});
        }
        return .{ .client = client, .presentations = definitions.presentations };
    }
    pub fn close(self: *ClientRegistries, _: *lightning_rod.Closing) void {
        self.registry.close();
    }
};
