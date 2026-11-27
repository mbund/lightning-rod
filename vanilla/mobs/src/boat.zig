//! A boat or raft as vanilla 1.21.8 keeps it, and its tick on the server while no player steers it:
//! AbstractBoat.tick with what VehicleEntity and Entity do on the way. A boat reads the world as a
//! level, and the entities it collides with and the rest of the world through `Around`.

const std = @import("std");
const game_data = @import("game_data");
const entities = @import("entities");
const bodies = @import("vanilla_bodies");

const mth = bodies.mth;
const body = bodies.body;
const fluids = bodies.fluids;
const block_effects = bodies.block_effects;
const JavaRandom = bodies.java_random.JavaRandom;
const Box = body.Box;
const assert = std.debug.assert;

/// EntityType's size for every boat and raft, with a chest or without.
pub const box_width: f32 = 1.375;
pub const box_height: f32 = 0.5625;
/// AbstractBoat.getDefaultGravity.
pub const gravity: f64 = 0.04;
/// Ticks under water before passengers are thrown out, and before the boat cannot be boarded.
pub const out_of_control_limit: f32 = 60;

/// AbstractBoat.Status, in vanilla's order.
pub const Status = enum(u8) { in_water, under_water, under_flowing_water, on_land, in_air };

/// What a boat's tick changes that is not its body: VehicleEntity's and AbstractBoat's own, and
/// the Entity fields their tick reads.
pub const Boat = struct {
    /// VehicleEntity.DATA_ID_HURT, DATA_ID_HURTDIR and DATA_ID_DAMAGE.
    hurt_time: i32 = 0,
    hurt_dir: i32 = 1,
    damage: f32 = 0,
    /// AbstractBoat.DATA_ID_BUBBLE_TIME.
    bubble_time: i32 = 0,
    /// Null until the first tick, as the fields start in vanilla.
    status: ?Status = null,
    old_status: ?Status = null,
    out_of_control: f32 = 0,
    water_level: f64 = 0,
    land_friction: f32 = 0,
    last_yd: f64 = 0,
    above_bubble_column: bool = false,
    bubble_column_down: bool = false,
    /// Where the tick began, Entity.xo, yo and zo.
    old_position: [3]f64 = .{ 0, 0, 0 },
    on_ground: bool = false,
    on_ground_no_blocks: bool = false,
    supporting: ?[3]i32 = null,
    fall_distance: f64 = 0,
    stuck: [3]f64 = .{ 0, 0, 0 },
    /// Entity.remainingFireTicks, -getFireImmuneTicks to start, which is none for a boat.
    fire_ticks: i32 = 0,
    ticks_frozen: i32 = 0,
    in_powder_snow: bool = false,
    was_touching_water: bool = false,
    lava_height: f64 = 0,
    /// Entity.isEyeInFluid(WATER), as the last tick left it.
    eye_in_water: bool = false,
    first_tick: bool = true,
    removed: bool = false,
    /// Entity.hasImpulse and hurtMarked, for replication to send its motion now.
    impulse: bool = false,
    hurt_marked: bool = false,
    /// The entity's own RandomSource.
    random: JavaRandom,

    /// Entity.isInLava.
    pub fn inLava(self: *const Boat) bool {
        return !self.first_tick and self.lava_height > 0;
    }

    /// AbstractBoat.isUnderWater.
    pub fn underWater(self: *const Boat) bool {
        const status = self.status orelse return false;
        return status == .under_water or status == .under_flowing_water;
    }
};

/// The sounds a boat's tick makes.
pub const Sound = enum { generic_splash, generic_burn, generic_extinguish_fire, honey_block_slide };

