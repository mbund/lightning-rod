//! Buckets, as vanilla 1.21.8's BucketItem: an empty bucket takes up the fluid source a player
//! looks at, and a full one pours its fluid against the block they look at. Use goes through
//! the item use packet, as vanilla's buckets pass the use on a block and act on the item use.

const std = @import("std");
const chunks = @import("chunks");
const game_data = @import("game_data");
const inventories = @import("inventories");
const minecraft = @import("minecraft_model");
const Worlds = @import("worlds").Worlds;
const Players = @import("players").players.Players;
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const WorldBorder = @import("vanilla_world").world_border.WorldBorder;
const PlayerInventory = @import("vanilla_inventory").player_inventory.PlayerInventory;
const Dimensions = @import("vanilla_content").dimensions.Dimensions;
const Items = @import("vanilla_items").items.Items;
const ItemActions = @import("vanilla_items").item_actions.ItemActions;
const item_actions = @import("vanilla_items").item_actions;
const fluids = @import("fluids.zig");
const replaceable = @import("replaceable.zig");
const Effects = @import("vanilla_world").world_effects.Effects;
const raycast = @import("raycast.zig");

const assert = std.debug.assert;
const registry = game_data.registry;
const physics = game_data.physics;

const Direction = enum(u3) { down, up, north, south, west, east };

fn step(direction: Direction) [3]i32 {
    return switch (direction) {
        .down => .{ 0, -1, 0 },
        .up => .{ 0, 1, 0 },
        .north => .{ 0, 0, -1 },
        .south => .{ 0, 0, 1 },
        .west => .{ -1, 0, 0 },
        .east => .{ 1, 0, 0 },
    };
}

fn offset(position: chunks.Position, direction: Direction) chunks.Position {
    const by = step(direction);
    return .{ .x = position.x + by[0], .y = position.y + by[1], .z = position.z + by[2] };
}

pub const Hit = struct { position: chunks.Position, side: Direction };

