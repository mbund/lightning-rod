const Blocks = @import("vanilla_content").blocks.Blocks;
const Border = @import("vanilla_content").border.Border;
const game_data = @import("game_data");
const std = @import("std");
const chunks = @import("chunks");
const entities = @import("entities");

const assert = std.debug.assert;

pub const ItemPhysics = struct {
    pub const id = "minecraft:item_physics";

    pub const Configuration = struct {};

    pub const Dependencies = struct { blocks: *Blocks, chunks: *chunks.Chunks };

    pub const Window = chunks.ReadWindow(8);

    pub const Result = struct {
        body: entities.State,
        on_ground: bool,
        crossed_block: bool,
        /// Whether it moved this tick, which takes what held it back.
        moved: bool = false,
        effects: OrbEffects = .{},
    };

    deps: Dependencies,
    /// Reads block sections from the simulation budget, two windows of eight at once.
    chunk_client: chunks.Chunks.Client,
    /// The world border, which bodies moving near it collide with; set by whoever keeps it.
    border: ?*const Border = null,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*ItemPhysics {
        const self = try allocator.create(ItemPhysics);
        self.* = .{ .deps = deps, .chunk_client = try deps.chunks.simulation(16) };
        return self;
    }

    pub fn readWindow(self: *const ItemPhysics) Window {
        return Window.init(self.chunk_client);
    }

    /// The start of an item's Entity.baseTick: pushed by the currents it is in. How deep it is
    /// in each fluid decides what it does next.
    pub fn push(self: *ItemPhysics, neighborhood: *Window, body: *entities.State, ultrawarm: bool) !Fluids {
        try readAround(neighborhood, body.*);
        return self.pushFluids(neighborhood, body, 0.25, 0.25, ultrawarm);
    }

    /// The rest of ItemEntity.tick's movement, after `push`: afloat in water or lava over a
    /// tenth deep and falling otherwise, then moved, held back by what `stuck` holds it in, and
    /// slowed. Moving, it goes through `effects.apply(body, on_ground, from)`, which does what
    /// the blocks it crossed do to it, as Entity.applyEffectsFromBlocks, unless `effects` is
    /// void. A stuck item stays stuck until it moves.
    pub fn advance(self: *ItemPhysics, neighborhood: *Window, entity_id: u32, ticks: u32, pushed: entities.State, on_ground: bool, fluids: Fluids, stuck: [3]f64, effects: anytype) !Result {
        return self.advanceRandomly(neighborhood, entity_id, ticks, pushed, on_ground, fluids, stuck, effects, null);
    }

    /// As `advance`, with the random an item inside a block is pushed out by: ItemEntity.tick's
    /// noClip, then Entity.pushOutOfBlocks. Without one, an item inside a block stays as it is.
    pub fn advanceRandomly(self: *ItemPhysics, neighborhood: *Window, entity_id: u32, ticks: u32, pushed: entities.State, on_ground: bool, fluids: Fluids, stuck: [3]f64, effects: anytype, random: ?std.Random) !Result {
        assert(entity_id > 0);
        var body = pushed;
        // ItemEntity.setUnderwaterMovement and setUnderLavaMovement in place of gravity.
        if (fluids.water > @as(f32, 0.1)) {
            buoy(&body.velocity, @as(f32, 0.99));
        } else if (fluids.lava > @as(f32, 0.1)) {
            buoy(&body.velocity, @as(f32, 0.95));
        } else body.velocity[1] -= 0.04;
        // Inside a block, it moves through blocks, pushed towards the nearest way out.
        var inside = false;
        if (random) |source| if (try self.collides(neighborhood, body, 0.125, 0.25)) {
            inside = true;
            try self.escape(neighborhood, &body, source, 0.125);
        };
        if (inside) return self.advanceThrough(neighborhood, entity_id, ticks, body, on_ground, effects);
        return self.advanceBody(false, neighborhood, entity_id, ticks, body, on_ground, stuck, effects);
    }

    /// ItemEntity.tick's move with noClip set: Entity.move only adds the motion, touching neither
    /// what holds the item back nor whether it is on the ground; the slowing after is as ever.
    fn advanceThrough(self: *ItemPhysics, neighborhood: *Window, entity_id: u32, ticks: u32, body: entities.State, on_ground: bool, effects: anytype) !Result {
        var next = body;
        const moved = !on_ground or next.velocity[0] * next.velocity[0] + next.velocity[2] * next.velocity[2] > @as(f64, @as(f32, 0.00001)) or movesOnPhase(ticks, entity_id);
        if (moved) {
            for (&next.position, next.velocity) |*position, velocity| position.* += velocity;
            if (@TypeOf(effects) != void) try effects.apply(&next, on_ground, body.position);
            var friction: f32 = 0.98;
            if (on_ground) {
                const below: chunks.Position = .{ .x = @intFromFloat(@floor(next.position[0])), .y = @intFromFloat(@floor(next.position[1] - @as(f64, @as(f32, 0.999999)))), .z = @intFromFloat(@floor(next.position[2])) };
                friction *= self.deps.blocks.get(try self.blockState(neighborhood, body.world, below)).friction;
            }
            next.velocity[0] *= friction;
            next.velocity[1] *= 0.98;
            next.velocity[2] *= friction;
            if (on_ground and next.velocity[1] < 0) next.velocity[1] *= -0.5;
        }
        var crossed = false;
        for (body.position, next.position) |before, after| crossed = crossed or @floor(before) != @floor(after);
        return .{ .body = next, .on_ground = on_ground, .crossed_block = crossed, .moved = moved };
    }

    /// An item's movement alone, `push` then `advance`, with nothing holding it back and no
    /// block effects.
    pub fn step(self: *ItemPhysics, neighborhood: *Window, entity_id: u32, ticks: u32, body: entities.State, on_ground: bool, ultrawarm: bool) !Result {
        var pushed = body;
        const fluids = try self.push(neighborhood, &pushed, ultrawarm);
        return self.advance(neighborhood, entity_id, ticks, pushed, on_ground, fluids, .{ 0, 0, 0 }, {});
    }

    pub fn advanceOrb(self: *ItemPhysics, neighborhood: *Window, entity_id: u32, ticks: u32, body: entities.State, on_ground: bool, stuck: [3]f64) !Result {
        return self.advanceBody(true, neighborhood, entity_id, ticks, body, on_ground, stuck, {});
    }

    pub const OrbEnvironment = struct { solid: bool, water: bool, lava: bool };
    pub const OrbEffects = struct { extinguish: bool = false, lava: u8 = 0, fire: u8 = 0, cactus: u8 = 0, stuck: [3]f64 = .{ 0, 0, 0 }, honey: bool = false, bubble: ?struct { drag: bool, surface: bool } = null };

    pub fn orbEffects(self: *ItemPhysics, window: *Window, body: entities.State) !OrbEffects {
        var result: OrbEffects = .{};
        const low: [3]f64 = .{ body.position[0] - 0.25 + 1e-5, body.position[1] + 1e-5, body.position[2] - 0.25 + 1e-5 };
        const high: [3]f64 = .{ body.position[0] + 0.25 - 1e-5, body.position[1] + 0.5 - 1e-5, body.position[2] + 0.25 - 1e-5 };
        var y: i32 = @intFromFloat(@floor(low[1]));
        while (@as(f64, @floatFromInt(y)) < high[1]) : (y += 1) {
            var z: i32 = @intFromFloat(@floor(low[2]));
            while (@as(f64, @floatFromInt(z)) < high[2]) : (z += 1) {
                var x: i32 = @intFromFloat(@floor(low[0]));
                while (@as(f64, @floatFromInt(x)) < high[0]) : (x += 1) {
                    const state = try self.blockState(window, body.world, .{ .x = x, .y = y, .z = z });
                    const name = game_data.registry.blockStateName(state).?;
                    const properties = self.deps.blocks.get(state);
                    if (properties.fluid != .none) {
                        const above = self.deps.blocks.get(try self.blockState(window, body.world, .{ .x = x, .y = y + 1, .z = z }));
                        const height = if (above.fluid == properties.fluid) @as(f64, 1) else properties.height();
                        if (low[1] < @as(f64, @floatFromInt(y)) + height) {
                            result.extinguish = result.extinguish or properties.fluid == .water;
                            if (properties.fluid == .lava) result.lava += 1;
                        }
                    }
                    if (std.mem.startsWith(u8, name, "minecraft:fire[")) result.fire += 1;
                    if (std.mem.eql(u8, name, "minecraft:soul_fire")) result.fire += 2;
                    if (std.mem.startsWith(u8, name, "minecraft:cactus[")) result.cactus += 1;
                    if (std.mem.eql(u8, name, "minecraft:cobweb")) result.stuck = .{ 0.25, 0.05, 0.25 };
                    if (std.mem.eql(u8, name, "minecraft:powder_snow")) {
                        result.stuck = .{ 0.9, 1.5, 0.9 };
                        result.extinguish = true;
                    }
                    if (std.mem.eql(u8, name, "minecraft:honey_block") and body.position[1] <= @as(f64, @floatFromInt(y)) + 0.9375 - 1e-7 and
                        (@abs(@as(f64, @floatFromInt(x)) + 0.5 - body.position[0]) + 1e-7 > 0.6875 or @abs(@as(f64, @floatFromInt(z)) + 0.5 - body.position[2]) + 1e-7 > 0.6875)) result.honey = true;
                    if (std.mem.startsWith(u8, name, "minecraft:bubble_column[")) {
                        const above = try self.blockState(window, body.world, .{ .x = x, .y = y + 1, .z = z });
                        const above_name = game_data.registry.blockStateName(above).?;
                        result.bubble = .{ .drag = std.mem.indexOf(u8, name, "drag=true") != null, .surface = std.mem.eql(u8, above_name, "minecraft:air") or std.mem.eql(u8, above_name, "minecraft:cave_air") or std.mem.eql(u8, above_name, "minecraft:void_air") };
                    }
                }
            }
        }
        return result;
    }

    pub fn orbEnvironment(self: *ItemPhysics, window: *Window, body: entities.State) !OrbEnvironment {
        const eye = body.position[1] + @as(f64, @as(f32, 0.425));
        const position: chunks.Position = .{ .x = @intFromFloat(@floor(body.position[0])), .y = @intFromFloat(@floor(eye)), .z = @intFromFloat(@floor(body.position[2])) };
        const water = self.deps.blocks.get(try self.blockState(window, body.world, position));
        const above = self.deps.blocks.get(try self.blockState(window, body.world, .{ .x = position.x, .y = position.y + 1, .z = position.z }));
        const base = self.deps.blocks.get(try self.blockState(window, body.world, .{ .x = position.x, .y = @intFromFloat(@floor(body.position[1])), .z = position.z }));
        return .{ .solid = try self.orbCollides(window, body), .water = water.fluid == .water and eye < @as(f64, @as(f32, @floatFromInt(position.y)) + (if (above.fluid == .water) @as(f32, 1) else water.height())), .lava = base.fluid == .lava };
    }

    /// What a resting item's move ticks take from its block, if nothing else around it does
    /// anything: every cell its box is in holds air, and the block it rests on is one that does
    /// nothing to an item but hold, steady and slow it.
    pub const Rest = struct { speed: f64, friction: f64 };

    const restless_supports = [_][]const u8{
        "minecraft:redstone_ore",            "minecraft:deepslate_redstone_ore", "minecraft:sculk_sensor",
        "minecraft:calibrated_sculk_sensor", "minecraft:sculk_shrieker",         "minecraft:turtle_egg",
        "minecraft:slime_block",             "minecraft:honey_block",            "minecraft:magma_block",
        "minecraft:hopper",                  "minecraft:campfire",               "minecraft:soul_campfire",
        "minecraft:big_dripleaf",            "minecraft:cactus",                 "minecraft:pointed_dripstone",
        "minecraft:scaffolding",             "minecraft:powder_snow",            "minecraft:bubble_column",
    };

    pub fn rest(self: *ItemPhysics, window: *Window, body: entities.State) !?Rest {
        const p = body.position;
        // The cells the box is in: 0.25 wide and high, standing on the block below.
        var x = floorCell(p[0] - 0.125);
        while (x <= floorCell(p[0] + 0.125)) : (x += 1) {
            var z = floorCell(p[2] - 0.125);
            while (z <= floorCell(p[2] + 0.125)) : (z += 1) {
                var y = floorCell(p[1]);
                while (y <= floorCell(p[1] + 0.25)) : (y += 1) {
                    const state = try self.blockState(window, body.world, .{ .x = x, .y = y, .z = z });
                    if (!isAir(state)) return null;
                }
            }
        }
        // The block it rests on, as advanceBody finds it after a move; none, and it keeps awake.
        const supporting = (try self.nearestSupport(window, body.world, p, 0.125, .{ 0, 0 })) orelse return null;
        const below_position: chunks.Position = .{ .x = supporting.x, .y = floorCell(p[1] - @as(f64, @as(f32, 0.500001))), .z = supporting.z };
        const below = try self.blockState(window, body.world, below_position);
        const name = game_data.registry.block_state_names[below];
        const block = name[0 .. std.mem.indexOfScalar(u8, name, '[') orelse name.len];
        for (restless_supports) |restless| if (std.mem.eql(u8, block, restless)) return null;
        // As advanceBody works them out on a move tick.
        const base = self.deps.blocks.get(try self.blockState(window, body.world, .{ .x = floorCell(p[0]), .y = floorCell(p[1]), .z = floorCell(p[2]) }));
        var speed = base.speed;
        if (speed == 1 and !base.water_block) speed = self.deps.blocks.get(below).speed;
        var friction: f32 = 0.98;
        friction *= self.deps.blocks.get(below).friction;
        return .{ .speed = speed, .friction = friction };
    }

    fn floorCell(value: f64) i32 {
        return @intFromFloat(@floor(value));
    }

    fn isAir(state: u16) bool {
        return state == game_data.registry.block_air_default_state or game_data.registry.block_state_names[state].len >= 14 and
            (std.mem.eql(u8, game_data.registry.block_state_names[state], "minecraft:cave_air") or std.mem.eql(u8, game_data.registry.block_state_names[state], "minecraft:void_air"));
    }

    fn blockState(self: *ItemPhysics, window: *Window, world: u32, position: chunks.Position) !u16 {
        assert(window.client.chunks == self.deps.chunks and window.client.index == self.chunk_client.index);
        var views: [1]chunks.View = undefined;
        try window.readMany(&.{chunks.sectionAt(world, position)}, &views);
        const state = views[0].get(chunks.localIndex(position));
        if (state >= game_data.registry.block_state_names.len) return error.Corrupt;
        return state;
    }

    pub fn pushOrb(self: *ItemPhysics, window: *Window, body: *entities.State, ultrawarm: bool) !void {
        _ = try self.pushFluids(window, body, 0.5, 0.5, ultrawarm);
    }

    /// Reads in one batch every section an item's tick can touch: the blocks its currents are
    /// read from, which are within a block of it, and those it can move through, as far as its
    /// velocity reaches once currents and gravity changed it, at most 0.06 a tick.
    fn readAround(window: *Window, body: entities.State) !void {
        // The item's box, a quarter block wide and tall, from its feet.
        const low: [3]f64 = .{ body.position[0] - 0.125, body.position[1], body.position[2] - 0.125 };
        const high: [3]f64 = .{ body.position[0] + 0.125, body.position[1] + 0.25, body.position[2] + 0.125 };
        var first: [3]i32 = undefined;
        var last: [3]i32 = undefined;
        for (0..3) |axis| {
            const velocity = body.velocity[axis];
            first[axis] = @divFloor(@as(i32, @intFromFloat(@floor(low[axis] + @min(velocity, 0) - 0.06))) - 1, 16);
            last[axis] = @divFloor(@as(i32, @intFromFloat(@floor(high[axis] + @max(velocity, 0) + 0.06))) + 1, 16);
        }
        var sections: [8]chunks.Section = undefined;
        var count: usize = 0;
        var y = first[1];
        while (y <= last[1]) : (y += 1) {
            var z = first[2];
            while (z <= last[2]) : (z += 1) {
                var x = first[0];
                while (x <= last[0]) : (x += 1) {
                    // A body too fast for the window reads in the batches its move takes.
                    if (count == sections.len) return;
                    sections[count] = .{ .world = body.world, .x = x, .y = y, .z = z };
                    count += 1;
                }
            }
        }
        var views: [8]chunks.View = undefined;
        try window.readMany(sections[0..count], views[0..count]);
    }

    /// How deep a body is in water and in lava: from its bottom to the top of the fluid.
    pub const Fluids = struct { water: f64 = 0, lava: f64 = 0 };

    /// Entity.updateInWaterStateAndDoFluidPushing for a body `width` wide and `height` tall:
    /// pushed by the water around it, then by the lava, as Entity.updateFluidHeightAndDoFluidPushing
    /// does with each.
    fn pushFluids(self: *ItemPhysics, window: *Window, body: *entities.State, comptime width: f32, comptime tall: f32, ultrawarm: bool) !Fluids {
        var fluids: Fluids = .{};
        inline for (.{ game_data.physics_data.Fluid.water, game_data.physics_data.Fluid.lava }) |kind| {
            // EntityDimensions.makeBoundingBox, then AABB.deflate(0.001).
            const half: f64 = width / 2;
            const low: [3]f64 = .{ body.position[0] - half + 0.001, body.position[1] + 0.001, body.position[2] - half + 0.001 };
            const high: [3]f64 = .{ body.position[0] + half - 0.001, body.position[1] + @as(f64, tall) - 0.001, body.position[2] + half - 0.001 };
            var total: [3]f64 = .{ 0, 0, 0 };
            var count: usize = 0;
            var depth: f64 = 0;
            var x: i32 = @intFromFloat(@floor(low[0]));
            while (@as(f64, @floatFromInt(x)) < high[0]) : (x += 1) {
                var y: i32 = @intFromFloat(@floor(low[1]));
                while (@as(f64, @floatFromInt(y)) < high[1]) : (y += 1) {
                    var z: i32 = @intFromFloat(@floor(low[2]));
                    while (@as(f64, @floatFromInt(z)) < high[2]) : (z += 1) {
                        const position: chunks.Position = .{ .x = x, .y = y, .z = z };
                        const state = self.deps.blocks.get(try self.blockState(window, body.world, position));
                        if (state.fluid != kind) continue;
                        const above = self.deps.blocks.get(try self.blockState(window, body.world, .{ .x = x, .y = y + 1, .z = z }));
                        // Added as floats, as vanilla does.
                        const height = @as(f64, @as(f32, @floatFromInt(y)) + (if (above.fluid == kind) @as(f32, 1) else state.height()));
                        if (height < low[1]) continue;
                        depth = @max(depth, height - low[1]);
                        const current = try self.flow(window, body.world, position, state);
                        for (&total, current) |*component, velocity| component.* += velocity * (if (depth < 0.4) depth else 1);
                        count += 1;
                    }
                }
            }
            if (kind == .water) fluids.water = depth else fluids.lava = depth;
            if (length(total) > 0) {
                if (count > 0) total = scaled(total, 1.0 / @as(f64, @floatFromInt(count)));
                const strength: f64 = if (kind == .water) 0.014 else if (ultrawarm) 0.007 else 0.0023333333333333335;
                var current = scaled(normalized(total), strength);
                if (@abs(body.velocity[0]) < 0.003 and @abs(body.velocity[2]) < 0.003 and length(current) < 0.0045000000000000005) current = scaled(normalized(current), 0.0045000000000000005);
                for (&body.velocity, current) |*velocity, component| velocity.* += component;
            }
        }
        return fluids;
    }

    fn flow(self: *ItemPhysics, window: *Window, world: u32, position: chunks.Position, state: game_data.physics_data.State) ![3]f64 {
        const directions = [_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
        var velocity: [3]f64 = .{ 0, 0, 0 };
        var falling_wall = false;
        for (directions, 0..) |direction, face| {
            const neighbor: chunks.Position = .{ .x = position.x + direction[0], .y = position.y, .z = position.z + direction[1] };
            const other = self.deps.blocks.get(try self.blockState(window, world, neighbor));
            if (other.fluid == state.fluid or other.fluid == .none) {
                var difference: f32 = 0;
                if (other.height() == 0) {
                    if (!other.blocks_motion) {
                        const below = self.deps.blocks.get(try self.blockState(window, world, .{ .x = neighbor.x, .y = neighbor.y - 1, .z = neighbor.z }));
                        if (below.fluid == state.fluid and below.height() > 0) difference = state.height() - (below.height() - @as(f32, 0.8888889));
                    }
                } else difference = state.height() - other.height();
                velocity[0] += @as(f32, @floatFromInt(direction[0])) * difference;
                velocity[2] += @as(f32, @floatFromInt(direction[1])) * difference;
            }
            if (state.falling) {
                const above = self.deps.blocks.get(try self.blockState(window, world, .{ .x = neighbor.x, .y = neighbor.y + 1, .z = neighbor.z }));
                const mask = @as(u8, 1) << @intCast(face);
                falling_wall = falling_wall or (other.fluid != state.fluid and !other.ice and other.sturdy & mask != 0) or (above.fluid != state.fluid and !above.ice and above.sturdy & mask != 0);
            }
        }
        if (falling_wall) {
            velocity = normalized(velocity);
            velocity[1] -= 6;
        }
        return normalized(velocity);
    }

    /// Entity.updateSupportingBlockPos for a body on the ground: of the blocks under a sliver
    /// below its box, World.findSupportingBlockPos's nearest by block centre, ties to the
    /// greatest by y, z then x; none there, the same back along the move. Getting the block a
    /// wall or fence gate keeps for itself is left out: those stand 1.5 high, so the height
    /// half a block under the feet is their own block anyway.
    fn supportingBlock(self: *ItemPhysics, window: *Window, world: u32, position: [3]f64, half_width: f64, moved: [3]f64) !?chunks.Position {
        if (try self.nearestSupport(window, world, position, half_width, .{ 0, 0 })) |found| return found;
        return self.nearestSupport(window, world, position, half_width, .{ -moved[0], -moved[2] });
    }

    fn nearestSupport(self: *ItemPhysics, window: *Window, world: u32, position: [3]f64, half_width: f64, shift: [2]f64) !?chunks.Position {
        const low: [3]f64 = .{ position[0] - half_width + shift[0], position[1] - 1.0e-6, position[2] - half_width + shift[1] };
        const high: [3]f64 = .{ position[0] + half_width + shift[0], position[1], position[2] + half_width + shift[1] };
        var best: ?chunks.Position = null;
        var best_distance = std.math.floatMax(f64);
        var y: i32 = @intFromFloat(@floor(low[1]));
        while (y <= @as(i32, @intFromFloat(@floor(high[1])))) : (y += 1) {
            var z: i32 = @intFromFloat(@floor(low[2]));
            while (z <= @as(i32, @intFromFloat(@floor(high[2])))) : (z += 1) {
                var x: i32 = @intFromFloat(@floor(low[0]));
                while (x <= @as(i32, @intFromFloat(@floor(high[0])))) : (x += 1) {
                    const at: chunks.Position = .{ .x = x, .y = y, .z = z };
                    const state = try self.blockState(window, world, at);
                    if (state >= game_data.registry.block_state_collision_shape.len) return error.Corrupt;
                    const shape = game_data.registry.collision_shapes[game_data.registry.block_state_collision_shape[state]];
                    const offset: [3]f64 = .{ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) };
                    const touches = for (game_data.registry.collision_boxes[shape.offset..][0..shape.count]) |box| {
                        const minimum: [3]f64 = .{ offset[0] + @as(f64, @floatFromInt(box.min_x)) / 64, offset[1] + @as(f64, @floatFromInt(box.min_y)) / 64, offset[2] + @as(f64, @floatFromInt(box.min_z)) / 64 };
                        const maximum: [3]f64 = .{ offset[0] + @as(f64, @floatFromInt(box.max_x)) / 64, offset[1] + @as(f64, @floatFromInt(box.max_y)) / 64, offset[2] + @as(f64, @floatFromInt(box.max_z)) / 64 };
                        if (for (0..3) |axis| {
                            if (!(low[axis] < maximum[axis] and high[axis] > minimum[axis])) break false;
                        } else true) break true;
                    } else false;
                    if (!touches) continue;
                    // Vec3i.getSquaredDistance from the block's centre.
                    var distance: f64 = 0;
                    for (offset, position) |corner, value| distance += (corner + 0.5 - value) * (corner + 0.5 - value);
                    const later = if (best) |previous| previous.y < y or (previous.y == y and (previous.z < z or (previous.z == z and previous.x < x))) else true;
                    if (distance < best_distance or (distance == best_distance and later)) {
                        best = at;
                        best_distance = distance;
                    }
                }
            }
        }
        return best;
    }

    pub fn orbCollides(self: *ItemPhysics, window: *Window, body: entities.State) !bool {
        return self.collides(window, body, 0.25, 0.5);
    }

    /// Whether a body's box, `half_width` to each side and `height` up from its feet, overlaps
    /// any block's collision shape: World.isSpaceEmpty of the box drawn in by 1e-7.
    pub fn collides(self: *ItemPhysics, window: *Window, body: entities.State, comptime half_width: f64, comptime height: f64) !bool {
        assert(window.client.chunks == self.deps.chunks and window.client.index == self.chunk_client.index);
        const low: [3]f64 = .{ body.position[0] - half_width, body.position[1], body.position[2] - half_width };
        const high: [3]f64 = .{ body.position[0] + half_width, body.position[1] + height, body.position[2] + half_width };
        var y: i32 = @intFromFloat(@floor(low[1] + 1e-7));
        while (@as(f64, @floatFromInt(y)) < high[1] - 1e-7) : (y += 1) {
            var z: i32 = @intFromFloat(@floor(low[2] + 1e-7));
            while (@as(f64, @floatFromInt(z)) < high[2] - 1e-7) : (z += 1) {
                var x: i32 = @intFromFloat(@floor(low[0] + 1e-7));
                while (@as(f64, @floatFromInt(x)) < high[0] - 1e-7) : (x += 1) {
                    const position: chunks.Position = .{ .x = x, .y = y, .z = z };
                    var views: [1]chunks.View = undefined;
                    try window.readMany(&.{chunks.sectionAt(body.world, position)}, &views);
                    const state = views[0].get(chunks.localIndex(position));
                    if (state >= game_data.registry.block_state_collision_shape.len) return error.Corrupt;
                    const shape = game_data.registry.collision_shapes[game_data.registry.block_state_collision_shape[state]];
                    for (game_data.registry.collision_boxes[shape.offset..][0..shape.count]) |box| {
                        const offset: [3]f64 = .{ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) };
                        const minimum: [3]i16 = .{ box.min_x, box.min_y, box.min_z };
                        const maximum: [3]i16 = .{ box.max_x, box.max_y, box.max_z };
                        const overlaps = for (0..3) |axis| {
                            if (high[axis] <= offset[axis] + @as(f64, @floatFromInt(minimum[axis])) / 64 + 1e-7 or low[axis] >= offset[axis] + @as(f64, @floatFromInt(maximum[axis])) / 64 - 1e-7) break false;
                        } else true;
                        if (overlaps) return true;
                    }
                }
            }
        }
        return false;
    }

    pub fn escapeOrb(self: *ItemPhysics, window: *Window, body: *entities.State, random: std.Random) !void {
        return self.escape(window, body, random, 0.25);
    }

    /// Entity.pushOutOfBlocks from the middle of the body's box, `half_height` above its feet:
    /// towards the nearest side, of four and the top, that is not a full block.
    pub fn escape(self: *ItemPhysics, window: *Window, body: *entities.State, random: std.Random, comptime half_height: f64) !void {
        assert(window.client.chunks == self.deps.chunks and window.client.index == self.chunk_client.index);
        const center: [3]f64 = .{ body.position[0], body.position[1] + half_height, body.position[2] };
        const directions = [_][3]i32{ .{ 0, 0, -1 }, .{ 0, 0, 1 }, .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } };
        var selected: usize = 4;
        var closest = std.math.inf(f64);
        for (directions, 0..) |direction, index| {
            const position: chunks.Position = .{ .x = @as(i32, @intFromFloat(@floor(center[0]))) + direction[0], .y = @as(i32, @intFromFloat(@floor(center[1]))) + direction[1], .z = @as(i32, @intFromFloat(@floor(center[2]))) + direction[2] };
            var views: [1]chunks.View = undefined;
            try window.readMany(&.{chunks.sectionAt(body.world, position)}, &views);
            const state = views[0].get(chunks.localIndex(position));
            if (state >= game_data.registry.block_state_collision_shape.len) return error.Corrupt;
            const shape = game_data.registry.collision_shapes[game_data.registry.block_state_collision_shape[state]];
            if (shape.count == 1) {
                const box = game_data.registry.collision_boxes[shape.offset];
                if (box.min_x == 0 and box.min_y == 0 and box.min_z == 0 and box.max_x == 64 and box.max_y == 64 and box.max_z == 64) continue;
            }
            for (direction, 0..) |component, axis| {
                if (component == 0) continue;
                const fraction = center[axis] - @floor(center[axis]);
                const distance = if (component > 0) 1 - fraction else fraction;
                if (distance < closest) {
                    closest = distance;
                    selected = index;
                }
            }
        }
        const impulse = random.float(f32) * @as(f32, 0.2) + 0.1;
        for (directions[selected], &body.velocity) |component, *velocity| velocity.* = if (component == 0) velocity.* * 0.75 else @as(f32, @floatFromInt(component)) * impulse;
    }

    pub fn placeOrb(self: *ItemPhysics, window: *Window, body: *entities.State) !void {
        if (!try self.orbCollides(window, body.*)) return;
        const center: [3]f64 = .{ body.position[0], body.position[1] + 0.25, body.position[2] };
        var minimum: [3]f64 = undefined;
        var maximum: [3]f64 = undefined;
        var origin: [3]i64 = undefined;
        var size: [3]usize = undefined;
        for (center, 0..) |coordinate, axis| {
            minimum[axis] = coordinate - 0.25;
            maximum[axis] = coordinate + 0.25;
            origin[axis] = @intFromFloat(@floor(minimum[axis] * 64));
            size[axis] = @intCast(@as(i64, @intFromFloat(@ceil(maximum[axis] * 64))) - origin[axis]);
            assert(size[axis] <= 33);
        }
        // Collision boxes and the expanded orb bounds share the registry's 1/64 grid.
        // Each free cell is convex. Its closest point is sufficient for the global minimum.
        var occupied: std.StaticBitSet(33 * 33 * 33) = .empty;
        var y: i32 = @intFromFloat(@floor(minimum[1] - 0.25) - 1);
        while (@as(f64, @floatFromInt(y)) <= @floor(maximum[1] + 0.25) + 1) : (y += 1) {
            var z: i32 = @intFromFloat(@floor(minimum[2] - 0.25) - 1);
            while (@as(f64, @floatFromInt(z)) <= @floor(maximum[2] + 0.25) + 1) : (z += 1) {
                var x: i32 = @intFromFloat(@floor(minimum[0] - 0.25) - 1);
                while (@as(f64, @floatFromInt(x)) <= @floor(maximum[0] + 0.25) + 1) : (x += 1) {
                    const position: chunks.Position = .{ .x = x, .y = y, .z = z };
                    var views: [1]chunks.View = undefined;
                    try window.readMany(&.{chunks.sectionAt(body.world, position)}, &views);
                    const state = views[0].get(chunks.localIndex(position));
                    if (state >= game_data.registry.block_state_collision_shape.len) return error.Corrupt;
                    const shape = game_data.registry.collision_shapes[game_data.registry.block_state_collision_shape[state]];
                    for (game_data.registry.collision_boxes[shape.offset..][0..shape.count]) |box| {
                        const base: [3]i64 = .{ @as(i64, x) * 64, @as(i64, y) * 64, @as(i64, z) * 64 };
                        const low: [3]i64 = .{ base[0] + box.min_x - 16, base[1] + box.min_y - 16, base[2] + box.min_z - 16 };
                        const high: [3]i64 = .{ base[0] + box.max_x + 16, base[1] + box.max_y + 16, base[2] + box.max_z + 16 };
                        var first: [3]usize = undefined;
                        var last: [3]usize = undefined;
                        for (0..3) |axis| {
                            first[axis] = @intCast(std.math.clamp(low[axis] - origin[axis], 0, @as(i64, @intCast(size[axis]))));
                            last[axis] = @intCast(std.math.clamp(high[axis] - origin[axis], 0, @as(i64, @intCast(size[axis]))));
                        }
                        for (first[1]..last[1]) |iy| for (first[2]..last[2]) |iz| {
                            const row = (iy * size[2] + iz) * size[0];
                            occupied.setRangeValue(.{ .start = row + first[0], .end = row + last[0] }, true);
                        };
                    }
                }
            }
        }
        var closest = std.math.inf(f64);
        var destination = center;
        for (0..size[0] * size[1] * size[2]) |index| {
            if (occupied.isSet(index)) continue;
            const cell: [3]usize = .{ index % size[0], index / size[0] / size[2], index / size[0] % size[2] };
            var candidate: [3]f64 = undefined;
            var squared: f64 = 0;
            for (0..3) |axis| {
                const low = @max(minimum[axis], @as(f64, @floatFromInt(origin[axis] + @as(i64, @intCast(cell[axis])))) / 64);
                const high = @min(maximum[axis], @as(f64, @floatFromInt(origin[axis] + @as(i64, @intCast(cell[axis])) + 1)) / 64);
                candidate[axis] = std.math.clamp(center[axis], low, high);
                squared += (candidate[axis] - center[axis]) * (candidate[axis] - center[axis]);
            }
            if (squared < closest) {
                closest = squared;
                destination = candidate;
            }
        }
        body.position = .{ destination[0], destination[1] - 0.25, destination[2] };
    }

    /// WorldBorder.canCollide for a body whose feet stand at `position`, moving by `motion`: near
    /// the border and inside it, the border's outside as four boxes, as Entity.findCollisionsForMovement
    /// adds it. The same rule as vanilla_bodies' borderFor.
    fn borderFor(self: *const ItemPhysics, world: u32, position: [3]f64, half_width: f64, motion: [3]f64) ?[4][2][3]f64 {
        const shared = self.border orelse return null;
        const bounds = shared.of(world);
        if (!bounds.canCollide(position[0], position[2], half_width * 2 + @abs(motion[0]), half_width * 2 + @abs(motion[2]))) return null;
        return bounds.outside();
    }

    /// VoxelShape.collide along one axis for one box, within vanilla's 1e-7 tolerance.
    fn clampAgainst(low: [3]f64, high: [3]f64, minimum: [3]f64, maximum: [3]f64, axis: usize, requested: f64) f64 {
        const a = (axis + 1) % 3;
        const b = (axis + 2) % 3;
        if (maximum[a] <= low[a] + 1e-7 or minimum[a] >= high[a] - 1e-7 or maximum[b] <= low[b] + 1e-7 or minimum[b] >= high[b] - 1e-7) return requested;
        var movement = requested;
        if (movement > 0 and maximum[axis] <= low[axis] + 1e-7) movement = @min(movement, @max(0, low[axis] - maximum[axis]));
        if (movement < 0 and minimum[axis] >= high[axis] - 1e-7) movement = @max(movement, @min(0, high[axis] - minimum[axis]));
        return movement;
    }

    fn advanceBody(self: *ItemPhysics, comptime orb: bool, neighborhood: *Window, entity_id: u32, ticks: u32, body: entities.State, on_ground: bool, stuck: [3]f64, effects: anytype) !Result {
        assert(entity_id > 0 and neighborhood.client.index == self.chunk_client.index);
        var next = body;

        for (body.position ++ body.velocity) |value| assert(std.math.isFinite(value));
        const vertical_velocity = next.velocity[1];
        var motion = next.velocity;
        var orb_effects: OrbEffects = .{};
        var grounded = on_ground;
        var moved = false;
        if (orb or !on_ground or next.velocity[0] * next.velocity[0] + next.velocity[2] * next.velocity[2] > @as(f64, @as(f32, 0.00001)) or
            movesOnPhase(ticks, entity_id))
        {
            moved = true;
            // Entity.move: what holds the body back takes its motion and is spent.
            if (stuck[0] * stuck[0] + stuck[1] * stuck[1] + stuck[2] * stuck[2] > 1e-7) {
                for (&motion, stuck) |*component, multiplier| component.* *= multiplier;
                next.velocity = .{ 0, 0, 0 };
            }
            const order: [3]usize = if (@abs(motion[0]) < @abs(motion[2])) .{ 1, 2, 0 } else .{ 1, 0, 2 };
            // Entity.adjustMovementForCollisions moves the box axis by axis; Entity.move then takes
            // the result only if it goes somewhere or the blocks barely held it back.
            var box_at = next.position;
            var adjusted: [3]f64 = .{ 0, 0, 0 };
            const body_half: f64 = if (orb) 0.25 else 0.125;
            const body_tall: f64 = if (orb) 0.5 else 0.25;
            const border = self.borderFor(body.world, next.position, body_half, motion);

            for (order) |axis| {
                const requested = motion[axis];
                if (requested == 0) continue;

                var movement = requested;
                const minimum: [3]f64 = .{ box_at[0] - body_half, box_at[1], box_at[2] - body_half };
                const maximum: [3]f64 = .{ box_at[0] + body_half, box_at[1] + body_tall, box_at[2] + body_half };
                // The border's shape comes before the blocks'.
                if (border) |outside| for (outside) |side| {
                    movement = clampAgainst(side[0], side[1], minimum, maximum, axis, movement);
                };
                var first: [3]i32 = undefined;
                var last: [3]i32 = undefined;

                for (0..3) |a| {
                    first[a] = @intFromFloat(@floor(minimum[a] + if (a == axis) @min(requested, 0) else 0) - 1);
                    last[a] = @intFromFloat(@floor(maximum[a] + if (a == axis) @max(requested, 0) else 0) + 1);
                }

                const sx = @divFloor(first[0], 16);
                const sy = @divFloor(first[1], 16);
                const sz = @divFloor(first[2], 16);
                const nx: usize = @intCast(@divFloor(last[0], 16) - sx + 1);
                const ny: usize = @intCast(@divFloor(last[1], 16) - sy + 1);
                const nz: usize = @intCast(@divFloor(last[2], 16) - sz + 1);
                var cursor: usize = 0;

                while (cursor < nx * ny * nz) {
                    var sections: [8]chunks.Section = undefined;
                    var views: [8]chunks.View = undefined;
                    const count = @min(sections.len, self.deps.chunks.cache.entries.len, nx * ny * nz - cursor);
                    assert(count > 0);

                    for (sections[0..count], 0..) |*section, i| {
                        const at = cursor + i;
                        section.* = .{
                            .world = body.world,
                            .x = sx + @as(i32, @intCast(at % nx)),
                            .z = sz + @as(i32, @intCast(at / nx % nz)),
                            .y = sy + @as(i32, @intCast(at / nx / nz)),
                        };
                    }

                    try neighborhood.readMany(sections[0..count], views[0..count]);
                    cursor += count;

                    for (sections[0..count], views[0..count]) |section, view| {
                        if (view == .uniform) {
                            const state = view.uniform;
                            if (state >= game_data.registry.block_state_collision_shape.len) return error.Corrupt;
                            const shape = game_data.registry.collision_shapes[game_data.registry.block_state_collision_shape[state]];
                            if (shape.count == 0) continue;
                        }
                        var y = @max(first[1], section.y * 16);

                        while (y <= @min(last[1], section.y * 16 + 15)) : (y += 1) {
                            var z = @max(first[2], section.z * 16);

                            while (z <= @min(last[2], section.z * 16 + 15)) : (z += 1) {
                                var x = @max(first[0], section.x * 16);

                                while (x <= @min(last[0], section.x * 16 + 15)) : (x += 1) {
                                    const state = view.get(chunks.localIndex(.{ .x = x, .y = y, .z = z }));
                                    if (state >= game_data.registry.block_state_collision_shape.len) return error.Corrupt;

                                    const shape = game_data.registry.collision_shapes[game_data.registry.block_state_collision_shape[state]];
                                    const offset: [3]f64 = .{ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) };

                                    for (game_data.registry.collision_boxes[shape.offset..][0..shape.count]) |box| {
                                        const low: [3]f64 = .{ offset[0] + @as(f64, @floatFromInt(box.min_x)) / 64, offset[1] + @as(f64, @floatFromInt(box.min_y)) / 64, offset[2] + @as(f64, @floatFromInt(box.min_z)) / 64 };
                                        const high: [3]f64 = .{ offset[0] + @as(f64, @floatFromInt(box.max_x)) / 64, offset[1] + @as(f64, @floatFromInt(box.max_y)) / 64, offset[2] + @as(f64, @floatFromInt(box.max_z)) / 64 };
                                        const a = (axis + 1) % 3;
                                        const b = (axis + 2) % 3;
                                        if (maximum[a] <= low[a] + 1e-7 or minimum[a] >= high[a] - 1e-7 or
                                            maximum[b] <= low[b] + 1e-7 or minimum[b] >= high[b] - 1e-7) continue;

                                        if (movement > 0 and maximum[axis] <= low[axis] + 1e-7) movement = @min(movement, @max(0, low[axis] - maximum[axis]));

                                        if (movement < 0 and minimum[axis] >= high[axis] - 1e-7) movement = @max(movement, @min(0, high[axis] - minimum[axis]));
                                    }
                                }
                            }
                        }
                    }
                }

                box_at[axis] += movement;
                adjusted[axis] = movement;

                if (axis == 1) grounded = requested < 0 and requested != movement;

                // A vertical stop is Block.onEntityLand, which scales the fall away (to -0.0 when
                // falling); a sideways one counts only past MathHelper.approximatelyEquals.
                if (axis == 1) {
                    if (requested != movement) next.velocity[1] *= 0;
                } else if (!(@abs(movement - requested) < 1.0e-5)) next.velocity[axis] = 0;
            }
            const taken = adjusted[0] * adjusted[0] + adjusted[1] * adjusted[1] + adjusted[2] * adjusted[2];
            const asked = motion[0] * motion[0] + motion[1] * motion[1] + motion[2] * motion[2];
            if (taken > 1.0e-7 or asked - taken < 1.0e-7) {
                for (&next.position, adjusted) |*axis, movement| axis.* += movement;
            }

            var below: ?u16 = null;
            const half_width: f64 = if (orb) 0.25 else 0.125;
            // Entity.getVelocityAffectingPos: the block it rests on when it rests on one, at the
            // height just over half a block below its feet.
            const supporting = if (grounded) try self.supportingBlock(neighborhood, body.world, next.position, half_width, adjusted) else null;
            const below_y: i32 = @intFromFloat(@floor(next.position[1] - @as(f64, @as(f32, 0.500001))));
            const below_position: chunks.Position = if (supporting) |at| .{ .x = at.x, .y = below_y, .z = at.z } else .{ .x = @intFromFloat(@floor(next.position[0])), .y = below_y, .z = @intFromFloat(@floor(next.position[2])) };
            // Entity.getBlockSpeedFactor, which slows every body on soul sand and honey.
            {
                const base = self.deps.blocks.get(try self.blockState(neighborhood, body.world, .{ .x = @intFromFloat(@floor(next.position[0])), .y = @intFromFloat(@floor(next.position[1])), .z = @intFromFloat(@floor(next.position[2])) }));
                var speed = base.speed;
                if (speed == 1 and !base.water_block) {
                    below = try self.blockState(neighborhood, body.world, below_position);
                    speed = self.deps.blocks.get(below.?).speed;
                }
                next.velocity[0] *= speed;
                next.velocity[2] *= speed;
            }
            if (@TypeOf(effects) != void) try effects.apply(&next, grounded, body.position);
            if (orb) {
                orb_effects = try self.orbEffects(neighborhood, next);
                const effects_found = orb_effects;
                if (effects_found.honey and !grounded) {
                    // Vanilla applies its living-entity gravity transform to every honey slider.
                    const previous = next.velocity[1] / @as(f64, @as(f32, 0.98)) + 0.08;
                    if (previous < -0.08) {
                        if (previous < -0.13) {
                            next.velocity[0] *= -0.05 / previous;
                            next.velocity[2] *= -0.05 / previous;
                        }
                        next.velocity[1] = (-0.05 - 0.08) * @as(f64, @as(f32, 0.98));
                    }
                }
                if (effects_found.bubble) |bubble| {
                    next.velocity[1] = if (bubble.drag) @max(if (bubble.surface) @as(f64, -0.9) else -0.3, next.velocity[1] - 0.03) else @min(if (bubble.surface) @as(f64, 1.8) else 0.7, next.velocity[1] + (if (bubble.surface) @as(f64, 0.1) else 0.06));
                }
            }

            var friction: f32 = 0.98;
            if (grounded) {
                const state = below orelse try self.blockState(neighborhood, body.world, below_position);
                friction *= self.deps.blocks.get(state).friction;
            }

            next.velocity[0] *= friction;
            next.velocity[1] *= if (orb) @as(f64, friction) else 0.98;
            next.velocity[2] *= friction;

            if (orb) {
                if (grounded and vertical_velocity < -0.03) next.velocity[1] = -vertical_velocity * 0.4;
            } else if (grounded and next.velocity[1] < 0) next.velocity[1] *= -0.5;
        }

        var crossed = false;

        for (body.position, next.position) |before, after| crossed = crossed or @floor(before) != @floor(after);
        return .{ .body = next, .on_ground = grounded, .crossed_block = crossed, .moved = moved, .effects = orb_effects };
    }
};

