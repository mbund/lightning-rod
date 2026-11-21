//! Tools used on blocks, as AxeItem, ShovelItem, HoeItem and ShearsItem.useOn and
//! PumpkinBlock.useItemOn work: logs strip, copper scrapes and loses its wax, earth flattens into
//! paths or tills into farmland, campfires go out, growing plants stop, and pumpkins carve. What
//! each tool turns each block state into is worked out once from the state names, so a click is
//! one lookup.

const std = @import("std");
const chunks = @import("chunks");
const game_data = @import("game_data");
const inventories = @import("inventories");
const Players = @import("players").players.Players;
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const PlayerInventory = @import("vanilla_inventory").player_inventory.PlayerInventory;
const Items = @import("vanilla_items").items.Items;
const item_actions = @import("vanilla_items").item_actions;
const ItemActions = item_actions.ItemActions;
const Durability = @import("vanilla_items").item_properties.Durability;
const ItemEntities = @import("vanilla_item_entities").item_entities.ItemEntities;
const Effects = @import("vanilla_world").world_effects.Effects;
const state_names = @import("state_names.zig");

const assert = std.debug.assert;
const registry = game_data.registry;

const Tool = enum(u8) { axe, shovel, hoe, shears };
const Kind = enum(u8) { strip, scrape, wax_off, flatten, douse, till, till_rooted, trim };
const Key = struct { tool: Tool, state: u16 };
const Change = struct { kind: Kind, target: u16, door: bool = false };

/// Logs and wood that strip: each becomes its stripped form.
const strippable = [_][]const u8{
    "oak_wood",      "oak_log",      "dark_oak_wood", "dark_oak_log",   "pale_oak_wood",  "pale_oak_log",
    "acacia_wood",   "acacia_log",   "cherry_wood",   "cherry_log",     "birch_wood",     "birch_log",
    "jungle_wood",   "jungle_log",   "spruce_wood",   "spruce_log",     "mangrove_wood",  "mangrove_log",
    "warped_stem",   "warped_hyphae", "crimson_stem", "crimson_hyphae", "bamboo_block",
};

/// WeatheringCopper's families, each from unaffected to oxidized.
const copper_families = [_][4][]const u8{
    .{ "copper_block", "exposed_copper", "weathered_copper", "oxidized_copper" },
    stages("cut_copper"),
    stages("chiseled_copper"),
    stages("cut_copper_slab"),
    stages("cut_copper_stairs"),
    stages("copper_door"),
    stages("copper_trapdoor"),
    stages("copper_grate"),
    stages("copper_bulb"),
};

fn stages(comptime name: []const u8) [4][]const u8 {
    return .{ name, "exposed_" ++ name, "weathered_" ++ name, "oxidized_" ++ name };
}

/// ShovelItem.FLATTENABLES: all become dirt paths.
const flattenable = [_][]const u8{ "grass_block", "dirt", "podzol", "coarse_dirt", "mycelium", "rooted_dirt" };
/// GrowingPlantHeadBlock's heads, which shears stop at their full age.
const growing_heads = [_][]const u8{ "kelp", "weeping_vines", "twisting_vines", "cave_vines" };

