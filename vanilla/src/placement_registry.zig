const placement_behavior = @import("placement_behavior.zig");
const ids = @import("content_ids.zig");
const std = @import("std");
const game_data = @import("game_data");
const lightning_rod = @import("lightning_rod");
const registry = @import("registry.zig");
pub const Definition = struct { item: []const u8, state: ?[]const u8 = null, behavior: placement_behavior.Binding.Selection = .inherit };
pub const PlacementRegistry = struct {
    pub const id = "minecraft:placement_definitions";
    pub const Definitions = struct { items: []const Definition = &.{} };
    pub const Data = struct { states: []const u16, callbacks: []const ?*const placement_behavior.Binding };
    pub const Configuration = registry.Registry(PlacementRegistry).Configuration;
    registry: registry.Registry(PlacementRegistry),
    states: []const u16,
    callbacks: []const ?*const placement_behavior.Binding,
    pub fn init(allocator: std.mem.Allocator, configuration: Configuration) !*PlacementRegistry {
        const self = try allocator.create(PlacementRegistry);
        try registry.Registry(PlacementRegistry).init(self, allocator, configuration);
        return self;
    }
    pub fn addDefinitions(self: *PlacementRegistry, entries: []const Definition) !void {
        try self.registry.add(.{ .items = entries });
    }
    pub fn compile(_: *PlacementRegistry, allocator: std.mem.Allocator, scratch: std.mem.Allocator, definitions: Definitions) !Data {
        const names: std.StringHashMapUnmanaged(u32) = if (definitions.items.len > 0) try ids.index(scratch, game_data.registry.block_state_names) else .empty;
        const items: std.StringHashMapUnmanaged(u32) = if (definitions.items.len > 0) try ids.index(scratch, game_data.registry.item_names) else .empty;
        const states = try allocator.alloc(u16, game_data.registry.items.len);
        @memset(states, 0);
        const callbacks = try allocator.alloc(?*const placement_behavior.Binding, states.len);
        @memset(callbacks, null);
        for (definitions.items) |*entry| {
            const kind: usize = @intCast(items.get(entry.item) orelse return error.UnknownItem);
            if (entry.state) |state| states[kind] = @intCast(names.get(state) orelse return error.UnknownBlockState);
            callbacks[kind] = entry.behavior.resolve(callbacks[kind]);
        }
        return .{ .states = states, .callbacks = callbacks };
    }
    pub fn close(self: *PlacementRegistry, _: *lightning_rod.Closing) void {
        self.registry.close();
    }
};
