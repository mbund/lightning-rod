const std = @import("std");
const registry = @import("registry_data");
const game_data = @import("../game_data.zig");
const limits = @import("limits.zig");
const collision = @import("../collision.zig");
const navigation = @import("../navigation.zig");
const diagnostics = @import("../diagnostics.zig");
const block_store = @import("blocks.zig");
const geometry = @import("geometry.zig");
const world_identity = @import("identity.zig");
const test_generator = @import("../test_support/world_generator.zig");

fn blockCoordBelow(value: f64) i32 {
    return geometry.blockCoord(@ceil(value) - 1);
}

fn initialRayBoundary(coordinate: f64, block: i32, step: i32, delta: f64) f64 {
    if (step == 0) return std.math.inf(f64);
    const boundary: f64 = @floatFromInt(block + @intFromBool(step > 0));
    return (boundary - coordinate) / delta;
}

pub const BlockStates = struct {
    context: *anyopaque,
    at_fn: *const fn (*anyopaque, world_identity.Handle, geometry.BlockPos) ?i32,

    pub fn at(self: BlockStates, world: world_identity.Handle, pos: geometry.BlockPos) ?i32 {
        return self.at_fn(self.context, world, pos);
    }

    pub fn resident(blocks: *block_store.Blocks) BlockStates {
        return .{ .context = blocks, .at_fn = residentBlockState };
    }

    fn residentBlockState(context: *anyopaque, world: world_identity.Handle, pos: geometry.BlockPos) ?i32 {
        const blocks: *block_store.Blocks = @ptrCast(@alignCast(context));
        return blocks.blockAtIfMaterialized(world, pos);
    }
};

pub fn isOpenTrapdoor(block_state: i32) bool {
    if (block_state < 0 or block_state > registry.maximum_block_state) return false;
    const state: usize = @intCast(block_state);
    return registry.open_trapdoor_state_bits[state >> 6] & (@as(u64, 1) << @intCast(state & 63)) != 0;
}

pub fn adjustLivingMovement(blocks: *block_store.Blocks, world: world_identity.Handle, box: collision.Box, requested: collision.Movement) collision.Movement {
    return adjustLivingMovementFrom(BlockStates.resident(blocks), world, box, requested);
}

pub fn adjustLivingMovementFrom(source: BlockStates, world: world_identity.Handle, box: collision.Box, requested: collision.Movement) collision.Movement {
    if (requested.x == 0 and requested.y == 0 and requested.z == 0) return requested;
    const swept = box.stretch(requested);
    var adjusted: collision.Movement = .{};
    adjusted.y = clipLivingAxis(source, world, .y, box, swept, requested.y);
    if (@abs(requested.x) < @abs(requested.z)) {
        adjusted.z = clipLivingAxis(source, world, .z, box.offset(adjusted), swept, requested.z);
        adjusted.x = clipLivingAxis(source, world, .x, box.offset(adjusted), swept, requested.x);
    } else {
        adjusted.x = clipLivingAxis(source, world, .x, box.offset(adjusted), swept, requested.x);
        adjusted.z = clipLivingAxis(source, world, .z, box.offset(adjusted), swept, requested.z);
    }
    return adjusted;
}

pub fn livingBoxCollides(blocks: *block_store.Blocks, world: world_identity.Handle, box: collision.Box) bool {
    return livingBoxCollidesFrom(BlockStates.resident(blocks), world, box);
}

pub fn livingBoxCollidesFrom(source: BlockStates, world: world_identity.Handle, box: collision.Box) bool {
    const min_x = geometry.blockCoord(box.min_x);
    const max_x = blockCoordBelow(box.max_x);
    const min_y = @max(geometry.blockCoord(box.min_y), @as(i32, limits.min_y));
    const max_y = @min(blockCoordBelow(box.max_y), @as(i32, block_store.world_top_y));
    const min_z = geometry.blockCoord(box.min_z);
    const max_z = blockCoordBelow(box.max_z);
    if (min_y > max_y) return false;

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var z = min_z;
        while (z <= max_z) : (z += 1) {
            var x = min_x;
            while (x <= max_x) : (x += 1) {
                const block_state = source.at(world, .{ .x = x, .y = @intCast(y), .z = z }) orelse return true;
                for (collision.shapeBoxes(block_state)) |local_box| {
                    if (box.intersects(collision.worldBox(local_box, x, y, z))) return true;
                }
            }
        }
    }
    return false;
}

pub fn playerGroundSupported(blocks: *block_store.Blocks, world: world_identity.Handle, position: geometry.Vec3) bool {
    return playerGroundSupportedFrom(BlockStates.resident(blocks), world, position);
}

