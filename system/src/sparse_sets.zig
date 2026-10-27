const std = @import("std");
const bit_sets = @import("bit_sets.zig");
const assert = std.debug.assert;
const width = @bitSizeOf(usize);
const absent = std.math.maxInt(usize);
const Shift = std.math.Log2Int(usize);

const Entry = struct { row: usize = absent, word: usize = 0, value: usize = 0, bucket_next: usize = absent, previous: usize = absent, next: usize = absent };
const State = struct { head: usize = absent, tail: usize = absent, count: usize = 0, nodes: usize = 0, inline_word: usize = 0, inline_value: usize = 0, inline_used: bool = false, inverted: bool = false, hash_value: u64 = 0, hash_dirty: bool = true };
const Operation = enum { copy, unite, intersect, subtract, difference };
pub const Result = struct { changed: ?bit_sets.Set = null };

pub const WordIterator = struct {
    pool: *const Pool,
    row: usize,
    node: usize,
    inline_pending: bool,

    pub fn next(self: *WordIterator) ?struct { index: usize, value: usize } {
        const row = &self.pool.rows[self.row];
        if (self.inline_pending and (self.node == absent or row.inline_word < self.pool.entries[self.node].word)) {
            self.inline_pending = false;
            return .{ .index = row.inline_word, .value = row.inline_value };
        }
        if (self.node == absent) return null;
        const entry = self.pool.entries[self.node];
        self.node = entry.next;
        return .{ .index = entry.word, .value = entry.value };
    }
};

pub const View = struct {
    pool: *Pool,
    index: usize,

    pub fn iterator(self: View) WordIterator {
        const row = self.pool.rows[self.index];
        return .{ .pool = self.pool, .row = self.index, .node = row.head, .inline_pending = row.inline_used };
    }

    pub fn wordAt(self: View, word: usize) usize {
        return self.pool.wordAt(self.index, word);
    }

    pub fn count(self: View) usize {
        return self.pool.rows[self.index].count;
    }

    pub fn hash(self: View) u64 {
        const row = &self.pool.rows[self.index];
        if (row.hash_dirty) {
            var value: u64 = if (row.inverted) self.pool.full_hash else 0;
            var words = self.iterator();
            var next = words.next();
            while (next) |first| {
                const start = first.index - first.index % bit_sets.hash_block_words;
                const used = @min(bit_sets.hash_block_words, self.pool.scratch.len - start);
                const buffer = &self.pool.hash_words;
                const begin = if (row.inverted) 0 else first.index - start;
                var end: usize = begin;
                if (row.inverted) {
                    @memset(buffer[0..used], std.math.maxInt(usize));
                    buffer[used - 1] = self.pool.full(start + used - 1);
                    value ^= bit_sets.hashBlock(start, buffer[0..used]);
                }
                while (next) |word| {
                    if (word.index >= start + used) break;
                    const offset = word.index - start;
                    if (!row.inverted) @memset(buffer[end..offset], 0);
                    buffer[offset] = word.value;
                    end = offset + 1;
                    next = words.next();
                }
                value ^= bit_sets.hashBlock(start + begin, buffer[begin..if (row.inverted) used else end]);
            }
            row.hash_value = value;
            row.hash_dirty = false;
        }
        return row.hash_value;
    }
};

