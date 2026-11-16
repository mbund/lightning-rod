//! Scheduled block ticks: an event at a block that runs on a later game tick, in vanilla's order
//! (trigger tick, then priority, then the order they were scheduled). Every event belongs to its
//! column. A column that stops ticking parks its events with the delay they had left, as vanilla
//! freezes the ticks of a chunk that unloads, and they run again once it ticks. Memory is fixed:
//! events, columns and the indexes over them are allocated once.

const std = @import("std");

const assert = std.debug.assert;

pub const Column = struct {
    world: u32,
    x: i32,
    z: i32,

    pub fn of(world: u32, position: Position) Column {
        return .{ .world = world, .x = position.x >> 4, .z = position.z >> 4 };
    }

    fn hash(self: Column) u64 {
        var bytes: [12]u8 = undefined;
        std.mem.writeInt(u32, bytes[0..4], self.world, .little);
        std.mem.writeInt(i32, bytes[4..8], self.x, .little);
        std.mem.writeInt(i32, bytes[8..12], self.z, .little);
        return std.hash.Wyhash.hash(0x636f6c756d6e, &bytes);
    }
};

pub const Position = struct { x: i32, y: i32, z: i32 };

/// What is ticked, by the index the handler was registered under.
pub const Kind = u16;

/// Vanilla's priorities. Lower runs first among ticks due on the same game tick.
pub const Priority = enum(i8) {
    extremely_high = -3,
    very_high = -2,
    high = -1,
    normal = 0,
    low = 1,
    very_low = 2,
    extremely_low = 3,
};

pub const Event = struct {
    world: u32,
    position: Position,
    kind: Kind,
    priority: Priority = .normal,

    fn hash(self: Event) u64 {
        var bytes: [18]u8 = undefined;
        std.mem.writeInt(u32, bytes[0..4], self.world, .little);
        std.mem.writeInt(i32, bytes[4..8], self.position.x, .little);
        std.mem.writeInt(i32, bytes[8..12], self.position.y, .little);
        std.mem.writeInt(i32, bytes[12..16], self.position.z, .little);
        std.mem.writeInt(u16, bytes[16..18], self.kind, .little);
        return std.hash.Wyhash.hash(0x7469636b, &bytes);
    }

    /// Vanilla keeps one tick of a kind at a block, whatever its priority.
    fn same(self: Event, other: Event) bool {
        return self.world == other.world and self.kind == other.kind and std.meta.eql(self.position, other.position);
    }
};

/// A parked or scheduled event with the ticks left until it runs.
pub const Pending = struct { event: Event, delay: u64 };

pub const Configuration = struct {
    /// Events scheduled or parked at once.
    events: u32,
    /// Columns with events in memory at once, ticking or parked.
    columns: u32,
};