/// What a boat ticks against besides the blocks, answered by whoever keeps it.
pub const Around = struct {
    context: *anyopaque,
    /// The boat's slot, which meets the other entities through the level, as a vehicle does.
    slot: u32,
    /// VehicleEntity.hurtServer, for what blocks and fire do to the boat, whose kind of damage
    /// counts for nothing: whether it took the damage.
    hurt: *const fn (context: *anyopaque, amount: f32) anyerror!bool,
    sound: *const fn (context: *anyopaque, sound: Sound, volume: f32, pitch: f32) void,
    /// What blocks change, through the game's rules: Level.destroyBlock without drops, and with them.
    destroy_block: *const fn (context: *anyopaque, world: u32, position: [3]i32) anyerror!void,
    break_block: *const fn (context: *anyopaque, world: u32, position: [3]i32) anyerror!void,
    lower_cauldron: *const fn (context: *anyopaque, world: u32, position: [3]i32) anyerror!void,
    /// Entity.ejectPassengers, which may leave the boat its own to move.
    eject: *const fn (context: *anyopaque) anyerror!void,
    level_random: *JavaRandom,
    mob_griefing: bool = true,
    /// Whether the dimension is ultrawarm, where lava pushes harder.
    ultrawarm: bool = false,
};

/// Room a tick works in, kept by the owner so it is not filled anew each tick.
pub const Scratch = struct {
    effects: block_effects.Scratch = .{},
};

/// EntityDimensions.makeBoundingBox at a position.
pub fn boxAt(position: [3]f64) Box {
    return body.makeBox(position, box_width, box_height);
}

/// Who moves a boat: the server, or the client of the player who steers it, whose moves since the
/// last tick block effects trace.
pub const Steering = struct {
    steered: bool = false,
    movements: []const block_effects.Movement = &.{},
};

/// AbstractBoat.tick on the server: its body and state move on a tick, by itself unless a player
/// steers it. The owner pushes and picks up what is around it after, and places its riders.
pub fn tick(level: *const body.Level, around: Around, state: *entities.State, boat: *Boat, scratch: *Scratch, steering: *const Steering) !void {
    boat.old_position = state.position;
    boat.old_status = boat.status;
    const status = try statusOf(level, state.position, boat);
    boat.status = status;
    boat.out_of_control = if (status == .under_water or status == .under_flowing_water) boat.out_of_control + 1 else 0;
    if (boat.out_of_control >= out_of_control_limit) try around.eject(around.context);
    if (boat.hurt_time > 0) boat.hurt_time -= 1;
    if (boat.damage > 0) boat.damage -= 1;
    // A boat removed on the way finishes its tick as vanilla's does: the block effects pass it by.
    try baseTick(level, around, state, boat);
    // AbstractBoat.tick applies the block effects twice: the first takes the movements the moves
    // kept, and the second, finding none left, walks from where the tick began.
    if (steering.steered) {
        // Not the server's to move: its client's packets did.
        state.velocity = .{ 0, 0, 0 };
        try applyEffects(level, around, state, boat, scratch, steering.movements);
    } else {
        try floatBoat(level, around, state, boat);
        const kept = try move(level, around, state, boat, state.velocity);
        try applyEffects(level, around, state, boat, scratch, if (kept) |movement| &.{movement} else &.{});
    }
    try applyEffects(level, around, state, boat, scratch, &.{});
    if (tickBubbleColumn(state, boat)) try around.eject(around.context);
}

/// AbstractBoat.getStatus, which also sets the water level and land friction it found.
pub fn statusOf(level: *const body.Level, position: [3]f64, boat: *Boat) !Status {
    const box = boxAt(position);
    if (try underwater(level, box)) |status| {
        boat.water_level = box.max[1];
        return status;
    }
    if (try inWater(level, box, boat)) return .in_water;
    const friction = try groundFriction(level, box);
    if (friction > 0) {
        boat.land_friction = friction;
        return .on_land;
    }
    return .in_air;
}

