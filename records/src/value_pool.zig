const std = @import("std");
const assert = std.debug.assert;

pub const Fixed = struct {
    pub fn slots(capacity: usize) !usize {
        return capacity;
    }

    pub fn bytes(capacity: usize, maximum: usize) !usize {
        return std.math.mul(usize, capacity, maximum);
    }

    pub fn init(_: std.mem.Allocator, _: usize, _: usize) !Fixed {
        return .{};
    }

    pub fn deinit(_: *Fixed, _: std.mem.Allocator) void {}

    pub fn reserve(_: *Fixed, _: usize, _: usize) bool {
        return true;
    }

    pub fn release(_: *Fixed, _: usize) void {}

    pub fn shrink(_: *Fixed, _: usize, _: usize) void {}

    pub fn buffer(_: *const Fixed, storage: []u8, maximum: usize, index: usize) []u8 {
        return storage[index * maximum ..][0..maximum];
    }
};

pub const Pool = struct {
    const leaves = 16;
    const levels = std.math.log2_int(usize, leaves) + 1;
    const nodes_per_root = 2 * leaves - 1;
    const absent = std.math.maxInt(usize);
    const State = enum(u8) { free, split, used };
    nodes: []State,
    blocks: []usize,
    available_roots: []usize,
    root_bytes: usize,
    used_bytes: usize = 0,
    peak_bytes: usize = 0,

    pub fn slots(capacity: usize) !usize {
        return std.math.mul(usize, capacity, leaves);
    }

    pub fn bytes(capacity: usize, maximum: usize) !usize {
        const quantum = leaves * 64;
        const root = try std.math.add(usize, maximum, quantum - 1);
        return std.math.mul(usize, capacity, root / quantum * quantum);
    }

    pub fn init(allocator: std.mem.Allocator, capacity: usize, maximum: usize) !Pool {
        const root_bytes = try bytes(1, maximum);
        const nodes = try allocator.alloc(State, try std.math.mul(usize, capacity, nodes_per_root));
        errdefer allocator.free(nodes);
        const blocks = try allocator.alloc(usize, try slots(capacity));
        errdefer allocator.free(blocks);
        const words = std.math.divCeil(usize, capacity, @bitSizeOf(usize)) catch unreachable;
        const available_roots = try allocator.alloc(usize, try std.math.mul(usize, words, levels));
        @memset(nodes, .free);
        @memset(blocks, absent);
        @memset(available_roots, 0);
        for (0..levels) |level| for (0..capacity) |root| {
            available_roots[level * words + root / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(root % @bitSizeOf(usize));
        };
        return .{ .nodes = nodes, .blocks = blocks, .available_roots = available_roots, .root_bytes = root_bytes };
    }

    pub fn deinit(self: *Pool, allocator: std.mem.Allocator) void {
        allocator.free(self.nodes);
        allocator.free(self.blocks);
        allocator.free(self.available_roots);
    }

    pub fn reserve(self: *Pool, index: usize, minimum: usize) bool {
        assert(minimum <= self.root_bytes);
        if (self.blocks[index] != absent) {
            if (self.blockBytes(self.blocks[index]) >= minimum) return true;
            self.release(index);
        }
        if (minimum == 0) return true;
        var level: usize = 0;
        var capacity = self.root_bytes / leaves;
        while (capacity < minimum) : (level += 1) capacity *= 2;
        assert(level < levels);
        const words = self.available_roots.len / levels;
        for (self.available_roots[level * words ..][0..words], 0..) |roots, word| {
            if (roots == 0) continue;
            const root = word * @bitSizeOf(usize) + @ctz(roots);
            const node = self.find(root * nodes_per_root, 0, self.root_bytes, minimum).?;
            assert(self.nodes[node] == .free);
            self.nodes[node] = .used;
            self.blocks[index] = node;
            self.used_bytes += self.blockBytes(node);
            self.peak_bytes = @max(self.peak_bytes, self.used_bytes);
            self.updateRoot(root);
            return true;
        }
        return false;
    }

    fn freeLevel(self: *const Pool, root: usize, node: usize, level: u3) u3 {
        assert(level > 0);
        return switch (self.nodes[root + node]) {
            .free => level,
            .used => 0,
            .split => @max(self.freeLevel(root, node * 2 + 1, level - 1), self.freeLevel(root, node * 2 + 2, level - 1)),
        };
    }

    fn updateRoot(self: *Pool, root: usize) void {
        const largest = self.freeLevel(root * nodes_per_root, 0, levels);
        const words = self.available_roots.len / levels;
        const mask = @as(usize, 1) << @intCast(root % @bitSizeOf(usize));
        for (0..levels) |level| {
            const word = &self.available_roots[level * words + root / @bitSizeOf(usize)];
            word.* = (word.* & ~mask) | (mask * @intFromBool(largest > level));
        }
    }

    fn find(self: *Pool, root: usize, node: usize, length: usize, minimum: usize) ?usize {
        const at = root + node;
        if (self.nodes[at] == .used) return null;
        if (node >= leaves - 1 or length / 2 < minimum) {
            return if (self.nodes[at] == .free) at else null;
        }
        if (self.find(root, node * 2 + 1, length / 2, minimum) orelse self.find(root, node * 2 + 2, length / 2, minimum)) |found| {
            self.nodes[at] = .split;
            return found;
        }
        return null;
    }

    fn blockBytes(self: *const Pool, node: usize) usize {
        const local = node % nodes_per_root;
        return self.root_bytes >> std.math.log2_int(usize, local + 1);
    }

    pub fn release(self: *Pool, index: usize) void {
        var node = self.blocks[index];
        if (node == absent) return;
        self.blocks[index] = absent;
        assert(self.nodes[node] == .used);
        self.used_bytes -= self.blockBytes(node);
        const root = node / nodes_per_root * nodes_per_root;
        self.nodes[node] = .free;
        while (node != root) {
            const parent = root + (node - root - 1) / 2;
            const left = root + (parent - root) * 2 + 1;
            if (self.nodes[left] != .free or self.nodes[left + 1] != .free) break;
            assert(self.nodes[parent] == .split);
            self.nodes[parent] = .free;
            node = parent;
        }
        self.updateRoot(root / nodes_per_root);
    }

    pub fn shrink(self: *Pool, index: usize, length: usize) void {
        if (length == 0) return self.release(index);
        var node = self.blocks[index];
        assert(node != absent and self.nodes[node] == .used);
        const root = node / nodes_per_root * nodes_per_root;
        var capacity = self.blockBytes(node);
        assert(length <= capacity);
        while (node - root < leaves - 1 and length <= capacity / 2) {
            self.nodes[node] = .split;
            self.used_bytes -= capacity / 2;
            node = root + (node - root) * 2 + 1;
            assert(self.nodes[node] == .free and self.nodes[node + 1] == .free);
            self.nodes[node] = .used;
            capacity /= 2;
        }
        self.blocks[index] = node;
        self.updateRoot(root / nodes_per_root);
    }

    pub fn buffer(self: *const Pool, storage: []u8, _: usize, index: usize) []u8 {
        const node = self.blocks[index];
        if (node == absent) return &.{};
        assert(self.nodes[node] == .used);
        const local = node % nodes_per_root;
        const level = std.math.log2_int(usize, local + 1);
        const length = self.root_bytes >> level;
        const first = (@as(usize, 1) << level) - 1;
        const offset = node / nodes_per_root * self.root_bytes + (local - first) * length;
        assert(offset % 64 == 0 and length >= 64);
        return storage[offset..][0..length];
    }
};