pub const Pool = struct {
    capacity: usize,
    rows: []State,
    entries: []Entry,
    buckets: []usize,
    scratch: []usize,
    positions: []usize,
    free: usize,
    used: usize = 0,
    full_hash: u64 = 0,
    hash_words: [bit_sets.hash_block_words]usize = @splat(0),

    fn init(allocator: std.mem.Allocator, rows: usize, capacity: usize, words: usize) !*Pool {
        const self = try allocator.create(Pool);
        errdefer allocator.destroy(self);
        const entries = try allocator.alloc(Entry, words);
        errdefer allocator.free(entries);
        for (entries, 0..) |*entry, index| entry.* = .{ .bucket_next = if (index + 1 == entries.len) absent else index + 1 };
        const states = try allocator.alloc(State, rows);
        errdefer allocator.free(states);
        @memset(states, .{});
        const buckets = try allocator.alloc(usize, try std.math.ceilPowerOfTwo(usize, @max(1, try std.math.mul(usize, words, 2))));
        errdefer allocator.free(buckets);
        @memset(buckets, absent);
        const scratch = try allocator.alloc(usize, capacity / width + @intFromBool(capacity % width != 0));
        errdefer allocator.free(scratch);
        const positions = try allocator.alloc(usize, scratch.len);
        self.* = .{ .capacity = capacity, .rows = states, .entries = entries, .buckets = buckets, .scratch = scratch, .positions = positions, .free = if (entries.len == 0) absent else 0 };
        var start: usize = 0;
        while (start < scratch.len) {
            const used = @min(bit_sets.hash_block_words, scratch.len - start);
            @memset(self.hash_words[0..used], std.math.maxInt(usize));
            self.hash_words[used - 1] = self.full(start + used - 1);
            self.full_hash ^= bit_sets.hashBlock(start, self.hash_words[0..used]);
            start += used;
        }
        return self;
    }

    fn bucket(self: *const Pool, row: usize, word: usize) usize {
        const key = [_]usize{ row, word };
        return @intCast(std.hash.Wyhash.hash(0, std.mem.asBytes(&key)) & (self.buckets.len - 1));
    }

    fn find(self: *const Pool, row: usize, word: usize) ?usize {
        var index = self.buckets[self.bucket(row, word)];
        while (index != absent) : (index = self.entries[index].bucket_next) {
            const entry = self.entries[index];
            if (entry.row == row and entry.word == word) return index;
        }
        return null;
    }

    fn full(self: *const Pool, word: usize) usize {
        assert(word < self.scratch.len);
        if (word + 1 == self.scratch.len and self.capacity % width != 0) return @as(usize, std.math.maxInt(usize)) >> @as(Shift, @intCast(width - self.capacity % width));
        return std.math.maxInt(usize);
    }

    fn wordAt(self: *const Pool, row: usize, word: usize) usize {
        assert(row < self.rows.len and word < self.scratch.len);
        const state = &self.rows[row];
        if (state.inline_used and state.inline_word == word) return state.inline_value;
        if (state.nodes != 0) if (self.find(row, word)) |index| return self.entries[index].value;
        return if (state.inverted) self.full(word) else 0;
    }

    fn erase(self: *Pool, index: usize) void {
        const entry = self.entries[index];
        const row = &self.rows[entry.row];
        if (entry.previous == absent) row.head = entry.next else self.entries[entry.previous].next = entry.next;
        if (entry.next == absent) row.tail = entry.previous else self.entries[entry.next].previous = entry.previous;
        var link = &self.buckets[self.bucket(entry.row, entry.word)];
        while (link.* != index) link = &self.entries[link.*].bucket_next;
        link.* = entry.bucket_next;
        self.entries[index] = .{ .bucket_next = self.free };
        self.free = index;
        self.used -= 1;
        row.nodes -= 1;
    }

    fn insert(self: *Pool, row_index: usize, word: usize, value: usize) void {
        const state = &self.rows[row_index];
        assert((!state.inline_used or state.inline_word != word) and self.find(row_index, word) == null);
        if (!state.inline_used) {
            state.inline_word = word;
            state.inline_value = value;
            state.inline_used = true;
            return;
        }
        assert(self.free != absent);
        const index = self.free;
        self.free = self.entries[index].bucket_next;
        const at = self.bucket(row_index, word);
        const row = &self.rows[row_index];
        var before = row.tail;
        while (before != absent and self.entries[before].word > word) before = self.entries[before].previous;
        const after = if (before == absent) row.head else self.entries[before].next;
        self.entries[index] = .{ .row = row_index, .word = word, .value = value, .bucket_next = self.buckets[at], .previous = before, .next = after };
        self.buckets[at] = index;
        if (before == absent) row.head = index else self.entries[before].next = index;
        if (after == absent) row.tail = index else self.entries[after].previous = index;
        self.used += 1;
        row.nodes += 1;
    }

    fn clear(self: *Pool, index: usize) void {
        while (self.rows[index].head != absent) self.erase(self.rows[index].head);
        self.rows[index] = .{};
    }

    fn bit(self: *Pool, row_index: usize, index: usize, present: bool) bool {
        assert(index < self.capacity);
        const word = index / width;
        const flag = @as(usize, 1) << @as(Shift, @intCast(index % width));
        const old = self.wordAt(row_index, word);
        const value = if (present) old | flag else old & ~flag;
        if (!self.putWord(row_index, word, value)) return false;
        assert((self.wordAt(row_index, word) & flag != 0) == present);
        return true;
    }

    fn putWord(self: *Pool, row_index: usize, word: usize, value: usize) bool {
        assert(word < self.scratch.len and value & ~self.full(word) == 0);
        const old = self.wordAt(row_index, word);
        if (old == value) return true;
        const row = &self.rows[row_index];
        const baseline = if (row.inverted) self.full(word) else 0;
        if (row.inline_used and row.inline_word == word) {
            if (value == baseline) row.inline_used = false else row.inline_value = value;
        } else {
            const existing = self.find(row_index, word);
            if (existing == null and value != baseline and row.inline_used and self.free == absent) return false;
            if (existing) |entry| {
                if (value == baseline) self.erase(entry) else self.entries[entry].value = value;
            } else if (value != baseline) self.insert(row_index, word, value);
        }
        row.count = row.count - @popCount(old) + @popCount(value);
        row.hash_dirty = true;
        assert(self.wordAt(row_index, word) == value);
        return true;
    }

    fn combine(comptime operation: Operation, left: usize, right: usize) usize {
        return switch (operation) {
            .copy => left,
            .unite => left | right,
            .intersect => left & right,
            .subtract => left & ~right,
            .difference => left ^ right,
        };
    }

    fn merge(self: *Pool, row_index: usize, comptime operation: Operation, a: View, b: View) ?Result {
        const left_full = a.pool.rows[a.index].inverted;
        const right_full = b.pool.rows[b.index].inverted;
        const baseline = combine(operation, if (left_full) std.math.maxInt(usize) else 0, if (right_full) std.math.maxInt(usize) else 0) != 0;
        var left = a.iterator();
        var right = b.iterator();
        var l = left.next();
        var r: @TypeOf(l) = if (operation == .copy) null else right.next();
        var used: usize = 0;
        var nonzero: usize = if (baseline) self.scratch.len else 0;
        var nonfull: usize = if (baseline) 0 else self.scratch.len;
        var count: usize = if (baseline) self.capacity else 0;
        while (l != null or r != null) {
            const index = @min(if (l) |word| word.index else absent, if (r) |word| word.index else absent);
            const full_word = self.full(index);
            var av: usize = if (left_full) full_word else 0;
            var bv: usize = if (right_full) full_word else 0;
            if (l) |word| if (word.index == index) {
                av = word.value;
                l = left.next();
            };
            if (r) |word| if (word.index == index) {
                bv = word.value;
                r = right.next();
            };
            const value = combine(operation, av, bv);
            const default: usize = if (baseline) full_word else 0;
            nonzero = nonzero - @intFromBool(default != 0) + @intFromBool(value != 0);
            nonfull = nonfull - @intFromBool(default != full_word) + @intFromBool(value != full_word);
            count = count - @popCount(default) + @popCount(value);
            if (value == default) continue;
            assert(used < self.scratch.len);
            self.positions[used] = index;
            self.scratch[used] = value;
            used += 1;
        }
        const inverted = nonfull < nonzero;
        // A representation change or exhausted pool uses the dense atomic-failure path.
        if (inverted != baseline or used -| 1 > self.entries.len - self.used + self.rows[row_index].nodes) return null;
        return self.install(row_index, inverted, count, used);
    }

    fn restrict(self: *Pool, row_index: usize, comptime operation: Operation, a: View, b: bit_sets.Set) ?Result {
        assert(!a.pool.rows[a.index].inverted and (operation == .intersect or operation == .subtract));
        var words = a.iterator();
        var used: usize = 0;
        var count: usize = 0;
        var nonfull = self.scratch.len;
        while (words.next()) |word| {
            const value = combine(operation, word.value, b.wordAt(word.index));
            if (value == 0) continue;
            self.positions[used] = word.index;
            self.scratch[used] = value;
            used += 1;
            count += @popCount(value);
            nonfull -= @intFromBool(value == self.full(word.index));
        }
        if (nonfull < used or used -| 1 > self.entries.len - self.used + self.rows[row_index].nodes) return null;
        return self.install(row_index, false, count, used);
    }

    fn install(self: *Pool, row_index: usize, inverted: bool, count: usize, used: usize) Result {
        const row = &self.rows[row_index];
        if (row.inverted == inverted and row.count == count and row.nodes + @intFromBool(row.inline_used) == used) {
            var previous = (View{ .pool = self, .index = row_index }).iterator();
            const equal = for (self.positions[0..used], self.scratch[0..used]) |index, value| {
                const word = previous.next().?;
                if (word.index != index or word.value != value) break false;
            } else true;
            if (equal) return .{};
        }
        self.clear(row_index);
        row.inverted = inverted;
        row.count = count;
        for (self.positions[0..used], self.scratch[0..used]) |index, value| self.insert(row_index, index, value);
        assert(row.nodes == used -| 1 and row.count == count);
        return .{};
    }

    fn apply(self: *Pool, row_index: usize, comptime operation: Operation, a: bit_sets.Set, b: bit_sets.Set) Result {
        assert(a.capacity == self.capacity and b.capacity == self.capacity);
        if (a.sparse) |left| {
            if (operation == .copy or b.sparse != null) {
                if (self.merge(row_index, operation, left, if (operation == .copy) left else b.sparse.?)) |result| return result;
            }
        }
        if (operation == .intersect or operation == .subtract) {
            if (a.sparse) |left| if (!left.pool.rows[left.index].inverted) {
                if (self.restrict(row_index, operation, left, b)) |result| return result;
            };
            if (operation == .intersect) if (b.sparse) |right| if (!right.pool.rows[right.index].inverted) {
                if (self.restrict(row_index, operation, right, a)) |result| return result;
            };
        }
        var nonzero: usize = 0;
        var nonfull: usize = 0;
        var count: usize = 0;
        for (self.scratch, 0..) |*word, index| {
            const left = a.wordAt(index);
            const right = if (operation == .copy) 0 else b.wordAt(index);
            word.* = combine(operation, left, right);
            count += @popCount(word.*);
            nonzero += @intFromBool(word.* != 0);
            nonfull += @intFromBool(word.* != self.full(index));
        }
        const inverted = nonfull < nonzero;
        const words = if (inverted) nonfull else nonzero;
        const required = words -| 1;
        if (required > self.entries.len - self.used + self.rows[row_index].nodes) {
            for (self.scratch, 0..) |*word, index| word.* ^= self.wordAt(row_index, index);
            return .{ .changed = .{ .words = self.scratch, .capacity = self.capacity } };
        }
        self.clear(row_index);
        const row = &self.rows[row_index];
        row.inverted = inverted;
        row.count = count;
        for (self.scratch, 0..) |word, index| if (word != (if (inverted) self.full(index) else 0)) self.insert(row_index, index, word);
        assert(row.nodes == required);
        return .{};
    }
};