/// AbstractBoat.isUnderwater: water above the box's top, under flowing water as soon as any is.
fn underwater(level: *const body.Level, box: Box) !?Status {
    const top = box.max[1] + 0.001;
    const first: [3]i32 = .{ mth.floor(box.min[0]), mth.floor(box.max[1]), mth.floor(box.min[2]) };
    const last: [3]i32 = .{ mth.ceil(box.max[0]), mth.ceil(top), mth.ceil(box.max[2]) };
    var under = false;
    var x = first[0];
    while (x < last[0]) : (x += 1) {
        var y = first[1];
        while (y < last[1]) : (y += 1) {
            var z = first[2];
            while (z < last[2]) : (z += 1) {
                const physics = try level.fluid(x, y, z);
                if (physics.fluid != .water) continue;
                if (!(top < try fluids.top(level, x, y, z, physics))) continue;
                if (physics.amount == 8 and !physics.falling) {
                    under = true;
                } else return .under_flowing_water;
            }
        }
    }
    return if (under) .under_water else null;
}

/// AbstractBoat.checkInWater: water in the slice at the box's bottom, the level its top reaches.
fn inWater(level: *const body.Level, box: Box, boat: *Boat) !bool {
    const first: [3]i32 = .{ mth.floor(box.min[0]), mth.floor(box.min[1]), mth.floor(box.min[2]) };
    const last: [3]i32 = .{ mth.ceil(box.max[0]), mth.ceil(box.min[1] + 0.001), mth.ceil(box.max[2]) };
    var found = false;
    boat.water_level = -std.math.floatMax(f64);
    var x = first[0];
    while (x < last[0]) : (x += 1) {
        var y = first[1];
        while (y < last[1]) : (y += 1) {
            var z = first[2];
            while (z < last[2]) : (z += 1) {
                const physics = try level.fluid(x, y, z);
                if (physics.fluid != .water) continue;
                const surface = try fluids.top(level, x, y, z, physics);
                boat.water_level = @max(surface, boat.water_level);
                found = found or box.min[1] < surface;
            }
        }
    }
    return found;
}

/// AbstractBoat.getGroundFriction: the friction of the blocks whose collision shapes meet a sliver
/// under the box, averaged, the corners and the ring's top and bottom at its edges passed over,
/// and lily pads with them. NaN when none meets, which is no friction.
pub fn groundFriction(level: *const body.Level, box: Box) !f32 {
    const sliver: Box = .{ .min = .{ box.min[0], box.min[1] - 0.001, box.min[2] }, .max = .{ box.max[0], box.min[1], box.max[2] } };
    const first: [3]i32 = .{ mth.floor(sliver.min[0]) - 1, mth.floor(sliver.min[1]) - 1, mth.floor(sliver.min[2]) - 1 };
    const last: [3]i32 = .{ mth.ceil(sliver.max[0]) + 1, mth.ceil(sliver.max[1]) + 1, mth.ceil(sliver.max[2]) + 1 };
    var sum: f32 = 0;
    var count: i32 = 0;
    var x = first[0];
    while (x < last[0]) : (x += 1) {
        var z = first[2];
        while (z < last[2]) : (z += 1) {
            const edges = @as(u8, @intFromBool(x == first[0] or x == last[0] - 1)) + @intFromBool(z == first[2] or z == last[2] - 1);
            if (edges == 2) continue;
            var y = first[1];
            while (y < last[1]) : (y += 1) {
                if (edges > 0 and (y == first[1] or y == last[1] - 1)) continue;
                const state = try level.state(x, y, z);
                if (level.blocks.get(state).kind == .lily_pad) continue;
                const boxes = body.contextFreeBoxes(state, x, z);
                const origin: [3]f64 = .{ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) };
                const meets = for (0..boxes.count) |index| {
                    const value = boxes.get(index);
                    const shape: Box = .{ .min = .{ origin[0] + value[0], origin[1] + value[1], origin[2] + value[2] }, .max = .{ origin[0] + value[3], origin[1] + value[4], origin[2] + value[5] } };
                    if (shape.intersects(sliver)) break true;
                } else false;
                if (!meets) continue;
                sum += game_data.physics.get(state).friction;
                count += 1;
            }
        }
    }
    return sum / @as(f32, @floatFromInt(count));
}

