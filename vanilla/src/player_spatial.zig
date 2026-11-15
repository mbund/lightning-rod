const BatchIndex = @import("lightning_rod").system.BatchIndex;
const std = @import("std");
const IndexSet = @import("lightning_rod").system.IndexSet;

const assert = std.debug.assert;

test "spatial windows preserve exact query membership and expire on every position change" {
    const Spatial = Grid(8);
    var spatial = try Spatial.init(std.testing.allocator, 257);
    defer spatial.deinit(std.testing.allocator);
    var random = std.Random.DefaultPrng.init(0x815c);
    for (0..257) |index| spatial.update(index, .{
        .world = @intCast(index % 3),
        .x = random.random().intRangeAtMost(i32, -96, 96),
        .z = random.random().intRangeAtMost(i32, -96, 96),
    });
    var members: [257]usize = undefined;
    const captured = spatial.window(.{ .world = 0, .x = -3, .z = 7 }, 64, &members);
    for ([_]i32{ 0, 1, 8, 32 }) |radius| for (0..128) |_| {
        const center: Spatial.Position = .{ .world = 0, .x = random.random().intRangeAtMost(i32, -35, 29), .z = random.random().intRangeAtMost(i32, -25, 39) };
        var direct = spatial.query(center, radius);
        var retained = captured.query(center, radius).?;
        var expected: [257]bool = @splat(false);
        while (direct.next()) |index| expected[index] = true;
        while (retained.next()) |index| {
            try std.testing.expect(expected[index]);
            expected[index] = false;
        }
        for (expected) |present| try std.testing.expect(!present);
        try std.testing.expectEqual(@as(usize, 0), retained.buckets);
    };
    try std.testing.expect(captured.query(.{ .world = 1, .x = -3, .z = 7 }, 1) == null);
    try std.testing.expect(captured.query(.{ .world = 0, .x = -3, .z = 7 }, 65) == null);
    spatial.update(0, .{ .world = 0, .x = 0, .z = 0 });
    const updated = spatial.window(.{ .world = 0, .x = 0, .z = 0 }, 32, &members);
    spatial.update(0, .{ .world = 0, .x = 1, .z = 0 });
    try std.testing.expect(updated.query(.{ .world = 0, .x = 0, .z = 0 }, 16) == null);
}

pub const Index = Grid(8);

