//! Water and lava flow on scheduled fluid ticks, as vanilla 1.21.8 does: FlowableFluid,
//! WaterFluid, LavaFluid, FluidBlock and Waterloggable. A fluid tick works out the level the
//! cell should hold from the cells around it, then flows down, or to the sides that lead
//! soonest to a drop. Edits schedule the fluids next to them, as vanilla's neighbour updates
//! do, and lava that touches water hardens.
//!
//! Ticks read blocks through copies decoded once and kept as edits change them, so the flood
//! fill of a spreading fluid is array lookups rather than a lease per block.

const std = @import("std");
const chunks = @import("chunks");
const game_data = @import("game_data");
const entities = @import("entities");
const inventories = @import("inventories");
const ticks = @import("ticks").ticks;
const Worlds = @import("worlds").Worlds;
const Blocks = @import("vanilla_content").blocks.Blocks;
const Dimensions = @import("vanilla_content").dimensions.Dimensions;
const Items = @import("vanilla_items").items.Items;
const loot_tables = @import("vanilla_items").loot;
const item_data = @import("vanilla_items").item_data;
const BlockLoot = @import("block_loot.zig").BlockLoot;
const ItemEntities = @import("vanilla_item_entities").item_entities.ItemEntities;
const Players = @import("players").players.Players;
const Effects = @import("world_effects.zig").Effects;

const assert = std.debug.assert;
const registry = game_data.registry;
const physics = game_data.physics;
const state_names = @import("state_names.zig");

pub const Kind = enum(u2) { empty, water, lava };

/// A cell's fluid. Sources hold 8 and do not fall. Flowing fluid holds 1 to 8.
pub const Fluid = struct {
    kind: Kind = .empty,
    amount: u8 = 0,
    falling: bool = false,

    pub fn still(self: Fluid) bool {
        return self.kind != .empty and self.amount == 8 and !self.falling;
    }

    pub fn empty(self: Fluid) bool {
        return self.kind == .empty;
    }

    fn source(kind: Kind) Fluid {
        return .{ .kind = kind, .amount = 8 };
    }

    fn flowing(kind: Kind, amount: u8, falling: bool) Fluid {
        assert(amount >= 1 and amount <= 8);
        return .{ .kind = kind, .amount = amount, .falling = falling };
    }
};

/// What vanilla calls a Fluid: a kind, still or flowing. Fluid ticks are scheduled per variant,
/// and run only while the cell still holds that variant.
const Variant = struct { kind: Kind, still: bool };

fn variant(fluid: Fluid) Variant {
    return .{ .kind = fluid.kind, .still = fluid.still() };
}

const Direction = enum(u3) {
    down,
    up,
    north,
    south,
    west,
    east,

    fn step(self: Direction) [3]i32 {
        return switch (self) {
            .down => .{ 0, -1, 0 },
            .up => .{ 0, 1, 0 },
            .north => .{ 0, 0, -1 },
            .south => .{ 0, 0, 1 },
            .west => .{ -1, 0, 0 },
            .east => .{ 1, 0, 0 },
        };
    }

    fn opposite(self: Direction) Direction {
        return switch (self) {
            .down => .up,
            .up => .down,
            .north => .south,
            .south => .north,
            .west => .east,
            .east => .west,
        };
    }
};

/// Direction.Type.HORIZONTAL, the order vanilla looks around a cell in.
const horizontal = [_]Direction{ .north, .east, .south, .west };
/// The order an EnumMap of directions, as getSpread returns, flows in.
const spread_order = [_]Direction{ .north, .south, .west, .east };
/// FluidBlock.FLOW_DIRECTIONS, looked along backwards for water touching lava.
const contact_order = [_]Direction{ .down, .south, .north, .east, .west };

const Shape = enum(u2) { empty, full, partial };
/// FluidFillable blocks: waterloggable ones take still water, water plants take nothing.
pub const Fillable = enum(u2) { no, waterloggable, plant };
/// A face of a collision box on the boundary of its cell: the range it covers on the two axes
/// across the face.
const Rectangle = [4]f32;
const rectangles_max = 16;

/// What fluids know of each block state, built once from the game data.
const Tables = struct {
    fluid: []const Fluid,
    /// Water and lava blocks themselves, FluidBlock.
    liquid: []const bool,
    air: []const bool,
    blocks_motion: []const bool,
    /// BlockState.isSolid, which also counts cobweb and bamboo saplings.
    solid: []const bool,
    /// Blocks no fluid flows into whatever their shape: doors, ladders, portals and the rest
    /// FlowableFluid.canFill names, but for signs, which come from a tag.
    refuses: []const bool,
    fillable: []const Fillable,
    waterlogged: []const bool,
    /// The same state waterlogged, for waterloggable states that are not.
    waterlog: []const u16,
    /// The same state dry, for waterlogged states.
    dry: []const u16,
    shape: []const Shape,
    /// Where each state's rectangles on each face lie in `rectangles`.
    faces: []const [6][2]u32,
    rectangles: []const Rectangle,
    water: [16]u16,
    lava: [16]u16,
    stone: u16,
    cobblestone: u16,
    obsidian: u16,
    basalt: u16,
    soul_soil: u16,
    blue_ice: u16,
    /// Blocks by name, for the sign tag, whose members name blocks by their place in another
    /// registry.
    blocks: std.StringHashMapUnmanaged(u16),
};

var tables: Tables = undefined;
var tables_ready = std.atomic.Value(bool).init(false);

fn stateId(name: []const u8) !u16 {
    return @intCast(registry.blockStateId(name) orelse return error.UnknownBlockState);
}

fn blockName(name: []const u8) []const u8 {
    return name[0 .. std.mem.indexOfScalar(u8, name, '[') orelse name.len];
}

