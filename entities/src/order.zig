//! The order entities tick in, as vanilla's entity tick list keeps it: each entity in a ticking
//! column has a place, given as it joins, so one that leaves and comes back goes last. Where an
//! entity stands is its directory entry's: its place, its sequence, and whether it is awake. The
//! rows of each kind's table lie in that order, so a pass walks the kinds' tables side by side,
//! taking the next awake row of whichever comes first, and the dormant woken by their places.
//!
//! A pass sees the list as it stood when it began, as vanilla's copy on first change does:
//! entities joining during it tick from the next pass; one that left before its turn is passed
//! over, as vanilla's chunk check passes it over; one that left and joined again before its
//! turn is still met at its old place, where vanilla's copy meets it in a chunk that ticks. A
//! sleeper woken before its turn takes it.
//!
//! A sleeper stays among the ticking, passed over, for a while: asleep `doze_ticks` its row goes
//! to its table's dormant part, and back at its place when it wakes.

const std = @import("std");
const pool_module = @import("pool.zig");
const directory_module = @import("directory.zig");
const kind_table = @import("kind_table.zig");

const assert = std.debug.assert;
const Array = pool_module.Array;
const Directory = directory_module.Directory;
const Core = kind_table.Core;

pub const Id = u64;
pub const max_kinds = 256;

/// An entity's place, and its kind, which says what ticks it, and its slot.
pub const Entry = struct { sequence: u64, id: Id, kind: u32, slot: u32 };

