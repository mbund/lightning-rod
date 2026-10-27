const std = @import("std");
const sparse_sets = @import("sparse_sets.zig");
const assert = std.debug.assert;
const width = @bitSizeOf(usize);
const Shift = std.math.Log2Int(usize);
const vector_words = std.simd.suggestVectorLength(usize) orelse 1;
const vector_minimum_words = 32;

// Independent blocks give dense and sparse views the same hash without visiting absent words.
pub const hash_block_words = 32;

pub fn hashBlock(start: usize, words: []const usize) u64 {
    var first: usize = 0;
    var end = words.len;
    while (first < end and words[first] == 0) first += 1;
    while (end > first and words[end - 1] == 0) end -= 1;
    if (first == end) return 0;
    return std.hash.Wyhash.hash(start + first, std.mem.sliceAsBytes(words[first..end]));
}

fn hashDense(words: []const usize) u64 {
    var value: u64 = 0;
    var start: usize = 0;
    while (start < words.len) {
        const count = @min(hash_block_words, words.len - start);
        value ^= hashBlock(start, words[start..][0..count]);
        start += count;
    }
    return value;
}

pub const Selection = union(enum) {
    all,
    players: Set,

    pub fn contains(self: Selection, index: usize) bool {
        return switch (self) {
            .all => true,
            .players => |set| set.contains(index),
        };
    }
};