pub const Row = struct {
    dense: bit_sets.Row = .{},
    sparse: ?View = null,

    pub fn view(self: Row) bit_sets.Set {
        if (self.sparse) |value| return .{ .words = &.{}, .capacity = value.pool.capacity, .sparse = value };
        return self.dense.view();
    }

    pub fn clear(self: Row) void {
        if (self.sparse) |value| value.pool.clear(value.index) else self.dense.clear();
    }

    pub fn fill(self: Row) void {
        if (self.sparse) |value| {
            value.pool.clear(value.index);
            const state = &value.pool.rows[value.index];
            state.inverted = true;
            state.count = value.pool.capacity;
            state.hash_value = value.pool.full_hash;
            state.hash_dirty = false;
        } else self.dense.fill();
    }

    pub fn insert(self: Row, index: usize) bool {
        if (self.sparse) |value| return value.pool.bit(value.index, index, true);
        self.dense.insert(index);
        return true;
    }

    pub fn remove(self: Row, index: usize) bool {
        if (self.sparse) |value| return value.pool.bit(value.index, index, false);
        self.dense.remove(index);
        return true;
    }

    pub fn putWord(self: Row, word: usize, value: usize) bool {
        if (self.sparse) |stored| return stored.pool.putWord(stored.index, word, value);
        assert(word < self.dense.words.len);
        self.dense.words[word] = value;
        return true;
    }

    pub fn apply(self: Row, comptime operation: Operation, a: bit_sets.Set, b: bit_sets.Set) Result {
        if (self.sparse) |value| return value.pool.apply(value.index, operation, a, b);
        switch (operation) {
            .copy => self.dense.copy(a),
            .unite => self.dense.unite(a, b),
            .intersect => self.dense.intersect(a, b),
            .subtract => self.dense.subtract(a, b),
            .difference => self.dense.difference(a, b),
        }
        return .{};
    }
};