pub const Order = struct {
    directory: *Directory,
    next: u64 = 1,
    /// Each kind's table, and the tables the pass walks, each once.
    cores: [max_kinds]?*Core = @splat(null),
    walked: [max_tables]*Core = undefined,
    walked_count: usize = 0,
    member_count: usize = 0,
    awake_count: usize = 0,
    pass: ?PassState = null,
    /// Woken during a run whose turn the pass had already taken past: met as soon as the run
    /// is done, in place order.
    late: Array(Entry),
    late_count: usize = 0,
    late_at: usize = 0,
    /// Those fallen asleep, oldest first, to go dormant if still asleep `doze_ticks` on.
    sleepers: Array(Sleeper),
    sleepers_at: usize = 0,
    sleepers_count: usize = 0,
    /// Passes begun.
    tick: u32 = 0,

    pub const max_tables = 16;
    /// Ticks a sleeper stays among the ticking before its row goes dormant.
    pub const doze_ticks = 20;

    const Sleeper = struct { id: Id, slot: u32, since: u32 };

    /// `floor`: the place before the run under way, past which a sleeper woken behind the pass
    /// is met late rather than next pass.
    const PassState = struct { end: u64, last: u64 = 0, floor: u64 = 0 };

    pub fn init(allocator: std.mem.Allocator, pool: *pool_module.Pool, directory: *Directory) !Order {
        return .{ .directory = directory, .late = try .init(allocator, pool), .sleepers = try .init(allocator, pool) };
    }

    /// A kind's entities have their rows in `core`.
    pub fn addTable(self: *Order, kind: u32, core: *Core) !void {
        if (kind >= max_kinds) return error.InvalidKind;
        if (self.cores[kind] != null) return error.KindTableTaken;
        self.cores[kind] = core;
        for (self.walked[0..self.walked_count]) |walked| if (walked == core) return;
        if (self.walked_count == max_tables) return error.TooManyTables;
        self.walked[self.walked_count] = core;
        self.walked_count += 1;
    }

    pub fn count(self: *const Order) usize {
        return self.member_count;
    }

    pub fn awakeCount(self: *const Order) usize {
        return self.awake_count;
    }

    fn slotOf(self: *const Order, entity: Id) ?u32 {
        return self.directory.slotOf(entity);
    }

    fn coreOf(self: *const Order, slot: u32) ?*Core {
        return self.cores[self.directory.entry(slot).kind];
    }

    pub fn sequenceOf(self: *const Order, entity: Id) ?u64 {
        return self.sequenceAt(self.slotOf(entity) orelse return null);
    }

    pub fn sequenceAt(self: *const Order, slot: u32) ?u64 {
        const sequence = self.directory.entry(slot).sequence;
        return if (sequence == 0) null else sequence;
    }

    pub fn isAwake(self: *const Order, entity: Id) bool {
        return self.directory.entry(self.slotOf(entity) orelse return false).awake;
    }

    /// The entity takes the last place, awake. One already placed keeps its place.
    pub fn join(self: *Order, entity: Id) !u64 {
        return self.joinSlot(self.slotOf(entity) orelse return error.NotInMemory);
    }

    pub fn joinSlot(self: *Order, slot: u32) !u64 {
        const entry = self.directory.entry(slot);
        if (entry.sequence != 0) return entry.sequence;
        entry.sequence = self.next;
        entry.awake = true;
        self.next += 1;
        self.member_count += 1;
        self.awake_count += 1;
        if (self.coreOf(slot)) |core| _ = try core.comeBack(slot);
        return entry.sequence;
    }

    pub fn leave(self: *Order, entity: Id) void {
        self.leaveSlot(self.slotOf(entity) orelse return);
    }

    pub fn leaveSlot(self: *Order, slot: u32) void {
        const entry = self.directory.entry(slot);
        if (entry.sequence == 0) return;
        if (entry.awake) self.awake_count -= 1;
        self.member_count -= 1;
        entry.sequence = 0;
        entry.awake = false;
        if (self.coreOf(slot)) |core| core.goDormant(slot);
    }

    /// The entity stops being walked, keeping its place.
    pub fn sleep(self: *Order, entity: Id) void {
        self.sleepSlot(self.slotOf(entity) orelse return);
    }

    pub fn sleepSlot(self: *Order, slot: u32) void {
        const entry = self.directory.entry(slot);
        if (entry.sequence == 0 or !entry.awake) return;
        entry.awake = false;
        self.awake_count -= 1;
        entry.slept = self.tick;
        const core = self.coreOf(slot) orelse return;
        core.showAwake(slot);
        if (entry.block == directory_module.none or entry.dormant) return;
        self.sleepers.ensure(self.sleepers_count + 1) catch return;
        self.sleepers.at(self.sleepers_count).* = .{ .id = entry.id, .slot = slot, .since = self.tick };
        self.sleepers_count += 1;
    }

    /// The entity stops being walked for long: its row goes dormant at the tick's end.
    pub fn sleepLong(self: *Order, entity: Id) void {
        self.sleepLongSlot(self.slotOf(entity) orelse return);
    }

    pub fn sleepLongSlot(self: *Order, slot: u32) void {
        const entry = self.directory.entry(slot);
        if (entry.sequence == 0) return;
        if (entry.awake) {
            entry.awake = false;
            self.awake_count -= 1;
        }
        if (self.coreOf(slot)) |core| core.goDormant(slot);
    }

    pub fn wake(self: *Order, entity: Id) !void {
        try self.wakeSlot(self.slotOf(entity) orelse return);
    }

    pub fn wakeSlot(self: *Order, slot: u32) !void {
        const entry = self.directory.entry(slot);
        if (entry.sequence == 0 or entry.awake) return;
        entry.awake = true;
        self.awake_count += 1;
        const core = self.coreOf(slot) orelse return;
        const back = try core.comeBack(slot);
        const pass = self.pass orelse return;
        if (entry.sequence <= pass.last) {
            if (entry.sequence > pass.floor) {
                try self.late.ensure(self.late_count + 1);
                self.late.at(self.late_count).* = .{ .sequence = entry.sequence, .id = entry.id, .kind = entry.kind, .slot = slot };
                self.late_count += 1;
            }
        } else if (!back) core.rewind(slot);
    }

    /// A run of entities is about to tick, all placed after `floor`: a sleeper one of them wakes
    /// that comes before the pass's place but after `floor` is still met, by `takeLate`.
    pub fn beginRun(self: *Order, floor: u64) void {
        const pass = &(self.pass orelse unreachable);
        pass.floor = floor;
        self.late_count = 0;
        self.late_at = 0;
    }

    /// The next sleeper woken late in the run just done, in place order, or null.
    pub fn takeLate(self: *Order) ?Entry {
        const pass = self.pass orelse unreachable;
        if (self.late_at < self.late_count) {
            if (self.late.run(self.late_at, self.late_count)) |pending| std.sort.pdq(Entry, pending, {}, before) else {
                const Sort = struct {
                    values: *Array(Entry),
                    pub fn lessThan(sort: @This(), a: usize, b: usize) bool {
                        return sort.values.at(a).sequence < sort.values.at(b).sequence;
                    }
                    pub fn swap(sort: @This(), a: usize, b: usize) void {
                        std.mem.swap(Entry, sort.values.at(a), sort.values.at(b));
                    }
                };
                std.sort.pdqContext(self.late_at, self.late_count, Sort{ .values = &self.late });
            }
        }
        while (self.late_at < self.late_count) {
            const entry = self.late.at(self.late_at).*;
            self.late_at += 1;
            if (self.current(entry.slot, entry.id, entry.sequence, pass.end)) return entry;
        }
        return null;
    }

    /// Whether a place still stands for its entity in the pass under way.
    fn current(self: *const Order, slot: u32, id: Id, sequence: u64, pass_end: u64) bool {
        const entry = self.directory.entry(slot);
        if (entry.id != id or !entry.awake) return false;
        if (entry.sequence == sequence) return true;
        // Placed again since the pass began: vanilla's copy still meets it here.
        return entry.sequence > pass_end;
    }

    pub fn begin(self: *Order) !void {
        assert(self.pass == null);
        self.tick +%= 1;
        self.pass = .{ .end = self.next - 1 };
        for (self.walked[0..self.walked_count]) |core| core.beginPass();
    }

    /// The next awake entity in the pass, or null at its end.
    pub fn nextInPass(self: *Order) ?Entry {
        const pass = &(self.pass orelse unreachable);
        while (true) {
            var best_sequence: u64 = std.math.maxInt(u64);
            var best_core: ?*Core = null;
            var best_woken = false;
            for (self.walked[0..self.walked_count]) |core| {
                if (core.head()) |found| if (found.sequence < best_sequence) {
                    best_sequence = found.sequence;
                    best_core = core;
                    best_woken = false;
                };
                while (core.wakingHead()) |woken| {
                    // Woken before their turn this pass, or after it: the latter wait for the next.
                    if (woken.sequence <= pass.last) {
                        core.takeWakingHead();
                        continue;
                    }
                    if (woken.sequence < best_sequence) {
                        best_sequence = woken.sequence;
                        best_core = core;
                        best_woken = true;
                    }
                    break;
                }
            }
            const core = best_core orelse return null;
            if (best_sequence > pass.end) return null;
            var slot: u32 = undefined;
            var id: Id = undefined;
            if (best_woken) {
                const woken = core.wakingHead().?;
                core.takeWakingHead();
                slot = woken.slot;
                id = woken.id;
            } else {
                const found = core.head().?;
                core.takeHead();
                slot = found.slot;
                id = found.id;
            }
            // One asleep and woken again before its turn is met once.
            if (best_sequence <= pass.last) continue;
            pass.last = best_sequence;
            if (self.current(slot, id, best_sequence, pass.end)) return .{ .sequence = best_sequence, .id = id, .kind = self.directory.entry(slot).kind, .slot = slot };
        }
    }

    pub fn end(self: *Order) void {
        assert(self.pass != null);
        self.pass = null;
    }

    /// At the tick's end, before the tables are maintained: those asleep long enough go dormant.
    pub fn endTick(self: *Order) void {
        while (self.sleepers_at < self.sleepers_count) {
            const sleeper = self.sleepers.at(self.sleepers_at).*;
            if (self.tick -% sleeper.since < doze_ticks) break;
            self.sleepers_at += 1;
            const entry = self.directory.entry(sleeper.slot);
            if (entry.id != sleeper.id or entry.sequence == 0 or entry.awake or entry.slept != sleeper.since) continue;
            if (self.coreOf(sleeper.slot)) |core| core.goDormant(sleeper.slot);
        }
        if (self.sleepers_at == self.sleepers_count) {
            self.sleepers_at = 0;
            self.sleepers_count = 0;
        } else if (self.sleepers_at >= 4096 and self.sleepers_at * 2 >= self.sleepers_count) {
            const left = self.sleepers_count - self.sleepers_at;
            for (0..left) |at| self.sleepers.at(at).* = self.sleepers.at(self.sleepers_at + at).*;
            self.sleepers_at = 0;
            self.sleepers_count = left;
        }
    }

    fn before(_: void, a: Entry, b: Entry) bool {
        return a.sequence < b.sequence;
    }
};