fn property(name: []const u8, key: []const u8) ?[]const u8 {
    const begin = std.mem.indexOfScalar(u8, name, '[') orelse return null;
    var properties = std.mem.splitScalar(u8, name[begin + 1 .. name.len - 1], ',');
    while (properties.next()) |entry| {
        const separator = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, entry[0..separator], key)) return entry[separator + 1 ..];
    }
    return null;
}

/// The tables are game data, like the registry they come from, so they live for the process.
/// They are first built while the server starts, before any thread but the main one runs.
fn ensureTables() void {
    if (tables_ready.load(.acquire)) return;
    prepareTables(std.heap.page_allocator) catch |err| std.debug.panic("fluid tables: {t}", .{err});
}

fn prepareTables(allocator: std.mem.Allocator) !void {
    if (tables_ready.load(.acquire)) return;
    const count = registry.block_state_names.len;
    const fluid = try allocator.alloc(Fluid, count);
    const liquid = try allocator.alloc(bool, count);
    const air = try allocator.alloc(bool, count);
    const blocks_motion = try allocator.alloc(bool, count);
    const solid = try allocator.alloc(bool, count);
    const refuses = try allocator.alloc(bool, count);
    const fillable = try allocator.alloc(Fillable, count);
    const waterlogged = try allocator.alloc(bool, count);
    const waterlog = try allocator.alloc(u16, count);
    const dry = try allocator.alloc(u16, count);
    for (dry, 0..) |*state, index| state.* = @intCast(index);
    const shape = try allocator.alloc(Shape, count);
    const faces = try allocator.alloc([6][2]u32, count);
    var rectangles: std.ArrayListUnmanaged(Rectangle) = .empty;
    var scratch: [256]u8 = undefined;
    for (registry.block_state_names, 0..) |name, index| {
        const state: u16 = @intCast(index);
        const facts = physics.get(state);
        fluid[index] = switch (facts.fluid) {
            .none => .{},
            .water => .{ .kind = .water, .amount = facts.amount, .falling = facts.falling },
            .lava => .{ .kind = .lava, .amount = facts.amount, .falling = facts.falling },
        };
        liquid[index] = facts.liquid_block;
        air[index] = facts.air;
        blocks_motion[index] = facts.blocks_motion;
        const block = blockName(name);
        solid[index] = facts.blocks_motion or std.mem.eql(u8, block, "minecraft:cobweb") or std.mem.eql(u8, block, "minecraft:bamboo_sapling");
        refuses[index] = std.mem.endsWith(u8, block, "_door") or for ([_][]const u8{
            "minecraft:ladder",     "minecraft:sugar_cane",  "minecraft:bubble_column",  "minecraft:nether_portal",
            "minecraft:end_portal", "minecraft:end_gateway", "minecraft:structure_void",
        }) |refused| {
            if (std.mem.eql(u8, block, refused)) break true;
        } else false;
        const logged = property(name, "waterlogged");
        waterlogged[index] = if (logged) |value| std.mem.eql(u8, value, "true") else false;
        fillable[index] = if (logged != null) .waterloggable else if (for ([_][]const u8{ "minecraft:kelp", "minecraft:kelp_plant", "minecraft:seagrass", "minecraft:tall_seagrass" }) |plant| {
            if (std.mem.eql(u8, block, plant)) break true;
        } else false) .plant else .no;
        waterlog[index] = state;
        if (logged) |value| if (std.mem.eql(u8, value, "false")) {
            const begin = std.mem.indexOf(u8, name, "waterlogged=false").?;
            const renamed = try std.fmt.bufPrint(&scratch, "{s}waterlogged=true{s}", .{ name[0..begin], name[begin + "waterlogged=false".len ..] });
            waterlog[index] = state_names.id(renamed) orelse return error.UnknownBlockState;
            dry[waterlog[index]] = state;
        };
        // Collision boxes, without the offset some plants take from their position.
        const boxes = physics.spawnCollision(state, 0, 64, 0);
        var full = boxes.count == 1;
        var faces_of: [6][2]u32 = undefined;
        for (0..6) |face| {
            const begin: u32 = @intCast(rectangles.items.len);
            const axis: usize = switch (@as(Direction, @fromBackingInt(@intCast(face)))) {
                .down, .up => 1,
                .north, .south => 2,
                .west, .east => 0,
            };
            const positive = switch (@as(Direction, @fromBackingInt(@intCast(face)))) {
                .up, .south, .east => true,
                else => false,
            };
            for (0..boxes.count) |at| {
                const translated = boxes.get(at);
                var box: [6]f64 = undefined;
                for (&box, translated, 0..) |*value, coordinate, position| value.* = coordinate - boxes.translation[position % 3];
                if (face == 0) {
                    if (!(@abs(box[0]) < 1e-7 and @abs(box[1]) < 1e-7 and @abs(box[2]) < 1e-7 and @abs(box[3] - 1) < 1e-7 and @abs(box[4] - 1) < 1e-7 and @abs(box[5] - 1) < 1e-7)) full = false;
                }
                const touches = if (positive) box[axis + 3] >= 1 - 1e-7 else box[axis] <= 1e-7;
                if (!touches) continue;
                const across = [2]usize{ (axis + 1) % 3, (axis + 2) % 3 };
                try rectangles.append(allocator, .{ @floatCast(box[across[0]]), @floatCast(box[across[1]]), @floatCast(box[across[0] + 3]), @floatCast(box[across[1] + 3]) });
            }
            const end: u32 = @intCast(rectangles.items.len);
            if (end - begin > rectangles_max) return error.ShapeCapacity;
            faces_of[face] = .{ begin, end - begin };
        }
        faces[index] = faces_of;
        shape[index] = if (boxes.count == 0) .empty else if (full) .full else .partial;
    }
    var water: [16]u16 = undefined;
    var lava: [16]u16 = undefined;
    for (&water, &lava, 0..) |*water_state, *lava_state, level| {
        var buffer: [64]u8 = undefined;
        water_state.* = try stateId(try std.fmt.bufPrint(&buffer, "minecraft:water[level={d}]", .{level}));
        lava_state.* = try stateId(try std.fmt.bufPrint(&buffer, "minecraft:lava[level={d}]", .{level}));
    }
    var blocks: std.StringHashMapUnmanaged(u16) = .empty;
    try blocks.ensureTotalCapacity(allocator, @intCast(registry.blocks.len));
    for (registry.blocks, 0..) |info, index| {
        blocks.putAssumeCapacity(blockName(registry.block_state_names[@intCast(info.default_state)]), @intCast(index));
    }
    tables = .{
        .fluid = fluid,
        .liquid = liquid,
        .air = air,
        .blocks_motion = blocks_motion,
        .solid = solid,
        .refuses = refuses,
        .fillable = fillable,
        .waterlogged = waterlogged,
        .waterlog = waterlog,
        .dry = dry,
        .shape = shape,
        .faces = faces,
        .rectangles = try rectangles.toOwnedSlice(allocator),
        .water = water,
        .lava = lava,
        .stone = try stateId("minecraft:stone"),
        .cobblestone = try stateId("minecraft:cobblestone"),
        .obsidian = try stateId("minecraft:obsidian"),
        .basalt = try stateId("minecraft:basalt[axis=y]"),
        .soul_soil = try stateId("minecraft:soul_soil"),
        .blue_ice = try stateId("minecraft:blue_ice"),
        .blocks = blocks,
    };
    tables_ready.store(true, .release);
}