pub const Matrix = struct {
    dense: ?bit_sets.Matrix = null,
    pool: ?*Pool = null,
    count: usize,

    pub fn init(allocator: std.mem.Allocator, rows: usize, capacity: usize, extra_words: usize) !Matrix {
        const stride = capacity / width + @intFromBool(capacity % width != 0);
        if (stride <= std.atomic.cache_line / @sizeOf(usize)) return .{ .dense = try bit_sets.Matrix.init(allocator, rows, capacity), .count = rows };
        const possible = std.math.mul(usize, rows, stride - 1) catch std.math.maxInt(usize);
        return .{ .pool = try Pool.init(allocator, rows, capacity, @min(extra_words, possible)), .count = rows };
    }

    pub fn row(self: Matrix, index: usize) Row {
        assert(index < self.count);
        if (self.dense) |matrix| return .{ .dense = matrix.row(index) };
        return .{ .sparse = .{ .pool = self.pool.?, .index = index } };
    }

    pub fn deinit(self: *Matrix, allocator: std.mem.Allocator) void {
        if (self.dense) |*matrix| matrix.deinit(allocator);
        if (self.pool) |pool| {
            allocator.free(pool.positions);
            allocator.free(pool.scratch);
            allocator.free(pool.buckets);
            allocator.free(pool.entries);
            allocator.free(pool.rows);
            allocator.destroy(pool);
        }
        self.* = undefined;
    }

    pub fn memoryBytes(self: Matrix) usize {
        if (self.dense) |matrix| return matrix.words.len * @sizeOf(usize) + matrix.rows.len * @sizeOf(bit_sets.Row);
        const pool = self.pool.?;
        return @sizeOf(Pool) + pool.rows.len * @sizeOf(State) + pool.entries.len * @sizeOf(Entry) + pool.buckets.len * @sizeOf(usize) + (pool.scratch.len + pool.positions.len) * @sizeOf(usize);
    }
};