/// ItemEntity.tick's `(age + getId()) % 4 == 0`, in Java's int arithmetic with the network id
/// the world sends, which is the negated entity id. An item lying still on the ground moves, and
/// so finds out its block went, only on these ticks: items fall in four groups by their id, which
/// wireless redstone relies on. Sleeping must keep waking resting items in time for theirs.
pub fn movesOnPhase(ticks: u32, entity_id: u32) bool {
    assert(entity_id > 0 and entity_id <= std.math.maxInt(i32));
    const network_id = -@as(i32, @intCast(entity_id));
    return @rem(@as(i32, @bitCast(ticks)) +% network_id, 4) == 0;
}

test "resting items move on ticks grouped by their network id, four groups" {
    // Entity 1 is network id -1: (5 + -1) % 4 == 0.
    try std.testing.expect(movesOnPhase(5, 1));
    try std.testing.expect(!movesOnPhase(5, 2));
    try std.testing.expect(movesOnPhase(6, 2));
    // Java's remainder keeps the sign: (1 + -3) % 4 is -2, not a move tick; (3 + -3) is.
    try std.testing.expect(!movesOnPhase(1, 3));
    try std.testing.expect(movesOnPhase(3, 3));
    // Every tick, exactly a quarter of any four consecutive ids move.
    for (0..8) |tick| {
        var moving: usize = 0;
        for (1..5) |id| moving += @intFromBool(movesOnPhase(@intCast(tick), @intCast(id)));
        try std.testing.expectEqual(@as(usize, 1), moving);
    }
}

/// Vec3.normalize: zero below a float's 1e-5 long.
fn normalized(vector: [3]f64) [3]f64 {
    const size = length(vector);
    if (size < @as(f32, 1.0e-5)) return .{ 0, 0, 0 };
    return .{ vector[0] / size, vector[1] / size, vector[2] / size };
}

fn length(vector: [3]f64) f64 {
    return @sqrt(vector[0] * vector[0] + vector[1] * vector[1] + vector[2] * vector[2]);
}

fn scaled(vector: [3]f64, factor: f64) [3]f64 {
    return .{ vector[0] * factor, vector[1] * factor, vector[2] * factor };
}

/// ItemEntity.setFluidMovement: slowed across, and lifted while sinking or rising slowly.
fn buoy(velocity: *[3]f64, comptime drag: f32) void {
    velocity[0] *= drag;
    velocity[1] += if (velocity[1] < @as(f32, 0.06)) @as(f64, @as(f32, 5.0e-4)) else 0;
    velocity[2] *= drag;
}