/// What the fluid tables know of a block state, for what else handles fluids, like buckets.
pub fn fluidOf(state: u16) Fluid {
    ensureTables();
    return tables.fluid[state];
}

pub fn fillableOf(state: u16) Fillable {
    ensureTables();
    return tables.fillable[state];
}

pub fn isLiquid(state: u16) bool {
    ensureTables();
    return tables.liquid[state];
}

pub fn isSolid(state: u16) bool {
    ensureTables();
    return tables.solid[state];
}

pub fn isAir(state: u16) bool {
    ensureTables();
    return tables.air[state];
}

pub fn isWaterlogged(state: u16) bool {
    ensureTables();
    return tables.waterlogged[state];
}

pub fn dryOf(state: u16) u16 {
    ensureTables();
    return tables.dry[state];
}

pub fn sourceOf(kind: Kind) u16 {
    ensureTables();
    return blockOf(.source(kind));
}

/// The state a block placed at a cell takes: waterloggable blocks placed in still water come out
/// waterlogged, as their getPlacementState makes them.
pub fn placedIn(state: u16, previous: u16) u16 {
    ensureTables();
    if (tables.fillable[state] != .waterloggable or tables.waterlogged[state]) return state;
    const fluid = tables.fluid[previous];
    return if (fluid.kind == .water and fluid.still()) tables.waterlog[state] else state;
}

/// The block state that holds a fluid on its own, FlowableFluid.getBlockStateLevel.
fn blockOf(fluid: Fluid) u16 {
    if (fluid.empty()) return 0;
    const level: usize = if (fluid.still()) 0 else 8 - @as(usize, @min(fluid.amount, 8)) + @as(usize, if (fluid.falling) 8 else 0);
    return if (fluid.kind == .water) tables.water[level] else tables.lava[level];
}

/// Whether the faces two cells share on `face`, seen from the first, cover the whole square
/// between them, VoxelShapes.adjacentSidesCoverSquare.
fn coversSquare(first: u16, second: u16, face: Direction) bool {
    if (tables.shape[first] == .full or tables.shape[second] == .full) return true;
    var rectangles: [2 * rectangles_max]Rectangle = undefined;
    var count: usize = 0;
    for ([_]struct { state: u16, face: Direction }{ .{ .state = first, .face = face }, .{ .state = second, .face = face.opposite() } }) |side| {
        const range = tables.faces[side.state][@backingInt(side.face)];
        for (tables.rectangles[range[0]..][0..range[1]]) |rectangle| {
            rectangles[count] = rectangle;
            count += 1;
        }
    }
    if (count == 0) return false;
    // Every cell of the grid the rectangle edges make must lie in some rectangle.
    var us: [2 * rectangles_max * 2 + 2]f32 = undefined;
    var vs: [2 * rectangles_max * 2 + 2]f32 = undefined;
    us[0] = 0;
    us[1] = 1;
    vs[0] = 0;
    vs[1] = 1;
    var edges: usize = 2;
    for (rectangles[0..count]) |rectangle| {
        us[edges] = std.math.clamp(rectangle[0], 0, 1);
        us[edges + 1] = std.math.clamp(rectangle[2], 0, 1);
        vs[edges] = std.math.clamp(rectangle[1], 0, 1);
        vs[edges + 1] = std.math.clamp(rectangle[3], 0, 1);
        edges += 2;
    }
    std.mem.sort(f32, us[0..edges], {}, std.sort.asc(f32));
    std.mem.sort(f32, vs[0..edges], {}, std.sort.asc(f32));
    for (0..edges - 1) |i| {
        if (us[i + 1] - us[i] < 1e-6) continue;
        const u = (us[i] + us[i + 1]) / 2;
        for (0..edges - 1) |j| {
            if (vs[j + 1] - vs[j] < 1e-6) continue;
            const v = (vs[j] + vs[j + 1]) / 2;
            const inside = for (rectangles[0..count]) |rectangle| {
                if (u > rectangle[0] and u < rectangle[2] and v > rectangle[1] and v < rectangle[3]) break true;
            } else false;
            if (!inside) return false;
        }
    }
    return true;
}

