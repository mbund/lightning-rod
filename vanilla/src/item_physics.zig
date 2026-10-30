const Blocks = @import("blocks.zig").Blocks;
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
        effects: OrbEffects = .{},
    };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*ItemPhysics {
        const self = try allocator.create(ItemPhysics);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn readWindow(self: *const ItemPhysics) Window {
        return Window.init(self.deps.chunks);
    }

    pub fn advance(self: *ItemPhysics, neighborhood: *Window, entity_id: u32, ticks: u32, body: entities.State, on_ground: bool) !Result {
        return self.advanceBody(false, neighborhood, entity_id, ticks, body, on_ground, .{ 0, 0, 0 });
    }

    pub fn advanceOrb(self: *ItemPhysics, neighborhood: *Window, entity_id: u32, ticks: u32, body: entities.State, on_ground: bool, stuck: [3]f64) !Result {
        return self.advanceBody(true, neighborhood, entity_id, ticks, body, on_ground, stuck);
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

    fn blockState(self: *ItemPhysics, window: *Window, world: u32, position: chunks.Position) !u16 {
        assert(window.owner == self.deps.chunks);
        var views: [1]chunks.View = undefined;
        try window.readMany(&.{chunks.sectionAt(world, position)}, &views);
        const state = views[0].get(chunks.localIndex(position));
        if (state >= game_data.registry.block_state_names.len) return error.Corrupt;
        return state;
    }

    pub fn pushOrb(self: *ItemPhysics, window: *Window, body: *entities.State, ultrawarm: bool) !void {
        inline for (.{ game_data.physics_data.Fluid.water, game_data.physics_data.Fluid.lava }) |kind| {
            const low: [3]f64 = .{ body.position[0] - 0.249, body.position[1] + 0.001, body.position[2] - 0.249 };
            const high: [3]f64 = .{ body.position[0] + 0.249, body.position[1] + 0.499, body.position[2] + 0.249 };
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
                        const height = @as(f64, @as(f32, @floatFromInt(y)) + (if (above.fluid == kind) @as(f32, 1) else state.height()));
                        if (height < low[1]) continue;
                        depth = @max(depth, height - low[1]);
                        const current = try self.flow(window, body.world, position, state);
                        for (&total, current) |*component, velocity| component.* += velocity * (if (depth < 0.4) depth else 1);
                        count += 1;
                    }
                }
            }
            const squared = total[0] * total[0] + total[1] * total[1] + total[2] * total[2];
            if (squared > 0) {
                for (&total) |*component| component.* /= @as(f64, @floatFromInt(count));
                var direction = normalized(total);
                const strength: f64 = if (kind == .water) 0.014 else if (ultrawarm) 0.007 else 0.0023333333333333335;
                const scale: f64 = if (@abs(body.velocity[0]) < 0.003 and @abs(body.velocity[2]) < 0.003 and strength < 0.0045000000000000005) 0.0045000000000000005 else strength;
                for (&direction, &body.velocity) |*component, *velocity| {
                    component.* *= scale;
                    velocity.* += component.*;
                }
            }
        }
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

    pub fn orbCollides(self: *ItemPhysics, window: *Window, body: entities.State) !bool {
        assert(window.owner == self.deps.chunks);
        const low: [3]f64 = .{ body.position[0] - 0.25, body.position[1], body.position[2] - 0.25 };
        const high: [3]f64 = .{ body.position[0] + 0.25, body.position[1] + 0.5, body.position[2] + 0.25 };
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
        assert(window.owner == self.deps.chunks);
        const center: [3]f64 = .{ body.position[0], body.position[1] + 0.25, body.position[2] };
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
        var occupied: std.StaticBitSet(33 * 33 * 33) = .initEmpty();
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

    fn advanceBody(self: *ItemPhysics, comptime orb: bool, neighborhood: *Window, entity_id: u32, ticks: u32, body: entities.State, on_ground: bool, stuck: [3]f64) !Result {
        assert(entity_id > 0 and neighborhood.owner == self.deps.chunks);
        var next = body;

        for (body.position ++ body.velocity) |value| assert(std.math.isFinite(value));
        if (!orb) next.velocity[1] -= 0.04;
        const vertical_velocity = next.velocity[1];
        var motion = next.velocity;
        if (orb and stuck[0] * stuck[0] + stuck[1] * stuck[1] + stuck[2] * stuck[2] > 1e-7) {
            for (&motion, stuck) |*component, multiplier| component.* *= multiplier;
            next.velocity = .{ 0, 0, 0 };
        }
        var effects: OrbEffects = .{};
        var grounded = on_ground;
        if (orb or !on_ground or next.velocity[0] * next.velocity[0] + next.velocity[2] * next.velocity[2] > @as(f64, @as(f32, 0.00001)) or
            (ticks +% entity_id) % 4 == 0)
        {
            const order: [3]usize = if (@abs(motion[0]) < @abs(motion[2])) .{ 1, 2, 0 } else .{ 1, 0, 2 };

            for (order) |axis| {
                const requested = motion[axis];
                if (requested == 0) continue;

                var movement = requested;
                const minimum: [3]f64 = .{ next.position[0] - @as(f64, if (orb) 0.25 else 0.125), next.position[1], next.position[2] - @as(f64, if (orb) 0.25 else 0.125) };
                const maximum: [3]f64 = .{ next.position[0] + @as(f64, if (orb) 0.25 else 0.125), next.position[1] + @as(f64, if (orb) 0.5 else 0.25), next.position[2] + @as(f64, if (orb) 0.25 else 0.125) };
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

                next.position[axis] += movement;

                if (axis == 1) grounded = requested < 0 and requested != movement;

                if (requested != movement) next.velocity[axis] = 0;
            }

            var below: ?u16 = null;
            const below_position: chunks.Position = .{ .x = @intFromFloat(@floor(next.position[0])), .y = @intFromFloat(@floor(next.position[1] - @as(f64, @as(f32, 0.999999)))), .z = @intFromFloat(@floor(next.position[2])) };
            if (orb) {
                const base = self.deps.blocks.get(try self.blockState(neighborhood, body.world, .{ .x = @intFromFloat(@floor(next.position[0])), .y = @intFromFloat(@floor(next.position[1])), .z = @intFromFloat(@floor(next.position[2])) }));
                var speed = base.speed;
                if (speed == 1 and !base.water_block) {
                    below = try self.blockState(neighborhood, body.world, below_position);
                    speed = self.deps.blocks.get(below.?).speed;
                }
                next.velocity[0] *= speed;
                next.velocity[2] *= speed;
                effects = try self.orbEffects(neighborhood, next);
                if (effects.honey and !grounded) {
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
                if (effects.bubble) |bubble| {
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
        return .{ .body = next, .on_ground = grounded, .crossed_block = crossed, .effects = effects };
    }
};

fn normalized(vector: [3]f64) [3]f64 {
    const length = @sqrt(vector[0] * vector[0] + vector[1] * vector[1] + vector[2] * vector[2]);
    if (length < 1e-4) return .{ 0, 0, 0 };
    return .{ vector[0] / length, vector[1] / length, vector[2] / length };
}