pub fn Grid(comptime cell_width: i32) type {
    if (cell_width <= 0) @compileError("Spatial cell width must be positive");
    return struct {
        const Self = @This();
        const width = cell_width;
        pub const Position = struct { world: u32, x: i32, z: i32 };
        const Cell = Position;
        const absent = std.math.maxInt(usize);
        const Node = struct {
            position: ?Position = null,
            previous: ?usize = null,
            next: ?usize = null,
        };

        // Different spatial cells can share a hash bucket. Queries match the exact cell before yielding.
        heads: []usize = &.{},
        nodes: []Node = &.{},
        active: IndexSet = .{ .indices = &.{}, .positions = &.{} },
        revision: u64 = 0,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            if (capacity == 0) return .{};
            const nodes = try allocator.alloc(Node, capacity);
            errdefer allocator.free(nodes);
            @memset(nodes, .{});
            var active = try IndexSet.init(allocator, capacity);
            errdefer active.deinit(allocator);
            const buckets = try std.math.ceilPowerOfTwo(usize, try std.math.mul(usize, capacity, 2));
            const heads = try allocator.alloc(usize, buckets);
            @memset(heads, absent);
            return .{ .nodes = nodes, .active = active, .heads = heads };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.heads);
            if (self.nodes.len != 0) self.active.deinit(allocator);
            allocator.free(self.nodes);
            self.* = undefined;
        }

        pub fn contains(self: *const Self, index: usize) bool {
            assert(index < self.nodes.len);
            return self.nodes[index].position != null;
        }

        fn cell(position: Position) Cell {
            return .{ .world = position.world, .x = @divFloor(position.x, width), .z = @divFloor(position.z, width) };
        }

        fn bucket(self: *const Self, key: Cell) usize {
            assert(self.heads.len > 0 and std.math.isPowerOfTwo(self.heads.len));
            var hash = std.hash.Wyhash.init(0);
            std.hash.autoHash(&hash, key);
            return @intCast(hash.final() & (self.heads.len - 1));
        }

        /// Membership changes update links without moving other nodes.
        pub fn update(self: *Self, index: usize, position: ?Position) void {
            assert(index < self.nodes.len);
            const node = &self.nodes[index];
            if (std.meta.eql(node.position, position)) return;
            self.revision += 1;
            if (node.position) |old| {
                if (position) |next| if (std.meta.eql(cell(old), cell(next))) {
                    node.position = next;
                    return;
                };
                if (node.previous) |previous| {
                    assert(self.nodes[previous].next == index);
                    self.nodes[previous].next = node.next;
                } else {
                    const head = &self.heads[self.bucket(cell(old))];
                    assert(head.* == index);
                    head.* = node.next orelse absent;
                }
                if (node.next) |next| {
                    assert(self.nodes[next].previous == index);
                    self.nodes[next].previous = node.previous;
                }
                self.active.remove(index);
            }
            node.* = .{ .position = position };
            if (position) |next| {
                const head = &self.heads[self.bucket(cell(next))];
                if (head.* != absent) {
                    node.next = head.*;
                    assert(self.nodes[node.next.?].previous == null);
                    self.nodes[node.next.?].previous = index;
                }
                head.* = index;
                self.active.insert(index);
            }
            assert(self.active.contains(index) == (position != null));
        }

        /// Iterators borrow membership until the next update that changes a position.
        pub const Query = struct {
            owner: *const Self,
            revision: u64,
            world: u32,
            minimum: [2]i64,
            maximum: [2]i64,
            low: Cell,
            high: Cell,
            at: Cell,
            selected: Cell = undefined,
            current: ?usize = null,
            exhausted: bool = false,
            scan: bool,
            indices: []const usize = &.{},
            cursor: usize = 0,
            visited: usize = 0,
            buckets: usize = 0,

            pub fn next(self: *Query) ?usize {
                assert(self.owner.revision == self.revision);
                while (true) {
                    const index = if (self.scan) scan: {
                        if (self.cursor == self.indices.len) return null;
                        const index = self.indices[self.cursor];
                        self.cursor += 1;
                        break :scan index;
                    } else bucket: {
                        while (self.current == null) {
                            if (self.exhausted) return null;
                            const head = self.owner.heads[self.owner.bucket(self.at)];
                            self.current = if (head == absent) null else head;
                            self.selected = self.at;
                            self.buckets += 1;
                            if (self.at.z < self.high.z) {
                                self.at.z += 1;
                            } else if (self.at.x < self.high.x) {
                                self.at.x += 1;
                                self.at.z = self.low.z;
                            } else self.exhausted = true;
                        }
                        const index = self.current.?;
                        self.current = self.owner.nodes[index].next;
                        break :bucket index;
                    };
                    self.visited += 1;
                    const position = self.owner.nodes[index].position.?;
                    if (!self.scan and !std.meta.eql(cell(position), self.selected)) continue;
                    if (position.world == self.world and position.x >= self.minimum[0] and position.x <= self.maximum[0] and position.z >= self.minimum[1] and position.z <= self.maximum[1]) return index;
                }
            }
        };

        pub fn query(self: *const Self, center: Position, radius: i32) Query {
            assert(radius >= 0);
            const minimum: [2]i64 = .{ @as(i64, center.x) - radius, @as(i64, center.z) - radius };
            const maximum: [2]i64 = .{ @as(i64, center.x) + radius, @as(i64, center.z) + radius };
            const low = cell(.{ .world = center.world, .x = @intCast(@max(std.math.minInt(i32), minimum[0])), .z = @intCast(@max(std.math.minInt(i32), minimum[1])) });
            const high = cell(.{ .world = center.world, .x = @intCast(@min(std.math.maxInt(i32), maximum[0])), .z = @intCast(@min(std.math.maxInt(i32), maximum[1])) });
            const cells: u64 = @as(u64, @intCast(@as(i64, high.x) - low.x + 1)) * @as(u64, @intCast(@as(i64, high.z) - low.z + 1));
            const scan = cells >= self.active.count;
            return .{ .owner = self, .revision = self.revision, .world = center.world, .minimum = minimum, .maximum = maximum, .low = low, .high = high, .at = low, .scan = scan, .indices = if (scan) self.active.values() else &.{} };
        }

        pub const Window = struct {
            owner: *const Self,
            revision: u64,
            world: u32,
            minimum: [2]i64,
            maximum: [2]i64,
            indices: []const usize,

            pub fn query(self: Window, center: Position, radius: i32) ?Query {
                assert(radius >= 0);
                if (self.owner.revision != self.revision or self.world != center.world) return null;
                const minimum: [2]i64 = .{ @as(i64, center.x) - radius, @as(i64, center.z) - radius };
                const maximum: [2]i64 = .{ @as(i64, center.x) + radius, @as(i64, center.z) + radius };
                for (0..2) |axis| if (minimum[axis] < self.minimum[axis] or maximum[axis] > self.maximum[axis]) return null;
                return .{ .owner = self.owner, .revision = self.revision, .world = center.world, .minimum = minimum, .maximum = maximum, .scan = true, .indices = self.indices, .low = undefined, .high = undefined, .at = undefined };
            }
        };

        /// Members borrow output until it is reused. A position update invalidates the window.
        pub fn window(self: *const Self, center: Position, radius: i32, output: []usize) Window {
            assert(output.len >= self.active.count);
            var selected = self.query(center, radius);
            var count: usize = 0;
            while (selected.next()) |index| {
                assert(count < output.len);
                output[count] = index;
                count += 1;
            }
            return .{ .owner = self, .revision = self.revision, .world = center.world, .minimum = selected.minimum, .maximum = selected.maximum, .indices = output[0..count] };
        }
    };
}