/// AbstractBoat.getWaterLevelAbove: the height of the water over the box, from its top down
/// through what it fell since the last tick.
fn waterLevelAbove(level: *const body.Level, box: Box, last_yd: f64) !f32 {
    const first_x = mth.floor(box.min[0]);
    const last_x = mth.ceil(box.max[0]);
    const first_y = mth.floor(box.max[1]);
    const last_y = mth.ceil(box.max[1] - last_yd);
    const first_z = mth.floor(box.min[2]);
    const last_z = mth.ceil(box.max[2]);
    var y = first_y;
    rows: while (y < last_y) : (y += 1) {
        var highest: f32 = 0;
        var x = first_x;
        while (x < last_x) : (x += 1) {
            var z = first_z;
            while (z < last_z) : (z += 1) {
                const physics = try level.fluid(x, y, z);
                if (physics.fluid == .water) highest = @max(highest, @as(f32, @floatCast(try fluids.top(level, x, y, z, physics) - @as(f64, @floatFromInt(y)))));
                if (highest >= 1) continue :rows;
            }
        }
        if (highest < 1) return @as(f32, @floatFromInt(y)) + highest;
    }
    return @floatFromInt(last_y + 1);
}

/// Entity.baseTick as it reaches a boat on the server: fire, fluids and the world's floor.
fn baseTick(level: *const body.Level, around: Around, state: *entities.State, boat: *Boat) !void {
    boat.in_powder_snow = false;
    try updateFluids(level, around, state, boat);
    if (boat.fire_ticks > 0) {
        if (@mod(boat.fire_ticks, 20) == 0 and !boat.inLava()) _ = try around.hurt(around.context, 1.0);
        boat.fire_ticks -= 1;
    }
    if (boat.inLava()) boat.fall_distance *= 0.5;
    // Entity.checkBelowWorld.
    if (state.position[1] < @as(f64, @floatFromInt(level.minimum_y - 64))) boat.removed = true;
    boat.first_tick = false;
}

/// Entity.updateInWaterStateAndDoFluidPushing for a boat, which water and lava push.
fn updateFluids(level: *const body.Level, around: Around, state: *entities.State, boat: *Boat) !void {
    const box = boxAt(state.position);
    const water = try fluids.heightAndPush(level, box, &state.velocity, .water, 0.014);
    if (water.touching) {
        if (!boat.was_touching_water and !boat.first_tick) splash(around, state, boat);
        boat.fall_distance = 0;
        boat.was_touching_water = true;
    } else boat.was_touching_water = false;
    boat.lava_height = (try fluids.heightAndPush(level, box, &state.velocity, .lava, if (around.ultrawarm) 0.007 else 0.0023333333333333335)).height;
    // Entity.updateFluidOnEyes: water over its eyes, at the top of its box.
    const eye = state.position[1] + @as(f64, box_height);
    const at: [3]i32 = .{ mth.floor(state.position[0]), mth.floor(eye), mth.floor(state.position[2]) };
    const physics = try level.fluid(at[0], at[1], at[2]);
    boat.eye_in_water = physics.fluid == .water and try fluids.top(level, at[0], at[1], at[2], physics) > eye;
}

/// Entity.doWaterSplashEffect for a boat that is its own controller: the sound, and the draws its
/// particles take, which the server makes though it shows none.
fn splash(around: Around, state: *const entities.State, boat: *Boat) void {
    const velocity = state.velocity;
    const strength: f32 = @min(1.0, @as(f32, @floatCast(@sqrt(velocity[0] * velocity[0] * @as(f64, @as(f32, 0.2)) + velocity[1] * velocity[1] + velocity[2] * velocity[2] * @as(f64, @as(f32, 0.2))))) * 0.2);
    const pitch = 1.0 + (boat.random.nextFloat() - boat.random.nextFloat()) * 0.4;
    around.sound(around.context, .generic_splash, strength, pitch);
    const count = 1.0 + box_width * 20.0;
    var index: f32 = 0;
    while (index < count) : (index += 1) {
        _ = boat.random.nextDouble();
        _ = boat.random.nextDouble();
        _ = boat.random.nextDouble();
    }
    index = 0;
    while (index < count) : (index += 1) {
        _ = boat.random.nextDouble();
        _ = boat.random.nextDouble();
    }
}

