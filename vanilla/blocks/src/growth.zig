//! Vanilla growth on random and scheduled ticks. Grass spreads onto dirt it can light and dies
//! under blocks that shut light out, leaves that no log holds decay, and sugar cane grows up to
//! three tall and breaks when it loses its ground. Rules follow vanilla 1.21.8, the gameplay
//! baseline: SpreadableBlock, LeavesBlock and SugarCaneBlock.

const std = @import("std");
const chunks = @import("chunks");
const game_data = @import("game_data");
const entities = @import("entities");
const inventories = @import("inventories");
const ticks = @import("ticks").ticks;
const random_ticks = @import("random_ticks").random_ticks;
const Lighting = @import("terrain").lighting.Lighting;
const LightSample = @import("terrain").lighting.Sample;
const Blocks = @import("vanilla_content").blocks.Blocks;
const Time = @import("vanilla_world").time.Time;
const Weather = @import("vanilla_world").weather.Weather;
const Items = @import("vanilla_items").items.Items;
const loot_tables = @import("vanilla_items").loot;
const item_data = @import("vanilla_items").item_data;
const BlockLoot = @import("block_loot.zig").BlockLoot;
const ItemEntities = @import("vanilla_item_entities").item_entities.ItemEntities;

const assert = std.debug.assert;
const registry = game_data.registry;
const state_names = @import("state_names.zig");

const Kind = enum(u8) { other, grass, leaves, sugar_cane };

/// What growth knows of each block state from its name, built once.
const Tables = struct {
    kinds: []const Kind,
    /// The `distance` property, 0 for states without one.
    distance: []const u8,
    persistent: []const bool,
    waterlogged: []const bool,
    /// The state with distance 1 and every other property the same, for leaves.
    leaf_base: []const u16,
    /// States between consecutive distances of a leaf block.
    leaf_stride: []const u16,
    grass: [2]u16,
    dirt: u16,
    snow_layer: u16,
    water: u16,
    sugar_cane: u16,
    /// The first and last frosted ice states.
    frosted_ice: [2]u16,
    /// Blocks by name, for tags, whose members name blocks by their place in another registry.
    blocks: std.StringHashMapUnmanaged(u16),
};

var tables: Tables = undefined;
var tables_ready = std.atomic.Value(bool).init(false);

