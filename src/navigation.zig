const std = @import("std");
const preallocated = @import("preallocated");
const none: u16 = std.math.maxInt(u16);

pub const Configuration = struct {
    maximum_entities: usize = 512,
    maximum_search_nodes: usize = 2_048,
    maximum_path_nodes: usize = 128,

    pub fn validate(self: Configuration) !void {
        if (self.maximum_entities == 0 or self.maximum_entities >= std.math.maxInt(u16)) return error.InvalidEntityCapacity;
        if (self.maximum_search_nodes == 0 or self.maximum_search_nodes >= std.math.maxInt(u16)) return error.InvalidSearchCapacity;
        if (!std.math.isPowerOfTwo(self.maximum_search_nodes * 2)) return error.SearchLookupMustBePowerOfTwo;
        if (self.maximum_path_nodes == 0 or self.maximum_path_nodes > std.math.maxInt(u8)) return error.InvalidPathCapacity;
    }
};

pub const NodeType = enum(u8) {
    blocked,
    open,
    walkable,
};

pub const Node = extern struct {
    x: i32,
    y: i16,
    z: i32,
    node_type: NodeType = .walkable,
    penalty: f32 = 0,
};

pub const Candidate = struct {
    node: Node,
    passable: bool,
    search_index: u16 = none,
};

pub const Paths = struct {
    x: []align(64) i32 = &.{},
    y: []align(64) i16 = &.{},
    z: []align(64) i32 = &.{},
    node_type: []align(64) NodeType = &.{},
    penalty: []align(64) f32 = &.{},
    length: []align(64) u8 = &.{},
    current: []align(64) u8 = &.{},
    target_x: []align(64) i32 = &.{},
    target_y: []align(64) i16 = &.{},
    target_z: []align(64) i32 = &.{},
    reaches_target: []align(64) bool = &.{},
    speed: []align(64) f64 = &.{},
    path_capacity: usize = 0,

    pub fn allocate(self: *Paths, allocator: std.mem.Allocator, configuration: Configuration) !void {
        try configuration.validate();
        self.* = .{};
        const node_capacity = configuration.maximum_entities * configuration.maximum_path_nodes;
        self.x = try preallocated.alignedAlloc(i32, allocator, .@"64", node_capacity);
        self.y = try preallocated.alignedAlloc(i16, allocator, .@"64", node_capacity);
        self.z = try preallocated.alignedAlloc(i32, allocator, .@"64", node_capacity);
        self.node_type = try preallocated.alignedAlloc(NodeType, allocator, .@"64", node_capacity);
        self.penalty = try preallocated.alignedAlloc(f32, allocator, .@"64", node_capacity);
        self.length = try preallocated.alignedAlloc(u8, allocator, .@"64", configuration.maximum_entities);
        self.current = try preallocated.alignedAlloc(u8, allocator, .@"64", configuration.maximum_entities);
        self.target_x = try preallocated.alignedAlloc(i32, allocator, .@"64", configuration.maximum_entities);
        self.target_y = try preallocated.alignedAlloc(i16, allocator, .@"64", configuration.maximum_entities);
        self.target_z = try preallocated.alignedAlloc(i32, allocator, .@"64", configuration.maximum_entities);
        self.reaches_target = try preallocated.alignedAlloc(bool, allocator, .@"64", configuration.maximum_entities);
        self.speed = try preallocated.alignedAlloc(f64, allocator, .@"64", configuration.maximum_entities);
        self.path_capacity = configuration.maximum_path_nodes;
        @memset(self.length, 0);
        @memset(self.current, 0);
        @memset(self.reaches_target, false);
        @memset(self.speed, 0);
    }

    pub fn clear(self: *Paths, entity: usize) void {
        self.length[entity] = 0;
        self.current[entity] = 0;
        self.reaches_target[entity] = false;
        self.speed[entity] = 0;
    }

    pub fn isIdle(self: *const Paths, entity: usize) bool {
        return self.current[entity] >= self.length[entity];
    }

    pub fn currentNode(self: *const Paths, entity: usize) ?Node {
        if (self.isIdle(entity)) return null;
        const at = self.current[entity];
        return .{
            .x = self.xFor(entity)[at],
            .y = self.yFor(entity)[at],
            .z = self.zFor(entity)[at],
            .node_type = self.nodeTypesFor(entity)[at],
            .penalty = self.penaltiesFor(entity)[at],
        };
    }

    pub inline fn xFor(self: anytype, entity: usize) []i32 {
        return self.x[entity * self.path_capacity ..][0..self.path_capacity];
    }

    pub inline fn yFor(self: anytype, entity: usize) []i16 {
        return self.y[entity * self.path_capacity ..][0..self.path_capacity];
    }

    pub inline fn zFor(self: anytype, entity: usize) []i32 {
        return self.z[entity * self.path_capacity ..][0..self.path_capacity];
    }

    pub inline fn nodeTypesFor(self: anytype, entity: usize) []NodeType {
        return self.node_type[entity * self.path_capacity ..][0..self.path_capacity];
    }

    pub inline fn penaltiesFor(self: anytype, entity: usize) []f32 {
        return self.penalty[entity * self.path_capacity ..][0..self.path_capacity];
    }
};