/// AbstractBoat.floatBoat: gravity, buoyancy and friction by where the boat is, a boat landing on
/// water out of the air set at its surface.
fn floatBoat(level: *const body.Level, around: Around, state: *entities.State, boat: *Boat) !void {
    var fall: f64 = -gravity;
    var buoyancy: f64 = 0;
    var friction: f32 = 0.05;
    const status = boat.status.?;
    if (boat.old_status == .in_air and status != .in_air and status != .on_land) {
        // Entity.getY(1.0): the box's top.
        boat.water_level = state.position[1] + @as(f64, box_height);
        const settled = @as(f64, try waterLevelAbove(level, boxAt(state.position), boat.last_yd) - box_height) + 0.101;
        const box = boxAt(state.position);
        if (try body.noCollision(level, box.move(.{ 0, settled - state.position[1], 0 }), contextOf(around, state, boat))) {
            state.position[1] = settled;
            // Vec3.multiply(1, 0, 1), which keeps the sign of what it zeroes.
            state.velocity[1] *= 0;
            boat.last_yd = 0;
        }
        boat.status = .in_water;
        return;
    }
    switch (status) {
        .in_water => {
            buoyancy = (boat.water_level - state.position[1]) / @as(f64, box_height);
            friction = 0.9;
        },
        .under_flowing_water => {
            fall = -7.0e-4;
            friction = 0.9;
        },
        .under_water => {
            buoyancy = @as(f32, 0.01);
            friction = 0.45;
        },
        .in_air => friction = 0.9,
        // Halved where a player steers, which no boat here has.
        .on_land => friction = boat.land_friction,
    }
    state.velocity = .{ state.velocity[0] * friction, state.velocity[1] + fall, state.velocity[2] * friction };
    if (buoyancy > 0) state.velocity[1] = (state.velocity[1] + buoyancy * (gravity / 0.65)) * 0.75;
}

/// The boat as collisions take it: a vehicle, AbstractBoat.canCollideWith.
fn contextOf(around: Around, state: *const entities.State, boat: *const Boat) body.Context {
    return .{ .bottom = state.position[1], .fall_distance = boat.fall_distance, .slot = around.slot, .vehicle = true };
}

/// Entity.move for a boat moving itself, as one that never steps up: the movement it keeps for
/// the block effects, if it moved.
fn move(level: *const body.Level, around: Around, state: *entities.State, boat: *Boat, requested_in: [3]f64) !?block_effects.Movement {
    var kept: ?block_effects.Movement = null;
    var requested = requested_in;
    if (lengthSquared(boat.stuck) > 1.0e-7) {
        requested = .{ requested[0] * boat.stuck[0], requested[1] * boat.stuck[1], requested[2] * boat.stuck[2] };
        boat.stuck = .{ 0, 0, 0 };
        state.velocity = .{ 0, 0, 0 };
    }
    const start = boxAt(state.position);
    const moved = try body.collide(level, start, requested, contextOf(around, state, boat), boat.on_ground, 0);
    const moved_squared = lengthSquared(moved);
    if (moved_squared > 1.0e-7 or lengthSquared(requested) - moved_squared < 1.0e-7) {
        const destination: [3]f64 = .{ state.position[0] + moved[0], state.position[1] + moved[1], state.position[2] + moved[2] };
        if (boat.fall_distance != 0 and moved_squared >= 1.0) {
            if (try body.clipsFallReset(level, state.position, destination)) boat.fall_distance = 0;
        }
        kept = .{ .from = state.position, .to = destination, .axis_independent = true };
        state.position = destination;
    }
    const blocked_x = !mth.equal(requested[0], moved[0]);
    const blocked_z = !mth.equal(requested[2], moved[2]);
    // A boat on the server is its own authority, so the vertical flags always update.
    const vertical = requested[1] != moved[1];
    boat.on_ground = vertical and requested[1] < 0;
    try checkSupportingBlock(level, state, boat, moved);
    const on_position = try onPosition(level, state.position, boat, 0.2);
    const on_state = try level.state(on_position[0], on_position[1], on_position[2]);
    try checkFallDamage(level, state, boat, moved[1]);
    if (boat.removed) return kept;
    if (blocked_x) state.velocity[0] = 0;
    if (blocked_z) state.velocity[2] = 0;
    if (vertical) afterFallOn(level, state, on_state);
    // Boats emit only game events from their movement, which this server has none of.
    const factor = try blockSpeedFactor(level, state.position, boat);
    state.velocity[0] *= factor;
    state.velocity[2] *= factor;
    return kept;
}