/// The tables are game data, like the registry they come from, so they live for the process.
/// They are first built while the server starts, before any thread but the main one runs.
fn ensureTables() void {
    if (tables_ready.load(.acquire)) return;
    prepareTables(std.heap.page_allocator) catch |err| std.debug.panic("growth tables: {t}", .{err});
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

fn stateId(name: []const u8) !u16 {
    return @intCast(registry.blockStateId(name) orelse return error.UnknownBlockState);
}

/// Reads the state names once.
fn prepareTables(allocator: std.mem.Allocator) !void {
    if (tables_ready.load(.acquire)) return;
    const count = registry.block_state_names.len;
    const kinds = try allocator.alloc(Kind, count);
    const distance = try allocator.alloc(u8, count);
    const persistent = try allocator.alloc(bool, count);
    const waterlogged = try allocator.alloc(bool, count);
    const leaf_base = try allocator.alloc(u16, count);
    const leaf_stride = try allocator.alloc(u16, count);
    var scratch: [256]u8 = undefined;
    for (registry.block_state_names, 0..) |name, state| {
        const block_name = name[0 .. std.mem.indexOfScalar(u8, name, '[') orelse name.len];
        kinds[state] = if (std.mem.eql(u8, block_name, "minecraft:grass_block"))
            .grass
        else if (std.mem.eql(u8, block_name, "minecraft:sugar_cane"))
            .sugar_cane
        else if (std.mem.endsWith(u8, block_name, "_leaves"))
            .leaves
        else
            .other;
        distance[state] = if (property(name, "distance")) |value| std.fmt.parseInt(u8, value, 10) catch 0 else 0;
        persistent[state] = if (property(name, "persistent")) |value| std.mem.eql(u8, value, "true") else false;
        waterlogged[state] = if (property(name, "waterlogged")) |value| std.mem.eql(u8, value, "true") else false;
        leaf_base[state] = @intCast(state);
        leaf_stride[state] = 0;
        if (kinds[state] != .leaves or distance[state] == 0) continue;
        // The same leaf at distance 1 and 2 gives where its distances lie.
        var ids: [2]u16 = undefined;
        for (&ids, 1..) |*id, value| {
            const begin = std.mem.indexOf(u8, name, "distance=").?;
            const renamed = try std.fmt.bufPrint(&scratch, "{s}distance={d}{s}", .{ name[0..begin], value, name[begin + "distance=".len + 1 ..] });
            id.* = state_names.id(renamed) orelse return error.UnknownBlockState;
        }
        leaf_base[state] = ids[0];
        leaf_stride[state] = ids[1] - ids[0];
    }
    var blocks: std.StringHashMapUnmanaged(u16) = .empty;
    try blocks.ensureTotalCapacity(allocator, @intCast(registry.blocks.len));
    for (registry.blocks, 0..) |info, index| {
        const name = registry.block_state_names[@intCast(info.default_state)];
        blocks.putAssumeCapacity(name[0 .. std.mem.indexOfScalar(u8, name, '[') orelse name.len], @intCast(index));
    }
    tables = .{
        .kinds = kinds,
        .distance = distance,
        .persistent = persistent,
        .waterlogged = waterlogged,
        .leaf_base = leaf_base,
        .leaf_stride = leaf_stride,
        .grass = .{ try stateId("minecraft:grass_block[snowy=false]"), try stateId("minecraft:grass_block[snowy=true]") },
        .dirt = try stateId("minecraft:dirt"),
        .snow_layer = try stateId("minecraft:snow[layers=1]"),
        .water = try stateId("minecraft:water[level=0]"),
        .sugar_cane = @intCast(registry.blocks[registry.block_state_to_block[try stateId("minecraft:sugar_cane[age=0]")]].default_state),
        .blocks = blocks,
        .frosted_ice = frosted: {
            const info = registry.blocks[registry.block_state_to_block[try stateId("minecraft:frosted_ice[age=0]")]];
            break :frosted .{ @intCast(info.min_state), @intCast(info.max_state) };
        },
    };
    tables_ready.store(true, .release);
}

pub const Growth = struct {
    pub const id = "minecraft:growth";
    pub const Configuration = struct { loot_scratch_bytes: usize = 16 * 1024, seed: u64 = 0x67726f777468 };
    pub const Dependencies = struct {
        chunks: *chunks.Chunks,
        ticks: *ticks.Ticks,
        random_ticks: *random_ticks.RandomTicks.Registry,
        lighting: *Lighting,
        block_definitions: *Blocks,
        time: *Time,
        weather: *Weather,
        loot: *BlockLoot,
        items: *Items,
        inventories: *inventories.Inventories,
        dropped: *ItemEntities,
    };

    deps: Dependencies,
    /// Reads blocks one at a time from the simulation budget.
    chunk_client: chunks.Chunks.Client,
    /// Reads a changed section and the six around it, nested in plugins that hold none.
    window_client: chunks.Chunks.Client,
    leaves_tick: ticks.Kind,
    sugar_cane_tick: ticks.Kind,
    /// By block, membership of the tags the rules read.
    logs: []bool,
    sugar_cane_ground: []bool,
    snow: []bool,
    loot_scratch: std.heap.FixedBufferAllocator,
    random: std.Random.DefaultPrng,
    /// The sections around the random tick being run, read once for its section.
    hit_blocks: ?*const random_ticks.Blocks = null,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*Growth {
        ensureTables();
        const self = try allocator.create(Growth);
        self.* = .{
            .deps = deps,
            .chunk_client = try deps.chunks.simulation(1),
            .window_client = try deps.chunks.simulation(7),
            .leaves_tick = undefined,
            .sugar_cane_tick = undefined,
            .logs = try allocator.alloc(bool, registry.blocks.len),
            .sugar_cane_ground = try allocator.alloc(bool, registry.blocks.len),
            .snow = try allocator.alloc(bool, registry.blocks.len),
            .loot_scratch = .init(try allocator.alloc(u8, configuration.loot_scratch_bytes)),
            .random = .init(configuration.seed),
        };
        try self.readTags();
        try deps.block_definitions.registry.onChange(self, readTags);
        self.leaves_tick = try deps.ticks.register("minecraft:leaves", .block, .init(Growth, self, leavesTick));
        self.sugar_cane_tick = try deps.ticks.register("minecraft:sugar_cane", .block, .init(Growth, self, sugarCaneTick));
        try self.registerRandomTicks(deps.random_ticks);
        try deps.chunks.observe(.init(self, blocksChanged));
        return self;
    }

    /// Tags come with the block definitions, which a datapack may change, so they are read again
    /// each time those are published. A tag a datapack leaves out has no members, as in vanilla.
    fn readTags(self: *Growth) !void {
        for ([_][]bool{ self.logs, self.sugar_cane_ground, self.snow }) |output| @memset(output, false);
        const block_registry = self.deps.block_definitions.client.get("minecraft:block") orelse return;
        const tags = &block_registry.tags;
        for ([_]struct { name: []const u8, output: []bool }{
            .{ .name = "minecraft:logs", .output = self.logs },
            .{ .name = "minecraft:dirt", .output = self.sugar_cane_ground },
            .{ .name = "minecraft:sand", .output = self.sugar_cane_ground },
            .{ .name = "minecraft:snow", .output = self.snow },
        }) |tag| {
            const found = tags.find(tag.name) orelse continue;
            for (tags.members(found)) |member| {
                if (member >= block_registry.entries.len) continue;
                const index = tables.blocks.get(block_registry.entries[member].name) orelse continue;
                tag.output[index] = true;
            }
        }
    }

    /// Random ticks reach only cells a hit could change: grass that dies or has dirt to spread
    /// to, sugar cane that can grow, and leaves that decay. A hit on any other of them does
    /// nothing in vanilla.
    fn registerRandomTicks(self: *Growth, ticking: *random_ticks.RandomTicks.Registry) !void {
        const grass = try ticking.addSet();
        const dirt = try ticking.addSet();
        // What grass and dirt cannot live under: grass under it dies, and dirt under it is
        // no target to spread onto.
        const cover = try ticking.addSet();
        const water = try ticking.addSet();
        const sugar_cane = try ticking.addSet();
        const air = try ticking.addSet();
        const decaying = try ticking.addSet();
        for (0..registry.block_state_names.len) |index| {
            const state: u16 = @intCast(index);
            if (tables.kinds[state] == .grass) ticking.include(grass, state);
            if (state == tables.dirt) ticking.include(dirt, state);
            if (!self.livesUnder(tables.grass[0], state)) ticking.include(cover, state);
            if (self.physics(state).fluid == .water) ticking.include(water, state);
            if (tables.kinds[state] == .sugar_cane) ticking.include(sugar_cane, state);
            if (self.physics(state).air) ticking.include(air, state);
            if (tables.kinds[state] == .leaves and tables.distance[state] == 7 and !tables.persistent[state]) ticking.include(decaying, state);
        }
        // SpreadingSnowyBlock.randomTick: grass dies when covered, and otherwise tries cells
        // from 3 below to 1 above it for dirt with neither cover nor water on top.
        const grass_nodes = [_]random_ticks.Node{
            .{ .set = dirt },
            .{ .set = cover },
            .{ .set = water },
            .{ .either = .{ 1, 2 } },
            .{ .offset = .{ .of = 3, .by = .{ 0, 1, 0 } } },
            .{ .not = 4 },
            .{ .both = .{ 0, 5 } },
            .{ .any = .{ .of = 6, .low = .{ -1, -3, -1 }, .high = .{ 1, 1, 1 } } },
            .{ .offset = .{ .of = 1, .by = .{ 0, 1, 0 } } },
            .{ .either = .{ 7, 8 } },
        };
        try ticking.register(.{ .selected = grass, .nodes = &grass_nodes }, .init(Growth, self, grassRandomTick));
        // SugarCaneBlock.randomTick: cane grows into air above it until it is three tall.
        const sugar_cane_nodes = [_]random_ticks.Node{
            .{ .set = air },
            .{ .offset = .{ .of = 0, .by = .{ 0, 1, 0 } } },
            .{ .set = sugar_cane },
            .{ .offset = .{ .of = 2, .by = .{ 0, -1, 0 } } },
            .{ .offset = .{ .of = 2, .by = .{ 0, -2, 0 } } },
            .{ .both = .{ 3, 4 } },
            .{ .not = 5 },
            .{ .both = .{ 1, 6 } },
        };
        try ticking.register(.{ .selected = sugar_cane, .nodes = &sugar_cane_nodes }, .init(Growth, self, sugarCaneRandomTick));
        // LeavesBlock.randomTick: leaves no log holds decay.
        try ticking.register(.{ .selected = decaying }, .init(Growth, self, leavesRandomTick));
    }

    fn block(state: u16) u16 {
        return registry.block_state_to_block[state];
    }

    /// During a random tick, writes wait for the hit to end, so they apply together.
    fn set(self: *Growth, world: u32, position: chunks.Position, state: u16) !void {
        if (self.hit_blocks) |blocks| return blocks.set(position, state);
        try self.deps.chunks.setBlock(world, position, state);
    }

    fn get(self: *Growth, world: u32, position: chunks.Position) !u16 {
        if (self.hit_blocks) |blocks| if (blocks.get(position)) |state| return state;
        return self.chunk_client.getBlock(world, position);
    }

    fn physics(self: *Growth, state: u16) game_data.physics_data.State {
        return self.deps.block_definitions.get(state);
    }

    fn offset(position: chunks.Position, x: i32, y: i32, z: i32) chunks.Position {
        return .{ .x = position.x + x, .y = position.y + y, .z = position.z + z };
    }

    /// Whether the world has a block there to read.
    fn inside(self: *Growth, world: u32, position: chunks.Position) bool {
        const definition = self.deps.lighting.deps.worlds.get(world) orelse return false;
        const bottom = definition.dimension.minimumSection() * 16;
        return position.y >= bottom and position.y < bottom + @as(i32, @intCast(definition.dimension.sectionCount() * 16));
    }

    // Grass, SpreadingSnowyBlock.

    /// Grass lives under a single snow layer, or under a block light passes up into that is no
    /// full fluid.
    fn canStayAlive(self: *Growth, world: u32, state: u16, position: chunks.Position) !bool {
        const up = offset(position, 0, 1, 0);
        if (!self.inside(world, up)) return true;
        return self.livesUnder(state, try self.get(world, up));
    }

    fn livesUnder(self: *Growth, state: u16, above: u16) bool {
        if (above == tables.snow_layer) return true;
        const fluid = self.physics(above);
        if (fluid.fluid != .none and fluid.amount == 8) return false;
        const light = self.deps.block_definitions.light;
        const dampening: u8 = if (light.blocked(state, above, .up)) 16 else light.states[above].opacity;
        return dampening < 15;
    }

    fn canPropagate(self: *Growth, world: u32, state: u16, position: chunks.Position) !bool {
        if (!try self.canStayAlive(world, state, position)) return false;
        const up = offset(position, 0, 1, 0);
        if (!self.inside(world, up)) return true;
        return self.physics(try self.get(world, up)).fluid != .water;
    }

    /// What the time of day and the weather take from the sky's light, as World.calculateAmbientDarkness.
    fn skyDarken(self: *Growth) u4 {
        // DimensionType.getSkyAngle.
        const day: f64 = @floatFromInt(@mod(self.deps.time.day_time, 24000));
        const turn = day / 24000 - 0.25 - @floor(day / 24000 - 0.25);
        const angle = (turn * 2 + (0.5 - @cos(turn * std.math.pi) / 2)) / 3;
        var light = 1 - std.math.clamp(1 - (@cos(angle * 2 * std.math.pi) * 2 + 0.5), 0, 1);
        light *= 1 - @as(f64, self.deps.weather.rain_level) * 5 / 16;
        light *= 1 - @as(f64, self.deps.weather.thunder_level) * 5 / 16;
        return @intFromFloat((1 - light) * 11);
    }

    fn grassRandomTick(self: *Growth, hit: random_ticks.Hit) !void {
        self.hit_blocks = hit.blocks;
        defer self.hit_blocks = null;
        const world = hit.world;
        const position = hit.position;
        if (!try self.canStayAlive(world, hit.state, position)) {
            try self.set(world, position, tables.dirt);
            return;
        }
        const up = offset(position, 0, 1, 0);
        if (!self.inside(world, up)) return;
        var sample: [1]?LightSample = undefined;
        try self.deps.lighting.sampleMany(world, &.{up}, &sample);
        // Light that is not in memory yet is light the server cannot judge by. The hit is lost,
        // as one is in vanilla for a block that is not loaded.
        const light = sample[0] orelse return;
        const brightness = @max(light.block, light.sky -| self.skyDarken());
        if (brightness < 9) return;
        const random = self.random.random();
        for (0..4) |_| {
            const target = offset(position, random.intRangeAtMost(i32, -1, 1), random.intRangeAtMost(i32, -3, 1), random.intRangeAtMost(i32, -1, 1));
            if (!self.inside(world, target)) continue;
            if (try self.get(world, target) != tables.dirt) continue;
            if (!try self.canPropagate(world, tables.grass[0], target)) continue;
            const over = offset(target, 0, 1, 0);
            const snowy = self.inside(world, over) and self.snow[block(try self.get(world, over))];
            try self.set(world, target, tables.grass[@intFromBool(snowy)]);
        }
    }

    // Leaves, LeavesBlock.

    fn distanceAt(self: *Growth, state: u16) u8 {
        if (self.logs[block(state)]) return 0;
        return if (tables.distance[state] != 0) tables.distance[state] else 7;
    }

    fn withDistance(state: u16, distance: u8) u16 {
        assert(distance >= 1 and distance <= 7 and tables.leaf_stride[state] != 0);
        return tables.leaf_base[state] + (distance - 1) * tables.leaf_stride[state];
    }

    fn leavesTick(self: *Growth, event: ticks.Event) !void {
        const position: chunks.Position = .{ .x = event.position.x, .y = event.position.y, .z = event.position.z };
        const state = try self.get(event.world, position);
        if (tables.kinds[state] != .leaves or tables.leaf_stride[state] == 0) return;
        var distance: u8 = 7;
        for (directions) |direction| {
            const neighbour = offset(position, direction[0], direction[1], direction[2]);
            if (!self.inside(event.world, neighbour)) continue;
            distance = @min(distance, self.distanceAt(try self.get(event.world, neighbour)) + 1);
            if (distance == 1) break;
        }
        const updated = withDistance(state, distance);
        if (updated != state) try self.set(event.world, position, updated);
    }

    fn leavesRandomTick(self: *Growth, hit: random_ticks.Hit) !void {
        self.hit_blocks = hit.blocks;
        defer self.hit_blocks = null;
        try self.dropLoot(hit.world, hit.position, hit.state);
        // A waterlogged leaf leaves its water behind.
        try self.set(hit.world, hit.position, if (tables.waterlogged[hit.state]) tables.water else 0);
    }

    // Sugar cane, SugarCaneBlock.

    fn canSurvive(self: *Growth, world: u32, position: chunks.Position) !bool {
        const down = offset(position, 0, -1, 0);
        if (!self.inside(world, down)) return false;
        const below = try self.get(world, down);
        if (tables.kinds[below] == .sugar_cane) return true;
        if (!self.sugar_cane_ground[block(below)]) return false;
        for ([_][2]i32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } }) |side| {
            const state = try self.get(world, offset(down, side[0], 0, side[1]));
            if (self.physics(state).fluid == .water or state == tables.frosted_ice[0] or (state >= tables.frosted_ice[0] and state <= tables.frosted_ice[1])) return true;
        }
        return false;
    }

    fn sugarCaneTick(self: *Growth, event: ticks.Event) !void {
        const position: chunks.Position = .{ .x = event.position.x, .y = event.position.y, .z = event.position.z };
        const state = try self.get(event.world, position);
        if (tables.kinds[state] != .sugar_cane or try self.canSurvive(event.world, position)) return;
        try self.dropLoot(event.world, position, state);
        try self.set(event.world, position, 0);
    }

    fn sugarCaneRandomTick(self: *Growth, hit: random_ticks.Hit) !void {
        self.hit_blocks = hit.blocks;
        defer self.hit_blocks = null;
        const world = hit.world;
        const position = hit.position;
        const up = offset(position, 0, 1, 0);
        if (!self.inside(world, up) or !self.physics(try self.get(world, up)).air) return;
        var height: i32 = 1;
        while (height < 3) : (height += 1) {
            const down = offset(position, 0, -height, 0);
            if (!self.inside(world, down) or tables.kinds[try self.get(world, down)] != .sugar_cane) break;
        }
        if (height >= 3) return;
        const age = hit.state - tables.sugar_cane;
        if (age == 15) {
            try self.set(world, up, tables.sugar_cane);
            try self.set(world, position, tables.sugar_cane);
        } else try self.set(world, position, hit.state + 1);
    }

    // Neighbour changes, as vanilla's updateShape.

    const directions = [_][3]i32{ .{ 0, -1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 }, .{ -1, 0, 0 }, .{ 1, 0, 0 } };

    fn blocksChanged(self: *Growth, section: chunks.Section, edits: []const chunks.BlockEdit, previous: []const u16) void {
        self.reactToChanges(section, edits, previous) catch |err| std.log.warn("event=growth_update_failed reason={t}", .{err});
    }

    /// Whether a section holds any block whose neighbours' changes it reacts to.
    fn reactive(view: chunks.View) bool {
        switch (view) {
            .uniform => |state| return tables.kinds[state] == .leaves or tables.kinds[state] == .sugar_cane,
            .palette => |palette| {
                for (0..palette.paletteCount()) |rank| {
                    const kind = tables.kinds[palette.state(rank)];
                    if (kind == .leaves or kind == .sugar_cane) return true;
                }
                return false;
            },
            .dense => {
                for (0..4096) |index| {
                    const kind = tables.kinds[view.get(@intCast(index))];
                    if (kind == .leaves or kind == .sugar_cane) return true;
                }
                return false;
            },
        }
    }

    fn reactToChanges(self: *Growth, section: chunks.Section, edits: []const chunks.BlockEdit, previous: []const u16) !void {
        // Sections can lie past the last block position, where no block has neighbours to react.
        const origin: chunks.Position = .{
            .x = std.math.mul(i32, section.x, 16) catch return,
            .y = std.math.mul(i32, section.y, 16) catch return,
            .z = std.math.mul(i32, section.z, 16) catch return,
        };
        // A leaf placed or grown finds its own distance a tick later, as vanilla's placement
        // does at once.
        for (edits, previous) |edit, old| {
            if (tables.kinds[edit.state] != .leaves or block(edit.state) == block(old)) continue;
            try self.schedule(section.world, .{ .x = origin.x + (edit.index & 15), .y = origin.y + (edit.index >> 8), .z = origin.z + ((edit.index >> 4) & 15) }, self.leaves_tick);
        }
        // The section and the six around it, read once. Most edits touch none that react, and
        // a large batch then costs seven palette checks rather than a read per cell.
        var sections: [7]chunks.Section = undefined;
        var slots: [7]?u8 = @splat(null);
        var count: u8 = 0;
        for ([_][3]i32{ .{ 0, 0, 0 }, .{ 0, -1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 }, .{ -1, 0, 0 }, .{ 1, 0, 0 } }, 0..) |step, at| {
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
            if (reactive(view)) break true;
        } else false;
        if (!any) return;
        for (edits, previous) |edit, old| {
            if (edit.state == old) continue;
            const local = [3]i32{ edit.index & 15, edit.index >> 8, (edit.index >> 4) & 15 };
            const hop = self.distanceAt(edit.state) + 1;
            for (directions) |direction| {
                const cell = [3]i32{ local[0] + direction[0], local[1] + direction[1], local[2] + direction[2] };
                // Which of the seven sections the neighbour lies in.
                const at: usize = if (cell[1] < 0) 1 else if (cell[1] > 15) 2 else if (cell[2] < 0) 3 else if (cell[2] > 15) 4 else if (cell[0] < 0) 5 else if (cell[0] > 15) 6 else 0;
                const slot = slots[at] orelse continue;
                const index: u12 = @intCast(@mod(cell[1], 16) * 256 + @mod(cell[2], 16) * 16 + @mod(cell[0], 16));
                const state = views[slot].get(index);
                const kind = tables.kinds[state];
                if (kind != .leaves and kind != .sugar_cane) continue;
                const neighbour: chunks.Position = .{
                    .x = std.math.add(i32, origin.x, cell[0]) catch continue,
                    .y = std.math.add(i32, origin.y, cell[1]) catch continue,
                    .z = std.math.add(i32, origin.z, cell[2]) catch continue,
                };
                switch (kind) {
                    .leaves => if (hop != 1 or tables.distance[state] != 1) try self.schedule(section.world, neighbour, self.leaves_tick),
                    // The tick checks whether the cane still stands, as vanilla's does.
                    .sugar_cane => try self.schedule(section.world, neighbour, self.sugar_cane_tick),
                    else => unreachable,
                }
            }
        }
    }

    fn schedule(self: *Growth, world: u32, position: chunks.Position, kind: ticks.Kind) !void {
        try self.deps.ticks.schedule(.{ .world = world, .position = .{ .x = position.x, .y = position.y, .z = position.z }, .kind = kind }, 1);
    }

    // Drops, as Block.dropResources with no tool.

    fn dropLoot(self: *Growth, world: u32, position: chunks.Position, state: u16) !void {
        const table = self.deps.loot.table(state) orelse return;
        self.loot_scratch.reset();
        var neighbors: [16]loot_tables.Neighbor = undefined;
        for (table.offsets, neighbors[0..table.offsets.len]) |at, *neighbor| {
            const cell = offset(position, at.x, at.y, at.z);
            neighbor.* = .{ .offset = at, .state = if (self.inside(world, cell)) try self.get(world, cell) else 0 };
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