pub fn playerGroundSupportedFrom(source: BlockStates, world: world_identity.Handle, position: geometry.Vec3) bool {
    const box = collision.entityBox(position.x, position.y + 0.001, position.z, 0.6, 1.8);
    return adjustLivingMovementFrom(source, world, box, .{ .y = -0.05 }).y > -0.05;
}

pub fn itemGroundYFrom(source: BlockStates, world: world_identity.Handle, position: geometry.Vec3) ?f64 {
    const x = geometry.blockCoord(position.x);
    const z = geometry.blockCoord(position.z);
    var y = @min(geometry.blockCoord(position.y - 0.01), @as(i32, block_store.world_top_y));
    while (y >= limits.min_y) : (y -= 1) {
        const state = source.at(world, .{ .x = x, .y = @intCast(y), .z = z }) orelse return null;
        var top: u8 = 0;
        const local_x = (position.x - @as(f64, @floatFromInt(x))) * collision.coordinate_scale;
        const local_z = (position.z - @as(f64, @floatFromInt(z))) * collision.coordinate_scale;
        for (collision.shapeBoxes(state)) |box| {
            if (local_x >= @as(f64, @floatFromInt(box.min_x)) and local_x <= @as(f64, @floatFromInt(box.max_x)) and
                local_z >= @as(f64, @floatFromInt(box.min_z)) and local_z <= @as(f64, @floatFromInt(box.max_z)))
                top = @max(top, box.max_y);
        }
        if (top != 0) return @as(f64, @floatFromInt(y)) + @as(f64, @floatFromInt(top)) / collision.coordinate_scale;
    }
    return null;
}

pub fn hasLineOfSight(blocks: *block_store.Blocks, world: world_identity.Handle, start: geometry.Vec3, end: geometry.Vec3) bool {
    return hasLineOfSightFrom(BlockStates.resident(blocks), world, start, end);
}

pub fn hasLineOfSightFrom(source: BlockStates, world: world_identity.Handle, start: geometry.Vec3, end: geometry.Vec3) bool {
    const ray_start = collision.Movement{ .x = start.x, .y = start.y, .z = start.z };
    const ray_end = collision.Movement{ .x = end.x, .y = end.y, .z = end.z };
    const delta_x = end.x - start.x;
    const delta_y = end.y - start.y;
    const delta_z = end.z - start.z;
    var x = geometry.blockCoord(start.x);
    var y = geometry.blockCoord(start.y);
    var z = geometry.blockCoord(start.z);
    const end_x = geometry.blockCoord(end.x);
    const end_y = geometry.blockCoord(end.y);
    const end_z = geometry.blockCoord(end.z);
    const step_x: i32 = if (delta_x > 0) 1 else if (delta_x < 0) -1 else 0;
    const step_y: i32 = if (delta_y > 0) 1 else if (delta_y < 0) -1 else 0;
    const step_z: i32 = if (delta_z > 0) 1 else if (delta_z < 0) -1 else 0;

    var traversed: usize = 0;
    while (traversed < 256) : (traversed += 1) {
        if (y >= limits.min_y and y <= block_store.world_top_y) {
            const block_state = source.at(world, .{ .x = x, .y = @intCast(y), .z = z }) orelse return false;
            for (collision.shapeBoxes(block_state)) |local_box| {
                if (collision.segmentIntersectsBox(ray_start, ray_end, collision.worldBox(local_box, x, y, z))) return false;
            }
        }
        if (x == end_x and y == end_y and z == end_z) return true;
        const boundary_x: f64 = @floatFromInt(x + @intFromBool(step_x > 0));
        const boundary_y: f64 = @floatFromInt(y + @intFromBool(step_y > 0));
        const boundary_z: f64 = @floatFromInt(z + @intFromBool(step_z > 0));
        const next_x = if (step_x == 0) std.math.inf(f64) else (boundary_x - start.x) / delta_x;
        const next_y = if (step_y == 0) std.math.inf(f64) else (boundary_y - start.y) / delta_y;
        const next_z = if (step_z == 0) std.math.inf(f64) else (boundary_z - start.z) / delta_z;
        if (next_x <= next_y and next_x <= next_z) {
            x += step_x;
        } else if (next_y <= next_z) {
            y += step_y;
        } else {
            z += step_z;
        }
    }
    return false;
}

