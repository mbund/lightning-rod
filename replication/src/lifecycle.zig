const BatchIndex = @import("lightning_rod").system.BatchIndex;
const std = @import("std");
const bit_sets = @import("lightning_rod").system.bit_sets;
const minecraft = @import("minecraft_model");
const IndexSet = @import("lightning_rod").system.IndexSet;
const assert = std.debug.assert;
const absent = std.math.maxInt(usize);

pub const Lifecycle = struct {
    pub const State = struct {
        uuid: u128 = 0,
        generation: u32 = 0,
        known: bool = false,
        listed: bool = false,
        spawned: bool = false,
        gamemode: ?minecraft.GameMode = null,
    };
    const Row = struct { value: State = .{}, epoch: u64 = 0, head: usize = absent, count: usize = 0 };
    const Column = struct { epoch: u64 = 0, head: usize = absent, count: usize = 0, previous: ?usize = null, next: ?usize = null };
    const Entry = struct { subject: usize = absent, observer: usize = absent, value: State = .{}, bucket_next: usize = absent, row_next: usize = absent, row_previous: usize = absent, column_next: usize = absent, column_previous: usize = absent };
    rows: []Row,
    columns: []Column,
    entries: []Entry,
    buckets: []usize,
    active: IndexSet,
    scratch: []State,
    frequencies: BatchIndex(State, usize, std.hash_map.AutoContext(State)),
    free: usize,
    count: usize = 0,
    epoch: u64 = 0,
    working: ?usize = null,
    selected: bit_sets.Set = undefined,
    replace: bool = false,
    last: ?usize = null,

    pub fn init(allocator: std.mem.Allocator, players: usize, exceptions: usize) !Lifecycle {
        const rows = try allocator.alloc(Row, players);
        @memset(rows, .{});
        const columns = try allocator.alloc(Column, players);
        @memset(columns, .{});
        assert(players > 0);
        const possible = std.math.mul(usize, players, players - 1) catch std.math.maxInt(usize);
        const entries = try allocator.alloc(Entry, try std.math.add(usize, @min(exceptions, possible), players));
        for (entries, 0..) |*entry, index| entry.* = .{ .bucket_next = if (index + 1 == entries.len) absent else index + 1 };
        const buckets = try allocator.alloc(usize, try std.math.ceilPowerOfTwo(usize, try std.math.mul(usize, entries.len, 2)));
        @memset(buckets, absent);
        const frequencies = try BatchIndex(State, usize, std.hash_map.AutoContext(State)).init(allocator, players);
        return .{ .rows = rows, .columns = columns, .entries = entries, .buckets = buckets, .active = try IndexSet.init(allocator, players), .scratch = try allocator.alloc(State, players), .frequencies = frequencies, .free = 0 };
    }

    fn bucket(self: *const Lifecycle, subject: usize, observer: usize) usize {
        const key = [_]usize{ subject, observer };
        return @intCast(std.hash.Wyhash.hash(0, std.mem.asBytes(&key)) & (self.buckets.len - 1));
    }

    fn find(self: *const Lifecycle, subject: usize, observer: usize) ?usize {
        var index = self.buckets[self.bucket(subject, observer)];
        while (index != absent) : (index = self.entries[index].bucket_next) {
            const entry = self.entries[index];
            if (entry.subject == subject and entry.observer == observer) return index;
        }
        return null;
    }

    fn remove(self: *Lifecycle, index: usize) void {
        const entry = self.entries[index];
        const row = &self.rows[entry.subject];
        const column = &self.columns[entry.observer];
        if (entry.row_previous == absent) row.head = entry.row_next else self.entries[entry.row_previous].row_next = entry.row_next;
        if (entry.row_next != absent) self.entries[entry.row_next].row_previous = entry.row_previous;
        if (entry.column_previous == absent) column.head = entry.column_next else self.entries[entry.column_previous].column_next = entry.column_next;
        if (entry.column_next != absent) self.entries[entry.column_next].column_previous = entry.column_previous;
        var link = &self.buckets[self.bucket(entry.subject, entry.observer)];
        while (link.* != index) link = &self.entries[link.*].bucket_next;
        link.* = entry.bucket_next;
        self.entries[index] = .{ .bucket_next = self.free };
        self.free = index;
        self.count -= 1;
        row.count -= 1;
        column.count -= 1;
    }

    pub fn activate(self: *Lifecycle, observer: usize) void {
        assert(self.working == null and !self.active.contains(observer));
        self.epoch += 1;
        self.columns[observer].epoch = self.epoch;
        self.columns[observer].previous = self.last;
        if (self.last) |previous| self.columns[previous].next = observer;
        self.last = observer;
        self.active.insert(observer);
    }

    pub fn deactivate(self: *Lifecycle, observer: usize) void {
        assert(self.working == null);
        if (!self.active.contains(observer)) {
            assert(self.columns[observer].head == absent and self.columns[observer].count == 0);
            return;
        }
        self.active.remove(observer);
        while (self.columns[observer].head != absent) self.remove(self.columns[observer].head);
        const column = self.columns[observer];
        if (column.previous) |previous| self.columns[previous].next = column.next;
        if (column.next) |next| self.columns[next].previous = column.previous else self.last = column.previous;
        self.columns[observer] = .{};
    }

    pub fn get(self: *const Lifecycle, subject: usize, observer: usize) State {
        if (self.working == subject and self.selected.contains(observer)) return self.scratch[observer];
        if (!self.active.contains(observer)) return .{};
        const row = self.rows[subject];
        if (row.count != 0) if (self.find(subject, observer)) |index| return self.entries[index].value;
        return if (row.epoch >= self.columns[observer].epoch) row.value else .{};
    }

    /// The selection stays borrowed until commit. Every selected observer must be active.
    pub fn begin(self: *Lifecycle, subject: usize, selected: bit_sets.Set) bool {
        assert(self.working == null and selected.capacity == self.rows.len);
        const count = selected.count();
        assert(count <= self.active.count);
        const replace = count == self.active.count;
        var needed: usize = 0;
        var observers = selected.iterator();
        while (observers.next()) |observer| {
            assert(self.active.contains(observer));
            if (replace or self.find(subject, observer) == null) needed += 1;
            self.scratch[observer] = self.get(subject, observer);
        }
        const available = self.entries.len - self.count + if (replace) self.rows[subject].count else @as(usize, 0);
        if (needed > available) return false;
        self.selected = selected;
        self.replace = replace;
        self.working = subject;
        return true;
    }

    pub fn edit(self: *Lifecycle, observer: usize) *State {
        assert(self.working != null and self.selected.contains(observer) and self.active.contains(observer));
        return &self.scratch[observer];
    }

    pub fn commit(self: *Lifecycle) void {
        const subject = self.working.?;
        const row = &self.rows[subject];
        if (self.replace) {
            self.frequencies.clear();
            var common: State = .{};
            var maximum: usize = 0;
            var observers = self.selected.iterator();
            while (observers.next()) |observer| {
                self.scratch[observer].spawned = false;
                const value = self.scratch[observer];
                const result = self.frequencies.getOrPut(value);
                if (!result.found_existing) result.value_ptr.* = 0;
                result.value_ptr.* += 1;
                if (result.value_ptr.* > maximum) {
                    maximum = result.value_ptr.*;
                    common = value;
                }
            }
            while (row.head != absent) self.remove(row.head);
            row.value = common;
            row.epoch = self.epoch;
        }
        var observers = self.selected.iterator();
        while (observers.next()) |observer| {
            var value = self.scratch[observer];
            value.spawned = false;
            const column = &self.columns[observer];
            // Extend shared coverage only after every earlier active observer is covered.
            if (column.epoch > row.epoch and std.meta.eql(value, row.value) and
                (column.previous == null or self.columns[column.previous.?].epoch <= row.epoch))
            {
                row.epoch = column.epoch;
                var next = column.next;
                while (next) |following| {
                    const exception = self.find(subject, following) orelse break;
                    if (!std.meta.eql(self.entries[exception].value, row.value)) break;
                    row.epoch = self.columns[following].epoch;
                    self.remove(exception);
                    next = self.columns[following].next;
                }
            }
            const existing = self.find(subject, observer);
            const implicit = if (row.epoch >= column.epoch) row.value else State{};
            if (std.meta.eql(value, implicit)) {
                if (existing) |index| self.remove(index);
                continue;
            }
            if (existing) |index| {
                self.entries[index].value = value;
                continue;
            }
            assert(self.free != absent);
            const index = self.free;
            self.free = self.entries[index].bucket_next;
            const at = self.bucket(subject, observer);
            self.entries[index] = .{ .subject = subject, .observer = observer, .value = value, .bucket_next = self.buckets[at], .row_next = row.head, .column_next = column.head };
            if (row.head != absent) self.entries[row.head].row_previous = index;
            if (column.head != absent) self.entries[column.head].column_previous = index;
            row.head = index;
            column.head = index;
            self.buckets[at] = index;
            self.count += 1;
            row.count += 1;
            column.count += 1;
        }
        self.working = null;
        assert(self.count <= self.entries.len);
    }

    pub fn prune(self: *Lifecycle, subject: usize) bool {
        assert(self.working == null);
        const row = &self.rows[subject];
        if (row.value.known) {
            for (self.active.values()) |observer| if (self.get(subject, observer).known) return false;
        } else {
            var index = row.head;
            while (index != absent) : (index = self.entries[index].row_next) if (self.entries[index].value.known) return false;
        }
        while (row.head != absent) self.remove(row.head);
        row.* = .{};
        return true;
    }

    pub fn largestObserver(self: *const Lifecycle) usize {
        assert(self.count != 0);
        var largest: usize = 0;
        for (self.columns, 0..) |column, index| if (column.count > self.columns[largest].count) {
            largest = index;
        };
        assert(self.active.contains(largest) and self.columns[largest].count != 0);
        return largest;
    }
};

