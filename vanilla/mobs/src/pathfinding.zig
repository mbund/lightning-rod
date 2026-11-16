//! Vanilla's ground pathfinding: WalkNodeEvaluator decides what each block is to a walking mob
//! and which neighbours a node has, and PathFinder runs A* over them with vanilla's binary heap,
//! costs and tie breaking, so mobs choose the paths vanilla mobs choose. That includes how
//! trapdoors, doors, fences and rails look to a mob, which farms rely on.
//!
//! A search keeps its nodes in a fixed pool keyed as vanilla keys them (Node.createHash), and
//! remembers path types for the search only, as WalkNodeEvaluator does.

const std = @import("std");
const game_data = @import("game_data");
const mth = @import("mth.zig");
const body = @import("body.zig");
const mob_blocks = @import("mob_blocks.zig");

const PathType = mob_blocks.PathType;
const assert = std.debug.assert;

pub const Node = struct {
    x: i32,
    y: i32,
    z: i32,
    heap_index: i32 = -1,
    g: f32 = 0,
    h: f32 = 0,
    f: f32 = 0,
    came_from: ?u32 = null,
    closed: bool = false,
    walked_distance: f32 = 0,
    cost_malus: f32 = 0,
    type: PathType = .blocked,

    fn inOpenSet(self: Node) bool {
        return self.heap_index >= 0;
    }

    pub fn distanceTo(self: Node, other: Node) f32 {
        return distance(self, other.x, other.y, other.z);
    }

    fn distanceManhattan(self: Node, x: i32, y: i32, z: i32) f32 {
        const dx: f32 = @floatFromInt(@abs(x - self.x));
        const dy: f32 = @floatFromInt(@abs(y - self.y));
        const dz: f32 = @floatFromInt(@abs(z - self.z));
        return dx + dy + dz;
    }
};

fn distance(node: Node, x: i32, y: i32, z: i32) f32 {
    const dx: f32 = @floatFromInt(x - node.x);
    const dy: f32 = @floatFromInt(y - node.y);
    const dz: f32 = @floatFromInt(z - node.z);
    return mth.sqrt(dx * dx + dy * dy + dz * dz);
}

/// Node.createHash, which keys a search's nodes. Positions that share it share a node, as in
/// vanilla, which no search reaches far enough to see.
pub fn nodeHash(x: i32, y: i32, z: i32) i32 {
    var hash: u32 = @as(u32, @bitCast(y)) & 0xff;
    hash |= (@as(u32, @bitCast(x)) & 32767) << 8;
    hash |= (@as(u32, @bitCast(z)) & 32767) << 24;
    if (x < 0) hash |= 0x8000_0000;
    if (z < 0) hash |= 32768;
    return @bitCast(hash);
}

/// What the evaluator needs to know about the mob it searches for.
pub const Mob = struct {
    width: f32,
    height: f32,
    max_up_step: f32,
    position: [3]f64,
    on_ground: bool,
    in_water: bool,
    /// Mob.getMaxFallDistance with no target: LivingEntity.getComfortableFallDistance(0).
    max_fall_distance: i32 = 3,
    can_float: bool,
    can_open_doors: bool = false,
    can_pass_doors: bool = true,
    can_walk_over_fences: bool = false,
    /// Mob.setPathfindingMalus overrides by path type, or null for the type's own malus.
    malus: [PathType.count]?f32 = @splat(null),

    pub fn pathfindingMalus(self: *const Mob, path_type: PathType) f32 {
        return self.malus[@backingInt(path_type)] orelse path_type.malus();
    }

    fn blockPosition(self: *const Mob) [3]i32 {
        return .{ mth.floor(self.position[0]), mth.floor(self.position[1]), mth.floor(self.position[2]) };
    }

    fn box(self: *const Mob) body.Box {
        return body.makeBox(self.position, self.width, self.height);
    }
};

/// The nodes of a path, start first, as Path holds them.
pub const Path = struct {
    nodes: []PathNode,
    count: usize,
    target: [3]i32,
    distance_to_target: f32,
    reached: bool,
};

pub const PathNode = struct { x: i32, y: i32, z: i32, type: PathType };