pub fn hasVisualLineOfSight(
    blocks: *const block_store.Blocks,
    world: world_identity.Handle,
    start: geometry.Vec3,
    end: geometry.Vec3,
) bool {
    const delta_x = end.x - start.x;
    const delta_y = end.y - start.y;
    const delta_z = end.z - start.z;
    var x = geometry.blockCoord(start.x);
    var y = geometry.blockCoord(start.y);
    var z = geometry.blockCoord(start.z);
    const end_x = geometry.blockCoord(end.x);
    const end_y = geometry.blockCoord(end.y);
    const end_z = geometry.blockCoord(end.z);
    if (!blocks.blockRectangleMaterialized(
        world,
        @min(x, end_x),
        @max(x, end_x),
        @min(z, end_z),
        @max(z, end_z),
    )) return false;

    const step_x: i32 = if (delta_x > 0) 1 else if (delta_x < 0) -1 else 0;
    const step_y: i32 = if (delta_y > 0) 1 else if (delta_y < 0) -1 else 0;
    const step_z: i32 = if (delta_z > 0) 1 else if (delta_z < 0) -1 else 0;
    const t_delta_x =
        if (step_x == 0) std.math.inf(f64) else @abs(1.0 / delta_x);
    const t_delta_y =
        if (step_y == 0) std.math.inf(f64) else @abs(1.0 / delta_y);
    const t_delta_z =
        if (step_z == 0) std.math.inf(f64) else @abs(1.0 / delta_z);
    var t_max_x = initialRayBoundary(start.x, x, step_x, delta_x);
    var t_max_y = initialRayBoundary(start.y, y, step_y, delta_y);
    var t_max_z = initialRayBoundary(start.z, z, step_z, delta_z);
    var materialized_chunk = geometry.chunkForBlock(.{ .x = x, .y = 0, .z = z });
    var resident = blocks.materializedChunk(world, materialized_chunk).?;

    var traversed: usize = 0;
    while (traversed < 512) : (traversed += 1) {
        if (y >= limits.min_y and y <= block_store.world_top_y) {
            const current_chunk =
                geometry.chunkForBlock(.{ .x = x, .y = 0, .z = z });
            if (!geometry.sameChunk(current_chunk, materialized_chunk)) {
                materialized_chunk = current_chunk;
                resident = blocks.materializedChunk(world, current_chunk) orelse return false;
            }
            const block_state = blocks.blockAtMaterialized(
                resident,
                .{ .x = x, .y = @intCast(y), .z = z },
            );
            if (!game_data.blockInfo(block_state).visually_transparent)
                return false;
        }
        if (x == end_x and y == end_y and z == end_z) return true;

        if (t_max_x <= t_max_y and t_max_x <= t_max_z) {
            x += step_x;
            t_max_x += t_delta_x;
        } else if (t_max_y <= t_max_z) {
            y += step_y;
            t_max_y += t_delta_y;
        } else {
            z += step_z;
            t_max_z += t_delta_z;
        }
    }
    return false;
}

pub fn pathNode(blocks: *block_store.Blocks, world: world_identity.Handle, x: i32, y: i16, z: i32, baby: bool) navigation.Candidate {
    if (y <= limits.min_y or y > block_store.world_top_y) return .{ .node = .{ .x = x, .y = y, .z = z, .node_type = .blocked, .penalty = -1 }, .passable = false };
    const resident = blocks.materializedChunk(world, .{ .x = @divFloor(x, 16), .z = @divFloor(z, 16) }) orelse
        return .{ .node = .{ .x = x, .y = y, .z = z, .node_type = .blocked, .penalty = -1 }, .passable = false };
    return pathNodeInResident(blocks, resident, x, y, z, baby);
}

pub fn pathNodeInResident(blocks: *const block_store.Blocks, resident: *const block_store.MaterializedChunk, x: i32, y: i16, z: i32, baby: bool) navigation.Candidate {
    return pathNodeForDimensionsInResident(
        blocks,
        resident,
        x,
        y,
        z,
        if (baby) 0.3 else 0.6,
        if (baby) 0.975 else 1.95,
    );
}