/// FlowableFluid.receivesFlow: whether fluid passes between a cell and the one on `face`.
fn receivesFlow(face: Direction, state: u16, from: u16) bool {
    if (tables.shape[from] == .full or tables.shape[state] == .full) return false;
    if (tables.shape[state] == .empty and tables.shape[from] == .empty) return true;
    return !coversSquare(state, from, face);
}

/// FlowableFluid.canFill(BlockState).
fn canFill(state: u16, signs: []const bool) bool {
    if (tables.fillable[state] != .no) return true;
    if (tables.blocks_motion[state]) return false;
    return !tables.refuses[state] and !signs[registry.block_state_to_block[state]];
}

/// FlowableFluid.canFillWithFluid: what a FluidFillable block takes. Waterloggable blocks take
/// still water only, so flowing water passes them by.
fn canFillWithFluid(state: u16, fluid: Variant) bool {
    return switch (tables.fillable[state]) {
        .no => true,
        .waterloggable => fluid.kind == .water and fluid.still,
        .plant => false,
    };
}

pub const Fluids = struct {
    pub const id = "minecraft:fluids";
    pub const Configuration = struct {
        /// The waterSourceConversion and lavaSourceConversion game rules.
        water_source_conversion: bool = true,
        lava_source_conversion: bool = false,
        /// Sections fluid ticks keep decoded, 8 KiB each.
        copies: u32 = 256,
        loot_scratch_bytes: usize = 16 * 1024,
        seed: u64 = 0x666c756964,
    };
    pub const Dependencies = struct {
        chunks: *chunks.Chunks,
        ticks: *ticks.Ticks,
        worlds: *Worlds,
        dimensions: *Dimensions,
        block_definitions: *Blocks,
        loot: *BlockLoot,
        items: *Items,
        inventories: *inventories.Inventories,
        dropped: *ItemEntities,
        players: *Players,
    };

    deps: Dependencies,
    config: Configuration,
    copies: *chunks.Copies,
    /// Reads a changed section and the six around it, for the edit observer.
    window_client: chunks.Chunks.Client,
    /// Tick kinds by variant: still water, flowing water, still lava, flowing lava.
    kinds: [4]ticks.Kind,
    /// By block, membership of the sign tag.
    signs: []bool,
    loot_scratch: std.heap.FixedBufferAllocator,
    random: std.Random.DefaultPrng,
    effects: Effects,
    /// The kind of fluid whose tick is running, while one is.
    flowing_kind: Kind = .empty,
    ultrawarm_world: u32 = std.math.maxInt(u32),
    ultrawarm: bool = false,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*Fluids {
        ensureTables();
        const self = try allocator.create(Fluids);
        self.* = .{
            .deps = deps,
            .config = configuration,
            .copies = try chunks.Copies.init(allocator, deps.chunks, configuration.copies),
            .window_client = try deps.chunks.simulation(7),
            .kinds = undefined,
            .signs = try allocator.alloc(bool, registry.blocks.len),
            .loot_scratch = .init(try allocator.alloc(u8, configuration.loot_scratch_bytes)),
            .random = .init(configuration.seed),
            .effects = try .init(allocator, deps.players),
        };
        try self.readTags();
        try deps.block_definitions.registry.onChange(self, readTags);
        for ([_][]const u8{ "minecraft:water", "minecraft:flowing_water", "minecraft:lava", "minecraft:flowing_lava" }, &self.kinds) |name, *kind| {
            kind.* = try deps.ticks.register(name, .fluid, .init(Fluids, self, fluidTick));
        }
        try deps.chunks.observe(.init(self, blocksChanged));
        return self;
    }

    fn readTags(self: *Fluids) !void {
        @memset(self.signs, false);
        const block_registry = self.deps.block_definitions.client.get("minecraft:block") orelse return;
        const tags = &block_registry.tags;
        const found = tags.find("minecraft:signs") orelse return;
        for (tags.members(found)) |member| {
            if (member >= block_registry.entries.len) continue;
            const index = tables.blocks.get(block_registry.entries[member].name) orelse continue;
            self.signs[index] = true;
        }
    }

    /// Copies of absent sections last only for the tick.
    pub fn tick(self: *Fluids) void {
        self.copies.endTick();
    }

    fn kindOf(self: *const Fluids, fluid: Variant) ticks.Kind {
        assert(fluid.kind != .empty);
        return self.kinds[(@as(usize, @backingInt(fluid.kind)) - 1) * 2 + @intFromBool(!fluid.still)];
    }

    fn inside(self: *Fluids, world: u32, position: chunks.Position) bool {
        const definition = self.deps.worlds.get(world) orelse return false;
        const bottom = definition.dimension.minimumSection() * 16;
        return position.y >= bottom and position.y < bottom + @as(i32, @intCast(definition.dimension.sectionCount() * 16));
    }

    /// Cells past the top and bottom of the world hold air.
    fn get(self: *Fluids, world: u32, position: chunks.Position) !u16 {
        if (!self.inside(world, position)) return 0;
        return self.copies.get(world, position);
    }

    fn set(self: *Fluids, world: u32, position: chunks.Position, state: u16) !void {
        if (!self.inside(world, position)) return;
        try self.copies.set(world, position, state);
    }

    fn schedule(self: *Fluids, world: u32, position: chunks.Position, fluid: Variant, delay: u32) !void {
        try self.deps.ticks.schedule(.{ .world = world, .position = .{ .x = position.x, .y = position.y, .z = position.z }, .kind = self.kindOf(fluid) }, delay);
    }

    fn isUltrawarm(self: *Fluids, world: u32) bool {
        if (self.ultrawarm_world == world) return self.ultrawarm;
        const definition = self.deps.worlds.get(world) orelse return false;
        self.ultrawarm = if (self.deps.dimensions.get(definition.dimension.name)) |dimension| dimension.ultrawarm else false;
        self.ultrawarm_world = world;
        return self.ultrawarm;
    }

    fn tickRate(self: *Fluids, world: u32, kind: Kind) u32 {
        return if (kind == .water) 5 else if (self.isUltrawarm(world)) 10 else 30;
    }

    fn decrease(self: *Fluids, world: u32, kind: Kind) u8 {
        return if (kind == .water or self.isUltrawarm(world)) 1 else 2;
    }

    fn maxFlowDistance(self: *Fluids, world: u32, kind: Kind) u32 {
        return if (kind == .water or self.isUltrawarm(world)) 4 else 2;
    }

    fn infinite(self: *const Fluids, kind: Kind) bool {
        return if (kind == .water) self.config.water_source_conversion else self.config.lava_source_conversion;
    }

    fn fluidTick(self: *Fluids, event: ticks.Event) !void {
        const world = event.world;
        const position: chunks.Position = .{ .x = event.position.x, .y = event.position.y, .z = event.position.z };
        const state = try self.get(world, position);
        const fluid = tables.fluid[state];
        // A tick runs only while the cell holds the variant it was scheduled for.
        if (fluid.empty() or self.kindOf(variant(fluid)) != event.kind) return;
        self.flowing_kind = fluid.kind;
        defer self.flowing_kind = .empty;
        try self.scheduledTick(world, position, state, fluid);
    }

    /// FlowableFluid.onScheduledTick.
    fn scheduledTick(self: *Fluids, world: u32, position: chunks.Position, state: u16, fluid: Fluid) !void {
        var block_state = state;
        var current = fluid;
        if (!current.still()) {
            const updated = try self.updatedState(world, position, block_state, current.kind);
            const delay = self.nextTickDelay(world, position, current, updated);
            if (updated.empty()) {
                current = updated;
                block_state = 0;
                try self.set(world, position, 0);
            } else if (!std.meta.eql(updated, current)) {
                current = updated;
                block_state = blockOf(updated);
                try self.set(world, position, block_state);
                try self.schedule(world, position, variant(updated), delay);
            }
        }
        try self.tryFlow(world, position, block_state, current);
    }

    fn nextTickDelay(self: *Fluids, world: u32, position: chunks.Position, old: Fluid, new: Fluid) u32 {
        const rate = self.tickRate(world, old.kind);
        if (old.kind != .lava) return rate;
        // LavaFluid.getNextTickDelay: lava that rises waits longer, three times in four.
        if (old.empty() or new.empty() or old.falling or new.falling) return rate;
        const above = self.fluidAboveMatches(world, position, new.kind) catch false;
        const new_height: f32 = if (above) 1 else @as(f32, @floatFromInt(new.amount)) / 9;
        const old_height: f32 = if (above) 1 else @as(f32, @floatFromInt(old.amount)) / 9;
        if (new_height > old_height and self.random.random().uintLessThan(u32, 4) != 0) return rate * 4;
        return rate;
    }

    fn fluidAboveMatches(self: *Fluids, world: u32, position: chunks.Position, kind: Kind) !bool {
        return tables.fluid[try self.get(world, offset(position, .up))].kind == kind;
    }

    /// FlowableFluid.getUpdatedState: the fluid a cell should hold, from the cells around it.
    fn updatedState(self: *Fluids, world: u32, position: chunks.Position, state: u16, kind: Kind) !Fluid {
        var level: u8 = 0;
        var sources: u8 = 0;
        for (horizontal) |direction| {
            const neighbour = try self.get(world, offset(position, direction));
            const fluid = tables.fluid[neighbour];
            if (fluid.kind != kind or !receivesFlow(direction, state, neighbour)) continue;
            if (fluid.still()) sources += 1;
            level = @max(level, fluid.amount);
        }
        if (sources >= 2 and self.infinite(kind)) {
            const below = try self.get(world, offset(position, .down));
            if (tables.solid[below] or isMatchingAndStill(tables.fluid[below], kind)) return .source(kind);
        }
        const above = try self.get(world, offset(position, .up));
        const fluid_above = tables.fluid[above];
        if (fluid_above.kind == kind and receivesFlow(.up, state, above)) return .flowing(kind, 8, true);
        const remaining = @as(i32, level) - self.decrease(world, kind);
        return if (remaining <= 0) .{} else .flowing(kind, @intCast(remaining), false);
    }

    fn isMatchingAndStill(fluid: Fluid, kind: Kind) bool {
        return fluid.kind == kind and fluid.still();
    }

    /// The seven argument FlowableFluid.canFlowThrough.
    fn canFlowThrough(self: *Fluids, kind: Kind, state: u16, face: Direction, from: u16) bool {
        return !isMatchingAndStill(tables.fluid[from], kind) and canFill(from, self.signs) and receivesFlow(face, state, from);
    }

    /// FlowableFluid.canFlowDownTo.
    fn canFlowDownTo(self: *Fluids, kind: Kind, state: u16, below: u16) bool {
        if (!receivesFlow(.down, state, below)) return false;
        if (tables.fluid[below].kind == kind) return true;
        return canFill(below, self.signs) and canFillWithFluid(below, .{ .kind = kind, .still = false });
    }

    fn countNeighboringSources(self: *Fluids, world: u32, position: chunks.Position, kind: Kind) !u8 {
        var count: u8 = 0;
        for (horizontal) |direction| {
            if (isMatchingAndStill(tables.fluid[try self.get(world, offset(position, direction))], kind)) count += 1;
        }
        return count;
    }

    /// WaterFluid and LavaFluid canBeReplacedWith, and EmptyFluid's, which always gives way.
    fn canBeReplacedWith(self: *Fluids, world: u32, position: chunks.Position, target: Fluid, incoming: Kind, direction: Direction) !bool {
        return switch (target.kind) {
            .empty => true,
            .water => direction == .down and incoming != .water,
            .lava => lava: {
                if (incoming != .water) break :lava false;
                const height: f32 = if (try self.fluidAboveMatches(world, position, .lava)) 1 else @as(f32, @floatFromInt(target.amount)) / 9;
                break :lava height >= 0.44444445;
            },
        };
    }

    /// FlowableFluid.tryFlow.
    fn tryFlow(self: *Fluids, world: u32, position: chunks.Position, state: u16, fluid: Fluid) !void {
        if (fluid.empty()) return;
        const below_position = offset(position, .down);
        const below = try self.get(world, below_position);
        const fluid_below = tables.fluid[below];
        if (self.canFlowThrough(fluid.kind, state, .down, below)) {
            const updated = try self.updatedState(world, below_position, below, fluid.kind);
            if (try self.canBeReplacedWith(world, below_position, fluid_below, updated.kind, .down) and canFillWithFluid(below, variant(updated))) {
                try self.flow(world, below_position, below, .down, updated);
                if (try self.countNeighboringSources(world, position, fluid.kind) >= 3) try self.flowToSides(world, position, fluid, state);
                return;
            }
        }
        if (fluid.still() or !self.canFlowDownTo(fluid.kind, state, below)) try self.flowToSides(world, position, fluid, state);
    }

    fn flowToSides(self: *Fluids, world: u32, position: chunks.Position, fluid: Fluid, state: u16) !void {
        const level: i32 = if (fluid.falling) 7 else @as(i32, fluid.amount) - self.decrease(world, fluid.kind);
        if (level <= 0) return;
        var spread: [6]?Fluid = @splat(null);
        try self.getSpread(world, position, state, fluid.kind, &spread);
        for (spread_order) |direction| {
            const target = spread[@backingInt(direction)] orelse continue;
            const at = offset(position, direction);
            try self.flow(world, at, try self.get(world, at), direction, target);
        }
    }

    /// FlowableFluid.getSpread: the sides that lead soonest to a drop, and what flows there.
    fn getSpread(self: *Fluids, world: u32, position: chunks.Position, state: u16, kind: Kind, spread: *[6]?Fluid) !void {
        var best: u32 = 1000;
        for (horizontal) |direction| {
            const at = offset(position, direction);
            const neighbour = try self.get(world, at);
            const fluid = tables.fluid[neighbour];
            if (!self.canFlowThrough(kind, state, direction, neighbour)) continue;
            const updated = try self.updatedState(world, at, neighbour, kind);
            if (!canFillWithFluid(neighbour, variant(updated))) continue;
            const distance = if (try self.spreadCanFlowDownTo(world, at, neighbour, kind)) 0 else try self.minFlowDownDistance(world, at, 1, direction.opposite(), neighbour, kind);
            if (distance < best) spread.* = @splat(null);
            if (distance <= best) {
                if (try self.canBeReplacedWith(world, at, fluid, updated.kind, direction)) spread[@backingInt(direction)] = updated;
                best = distance;
            }
        }
    }

    fn spreadCanFlowDownTo(self: *Fluids, world: u32, position: chunks.Position, state: u16, kind: Kind) !bool {
        return self.canFlowDownTo(kind, state, try self.get(world, offset(position, .down)));
    }

    /// FlowableFluid.getMinFlowDownDistance: how many cells from here a drop lies, searching no
    /// further than the fluid flows and never back the way it came.
    fn minFlowDownDistance(self: *Fluids, world: u32, position: chunks.Position, distance: u32, from: Direction, state: u16, kind: Kind) !u32 {
        var best: u32 = 1000;
        for (horizontal) |direction| {
            if (direction == from) continue;
            const at = offset(position, direction);
            const neighbour = try self.get(world, at);
            if (!self.canFlowThrough(kind, state, direction, neighbour) or !canFillWithFluid(neighbour, .{ .kind = kind, .still = false })) continue;
            if (try self.spreadCanFlowDownTo(world, at, neighbour, kind)) return distance;
            if (distance >= self.maxFlowDistance(world, kind)) continue;
            best = @min(best, try self.minFlowDownDistance(world, at, distance + 1, direction.opposite(), neighbour, kind));
        }
        return best;
    }

    /// FlowableFluid.flow, with LavaFluid's: lava falling onto water makes stone.
    fn flow(self: *Fluids, world: u32, position: chunks.Position, state: u16, direction: Direction, fluid: Fluid) !void {
        if (self.flowing_kind == .lava and direction == .down and tables.fluid[state].kind == .water) {
            if (tables.liquid[state]) try self.set(world, position, tables.stone);
            try self.extinguished(world, position);
            return;
        }
        switch (tables.fillable[state]) {
            // Waterloggable.tryFillWithFluid takes still water only.
            .waterloggable => _ = try self.fill(world, position, state, fluid),
            .plant => {},
            .no => {
                // WaterFluid.beforeBreakingBlock drops what the block drops, LavaFluid's hisses.
                if (!tables.air[state]) {
                    if (fluid.kind == .water) try self.dropLoot(world, position, state) else try self.extinguished(world, position);
                }
                try self.set(world, position, blockOf(fluid));
            },
        }
    }

    /// Waterloggable.tryFillWithFluid: still water fills a dry waterloggable block and ticks there.
    pub fn fill(self: *Fluids, world: u32, position: chunks.Position, state: u16, fluid: Fluid) !bool {
        if (tables.fillable[state] != .waterloggable or tables.waterlogged[state] or fluid.kind != .water or !fluid.still()) return false;
        try self.set(world, position, tables.waterlog[state]);
        try self.schedule(world, position, .{ .kind = .water, .still = true }, 5);
        return true;
    }

    /// FluidBlock.receiveNeighborFluids, in the neighbour update of an edit: lava next to water
    /// becomes obsidian where it is a source and cobblestone where it flows, and lava over soul
    /// soil next to blue ice basalt. The change chains on the edit, as in vanilla.
    fn touchWater(self: *Fluids, world: u32, position: chunks.Position) !void {
        const state = try self.get(world, position);
        const fluid = tables.fluid[state];
        if (fluid.kind != .lava or !tables.liquid[state]) return;
        const on_soul_soil = try self.get(world, offset(position, .down)) == tables.soul_soil;
        for (contact_order) |direction| {
            const neighbour = try self.get(world, offset(position, direction.opposite()));
            if (tables.fluid[neighbour].kind == .water) {
                try self.deps.chunks.chain(world, position, if (fluid.still()) tables.obsidian else tables.cobblestone);
                try self.extinguished(world, position);
                return;
            }
            if (on_soul_soil and neighbour == tables.blue_ice) {
                try self.deps.chunks.chain(world, position, tables.basalt);
                try self.extinguished(world, position);
                return;
            }
        }
    }

    /// WorldEvents.LAVA_EXTINGUISHED, which clients play as a hiss and smoke. World events reach
    /// the players within 64 blocks, as ServerWorld.syncWorldEvent sends them.
    fn extinguished(self: *Fluids, world: u32, position: chunks.Position) !void {
        self.effects.worldEvent(world, position, 1501, 0);
    }

    fn blocksChanged(self: *Fluids, section: chunks.Section, edits: []const chunks.BlockEdit, previous: []const u16) void {
        self.reactToChanges(section, edits, previous) catch |err| std.log.warn("event=fluid_update_failed reason={t}", .{err});
    }

    /// The neighbour updates of an edit: fluids it touches tick again, a fluid placed ticks, and
    /// lava it touches checks for water.
    fn reactToChanges(self: *Fluids, section: chunks.Section, edits: []const chunks.BlockEdit, previous: []const u16) !void {
        // Sections can lie past the last block position, where no block has neighbours to react.
        const origin: chunks.Position = .{
            .x = std.math.mul(i32, section.x, 16) catch return,
            .y = std.math.mul(i32, section.y, 16) catch return,
            .z = std.math.mul(i32, section.z, 16) catch return,
        };
        // The section and the six around it, read once. Most edits touch no fluid, and a large
        // batch then costs seven palette checks rather than a read per cell.
        const steps = [_][3]i32{ .{ 0, 0, 0 }, .{ 0, -1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 }, .{ -1, 0, 0 }, .{ 1, 0, 0 } };
        var sections: [7]chunks.Section = undefined;
        var slots: [7]?u8 = @splat(null);
        var count: u8 = 0;
        for (steps, 0..) |step, at| {
            const neighbour: chunks.Section = .{
                .world = section.world,
                .x = std.math.add(i32, section.x, step[0]) catch continue,
                .y = std.math.add(i32, section.y, step[1]) catch continue,
                .z = std.math.add(i32, section.z, step[2]) catch continue,
            };
            const corner: chunks.Position = .{ .x = 0, .y = std.math.mul(i32, neighbour.y, 16) catch continue, .z = 0 };
            if (!self.inside(section.world, corner)) continue;
            sections[count] = neighbour;
            slots[at] = count;
            count += 1;
        }
        var window = chunks.ReadWindow(7).init(self.window_client);
        defer window.deinit();
        var views: [7]chunks.View = undefined;
        try window.readMany(sections[0..count], views[0..count]);
        const any = for (views[0..count]) |view| {
            if (holdsFluid(view)) break true;
        } else false;
        if (!any) return;
        for (edits, previous) |edit, old| {
            if (edit.state == old) continue;
            const local = [3]i32{ edit.index & 15, edit.index >> 8, (edit.index >> 4) & 15 };
            const position = chunks.Position{ .x = origin.x + local[0], .y = origin.y + local[1], .z = origin.z + local[2] };
            // FluidBlock.onBlockAdded.
            if (tables.liquid[edit.state] and registry.block_state_to_block[edit.state] != registry.block_state_to_block[old]) {
                try self.schedule(section.world, position, variant(tables.fluid[edit.state]), self.tickRate(section.world, tables.fluid[edit.state].kind));
                if (tables.fluid[edit.state].kind == .lava) try self.touchWater(section.world, position);
            }
            for (std.enums.values(Direction)) |direction| {
                const step = direction.step();
                const cell = [3]i32{ local[0] + step[0], local[1] + step[1], local[2] + step[2] };
                // Which of the seven sections the neighbour lies in.
                const at: usize = if (cell[1] < 0) 1 else if (cell[1] > 15) 2 else if (cell[2] < 0) 3 else if (cell[2] > 15) 4 else if (cell[0] < 0) 5 else if (cell[0] > 15) 6 else 0;
                const slot = slots[at] orelse continue;
                const index: u12 = @intCast(@mod(cell[1], 16) * 256 + @mod(cell[2], 16) * 16 + @mod(cell[0], 16));
                const state = views[slot].get(index);
                const fluid = tables.fluid[state];
                if (fluid.empty()) continue;
                const neighbour: chunks.Position = .{
                    .x = std.math.add(i32, origin.x, cell[0]) catch continue,
                    .y = std.math.add(i32, origin.y, cell[1]) catch continue,
                    .z = std.math.add(i32, origin.z, cell[2]) catch continue,
                };
                // FluidBlock.neighborUpdate and getStateForNeighborUpdate, and the waterlogged
                // blocks' own getStateForNeighborUpdate.
                try self.schedule(section.world, neighbour, variant(fluid), self.tickRate(section.world, fluid.kind));
                if (fluid.kind == .lava and tables.liquid[state]) try self.touchWater(section.world, neighbour);
            }
        }
    }

    fn holdsFluid(view: chunks.View) bool {
        switch (view) {
            .uniform => |state| return !tables.fluid[state].empty(),
            .palette => |palette| {
                for (0..palette.paletteCount()) |rank| if (!tables.fluid[palette.state(rank)].empty()) return true;
                return false;
            },
            .dense => {
                for (0..4096) |index| if (!tables.fluid[view.get(@intCast(index))].empty()) return true;
                return false;
            },
        }
    }

    /// What a block drops when it breaks without a tool, Block.dropStacks.
    pub fn dropLoot(self: *Fluids, world: u32, position: chunks.Position, state: u16) !void {
        const table = self.deps.loot.table(state) orelse return;
        self.loot_scratch.reset();
        var neighbors: [16]loot_tables.Neighbor = undefined;
        for (table.offsets, neighbors[0..table.offsets.len]) |at, *neighbor| {
            const cell: chunks.Position = .{ .x = position.x + at.x, .y = position.y + at.y, .z = position.z + at.z };
            neighbor.* = .{ .offset = at, .state = try self.get(world, cell) };
        }
        const random = self.random.random();
        var buffer: [loot_tables.maximum_drops]loot_tables.Drop = undefined;
        const context: loot_tables.Context = .{
            .items = self.deps.items.deps.definitions,
            .state = state,
            .location = .{ .world = world, .x = @floatFromInt(position.x), .y = @floatFromInt(position.y), .z = @floatFromInt(position.z) },
            .neighbors = neighbors[0..table.offsets.len],
            .random = random,
            .scratch = &self.loot_scratch,
        };
        const drops = table.evaluate(&context, &buffer) catch |err| switch (err) {
            error.OutOfMemory, error.LootCapacity => return,
            else => return err,
        };
        if (drops.len == 0 or !self.deps.dropped.canCreate(drops.len)) return;
        var requests: [loot_tables.maximum_drops]ItemEntities.Spawn = undefined;
        var spawned: [loot_tables.maximum_drops]entities.Id = undefined;
        for (drops, requests[0..drops.len]) |drop, *request| request.* = .{
            .world = world,
            .position = .{
                @as(f64, @floatFromInt(position.x)) + 0.25 + random.float(f64) * 0.5,
                @as(f64, @floatFromInt(position.y)) + 0.25 + random.float(f64) * 0.5 - 0.125,
                @as(f64, @floatFromInt(position.z)) + 0.25 + random.float(f64) * 0.5,
            },
            .velocity = .{ random.float(f64) * 0.2 - 0.1, 0.2, random.float(f64) * 0.2 - 0.1 },
            .stack = .{ .item = try item_data.define(self.deps.inventories, drop.kind, drop.components), .count = drop.count },
        };
        try self.deps.dropped.createMany(requests[0..drops.len], spawned[0..drops.len]);
    }
};