pub const Groups = struct {
    const Group = struct { head: usize };
    entries: BatchIndex(Index.Position, Group, std.hash_map.AutoContext(Index.Position)),
    links: []?usize,
    indices: []usize,
    members: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Groups {
        var entries = try BatchIndex(Index.Position, Group, std.hash_map.AutoContext(Index.Position)).init(allocator, capacity);
        errdefer entries.deinit(allocator);
        const links = try allocator.alloc(?usize, capacity);
        errdefer allocator.free(links);
        const indices = try allocator.alloc(usize, capacity);
        return .{ .entries = entries, .links = links, .indices = indices };
    }

    pub fn deinit(self: *Groups, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        allocator.free(self.links);
        allocator.free(self.indices);
        self.* = undefined;
    }

    pub fn clear(self: *Groups) void {
        self.entries.clear();
        self.members = 0;
    }

    /// Add each slot once. Equal centers become adjacent in ordered().
    pub fn add(self: *Groups, index: usize, center: Index.Position) void {
        assert(index < self.links.len and self.members < self.indices.len);
        const entry = self.entries.getOrPut(center);
        self.links[index] = if (entry.found_existing) entry.value_ptr.head else null;
        entry.value_ptr.* = .{ .head = index };
        self.members += 1;
    }

    pub fn count(self: *const Groups) usize {
        return self.entries.count();
    }

    /// The order borrows this group until its next mutation.
    pub fn ordered(self: *Groups) []const usize {
        var length: usize = 0;
        for (self.entries.values()) |group| {
            var next: ?usize = group.head;
            while (next) |index| {
                assert(length < self.members);
                self.indices[length] = index;
                length += 1;
                next = self.links[index];
            }
        }
        assert(length == self.members);
        return self.indices[0..length];
    }
};

test "bucket membership matches exhaustive queries without allocating after init" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var index = try Index.init(allocator, 128);
    defer index.deinit(allocator);
    failing.fail_index = failing.alloc_index;
    var positions: [128]?Index.Position = @splat(null);
    var random = std.Random.DefaultPrng.init(20261026);
    for (0..4096) |step| {
        const slot = random.random().uintLessThan(usize, positions.len);
        positions[slot] = if (step % 5 == 0) null else .{
            .world = random.random().uintLessThan(u32, 3),
            .x = random.random().intRangeAtMost(i32, -256, 256),
            .z = random.random().intRangeAtMost(i32, -256, 256),
        };
        index.update(slot, positions[slot]);
        const center: Index.Position = .{ .world = random.random().uintLessThan(u32, 3), .x = random.random().intRangeAtMost(i32, -256, 256), .z = random.random().intRangeAtMost(i32, -256, 256) };
        const radius = random.random().intRangeAtMost(i32, 0, 512);
        var expected: [128]bool = @splat(false);
        for (positions, 0..) |entry, at| if (entry) |position| {
            expected[at] = position.world == center.world and @abs(position.x - center.x) <= radius and @abs(position.z - center.z) <= radius;
        };
        var actual: [128]bool = @splat(false);
        var query = index.query(center, radius);
        while (query.next()) |at| {
            try std.testing.expect(!actual[at]);
            actual[at] = true;
        }
        try std.testing.expectEqualSlices(bool, &expected, &actual);
    }
}