pub fn pathNodeForDimensionsInResident(
    blocks: *const block_store.Blocks,
    resident: *const block_store.MaterializedChunk,
    x: i32,
    y: i16,
    z: i32,
    width: f32,
    height: f32,
) navigation.Candidate {
    if (y <= limits.min_y or y > block_store.world_top_y) return .{ .node = .{ .x = x, .y = y, .z = z, .node_type = .blocked, .penalty = -1 }, .passable = false };
    std.debug.assert(geometry.sameChunk(resident.chunk, .{ .x = @divFloor(x, 16), .z = @divFloor(z, 16) }));
    const below_y: i32 = @as(i32, y) - 1;
    const below_state = blocks.blockAtMaterialized(resident, .{ .x = x, .y = @intCast(below_y), .z = z });
    var support_height: f64 = if (isOpenTrapdoor(below_state)) 1 else 0;
    if (support_height == 0) for (collision.shapeBoxes(below_state)) |local_box| {
        support_height = @max(support_height, @as(f64, @floatFromInt(local_box.max_y)) / collision.coordinate_scale);
    };
    if (support_height == 0) return .{ .node = .{ .x = x, .y = y, .z = z, .node_type = .open }, .passable = false };

    const feet_y = @as(f64, @floatFromInt(below_y)) + support_height;
    const body = collision.entityBox(
        @as(f64, @floatFromInt(x)) + 0.5,
        feet_y + 0.001,
        @as(f64, @floatFromInt(z)) + 0.5,
        width,
        height - 0.002,
    );
    const min_y = @max(geometry.blockCoord(body.min_y), @as(i32, limits.min_y));
    const max_y = @min(blockCoordBelow(body.max_y), @as(i32, block_store.world_top_y));
    var body_y = min_y;
    while (body_y <= max_y) : (body_y += 1) {
        const block_state = blocks.blockAtMaterialized(resident, .{ .x = x, .y = @intCast(body_y), .z = z });
        for (collision.shapeBoxes(block_state)) |local_box| {
            if (body.intersects(collision.worldBox(local_box, x, body_y, z)))
                return .{ .node = .{ .x = x, .y = y, .z = z, .node_type = .blocked, .penalty = -1 }, .passable = false };
        }
    }
    return .{ .node = .{ .x = x, .y = y, .z = z, .node_type = .walkable }, .passable = true };
}

pub fn pathNodeForDimensionsFrom(
    source: BlockStates,
    world: world_identity.Handle,
    x: i32,
    y: i16,
    z: i32,
    width: f32,
    height: f32,
) navigation.Candidate {
    if (y <= limits.min_y or y > block_store.world_top_y) return .{ .node = .{ .x = x, .y = y, .z = z, .node_type = .blocked, .penalty = -1 }, .passable = false };
    const below_y: i32 = @as(i32, y) - 1;
    const below_state = source.at(world, .{ .x = x, .y = @intCast(below_y), .z = z }) orelse
        return .{ .node = .{ .x = x, .y = y, .z = z, .node_type = .blocked, .penalty = -1 }, .passable = false };
    var support_height: f64 = if (isOpenTrapdoor(below_state)) 1 else 0;
    if (support_height == 0) for (collision.shapeBoxes(below_state)) |local_box| {
        support_height = @max(support_height, @as(f64, @floatFromInt(local_box.max_y)) / collision.coordinate_scale);
    };
    if (support_height == 0) return .{ .node = .{ .x = x, .y = y, .z = z, .node_type = .open }, .passable = false };

    const feet_y = @as(f64, @floatFromInt(below_y)) + support_height;
    const body = collision.entityBox(@as(f64, @floatFromInt(x)) + 0.5, feet_y + 0.001, @as(f64, @floatFromInt(z)) + 0.5, width, height - 0.002);
    const min_y = @max(geometry.blockCoord(body.min_y), @as(i32, limits.min_y));
    const max_y = @min(blockCoordBelow(body.max_y), @as(i32, block_store.world_top_y));
    var body_y = min_y;
    while (body_y <= max_y) : (body_y += 1) {
        const block_state = source.at(world, .{ .x = x, .y = @intCast(body_y), .z = z }) orelse
            return .{ .node = .{ .x = x, .y = y, .z = z, .node_type = .blocked, .penalty = -1 }, .passable = false };
        for (collision.shapeBoxes(block_state)) |local_box| if (body.intersects(collision.worldBox(local_box, x, body_y, z)))
            return .{ .node = .{ .x = x, .y = y, .z = z, .node_type = .blocked, .penalty = -1 }, .passable = false };
    }
    return .{ .node = .{ .x = x, .y = y, .z = z, .node_type = .walkable }, .passable = true };
}

fn clipLivingAxis(source: BlockStates, world: world_identity.Handle, axis: collision.Axis, moving: collision.Box, swept: collision.Box, requested: f64) f64 {
    if (requested == 0) return 0;
    var result = requested;
    const min_x = geometry.blockCoord(swept.min_x);
    const max_x = blockCoordBelow(swept.max_x);
    const min_y = @max(geometry.blockCoord(swept.min_y), @as(i32, limits.min_y));
    const max_y = @min(blockCoordBelow(swept.max_y), @as(i32, block_store.world_top_y));
    const min_z = geometry.blockCoord(swept.min_z);
    const max_z = blockCoordBelow(swept.max_z);
    if (min_y > max_y) return result;

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var z = min_z;
        while (z <= max_z) : (z += 1) {
            var x = min_x;
            while (x <= max_x) : (x += 1) {
                const block_state = source.at(world, .{ .x = x, .y = @intCast(y), .z = z }) orelse return 0;
                for (collision.shapeBoxes(block_state)) |local_box| {
                    result = collision.clipAxis(axis, moving, collision.worldBox(local_box, x, y, z), result);
                    if (result == 0) return 0;
                }
            }
        }
    }
    return result;
}