test "shared lifecycle defaults preserve late joins reuse and bounded exceptions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var table = try Lifecycle.init(failing.allocator(), 3, 0);
    failing.fail_index = failing.alloc_index;
    table.activate(0);
    table.activate(1);
    const value: Lifecycle.State = .{ .uuid = 17, .generation = 1, .known = true, .listed = true, .gamemode = .creative };
    try std.testing.expect(table.begin(0, .{ .words = &.{3}, .capacity = 3 }));
    table.edit(0).* = value;
    table.edit(1).* = value;
    table.commit();
    try std.testing.expectEqual(@as(usize, 0), table.count);
    table.activate(2);
    try std.testing.expect(!table.get(0, 2).known);
    try std.testing.expect(table.begin(0, .{ .words = &.{7}, .capacity = 3 }));
    table.edit(0).* = value;
    table.edit(1).* = value;
    table.edit(2).* = .{};
    table.commit();
    try std.testing.expectEqual(@as(usize, 1), table.count);
    try std.testing.expect(!table.begin(1, .{ .words = &.{7}, .capacity = 3 }));
    try std.testing.expectEqual(@as(usize, 2), table.largestObserver());
    table.deactivate(2);
    try std.testing.expectEqual(@as(usize, 0), table.count);
    try std.testing.expectEqual(value, table.get(0, 0));
    table.activate(2);
    try std.testing.expect(!table.get(0, 2).known);
    try std.testing.expect(table.begin(0, .{ .words = &.{7}, .capacity = 3 }));
    table.edit(2).* = value;
    table.commit();
    try std.testing.expectEqual(value, table.get(0, 2));
}