pub const Queue = struct {
    const none = std.math.maxInt(u32);

    const Slot = struct {
        event: Event,
        /// The trigger tick while the column ticks, the delay left while it is parked.
        time: u64,
        sequence: u64,
        /// Place in the heap, or `none` while parked or free.
        heap: u32,
        column: u32,
        /// The column's list of events. A free slot links the free list through `next`.
        next: u32,
        previous: u32,
    };

    pub const ColumnState = struct {
        column: Column,
        head: u32 = none,
        count: u32 = 0,
        parked: bool,
        /// Events changed since the column was read or saved, so its record is out of date.
        dirty: bool = false,
        /// False while the state is free.
        live: bool = true,
        next_free: u32 = none,
    };

    slots: []Slot,
    free: u32,
    used: u32 = 0,
    heap: []u32,
    heap_count: u32 = 0,
    /// Open addressing by event, linear probing, backward shift deletion. Holds slot indices.
    by_event: []u32,
    column_states: []ColumnState,
    column_free: u32,
    column_count: u32 = 0,
    /// Open addressing by column. Holds column state indices.
    by_column: []u32,
    now: u64 = 0,
    sequence: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Configuration) !Queue {
        if (config.events == 0 or config.columns == 0 or config.events >= none / 2 or config.columns >= none / 2) return error.InvalidConfiguration;
        const slots = try allocator.alloc(Slot, config.events);
        errdefer allocator.free(slots);
        const heap = try allocator.alloc(u32, config.events);
        errdefer allocator.free(heap);
        const by_event = try allocator.alloc(u32, try std.math.ceilPowerOfTwo(usize, 2 * @as(usize, config.events)));
        errdefer allocator.free(by_event);
        const column_states = try allocator.alloc(ColumnState, config.columns);
        errdefer allocator.free(column_states);
        const by_column = try allocator.alloc(u32, try std.math.ceilPowerOfTwo(usize, 2 * @as(usize, config.columns)));
        @memset(by_event, none);
        @memset(by_column, none);
        for (slots, 0..) |*slot, index| slot.next = if (index + 1 < slots.len) @intCast(index + 1) else none;
        for (column_states, 0..) |*state, index| state.* = .{
            .column = .{ .world = 0, .x = 0, .z = 0 },
            .parked = true,
            .live = false,
            .next_free = if (index + 1 < column_states.len) @intCast(index + 1) else none,
        };
        return .{ .slots = slots, .free = 0, .heap = heap, .by_event = by_event, .column_states = column_states, .column_free = 0, .by_column = by_column };
    }

    pub fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        allocator.free(self.slots);
        allocator.free(self.heap);
        allocator.free(self.by_event);
        allocator.free(self.column_states);
        allocator.free(self.by_column);
        self.* = undefined;
    }

    /// The column's state, if it has events or was tracked.
    pub fn columnState(self: *const Queue, column: Column) ?*ColumnState {
        const at = self.findColumn(column) orelse return null;
        return &self.column_states[self.by_column[at]];
    }

    /// Starts keeping events for a column, ticking or parked. A tracked column stays until `forget`.
    pub fn track(self: *Queue, column: Column, parked: bool) error{ColumnCapacity}!*ColumnState {
        if (self.columnState(column)) |state| return state;
        const index = self.column_free;
        if (index == none) return error.ColumnCapacity;
        self.column_free = self.column_states[index].next_free;
        self.column_states[index] = .{ .column = column, .parked = parked };
        self.column_count += 1;
        var at = self.columnHome(column);
        while (self.by_column[at] != none) at = (at + 1) & (self.by_column.len - 1);
        self.by_column[at] = index;
        return &self.column_states[index];
    }

    /// Drops a column and its events, as once they are saved.
    pub fn forget(self: *Queue, column: Column) void {
        const at = self.findColumn(column) orelse return;
        const index = self.by_column[at];
        const state = &self.column_states[index];
        while (state.head != none) self.remove(state.head);
        assert(state.count == 0);
        self.removeColumnIndex(at);
        state.live = false;
        state.next_free = self.column_free;
        self.column_free = index;
        self.column_count -= 1;
    }

    /// Whether a tick of this kind is scheduled at the block, ticking or parked.
    pub fn scheduled(self: *const Queue, event: Event) bool {
        return self.findEvent(event) != null;
    }

    pub const Scheduled = enum { added, present };

    /// Schedules an event in a tracked column `delay` ticks from now. An event of the same kind at
    /// the same block keeps its time, as in vanilla.
    pub fn schedule(self: *Queue, event: Event, delay: u64) error{ Untracked, EventCapacity }!Scheduled {
        const column = Column.of(event.world, event.position);
        const column_at = self.findColumn(column) orelse return error.Untracked;
        if (self.findEvent(event) != null) return .present;
        const index = self.free;
        if (index == none) return error.EventCapacity;
        self.free = self.slots[index].next;
        self.used += 1;
        const column_index = self.by_column[column_at];
        const state = &self.column_states[column_index];
        self.slots[index] = .{
            .event = event,
            .time = if (state.parked) delay else self.now + delay,
            .sequence = self.sequence,
            .heap = none,
            .column = column_index,
            .next = state.head,
            .previous = none,
        };
        self.sequence += 1;
        if (state.head != none) self.slots[state.head].previous = index;
        state.head = index;
        state.count += 1;
        state.dirty = true;
        var at = self.eventHome(event);
        while (self.by_event[at] != none) at = (at + 1) & (self.by_event.len - 1);
        self.by_event[at] = index;
        if (!state.parked) self.push(index);
        return .added;
    }

    /// Advances the game tick. Events whose time has come are due after this.
    pub fn advance(self: *Queue) void {
        self.now += 1;
    }

    /// Takes due events in run order, at most `output.len`. Events not taken stay due.
    pub fn takeDue(self: *Queue, output: []Event) usize {
        var count: usize = 0;
        while (count < output.len and self.heap_count != 0) {
            const top = self.heap[0];
            if (self.slots[top].time > self.now) break;
            output[count] = self.slots[top].event;
            count += 1;
            self.remove(top);
        }
        return count;
    }

    /// The column stops ticking. Its events keep the delay they had left.
    pub fn park(self: *Queue, column: Column) void {
        const state = self.columnState(column) orelse return;
        if (state.parked) return;
        state.parked = true;
        var index = state.head;
        while (index != none) : (index = self.slots[index].next) {
            const slot = &self.slots[index];
            self.heapRemove(slot.heap);
            slot.time -|= self.now;
        }
    }

    /// The column ticks again. Its events run their delay from now.
    pub fn unpark(self: *Queue, column: Column) void {
        const state = self.columnState(column) orelse return;
        if (!state.parked) return;
        state.parked = false;
        var index = state.head;
        while (index != none) : (index = self.slots[index].next) {
            self.slots[index].time += self.now;
            self.push(index);
        }
    }

    /// Lists a column's events with the delay each has left, in the order they were scheduled.
    /// Returns how many there are, which may be more than `output` holds.
    pub fn pending(self: *const Queue, column: Column, output: []Pending) usize {
        const state = self.columnState(column) orelse return 0;
        // The list runs newest first. Filling from the back keeps scheduling order.
        var index = state.head;
        var remaining: usize = state.count;
        while (index != none) : (index = self.slots[index].next) {
            remaining -= 1;
            const slot = self.slots[index];
            if (remaining < output.len) output[remaining] = .{ .event = slot.event, .delay = if (state.parked) slot.time else slot.time -| self.now };
        }
        assert(remaining == 0);
        return state.count;
    }

    fn remove(self: *Queue, index: u32) void {
        const slot = &self.slots[index];
        if (slot.heap != none) self.heapRemove(slot.heap);
        const state = &self.column_states[slot.column];
        if (slot.previous != none) self.slots[slot.previous].next = slot.next else state.head = slot.next;
        if (slot.next != none) self.slots[slot.next].previous = slot.previous;
        state.count -= 1;
        state.dirty = true;
        self.removeEventIndex(self.findEvent(slot.event).?);
        slot.next = self.free;
        self.free = index;
        self.used -= 1;
    }

    fn eventHome(self: *const Queue, event: Event) usize {
        return @intCast(event.hash() & (self.by_event.len - 1));
    }

    fn columnHome(self: *const Queue, column: Column) usize {
        return @intCast(column.hash() & (self.by_column.len - 1));
    }

    fn findEvent(self: *const Queue, event: Event) ?usize {
        var at = self.eventHome(event);
        while (self.by_event[at] != none) : (at = (at + 1) & (self.by_event.len - 1)) {
            if (self.slots[self.by_event[at]].event.same(event)) return at;
        }
        return null;
    }

    fn findColumn(self: *const Queue, column: Column) ?usize {
        var at = self.columnHome(column);
        while (self.by_column[at] != none) : (at = (at + 1) & (self.by_column.len - 1)) {
            if (std.meta.eql(self.column_states[self.by_column[at]].column, column)) return at;
        }
        return null;
    }

    fn removeEventIndex(self: *Queue, start: usize) void {
        const mask = self.by_event.len - 1;
        var hole = start;
        var at = (start + 1) & mask;
        while (self.by_event[at] != none) : (at = (at + 1) & mask) {
            const home = self.eventHome(self.slots[self.by_event[at]].event);
            // An entry moves back into the hole unless its home lies between the hole and it.
            if ((at -% home) & mask >= (at -% hole) & mask) {
                self.by_event[hole] = self.by_event[at];
                hole = at;
            }
        }
        self.by_event[hole] = none;
    }

    fn removeColumnIndex(self: *Queue, start: usize) void {
        const mask = self.by_column.len - 1;
        var hole = start;
        var at = (start + 1) & mask;
        while (self.by_column[at] != none) : (at = (at + 1) & mask) {
            const home = self.columnHome(self.column_states[self.by_column[at]].column);
            if ((at -% home) & mask >= (at -% hole) & mask) {
                self.by_column[hole] = self.by_column[at];
                hole = at;
            }
        }
        self.by_column[hole] = none;
    }

    fn before(self: *const Queue, a: u32, b: u32) bool {
        const first = &self.slots[a];
        const second = &self.slots[b];
        if (first.time != second.time) return first.time < second.time;
        if (first.event.priority != second.event.priority) return @backingInt(first.event.priority) < @backingInt(second.event.priority);
        return first.sequence < second.sequence;
    }

    fn place(self: *Queue, at: u32, index: u32) void {
        self.heap[at] = index;
        self.slots[index].heap = at;
    }

    fn push(self: *Queue, index: u32) void {
        assert(self.slots[index].heap == none and self.heap_count < self.heap.len);
        self.heap_count += 1;
        self.place(self.heap_count - 1, index);
        self.siftUp(self.heap_count - 1);
    }

    fn heapRemove(self: *Queue, at: u32) void {
        assert(at < self.heap_count);
        const removed = self.heap[at];
        self.slots[removed].heap = none;
        self.heap_count -= 1;
        if (at == self.heap_count) return;
        self.place(at, self.heap[self.heap_count]);
        self.siftDown(at);
        self.siftUp(self.slots[self.heap[at]].heap);
    }

    fn siftUp(self: *Queue, start: u32) void {
        var at = start;
        while (at > 0) {
            const parent = (at - 1) / 2;
            if (!self.before(self.heap[at], self.heap[parent])) break;
            const moved = self.heap[parent];
            self.place(parent, self.heap[at]);
            self.place(at, moved);
            at = parent;
        }
    }

    fn siftDown(self: *Queue, start: u32) void {
        var at = start;
        while (true) {
            var best = at;
            for ([_]u32{ 2 * at + 1, 2 * at + 2 }) |child| {
                if (child < self.heap_count and self.before(self.heap[child], self.heap[best])) best = child;
            }
            if (best == at) return;
            const moved = self.heap[best];
            self.place(best, self.heap[at]);
            self.place(at, moved);
            at = best;
        }
    }
};