pub const ToolActions = struct {
    pub const id = "minecraft:tool_actions";
    pub const Configuration = struct { seed: u64 = 0x746f6f6c73 };
    pub const Dependencies = struct {
        actions: *ItemActions,
        players: *Players,
        player_states: *PlayerStates,
        menus: *PlayerInventory,
        inventories: *inventories.Inventories,
        items: *Items,
        chunks: *chunks.Chunks,
        durability: *Durability,
        dropped: *ItemEntities,
    };
    /// More than every vanilla change, which number some hundreds.
    const changes_max = 4096;

    deps: Dependencies,
    chunk_client: chunks.Chunks.Client,
    effects: Effects,
    random: std.Random.DefaultPrng,
    scratch: std.heap.FixedBufferAllocator,
    changes: std.AutoHashMapUnmanaged(Key, Change),
    /// Carved pumpkins by the face that was carved: north, south, west, east.
    carved: [4]u16,
    pumpkin: u16,
    air: [3]u16,
    shears: u32,
    hanging_roots: u32,
    pumpkin_seeds: u32,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*ToolActions {
        const self = try allocator.create(ToolActions);
        self.* = .{
            .deps = deps,
            .chunk_client = try deps.chunks.simulation(1),
            .effects = try .init(allocator, deps.players),
            .random = .init(configuration.seed),
            .scratch = .init(try allocator.alloc(u8, 1024)),
            .changes = .empty,
            .carved = .{ try state("minecraft:carved_pumpkin[facing=north]"), try state("minecraft:carved_pumpkin[facing=south]"), try state("minecraft:carved_pumpkin[facing=west]"), try state("minecraft:carved_pumpkin[facing=east]") },
            .pumpkin = try state("minecraft:pumpkin"),
            .air = .{ try state("minecraft:air"), try state("minecraft:cave_air"), try state("minecraft:void_air") },
            .shears = try item("minecraft:shears"),
            .hanging_roots = try item("minecraft:hanging_roots"),
            .pumpkin_seeds = try item("minecraft:pumpkin_seeds"),
        };
        try self.changes.ensureTotalCapacity(allocator, changes_max);
        try self.build();
        try deps.actions.on(item_actions.Binding.bind(ToolActions, self, use));
        return self;
    }

    fn state(name: []const u8) !u16 {
        return state_names.id(name) orelse error.UnknownBlockState;
    }

    fn item(name: []const u8) !u32 {
        return @intCast(registry.itemId(name) orelse return error.UnknownItem);
    }

    /// A block's default state, found through any of its states.
    fn defaultState(comptime name: []const u8) !u16 {
        const any = state_names.id(name) orelse for (registry.block_state_names, 0..) |candidate, index| {
            if (std.mem.startsWith(u8, candidate, name ++ "[")) break @as(u16, @intCast(index));
        } else return error.UnknownBlock;
        return @intCast(registry.blocks[registry.block_state_to_block[any]].default_state);
    }

    /// Every change, from one pass over the state names.
    fn build(self: *ToolActions) !void {
        const path = try defaultState("minecraft:dirt_path");
        const farmland = try defaultState("minecraft:farmland");
        const dirt = try defaultState("minecraft:dirt");
        for (registry.block_state_names, 0..) |name, index| {
            const from: u16 = @intCast(index);
            const block, const properties = split(name);
            for (strippable) |source| if (std.mem.eql(u8, block, source)) try self.alike(.axe, .strip, from, "stripped_", source, "", properties);
            for (copper_families) |family| for (family, 0..) |stage, at| {
                if (at > 0 and std.mem.eql(u8, block, stage)) try self.alike(.axe, .scrape, from, "", family[at - 1], "", properties);
                if (block.len == "waxed_".len + stage.len and std.mem.startsWith(u8, block, "waxed_") and std.mem.eql(u8, block["waxed_".len..], stage)) try self.alike(.axe, .wax_off, from, "", stage, "", properties);
            };
            for (flattenable) |source| if (std.mem.eql(u8, block, source)) self.put(.shovel, from, .{ .kind = .flatten, .target = path });
            if ((std.mem.eql(u8, block, "campfire") or std.mem.eql(u8, block, "soul_campfire")) and std.mem.indexOf(u8, properties, "lit=true") != null) try self.replaced(.shovel, .douse, from, name, "lit=true", "lit=false");
            if (std.mem.eql(u8, block, "grass_block") or std.mem.eql(u8, block, "dirt_path") or std.mem.eql(u8, block, "dirt")) self.put(.hoe, from, .{ .kind = .till, .target = farmland });
            if (std.mem.eql(u8, block, "coarse_dirt")) self.put(.hoe, from, .{ .kind = .till, .target = dirt });
            if (std.mem.eql(u8, block, "rooted_dirt")) self.put(.hoe, from, .{ .kind = .till_rooted, .target = dirt });
            for (growing_heads) |source| if (std.mem.eql(u8, block, source)) try self.grown(from, name);
        }
    }

    /// A change to another block keeping every property, as withPropertiesOf and the axis copy do.
    fn alike(self: *ToolActions, tool: Tool, kind: Kind, from: u16, comptime prefix: []const u8, target: []const u8, comptime suffix: []const u8, properties: []const u8) !void {
        var buffer: [256]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "minecraft:" ++ prefix ++ "{s}" ++ suffix ++ "{s}", .{ target, properties });
        const to = state_names.id(name) orelse return error.UnknownBlockState;
        self.put(tool, from, .{ .kind = kind, .target = to, .door = std.mem.endsWith(u8, target, "_door") });
    }

    /// A change of one property's value.
    fn replaced(self: *ToolActions, tool: Tool, kind: Kind, from: u16, name: []const u8, old: []const u8, new: []const u8) !void {
        var buffer: [256]u8 = undefined;
        const at = std.mem.indexOf(u8, name, old).?;
        const changed = try std.fmt.bufPrint(&buffer, "{s}{s}{s}", .{ name[0..at], new, name[at + old.len ..] });
        self.put(tool, from, .{ .kind = kind, .target = state_names.id(changed) orelse return error.UnknownBlockState });
    }

    /// GrowingPlantHeadBlock at any age but its last stops there.
    fn grown(self: *ToolActions, from: u16, name: []const u8) !void {
        const start = std.mem.indexOf(u8, name, "age=") orelse return;
        var end = start + "age=".len;
        while (end < name.len and std.ascii.isDigit(name[end])) end += 1;
        if (std.mem.eql(u8, name[start..end], "age=25")) return;
        try self.replaced(.shears, .trim, from, name, name[start..end], "age=25");
    }

    fn put(self: *ToolActions, tool: Tool, from: u16, change: Change) void {
        assert(self.changes.count() < changes_max);
        self.changes.putAssumeCapacity(.{ .tool = tool, .state = from }, change);
    }

    /// Item.useOn for the tools, after the block's own use passed.
    fn use(self: *ToolActions, context: *const item_actions.Context) !item_actions.Result {
        const hit = context.hit orelse return .pass;
        const tool = self.toolOf(context.item.kind) orelse return .pass;
        const player = context.player;
        const slot = player.handle.?.index;
        const position: chunks.Position = .{ .x = hit.position.x, .y = hit.position.y, .z = hit.position.z };
        const current = try self.chunk_client.getBlock(player.world, position);
        if (tool == .shears and current == self.pumpkin) return self.carve(context, position, @intCast(hit.face));
        if (tool == .axe and context.hand == .main and !player.flags.sneaking and try self.offhandBlocks(slot)) return .pass;
        const change = self.changes.get(.{ .tool = tool, .state = current }) orelse return .pass;
        // The shovel does nothing from below, nor the hoe but on rooted dirt.
        if ((tool == .shovel or tool == .hoe) and hit.face == 0 and change.kind != .till_rooted) return .pass;
        if ((change.kind == .flatten or change.kind == .till) and !try self.airAbove(player.world, position)) return .pass;
        try self.apply(slot, position, change, @intCast(hit.face));
        try self.wear(context, 1);
        return .applied;
    }

    fn toolOf(self: *const ToolActions, kind: u32) ?Tool {
        if (kind == self.shears) return .shears;
        const tags = &self.deps.items.deps.definitions.tags;
        inline for (.{ .{ "minecraft:axes", Tool.axe }, .{ "minecraft:shovels", Tool.shovel }, .{ "minecraft:hoes", Tool.hoe } }) |entry| {
            if (tags.find(entry[0])) |tag| if (tags.contains(tag, kind)) return entry[1];
        }
        return null;
    }

    /// AxeItem.playerHasBlockingItemUseIntent: a shield in the other hand comes first.
    fn offhandBlocks(self: *ToolActions, slot: usize) !bool {
        const player = &self.deps.players.records[slot];
        const stack = (try self.deps.inventories.get(.{ .owner = player.uuid, .index = 45 })).stack orelse return false;
        return game_data.physics.itemBlocksAttacks(try self.deps.items.kind(stack)) != null;
    }

    fn airAbove(self: *ToolActions, world: u32, position: chunks.Position) !bool {
        const above = try self.chunk_client.getBlock(world, .{ .x = position.x, .y = position.y + 1, .z = position.z });
        return std.mem.indexOfScalar(u16, &self.air, above) != null;
    }

    /// The block changes, with the sound and the particles of the change, the dropped roots of
    /// tilled rooted dirt, and the other half of a door.
    fn apply(self: *ToolActions, slot: usize, position: chunks.Position, change: Change, face: u3) !void {
        const player = &self.deps.players.records[slot];
        try self.deps.chunks.setBlock(player.world, position, change.target);
        if (change.door) try self.otherHalf(player.world, position, change.kind);
        const seed: i64 = @bitCast(self.random.next());
        switch (change.kind) {
            .strip => self.effects.blockSound(player.world, position, "minecraft:item.axe.strip", .blocks, 1, 1, seed, slot),
            .scrape => {
                self.effects.blockSound(player.world, position, "minecraft:item.axe.scrape", .blocks, 1, 1, seed, slot);
                self.effects.worldEventExcept(player.world, position, 3005, 0, slot);
            },
            .wax_off => {
                self.effects.blockSound(player.world, position, "minecraft:item.axe.wax_off", .blocks, 1, 1, seed, slot);
                self.effects.worldEventExcept(player.world, position, 3004, 0, slot);
            },
            .flatten => self.effects.blockSound(player.world, position, "minecraft:item.shovel.flatten", .blocks, 1, 1, seed, slot),
            // CampfireBlock.dowse, after the extinguish event for everyone.
            .douse => self.effects.worldEvent(player.world, position, 1009, 0),
            .till => self.effects.blockSound(player.world, position, "minecraft:item.hoe.till", .blocks, 1, 1, seed, slot),
            .till_rooted => {
                self.effects.blockSound(player.world, position, "minecraft:item.hoe.till", .blocks, 1, 1, seed, slot);
                try self.popFromFace(player.world, position, face, self.hanging_roots, 1);
            },
            .trim => self.effects.blockSound(player.world, position, "minecraft:block.growing_plant.crop", .blocks, 1, 1, seed, slot),
        }
    }

    /// A door changes as one: the shape update turns its other half too.
    fn otherHalf(self: *ToolActions, world: u32, position: chunks.Position, kind: Kind) !void {
        for ([_]i32{ 1, -1 }) |dy| {
            const other: chunks.Position = .{ .x = position.x, .y = position.y + dy, .z = position.z };
            const neighbor = try self.chunk_client.getBlock(world, other);
            const change = self.changes.get(.{ .tool = .axe, .state = neighbor }) orelse continue;
            if (change.door and change.kind == kind) try self.deps.chunks.setBlock(world, other, change.target);
        }
    }

    /// PumpkinBlock.useItemOn with shears: carved toward the clicked side, or toward the player
    /// from above or below, with four seeds thrown out of the carved face.
    fn carve(self: *ToolActions, context: *const item_actions.Context, position: chunks.Position, face: u3) !item_actions.Result {
        const player = context.player;
        const facing: u2 = switch (face) {
            2 => 0,
            3 => 1,
            4 => 2,
            5 => 3,
            // Direction.fromYRot, then its opposite.
            else => switch (@as(u2, @intCast(@as(i32, @intFromFloat(@floor(player.rotation.yaw / 90.0 + 0.5))) & 3))) {
                0 => 0,
                1 => 3,
                2 => 1,
                3 => 2,
            },
        };
        const steps = [_][2]f64{ .{ 0, -1 }, .{ 0, 1 }, .{ -1, 0 }, .{ 1, 0 } };
        const step = steps[facing];
        self.effects.blockSound(player.world, position, "minecraft:block.pumpkin.carve", .blocks, 1, 1, @bitCast(self.random.next()), null);
        try self.deps.chunks.setBlock(player.world, position, self.carved[facing]);
        const random = self.random.random();
        // The ItemEntity draws a velocity of its own before this one replaces it.
        _ = random.float(f64);
        _ = random.float(f64);
        const at: [3]f64 = .{ @as(f64, @floatFromInt(position.x)) + 0.5 + step[0] * 0.65, @as(f64, @floatFromInt(position.y)) + 0.1, @as(f64, @floatFromInt(position.z)) + 0.5 + step[1] * 0.65 };
        const velocity: [3]f64 = .{ 0.05 * step[0] + random.float(f64) * 0.02, 0.05, 0.05 * step[1] + random.float(f64) * 0.02 };
        try self.drop(player.world, at, velocity, self.pumpkin_seeds, 4);
        try self.wear(context, 1);
        return .applied;
    }

    /// Block.popResourceFromFace: an item just outside the face, moving out of it.
    fn popFromFace(self: *ToolActions, world: u32, position: chunks.Position, face: u3, kind: u32, count: u16) !void {
        const steps = [_][3]f64{ .{ 0, -1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 }, .{ -1, 0, 0 }, .{ 1, 0, 0 } };
        const step = steps[face];
        const random = self.random.random();
        const half = 0.125;
        var at: [3]f64 = undefined;
        var velocity: [3]f64 = undefined;
        const base = [3]f64{ @floatFromInt(position.x), @floatFromInt(position.y), @floatFromInt(position.z) };
        for (0..3) |axis| {
            at[axis] = base[axis] + 0.5 + (if (step[axis] == 0) random.float(f64) * 0.5 - 0.25 else step[axis] * (0.5 + half));
            velocity[axis] = if (step[axis] == 0) (if (axis == 1) random.float(f64) * 0.1 else random.float(f64) * 0.2 - 0.1) else step[axis] * 0.1 + (if (axis == 1) @as(f64, 0.1) else 0);
        }
        at[1] -= half;
        try self.drop(world, at, velocity, kind, count);
    }

    fn drop(self: *ToolActions, world: u32, at: [3]f64, velocity: [3]f64, kind: u32, count: u16) !void {
        const stack: inventories.Stack = .{ .item = try self.deps.items.define(registry.item_names[kind]), .count = count };
        var spawned: [1]@import("entities").Id = undefined;
        try self.deps.dropped.createMany(&.{.{ .world = world, .position = at, .velocity = velocity, .stack = stack }}, &spawned);
    }

    /// ItemStack.hurtAndBreak on the tool, except in creative.
    fn wear(self: *ToolActions, context: *const item_actions.Context, amount: i32) !void {
        const player = context.player;
        if (self.deps.player_states.of(player).gamemode == .creative) return;
        const slot = player.handle.?.index;
        const index: u16 = if (context.hand == .off) 45 else 36 + @as(u16, self.deps.player_states.of(player).selected_slot);
        const at: inventories.Slot = .{ .owner = player.uuid, .index = index };
        const held = try self.deps.inventories.get(at);
        const stack = held.stack orelse return;
        self.scratch.reset();
        const worn = try self.deps.durability.wear(stack, .{ .amount = amount, .slot = if (context.hand == .off) 1 else 0, .actor = player, .random = self.random.random(), .scratch = &self.scratch });
        if (std.meta.eql(worn, held.stack)) return;
        const committed = try self.deps.inventories.set(at, held.revision, worn);
        assert(committed);
        self.deps.menus.changed(slot);
    }
};