pub const Set = struct {
    words: []const usize,
    capacity: usize,
    sparse: ?sparse_sets.View = null,

    pub fn wordAt(self: Set, index: usize) usize {
        if (self.sparse) |view| return view.wordAt(index);
        return self.words[index];
    }

    pub fn hash(self: Set) u64 {
        if (self.sparse) |view| return view.hash();
        return hashDense(self.words);
    }

    pub const HashContext = struct {
        pub fn hash(_: @This(), set: Set) u64 {
            return set.hash();
        }
        pub fn eql(_: @This(), a: Set, b: Set) bool {
            return a.eql(b);
        }
    };

    pub fn contains(self: Set, index: usize) bool {
        assert(index < self.capacity);
        return self.wordAt(index / width) & (@as(usize, 1) << @as(Shift, @intCast(index % width))) != 0;
    }

    pub fn any(self: Set) bool {
        if (self.sparse) |view| return view.count() != 0;
        for (self.words) |word| if (word != 0) return true;
        return false;
    }

    pub fn count(self: Set) usize {
        if (self.sparse) |view| return view.count();
        var total: usize = 0;
        for (self.words) |word| total += @popCount(word);
        return total;
    }

    pub fn eql(self: Set, other: Set) bool {
        assert(self.capacity == other.capacity);
        if (self.sparse == null and other.sparse == null) return std.mem.eql(usize, self.words, other.words);
        if (self.sparse) |a| if (other.sparse) |b| {
            if (a.count() != b.count()) return false;
            if (a.pool.rows[a.index].inverted == b.pool.rows[b.index].inverted) {
                var left = a.iterator();
                var right = b.iterator();
                while (left.next()) |word| {
                    const next = right.next() orelse return false;
                    if (word.index != next.index or word.value != next.value) return false;
                }
                return right.next() == null;
            }
        };
        var left = self.wordIterator();
        var right = other.wordIterator();
        while (left.next()) |word| {
            const next = right.next() orelse return false;
            if (word.index != next.index or word.value != next.value) return false;
        }
        if (right.next() != null) return false;
        return true;
    }

    pub fn intersects(self: Set, other: Set) bool {
        assert(self.capacity == other.capacity);
        if (self.sparse == null and other.sparse == null) {
            assert(self.words.len == other.words.len);
            var at: usize = 0;
            if (comptime vector_words > 1) {
                if (self.words.len >= vector_minimum_words) {
                    if (self.words[0] & other.words[0] != 0) return true;
                    at = 1;
                    while (self.words.len - at >= vector_words) : (at += vector_words) {
                        const left: @Vector(vector_words, usize) = self.words[at..][0..vector_words].*;
                        const right: @Vector(vector_words, usize) = other.words[at..][0..vector_words].*;
                        if (@reduce(.Or, left & right != @as(@Vector(vector_words, usize), @splat(0)))) return true;
                    }
                }
            }
            for (self.words[at..], other.words[at..]) |left, right| if (left & right != 0) return true;
            return false;
        }
        if (self.sparse != null and other.sparse != null) {
            if (self.count() > self.capacity - other.count()) return true;
        }
        const left = if (self.sparse) |view| !view.pool.rows[view.index].inverted else false;
        var selected = (if (left) self else other).wordIterator();
        const opposite = if (left) other else self;
        while (selected.next()) |word| if (word.value & opposite.wordAt(word.index) != 0) return true;
        return false;
    }

    pub fn includes(self: Set, other: Set) bool {
        assert(self.capacity == other.capacity);
        if (self.sparse == null and other.sparse == null) {
            assert(self.words.len == other.words.len);
            var at: usize = 0;
            if (comptime vector_words > 1) {
                if (self.words.len >= vector_minimum_words) {
                    while (self.words.len - at >= vector_words) : (at += vector_words) {
                        const left: @Vector(vector_words, usize) = self.words[at..][0..vector_words].*;
                        const right: @Vector(vector_words, usize) = other.words[at..][0..vector_words].*;
                        if (@reduce(.Or, (left & right) != right)) return false;
                    }
                }
            }
            for (self.words[at..], other.words[at..]) |left, right| if (left & right != right) return false;
            return true;
        }
        if (self.sparse != null and other.sparse != null) {
            if (other.count() == 0) return true;
            if (self.count() < other.count()) return false;
        }
        if (self.sparse) |view| if (view.pool.rows[view.index].inverted) {
            var exceptions = view.iterator();
            while (exceptions.next()) |word| if (other.wordAt(word.index) & ~word.value != 0) return false;
            return true;
        };
        var required = other.wordIterator();
        while (required.next()) |word| if (self.wordAt(word.index) & word.value != word.value) return false;
        return true;
    }

    pub const Word = struct { index: usize, value: usize };
    pub const WordIterator = struct {
        set: Set,
        index: usize = 0,
        sparse_words: ?sparse_sets.WordIterator = null,

        pub fn next(self: *WordIterator) ?Word {
            if (self.set.sparse) |view| if (!view.pool.rows[view.index].inverted) {
                if (self.sparse_words == null) self.sparse_words = view.iterator();
                const word = self.sparse_words.?.next() orelse return null;
                assert(word.value != 0);
                return .{ .index = word.index, .value = word.value };
            };
            const length = self.set.capacity / width + @intFromBool(self.set.capacity % width != 0);
            while (self.index < length) {
                const index = self.index;
                self.index += 1;
                const value = self.set.wordAt(index);
                if (value != 0) return .{ .index = index, .value = value };
            }
            return null;
        }
    };

    pub fn wordIterator(self: Set) WordIterator {
        return .{ .set = self };
    }

    pub fn iterator(self: Set) Iterator {
        return .{ .set = self };
    }

    pub fn firstFrom(self: Set, start: usize) ?usize {
        if (start >= self.capacity) return null;
        if (self.sparse) |view| if (!view.pool.rows[view.index].inverted) {
            var words = self.wordIterator();
            while (words.next()) |word| {
                if (word.index < start / width) continue;
                const bits = if (word.index == start / width) word.value & (@as(usize, std.math.maxInt(usize)) << @as(Shift, @intCast(start % width))) else word.value;
                if (bits != 0) return word.index * width + @ctz(bits);
            }
            return null;
        };
        var word = start / width;
        var pending = self.wordAt(word) & (@as(usize, std.math.maxInt(usize)) << @as(Shift, @intCast(start % width)));
        while (pending == 0) {
            word += 1;
            if (word == self.capacity / width + @intFromBool(self.capacity % width != 0)) return null;
            pending = self.wordAt(word);
        }
        const index = word * width + @ctz(pending);
        assert(index < self.capacity);
        return index;
    }

    pub const Iterator = struct {
        set: Set,
        word: usize = 0,
        pending: usize = 0,
        sparse_words: ?sparse_sets.WordIterator = null,

        pub fn next(self: *Iterator) ?usize {
            if (self.set.sparse) |view| if (!view.pool.rows[view.index].inverted) {
                if (self.sparse_words == null) self.sparse_words = view.iterator();
                while (self.pending == 0) {
                    const word = self.sparse_words.?.next() orelse return null;
                    self.word = word.index + 1;
                    self.pending = word.value;
                }
                const index = (self.word - 1) * width + @ctz(self.pending);
                self.pending &= self.pending - 1;
                assert(index < self.set.capacity);
                return index;
            };
            while (self.pending == 0) {
                if (self.word == self.set.capacity / width + @intFromBool(self.set.capacity % width != 0)) return null;
                self.pending = self.set.wordAt(self.word);
                self.word += 1;
            }
            const index = (self.word - 1) * width + @ctz(self.pending);
            self.pending &= self.pending - 1;
            assert(index < self.set.capacity);
            return index;
        }
    };
};