/// Entity.move for a boat its rider's client moved, MoverType.PLAYER as handleMoveVehicle moves
/// it: what the move kept for the block effects, if it moved.
pub fn moveBy(level: *const body.Level, around: Around, state: *entities.State, boat: *Boat, movement: [3]f64) !?block_effects.Movement {
    return move(level, around, state, boat, movement);
}

/// Entity.setOnGroundWithMovement then doCheckFallDamage, each finding its support again, as
/// handleMoveVehicle takes what the rider's client said of the boat.
pub fn landBy(level: *const body.Level, state: *const entities.State, boat: *Boat, moved: [3]f64, on_ground: bool) !void {
    boat.on_ground = on_ground;
    try checkSupportingBlock(level, state, boat, moved);
    if (boat.removed) return;
    try checkSupportingBlock(level, state, boat, moved);
    try checkFallDamage(level, state, boat, moved[1]);
}

/// Entity.checkSupportingBlock, after a move that may have landed.
fn checkSupportingBlock(level: *const body.Level, state: *const entities.State, boat: *Boat, moved: [3]f64) !void {
    if (!boat.on_ground) {
        boat.on_ground_no_blocks = false;
        boat.supporting = null;
        return;
    }
    const current = boxAt(state.position);
    const below: Box = .{ .min = .{ current.min[0], current.min[1] - 1.0e-6, current.min[2] }, .max = .{ current.max[0], current.min[1], current.max[2] } };
    const context: body.Context = .{ .bottom = state.position[1], .fall_distance = boat.fall_distance };
    var found = try body.findSupportingBlock(level, below, context, state.position);
    if (found != null or boat.on_ground_no_blocks) {
        boat.supporting = found;
    } else {
        found = try body.findSupportingBlock(level, below.move(.{ -moved[0], 0, -moved[2] }), context, state.position);
        boat.supporting = found;
    }
    boat.on_ground_no_blocks = found == null;
}

/// Entity.getOnPos: the block the boat stands on, looked for this far below its bottom.
pub fn onPosition(level: *const body.Level, position: [3]f64, boat: *const Boat, depth: f32) ![3]i32 {
    if (boat.supporting) |supporting| {
        if (!(depth > 1.0e-5)) return supporting;
        const entry = level.blocks.get(try level.state(supporting[0], supporting[1], supporting[2]));
        const keeps = (depth <= 0.5 and entry.flags.fence) or entry.flags.wall or entry.flags.fence_gate;
        if (keeps) return supporting;
        return .{ supporting[0], mth.floor(position[1] - depth), supporting[2] };
    }
    return .{ mth.floor(position[0]), mth.floor(position[1] - depth), mth.floor(position[2]) };
}

