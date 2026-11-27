//! Dropped items and experience orbs as ItemEntity and ExperienceOrb move them, over the bodies
//! substrate every kind shares: Entity.move's collisions with blocks, the border and solid
//! entities, the currents that push them, the block they rest on and the way out of a block they
//! are in all come from it. What is theirs alone stays here: how they float, fall, bounce, slow
//! and rest, on the server and as each release's clients step them.

const std = @import("std");
const game_data = @import("game_data");
const entities = @import("entities");
const bodies = @import("vanilla_bodies");
const Blocks = @import("vanilla_content").blocks.Blocks;

const body = bodies.body;
const fluids = bodies.fluids;
const mth = bodies.mth;
const Box = body.Box;
const Level = body.Level;
const Levels = bodies.levels.Levels;
const assert = std.debug.assert;

pub const ItemPhysics = struct {
    pub const id = "minecraft:item_physics";

    pub const Configuration = struct {};

    pub const Dependencies = struct { blocks: *Blocks, levels: *Levels };

    /// Where a body stands, as Entity keeps it from one move to the next: onGround;
    /// onGroundNoBlocks, on the ground with nothing but an entity under it, which the next move
    /// goes by; and mainSupportingBlockPos, the block it stands on, which getOnPos goes by. A move
    /// inside a block, with noPhysics, leaves it all as it was.
    pub const Ground = struct { on: bool = false, no_blocks: bool = false, supporting: ?[3]i32 = null };

    pub const Result = struct {
        body: entities.State,
        ground: Ground,
        crossed_block: bool,
        /// Whether it moved this tick, which takes what held it back.
        moved: bool = false,
    };

    /// What an item's move does once it moved: Entity.applyEffectsFromBlocks with the blocks it
    /// crossed, answered by whoever keeps its hazards, given where the body stands after the move.
    pub const Hook = struct {
        context: *anyopaque,
        apply: *const fn (context: *anyopaque, state: *entities.State, ground: Ground, from: [3]f64) anyerror!void,
    };

    deps: Dependencies,
    /// By state, the blocks an item rests on that do something to it beside holding it.
    restless: []bool,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*ItemPhysics {
        const self = try allocator.create(ItemPhysics);
        const restless = try allocator.alloc(bool, game_data.registry.block_state_names.len);
        for (restless, game_data.registry.block_state_names) |*marked, name| {
            const block = name[0 .. std.mem.indexOfScalar(u8, name, '[') orelse name.len];
            marked.* = for (restless_supports) |known| {
                if (std.mem.eql(u8, block, known)) break true;
            } else false;
        }
        self.* = .{ .deps = deps, .restless = restless };
        return self;
    }

    /// The world as an item or orb in it reads it.
    pub fn level(self: *ItemPhysics, world: u32) Level {
        return self.deps.levels.level(world);
    }

    const item_width: f32 = 0.25;
    const item_height: f32 = 0.25;
    const orb_width: f32 = 0.5;
    const orb_height: f32 = 0.5;

    fn itemBox(position: [3]f64) Box {
        return body.makeBox(position, item_width, item_height);
    }

    fn orbBox(position: [3]f64) Box {
        return body.makeBox(position, orb_width, orb_height);
    }

    /// The start of an item's Entity.baseTick: pushed by the currents it is in. How deep it is
    /// in each fluid decides what it does next.
    pub fn push(_: *ItemPhysics, at: *const Level, state: *entities.State, ultrawarm: bool) !Fluids {
        return pushFluids(at, itemBox(state.position), state, ultrawarm);
    }

    /// The start of an orb's Entity.baseTick, as `push` for items.
    pub fn pushOrb(_: *ItemPhysics, at: *const Level, state: *entities.State, ultrawarm: bool) !Fluids {
        return pushFluids(at, orbBox(state.position), state, ultrawarm);
    }

    /// How deep a body is in water and in lava: from its bottom to the top of the fluid.
    pub const Fluids = struct { water: f64 = 0, lava: f64 = 0 };

    /// Entity.updateInWaterStateAndDoFluidPushing: pushed by the water around it, then by the
    /// lava, as Entity.updateFluidHeightAndDoFluidPushing does with each.
    fn pushFluids(at: *const Level, box: Box, state: *entities.State, ultrawarm: bool) !Fluids {
        const water = try fluids.heightAndPush(at, box, &state.velocity, .water, 0.014);
        const lava = try fluids.heightAndPush(at, box, &state.velocity, .lava, if (ultrawarm) 0.007 else 0.0023333333333333335);
        return .{ .water = water.height, .lava = lava.height };
    }

    /// The rest of ItemEntity.tick's movement, after `push`: afloat in water or lava over a
    /// tenth deep and falling otherwise, then moved, held back by what `stuck` holds it in, and
    /// slowed. Moving, it goes through `hook`, which does what the blocks it crossed do to it, as
    /// Entity.applyEffectsFromBlocks. A stuck item stays stuck until it moves.
    pub fn advance(self: *ItemPhysics, at: *const Level, entity_id: u32, ticks: u32, pushed: entities.State, ground: Ground, fluid: Fluids, stuck: [3]f64, hook: ?Hook) !Result {
        return self.advanceRandomly(at, entity_id, ticks, pushed, ground, fluid, stuck, hook, null);
    }

    /// As `advance`, with the random an item inside a block is pushed out by: ItemEntity.tick's
    /// noPhysics, then Entity.moveTowardsClosestSpace. Without one, an item inside stays as it is.
    pub fn advanceRandomly(self: *ItemPhysics, at: *const Level, entity_id: u32, ticks: u32, pushed: entities.State, ground: Ground, fluid: Fluids, stuck: [3]f64, hook: ?Hook, random: ?std.Random) !Result {
        assert(entity_id > 0);
        var next = pushed;
        afloat(&next.velocity, fluid);
        // Inside a block, or a solid entity, it moves through them, pushed towards the nearest way out.
        if (random) |source| if (!try body.noCollision(at, itemBox(next.position).inflate(-1.0e-7, -1.0e-7, -1.0e-7), .{ .bottom = next.position[1] })) {
            try escape(at, &next, source, item_height / 2);
            return self.advanceThrough(at, entity_id, ticks, next, ground, hook);
        };
        return self.advanceBody(false, .server, .latest, at, entity_id, ticks, next, ground, stuck, hook);
    }

    /// ItemEntity.tick's move with noPhysics set: Entity.move only adds the motion, touching
    /// neither what holds the item back nor where it stands; the slowing after is as ever, by the
    /// block it stood on.
    fn advanceThrough(self: *ItemPhysics, at: *const Level, entity_id: u32, ticks: u32, state: entities.State, ground: Ground, hook: ?Hook) !Result {
        var next = state;
        const on_ground = ground.on;
        const moved = !on_ground or next.velocity[0] * next.velocity[0] + next.velocity[2] * next.velocity[2] > @as(f64, @as(f32, 0.00001)) or movesOnPhase(ticks, entity_id);
        if (moved) {
            for (&next.position, next.velocity) |*position, velocity| position.* += velocity;
            if (hook) |effects| try effects.apply(effects.context, &next, ground, state.position);
            var friction: f32 = 0.98;
            if (on_ground) {
                const below = try body.onPos(at, ground.supporting, next.position, @as(f32, 0.999999));
                friction *= self.deps.blocks.get(try at.state(below[0], below[1], below[2])).friction;
            }
            next.velocity[0] *= friction;
            next.velocity[1] *= Release.latest.verticalDrag();
            next.velocity[2] *= friction;
            if (on_ground and next.velocity[1] < 0) next.velocity[1] *= -0.5;
        }
        return .{ .body = next, .ground = ground, .crossed_block = crossed(state.position, next.position), .moved = moved };
    }

    /// An item's movement alone, `push` then `advance`, with nothing holding it back and no
    /// block effects.
    pub fn step(self: *ItemPhysics, at: *const Level, entity_id: u32, ticks: u32, state: entities.State, on_ground: bool, ultrawarm: bool) !Result {
        var pushed = state;
        const fluid = try self.push(at, &pushed, ultrawarm);
        return self.advance(at, entity_id, ticks, pushed, .{ .on = on_ground }, fluid, .{ 0, 0, 0 }, null);
    }

    /// ExperienceOrb.tick's move, through `hook` every tick, as Entity.applyEffectsFromBlocks.
    /// An orb always moves, so the block it stands on is found anew each tick.
    pub fn advanceOrb(self: *ItemPhysics, at: *const Level, entity_id: u32, ticks: u32, state: entities.State, ground: Ground, stuck: [3]f64, hook: ?Hook) !Result {
        return self.advanceBody(true, .server, .latest, at, entity_id, ticks, state, ground, stuck, hook);
    }

    pub const OrbEnvironment = struct { solid: bool, water: bool, lava: bool };

    /// ExperienceOrb.tick's look about it: inside something it collides with, as
    /// Level.noCollision(box) asks with no entity; its eyes under water; in lava at its feet.
    pub fn orbEnvironment(self: *ItemPhysics, at: *const Level, state: entities.State) !OrbEnvironment {
        const eye = state.position[1] + @as(f64, @as(f32, 0.425));
        const x = mth.floor(state.position[0]);
        const z = mth.floor(state.position[2]);
        const eye_y = mth.floor(eye);
        const water = self.deps.blocks.get(try at.state(x, eye_y, z));
        const above = self.deps.blocks.get(try at.state(x, eye_y + 1, z));
        const base = self.deps.blocks.get(try at.state(x, mth.floor(state.position[1]), z));
        return .{
            .solid = try self.orbCollides(at, state),
            .water = water.fluid == .water and eye < @as(f64, @as(f32, @floatFromInt(eye_y)) + (if (above.fluid == .water) @as(f32, 1) else water.height())),
            .lava = base.fluid == .lava,
        };
    }

    /// Whether an orb's box holds a block shape or a solid entity: Level.noCollision(box), with
    /// no entity, inverted.
    pub fn orbCollides(_: *ItemPhysics, at: *const Level, state: entities.State) !bool {
        return !try body.noCollision(at, orbBox(state.position), .{ .empty = true });
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

    pub fn rest(self: *ItemPhysics, at: *const Level, state: entities.State) !?Rest {
        const p = state.position;
        // The cells the box is in: 0.25 wide and high, standing on the block below.
        var x = mth.floor(p[0] - 0.125);
        while (x <= mth.floor(p[0] + 0.125)) : (x += 1) {
            var z = mth.floor(p[2] - 0.125);
            while (z <= mth.floor(p[2] + 0.125)) : (z += 1) {
                var y = mth.floor(p[1]);
                while (y <= mth.floor(p[1] + 0.25)) : (y += 1) {
                    if (!game_data.physics.get(try at.state(x, y, z)).air) return null;
                }
            }
        }
        // The block it rests on, as advanceBody finds it after a move; none, as on an entity,
        // and it keeps awake.
        const supporting = (try body.supportingBlock(at, itemBox(p), .{ .bottom = p[1] }, p, null, false)) orelse return null;
        const below = try at.state(supporting[0], mth.floor(p[1] - @as(f64, @as(f32, 0.999999))), supporting[2]);
        if (self.restless[below]) return null;
        // As advanceBody works them out on a move tick.
        const base = self.deps.blocks.get(try at.state(mth.floor(p[0]), mth.floor(p[1]), mth.floor(p[2])));
        var speed = base.speed;
        if (speed == 1 and !base.water_block) speed = self.deps.blocks.get(below).speed;
        var friction: f32 = 0.98;
        friction *= self.deps.blocks.get(below).friction;
        return .{ .speed = speed, .friction = friction };
    }

    pub fn escapeOrb(_: *ItemPhysics, at: *const Level, state: *entities.State, random: std.Random) !void {
        return escape(at, state, random, orb_height / 2);
    }

    /// Entity.moveTowardsClosestSpace from the middle of the body's box, `half_height` above its
    /// feet: towards the nearest side, of four and the top, that is not a full block.
    fn escape(at: *const Level, state: *entities.State, random: std.Random, comptime half_height: f64) !void {
        const center: [3]f64 = .{ state.position[0], state.position[1] + half_height, state.position[2] };
        const directions = [_][3]i32{ .{ 0, 0, -1 }, .{ 0, 0, 1 }, .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } };
        var selected: usize = 4;
        var closest = std.math.inf(f64);
        for (directions, 0..) |direction, index| {
            const block_state = try at.state(mth.floor(center[0]) + direction[0], mth.floor(center[1]) + direction[1], mth.floor(center[2]) + direction[2]);
            // BlockState.isCollisionShapeFullBlock.
            if (at.blocks.get(block_state).collision == at.blocks.full_cube) continue;
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
        for (directions[selected], &state.velocity) |component, *velocity| velocity.* = if (component == 0) velocity.* * 0.75 else @as(f32, @floatFromInt(component)) * impulse;
    }

    /// ExperienceOrb's place as it comes into the world, out of the blocks it would be in: the
    /// nearest point where its box meets no block shape.
    pub fn placeOrb(self: *ItemPhysics, at: *const Level, state: *entities.State) !void {
        if (!try self.orbCollides(at, state.*)) return;
        const center: [3]f64 = .{ state.position[0], state.position[1] + 0.25, state.position[2] };
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
                    const block_state = try at.state(x, y, z);
                    const shape = game_data.registry.collision_shapes[game_data.registry.block_state_collision_shape[block_state]];
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
        state.position = .{ destination[0], destination[1] - 0.25, destination[2] };
    }

    /// Which side moves it: a client skips what only the side that simulates it does.
    pub const Side = enum { server, client };

    /// An item's move as a client makes it, from where it was pushed: ItemEntity.tick with
    /// Entity.canSimulateMovement false, so no landing reaction keeps a fall from turning into a
    /// bounce, and never pushed out of the block it is in. `ticks` is the client's own tick count,
    /// and `release` how its release steps it.
    pub fn advanceClient(self: *ItemPhysics, at: *const Level, entity_id: u32, ticks: u32, pushed: entities.State, ground: Ground, fluid: Fluids, release: Release) !Result {
        var next = pushed;
        afloat(&next.velocity, fluid);
        return self.advanceBody(false, .client, release, at, entity_id, ticks, next, ground, .{ 0, 0, 0 }, null);
    }

    /// How a release steps an item, where releases differ. From 26.2, ItemEntity.tick slows its
    /// fall by Entity.getAirDrag, the float 0.98, and before by the double 0.98; and from 26.2
    /// Entity.restituteMovementAfterCollisions takes the motion of a sideways stop too, only where
    /// canSimulateMovement, so a client keeps an item's motion against a wall, where before every
    /// side took it. The server steps as the latest.
    pub const Release = enum {
        latest,
        before_26_2,

        /// 26.2's protocol.
        const latest_protocol = 776;

        pub fn of(protocol: i32) Release {
            return if (protocol >= latest_protocol) .latest else .before_26_2;
        }

        fn verticalDrag(self: Release) f64 {
            return switch (self) {
                .latest => @as(f64, @as(f32, 0.98)),
                .before_26_2 => 0.98,
            };
        }
    };

    /// The sets of rules clients step items by, the server's own first: the releases.
    pub const rule_sets = @typeInfo(Release).@"enum".field_names.len;

    /// Which set of rules a protocol's clients step items by.
    pub fn rulesOf(protocol: i32) u8 {
        return @backingInt(Release.of(protocol));
    }

    pub fn releaseOf(rules: u8) Release {
        return @fromBackingInt(@intCast(rules));
    }

    /// ItemEntity.setUnderwaterMovement and setUnderLavaMovement in place of gravity.
    fn afloat(velocity: *[3]f64, fluid: Fluids) void {
        if (fluid.water > @as(f32, 0.1)) {
            buoy(velocity, @as(f32, 0.99));
        } else if (fluid.lava > @as(f32, 0.1)) {
            buoy(velocity, @as(f32, 0.95));
        } else velocity[1] -= 0.04;
    }

    fn advanceBody(self: *ItemPhysics, comptime orb: bool, comptime moving: Side, release: Release, at: *const Level, entity_id: u32, ticks: u32, state: entities.State, ground: Ground, stuck: [3]f64, hook: ?Hook) !Result {
        assert(entity_id > 0);
        var next = state;
        const on_ground = ground.on;
        for (state.position ++ state.velocity) |value| assert(std.math.isFinite(value));
        const vertical_velocity = next.velocity[1];
        var motion = next.velocity;
        var grounded = on_ground;
        var after = ground;
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
            // Entity.collide against blocks, the border and solid entities, which items never
            // step up from.
            const start = if (orb) orbBox(next.position) else itemBox(next.position);
            const adjusted = try body.collide(at, start, motion, .{ .bottom = next.position[1] }, on_ground, 0);
            for (0..3) |axis| {
                const requested = motion[axis];
                if (requested == 0) continue;
                const movement = adjusted[axis];
                if (axis == 1) {
                    grounded = requested < 0 and requested != movement;
                    // A vertical stop is Block.onEntityLand, which scales the fall away (to -0.0
                    // when falling), as Entity.restituteMovementAfterCollisions does where
                    // canSimulateMovement.
                    if (requested != movement and moving == .server) next.velocity[1] *= 0;
                    // A sideways one counts only past Mth.equal.
                } else if (!(@abs(movement - requested) < 1.0e-5) and (moving == .server or release == .before_26_2)) next.velocity[axis] = 0;
            }
            // Entity.move takes the result only if it goes somewhere or the blocks barely held
            // it back.
            const taken = adjusted[0] * adjusted[0] + adjusted[1] * adjusted[1] + adjusted[2] * adjusted[2];
            const asked = motion[0] * motion[0] + motion[1] * motion[1] + motion[2] * motion[2];
            if (taken > 1.0e-7 or asked - taken < 1.0e-7) {
                for (&next.position, adjusted) |*axis, movement| axis.* += movement;
            }

            // ItemEntity and ExperienceOrb.getBlockPosBelowThatAffectsMyMovement, getOnPos(0.999999):
            // the block it rests on when it rests on one, at the height just under a block below
            // its feet, so the block under a slab it lies on.
            const box = if (orb) orbBox(next.position) else itemBox(next.position);
            // Entity.checkSupportingBlock.
            const supporting = if (grounded) try body.supportingBlock(at, box, .{ .bottom = next.position[1] }, next.position, adjusted, ground.no_blocks) else null;
            after = .{ .on = grounded, .no_blocks = grounded and supporting == null, .supporting = supporting };
            const below_position = try body.onPos(at, supporting, next.position, @as(f32, 0.999999));
            var below: ?u16 = null;
            // Entity.getBlockSpeedFactor, which slows every body on soul sand and honey.
            {
                const base = self.deps.blocks.get(try at.state(mth.floor(next.position[0]), mth.floor(next.position[1]), mth.floor(next.position[2])));
                var speed = base.speed;
                if (speed == 1 and !base.water_block) {
                    below = try at.state(below_position[0], below_position[1], below_position[2]);
                    speed = self.deps.blocks.get(below.?).speed;
                }
                next.velocity[0] *= speed;
                next.velocity[2] *= speed;
            }
            if (hook) |effects| try effects.apply(effects.context, &next, after, state.position);
            var friction: f32 = 0.98;
            if (grounded) {
                const below_state = below orelse try at.state(below_position[0], below_position[1], below_position[2]);
                friction *= self.deps.blocks.get(below_state).friction;
            }

            next.velocity[0] *= friction;
            next.velocity[1] *= if (orb) @as(f64, friction) else release.verticalDrag();
            next.velocity[2] *= friction;

            if (orb) {
                if (grounded and vertical_velocity < -0.03) next.velocity[1] = -vertical_velocity * 0.4;
            } else if (grounded and next.velocity[1] < 0) next.velocity[1] *= -0.5;
        }
        return .{ .body = next, .ground = after, .crossed_block = crossed(state.position, next.position), .moved = moved };
    }
};