/// A borrowed row. Copies refer to the same storage.
pub const Row = struct {
    words: []usize = &.{},
    capacity: usize = 0,

    pub fn workspace(self: Row) sparse_sets.Workspace.RowView {
        return .{ .storage = .{ .dense = self } };
    }

    pub fn view(self: Row) Set {
        return .{ .words = self.words, .capacity = self.capacity };
    }

    pub fn clear(self: Row) void {
        if (self.words.len == 0) return;
        self.words[0] = 0;
        if (self.words.len > 1) @memset(self.words[1..], 0);
    }

    pub fn fill(self: Row) void {
        @memset(self.words, std.math.maxInt(usize));
        if (self.capacity % width != 0) self.words[self.words.len - 1] >>= @as(Shift, @intCast(width - self.capacity % width));
    }

    pub fn insert(self: Row, index: usize) void {
        assert(index < self.capacity);
        self.words[index / width] |= @as(usize, 1) << @as(Shift, @intCast(index % width));
        assert(self.view().contains(index));
    }

    pub fn remove(self: Row, index: usize) void {
        assert(index < self.capacity);
        self.words[index / width] &= ~(@as(usize, 1) << @as(Shift, @intCast(index % width)));
        assert(!self.view().contains(index));
    }

    pub fn toggle(self: Row, index: usize) void {
        assert(index < self.capacity);
        self.words[index / width] ^= @as(usize, 1) << @as(Shift, @intCast(index % width));
    }

    pub fn copy(self: Row, source: Set) void {
        assert(self.capacity == source.capacity);
        if (source.sparse != null) {
            for (self.words, 0..) |*word, index| word.* = source.wordAt(index);
            return;
        }
        assert(self.words.len == source.words.len);
        if (self.words.ptr == source.words.ptr or self.words.len == 0) return;
        self.words[0] = source.words[0];
        if (self.words.len > 1) @memcpy(self.words[1..], source.words[1..]);
    }

    pub fn unite(self: Row, a: Set, b: Set) void {
        assert(self.capacity == a.capacity and self.capacity == b.capacity);
        if (a.sparse == null and b.sparse == null) {
            for (self.words, a.words, b.words) |*out, left, right| out.* = left | right;
        } else for (self.words, 0..) |*out, index| out.* = a.wordAt(index) | b.wordAt(index);
    }

    pub fn intersect(self: Row, a: Set, b: Set) void {
        assert(self.capacity == a.capacity and self.capacity == b.capacity);
        if (a.sparse == null and b.sparse == null) {
            for (self.words, a.words, b.words) |*out, left, right| out.* = left & right;
        } else for (self.words, 0..) |*out, index| out.* = a.wordAt(index) & b.wordAt(index);
    }

    pub fn subtract(self: Row, a: Set, b: Set) void {
        assert(self.capacity == a.capacity and self.capacity == b.capacity);
        if (a.sparse == null and b.sparse == null) {
            for (self.words, a.words, b.words) |*out, left, right| out.* = left & ~right;
        } else for (self.words, 0..) |*out, index| out.* = a.wordAt(index) & ~b.wordAt(index);
    }

    pub fn difference(self: Row, a: Set, b: Set) void {
        assert(self.capacity == a.capacity and self.capacity == b.capacity);
        if (a.sparse == null and b.sparse == null) {
            for (self.words, a.words, b.words) |*out, left, right| out.* = left ^ right;
        } else for (self.words, 0..) |*out, index| out.* = a.wordAt(index) ^ b.wordAt(index);
    }
};