pub const Buckets = struct {
    pub const id = "minecraft:buckets";
    pub const Configuration = struct { seed: u64 = 0x6275636b6574 };
    pub const Dependencies = struct {
        actions: *ItemActions,
        players: *Players,
        player_states: *PlayerStates,
        world_border: *WorldBorder,
        menus: *PlayerInventory,
        inventories: *inventories.Inventories,
        items: *Items,
        chunks: *chunks.Chunks,
        worlds: *Worlds,
        dimensions: *Dimensions,
        fluids: *fluids.Fluids,
    };

    const Bucket = enum { empty, water, lava };

    deps: Dependencies,
    chunk_client: chunks.Chunks.Client,
    effects: Effects,
    random: std.Random.DefaultPrng,
    bucket: u32,
    water_bucket: u32,
    lava_bucket: u32,
    powder_snow_bucket: u32,
    bubble_column: u16,
    powder_snow: u16,
    end_portal: u16,
    end_gateway: u16,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*Buckets {
        const self = try allocator.create(Buckets);
        self.* = .{
            .deps = deps,
            .chunk_client = try deps.chunks.simulation(1),
            .effects = try .init(allocator, deps.players),
            .random = .init(configuration.seed),
            .bucket = try item("minecraft:bucket"),
            .water_bucket = try item("minecraft:water_bucket"),
            .lava_bucket = try item("minecraft:lava_bucket"),
            .powder_snow_bucket = try item("minecraft:powder_snow_bucket"),
            .bubble_column = try blockOf("minecraft:bubble_column[drag=true]"),
            .powder_snow = try blockOf("minecraft:powder_snow"),
            .end_portal = try blockOf("minecraft:end_portal"),
            .end_gateway = try blockOf("minecraft:end_gateway"),
        };
        try deps.actions.on(item_actions.Binding.bind(Buckets, self, use));
        return self;
    }

    fn item(name: []const u8) !u32 {
        return @intCast(registry.itemId(name) orelse return error.UnknownItem);
    }

    fn blockOf(name: []const u8) !u16 {
        const state = registry.blockStateId(name) orelse return error.UnknownBlockState;
        return registry.block_state_to_block[@intCast(state)];
    }

    fn block(state: u16) u16 {
        return registry.block_state_to_block[state];
    }

    fn get(self: *Buckets, world: u32, position: chunks.Position) !u16 {
        const definition = self.deps.worlds.get(world) orelse return 0;
        const bottom = definition.dimension.minimumSection() * 16;
        if (position.y < bottom or position.y >= bottom + @as(i32, @intCast(definition.dimension.sectionCount() * 16))) return 0;
        return self.chunk_client.getBlock(world, position);
    }

    /// BucketItem.use. Buckets act on the item use only: on a block, the client sends that
    /// after the use on the block passes, which it does for buckets.
    fn use(self: *Buckets, context: *const item_actions.Context) !item_actions.Result {
        if (context.hit != null) return .pass;
        const bucket: Bucket = if (context.item.kind == self.bucket) .empty else if (context.item.kind == self.water_bucket) .water else if (context.item.kind == self.lava_bucket) .lava else return .pass;
        const player = context.player;
        const index = player.handle.?.index;
        const state = self.deps.player_states.of(player);
        const hit = try self.trace(player, state.gamemode == .creative, bucket == .empty) orelse return .pass;
        const beside = offset(hit.position, hit.side);
        // World.canEntityModifyAt and PlayerEntity.canPlaceOn: inside the border, and a player
        // who may change the world.
        if (!self.deps.world_border.containsBlock(player.world, hit.position.x, hit.position.z) or (state.gamemode != .survival and state.gamemode != .creative)) return .denied;
        const world = player.world;
        if (bucket == .empty) {
            const filled = try self.drain(world, hit.position) orelse return .denied;
            const sound = if (filled == self.lava_bucket) "minecraft:item.bucket.fill_lava" else if (filled == self.powder_snow_bucket) "minecraft:item.bucket.fill_powder_snow" else "minecraft:item.bucket.fill";
            // PlayerEntity.playSound sounds where the player is, for everyone but them.
            self.effects.sound(world, player.position, sound, .players, 1, 1, self.random.random().int(i64), index);
            try self.exchange(context, filled);
            return .applied;
        }
        const kind: fluids.Kind = if (bucket == .water) .water else .lava;
        const at = try self.get(world, hit.position);
        const target = if (fluids.fillableOf(at) != .no and kind == .water) hit.position else beside;
        if (!try self.place(player, kind, target, hit)) return .denied;
        // BucketItem.getEmptiedStack gives an empty bucket back, but in creative.
        if (state.gamemode != .creative) try self.exchange(context, self.bucket);
        return .applied;
    }

    /// FluidDrainable.tryDrainFluid of FluidBlock, Waterloggable, BubbleColumnBlock and
    /// PowderSnowBlock: what bucket the block fills, after taking it up.
    fn drain(self: *Buckets, world: u32, position: chunks.Position) !?u32 {
        const state = try self.get(world, position);
        const fluid = fluids.fluidOf(state);
        if (fluids.isLiquid(state)) {
            if (!fluid.still()) return null;
            try self.deps.chunks.setBlock(world, position, 0);
            return if (fluid.kind == .water) self.water_bucket else self.lava_bucket;
        }
        if (fluids.fillableOf(state) == .waterloggable) {
            if (!fluids.isWaterlogged(state)) return null;
            try self.deps.chunks.setBlock(world, position, fluids.dryOf(state));
            return self.water_bucket;
        }
        if (block(state) == self.bubble_column) {
            try self.deps.chunks.setBlock(world, position, 0);
            return self.water_bucket;
        }
        if (block(state) == self.powder_snow) {
            try self.deps.chunks.setBlock(world, position, 0);
            self.effects.worldEvent(world, position, 2001, @intCast(state));
            return self.powder_snow_bucket;
        }
        return null;
    }

    /// BucketItem.placeFluid: pours where the block gives way to fluid, or against it, or into
    /// a waterloggable block. Water boils away in an ultrawarm dimension.
    fn place(self: *Buckets, player: *const Players.Player, kind: fluids.Kind, position: chunks.Position, hit: ?Hit) !bool {
        const world = player.world;
        const index = player.handle.?.index;
        const state = try self.get(world, position);
        const fillable = fluids.fillableOf(state);
        const refuses = block(state) == self.end_portal or block(state) == self.end_gateway;
        // AbstractBlock.canBucketPlace.
        const gives_way = !refuses and (replaceable.isReplaceable(state) or !fluids.isSolid(state));
        const takes = fluids.isAir(state) or gives_way or (fillable == .waterloggable and kind == .water);
        if (!takes) {
            const against = hit orelse return false;
            return self.place(player, kind, offset(against.position, against.side), null);
        }
        const definition = self.deps.worlds.get(world) orelse return false;
        const ultrawarm = if (self.deps.dimensions.get(definition.dimension.name)) |dimension| dimension.ultrawarm else false;
        if (ultrawarm and kind == .water) {
            const random = self.random.random();
            const pitch = 2.6 + (random.float(f32) - random.float(f32)) * 0.8;
            self.effects.blockSound(world, position, "minecraft:block.fire.extinguish", .blocks, 0.5, pitch, random.int(i64), index);
            return true;
        }
        if (fillable != .no and kind == .water) {
            _ = try self.deps.fluids.fill(world, position, state, .{ .kind = .water, .amount = 8 });
            self.emptied(player, kind, position);
            return true;
        }
        if (gives_way and !fluids.isLiquid(state)) {
            // World.breakBlock with drops.
            try self.deps.fluids.dropLoot(world, position, state);
            self.effects.worldEvent(world, position, 2001, @intCast(state));
            try self.deps.chunks.setBlock(world, position, 0);
        }
        const source = fluids.sourceOf(kind);
        const before = try self.get(world, position);
        if (before == source and !fluids.fluidOf(state).still()) return false;
        if (before != source) try self.deps.chunks.setBlock(world, position, source);
        self.emptied(player, kind, position);
        return true;
    }

    fn emptied(self: *Buckets, player: *const Players.Player, kind: fluids.Kind, position: chunks.Position) void {
        const sound = if (kind == .lava) "minecraft:item.bucket.empty_lava" else "minecraft:item.bucket.empty";
        self.effects.blockSound(player.world, position, sound, .blocks, 1, 1, self.random.random().int(i64), player.handle.?.index);
    }

    /// ItemUsage.exchangeStack: one of the held stack becomes `output`. In creative the held
    /// stack stays, and `output` is added if the inventory holds none like it.
    fn exchange(self: *Buckets, context: *const item_actions.Context, output: u32) !void {
        const player = context.player;
        const index = player.handle.?.index;
        const state = self.deps.player_states.of(player);
        const name = registry.item_names[output];
        if (state.gamemode == .creative) {
            if (!try self.holds(player, output)) _ = try self.deps.menus.give(index, name, 1);
            return;
        }
        const slot: inventories.Slot = .{ .owner = player.uuid, .index = if (context.hand == .off) 45 else 36 + @as(u16, state.selected_slot) };
        const held = try self.deps.inventories.get(slot);
        const stack = held.stack orelse return;
        if (stack.count == 1) {
            const committed = try self.deps.inventories.set(slot, held.revision, .{ .item = try self.deps.items.define(name), .count = 1 });
            assert(committed);
            self.deps.menus.changed(index);
            return;
        }
        const committed = try self.deps.inventories.set(slot, held.revision, .{ .item = stack.item, .count = stack.count - 1 });
        assert(committed);
        self.deps.menus.changed(index);
        if (try self.deps.menus.give(index, name, 1)) return;
        _ = try self.deps.menus.dropMany(player.*, &.{.{ .item = try self.deps.items.define(name), .count = 1 }});
    }

    /// PlayerInventory.contains for a plain item.
    fn holds(self: *Buckets, player: *const Players.Player, kind: u32) !bool {
        const wanted = try self.deps.items.define(registry.item_names[kind]);
        var slots: [46]inventories.Slot = undefined;
        for (&slots, 0..) |*slot, at| slot.* = .{ .owner = player.uuid, .index = @intCast(at) };
        var contents: [46]inventories.Contents = undefined;
        try self.deps.inventories.getMany(&slots, &contents);
        for (contents[9..]) |value| {
            const stack = value.stack orelse continue;
            if (std.mem.eql(u8, &stack.item, &wanted)) return true;
        }
        return false;
    }

    /// Item.raycast: from the eyes along the look, as far as the player reaches blocks, through
    /// outline shapes, and with an empty bucket stopping at fluid sources too.
    fn trace(self: *Buckets, player: *const Players.Player, creative: bool, sources: bool) !?Hit {
        const eye: f64 = if (player.flags.sneaking) 1.27 else 1.62;
        const origin: minecraft.Position = .{ .x = player.position.x, .y = player.position.y + eye, .z = player.position.z };
        const look = raycast.direction(player.rotation);
        // PlayerEntity.getBlockInteractionRange, with creative's modifier.
        const reach: f64 = if (creative) 5 else 4.5;
        var ray = try raycast.Ray.init(origin, look, reach);
        const start: [3]f64 = .{ origin.x, origin.y, origin.z };
        const end: [3]f64 = .{ origin.x + look[0] * reach, origin.y + look[1] * reach, origin.z + look[2] * reach };
        while (ray.next()) |cell| {
            const state = try self.get(player.world, cell);
            var best: ?struct { distance: f64, side: Direction } = null;
            const boxes = physics.outline(state, cell.x, cell.z);
            for (0..boxes.count) |at| {
                const box = boxes.get(at);
                if (intersect(start, end, cell, box)) |entry| {
                    if (best == null or entry.distance < best.?.distance) best = .{ .distance = entry.distance, .side = entry.side };
                }
            }
            if (sources) {
                const fluid = fluids.fluidOf(state);
                if (fluid.still()) {
                    // FluidState.getShape: as tall as the fluid stands, the whole cell under the same fluid.
                    const above = fluids.fluidOf(try self.get(player.world, offset(cell, .up)));
                    const height: f64 = if (above.kind == fluid.kind) 1 else @as(f64, @floatFromInt(fluid.amount)) / 9;
                    if (intersect(start, end, cell, .{ 0, 0, 0, 1, height, 1 })) |entry| {
                        if (best == null or entry.distance < best.?.distance) best = .{ .distance = entry.distance, .side = entry.side };
                    }
                }
            }
            if (best) |found| return .{ .position = cell, .side = found.side };
        }
        return null;
    }

    /// Where the segment first enters the box at `cell`, and through which face. A segment that
    /// starts inside hits at once, through the face it leaves by reversed, as VoxelShape.raycast.
    fn intersect(start: [3]f64, end: [3]f64, cell: chunks.Position, box: [6]f64) ?struct { distance: f64, side: Direction } {
        const base = [3]f64{ @floatFromInt(cell.x), @floatFromInt(cell.y), @floatFromInt(cell.z) };
        var low: f64 = 0;
        var high: f64 = 1;
        var entered: ?usize = null;
        for (0..3) |axis| {
            const delta = end[axis] - start[axis];
            const minimum = base[axis] + box[axis];
            const maximum = base[axis] + box[axis + 3];
            if (@abs(delta) < 1e-12) {
                if (start[axis] < minimum or start[axis] > maximum) return null;
                continue;
            }
            var near = (minimum - start[axis]) / delta;
            var far = (maximum - start[axis]) / delta;
            if (near > far) std.mem.swap(f64, &near, &far);
            if (near > low) {
                low = near;
                entered = axis;
            }
            high = @min(high, far);
            if (low > high) return null;
        }
        const axis = entered orelse {
            // Inside from the start: the face toward where the ray points, reversed.
            const delta = [3]f64{ end[0] - start[0], end[1] - start[1], end[2] - start[2] };
            var largest: usize = 0;
            for (1..3) |candidate| if (@abs(delta[candidate]) > @abs(delta[largest])) {
                largest = candidate;
            };
            return .{ .distance = 0, .side = faceOf(largest, delta[largest] < 0) };
        };
        const delta = end[axis] - start[axis];
        return .{ .distance = low, .side = faceOf(axis, delta > 0) };
    }

    /// The face a ray moving along `axis`, towards positive coordinates when `towards_positive`,
    /// enters through: the one facing back at it.
    fn faceOf(axis: usize, towards_positive: bool) Direction {
        return switch (axis) {
            0 => if (towards_positive) .west else .east,
            1 => if (towards_positive) .down else .up,
            else => if (towards_positive) .north else .south,
        };
    }
};