/// Owns enough word storage for every row. Mutations cannot exhaust the pool.
pub const Workspace = struct {
    matrix: Matrix,

    pub fn init(allocator: std.mem.Allocator, rows: usize, capacity: usize) !Workspace {
        const words = capacity / width + @intFromBool(capacity % width != 0);
        return .{ .matrix = try Matrix.init(allocator, rows, capacity, try std.math.mul(usize, rows, words -| 1)) };
    }

    pub fn deinit(self: *Workspace, allocator: std.mem.Allocator) void {
        self.matrix.deinit(allocator);
        self.* = undefined;
    }

    pub fn row(self: Workspace, index: usize) RowView {
        return .{ .storage = self.matrix.row(index) };
    }

    pub const RowView = struct {
        storage: Row,

        pub fn view(self: RowView) bit_sets.Set {
            return self.storage.view();
        }
        pub fn clear(self: RowView) void {
            self.storage.clear();
        }
        pub fn fill(self: RowView) void {
            self.storage.fill();
        }
        pub fn toggle(self: RowView, index: usize) void {
            if (self.view().contains(index)) self.remove(index) else self.insert(index);
        }
        pub fn insert(self: RowView, index: usize) void {
            const ready = self.storage.insert(index);
            assert(ready);
        }
        pub fn remove(self: RowView, index: usize) void {
            const ready = self.storage.remove(index);
            assert(ready);
        }
        pub fn uniteWord(self: RowView, word: usize, value: usize) void {
            const ready = self.storage.putWord(word, self.view().wordAt(word) | value);
            assert(ready);
        }
        pub fn copy(self: RowView, a: bit_sets.Set) void {
            const result = self.storage.apply(.copy, a, a);
            assert(result.changed == null);
        }
        pub fn unite(self: RowView, a: bit_sets.Set, b: bit_sets.Set) void {
            const result = self.storage.apply(.unite, a, b);
            assert(result.changed == null);
        }
        pub fn intersect(self: RowView, a: bit_sets.Set, b: bit_sets.Set) void {
            const result = self.storage.apply(.intersect, a, b);
            assert(result.changed == null);
        }
        pub fn subtract(self: RowView, a: bit_sets.Set, b: bit_sets.Set) void {
            const result = self.storage.apply(.subtract, a, b);
            assert(result.changed == null);
        }
        pub fn difference(self: RowView, a: bit_sets.Set, b: bit_sets.Set) void {
            const result = self.storage.apply(.difference, a, b);
            assert(result.changed == null);
        }
    };
};