/// AbstractBoat.checkFallDamage: it keeps how fast it fell, and how far it fell out of water.
fn checkFallDamage(level: *const body.Level, state: *const entities.State, boat: *Boat, moved_y: f64) !void {
    boat.last_yd = state.velocity[1];
    if (boat.on_ground) {
        boat.fall_distance = 0;
        return;
    }
    const at = blockPosition(state.position);
    if ((try level.fluid(at[0], at[1] - 1, at[2])).fluid != .water and moved_y < 0) boat.fall_distance -= @as(f64, @as(f32, @floatCast(moved_y)));
}

/// Block.updateEntityMovementAfterFallOn, after a move that stopped vertically: slime and beds
/// bounce what falls on them, less what is not living.
fn afterFallOn(level: *const body.Level, state: *entities.State, block: u16) void {
    const entry = level.blocks.get(block);
    if (entry.kind == .slime_block) {
        if (state.velocity[1] < 0) state.velocity[1] = -state.velocity[1] * 0.8;
        return;
    }
    if (entry.flags.bed) {
        if (state.velocity[1] < 0) state.velocity[1] = -state.velocity[1] * @as(f64, @as(f32, 0.66)) * 0.8;
        return;
    }
    // Vec3.multiply(1, 0, 1), which keeps the sign of what it zeroes.
    state.velocity[1] *= 0;
}

/// Entity.getBlockSpeedFactor: the block it is in, or the one under it, but in water.
fn blockSpeedFactor(level: *const body.Level, position: [3]f64, boat: *const Boat) !f32 {
    const at = blockPosition(position);
    const state = try level.state(at[0], at[1], at[2]);
    const factor = game_data.physics.get(state).speed;
    const kind = level.blocks.get(state).kind;
    if (kind == .water or kind == .bubble_column) return factor;
    if (factor != 1.0) return factor;
    const under = try onPosition(level, position, boat, 0.500001);
    return game_data.physics.get(try level.state(under[0], under[1], under[2])).speed;
}

/// Entity.applyEffectsFromBlocks over the movements recorded, or from where the tick began when none.
fn applyEffects(level: *const body.Level, around: Around, state: *entities.State, boat: *Boat, scratch: *Scratch, recorded: []const block_effects.Movement) !void {
    _ = try block_effects.apply(Host{ .level_view = level, .around = around, .held = boat, .room = scratch }, Subject.of(state, boat), recorded);
}

/// AbstractBoat.tickBubbleColumn on the server: a boat over a bubble column long enough is thrown
/// up out of it, or pulled down into it, and then its riders are thrown out.
fn tickBubbleColumn(state: *entities.State, boat: *Boat) bool {
    var pulled = false;
    if (!boat.above_bubble_column) boat.bubble_time = 0;
    var time = boat.bubble_time;
    if (time > 0) {
        time -= 1;
        boat.bubble_time = time;
        const elapsed = 60 - time - 1;
        if (elapsed > 0 and time == 0) {
            boat.bubble_time = 0;
            if (boat.bubble_column_down) {
                state.velocity[1] += -0.7;
                pulled = true;
            } else {
                // 2.7 under a passenger that is a player, which no boat here carries.
                state.velocity[1] = 0.6;
            }
        }
        boat.above_bubble_column = false;
    }
    return pulled;
}

/// AbstractBoat.onAboveBubbleColumn on the server.
fn aboveBubbleColumn(boat: *Boat, drag: bool) void {
    boat.above_bubble_column = true;
    boat.bubble_column_down = drag;
    if (boat.bubble_time == 0) boat.bubble_time = 60;
    if (boat.underWater()) return;
    if (boat.random.nextIntBounded(100) != 0) return;
    // The splash sound, played on clients alone, and its particle, whose draws the server makes.
    _ = boat.random.nextFloat();
    _ = boat.random.nextFloat();
    _ = boat.random.nextFloat();
}

/// BlockPos.containing.
pub fn blockPosition(position: [3]f64) [3]i32 {
    return .{ mth.floor(position[0]), mth.floor(position[1]), mth.floor(position[2]) };
}

