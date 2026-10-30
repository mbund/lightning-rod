const mining_behavior = @import("mining_behavior.zig");
const Items = @import("items.zig").Items;
const ids = @import("content_ids.zig");
const std = @import("std");
const game_data = @import("game_data");
const lightning_rod = @import("lightning_rod");
const registry = @import("registry.zig");
const inputs = @import("item_inputs.zig");
const recipes = @import("recipes.zig");
const ItemRegistry = @import("item_registry.zig").ItemRegistry;
pub const Experience = game_data.physics_data.Experience;
pub const ToolDefinition = struct { input: recipes.Input, speed: f32 = 1, harvest: bool = false };
pub const Tool = struct { item: u32, speed: f32, harvest: bool };
pub const Properties = struct { hardness: f32 = -1, diggable: bool = false, requires_tool: bool = false, experience: Experience = .{}, tools: []const Tool = &.{}, callback: ?*const mining_behavior.Binding = null };
pub const Definition = struct { name: []const u8, hardness: ?f32 = null, diggable: ?bool = null, requires_tool: ?bool = null, experience: ?Experience = null, tools: ?[]const ToolDefinition = null, behavior: mining_behavior.Binding.Selection = .inherit };
pub const MiningRegistry = struct {
    pub const id = "minecraft:mining_definitions";
    pub const Definitions = struct { blocks: []const Definition = &.{} };
    pub const Data = struct { properties: []const Properties };
    pub const Dependencies = struct { items: *ItemRegistry };
    pub const Configuration = registry.Registry(MiningRegistry).Configuration;
    registry: registry.Registry(MiningRegistry),
    deps: Dependencies,
    properties: []const Properties,
    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*MiningRegistry {
        const self = try allocator.create(MiningRegistry);
        self.deps = deps;
        try registry.Registry(MiningRegistry).init(self, allocator, configuration);
        try deps.items.registry.onChange(self, refresh);
        return self;
    }
    pub fn addDefinitions(self: *MiningRegistry, entries: []const Definition) !void {
        try self.registry.add(.{ .blocks = entries });
    }
    fn refresh(self: *MiningRegistry) !void {
        try self.registry.refresh();
    }
    pub fn compile(self: *MiningRegistry, allocator: std.mem.Allocator, scratch: std.mem.Allocator, definitions: Definitions) !Data {
        const states: std.StringHashMapUnmanaged(u32) = if (definitions.blocks.len > 0) try ids.index(scratch, game_data.registry.block_state_names) else .empty;
        const resolver = try inputs.Resolver.init(scratch, &self.deps.items.tags);
        const properties = try allocator.alloc(Properties, game_data.registry.blocks.len);
        @memset(properties, .{});
        for (definitions.blocks) |*entry| {
            const state: usize = @intCast(states.get(entry.name) orelse return error.UnknownBlock);
            const value = &properties[game_data.registry.block_state_to_block[state]];
            value.callback = entry.behavior.resolve(value.callback);
            if (entry.hardness) |hardness| {
                if (!std.math.isFinite(hardness)) return error.InvalidBlockHardness;
                value.hardness = hardness;
            }
            if (entry.diggable) |diggable| value.diggable = diggable;
            if (entry.requires_tool) |required| value.requires_tool = required;
            if (entry.experience) |experience| {
                if (experience.rolls != 0 and experience.bound == 0) return error.InvalidBlockExperience;
                value.experience = experience;
            }
            if (entry.tools) |tools| {
                var compiled: std.ArrayList(Tool) = .empty;
                for (tools) |tool| {
                    if (!std.math.isFinite(tool.speed) or tool.speed < 0) return error.InvalidMiningSpeed;
                    for (try resolver.resolve(tool.input)) |kind| try compiled.append(scratch, .{ .item = kind, .speed = tool.speed, .harvest = tool.harvest });
                }
                value.tools = try allocator.dupe(Tool, compiled.items);
            }
        }
        return .{ .properties = properties };
    }
    pub fn get(self: *const MiningRegistry, state: u16) Properties {
        return self.properties[game_data.registry.block_state_to_block[state]];
    }
    pub const Result = mining_behavior.Plan;
    pub fn evaluate(self: *const MiningRegistry, state: u16, tool: ?u32) Result {
        const block = self.get(state);
        var speed: f32 = 1;
        var harvest = !block.requires_tool;
        if (tool) |kind| for (block.tools) |entry| {
            if (entry.item != kind) continue;
            speed = entry.speed;
            harvest = harvest or entry.harvest;
        };
        return .{ .hardness = block.hardness, .diggable = block.diggable, .speed = speed, .harvest = harvest, .experience = if (harvest and block.diggable) block.experience else .{} };
    }
    pub fn evaluateContext(self: *const MiningRegistry, items: *Items, request: mining_behavior.Request, tool_kind: ?u32, scratch: *std.heap.FixedBufferAllocator) !Result {
        const standard = self.evaluate(request.state, tool_kind);
        const callback = self.get(request.state).callback orelse return standard;
        const pinned = if (request.tool) |stack| try items.acquire(stack) else null;
        defer if (pinned) |value| value.release();
        const start = scratch.end_index;
        defer scratch.end_index = start;
        const context: mining_behavior.Context = .{
            .player = if (request.actor) |actor| actor.uuid else null,
            .actor = request.actor,
            .world = request.world,
            .position = request.position,
            .state = request.state,
            .tool = if (pinned) |value| .{ .stack = request.tool.?, .view = value.view } else null,
            .tick = request.tick,
            .standard = standard,
            .scratch = scratch,
        };
        const result = try callback.call(&context) orelse return .{};
        try mining_behavior.validate(result);
        return result;
    }

    pub fn close(self: *MiningRegistry, _: *lightning_rod.Closing) void {
        self.registry.close();
    }
};