test "partial lifecycle patches preserve late observers and fold completed gaps" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var table = try Lifecycle.init(failing.allocator(), 8, 16);
    failing.fail_index = failing.alloc_index;
    table.activate(0);
    table.activate(1);
    const known: Lifecycle.State = .{ .uuid = 17, .generation = 1, .known = true, .listed = true, .gamemode = .creative };
    try std.testing.expect(table.begin(0, .{ .words = &.{3}, .capacity = 8 }));
    table.edit(0).* = known;
    table.edit(1).* = known;
    table.commit();
    table.activate(2);
    table.activate(3);
    try std.testing.expect(table.begin(0, .{ .words = &.{8}, .capacity = 8 }));
    table.edit(3).* = known;
    table.commit();
    try std.testing.expect(!table.get(0, 2).known);
    try std.testing.expectEqual(known, table.get(0, 3));
    try std.testing.expectEqual(@as(usize, 1), table.count);
    try std.testing.expect(table.begin(0, .{ .words = &.{4}, .capacity = 8 }));
    table.edit(2).* = known;
    table.commit();
    try std.testing.expectEqual(@as(usize, 0), table.count);
    for (0..4) |observer| try std.testing.expectEqual(known, table.get(0, observer));
    try std.testing.expect(table.begin(0, .{ .words = &.{2}, .capacity = 8 }));
    table.edit(1).* = .{};
    table.commit();
    try std.testing.expect(!table.get(0, 1).known);
    try std.testing.expectEqual(known, table.get(0, 0));
    table.deactivate(2);
    table.deactivate(7);
    table.activate(2);
    try std.testing.expect(!table.get(0, 2).known);
    try std.testing.expect(table.begin(0, .{ .words = &.{4}, .capacity = 8 }));
    table.edit(2).* = known;
    table.commit();
    try std.testing.expectEqual(@as(usize, 1), table.count);
    try std.testing.expectEqual(known, table.get(0, 2));
    try std.testing.expect(!table.get(0, 1).known);
}

test "partial lifecycle state matches a dense model through reordered activation and patches" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var table = try Lifecycle.init(arena.allocator(), 8, 64);
    var model: [8][8]Lifecycle.State = @splat(@splat(.{}));
    var random = std.Random.DefaultPrng.init(17);
    for (0..8) |observer| table.activate(observer);
    for (0..512) |step| {
        if (step % 7 == 0) {
            const observer = random.random().uintLessThan(usize, 8);
            table.deactivate(observer);
            table.activate(observer);
            for (&model) |*row| row[observer] = .{};
        }
        const subject = random.random().uintLessThan(usize, 8);
        const words = [_]usize{random.random().uintLessThan(usize, 255) + 1};
        const selected: bit_sets.Set = .{ .words = &words, .capacity = 8 };
        try std.testing.expect(table.begin(subject, selected));
        var observers = selected.iterator();
        while (observers.next()) |observer| {
            const value: Lifecycle.State = .{ .uuid = subject + 1, .generation = @intCast(step / 64 + 1), .known = random.random().boolean(), .listed = random.random().boolean(), .gamemode = .survival };
            table.edit(observer).* = value;
            model[subject][observer] = value;
        }
        table.commit();
        for (model, 0..) |row, owner| for (row, 0..) |value, observer| try std.testing.expectEqual(value, table.get(owner, observer));
    }
}