fn eventAt(world: u32, x: i32, y: i32, z: i32, kind: Kind) Event {
    return .{ .world = world, .position = .{ .x = x, .y = y, .z = z }, .kind = kind };
}

test "due events run in trigger, priority and scheduling order and duplicates keep their time" {
    var queue = try Queue.init(std.testing.allocator, .{ .events = 8, .columns = 2 });
    defer queue.deinit(std.testing.allocator);
    _ = try queue.track(.{ .world = 0, .x = 0, .z = 0 }, false);
    try std.testing.expectEqual(Queue.Scheduled.added, try queue.schedule(eventAt(0, 1, 0, 0, 0), 2));
    var urgent = eventAt(0, 2, 0, 0, 0);
    urgent.priority = .high;
    try std.testing.expectEqual(Queue.Scheduled.added, try queue.schedule(urgent, 2));
    try std.testing.expectEqual(Queue.Scheduled.added, try queue.schedule(eventAt(0, 3, 0, 0, 0), 1));
    try std.testing.expectEqual(Queue.Scheduled.added, try queue.schedule(eventAt(0, 4, 0, 0, 0), 2));
    // The same kind at the same block keeps the first time.
    try std.testing.expectEqual(Queue.Scheduled.present, try queue.schedule(eventAt(0, 3, 0, 0, 0), 5));
    try std.testing.expectError(error.Untracked, queue.schedule(eventAt(0, 16, 0, 0, 0), 1));
    var due: [8]Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), queue.takeDue(&due));
    queue.advance();
    try std.testing.expectEqual(@as(usize, 1), queue.takeDue(&due));
    try std.testing.expectEqual(@as(i32, 3), due[0].position.x);
    queue.advance();
    try std.testing.expectEqual(@as(usize, 3), queue.takeDue(&due));
    try std.testing.expectEqual([3]i32{ 2, 1, 4 }, .{ due[0].position.x, due[1].position.x, due[2].position.x });
    try std.testing.expectEqual(@as(u32, 0), queue.used);
}