test "full buckets retain immediate membership through shared movement and slot reuse" {
    var index = try Index.init(std.testing.allocator, 1024);
    defer index.deinit(std.testing.allocator);
    for (0..1024) |slot| index.update(slot, .{ .world = 1, .x = 7, .z = -1 });
    for (0..1024) |slot| {
        index.update(slot, .{ .world = 1, .x = 8, .z = 0 });
        var previous = index.query(.{ .world = 1, .x = 7, .z = -1 }, 0);
        var next = index.query(.{ .world = 1, .x = 8, .z = 0 }, 0);
        var counts: [2]usize = @splat(0);
        while (previous.next()) |_| counts[0] += 1;
        while (next.next()) |_| counts[1] += 1;
        try std.testing.expectEqual(1023 - slot, counts[0]);
        try std.testing.expectEqual(slot + 1, counts[1]);
    }
    for (0..1024) |slot| index.update(slot, null);
    for (index.heads) |head| try std.testing.expectEqual(Index.absent, head);
    for (0..1024) |slot| index.update(slot, .{ .world = 2, .x = @intCast(slot * 8), .z = 0 });
    try std.testing.expectEqual(@as(usize, 1024), index.active.count);
    var query = index.query(.{ .world = 2, .x = 800, .z = 0 }, 0);
    try std.testing.expectEqual(@as(usize, 100), query.next().?);
    try std.testing.expectEqual(null, query.next());
    try std.testing.expect(query.visited <= 8);
}

test "queries clip safely at coordinate limits and support an empty index" {
    var index = try Index.init(std.testing.allocator, 2);
    defer index.deinit(std.testing.allocator);
    const left: Index.Position = .{ .world = 0, .x = std.math.minInt(i32), .z = std.math.maxInt(i32) };
    const right: Index.Position = .{ .world = 0, .x = std.math.maxInt(i32), .z = std.math.minInt(i32) };
    index.update(0, left);
    index.update(1, right);
    var query = index.query(left, std.math.maxInt(i32));
    try std.testing.expectEqual(@as(usize, 0), query.next().?);
    try std.testing.expectEqual(null, query.next());
    var empty = try Index.init(std.testing.allocator, 0);
    defer empty.deinit(std.testing.allocator);
    query = empty.query(right, 0);
    try std.testing.expectEqual(null, query.next());
}

pub fn benchmark() !void {
    const io = std.testing.io;
    var buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &buffer);
    for ([_]usize{ 32, 256, 1024, 4096 }) |count| {
        var index = try Index.init(std.testing.allocator, count);
        defer index.deinit(std.testing.allocator);
        for (0..count) |slot| index.update(slot, .{ .world = 0, .x = 7, .z = 0 });
        const before = index.revision;
        for (0..count) |slot| index.update(slot, .{ .world = 0, .x = 8, .z = 0 });
        try std.testing.expectEqual(count, index.revision - before);
        var query = index.query(.{ .world = 0, .x = 7, .z = 0 }, 0);
        try std.testing.expectEqual(null, query.next());
        query = index.query(.{ .world = 0, .x = 8, .z = 0 }, 0);
        var found: usize = 0;
        while (query.next()) |_| found += 1;
        try std.testing.expectEqual(count, found);
        try output.interface.print("spatial clustered_players={d} member_updates={d} shifted_indices=0\n", .{ count, index.revision - before });
    }
    const streaming = try streamingGrids();
    try output.interface.print("spatial separated_players=32 horizon_radius=32 queries=4128 small_cell_visits={d} horizon_cell_visits={d}\n", .{ streaming[0], streaming[1] });
    try output.interface.flush();
}

test "streaming grids preserve exhaustive audiences across horizon boundaries" {
    _ = try streamingGrids();
}