const testing = std.testing;

const Fixture = struct {
    pool: pool_module.Pool,
    directory: Directory,
    table: kind_table.Table(struct { value: u32 }),
    order: Order,

    fn init(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.pool = try .init(allocator, 32 * pool_module.page_bytes);
        self.directory = try .init(allocator, &self.pool, 256);
        self.table = try .init(allocator, &self.pool, &self.directory);
        self.order = try .init(allocator, &self.pool, &self.directory);
        try self.order.addTable(0, &self.table.core);
    }

    /// The entity joins, coming into memory first if it is not.
    fn join(self: *Fixture, entity: Id) !void {
        if (self.directory.slotOf(entity)) |_| {
            _ = try self.order.join(entity);
            return;
        }
        const slot = try self.directory.add(entity, 0);
        _ = try self.order.joinSlot(slot);
        try self.table.add(slot, .{ .value = @intCast(entity) }, false);
    }

    fn passIds(self: *Fixture, output: []Id) ![]Id {
        self.order.endTick();
        try self.table.maintain();
        try self.order.begin();
        defer self.order.end();
        var n: usize = 0;
        while (self.order.nextInPass()) |entry| {
            output[n] = entry.id;
            n += 1;
        }
        return output[0..n];
    }
};

test "a pass walks the awake in the order they joined" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator());
    const order = &fixture.order;
    for ([_]Id{ 5, 3, 9, 1 }) |entity| try fixture.join(entity);
    order.sleep(3);
    var buffer: [8]Id = undefined;
    try testing.expectEqualSlices(Id, &.{ 5, 9, 1 }, try fixture.passIds(&buffer));
    // Woken, it ticks in its own place; one that leaves and comes back goes last.
    try order.wake(3);
    order.leave(5);
    try fixture.join(5);
    try testing.expectEqualSlices(Id, &.{ 3, 9, 1, 5 }, try fixture.passIds(&buffer));
    try testing.expectEqual(@as(usize, 4), order.awakeCount());
}

