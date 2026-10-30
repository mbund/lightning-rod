const std = @import("std");
const lightning_rod = @import("lightning_rod");
const game_data = @import("game_data");
const registry = @import("registry.zig");
const recipes = @import("recipes.zig");
const ItemRegistry = @import("item_registry.zig").ItemRegistry;
const loot = @import("loot.zig");
pub const Loot = struct {
    pub const id = "minecraft:loot";
    pub const Definitions = struct { tables: []const loot.Definition = &.{} };
    pub const Data = struct { tables: loot.Tables };
    pub const Dependencies = struct { items: *ItemRegistry };
    pub const Configuration = registry.Registry(Loot).Configuration;
    registry: registry.Registry(Loot),
    deps: Dependencies,
    tables: loot.Tables,
    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*Loot {
        const self = try allocator.create(Loot);
        self.deps = deps;
        try registry.Registry(Loot).init(self, allocator, configuration);
        try deps.items.registry.onChange(self, refresh);
        return self;
    }
    pub fn addTables(self: *Loot, definitions: []const loot.Definition) !void {
        try self.registry.add(.{ .tables = definitions });
    }
    fn refresh(self: *Loot) !void {
        try self.registry.refresh();
    }
    pub fn compile(self: *Loot, allocator: std.mem.Allocator, scratch: std.mem.Allocator, definitions: Definitions) !Data {
        return .{ .tables = try loot.Tables.prepare(allocator, scratch, &self.deps.items.tags, definitions.tables) };
    }
    pub fn close(self: *Loot, _: *lightning_rod.Closing) void {
        self.registry.close();
    }
};