pub const Matrix = struct {
    words: []usize,
    rows: []Row,
    capacity: usize,

    pub fn init(allocator: std.mem.Allocator, rows: usize, capacity: usize) !Matrix {
        const stride = capacity / width + @intFromBool(capacity % width != 0);
        const length = std.math.mul(usize, rows, stride) catch return error.OutOfMemory;
        const words = try allocator.alloc(usize, length);
        errdefer allocator.free(words);
        @memset(words, 0);
        const views = try allocator.alloc(Row, rows);
        for (views, 0..) |*view, index| view.* = .{ .words = words[index * stride ..][0..stride], .capacity = capacity };
        return .{ .words = words, .rows = views, .capacity = capacity };
    }

    pub fn deinit(self: *Matrix, allocator: std.mem.Allocator) void {
        allocator.free(self.rows);
        allocator.free(self.words);
        self.* = undefined;
    }

    pub fn row(self: Matrix, index: usize) Row {
        assert(index < self.rows.len);
        return self.rows[index];
    }
};

test "sets cross machine words and the former player and connection limits" {
    var sets = try Matrix.init(std.testing.allocator, 3, 65_537);
    defer sets.deinit(std.testing.allocator);
    const a = sets.row(0);
    const b = sets.row(1);
    const result = sets.row(2);
    for ([_]usize{ 0, width - 1, width, 255, 256, 65_535, 65_536 }) |index| a.insert(index);
    b.insert(256);
    b.insert(65_536);
    result.subtract(a.view(), b.view());
    var iterator = result.view().iterator();
    for ([_]usize{ 0, width - 1, width, 255, 65_535 }) |expected| try std.testing.expectEqual(expected, iterator.next().?);
    try std.testing.expectEqual(null, iterator.next());
    result.fill();
    try std.testing.expectEqual(@as(usize, 65_537), result.view().count());
    result.intersect(result.view(), a.view());
    try std.testing.expect(result.view().eql(a.view()));
    a.clear();
    try std.testing.expect(!a.view().any());
    try std.testing.expectEqual(@as(usize, 7), result.view().count());
}

test "dense predicates preserve scalar boundaries vector boundaries and partial words" {
    for ([_]usize{ 0, 1, 7, 8, 31, 32, 33, 63, 64, 65, 1025 }) |words| {
        const capacity = if (words == 0) 0 else words * width - 3;
        var matrix = try Matrix.init(std.testing.allocator, 2, capacity);
        defer matrix.deinit(std.testing.allocator);
        const a = matrix.row(0);
        const b = matrix.row(1);
        try std.testing.expect(a.view().includes(b.view()));
        try std.testing.expect(!a.view().intersects(b.view()));
        if (capacity == 0) continue;
        for ([_]usize{ 0, capacity / 2, capacity - 1 }) |index| {
            a.clear();
            b.clear();
            a.insert(index);
            b.insert(index);
            try std.testing.expect(a.view().includes(b.view()));
            try std.testing.expect(a.view().intersects(b.view()));
            b.remove(index);
            b.insert((index + 1) % capacity);
            try std.testing.expect(!a.view().includes(b.view()));
            try std.testing.expect(!a.view().intersects(b.view()));
            try std.testing.expect(!b.view().intersects(a.view()));
            b.insert(index);
            try std.testing.expect(a.view().intersects(b.view()));
            try std.testing.expect(b.view().includes(a.view()));
            try std.testing.expect(!a.view().includes(b.view()));
        }
        a.fill();
        b.fill();
        try std.testing.expect(a.view().includes(b.view()));
        try std.testing.expect(a.view().intersects(b.view()));
        a.remove(capacity - 1);
        try std.testing.expect(!a.view().includes(b.view()));
        try std.testing.expect(b.view().includes(a.view()));
    }
}