pub const Search = struct {
    x: []align(64) i32 = &.{},
    y: []align(64) i16 = &.{},
    z: []align(64) i32 = &.{},
    node_type: []align(64) NodeType = &.{},
    penalty: []align(64) f32 = &.{},
    heap_index: []align(64) i16 = &.{},
    penalized_length: []align(64) f32 = &.{},
    distance_to_target: []align(64) f32 = &.{},
    heap_weight: []align(64) f32 = &.{},
    previous: []align(64) u16 = &.{},
    visited: []align(64) bool = &.{},
    classification_known: []align(64) bool = &.{},
    classification_passable: []align(64) bool = &.{},
    path_length: []align(64) f32 = &.{},
    heap: []align(64) u16 = &.{},
    lookup_node: []align(64) u16 = &.{},
    lookup_epoch: []align(64) u32 = &.{},
    epoch: u32 = 0,
    count: u16 = 0,
    heap_count: u16 = 0,
    last_iterations: u16 = 0,
    search_capacity: usize = 0,
    lookup_capacity: usize = 0,

    pub fn allocate(self: *Search, allocator: std.mem.Allocator, configuration: Configuration) !void {
        try configuration.validate();
        self.* = .{};
        const search_capacity = configuration.maximum_search_nodes;
        const lookup_capacity = search_capacity * 2;
        self.x = try preallocated.alignedAlloc(i32, allocator, .@"64", search_capacity);
        self.y = try preallocated.alignedAlloc(i16, allocator, .@"64", search_capacity);
        self.z = try preallocated.alignedAlloc(i32, allocator, .@"64", search_capacity);
        self.node_type = try preallocated.alignedAlloc(NodeType, allocator, .@"64", search_capacity);
        self.penalty = try preallocated.alignedAlloc(f32, allocator, .@"64", search_capacity);
        self.heap_index = try preallocated.alignedAlloc(i16, allocator, .@"64", search_capacity);
        self.penalized_length = try preallocated.alignedAlloc(f32, allocator, .@"64", search_capacity);
        self.distance_to_target = try preallocated.alignedAlloc(f32, allocator, .@"64", search_capacity);
        self.heap_weight = try preallocated.alignedAlloc(f32, allocator, .@"64", search_capacity);
        self.previous = try preallocated.alignedAlloc(u16, allocator, .@"64", search_capacity);
        self.visited = try preallocated.alignedAlloc(bool, allocator, .@"64", search_capacity);
        self.classification_known = try preallocated.alignedAlloc(bool, allocator, .@"64", search_capacity);
        self.classification_passable = try preallocated.alignedAlloc(bool, allocator, .@"64", search_capacity);
        self.path_length = try preallocated.alignedAlloc(f32, allocator, .@"64", search_capacity);
        self.heap = try preallocated.alignedAlloc(u16, allocator, .@"64", search_capacity);
        self.lookup_node = try preallocated.alignedAlloc(u16, allocator, .@"64", lookup_capacity);
        self.lookup_epoch = try preallocated.alignedAlloc(u32, allocator, .@"64", lookup_capacity);
        self.search_capacity = search_capacity;
        self.lookup_capacity = lookup_capacity;
        @memset(self.lookup_epoch, 0);
    }

    pub fn findPath(
        self: *Search,
        context: anytype,
        paths: *Paths,
        entity: usize,
        start: Node,
        target: Node,
        target_distance: i32,
        max_distance: f32,
        max_iterations: usize,
    ) bool {
        std.debug.assert(entity < paths.length.len);
        std.debug.assert(max_iterations > 0);
        self.reset();
        paths.clear(entity);
        paths.target_x[entity] = target.x;
        paths.target_y[entity] = target.y;
        paths.target_z[entity] = target.z;

        const start_index = self.getOrCreate(start) orelse return false;
        self.penalized_length[start_index] = 0;
        self.distance_to_target[start_index] = distance(start, target);
        self.heap_weight[start_index] = self.distance_to_target[start_index];
        self.push(start_index);

        var nearest = start_index;
        var nearest_distance = self.distance_to_target[start_index];
        var reached = false;
        var iterations: usize = 0;
        while (self.heap_count != 0) {
            iterations += 1;
            if (iterations >= max_iterations) break;
            const current = self.pop();
            self.visited[current] = true;
            const current_node = self.node(current);
            const manhattan = manhattanDistance(current_node, target);
            if (manhattan <= @as(f32, @floatFromInt(target_distance))) {
                nearest = current;
                reached = true;
                break;
            }
            const current_target_distance = self.distance_to_target[current];
            if (current_target_distance < nearest_distance) {
                nearest = current;
                nearest_distance = current_target_distance;
            }
            if (distanceSquared(current_node, start) >= max_distance * max_distance) continue;
            self.relaxSuccessors(context, current, current_node, target, max_distance);
        }

        self.last_iterations = @intCast(iterations);
        self.writePath(paths, entity, nearest, reached);
        return paths.length[entity] != 0;
    }

    fn relaxSuccessors(self: *Search, context: anytype, current: u16, current_node: Node, target: Node, max_distance: f32) void {
        var successors: [8]Candidate = undefined;
        const successor_count = context.pathSuccessors(current_node, &successors);
        for (successors[0..successor_count]) |candidate| {
            if (!candidate.passable) continue;
            const successor = if (candidate.search_index != none)
                candidate.search_index
            else
                self.getOrCreate(candidate.node) orelse continue;
            if (self.visited[successor]) continue;
            const edge_distance = neighborDistance(current_node, candidate.node);
            self.path_length[successor] = self.path_length[current] + edge_distance;
            const penalized = self.penalized_length[current] + edge_distance + candidate.node.penalty;
            if (self.path_length[successor] >= max_distance) continue;
            if (self.heap_index[successor] >= 0 and penalized >= self.penalized_length[successor]) continue;
            self.previous[successor] = current;
            self.penalized_length[successor] = penalized;
            const heuristic_distance = distance(candidate.node, target);
            self.distance_to_target[successor] = heuristic_distance;
            const weight = penalized + heuristic_distance * @as(f32, 1.5);
            if (self.heap_index[successor] >= 0) {
                self.setWeight(successor, weight);
            } else {
                self.heap_weight[successor] = weight;
                self.push(successor);
            }
        }
    }

    pub fn classifyCached(self: *Search, context: anytype, value: Node) Candidate {
        const index = self.getOrCreate(value) orelse return context.classifyPathNode(value);
        if (self.classification_known[index]) return .{
            .node = self.node(index),
            .passable = self.classification_passable[index],
            .search_index = index,
        };
        const candidate = context.classifyPathNode(value);
        self.node_type[index] = candidate.node.node_type;
        self.penalty[index] = candidate.node.penalty;
        self.classification_known[index] = true;
        self.classification_passable[index] = candidate.passable;
        var cached = candidate;
        cached.search_index = index;
        return cached;
    }

    fn reset(self: *Search) void {
        self.count = 0;
        self.heap_count = 0;
        self.last_iterations = 0;
        self.epoch +%= 1;
        if (self.epoch == 0) {
            @memset(self.lookup_epoch, 0);
            self.epoch = 1;
        }
    }

    fn getOrCreate(self: *Search, value: Node) ?u16 {
        var slot = nodeHash(value) & (self.lookup_capacity - 1);
        for (0..self.lookup_capacity) |_| {
            if (self.lookup_epoch[slot] != self.epoch) break;
            const index = self.lookup_node[slot];
            if (self.x[index] == value.x and self.y[index] == value.y and self.z[index] == value.z) return index;
            slot = (slot + 1) & (self.lookup_capacity - 1);
        } else unreachable;
        std.debug.assert(self.lookup_epoch[slot] != self.epoch);
        if (self.count == self.search_capacity) return null;
        const index = self.count;
        self.count += 1;
        self.x[index] = value.x;
        self.y[index] = value.y;
        self.z[index] = value.z;
        self.node_type[index] = value.node_type;
        self.penalty[index] = value.penalty;
        self.heap_index[index] = -1;
        self.penalized_length[index] = 0;
        self.distance_to_target[index] = 0;
        self.heap_weight[index] = 0;
        self.previous[index] = none;
        self.visited[index] = false;
        self.classification_known[index] = false;
        self.classification_passable[index] = false;
        self.path_length[index] = 0;
        self.lookup_epoch[slot] = self.epoch;
        self.lookup_node[slot] = index;
        return index;
    }

    fn node(self: *const Search, index: u16) Node {
        return .{ .x = self.x[index], .y = self.y[index], .z = self.z[index], .node_type = self.node_type[index], .penalty = self.penalty[index] };
    }

    fn push(self: *Search, node_index: u16) void {
        std.debug.assert(self.heap_index[node_index] < 0);
        std.debug.assert(self.heap_count < self.search_capacity);
        const position = self.heap_count;
        self.heap_count += 1;
        self.heap[position] = node_index;
        self.heap_index[node_index] = @intCast(position);
        self.shiftUp(position);
    }

    fn pop(self: *Search) u16 {
        std.debug.assert(self.heap_count != 0);
        const result = self.heap[0];
        self.heap_count -= 1;
        if (self.heap_count != 0) {
            self.heap[0] = self.heap[self.heap_count];
            self.heap_index[self.heap[0]] = 0;
            self.shiftDown(0);
        }
        self.heap_index[result] = -1;
        return result;
    }

    fn setWeight(self: *Search, node_index: u16, weight: f32) void {
        const old = self.heap_weight[node_index];
        self.heap_weight[node_index] = weight;
        const at: u16 = @intCast(self.heap_index[node_index]);
        if (weight < old) self.shiftUp(at) else self.shiftDown(at);
    }

    fn shiftUp(self: *Search, initial: u16) void {
        var at = initial;
        const node_index = self.heap[at];
        const weight = self.heap_weight[node_index];
        while (at > 0) {
            const parent = (at - 1) >> 1;
            const parent_node = self.heap[parent];
            if (weight >= self.heap_weight[parent_node]) break;
            self.heap[at] = parent_node;
            self.heap_index[parent_node] = @intCast(at);
            at = parent;
        }
        self.heap[at] = node_index;
        self.heap_index[node_index] = @intCast(at);
    }

    fn shiftDown(self: *Search, initial: u16) void {
        var at = initial;
        const node_index = self.heap[at];
        const weight = self.heap_weight[node_index];
        for (0..self.heap_count) |_| {
            const left = 1 + (at << 1);
            if (left >= self.heap_count) break;
            const right = left + 1;
            const left_node = self.heap[left];
            const left_weight = self.heap_weight[left_node];
            const right_node = if (right < self.heap_count) self.heap[right] else left_node;
            const right_weight = if (right < self.heap_count) self.heap_weight[right_node] else std.math.inf(f32);
            const child = if (left_weight < right_weight) left else right;
            const child_node = self.heap[child];
            if (self.heap_weight[child_node] >= weight) break;
            self.heap[at] = child_node;
            self.heap_index[child_node] = @intCast(at);
            at = child;
        }
        self.heap[at] = node_index;
        self.heap_index[node_index] = @intCast(at);
    }

    fn writePath(self: *const Search, paths: *Paths, entity: usize, end: u16, reached: bool) void {
        var count: usize = 0;
        var cursor = end;
        while (count < paths.path_capacity) {
            count += 1;
            if (self.previous[cursor] == none) break;
            cursor = self.previous[cursor];
        }
        paths.length[entity] = @intCast(count);
        paths.current[entity] = 0;
        paths.reaches_target[entity] = reached;
        cursor = end;
        var path_index = count;
        while (path_index != 0) {
            path_index -= 1;
            const source = cursor;
            paths.xFor(entity)[path_index] = self.x[source];
            paths.yFor(entity)[path_index] = self.y[source];
            paths.zFor(entity)[path_index] = self.z[source];
            paths.nodeTypesFor(entity)[path_index] = self.node_type[source];
            paths.penaltiesFor(entity)[path_index] = self.penalty[source];
            if (self.previous[cursor] == none) break;
            cursor = self.previous[cursor];
        }
    }
};