fn offset(position: chunks.Position, direction: Direction) chunks.Position {
    const step = direction.step();
    return .{ .x = position.x + step[0], .y = position.y + step[1], .z = position.z + step[2] };
}

test "fluid states map to the block states that hold them, as vanilla numbers levels" {
    ensureTables();
    const source = tables.fluid[try stateId("minecraft:water[level=0]")];
    try std.testing.expect(source.still() and source.kind == .water);
    try std.testing.expectEqual(try stateId("minecraft:water[level=0]"), blockOf(source));
    const flowing = tables.fluid[try stateId("minecraft:water[level=3]")];
    try std.testing.expect(!flowing.still() and flowing.amount == 5 and !flowing.falling);
    try std.testing.expectEqual(try stateId("minecraft:water[level=3]"), blockOf(flowing));
    const falling = tables.fluid[try stateId("minecraft:lava[level=8]")];
    try std.testing.expect(falling.falling and falling.amount == 8 and falling.kind == .lava);
    try std.testing.expectEqual(try stateId("minecraft:lava[level=8]"), blockOf(.flowing(.lava, 8, true)));
    // A waterlogged block holds a water source and turns back into the same block dry.
    const dry = try stateId("minecraft:oak_stairs[facing=north,half=bottom,shape=straight,waterlogged=false]");
    try std.testing.expect(tables.fluid[tables.waterlog[dry]].still());
    try std.testing.expect(tables.fluid[dry].empty());
}

test "fluid passes faces that shapes leave open and stops at faces they cover" {
    ensureTables();
    const air: u16 = 0;
    const stone = tables.stone;
    const bottom_slab = try stateId("minecraft:oak_slab[type=bottom,waterlogged=false]");
    const top_slab = try stateId("minecraft:oak_slab[type=top,waterlogged=false]");
    try std.testing.expect(receivesFlow(.down, air, air));
    try std.testing.expect(!receivesFlow(.north, air, stone));
    // A bottom slab leaves its top face open, so water above it still reaches into it.
    try std.testing.expect(receivesFlow(.down, air, bottom_slab));
    // A top slab covers its top face.
    try std.testing.expect(!receivesFlow(.down, air, top_slab));
    // Sideways, a bottom slab covers only the lower half of each face.
    try std.testing.expect(receivesFlow(.east, air, bottom_slab));
    // A bottom slab under a top slab: their shared face is covered by neither, but the top
    // slab's lower face and the bottom slab's upper face together do not touch.
    try std.testing.expect(receivesFlow(.down, top_slab, bottom_slab));
}