/// A search's working memory, preallocated and reused by every search on the thread.
pub const Search = struct {
    nodes: []Node,
    node_count: u32 = 0,
    /// Open addressing from Node.createHash to a node.
    slots: []u32,
    /// The binary heap of open nodes, by node.
    heap: []u32,
    heap_size: u32 = 0,
    /// Path types this search looked up, by position, as pathTypesByPosCacheByMob keeps them.
    type_keys: []u64,
    type_values: []PathType,
    type_used: []bool,
    type_count: usize = 0,
    neighbors: [32]u32 = undefined,
    reusable: [4]?u32 = .{ null, null, null, null },
    level: *const body.Level = undefined,
    mob: *const Mob = undefined,
    width: i32 = 1,
    height: i32 = 1,
    depth: i32 = 1,

    const empty_slot = std.math.maxInt(u32);

    pub fn init(allocator: std.mem.Allocator, capacity: u32) !Search {
        assert(capacity > 0 and std.math.isPowerOfTwo(capacity));
        const types = capacity * 4;
        const self: Search = .{
            .nodes = try allocator.alloc(Node, capacity),
            .slots = try allocator.alloc(u32, capacity * 2),
            .heap = try allocator.alloc(u32, capacity),
            .type_keys = try allocator.alloc(u64, types),
            .type_values = try allocator.alloc(PathType, types),
            .type_used = try allocator.alloc(bool, types),
        };
        @memset(self.slots, empty_slot);
        @memset(self.type_used, false);
        return self;
    }

    fn reset(self: *Search, level: *const body.Level, mob: *const Mob) void {
        for (self.nodes[0..self.node_count]) |made| self.slots[self.slotOf(nodeHash(made.x, made.y, made.z))] = empty_slot;
        self.node_count = 0;
        self.heap_size = 0;
        @memset(self.type_used, false);
        self.type_count = 0;
        self.level = level;
        self.mob = mob;
        // NodeEvaluator.prepare.
        self.width = mth.floorFloat(mob.width + 1.0);
        self.height = mth.floorFloat(mob.height + 1.0);
        self.depth = mth.floorFloat(mob.width + 1.0);
    }

    fn slotOf(self: *const Search, hash: i32) usize {
        const mask = self.slots.len - 1;
        var slot: usize = @as(usize, @as(u32, @bitCast(hash)) *% 0x9e3779b9) & mask;
        while (true) : (slot = (slot + 1) & mask) {
            const index = self.slots[slot];
            if (index == empty_slot) return slot;
            const found = self.nodes[index];
            if (nodeHash(found.x, found.y, found.z) == hash) return slot;
        }
    }

    pub const Full = error{SearchFull};

    /// NodeEvaluator.getNode: the node at a position, made the first time.
    fn getNode(self: *Search, x: i32, y: i32, z: i32) Full!u32 {
        const slot = self.slotOf(nodeHash(x, y, z));
        if (self.slots[slot] != empty_slot) return self.slots[slot];
        if (self.node_count == self.nodes.len) return error.SearchFull;
        const index = self.node_count;
        self.nodes[index] = .{ .x = x, .y = y, .z = z };
        self.node_count += 1;
        self.slots[slot] = index;
        return index;
    }

    fn node(self: *Search, index: u32) *Node {
        return &self.nodes[index];
    }

    // The block view.

    fn state(self: *Search, x: i32, y: i32, z: i32) !u16 {
        return self.level.state(x, y, z);
    }

    fn baseType(self: *Search, x: i32, y: i32, z: i32) !PathType {
        return self.level.blocks.get(try self.state(x, y, z)).path;
    }

    /// WalkNodeEvaluator.getPathTypeStatic: an open block over ground is walkable, or dangerous
    /// by what is under or around it.
    pub fn pathTypeStatic(self: *Search, x: i32, y: i32, z: i32) !PathType {
        const own = try self.baseType(x, y, z);
        if (own != .open or y < self.level.minimum_y + 1) return own;
        return switch (try self.baseType(x, y - 1, z)) {
            .open, .water, .lava, .walkable => .open,
            .damage_fire => .damage_fire,
            .damage_other => .damage_other,
            .sticky_honey => .sticky_honey,
            .powder_snow => .danger_powder_snow,
            .damage_cautious => .damage_cautious,
            .trapdoor => .danger_trapdoor,
            else => try self.checkNeighbourBlocks(x, y, z, .walkable),
        };
    }

    /// WalkNodeEvaluator.checkNeighbourBlocks, in vanilla's order, first match winning.
    fn checkNeighbourBlocks(self: *Search, x: i32, y: i32, z: i32, fallback: PathType) !PathType {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dz: i32 = -1;
                while (dz <= 1) : (dz += 1) {
                    if (dx == 0 and dz == 0) continue;
                    switch (try self.baseType(x + dx, y + dy, z + dz)) {
                        .damage_other => return .danger_other,
                        .damage_fire, .lava => return .danger_fire,
                        .water => return .water_border,
                        .damage_cautious => return .damage_cautious,
                        else => {},
                    }
                }
            }
        }
        return fallback;
    }

    /// WalkNodeEvaluator.getPathTypeWithinMobBB, as a set of types by bit.
    fn typesWithinBox(self: *Search, x: i32, y: i32, z: i32) !u32 {
        var set: u32 = 0;
        const at = self.mob.blockPosition();
        var i: i32 = 0;
        while (i < self.width) : (i += 1) {
            var j: i32 = 0;
            while (j < self.height) : (j += 1) {
                var k: i32 = 0;
                while (k < self.depth) : (k += 1) {
                    var path_type = try self.pathTypeStatic(x + i, y + j, z + k);
                    if (path_type == .door_wood_closed and self.mob.can_open_doors and self.mob.can_pass_doors) path_type = .walkable_door;
                    if (path_type == .door_open and !self.mob.can_pass_doors) path_type = .blocked;
                    if (path_type == .rail and try self.pathTypeStatic(at[0], at[1], at[2]) != .rail and try self.pathTypeStatic(at[0], at[1] - 1, at[2]) != .rail) path_type = .unpassable_rail;
                    set |= @as(u32, 1) << @as(u5, @intCast(@backingInt(path_type)));
                }
            }
        }
        return set;
    }

    /// WalkNodeEvaluator.getPathTypeOfMob: of the types the mob's box covers, fences and rails it
    /// cannot cross win, then any it refuses, then the costliest, in PathType's order.
    fn pathTypeOfMob(self: *Search, x: i32, y: i32, z: i32) !PathType {
        const set = try self.typesWithinBox(x, y, z);
        if (set & bit(.fence) != 0) return .fence;
        if (set & bit(.unpassable_rail) != 0) return .unpassable_rail;
        var chosen: PathType = .blocked;
        var remaining = set;
        while (remaining != 0) {
            const path_type: PathType = @fromBackingInt(@intCast(@ctz(remaining)));
            remaining &= remaining - 1;
            const malus = self.mob.pathfindingMalus(path_type);
            if (malus < 0) return path_type;
            if (malus >= self.mob.pathfindingMalus(chosen)) chosen = path_type;
        }
        if (self.width <= 1 and chosen != .open and self.mob.pathfindingMalus(chosen) == 0 and try self.pathTypeStatic(x, y, z) == .open) return .open;
        return chosen;
    }

    fn bit(path_type: PathType) u32 {
        return @as(u32, 1) << @as(u5, @intCast(@backingInt(path_type)));
    }

    /// WalkNodeEvaluator.getCachedPathType.
    fn cachedPathType(self: *Search, x: i32, y: i32, z: i32) !PathType {
        const key = blockKey(x, y, z);
        const mask = self.type_keys.len - 1;
        var slot: usize = @as(usize, @truncate(key *% 0x9e3779b97f4a7c15 >> 32)) & mask;
        while (self.type_used[slot]) : (slot = (slot + 1) & mask) {
            if (self.type_keys[slot] == key) return self.type_values[slot];
        }
        const path_type = try self.pathTypeOfMob(x, y, z);
        // A full table only stops remembering, which costs time but not the result.
        if (self.type_count * 2 < self.type_keys.len) {
            self.type_used[slot] = true;
            self.type_keys[slot] = key;
            self.type_values[slot] = path_type;
            self.type_count += 1;
        }
        return path_type;
    }

    fn blockKey(x: i32, y: i32, z: i32) u64 {
        return (@as(u64, @as(u32, @bitCast(x))) << 32) ^ (@as(u64, @as(u32, @bitCast(z))) << 12) ^ @as(u64, @as(u32, @bitCast(y)));
    }

    /// WalkNodeEvaluator.getFloorLevel: where a mob stands in a block, on the collision shape of
    /// the block below, or at the middle of water for mobs that float.
    fn floorLevel(self: *Search, x: i32, y: i32, z: i32) !f64 {
        if (self.mob.can_float and game_data.physics.get(try self.state(x, y, z)).fluid == .water) return @as(f64, @floatFromInt(y)) + 0.5;
        return staticFloorLevel(self.level, x, y, z);
    }

    fn canStartAt(self: *Search, x: i32, y: i32, z: i32) !bool {
        const path_type = try self.cachedPathType(x, y, z);
        return path_type != .open and self.mob.pathfindingMalus(path_type) >= 0;
    }

    fn startNode(self: *Search, x: i32, y: i32, z: i32) !u32 {
        const index = try self.getNode(x, y, z);
        const path_type = try self.cachedPathType(x, y, z);
        self.node(index).type = path_type;
        self.node(index).cost_malus = self.mob.pathfindingMalus(path_type);
        return index;
    }

    /// WalkNodeEvaluator.getStart.
    fn getStart(self: *Search) !u32 {
        const mob = self.mob;
        var y = mth.floor(mob.position[1]);
        const x_column = mth.floor(mob.position[0]);
        const z_column = mth.floor(mob.position[2]);
        var current = try self.state(x_column, y, z_column);
        if (mob.can_float and mob.in_water) {
            while (true) {
                const physics = game_data.physics.get(current);
                const source_water = physics.fluid == .water and physics.amount == 8 and !physics.falling;
                if (self.level.blocks.get(current).kind != .water and !source_water) {
                    y -= 1;
                    break;
                }
                y += 1;
                current = try self.state(x_column, y, z_column);
            }
        } else if (mob.on_ground) {
            y = mth.floor(mob.position[1] + 0.5);
        } else {
            var probe_y = mth.floor(mob.position[1] + 1.0);
            while (probe_y > self.level.minimum_y) {
                y = probe_y;
                probe_y -= 1;
                const below = try self.state(x_column, probe_y, z_column);
                const entry = self.level.blocks.get(below);
                if (!entry.flags.air and !entry.flags.pathfindable_land) break;
            }
        }
        const at = mob.blockPosition();
        if (!try self.canStartAt(at[0], y, at[2])) {
            const box = mob.box();
            const corners = [_][2]f64{ .{ box.min[0], box.min[2] }, .{ box.min[0], box.max[2] }, .{ box.max[0], box.min[2] }, .{ box.max[0], box.max[2] } };
            for (corners) |corner| {
                const cx = mth.floor(corner[0]);
                const cz = mth.floor(corner[1]);
                if (try self.canStartAt(cx, y, cz)) return self.startNode(cx, y, cz);
            }
        }
        return self.startNode(at[0], y, at[2]);
    }

    fn getNodeAndUpdateCostToMax(self: *Search, x: i32, y: i32, z: i32, path_type: PathType, malus: f32) !u32 {
        const index = try self.getNode(x, y, z);
        const n = self.node(index);
        n.type = path_type;
        n.cost_malus = @max(n.cost_malus, malus);
        return index;
    }

    fn getBlockedNode(self: *Search, x: i32, y: i32, z: i32) !u32 {
        const index = try self.getNode(x, y, z);
        self.node(index).type = .blocked;
        self.node(index).cost_malus = -1;
        return index;
    }

    fn getClosedNode(self: *Search, x: i32, y: i32, z: i32, path_type: PathType) !u32 {
        const index = try self.getNode(x, y, z);
        const n = self.node(index);
        n.closed = true;
        n.type = path_type;
        n.cost_malus = path_type.malus();
        return index;
    }

    fn partialCollision(path_type: PathType) bool {
        return path_type == .fence or path_type == .door_wood_closed or path_type == .door_iron_closed;
    }

    fn mobJumpHeight(self: *const Search) f64 {
        return @max(1.125, @as(f64, self.mob.max_up_step));
    }

    /// CollisionGetter.noCollision for the mob, ignoring entities.
    fn hasCollisions(self: *Search, query: body.Box) !bool {
        return !try body.noCollision(self.level, query, .{ .bottom = self.mob.position[1] });
    }

    /// WalkNodeEvaluator.canReachWithoutCollision: the mob's box swept to the node in steps
    /// of its own size.
    fn canReachWithoutCollision(self: *Search, target: u32) !bool {
        var box = self.mob.box();
        const n = self.node(target).*;
        const size_x = box.max[0] - box.min[0];
        const size_y = box.max[1] - box.min[1];
        const size_z = box.max[2] - box.min[2];
        var step: [3]f64 = .{
            @as(f64, @floatFromInt(n.x)) - self.mob.position[0] + size_x / 2.0,
            @as(f64, @floatFromInt(n.y)) - self.mob.position[1] + size_y / 2.0,
            @as(f64, @floatFromInt(n.z)) - self.mob.position[2] + size_z / 2.0,
        };
        // AABB.getSize: the average of its sides.
        const size = (size_x + size_y + size_z) / 3.0;
        const steps = mth.ceil(@sqrt(step[0] * step[0] + step[1] * step[1] + step[2] * step[2]) / size);
        const scale: f64 = @as(f32, 1.0) / @as(f32, @floatFromInt(steps));
        step = .{ step[0] * scale, step[1] * scale, step[2] * scale };
        var index: i32 = 1;
        while (index <= steps) : (index += 1) {
            box = box.move(step);
            if (try self.hasCollisions(box)) return false;
        }
        return true;
    }

    /// WalkNodeEvaluator.findAcceptedNode: the node a mob reaches stepping to (x, y, z) from a
    /// node standing at floor height `floor`, jumping up to `jump` blocks or falling as far as it
    /// may.
    fn findAcceptedNode(self: *Search, x: i32, y: i32, z: i32, jump: i32, floor: f64, direction: Direction, from_type: PathType) (Full || anyerror)!?u32 {
        var result: ?u32 = null;
        const own_floor = try self.floorLevel(x, y, z);
        if (own_floor - floor > self.mobJumpHeight()) return null;
        const path_type = try self.cachedPathType(x, y, z);
        const malus = self.mob.pathfindingMalus(path_type);
        if (malus >= 0) result = try self.getNodeAndUpdateCostToMax(x, y, z, path_type, malus);
        if (partialCollision(from_type)) {
            if (result) |found| if (self.node(found).cost_malus >= 0 and !try self.canReachWithoutCollision(found)) {
                result = null;
            };
        }
        if (path_type == .walkable) return result;
        // Mobs here are never amphibious.
        const refused = result == null or self.node(result.?).cost_malus < 0;
        if (refused and jump > 0 and (path_type != .fence or self.mob.can_walk_over_fences) and path_type != .unpassable_rail and path_type != .trapdoor and path_type != .powder_snow) {
            return self.tryJumpOn(x, y, z, jump, floor, direction, from_type);
        } else if (path_type == .water and !self.mob.can_float) {
            return self.tryFindFirstNonWaterBelow(x, y, z, result);
        } else if (path_type == .open) {
            return try self.tryFindFirstGroundNodeBelow(x, y, z);
        } else if (partialCollision(path_type) and result == null) {
            return try self.getClosedNode(x, y, z, path_type);
        }
        return result;
    }

    fn tryJumpOn(self: *Search, x: i32, y: i32, z: i32, jump: i32, floor: f64, direction: Direction, from_type: PathType) (Full || anyerror)!?u32 {
        const found = (try self.findAcceptedNode(x, y + 1, z, jump - 1, floor, direction, from_type)) orelse return null;
        if (self.mob.width >= 1.0) return found;
        const n = self.node(found).*;
        if (n.type != .open and n.type != .walkable) return found;
        const step = direction.step();
        const center_x = @as(f64, @floatFromInt(x - step[0])) + 0.5;
        const center_z = @as(f64, @floatFromInt(z - step[1])) + 0.5;
        const half: f64 = self.mob.width / 2.0;
        const query: body.Box = .{
            .min = .{ center_x - half, try staticFloorLevelAt(self, center_x, @as(f64, @floatFromInt(y + 1)), center_z) + 0.001, center_z - half },
            .max = .{ center_x + half, @as(f64, self.mob.height) + try self.floorLevel(n.x, n.y, n.z) - 0.002, center_z + half },
        };
        return if (try self.hasCollisions(query)) null else found;
    }

    fn tryFindFirstNonWaterBelow(self: *Search, x: i32, y_start: i32, z: i32, initial: ?u32) !?u32 {
        var result = initial;
        var y = y_start - 1;
        while (y > self.level.minimum_y) : (y -= 1) {
            const path_type = try self.cachedPathType(x, y, z);
            if (path_type != .water) return result;
            result = try self.getNodeAndUpdateCostToMax(x, y, z, path_type, self.mob.pathfindingMalus(path_type));
        }
        return result;
    }

    fn tryFindFirstGroundNodeBelow(self: *Search, x: i32, y: i32, z: i32) !u32 {
        var below = y - 1;
        while (below >= self.level.minimum_y) : (below -= 1) {
            if (y - below > self.mob.max_fall_distance) return self.getBlockedNode(x, below, z);
            const path_type = try self.cachedPathType(x, below, z);
            const malus = self.mob.pathfindingMalus(path_type);
            if (path_type != .open) {
                if (malus >= 0) return self.getNodeAndUpdateCostToMax(x, below, z, path_type, malus);
                return self.getBlockedNode(x, below, z);
            }
        }
        return self.getBlockedNode(x, y, z);
    }

    fn neighborValid(self: *Search, candidate: ?u32, from: u32) bool {
        const index = candidate orelse return false;
        const n = self.node(index);
        return !n.closed and (n.cost_malus >= 0 or self.node(from).cost_malus < 0);
    }

    fn diagonalValid(self: *Search, from: u32, first: ?u32, second: ?u32) bool {
        const a_index = second orelse return false;
        const b_index = first orelse return false;
        const origin = self.node(from).*;
        const a = self.node(a_index).*;
        const b = self.node(b_index).*;
        if (a.y > origin.y or b.y > origin.y) return false;
        if (b.type == .walkable_door or a.type == .walkable_door) return false;
        const narrow = a.type == .fence and b.type == .fence and self.mob.width < 0.5;
        return (a.y < origin.y or a.cost_malus >= 0 or narrow) and (b.y < origin.y or b.cost_malus >= 0 or narrow);
    }

    fn diagonalNodeValid(self: *Search, candidate: ?u32) bool {
        const index = candidate orelse return false;
        const n = self.node(index);
        if (n.closed) return false;
        return if (n.type == .walkable_door) false else n.cost_malus >= 0;
    }

    /// WalkNodeEvaluator.getNeighbors: the four sides in Direction.Plane order, then the four
    /// corners each side and its clockwise neighbour allow.
    fn getNeighbors(self: *Search, from: u32) !usize {
        var count: usize = 0;
        const origin = self.node(from).*;
        var jump: i32 = 0;
        const above = try self.cachedPathType(origin.x, origin.y + 1, origin.z);
        const own = try self.cachedPathType(origin.x, origin.y, origin.z);
        if (self.mob.pathfindingMalus(above) >= 0 and own != .sticky_honey) jump = mth.floorFloat(@max(1.0, self.mob.max_up_step));
        const floor = try self.floorLevel(origin.x, origin.y, origin.z);
        for (Direction.horizontal) |direction| {
            const step = direction.step();
            const found = try self.findAcceptedNode(origin.x + step[0], origin.y, origin.z + step[1], jump, floor, direction, own);
            self.reusable[direction.data2d()] = found;
            if (self.neighborValid(found, from)) {
                self.neighbors[count] = found.?;
                count += 1;
            }
        }
        for (Direction.horizontal) |direction| {
            const clockwise = direction.clockwise();
            if (!self.diagonalValid(from, self.reusable[direction.data2d()], self.reusable[clockwise.data2d()])) continue;
            const a = direction.step();
            const b = clockwise.step();
            const found = try self.findAcceptedNode(origin.x + a[0] + b[0], origin.y, origin.z + a[1] + b[1], jump, floor, direction, own);
            if (self.diagonalNodeValid(found)) {
                self.neighbors[count] = found.?;
                count += 1;
            }
        }
        return count;
    }

    // BinaryHeap.

    fn heapInsert(self: *Search, index: u32) void {
        assert(self.node(index).heap_index < 0);
        self.heap[self.heap_size] = index;
        self.node(index).heap_index = @intCast(self.heap_size);
        self.upHeap(self.heap_size);
        self.heap_size += 1;
    }

    fn heapPop(self: *Search) u32 {
        const top = self.heap[0];
        self.heap_size -= 1;
        self.heap[0] = self.heap[self.heap_size];
        if (self.heap_size > 0) self.downHeap(0);
        self.node(top).heap_index = -1;
        return top;
    }

    fn changeCost(self: *Search, index: u32, cost: f32) void {
        const n = self.node(index);
        const previous = n.f;
        n.f = cost;
        if (cost < previous) self.upHeap(@intCast(n.heap_index)) else self.downHeap(@intCast(n.heap_index));
    }

    fn upHeap(self: *Search, start: u32) void {
        var at = start;
        const moving = self.heap[at];
        const cost = self.node(moving).f;
        while (at > 0) {
            const parent = (at - 1) >> 1;
            const other = self.heap[parent];
            if (!(cost < self.node(other).f)) break;
            self.heap[at] = other;
            self.node(other).heap_index = @intCast(at);
            at = parent;
        }
        self.heap[at] = moving;
        self.node(moving).heap_index = @intCast(at);
    }

    fn downHeap(self: *Search, start: u32) void {
        var at = start;
        const moving = self.heap[at];
        const cost = self.node(moving).f;
        while (true) {
            const left = 1 + (at << 1);
            const right = left + 1;
            if (left >= self.heap_size) break;
            const left_node = self.heap[left];
            const left_cost = self.node(left_node).f;
            const right_cost = if (right >= self.heap_size) std.math.inf(f32) else self.node(self.heap[right]).f;
            if (left_cost < right_cost) {
                if (!(left_cost < cost)) break;
                self.heap[at] = left_node;
                self.node(left_node).heap_index = @intCast(at);
                at = left;
            } else {
                if (!(right_cost < cost)) break;
                const right_node = self.heap[right];
                self.heap[at] = right_node;
                self.node(right_node).heap_index = @intCast(at);
                at = right;
            }
        }
        self.heap[at] = moving;
        self.node(moving).heap_index = @intCast(at);
    }

    // PathFinder.

    pub const Request = struct {
        target: [3]i32,
        /// How far from the start a path may wander, getMaxPathLength.
        max_range: f32,
        /// How close a node must come to the target to reach it, by Manhattan distance.
        accuracy: i32,
        max_visited_nodes: i32,
        multiplier: f32 = 1.0,
    };

    /// PathFinder.findPath for one target. The path's nodes go into `output`, and a path longer
    /// than it is reported as SearchFull, which no search under the visited node limit makes.
    pub fn findPath(self: *Search, level: *const body.Level, mob: *const Mob, request: Request, output: []PathNode) !?Path {
        self.reset(level, mob);
        const start = try self.getStart();
        // NodeEvaluator.getTargetNodeAt makes the target's node too, and the Target copies it.
        _ = try self.getNode(request.target[0], request.target[1], request.target[2]);
        const target_node: Node = .{ .x = request.target[0], .y = request.target[1], .z = request.target[2] };
        var best_heuristic = std.math.floatMax(f32);
        var best_node: ?u32 = null;
        var reached = false;
        {
            const s = self.node(start);
            s.g = 0;
            s.h = self.bestHeuristic(start, target_node, &best_heuristic, &best_node);
            s.f = s.h;
        }
        self.heap_size = 0;
        self.heapInsert(start);
        var visited: i32 = 0;
        const limit: i32 = @intFromFloat(@as(f32, @floatFromInt(request.max_visited_nodes)) * request.multiplier);
        const start_node = self.node(start).*;
        while (self.heap_size > 0) {
            visited += 1;
            if (visited >= limit) break;
            const current = self.heapPop();
            self.node(current).closed = true;
            if (self.node(current).distanceManhattan(target_node.x, target_node.y, target_node.z) <= @as(f32, @floatFromInt(request.accuracy))) {
                reached = true;
                break;
            }
            if (self.node(current).distanceTo(start_node) >= request.max_range) continue;
            const count = try self.getNeighbors(current);
            for (self.neighbors[0..count]) |neighbor| {
                const from = self.node(current).*;
                const step = from.distanceTo(self.node(neighbor).*);
                const next = self.node(neighbor);
                next.walked_distance = from.walked_distance + step;
                const cost = from.g + step + next.cost_malus;
                if (next.walked_distance < request.max_range and (!next.inOpenSet() or cost < next.g)) {
                    next.came_from = current;
                    next.g = cost;
                    next.h = self.bestHeuristic(neighbor, target_node, &best_heuristic, &best_node) * 1.5;
                    if (next.inOpenSet()) {
                        self.changeCost(neighbor, next.g + next.h);
                    } else {
                        next.f = next.g + next.h;
                        self.heapInsert(neighbor);
                    }
                }
            }
        }
        const end = best_node orelse return null;
        // PathFinder.reconstructPath, from the node nearest the target back to the start.
        var length: usize = 1;
        var walk = end;
        while (self.node(walk).came_from) |previous| : (walk = previous) length += 1;
        if (length > output.len) return error.SearchFull;
        walk = end;
        var at = length;
        while (true) {
            at -= 1;
            const n = self.node(walk).*;
            output[at] = .{ .x = n.x, .y = n.y, .z = n.z, .type = n.type };
            walk = n.came_from orelse break;
        }
        const last = output[length - 1];
        const last_node: Node = .{ .x = last.x, .y = last.y, .z = last.z };
        return .{
            .nodes = output[0..length],
            .count = length,
            .target = request.target,
            .distance_to_target = last_node.distanceManhattan(request.target[0], request.target[1], request.target[2]),
            .reached = reached,
        };
    }

    /// PathFinder.getBestH for one target, which also keeps the target's best node.
    fn bestHeuristic(self: *Search, index: u32, target: Node, best: *f32, best_node: *?u32) f32 {
        const value = self.node(index).distanceTo(target);
        if (value < best.*) {
            best.* = value;
            best_node.* = index;
        }
        return value;
    }
};