pub fn distance(a: Node, b: Node) f32 {
    const dx: f32 = @floatFromInt(b.x - a.x);
    const dy: f32 = @floatFromInt(@as(i32, b.y) - @as(i32, a.y));
    const dz: f32 = @floatFromInt(b.z - a.z);
    return @sqrt(dx * dx + dy * dy + dz * dz);
}

pub fn distanceSquared(a: Node, b: Node) f32 {
    const dx: f32 = @floatFromInt(b.x - a.x);
    const dy: f32 = @floatFromInt(@as(i32, b.y) - @as(i32, a.y));
    const dz: f32 = @floatFromInt(b.z - a.z);
    return dx * dx + dy * dy + dz * dz;
}

fn neighborDistance(a: Node, b: Node) f32 {
    const dx = b.x - a.x;
    const dy = @as(i32, b.y) - @as(i32, a.y);
    const dz = b.z - a.z;
    const squared = dx * dx + dy * dy + dz * dz;
    return switch (squared) {
        1 => 1,
        2 => 1.41421356237,
        3 => 1.73205080757,
        4 => 2,
        5 => 2.2360679775,
        6 => 2.44948974278,
        9 => 3,
        10 => 3.16227766017,
        11 => 3.31662479036,
        else => @sqrt(@as(f32, @floatFromInt(squared))),
    };
}