test "parked columns keep the delay they had left and resume from it" {
    var queue = try Queue.init(std.testing.allocator, .{ .events = 4, .columns = 2 });
    defer queue.deinit(std.testing.allocator);
    const column: Column = .{ .world = 0, .x = 0, .z = 0 };
    _ = try queue.track(column, false);
    _ = try queue.schedule(eventAt(0, 1, 0, 0, 0), 5);
    queue.advance();
    queue.advance();
    queue.park(column);
    for (0..100) |_| queue.advance();
    var due: [4]Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), queue.takeDue(&due));
    var listed: [4]Pending = undefined;
    try std.testing.expectEqual(@as(usize, 1), queue.pending(column, &listed));
    try std.testing.expectEqual(@as(u64, 3), listed[0].delay);
    // Scheduling into a parked column counts its delay from when the column resumes.
    _ = try queue.schedule(eventAt(0, 2, 0, 0, 0), 1);
    queue.unpark(column);
    queue.advance();
    try std.testing.expectEqual(@as(usize, 1), queue.takeDue(&due));
    try std.testing.expectEqual(@as(i32, 2), due[0].position.x);
    queue.advance();
    queue.advance();
    try std.testing.expectEqual(@as(usize, 1), queue.takeDue(&due));
    try std.testing.expectEqual(@as(i32, 1), due[0].position.x);
    queue.forget(column);
    try std.testing.expect(queue.columnState(column) == null);
}