test "a pass sees the list as it began, as vanilla's copy does" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator());
    const order = &fixture.order;
    for ([_]Id{ 1, 2, 3, 4 }) |entity| try fixture.join(entity);
    order.sleep(4);
    try fixture.table.maintain();
    try order.begin();
    var seen: [8]Id = undefined;
    var n: usize = 0;
    while (order.nextInPass()) |entry| {
        seen[n] = entry.id;
        n += 1;
        if (entry.id == 1) {
            // Joining now ticks from the next pass; leaving before one's turn passes it over;
            // leaving and joining again before it meets it at its old place.
            try fixture.join(7);
            order.leave(2);
            order.leave(3);
            try fixture.join(3);
            // Woken ahead of the pass, it takes its turn.
            try order.wake(4);
        }
    }
    order.end();
    try testing.expectEqualSlices(Id, &.{ 1, 3, 4 }, seen[0..n]);
    var buffer: [8]Id = undefined;
    try testing.expectEqualSlices(Id, &.{ 1, 4, 7, 3 }, try fixture.passIds(&buffer));
}

test "one woken behind the pass waits for the next" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator());
    const order = &fixture.order;
    for ([_]Id{ 1, 2, 3 }) |entity| try fixture.join(entity);
    order.sleep(1);
    try order.begin();
    var seen: [8]Id = undefined;
    var n: usize = 0;
    while (order.nextInPass()) |entry| {
        seen[n] = entry.id;
        n += 1;
        if (entry.id == 2) try order.wake(1);
    }
    order.end();
    try testing.expectEqualSlices(Id, &.{ 2, 3 }, seen[0..n]);
    var buffer: [8]Id = undefined;
    try testing.expectEqualSlices(Id, &.{ 1, 2, 3 }, try fixture.passIds(&buffer));
}

test "asleep and woken again before its turn, an entity ticks once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator());
    const order = &fixture.order;
    for ([_]Id{ 1, 2, 3 }) |entity| try fixture.join(entity);
    // Between passes.
    order.sleep(2);
    try order.wake(2);
    var buffer: [8]Id = undefined;
    try testing.expectEqualSlices(Id, &.{ 1, 2, 3 }, try fixture.passIds(&buffer));
    // Within a pass, ahead of its turn.
    try order.begin();
    var n: usize = 0;
    while (order.nextInPass()) |entry| {
        buffer[n] = entry.id;
        n += 1;
        if (entry.id == 1) {
            order.sleep(3);
            try order.wake(3);
        }
    }
    order.end();
    try testing.expectEqualSlices(Id, &.{ 1, 2, 3 }, buffer[0..n]);
    try testing.expectEqualSlices(Id, &.{ 1, 2, 3 }, try fixture.passIds(&buffer));
}

test "an entity joined again before its turn is still met at its old place" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator());
    const order = &fixture.order;
    for ([_]Id{ 1, 2, 3 }) |entity| try fixture.join(entity);
    try order.begin();
    var seen: [8]Id = undefined;
    var n: usize = 0;
    while (order.nextInPass()) |entry| {
        seen[n] = entry.id;
        n += 1;
        if (entry.id == 1) {
            order.leave(3);
            order.leave(2);
            try fixture.join(3);
        }
    }
    order.end();
    try testing.expectEqualSlices(Id, &.{ 1, 3 }, seen[0..n]);
    var buffer: [8]Id = undefined;
    try testing.expectEqualSlices(Id, &.{ 1, 3 }, try fixture.passIds(&buffer));
}

