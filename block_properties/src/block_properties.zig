//! Block state properties the engine reads: how light passes through each state and which
//! block entity it carries. Content provides them. Light may change while the server runs,
//! as when a datapack redefines blocks, and whoever depends on it listens.
const std = @import("std");
const assert = std.debug.assert;
const lighting = @import("lighting");

pub const BlockProperties = struct {
    /// How light passes each state.
    light: lighting.Registry,
    /// The block entity type each state carries, as an index into `entity_types`.
    entities: []const ?u8,
    entity_types: []const []const u8,
    listeners: [listeners_max]Listener = undefined,
    listener_count: usize = 0,

    /// Engine systems that keep work derived from light.
    const listeners_max = 8;
    const Listener = struct { context: *anyopaque, changed: *const fn (*anyopaque) void };

    pub fn init(light: lighting.Registry, entities: []const ?u8, entity_types: []const []const u8) BlockProperties {
        assert(light.states.len == entities.len);
        assert(entity_types.len <= std.math.maxInt(u8));
        for (entities) |entity| if (entity) |index| assert(index < entity_types.len);
        return .{ .light = light, .entities = entities, .entity_types = entity_types };
    }

    pub fn stateCount(self: *const BlockProperties) usize {
        return self.entities.len;
    }

    /// The name of the block entity type a state carries.
    pub fn entityName(self: *const BlockProperties, state: u16) ?[]const u8 {
        assert(state < self.entities.len);
        const index = self.entities[state] orelse return null;
        return self.entity_types[index];
    }

    /// Calls `changed` on `owner` after the light of states changes. Owners listen during
    /// startup and live as long as the properties.
    pub fn listen(self: *BlockProperties, comptime Owner: type, owner: *Owner, comptime changed: fn (*Owner) void) !void {
        if (self.listener_count == listeners_max) return error.TooManyBlockListeners;
        const Adapter = struct {
            fn call(context: *anyopaque) void {
                changed(@ptrCast(@alignCast(context)));
            }
        };
        self.listeners[self.listener_count] = .{ .context = owner, .changed = Adapter.call };
        self.listener_count += 1;
    }

    /// Content replaces the light of every state. Every listener hears of it, in the order
    /// they listened.
    pub fn changeLight(self: *BlockProperties, light: lighting.Registry) void {
        assert(light.states.len == self.entities.len);
        self.light = light;
        for (self.listeners[0..self.listener_count]) |listener| listener.changed(listener.context);
    }
};

test "listeners hear changed light in order and entity names follow their states" {
    const dark: [3]lighting.Properties = @splat(.{ .opacity = 15, .emission = 0, .faces = @splat(0) });
    var bright = dark;
    bright[1].emission = 15;
    const entities = [_]?u8{ null, 1, 0 };
    var properties: BlockProperties = .init(.{ .states = &dark, .faces = 1, .occlusion = &.{0} }, &entities, &.{ "test:chest", "test:furnace" });
    try std.testing.expectEqual(@as(usize, 3), properties.stateCount());
    try std.testing.expectEqual(@as(?[]const u8, null), properties.entityName(0));
    try std.testing.expectEqualStrings("test:furnace", properties.entityName(1).?);
    try std.testing.expectEqualStrings("test:chest", properties.entityName(2).?);

    const Heard = struct {
        order: [2]u8 = undefined,
        count: usize = 0,
        properties: *const BlockProperties,
        mark: u8,
        log: *@This(),

        fn changed(self: *@This()) void {
            std.debug.assert(self.properties.light.states[1].emission == 15);
            self.log.order[self.log.count] = self.mark;
            self.log.count += 1;
        }
    };
    var log: Heard = .{ .properties = &properties, .mark = 0, .log = undefined };
    log.log = &log;
    var first: Heard = .{ .properties = &properties, .mark = 1, .log = &log };
    var second: Heard = .{ .properties = &properties, .mark = 2, .log = &log };
    try properties.listen(Heard, &first, Heard.changed);
    try properties.listen(Heard, &second, Heard.changed);
    properties.changeLight(.{ .states = &bright, .faces = 1, .occlusion = &.{0} });
    try std.testing.expectEqual(@as(usize, 2), log.count);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &log.order);
}
