const Blocks = @import("blocks.zig").Blocks;
const std = @import("std");
const game_data = @import("game_data");
const provider = @import("definition_provider.zig");
const ItemDefinition = @import("item_registry.zig").Definition;
const mining = @import("mining_registry.zig");
const placement = @import("placement_registry.zig");
const item_properties = @import("vanilla_properties.zig");
const physics = game_data.physics_data;
const content = @import("content_types.zig");
const vanilla_definitions = @import("vanilla_definitions");

pub fn definitions() content.Definitions {
    return vanilla_definitions.definitions(content.Definitions);
}

pub const Vanilla = struct {
    pub const id = "minecraft:vanilla_definitions";
    pub const Configuration = struct {};
    pub const Dependencies = provider.Dependencies;

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Vanilla {
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        _ = try provider.register(deps, scratch.allocator(), try defaults(scratch.allocator()), null);
        return try allocator.create(Vanilla);
    }
};

pub fn defaults(allocator: std.mem.Allocator) !content.Definitions {
    var result = definitions();
    const item_definitions = try allocator.alloc(ItemDefinition, game_data.registry.items.len);
    const placements = try allocator.alloc(placement.Definition, game_data.registry.items.len);
    var placement_count: usize = 0;
    for (game_data.registry.items, item_definitions, game_data.registry.item_names) |item, *definition, name| {
        definition.* = .{ .name = name, .stack_size = item.stack_size, .durability = @intCast(item.max_durability), .equipment = item_properties.equipment(name) };
        if (item.block_state != 0) {
            placements[placement_count] = .{ .item = name, .state = game_data.registry.block_state_names[@intCast(item.block_state)] };
            placement_count += 1;
        }
    }
    const mining_definitions = try allocator.alloc(mining.Definition, game_data.registry.blocks.len);
    for (game_data.registry.blocks, mining_definitions, 0..) |block, *definition, index| {
        var tools: std.ArrayList(mining.ToolDefinition) = .empty;
        for (game_data.registry.material_tools[block.material_offset..][0..block.material_count]) |tool| {
            var harvest = false;
            for (game_data.registry.harvest_tools[block.harvest_offset..][0..block.harvest_count]) |kind| harvest = harvest or kind == tool.item_id;
            try tools.append(allocator, .{ .input = .{ .item = game_data.registry.item_names[@intCast(tool.item_id)] }, .speed = tool.multiplier, .harvest = harvest });
        }
        for (game_data.registry.harvest_tools[block.harvest_offset..][0..block.harvest_count]) |kind| {
            const exists = for (game_data.registry.material_tools[block.material_offset..][0..block.material_count]) |tool| {
                if (tool.item_id == kind) break true;
            } else false;
            if (!exists) try tools.append(allocator, .{ .input = .{ .item = game_data.registry.item_names[@intCast(kind)] }, .harvest = true });
        }
        definition.* = .{ .name = game_data.registry.block_state_names[@intCast(block.default_state)], .hardness = block.hardness, .diggable = block.diggable, .requires_tool = block.harvest_count != 0, .experience = game_data.physics.experience(@intCast(index)), .tools = tools.items };
    }
    const block_definitions = try blockDefinitions(allocator);
    result.items = item_definitions;
    result.mining = mining_definitions;
    result.placement = placements[0..placement_count];
    result.physics = block_definitions.physics;
    result.lighting = block_definitions.lighting;
    result.visibility = block_definitions.visibility;
    return result;
}

pub fn prepare(allocator: std.mem.Allocator) !provider.Dependencies {
    const deps = try provider.prepare(allocator);
    _ = try Vanilla.init(allocator, deps);
    return deps;
}

pub fn blockDefinitions(allocator: std.mem.Allocator) !Blocks.Definitions {
    const states = try allocator.alloc(physics.State, game_data.registry.block_state_names.len);
    const transparent = try allocator.alloc(bool, states.len);
    for (states, transparent, game_data.registry.block_state_to_block, 0..) |*state, *visible, block, index| {
        state.* = game_data.physics.get(@intCast(index));
        visible.* = game_data.registry.blocks[block].visually_transparent;
    }
    const snapshots = try allocator.alloc([]const physics.State, 1);
    snapshots[0] = states;
    const visibility = try allocator.alloc([]const bool, 1);
    visibility[0] = transparent;
    const lighting = try allocator.alloc(@TypeOf(try game_data.lighting.init(allocator)), 1);
    lighting[0] = try game_data.lighting.init(allocator);
    return .{ .physics = snapshots, .visibility = visibility, .lighting = lighting };
}

pub fn blocks(allocator: std.mem.Allocator) !*Blocks {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    return Blocks.init(allocator, .{ .definitions = try blockDefinitions(scratch.allocator()) });
}
