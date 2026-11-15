const std = @import("std");

const assert = std.debug.assert;

pub const Resident = struct {
    id: u64 = 0,
    world: u32 = 0,
    x: i32 = 0,
    z: i32 = 0,
    y: i32 = 0,
    alive: bool = false,
    position: [2]f64 = @splat(0),
};

pub const Index = struct {
    const Node = struct {
        parent: ?u32 = null,
        children: [2]?u32 = .{ null, null },
        height: u8 = 1,
        indexed: bool = false,
    };

    residents: []const Resident,
    nodes: []Node,
    root: ?u32 = null,
    count: usize = 0,
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, residents: []const Resident) !Index {
        assert(residents.len > 0 and residents.len <= 65536);
        const nodes = try allocator.alloc(Node, residents.len);
        @memset(nodes, .{});
        return .{ .residents = residents, .nodes = nodes };
    }

    pub fn less(a: Resident, b: Resident) bool {
        inline for (.{ "world", "x", "z", "y", "id" }) |field| {
            if (@field(a, field) != @field(b, field)) return @field(a, field) < @field(b, field);
        }
        return false;
    }

    pub fn lowerBound(self: *const Index, value: Resident) ?u32 {
        var current = self.root;
        var found: ?u32 = null;
        while (current) |index| {
            if (less(self.residents[index], value)) {
                current = self.nodes[index].children[1];
            } else {
                found = index;
                current = self.nodes[index].children[0];
            }
        }
        return found;
    }

    pub fn next(self: *const Index, index: u32) ?u32 {
        assert(self.nodes[index].indexed);
        if (self.nodes[index].children[1]) |right| return self.minimum(right);
        var child = index;
        var parent = self.nodes[child].parent;
        while (parent) |at| {
            if (self.nodes[at].children[0] == child) return at;
            assert(self.nodes[at].children[1] == child);
            child = at;
            parent = self.nodes[at].parent;
        }
        return null;
    }

    pub const Rectangle = struct {
        index: *const Index,
        world: u32,
        x: i32,
        minimum_z: i32,
        maximum: [2]i32,
        current: ?u32,

        pub fn next(self: *Rectangle) ?u32 {
            while (self.current) |slot| {
                const entry = self.index.residents[slot];
                if (entry.world != self.world or entry.x > self.maximum[0]) {
                    self.current = null;
                    return null;
                }
                if (entry.x != self.x) {
                    assert(entry.x > self.x);
                    self.x = entry.x;
                    self.current = self.index.lowerBound(.{ .world = self.world, .x = self.x, .z = self.minimum_z, .y = std.math.minInt(i32) });
                    continue;
                }
                if (entry.z > self.maximum[1]) {
                    if (self.x == self.maximum[0]) {
                        self.current = null;
                        return null;
                    }
                    self.x += 1;
                    self.current = self.index.lowerBound(.{ .world = self.world, .x = self.x, .z = self.minimum_z, .y = std.math.minInt(i32) });
                    continue;
                }
                assert(entry.alive and entry.z >= self.minimum_z);
                self.current = self.index.next(slot);
                return slot;
            }
            return null;
        }
    };

    /// Index links and resident keys must remain unchanged throughout iteration.
    pub fn rectangle(self: *const Index, world: u32, low: [2]i32, high: [2]i32) Rectangle {
        assert(low[0] <= high[0] and low[1] <= high[1]);
        return .{
            .index = self,
            .world = world,
            .x = low[0],
            .minimum_z = low[1],
            .maximum = high,
            .current = self.lowerBound(.{ .world = world, .x = low[0], .z = low[1], .y = std.math.minInt(i32) }),
        };
    }

    // Remove a resident before changing its key. Reinsert after publishing the new key.
    pub fn insert(self: *Index, index: u32) void {
        const node = &self.nodes[index];
        assert(self.residents[index].alive and !node.indexed);
        assert(node.parent == null and node.children[0] == null and node.children[1] == null);
        assert(self.count < self.nodes.len);
        var parent: ?u32 = null;
        var current = self.root;
        var side: usize = 0;
        while (current) |at| {
            assert(self.residents[at].id != self.residents[index].id);
            parent = at;
            side = @intFromBool(!less(self.residents[index], self.residents[at]));
            current = self.nodes[at].children[side];
        }
        node.* = .{ .parent = parent, .indexed = true };
        if (parent) |at| self.nodes[at].children[side] = index else self.root = index;
        self.count += 1;
        self.revision += 1;
        self.balance(parent);
        assert(node.indexed and self.root != null);
    }

    pub fn remove(self: *Index, index: u32) void {
        const node = &self.nodes[index];
        assert(node.indexed and self.residents[index].alive and self.count > 0);
        var changed = node.parent;
        if (node.children[0] == null or node.children[1] == null) {
            self.replace(index, node.children[@intFromBool(node.children[0] == null)]);
        } else {
            const successor = self.minimum(node.children[1].?);
            if (self.nodes[successor].parent != index) {
                changed = self.nodes[successor].parent;
                self.replace(successor, self.nodes[successor].children[1]);
                self.nodes[successor].children[1] = node.children[1];
                self.nodes[node.children[1].?].parent = successor;
            } else changed = successor;
            self.replace(index, successor);
            self.nodes[successor].children[0] = node.children[0];
            self.nodes[node.children[0].?].parent = successor;
        }
        node.* = .{};
        self.count -= 1;
        self.revision += 1;
        self.balance(changed);
        assert(!node.indexed and (self.root == null) == (self.count == 0));
    }

    fn height(self: *const Index, index: ?u32) u8 {
        return if (index) |at| self.nodes[at].height else 0;
    }

    fn refresh(self: *Index, index: u32) void {
        const node = &self.nodes[index];
        assert(node.indexed);
        node.height = 1 + @max(self.height(node.children[0]), self.height(node.children[1]));
        assert(node.height <= 32);
    }

    fn replace(self: *Index, index: u32, replacement: ?u32) void {
        const parent = self.nodes[index].parent;
        if (parent) |at| {
            const side: usize = @intFromBool(self.nodes[at].children[1] == index);
            assert(self.nodes[at].children[side] == index);
            self.nodes[at].children[side] = replacement;
        } else {
            assert(self.root == index);
            self.root = replacement;
        }
        if (replacement) |at| self.nodes[at].parent = parent;
    }

    fn rotate(self: *Index, index: u32, side: u1) u32 {
        const pivot = self.nodes[index].children[side ^ 1].?;
        self.replace(index, pivot);
        self.nodes[index].children[side ^ 1] = self.nodes[pivot].children[side];
        if (self.nodes[pivot].children[side]) |child| self.nodes[child].parent = index;
        self.nodes[pivot].children[side] = index;
        self.nodes[index].parent = pivot;
        self.refresh(index);
        self.refresh(pivot);
        return pivot;
    }

    fn balance(self: *Index, changed: ?u32) void {
        var current = changed;
        while (current) |index| {
            self.refresh(index);
            const children = self.nodes[index].children;
            var root = index;
            if (self.height(children[0]) > self.height(children[1]) + 1) {
                const left = children[0].?;
                if (self.height(self.nodes[left].children[1]) > self.height(self.nodes[left].children[0])) _ = self.rotate(left, 0);
                root = self.rotate(index, 1);
            } else if (self.height(children[1]) > self.height(children[0]) + 1) {
                const right = children[1].?;
                if (self.height(self.nodes[right].children[0]) > self.height(self.nodes[right].children[1])) _ = self.rotate(right, 1);
                root = self.rotate(index, 0);
            }
            current = self.nodes[root].parent;
        }
    }

    fn minimum(self: *const Index, root: u32) u32 {
        var index = root;
        while (self.nodes[index].children[0]) |left| index = left;
        return index;
    }
};
