const ids = @import("content_ids.zig");
const std = @import("std");
const game_data = @import("game_data");
const lightning_rod = @import("lightning_rod");
const lighting = @import("lighting");
const registry = @import("registry.zig");
const Tag = @import("content_tags.zig").Definition;
const Registries = @import("content_registries.zig").Registries;

pub const State = struct { name: []const u8, physics: ?game_data.physics_data.State = null, visually_transparent: ?bool = null };
pub const Blocks = struct {
    pub const id = "minecraft:blocks";
    pub const Definitions = struct { visibility: []const []const bool = &.{}, states: []const State = &.{}, physics: []const []const game_data.physics_data.State = &.{}, tags: []const Tag = &.{}, lighting: []const lighting.Registry = &.{} };
    pub const Data = struct { transparent: []const bool, properties: []const game_data.physics_data.State, light: lighting.Registry, client: Registries };
    pub const Configuration = registry.Registry(Blocks).Configuration;
    registry: registry.Registry(Blocks),
    transparent: []const bool,
    properties: []const game_data.physics_data.State,
    light: lighting.Registry,
    client: Registries,
    pub fn init(allocator: std.mem.Allocator, configuration: Configuration) !*Blocks {
        const self = try allocator.create(Blocks);
        try registry.Registry(Blocks).init(self, allocator, configuration);
        return self;
    }
    pub fn addDefinitions(self: *Blocks, definitions: Definitions) !void {
        try self.registry.add(definitions);
    }
    pub fn compile(_: *Blocks, allocator: std.mem.Allocator, scratch: std.mem.Allocator, definitions: Definitions) !Data {
        const client = try Registries.prepareSubset(allocator, scratch, &.{"minecraft:block"}, &.{}, definitions.tags);
        const properties = try allocator.alloc(game_data.physics_data.State, game_data.registry.block_state_names.len);
        const transparent = try allocator.alloc(bool, properties.len);
        @memset(transparent, false);
        for (definitions.visibility) |snapshot| {
            if (snapshot.len != transparent.len) return error.InvalidBlockVisibility;
            @memcpy(transparent, snapshot);
        }
        @memset(properties, .{ .friction = 1, .speed = 1, .water_block = false, .fluid = .none, .amount = 0, .blocks_motion = false, .falling = false, .ice = false, .sturdy = 0 });
        for (definitions.physics) |snapshot| {
            if (snapshot.len != properties.len) return error.InvalidBlockPhysics;
            @memcpy(properties, snapshot);
        }
        const names: std.StringHashMapUnmanaged(u32) = if (definitions.states.len > 0) try ids.index(scratch, game_data.registry.block_state_names) else .empty;
        for (definitions.states) |entry| {
            const state: usize = @intCast(names.get(entry.name) orelse return error.UnknownBlockState);
            if (entry.physics) |physics| properties[state] = physics;
            if (entry.visually_transparent) |value| transparent[state] = value;
        }
        for (properties) |physics| {
            if (!std.math.isFinite(physics.friction) or !std.math.isFinite(physics.speed) or physics.friction < 0 or physics.speed < 0 or physics.amount > 9) return error.InvalidBlockPhysics;
        }
        var light: lighting.Registry = undefined;
        if (definitions.lighting.len > 0) light = definitions.lighting[definitions.lighting.len - 1] else {
            const states = try allocator.alloc(lighting.Properties, properties.len);
            @memset(states, .{ .opacity = 0, .emission = 0, .faces = @splat(0) });
            light = .{ .states = states, .faces = 1, .occlusion = &.{0} };
        }
        if (light.states.len != properties.len or light.faces == 0 or light.occlusion.len != try std.math.mul(usize, light.faces, light.faces)) return error.InvalidLightingRegistry;
        for (light.states) |state| {
            if (state.opacity > 15 or state.emission > 15) return error.InvalidLightingRegistry;
            for (state.faces) |face| if (face >= light.faces) return error.InvalidLightingRegistry;
        }
        return .{ .transparent = transparent, .properties = properties, .light = light, .client = client };
    }
    pub fn get(self: *const Blocks, state: u16) game_data.physics_data.State {
        std.debug.assert(state < self.properties.len);
        return self.properties[state];
    }
    pub fn close(self: *Blocks, _: *lightning_rod.Closing) void {
        self.registry.close();
    }
};