test "sparse rows preserve exact values and reject exhaustion atomically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = failing.allocator();
    const capacity = 65_537;
    var matrix = try Matrix.init(allocator, 3, capacity, 2);
    const reference = try bit_sets.Matrix.init(allocator, 3, capacity);
    const scratch = try bit_sets.Matrix.init(allocator, 1, capacity);
    failing.fail_index = failing.alloc_index;
    var random = std.Random.DefaultPrng.init(578);
    for (0..2000) |_| {
        const row_index = random.random().uintLessThan(usize, 3);
        const other = (row_index + 1) % 3;
        const row = matrix.row(row_index);
        const model = reference.row(row_index);
        const next = scratch.row(0);
        next.copy(model.view());
        switch (random.random().uintLessThan(u8, 8)) {
            0 => {
                const index = random.random().uintLessThan(usize, capacity);
                if (row.insert(index)) model.insert(index);
            },
            1 => {
                const index = random.random().uintLessThan(usize, capacity);
                if (row.remove(index)) model.remove(index);
            },
            2 => {
                next.fill();
                if (row.apply(.copy, next.view(), next.view()).changed == null) model.copy(next.view());
            },
            3 => {
                next.subtract(model.view(), reference.row(other).view());
                if (row.apply(.subtract, row.view(), matrix.row(other).view()).changed == null) model.copy(next.view());
            },
            4 => {
                row.clear();
                model.clear();
            },
            5...7 => |choice| inline for (.{ Operation.unite, Operation.intersect, Operation.difference }, 5..) |operation, tag| {
                if (choice == tag) {
                    switch (operation) {
                        .unite => next.unite(model.view(), reference.row(other).view()),
                        .intersect => next.intersect(model.view(), reference.row(other).view()),
                        .difference => next.difference(model.view(), reference.row(other).view()),
                        else => unreachable,
                    }
                    if (row.apply(operation, row.view(), matrix.row(other).view()).changed == null) model.copy(next.view());
                }
            },
            else => unreachable,
        }
        try std.testing.expect(row.view().eql(model.view()));
        try std.testing.expectEqual(model.view().count(), row.view().count());
        try std.testing.expectEqual(model.view().hash(), row.view().hash());
        var expected = model.view().iterator();
        var actual = row.view().iterator();
        while (expected.next()) |index| try std.testing.expectEqual(index, actual.next().?);
        try std.testing.expectEqual(null, actual.next());
    }
    try std.testing.expect(matrix.memoryBytes() < capacity * 8);
}

