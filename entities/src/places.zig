//! Where entities are and which of them tick: the space every entity of every kind has a place
//! in, and the tick order of those in ticking columns, kept together as entities come, move and
//! go, and as columns start and stop ticking. As vanilla's entity sections and entity list go
//! together: an entity moving into a column that does not tick stops at once, and one coming
//! back, or in a column that starts ticking, joins the order at the end.

const std = @import("std");
const pool_module = @import("pool.zig");
const space_module = @import("space.zig");
const order_module = @import("order.zig");
const directory_module = @import("directory.zig");
const kind_table = @import("kind_table.zig");

pub const Id = u64;
pub const Column = space_module.Column;
pub const Space = space_module.Space;
pub const Shape = space_module.Shape;
pub const Kinds = space_module.Kinds;
pub const Order = order_module.Order;

/// Told of an entity that stopped ticking, as its column did or it moved out of one that ticks.
pub const Stopped = struct {
    context: *anyopaque,
    function: *const fn (*anyopaque, Id) void,
};

pub const Places = struct {
    space: Space,
    order: Order,
    /// Columns starting, sorted to start in order; those a resync finds starting and stopping;
    /// and a starting column's entities, sorted to join.
    joining: pool_module.Array(Column),
    entering: pool_module.Array(Column),
    stopping: pool_module.Array(Column),
    starting: pool_module.Array(space_module.Entry),
    /// Told when entities of their kinds stop.
    stopped: [max_watchers]Watcher = undefined,
    stopped_count: usize = 0,
    /// Rises whenever a column starts or stops ticking.
    ticking_revision: u64 = 0,
    /// The kinds whose entities join and leave the tick order as their columns start and stop
    /// ticking. Kinds that keep their own turns, as projectiles do, and subjects that only are
    /// somewhere, as players are, are not among them.
    following: Kinds = .all,

    const max_watchers = 8;
    const Watcher = struct { kinds: Kinds, hook: Stopped };

    /// Tells `hook` of every entity of the kinds that stops ticking.
    pub fn watchStopping(self: *Places, kinds: Kinds, hook: Stopped) !void {
        if (self.stopped_count == max_watchers) return error.TooManyWatchers;
        self.stopped[self.stopped_count] = .{ .kinds = kinds, .hook = hook };
        self.stopped_count += 1;
    }

    pub fn init(allocator: std.mem.Allocator, pool: *pool_module.Pool, directory: *directory_module.Directory) !Places {
        return .{
            .space = try .init(allocator, pool, directory),
            .order = try .init(allocator, pool, directory),
            .joining = try .init(allocator, pool),
            .entering = try .init(allocator, pool),
            .stopping = try .init(allocator, pool),
            .starting = try .init(allocator, pool),
        };
    }

    pub fn ticks(self: *const Places, column: Column) bool {
        const index = self.space.indexOf(column) orelse return false;
        return self.space.data(index).ticking;
    }

    /// The columns whose entities tick, in order.
    pub fn tickingColumns(self: *const Places) TickingColumns {
        return .{ .space = &self.space };
    }

    pub const TickingColumns = struct {
        space: *const Space,
        at: usize = 0,

        pub fn next(self: *TickingColumns) ?Column {
            while (self.at < self.space.columnCount()) {
                const held = self.space.columnAt(self.at);
                self.at += 1;
                if (held.ticking) return held.column;
            }
            return null;
        }
    };

    /// A new entity, or one come into memory: placed, and in a ticking column it ticks from
    /// the next tick on.
    pub fn insert(self: *Places, entity: Id, world: u32, position: [3]f64, shape: Shape) !void {
        try self.space.insert(entity, world, position, shape);
        if (self.ticks(space_module.columnOf(world, position))) _ = try self.order.join(entity);
    }

    /// An entity moved. Into a column that does not tick, it stops at once; back into one, it
    /// joins last.
    pub fn moveById(self: *Places, entity: Id, world: u32, position: [3]f64) !void {
        return self.move(self.space.directory.slotOf(entity) orelse return error.NotPlaced, world, position);
    }

    /// As `move`, for the entity in a slot: found without its id.
    pub fn move(self: *Places, slot: u32, world: u32, position: [3]f64) !void {
        const entry = self.space.directory.entry(slot);
        if (entry.space_column == directory_module.none) return error.NotPlaced;
        const entity = entry.id;
        const was = self.space.data(entry.space_column).column;
        const ticked = self.ticks(was);
        try self.space.move(slot, world, position);
        const to = space_module.columnOf(world, position);
        if (std.meta.eql(was, to)) return;
        const ticking_now = self.ticks(to);
        if (ticking_now == ticked) return;
        if (ticking_now) _ = try self.order.join(entity) else self.stopOne(entity);
    }

    /// A kind keeps its own turns: its entities are left out of the columns' ticking.
    /// As `Entities.declare` says, which is where a kind says it.
    pub fn keepsOwnTurns(self: *Places, kinds: Kinds) void {
        self.following.bits.setIntersection(kinds.bits.complement());
    }

    /// An entity went, or left memory: it leaves its section at once, as vanilla's do, and the
    /// order.
    pub fn remove(self: *Places, entity: Id) void {
        self.order.leave(entity);
        self.space.remove(entity);
    }

    /// Columns began and stopped ticking, as the domains say. Entities of one that stops leave
    /// the order; those of one that starts join it at the end, by section and then as they
    /// entered it, as vanilla's chunks do. Vanilla's order across chunks that start together is
    /// not fixed; this one is.
    pub fn changeTicking(self: *Places, entered: []const Column, left: []const Column) !void {
        for (left) |column| {
            const index = self.space.indexOf(column) orelse continue;
            if (!self.space.data(index).ticking) continue;
            var walk = self.space.entries(column, self.following);
            while (walk.next()) |entry| self.stopOne(entry.id);
            self.space.data(index).ticking = false;
            self.space.releaseColumn(index);
            self.ticking_revision += 1;
        }
        try self.joining.ensure(entered.len);
        for (entered, 0..) |column, at| self.joining.at(at).* = column;
        sortColumns(&self.joining, entered.len);
        for (0..entered.len) |at| {
            const column = self.joining.at(at).*;
            const index = try self.space.ensureColumn(column);
            if (self.space.data(index).ticking) continue;
            self.space.data(index).ticking = true;
            self.ticking_revision += 1;
            try self.startTicking(column);
        }
    }

    /// Takes the ticking columns afresh from what ticks now, as when more changed at once than
    /// could be told.
    pub fn resyncTicking(self: *Places, now: anytype) !void {
        for (0..self.space.columnCount()) |at| self.space.columnAt(at).mark = false;
        var starting: usize = 0;
        while (now.next()) |found| {
            const column: Column = .{ .world = found.world, .x = found.x, .z = found.z };
            if (self.space.indexOf(column)) |index| {
                const held = self.space.data(index);
                held.mark = true;
                if (held.ticking) continue;
            }
            try self.entering.ensure(starting + 1);
            self.entering.at(starting).* = column;
            starting += 1;
        }
        var stopping: usize = 0;
        for (0..self.space.columnCount()) |at| {
            const held = self.space.columnAt(at);
            if (!held.ticking or held.mark) continue;
            try self.stopping.ensure(stopping + 1);
            self.stopping.at(stopping).* = held.column;
            stopping += 1;
        }
        for (0..stopping) |at| try self.changeTicking(&.{}, &.{self.stopping.at(at).*});
        sortColumns(&self.entering, starting);
        for (0..starting) |at| try self.changeTicking(&.{self.entering.at(at).*}, &.{});
    }

    fn sortColumns(columns: *pool_module.Array(Column), count: usize) void {
        if (columns.run(0, count)) |values| return std.sort.pdq(Column, values, {}, columnBefore);
        const Sort = struct {
            values: *pool_module.Array(Column),
            pub fn lessThan(sort: @This(), a: usize, b: usize) bool {
                return columnBefore({}, sort.values.at(a).*, sort.values.at(b).*);
            }
            pub fn swap(sort: @This(), a: usize, b: usize) void {
                std.mem.swap(Column, sort.values.at(a), sort.values.at(b));
            }
        };
        std.sort.pdqContext(0, count, Sort{ .values = columns });
    }

    fn columnBefore(_: void, a: Column, b: Column) bool {
        if (a.world != b.world) return a.world < b.world;
        if (a.x != b.x) return a.x < b.x;
        return a.z < b.z;
    }

    fn startTicking(self: *Places, column: Column) !void {
        var held: usize = 0;
        var walk = self.space.entries(column, self.following);
        while (walk.next()) |entry| {
            try self.starting.ensure(held + 1);
            self.starting.at(held).* = entry;
            held += 1;
        }
        const Sort = struct {
            values: *pool_module.Array(space_module.Entry),
            pub fn lessThan(sort: @This(), a: usize, b: usize) bool {
                return space_module.before(sort.values.at(a).*, sort.values.at(b).*);
            }
            pub fn swap(sort: @This(), a: usize, b: usize) void {
                std.mem.swap(space_module.Entry, sort.values.at(a), sort.values.at(b));
            }
        };
        std.sort.pdqContext(0, held, Sort{ .values = &self.starting });
        for (0..held) |at| _ = try self.order.join(self.starting.at(at).id);
    }

    fn stopOne(self: *Places, entity: Id) void {
        if (self.order.sequenceOf(entity) == null) return;
        self.order.leave(entity);
        const kind = self.space.get(entity).?.shape.kind;
        for (self.stopped[0..self.stopped_count]) |watcher| if (watcher.kinds.has(kind)) watcher.hook.function(watcher.hook.context, entity);
    }
};

