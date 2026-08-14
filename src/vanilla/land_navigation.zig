const lightning_rod = @import("lightning_rod");
const entity_store = lightning_rod.entities;
const living_entities = lightning_rod.living_entities;
const block_store = lightning_rod.blocks;
const block_queries = lightning_rod.block_queries;
const geometry = lightning_rod.geometry;
const std = @import("std");
const config = lightning_rod.config.value;
const navigation = lightning_rod.navigation;
const vanilla_math = @import("math.zig");
const world_identity = lightning_rod.world_identity;

const LandPathContext = struct {
    world: world_identity.Handle,
    blocks: *block_store.Blocks,
    search: *navigation.Search,
    width: f32,
    height: f32,

    pub fn pathSuccessors(self: *@This(), current: navigation.Node, out: *[8]navigation.Candidate) usize {
        const cardinal_offsets = [_][2]i32{ .{ 0, 1 }, .{ -1, 0 }, .{ 0, -1 }, .{ 1, 0 } };
        var cardinal: [4]navigation.Candidate = undefined;
        for (cardinal_offsets, 0..) |offset, index| {
            cardinal[index] = self.successor(current, offset[0], offset[1]);
            out[index] = cardinal[index];
        }

        const diagonal_offsets = [_][2]i32{ .{ -1, 1 }, .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 } };
        const adjacent = [_][2]usize{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 } };
        for (diagonal_offsets, adjacent, 0..) |offset, sides, index| {
            var candidate = self.successor(current, offset[0], offset[1]);
            candidate.passable = candidate.passable and cardinal[sides[0]].passable and cardinal[sides[1]].passable and
                cardinal[sides[0]].node.y <= current.y and cardinal[sides[1]].node.y <= current.y;
            out[4 + index] = candidate;
        }
        return out.len;
    }

    fn successor(self: *@This(), current: navigation.Node, dx: i32, dz: i32) navigation.Candidate {
        const x = current.x + dx;
        const z = current.z + dz;
        var candidate = self.search.classifyCached(self, .{ .x = x, .y = current.y, .z = z });
        if (candidate.passable) return candidate;

        if (candidate.node.node_type == .blocked) {
            const above = self.search.classifyCached(self, .{ .x = x, .y = current.y +| 1, .z = z });
            if (above.passable) return above;
            return candidate;
        }

        var fall_y = current.y;
        var fall_distance: u8 = 0;
        while (fall_distance < 3 and fall_y > config.world_min_y) {
            fall_y -= 1;
            fall_distance += 1;
            candidate = self.search.classifyCached(self, .{ .x = x, .y = fall_y, .z = z });
            if (candidate.passable or candidate.node.node_type == .blocked) return candidate;
        }
        return candidate;
    }

    pub fn classifyPathNode(self: *@This(), node: navigation.Node) navigation.Candidate {
        const resident = self.blocks.residentChunk(self.world, .{ .x = @divFloor(node.x, 16), .z = @divFloor(node.z, 16) }) orelse
            return blockedCandidate(node);
        return block_queries.pathNodeForDimensionsInResident(self.blocks, resident, node.x, node.y, node.z, self.width, self.height);
    }
};

fn blockedCandidate(node: navigation.Node) navigation.Candidate {
    return .{
        .node = .{
            .x = node.x,
            .y = node.y,
            .z = node.z,
            .node_type = .blocked,
            .penalty = -1,
        },
        .passable = false,
    };
}

pub fn stop(living: *entity_store.LivingEntities, entity: usize) void {
    living.paths.clear(entity);
}

pub fn isIdle(living: *const entity_store.LivingEntities, entity: usize) bool {
    return living.paths.isIdle(entity);
}

pub fn start(
    blocks: *block_store.Blocks,
    living: *entity_store.LivingEntities,
    entity: usize,
    target: geometry.BlockPos,
    target_distance: i32,
    speed: f64,
) bool {
    const entity_type = living.entities.entity_types[entity];
    const baby = living.entities.baby[entity];
    const start_node = navigation.Node{
        .x = geometry.blockCoord(living.entities.position_x[entity]),
        .y = @intFromFloat(@floor(living.entities.position_y[entity] + 0.5)),
        .z = geometry.blockCoord(living.entities.position_z[entity]),
    };
    const target_node = navigation.Node{ .x = target.x, .y = target.y, .z = target.z };
    var context = LandPathContext{
        .world = living.entities.worlds[entity],
        .blocks = blocks,
        .search = &living.search,
        .width = living_entities.width(entity_type, baby),
        .height = living_entities.height(entity_type, baby),
    };
    const found = living.search.findPath(&context, &living.paths, entity, start_node, target_node, target_distance, 32, config.max_path_search_nodes);
    if (found) living.paths.speed[entity] = speed;
    return found;
}

pub fn tick(living: *entity_store.LivingEntities, entity: usize) bool {
    if (living.paths.isIdle(entity)) return false;
    const pool = &living.entities;
    const node = living.paths.currentNode(entity) orelse return false;
    const target_x = @as(f64, @floatFromInt(node.x)) + 0.5;
    const target_z = @as(f64, @floatFromInt(node.z)) + 0.5;
    const dx = target_x - pool.position_x[entity];
    const dz = target_z - pool.position_z[entity];
    const width = living_entities.width(pool.entity_types[entity], pool.baby[entity]);
    const reach: f64 = if (width > 0.75) @as(f64, width) / 2.0 else 0.75 - @as(f64, width) / 2.0;
    if (@abs(dx) < reach and @abs(dz) < reach and @abs(pool.position_y[entity] - @as(f64, @floatFromInt(node.y))) < 1) {
        living.paths.current[entity] += 1;
        if (living.paths.isIdle(entity)) return false;
    }

    const move_node = living.paths.currentNode(entity) orelse return false;
    const move_dx = @as(f64, @floatFromInt(move_node.x)) + 0.5 - pool.position_x[entity];
    const move_dz = @as(f64, @floatFromInt(move_node.z)) + 0.5 - pool.position_z[entity];
    const distance_squared = move_dx * move_dx + move_dz * move_dz;
    if (distance_squared < 2.500000277905201e-7) return false;

    const desired_yaw = vanilla_math.movementYaw(move_dz, move_dx);
    pool.yaw[entity] = vanilla_math.changeAngle(pool.yaw[entity], desired_yaw, 90);
    const movement_speed: f32 = @floatCast(living.paths.speed[entity] * pool.movement_speed[entity]);
    const slipperiness: f32 = 0.6;
    const acceleration: f32 = if (pool.on_ground[entity])
        movement_speed * (@as(f32, 0.21600002) / (slipperiness * slipperiness * slipperiness))
    else
        0.02;
    const radians = pool.yaw[entity] * @as(f32, 0.017453292);
    const scale: f64 = @floatCast(acceleration);
    const forward: f64 = @floatCast(movement_speed);
    pool.velocity_x[entity] -= forward * scale * @as(f64, @floatCast(vanilla_math.sin(radians)));
    pool.velocity_z[entity] += forward * scale * @as(f64, @floatCast(vanilla_math.cos(radians)));

    const vertical_delta = @as(f64, @floatFromInt(move_node.y)) - pool.position_y[entity];
    return vertical_delta > 0.6 and distance_squared < @max(@as(f64, 1), @as(f64, width));
}

test "navigation stops by clearing a living path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var paths = navigation.Paths{};
    try paths.allocate(arena.allocator());
    paths.length[0] = 1;
    paths.speed[0] = 1;
    paths.clear(0);
    try std.testing.expect(paths.isIdle(0));
    try std.testing.expectEqual(@as(f64, 0), paths.speed[0]);
}