test "a random schedule matches a linear model and never outgrows its memory" {
    const allocator = std.testing.allocator;
    var queue = try Queue.init(allocator, .{ .events = 64, .columns = 4 });
    defer queue.deinit(allocator);
    const Model = struct { event: Event, time: u64, sequence: u64, parked: bool };
    var model: [64]Model = undefined;
    var model_count: usize = 0;
    var sequence: u64 = 0;
    var parked: [4]bool = @splat(false);
    for (0..4) |x| _ = try queue.track(.{ .world = 0, .x = @intCast(x), .z = 0 }, false);
    var random = std.Random.DefaultPrng.init(0x71636b73);
    const rng = random.random();
    for (0..20000) |_| {
        switch (rng.uintLessThan(u8, 8)) {
            0, 1, 2 => {
                var event = eventAt(0, @as(i32, rng.uintLessThan(u8, 64)), rng.intRangeAtMost(i32, -2, 2), 0, rng.uintLessThan(Kind, 2));
                event.priority = @fromBackingInt(@intCast(rng.intRangeAtMost(i8, -3, 3)));
                const delay = rng.uintLessThan(u64, 6);
                const exists = for (model[0..model_count]) |entry| {
                    if (entry.event.same(event)) break true;
                } else false;
                const result = queue.schedule(event, delay) catch |err| {
                    try std.testing.expectEqual(error.EventCapacity, err);
                    try std.testing.expect(!exists and model_count == model.len);
                    continue;
                };
                try std.testing.expectEqual(exists, result == .present);
                if (!exists) {
                    const column: usize = @intCast(event.position.x >> 4);
                    model[model_count] = .{ .event = event, .time = if (parked[column]) delay else queue.now + delay, .sequence = sequence, .parked = parked[column] };
                    model_count += 1;
                    sequence += 1;
                }
            },
            3 => {
                const column = rng.uintLessThan(usize, 4);
                const id: Column = .{ .world = 0, .x = @intCast(column), .z = 0 };
                if (parked[column]) queue.unpark(id) else queue.park(id);
                for (model[0..model_count]) |*entry| if (entry.event.position.x >> 4 == column) {
                    if (parked[column]) entry.time += queue.now else entry.time -|= queue.now;
                    entry.parked = !parked[column];
                };
                parked[column] = !parked[column];
            },
            else => {
                queue.advance();
                var due: [64]Event = undefined;
                const limit = rng.uintLessThan(usize, 9);
                const count = queue.takeDue(due[0..limit]);
                for (due[0..count]) |event| {
                    // The model's next is the earliest unparked due event.
                    var best: ?usize = null;
                    for (model[0..model_count], 0..) |entry, index| {
                        if (entry.parked or entry.time > queue.now) continue;
                        if (best) |other| {
                            const b = model[other];
                            if (entry.time > b.time) continue;
                            if (entry.time == b.time and @backingInt(entry.event.priority) > @backingInt(b.event.priority)) continue;
                            if (entry.time == b.time and entry.event.priority == b.event.priority and entry.sequence > b.sequence) continue;
                        }
                        best = index;
                    }
                    try std.testing.expect(model[best.?].event.same(event));
                    model[best.?] = model[model_count - 1];
                    model_count -= 1;
                }
            },
        }
        try std.testing.expectEqual(model_count, queue.used);
    }
}