const testing = std.testing;

const TestTable = kind_table.Table(struct { value: u8 });

const item: Shape = .{ .kind = 1, .half_width = 0.125, .height = 0.25 };

fn passIds(places: *Places, table: *TestTable, output: []Id) ![]Id {
    places.order.endTick();
    try table.maintain();
    try places.order.begin();
    defer places.order.end();
    var n: usize = 0;
    while (places.order.nextInPass()) |entry| {
        output[n] = entry.id;
        n += 1;
    }
    return output[0..n];
}

test "entities tick in their columns' order as columns start, and stop as they move out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var pool = try pool_module.Pool.init(arena.allocator(), 64 * pool_module.page_bytes);
    var directory = try directory_module.Directory.init(arena.allocator(), &pool, 16);
    var places = try Places.init(arena.allocator(), &pool, &directory);
    var table = try TestTable.init(arena.allocator(), &pool, &directory);
    try places.order.addTable(item.kind, &table.core);
    const a: Column = .{ .world = 0, .x = 0, .z = 0 };
    const b: Column = .{ .world = 0, .x = 1, .z = 0 };
    // Section 4 entered before section 0: section 0 comes first when the column starts.
    for ([_]Id{ 1, 2, 3 }, [_][3]f64{ .{ 1, 70, 1 }, .{ 1, 3, 1 }, .{ 17, 64, 1 } }) |entity, position| {
        const slot = try directory.add(entity, item.kind);
        try places.insert(entity, 0, position, item);
        try table.add(slot, .{ .value = 0 }, false);
    }
    var buffer: [8]Id = undefined;
    try testing.expectEqualSlices(Id, &.{}, try passIds(&places, &table, &buffer));
    try places.changeTicking(&.{ b, a }, &.{});
    try testing.expectEqualSlices(Id, &.{ 2, 1, 3 }, try passIds(&places, &table, &buffer));
    // Into a column that does not tick it stops; back, it joins last.
    try places.moveById(2, 0, .{ 90, 3, 1 });
    try testing.expectEqualSlices(Id, &.{ 1, 3 }, try passIds(&places, &table, &buffer));
    try places.moveById(2, 0, .{ 2, 3, 1 });
    try testing.expectEqualSlices(Id, &.{ 1, 3, 2 }, try passIds(&places, &table, &buffer));
    try places.changeTicking(&.{}, &.{a});
    try testing.expectEqualSlices(Id, &.{3}, try passIds(&places, &table, &buffer));
    places.remove(3);
    try testing.expectEqualSlices(Id, &.{}, try passIds(&places, &table, &buffer));
    try testing.expectEqual(@as(usize, 2), places.space.count());
}