fn lengthSquared(vector: [3]f64) f64 {
    return vector[0] * vector[0] + vector[1] * vector[1] + vector[2] * vector[2];
}

/// What the shared block effects read and change of a boat.
const Subject = struct {
    world: *u32,
    position: *[3]f64,
    old_position: *[3]f64,
    velocity: *[3]f64,
    on_ground: *bool,
    fall_distance: *f64,
    stuck: *[3]f64,
    removed: *bool,
    fire_ticks: *i32,
    ticks_frozen: *i32,
    in_powder_snow: *bool,

    fn of(state: *entities.State, boat: *Boat) Subject {
        return .{
            .world = &state.world,
            .position = &state.position,
            .old_position = &boat.old_position,
            .velocity = &state.velocity,
            .on_ground = &boat.on_ground,
            .fall_distance = &boat.fall_distance,
            .stuck = &boat.stuck,
            .removed = &boat.removed,
            .fire_ticks = &boat.fire_ticks,
            .ticks_frozen = &boat.ticks_frozen,
            .in_powder_snow = &boat.in_powder_snow,
        };
    }
};

/// The boat as the host of the shared block effects: not living, and not immune to fire.
const Host = struct {
    pub const living = false;
    pub const boat = true;
    level_view: *const body.Level,
    around: Around,
    held: *Boat,
    room: *Scratch,

    pub fn level(self: Host, _: u32) body.Level {
        return self.level_view.*;
    }
    pub fn scratch(self: Host) *block_effects.Scratch {
        return &self.room.effects;
    }
    pub fn width(_: Host, _: Subject) f32 {
        return box_width;
    }
    pub fn height(_: Host, _: Subject) f32 {
        return box_height;
    }
    pub fn alive(self: Host, _: Subject) bool {
        return !self.held.removed;
    }
    pub fn fireImmune(_: Host, _: Subject) error{}!bool {
        return false;
    }
    pub fn onPosition(self: Host, subject: Subject, depth: f32) ![3]i32 {
        return onPositionOf(self.level_view, subject.position.*, self.held, depth);
    }
    pub fn hurt(self: Host, _: Subject, _: block_effects.Damage, amount: f32) !bool {
        return self.around.hurt(self.around.context, amount);
    }
    pub fn playSound(self: Host, _: Subject, sound: block_effects.Sound, volume: f32, pitch: f32) void {
        const kind: Sound = switch (sound) {
            inline else => |tag| @field(Sound, @tagName(tag)),
        };
        self.around.sound(self.around.context, kind, volume, pitch);
    }
    pub fn random(self: Host, _: Subject) *JavaRandom {
        return &self.held.random;
    }
    pub fn levelRandom(self: Host) *JavaRandom {
        return self.around.level_random;
    }
    pub fn mobGriefing(self: Host) bool {
        return self.around.mob_griefing;
    }
    pub fn destroyBlock(self: Host, world: u32, position: [3]i32) !void {
        return self.around.destroy_block(self.around.context, world, position);
    }
    pub fn lowerCauldron(self: Host, world: u32, position: [3]i32) !void {
        return self.around.lower_cauldron(self.around.context, world, position);
    }
    pub fn breakBlock(self: Host, world: u32, position: [3]i32) !void {
        return self.around.break_block(self.around.context, world, position);
    }
    /// Turtle eggs crack under the living alone.
    pub fn crackTurtleEgg(_: Host, _: u32, _: [3]i32, _: u16) !void {
        unreachable;
    }
    /// Honey slide effects are for the living alone.
    pub fn entityEvent(_: Host, _: Subject, _: u8) void {
        unreachable;
    }
    pub fn onAboveBubbleColumn(self: Host, _: Subject, drag: bool, _: [3]i32) !void {
        aboveBubbleColumn(self.held, drag);
    }
};

const onPositionOf = onPosition;