fn crossed(before: [3]f64, after: [3]f64) bool {
    for (before, after) |from, to| if (@floor(from) != @floor(to)) return true;
    return false;
}

/// ItemEntity.tick's `(age + getId()) % 4 == 0`, in Java's int arithmetic with the network id
/// the world sends. An item lying still on the ground moves, and so finds out its block went,
/// only on these ticks: items fall in four groups by their id, which wireless redstone relies on.
/// Sleeping must keep waking resting items in time for theirs.
pub fn movesOnPhase(ticks: u32, entity_id: u32) bool {
    assert(entity_id > 0 and entity_id <= std.math.maxInt(i32));
    const network_id: i32 = @intCast(entity_id);
    return @rem(@as(i32, @bitCast(ticks)) +% network_id, 4) == 0;
}

test "resting items move on ticks grouped by their network id, four groups" {
    // (3 + 1) % 4 == 0.
    try std.testing.expect(movesOnPhase(3, 1));
    try std.testing.expect(!movesOnPhase(3, 2));
    try std.testing.expect(movesOnPhase(2, 2));
    // Java's int addition wraps, and its remainder keeps the sign: an age past the int range
    // goes negative, (-2147483648 + 4) % 4 == 0.
    try std.testing.expect(movesOnPhase(0x8000_0000, 4));
    try std.testing.expect(!movesOnPhase(0x8000_0001, 4));
    // Every tick, exactly a quarter of any four consecutive ids move.
    for (0..8) |tick| {
        var moving: usize = 0;
        for (1..5) |id| moving += @intFromBool(movesOnPhase(@intCast(tick), @intCast(id)));
        try std.testing.expectEqual(@as(usize, 1), moving);
    }
}

/// ItemEntity.setFluidMovement: slowed across, and lifted while sinking or rising slowly.
fn buoy(velocity: *[3]f64, comptime drag: f32) void {
    velocity[0] *= drag;
    velocity[1] += if (velocity[1] < @as(f32, 0.06)) @as(f64, @as(f32, 5.0e-4)) else 0;
    velocity[2] *= drag;
}
