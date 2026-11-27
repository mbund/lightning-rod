//! How fluids push the bodies in them, as vanilla's Entity has it: the depth of a fluid in a box,
//! the current there, and the push it gives, for any body that reads the world as a level.

const std = @import("std");
const game_data = @import("game_data");
const mth = @import("mth.zig");
const body = @import("body.zig");
const mob_blocks = @import("mob_blocks.zig");

const Fluid = game_data.physics_data.Fluid;
const assert = std.debug.assert;
const verify_skips = @import("builtin").mode == .debug;

/// Whether a box touched the fluid, and how deep it is in it from the box's bottom.
pub const Depth = struct { touching: bool, height: f64 };

/// Entity.updateFluidHeightAndDoFluidPushing for a body whose box is `box`: how deep the fluid
/// is in it, and the push of the fluid's current added to `velocity` at `strength`.
pub fn heightAndPush(level: *const body.Level, box: body.Box, velocity: *[3]f64, fluid: Fluid, strength: f64) !Depth {
    const current = box.inflate(-0.001, -0.001, -0.001);
    const first: [3]i32 = .{ mth.floor(current.min[0]), mth.floor(current.min[1]), mth.floor(current.min[2]) };
    const last: [3]i32 = .{ mth.ceil(current.max[0]), mth.ceil(current.max[1]), mth.ceil(current.max[2]) };
    // No fluid around the body ticking means nothing to find, which Debug still looks for.
    const dry = try level.without(mob_blocks.mark_fluid, first, .{ last[0] - 1, last[1] - 1, last[2] - 1 });
    if (dry and !verify_skips) return .{ .touching = false, .height = 0 };
    var deepest: f64 = 0;
    var touching = false;
    var push: [3]f64 = .{ 0, 0, 0 };
    var pushes: u32 = 0;
    var x = first[0];
    while (x < last[0]) : (x += 1) {
        var y = first[1];
        while (y < last[1]) : (y += 1) {
            var z = first[2];
            while (z < last[2]) : (z += 1) {
                const physics = try level.fluid(x, y, z);
                if (physics.fluid != fluid) continue;
                const height = try top(level, x, y, z, physics);
                if (height < current.min[1]) continue;
                touching = true;
                deepest = @max(height - current.min[1], deepest);
                // Every body these are asked for is pushed by fluids.
                var flowing = try flow(level, x, y, z, physics);
                if (deepest < 0.4) flowing = .{ flowing[0] * deepest, flowing[1] * deepest, flowing[2] * deepest };
                push = .{ push[0] + flowing[0], push[1] + flowing[1], push[2] + flowing[2] };
                pushes += 1;
            }
        }
    }
    if (dry) assert(!touching and pushes == 0);
    if (@sqrt(lengthSquared(push)) > 0) {
        if (pushes > 0) {
            const scale = 1.0 / @as(f64, @floatFromInt(pushes));
            push = .{ push[0] * scale, push[1] * scale, push[2] * scale };
        }
        push = mth.normalize(push);
        push = .{ push[0] * strength, push[1] * strength, push[2] * strength };
        if (@abs(velocity[0]) < 0.003 and @abs(velocity[2]) < 0.003 and @sqrt(lengthSquared(push)) < 0.0045000000000000005) {
            push = mth.normalize(push);
            push = .{ push[0] * 0.0045000000000000005, push[1] * 0.0045000000000000005, push[2] * 0.0045000000000000005 };
        }
        velocity.* = .{ velocity[0] + push[0], velocity[1] + push[1], velocity[2] + push[2] };
    }
    return .{ .touching = touching, .height = deepest };
}

/// The top of a fluid block: its y and FluidState.getHeight, a full block under the same fluid
/// and its own height otherwise, added as floats as vanilla does.
pub fn top(level: *const body.Level, x: i32, y: i32, z: i32, physics: game_data.physics_data.State) !f64 {
    const above = try level.fluid(x, y + 1, z);
    const own: f32 = if (above.fluid == physics.fluid) 1.0 else physics.height();
    return @as(f32, @floatFromInt(y)) + own;
}

/// FlowingFluid.getFlow.
pub fn flow(level: *const body.Level, x: i32, y: i32, z: i32, physics: game_data.physics_data.State) ![3]f64 {
    // Direction.Plane.HORIZONTAL: north, east, south, west, with their sturdy face bits.
    const directions = [_]struct { dx: i32, dz: i32, face: u3 }{
        .{ .dx = 0, .dz = -1, .face = 2 },
        .{ .dx = 1, .dz = 0, .face = 1 },
        .{ .dx = 0, .dz = 1, .face = 3 },
        .{ .dx = -1, .dz = 0, .face = 0 },
    };
    var flow_x: f64 = 0;
    var flow_z: f64 = 0;
    for (directions) |direction| {
        const other = try level.fluid(x + direction.dx, y, z + direction.dz);
        if (other.fluid != physics.fluid and other.fluid != .none) continue;
        var own = other.height();
        var difference: f32 = 0;
        if (own == 0) {
            if (!other.blocks_motion) {
                const below = try level.fluid(x + direction.dx, y - 1, z + direction.dz);
                if (below.fluid == physics.fluid or below.fluid == .none) {
                    own = below.height();
                    if (own > 0) difference = physics.height() - (own - 0.8888889);
                }
            }
        } else if (own > 0) {
            difference = physics.height() - own;
        }
        if (difference != 0) {
            flow_x += @as(f64, @floatFromInt(direction.dx)) * difference;
            flow_z += @as(f64, @floatFromInt(direction.dz)) * difference;
        }
    }
    var flowing: [3]f64 = .{ flow_x, 0, flow_z };
    if (physics.falling) {
        for (directions) |direction| {
            const mask = @as(u8, 1) << direction.face;
            const side = try level.fluid(x + direction.dx, y, z + direction.dz);
            const above = try level.fluid(x + direction.dx, y + 1, z + direction.dz);
            const solid = (side.fluid != physics.fluid and !side.ice and side.sturdy & mask != 0) or (above.fluid != physics.fluid and !above.ice and above.sturdy & mask != 0);
            if (solid) {
                flowing = mth.normalize(flowing);
                flowing[1] -= 6.0;
                break;
            }
        }
    }
    return mth.normalize(flowing);
}

fn lengthSquared(vector: [3]f64) f64 {
    return vector[0] * vector[0] + vector[1] * vector[1] + vector[2] * vector[2];
}