/// WalkNodeEvaluator.getFloorLevel(BlockGetter, BlockPos): the top of the collision shape of
/// the block below, with no entity's context.
pub fn staticFloorLevel(level: *const body.Level, x: i32, y: i32, z: i32) !f64 {
    const below = try level.state(x, y - 1, z);
    const boxes = body.contextFreeBoxes(below, x, z);
    var top: ?f64 = null;
    for (0..boxes.count) |index| {
        const value = boxes.get(index)[4];
        top = if (top) |current| @max(current, value) else value;
    }
    return @as(f64, @floatFromInt(y - 1)) + (top orelse 0.0);
}

fn staticFloorLevelAt(search: *Search, x: f64, y: f64, z: f64) !f64 {
    return staticFloorLevel(search.level, mth.floor(x), mth.floor(y), mth.floor(z));
}

pub const Direction = enum {
    north,
    east,
    south,
    west,

    /// Direction.Plane.HORIZONTAL's order.
    pub const horizontal = [_]Direction{ .north, .east, .south, .west };

    pub fn step(self: Direction) [2]i32 {
        return switch (self) {
            .north => .{ 0, -1 },
            .east => .{ 1, 0 },
            .south => .{ 0, 1 },
            .west => .{ -1, 0 },
        };
    }

    pub fn clockwise(self: Direction) Direction {
        return switch (self) {
            .north => .east,
            .east => .south,
            .south => .west,
            .west => .north,
        };
    }

    /// Direction.get2DDataValue.
    pub fn data2d(self: Direction) usize {
        return switch (self) {
            .south => 0,
            .west => 1,
            .north => 2,
            .east => 3,
        };
    }
};

test "node hashes match vanilla" {
    // Node.createHash, printed by vanilla 1.21.8.
    try std.testing.expectEqual(@as(i32, 16777536), nodeHash(1, 64, 1));
    try std.testing.expectEqual(@as(i32, -2088764602), nodeHash(-5, 70, 3));
    try std.testing.expectEqual(@as(i32, -117406912), nodeHash(3, 64, -7));
    try std.testing.expectEqual(@as(i32, -1199596298), nodeHash(-100, -10, -200));
}