pub fn manhattanDistance(a: Node, b: Node) f32 {
    return @floatFromInt(@abs(b.x - a.x) + @abs(@as(i32, b.y) - @as(i32, a.y)) + @abs(b.z - a.z));
}

fn nodeHash(node: Node) usize {
    var value: u64 = @bitCast(@as(i64, node.x));
    value *%= 0x9e3779b185ebca87;
    value ^= @bitCast(@as(i64, node.z));
    value *%= 0xc2b2ae3d27d4eb4f;
    value ^= @as(u16, @bitCast(node.y));
    return @intCast(value ^ (value >> 32));
}

const FlatGrid = struct {
    min: i32,
    max: i32,

    fn pathSuccessors(self: *const FlatGrid, current: Node, out: *[8]Candidate) usize {
        const offsets = [_][2]i32{ .{ 0, 1 }, .{ -1, 0 }, .{ 0, -1 }, .{ 1, 0 }, .{ -1, 1 }, .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 } };
        var count: usize = 0;
        for (offsets) |offset| {
            const x = current.x + offset[0];
            const z = current.z + offset[1];
            const passable = x >= self.min and x <= self.max and z >= self.min and z <= self.max;
            out[count] = .{ .node = .{ .x = x, .y = current.y, .z = z }, .passable = passable };
            count += 1;
        }
        return count;
    }
};