/// A state name's block, without its namespace, and its bracketed properties, or nothing.
fn split(name: []const u8) struct { []const u8, []const u8 } {
    const start = if (std.mem.indexOfScalar(u8, name, ':')) |colon| colon + 1 else 0;
    const bracket = std.mem.indexOfScalar(u8, name, '[') orelse name.len;
    return .{ name[start..bracket], name[bracket..] };
}

test "tools turn vanilla's states into what vanilla turns them into" {
    var tools: ToolActions = undefined;
    tools.changes = .empty;
    defer tools.changes.deinit(std.testing.allocator);
    try tools.changes.ensureTotalCapacity(std.testing.allocator, ToolActions.changes_max);
    try tools.build();
    const Case = struct { tool: Tool, from: []const u8, kind: Kind, to: []const u8 };
    const cases = [_]Case{
        .{ .tool = .axe, .from = "minecraft:oak_log[axis=x]", .kind = .strip, .to = "minecraft:stripped_oak_log[axis=x]" },
        .{ .tool = .axe, .from = "minecraft:bamboo_block[axis=z]", .kind = .strip, .to = "minecraft:stripped_bamboo_block[axis=z]" },
        .{ .tool = .axe, .from = "minecraft:exposed_copper", .kind = .scrape, .to = "minecraft:copper_block" },
        .{ .tool = .axe, .from = "minecraft:oxidized_cut_copper_slab[type=top,waterlogged=false]", .kind = .scrape, .to = "minecraft:weathered_cut_copper_slab[type=top,waterlogged=false]" },
        .{ .tool = .axe, .from = "minecraft:waxed_copper_block", .kind = .wax_off, .to = "minecraft:copper_block" },
        .{ .tool = .axe, .from = "minecraft:waxed_weathered_copper_bulb[lit=true,powered=false]", .kind = .wax_off, .to = "minecraft:weathered_copper_bulb[lit=true,powered=false]" },
        .{ .tool = .shovel, .from = "minecraft:grass_block[snowy=false]", .kind = .flatten, .to = "minecraft:dirt_path" },
        .{ .tool = .shovel, .from = "minecraft:campfire[facing=east,lit=true,signal_fire=true,waterlogged=false]", .kind = .douse, .to = "minecraft:campfire[facing=east,lit=false,signal_fire=true,waterlogged=false]" },
        .{ .tool = .hoe, .from = "minecraft:dirt", .kind = .till, .to = "minecraft:farmland[moisture=0]" },
        .{ .tool = .hoe, .from = "minecraft:coarse_dirt", .kind = .till, .to = "minecraft:dirt" },
        .{ .tool = .hoe, .from = "minecraft:rooted_dirt", .kind = .till_rooted, .to = "minecraft:dirt" },
        .{ .tool = .shears, .from = "minecraft:kelp[age=3]", .kind = .trim, .to = "minecraft:kelp[age=25]" },
    };
    for (cases) |case| {
        const change = tools.changes.get(.{ .tool = case.tool, .state = state_names.id(case.from).? }) orelse return error.MissingChange;
        try std.testing.expectEqual(case.kind, change.kind);
        try std.testing.expectEqualStrings(case.to, registry.block_state_names[change.target]);
    }
    // Stripped logs, oxidized copper, unlit campfires and full grown kelp stay as they are.
    for ([_]Key{
        .{ .tool = .axe, .state = state_names.id("minecraft:stripped_oak_log[axis=y]").? },
        .{ .tool = .axe, .state = state_names.id("minecraft:copper_block").? },
        .{ .tool = .shovel, .state = state_names.id("minecraft:campfire[facing=east,lit=false,signal_fire=true,waterlogged=false]").? },
        .{ .tool = .shears, .state = state_names.id("minecraft:kelp[age=25]").? },
    }) |key| try std.testing.expect(tools.changes.get(key) == null);
}