fn streamingGrids() ![2]usize {
    const count = 32;
    const radius = 32;
    var visited: [2]usize = @splat(0);
    inline for (.{ 8, 64 }, 0..) |width, mode| {
        var bounded = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var index = try Grid(width).init(bounded.allocator(), count);
        defer index.deinit(bounded.allocator());
        bounded.fail_index = bounded.alloc_index;
        for (0..count) |player| index.update(player, .{ .world = @intCast(player % 3), .x = @as(i32, @intCast(player % 8)) * 128 - 448, .z = @as(i32, @intCast(player / 8)) * 128 - 192 });
        for (0..count) |player| for (0..129) |offset| {
            const center: Grid(width).Position = .{ .world = @intCast(player % 3), .x = @as(i32, @intCast(player % 8)) * 128 - 512 + @as(i32, @intCast(offset)), .z = @as(i32, @intCast(player / 8)) * 128 - 192 };
            var expected: [count]bool = @splat(false);
            for (index.nodes, 0..) |node, slot| {
                const position = node.position.?;
                expected[slot] = position.world == center.world and @abs(position.x - center.x) <= radius and @abs(position.z - center.z) <= radius;
            }
            var actual: [count]bool = @splat(false);
            var query = index.query(center, radius);
            while (query.next()) |slot| {
                try std.testing.expect(!actual[slot]);
                actual[slot] = true;
            }
            try std.testing.expectEqualSlices(bool, &expected, &actual);
            visited[mode] += query.visited;
        };
        try std.testing.expect(!bounded.has_induced_failure);
    }
    try std.testing.expectEqual(@as(usize, count * count * 129), visited[0]);
    try std.testing.expect(visited[1] < visited[0] / 4);
    return visited;
}

test "colliding hash buckets preserve exact cells without duplicate recipients" {
    var index = try Index.init(std.testing.allocator, 64);
    defer index.deinit(std.testing.allocator);
    const origin: Index.Position = .{ .world = 1, .x = 0, .z = 0 };
    var collision = origin;
    while (true) {
        collision.x += Index.width;
        if (index.bucket(Index.cell(collision)) == index.bucket(Index.cell(origin))) break;
    }
    var other = origin;
    while (index.bucket(Index.cell(other)) == index.bucket(Index.cell(origin))) other.z += Index.width;
    for (0..64) |slot| index.update(slot, other);
    index.update(0, origin);
    index.update(1, collision);
    var query = index.query(origin, 0);
    try std.testing.expect(!query.scan);
    try std.testing.expectEqual(@as(usize, 0), query.next().?);
    try std.testing.expectEqual(null, query.next());
    try std.testing.expectEqual(@as(usize, 2), query.visited);
    query = index.query(collision, 0);
    try std.testing.expectEqual(@as(usize, 1), query.next().?);
    try std.testing.expectEqual(null, query.next());
    index.update(0, null);
    query = index.query(collision, 0);
    try std.testing.expectEqual(@as(usize, 1), query.next().?);
    try std.testing.expectEqual(null, query.next());
}

test "spatial groups retain every slot and keep equal centers adjacent without allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var groups = try Groups.init(allocator, 257);
    defer groups.deinit(allocator);
    failing.fail_index = failing.alloc_index;
    for (0..3) |pattern| for ([_]usize{ 0, 1, 17, 257 }) |length| {
        groups.clear();
        var positions: [257]Index.Position = undefined;
        for (0..length) |offset| {
            const index = offset * 73 % 257;
            positions[index] = .{ .world = @intCast(if (pattern == 0) 0 else index % 3), .x = if (pattern == 2) @as(i32, @intCast(index)) - 128 else -1, .z = 0 };
            groups.add(index, positions[index]);
        }
        const ordered = groups.ordered();
        try std.testing.expectEqual(length, ordered.len);
        var seen: [257]bool = @splat(false);
        var distinct: usize = 0;
        for (ordered, 0..) |index, at| {
            try std.testing.expect(!seen[index]);
            seen[index] = true;
            if (at != 0 and std.meta.eql(positions[ordered[at - 1]], positions[index])) continue;
            distinct += 1;
            for (ordered[0..at]) |previous| try std.testing.expect(!std.meta.eql(positions[previous], positions[index]));
        }
        try std.testing.expectEqual(distinct, groups.count());
    };
}