test "sleepers doze off to the dormant part and come back at their places" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator());
    const order = &fixture.order;
    for (1..201) |entity| try fixture.join(entity);
    var buffer: [256]Id = undefined;
    for (1..201) |entity| if (entity % 3 == 0) order.sleep(entity);
    for (0..Order.doze_ticks + 1) |_| _ = try fixture.passIds(&buffer);
    try testing.expect(fixture.table.isDormant(fixture.directory.slotOf(3).?));
    try testing.expect(!fixture.table.isDormant(fixture.directory.slotOf(4).?));
    // Woken between passes and during one, ahead of the pass.
    try order.wake(99);
    try order.begin();
    var n: usize = 0;
    while (order.nextInPass()) |entry| {
        buffer[n] = entry.id;
        n += 1;
        if (entry.id == 100) try order.wake(150);
    }
    order.end();
    var expected: [256]Id = undefined;
    var m: usize = 0;
    for (1..201) |entity| if (entity % 3 != 0 or entity == 99 or entity == 150) {
        expected[m] = entity;
        m += 1;
    };
    try testing.expectEqualSlices(Id, expected[0..m], buffer[0..n]);
    try testing.expectEqualSlices(Id, expected[0..m], try fixture.passIds(&buffer));
    try testing.expect(!fixture.table.isDormant(fixture.directory.slotOf(150).?));
}

test "random joins, leaves, sleeps and wakes keep the pass in place order and the rows whole" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var pool = try pool_module.Pool.init(allocator, 256 * pool_module.page_bytes);
    var directory = try Directory.init(allocator, &pool, 4096);
    const Wide = kind_table.Table(struct { value: u64, wide: [300]u8 });
    var table = try Wide.init(allocator, &pool, &directory);
    var order = try Order.init(allocator, &pool, &directory);
    try order.addTable(0, &table.core);
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    const Model = struct { present: bool = false, sequence: u64 = 0, awake: bool = false };
    var model: [700]Model = @splat(.{});
    var expected: [700]Id = undefined;
    var seen: [700]Id = undefined;
    for (0..20_000) |step| {
        const at = random.uintLessThan(usize, model.len);
        const entity: Id = at + 1;
        const state = &model[at];
        if (!state.present) {
            const slot = try directory.add(entity, 0);
            if (random.boolean()) {
                state.sequence = try order.joinSlot(slot);
                state.awake = true;
            }
            try table.add(slot, .{ .value = entity, .wide = @splat(@truncate(entity)) }, random.uintLessThan(u8, 8) == 0);
            state.present = true;
        } else switch (random.uintLessThan(u8, 7)) {
            0 => {
                const slot = directory.slotOf(entity).?;
                order.leaveSlot(slot);
                table.remove(slot);
                directory.remove(slot);
                state.* = .{};
            },
            1 => {
                state.sequence = try order.join(entity);
                if (state.sequence != 0 and !state.awake and order.isAwake(entity)) state.awake = true;
            },
            2 => {
                order.leave(entity);
                state.sequence = 0;
                state.awake = false;
            },
            3 => {
                order.sleep(entity);
                state.awake = false;
            },
            4 => {
                order.sleepLong(entity);
                state.awake = false;
            },
            else => {
                try order.wake(entity);
                if (state.sequence != 0) state.awake = true;
            },
        }
        if (step % 37 != 0) continue;
        order.endTick();
        try table.maintain();
        var n: usize = 0;
        var m: usize = 0;
        for (model, 0..) |entry, index| if (entry.present and entry.sequence != 0 and entry.awake) {
            expected[m] = index + 1;
            m += 1;
        };
        std.sort.pdq(Id, expected[0..m], &model, struct {
            fn less(states: *const [700]Model, a: Id, b: Id) bool {
                return states[a - 1].sequence < states[b - 1].sequence;
            }
        }.less);
        try order.begin();
        while (order.nextInPass()) |entry| {
            seen[n] = entry.id;
            n += 1;
        }
        order.end();
        try testing.expectEqualSlices(Id, expected[0..m], seen[0..n]);
        // Every row is where the directory says, whole.
        for (model, 0..) |entry, index| {
            if (!entry.present) continue;
            const row = table.ref(directory.slotOf(index + 1).?);
            try testing.expectEqual(@as(u64, index + 1), row.field("value").*);
            try testing.expectEqual(@as(u8, @truncate(index + 1)), row.field("wide")[299]);
        }
    }
}