test "Vanilla successor order and heap ties produce a straight westward path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var search: Search = .{};
    var paths: Paths = .{};
    try search.allocate(arena.allocator(), .{});
    try paths.allocate(arena.allocator(), .{});
    const grid = FlatGrid{ .min = -16, .max = 16 };
    try std.testing.expect(search.findPath(&grid, &paths, 0, .{ .x = 10, .y = 64, .z = 0 }, .{ .x = 0, .y = 64, .z = 0 }, 0, 35, 560));
    try std.testing.expect(paths.reaches_target[0]);
    try std.testing.expectEqual(@as(u8, 11), paths.length[0]);
    for (0..paths.length[0]) |index| {
        try std.testing.expectEqual(@as(i32, 10) - @as(i32, @intCast(index)), paths.xFor(0)[index]);
        try std.testing.expectEqual(@as(i32, 0), paths.zFor(0)[index]);
    }
}

test "path search capacity failure remains bounded and allocation free" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var search: Search = .{};
    var paths: Paths = .{};
    try search.allocate(arena.allocator(), .{});
    try paths.allocate(arena.allocator(), .{});
    const grid = FlatGrid{ .min = -10000, .max = 10000 };
    try std.testing.expect(search.findPath(&grid, &paths, 0, .{ .x = 0, .y = 64, .z = 0 }, .{ .x = 10000, .y = 64, .z = 10000 }, 0, 35, 560));
    try std.testing.expect(!paths.reaches_target[0]);
    try std.testing.expect(search.count <= search.search_capacity);
}

test "path node classification is memoized for one search" {
    const Classifier = struct {
        calls: *usize,

        fn classifyPathNode(self: *@This(), node: Node) Candidate {
            self.calls.* += 1;
            return .{ .node = .{ .x = node.x, .y = node.y, .z = node.z, .node_type = .open, .penalty = 2 }, .passable = true };
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var search: Search = .{};
    try search.allocate(arena.allocator(), .{});
    var calls: usize = 0;
    var classifier = Classifier{ .calls = &calls };
    const node = Node{ .x = 7, .y = 64, .z = -3 };
    search.reset();
    const first = search.classifyCached(&classifier, node);
    const second = search.classifyCached(&classifier, node);
    try std.testing.expect(first.passable and second.passable);
    try std.testing.expectEqual(NodeType.open, second.node.node_type);
    try std.testing.expectEqual(@as(f32, 2), second.node.penalty);
    try std.testing.expectEqual(@as(usize, 1), calls);

    search.reset();
    _ = search.classifyCached(&classifier, node);
    try std.testing.expectEqual(@as(usize, 2), calls);
}