test "sparse merges touch only exceptional words and preserve inverted aliases" {
    const allocator = std.testing.allocator;
    const capacity = 65_537;
    var matrix = try Matrix.init(allocator, 3, capacity, 2);
    defer matrix.deinit(allocator);
    const pool = matrix.pool.?;
    try std.testing.expect(matrix.row(0).insert(5));
    try std.testing.expect(matrix.row(1).insert(11));
    @memset(pool.scratch, 42);
    @memset(pool.positions, absent);
    try std.testing.expect(matrix.row(2).apply(.unite, matrix.row(0).view(), matrix.row(1).view()).changed == null);
    try std.testing.expectEqual(@as(usize, 2), matrix.row(2).view().count());
    for (pool.scratch[1..]) |word| try std.testing.expectEqual(@as(usize, 42), word);
    for (pool.positions[1..]) |index| try std.testing.expectEqual(absent, index);
    try std.testing.expect(matrix.row(2).apply(.copy, matrix.row(2).view(), matrix.row(2).view()).changed == null);
    var dense = try bit_sets.Matrix.init(allocator, 1, capacity);
    defer dense.deinit(allocator);
    dense.row(0).fill();
    try std.testing.expect(matrix.row(0).apply(.copy, dense.row(0).view(), dense.row(0).view()).changed == null);
    try std.testing.expect(matrix.row(0).remove(capacity - 1));
    try std.testing.expect(matrix.row(1).apply(.copy, matrix.row(0).view(), matrix.row(0).view()).changed == null);
    try std.testing.expectEqual(capacity - 1, matrix.row(1).view().count());
    try std.testing.expect(!matrix.row(1).view().contains(capacity - 1));
    try std.testing.expect(matrix.row(1).apply(.difference, matrix.row(0).view(), matrix.row(1).view()).changed == null);
    try std.testing.expectEqual(@as(usize, 0), matrix.row(1).view().count());
    try std.testing.expect(matrix.row(0).view().count() == capacity - 1);
}

test "sparse matrix initialization releases partial allocations" {
    const Fixture = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var matrix = try Matrix.init(allocator, 3, 4096, 2);
            defer matrix.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Fixture.run, .{});
}

test "workspace preserves mixed representations across hash blocks without allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    const capacity = 4099;
    var workspace = try Workspace.init(allocator, 3, capacity);
    defer workspace.deinit(allocator);
    var model = try bit_sets.Matrix.init(allocator, 3, capacity);
    defer model.deinit(allocator);
    failing.fail_index = failing.alloc_index;
    var random = std.Random.DefaultPrng.init(921);
    for (0..250) |step| {
        const target = step % 3;
        const other = (target + 1) % 3;
        const row = workspace.row(target);
        const dense = model.row(target);
        const bit = random.random().uintLessThan(usize, capacity);
        switch (step % 7) {
            0 => {
                dense.fill();
                row.fill();
            },
            1 => {
                row.remove(bit);
                dense.remove(bit);
            },
            2 => {
                row.insert(bit);
                dense.insert(bit);
            },
            3 => {
                row.subtract(row.view(), model.row(other).view());
                dense.subtract(dense.view(), model.row(other).view());
            },
            4 => {
                row.intersect(model.row(other).view(), row.view());
                dense.intersect(model.row(other).view(), dense.view());
            },
            5 => {
                row.difference(row.view(), workspace.row(other).view());
                dense.difference(dense.view(), model.row(other).view());
            },
            6 => {
                row.unite(row.view(), workspace.row(other).view());
                dense.unite(dense.view(), model.row(other).view());
            },
            else => unreachable,
        }
        try std.testing.expectEqual(dense.view().hash(), row.view().hash());
        try std.testing.expect(row.view().eql(dense.view()));
        for (0..3) |index| {
            const expected = model.row(index).view();
            const actual = workspace.row(index).view();
            try std.testing.expectEqual(dense.view().includes(expected), row.view().includes(actual));
            try std.testing.expectEqual(dense.view().includes(expected), row.view().includes(expected));
            try std.testing.expectEqual(dense.view().intersects(expected), row.view().intersects(actual));
            try std.testing.expectEqual(dense.view().intersects(expected), row.view().intersects(expected));
            try std.testing.expectEqual(dense.view().intersects(expected), dense.view().intersects(actual));
        }
        const start = random.random().uintLessThan(usize, capacity);
        try std.testing.expectEqual(dense.view().firstFrom(start), row.view().firstFrom(start));
    }
    for (0..3) |index| {
        workspace.row(index).clear();
        model.row(index).clear();
        for (0..capacity / width + 1) |word| {
            workspace.row(index).uniteWord(word, 1);
            model.row(index).insert(word * width);
        }
        try std.testing.expectEqual(model.row(index).view().hash(), workspace.row(index).view().hash());
        try std.testing.expect(workspace.row(index).view().eql(model.row(index).view()));
    }
}

test "workspace initialization releases partial allocations" {
    const Fixture = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var workspace = try Workspace.init(allocator, 3, 4099);
            defer workspace.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Fixture.run, .{});
}
