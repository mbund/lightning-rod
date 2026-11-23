//! Entities of every kind: their ids, and the bodies they all have, in memory. What each kind
//! keeps besides lives with the kind, in tables of its own; where entities are and the order
//! they tick in are in places; what is kept for good goes to the store at checkpoints, each
//! entity under its column (see durable.zig).

const metrics = @import("metrics");
const std = @import("std");
const storage = @import("storage");
const records = @import("records");

const assert = std.debug.assert;

pub const table = @import("table.zig");
pub const Table = table.Table;
pub const order = @import("order.zig");
pub const Order = order.Order;
pub const space = @import("space.zig");
pub const Space = space.Space;
pub const Shape = space.Shape;
pub const Kinds = space.Kinds;
pub const Column = space.Column;
pub const Box = space.Box;
pub const places = @import("places.zig");
pub const Places = places.Places;
pub const durable = @import("durable.zig");
pub const residency = @import("residency.zig");
pub const Residency = residency.Residency;
pub const sorted_keys = @import("sorted_keys.zig");
pub const SortedKeys = sorted_keys.SortedKeys;
pub const schedule = @import("schedule.zig");
pub const Schedule = schedule.Schedule;
pub const extras = @import("extras.zig");
pub const slab = @import("slab.zig");
pub const Slab = slab.Slab;
pub const id_set = @import("id_set.zig");
pub const IdSet = id_set.IdSet;
pub const pool = @import("pool.zig");
pub const Pool = pool.Pool;
pub const Array = pool.Array;
pub const directory = @import("directory.zig");
pub const Directory = directory.Directory;
pub const Handle = directory.Handle;
pub const kind_table = @import("kind_table.zig");
pub const KindTable = kind_table.Table;
pub const BodyTable = @import("body_table.zig").BodyTable;

pub const Id = u64;

/// What every entity has: who it is, what kind, and where it is and goes.
pub const State = struct {
    uuid: u128,
    kind: u32,
    world: u32,
    position: [3]f64,
    velocity: [3]f64 = @splat(0),
    yaw: f32 = 0,
    pitch: f32 = 0,
    flags: u8 = 0,
};

pub const Entities = struct {
    pub const id = "lightning_rod:entities";

    pub const Configuration = struct {
        /// Memory entity state lives in: every table, of every kind, draws whole pages from it.
        /// The one bound: memory used up, the server stops cleanly, as vanilla runs out of heap.
        memory: usize = 64 * 1024 * 1024,
    };

    /// Memory each entity takes at the least, across its directory entry, its row and its place.
    const min_entity_bytes = 256;

    /// A kind's bodies, a column of its table.
    pub const BodyColumn = struct {
        context: *anyopaque,
        body: *const fn (*anyopaque, u32) ?*State,
    };

    pub fn addBodyColumn(self: *Entities, kind: u32, column: BodyColumn) !void {
        if (self.body_columns[kind] != null) return error.BodyColumnTaken;
        self.body_columns[kind] = column;
    }

    /// An entity's body where it lies, by slot, if it has one.
    fn bodyAt(self: *Entities, slot: u32) ?*State {
        const entry = self.directory.entry(slot);
        if (self.body_columns[entry.kind]) |column| {
            if (entry.block == directory.none) return null;
            return column.body(column.context, slot);
        }
        return null;
    }

    /// A kind's entities have their rows in a table: walked by the tick order, maintained with the
    /// rest once a tick when nothing holds its rows.
    pub fn addTable(self: *Entities, kind: u32, core: *kind_table.Core) !void {
        try self.places.order.addTable(kind, core);
    }

    /// Every kind's table brought up to date: what left goes, and what slept or woke moves.
    pub fn maintainAll(self: *Entities) !void {
        const tick_order = &self.places.order;
        tick_order.endTick();
        for (tick_order.walked[0..tick_order.walked_count]) |core| try core.maintain();
    }

    pub const Dependencies = struct {
        record_workspaces: *records.Workspaces,
        metrics: *metrics.Registry,
        storage: storage.Space,
    };

    deps: Dependencies,
    /// For stores of entity state beside the bodies, which keep caches of their own.
    io: std.Io,
    next_id: Id,
    checkpointed_id: Id,
    /// The memory every component's records live in, and where each entity's lie.
    pool: Pool,
    directory: Directory,
    /// Where each kind keeping its bodies in its own table has them.
    body_columns: [Kinds.max_kinds]?BodyColumn = @splat(null),
    /// Why the server should stop after this tick: a bound nearly reached.
    stopping: ?anyerror = null,
    /// Where every entity of every kind is, and the one order they all tick in.
    places: Places,
    /// What ticks each kind, in the order they were told, and which ticks a kind.
    tickers: [max_tickers]Ticker = undefined,
    ticker_count: usize = 0,
    ticker_of: [Kinds.max_kinds]u8 = @splat(no_ticker),
    /// The kinds whose entities follow the loaded columns, and whether anything tells them of the
    /// loaded domain, as `EntityColumns` does.
    holders: [max_holders]ColumnHolder = undefined,
    holder_count: usize = 0,
    columns_followed: bool = false,

    const max_tickers = 8;
    const no_ticker = std.math.maxInt(u8);
    /// Entities a run hands its ticker at most.
    pub const run_max = 64;

    /// What ticks entities of some kinds: made ready before the pass, handed each run of
    /// them that comes next in the order, and done after it.
    pub const Ticker = struct {
        kinds: Kinds,
        /// The longest run it takes at once. A run's entities are taken from the order before
        /// the first ticks: a kind whose ticks change others of its kind takes them one at a time.
        batch: usize,
        context: *anyopaque,
        prepare: *const fn (*anyopaque) anyerror!void,
        run: *const fn (*anyopaque, []const order.Entry) anyerror!void,
        finish: *const fn (*anyopaque) anyerror!void,

        pub fn init(comptime Context: type, context: *Context, kinds: Kinds, batch: usize) Ticker {
            assert(batch > 0 and batch <= run_max);
            const Adapter = struct {
                fn prepare(raw: *anyopaque) anyerror!void {
                    return Context.prepareTick(@ptrCast(@alignCast(raw)));
                }
                fn run(raw: *anyopaque, entries: []const order.Entry) anyerror!void {
                    return Context.tickRun(@ptrCast(@alignCast(raw)), entries);
                }
                fn finish(raw: *anyopaque) anyerror!void {
                    return Context.finishTick(@ptrCast(@alignCast(raw)));
                }
            };
            return .{ .kinds = kinds, .batch = batch, .context = context, .prepare = Adapter.prepare, .run = Adapter.run, .finish = Adapter.finish };
        }
    };

    /// A kind whose entities of a column go to the store as it leaves memory and come back from
    /// it as it returns: told in the order kinds were added.
    pub const ColumnHolder = struct {
        context: *anyopaque,
        load: *const fn (*anyopaque, Column) anyerror!void,
        unload: *const fn (*anyopaque, Column) anyerror!void,

        pub fn init(comptime Context: type, context: *Context, comptime load: fn (*Context, Column) anyerror!void, comptime unload: fn (*Context, Column) anyerror!void) ColumnHolder {
            const Adapter = struct {
                fn loadColumn(raw: *anyopaque, column: Column) anyerror!void {
                    return load(@ptrCast(@alignCast(raw)), column);
                }
                fn unloadColumn(raw: *anyopaque, column: Column) anyerror!void {
                    return unload(@ptrCast(@alignCast(raw)), column);
                }
            };
            return .{ .context = context, .load = Adapter.loadColumn, .unload = Adapter.unloadColumn };
        }
    };
    const max_holders = 8;

    pub fn addColumnHolder(self: *Entities, holder: ColumnHolder) !void {
        if (self.holder_count == max_holders) return error.TooManyColumnHolders;
        self.holders[self.holder_count] = holder;
        self.holder_count += 1;
    }

    /// Columns came into memory and left it, in column order: those leaving go to the store, then
    /// those coming are read from it, a column at a time, every kind's entities.
    pub fn columnsChanged(self: *Entities, entered: []const Column, left: []const Column) !void {
        for (left) |column| for (self.holders[0..self.holder_count]) |holder| try holder.unload(holder.context, column);
        for (entered) |column| for (self.holders[0..self.holder_count]) |holder| try holder.load(holder.context, column);
    }

    /// A kind's ticker; tickers are made ready in the order they are added.
    pub fn addTicker(self: *Entities, ticker: Ticker) !void {
        if (self.ticker_count == max_tickers) return error.TooManyTickers;
        for (0..Kinds.max_kinds) |kind| if (ticker.kinds.has(@intCast(kind))) {
            if (self.ticker_of[kind] != no_ticker) return error.KindTickedTwice;
            self.ticker_of[kind] = @intCast(self.ticker_count);
        };
        self.tickers[self.ticker_count] = ticker;
        self.ticker_count += 1;
    }

    /// ServerLevel's entity tick list, once through: every entity in the order, of whatever
    /// kind, each run of one kind handed to its ticker in turn. Every ticker is made ready first
    /// and done after, one that failed getting ready included, the first failure told once all
    /// are done.
    pub fn tickAll(self: *Entities) !void {
        try self.settle();
        var failure: ?anyerror = null;
        var prepared: usize = 0;
        while (prepared < self.ticker_count) {
            const ticker = &self.tickers[prepared];
            prepared += 1;
            ticker.prepare(ticker.context) catch |err| {
                std.log.err("event=entities_tick_failed stage=prepare reason={t}", .{err});
                failure = err;
                break;
            };
        }
        if (failure == null) self.pass() catch |err| {
            std.log.err("event=entities_tick_failed stage=pass reason={t}", .{err});
            failure = err;
        };
        for (self.tickers[0..prepared]) |*ticker| ticker.finish(ticker.context) catch |err| {
            std.log.err("event=entities_tick_failed stage=finish reason={t}", .{err});
            if (failure == null) failure = err;
        };
        self.maintainAll() catch |err| {
            if (failure == null) failure = err;
        };
        if (failure) |err| return err;
    }

    fn pass(self: *Entities) !void {
        const tick_order = &self.places.order;
        try tick_order.begin();
        defer tick_order.end();
        var run: [run_max]order.Entry = undefined;
        // The first of the next run, met while gathering this one.
        var pending: ?order.Entry = null;
        while (true) {
            const first = pending orelse (tick_order.nextInPass() orelse return);
            pending = null;
            const at = self.ticker_of[first.kind];
            if (at == no_ticker) continue;
            const ticker = &self.tickers[at];
            tick_order.beginRun(first.sequence - 1);
            run[0] = first;
            var count: usize = 1;
            while (count < ticker.batch) {
                const next = tick_order.nextInPass() orelse break;
                if (self.ticker_of[next.kind] != at) {
                    pending = next;
                    break;
                }
                run[count] = next;
                count += 1;
            }
            try ticker.run(ticker.context, run[0..count]);
            // Sleepers the run woke whose places it had passed take their turns now, in order,
            // before whatever comes after the run.
            while (tick_order.takeLate()) |late| {
                const late_at = self.ticker_of[late.kind];
                if (late_at == no_ticker) continue;
                try self.tickers[late_at].run(self.tickers[late_at].context, &.{late});
            }
        }
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io, configuration: Configuration, deps: Dependencies) !*Entities {
        const self = try allocate(allocator, io, configuration, deps);
        var sequence: [8]u8 = undefined;
        const length = try records.Table.init(deps.storage, deps.record_workspaces.resources).get(&.{0}, &sequence);
        if (length != null and length.? != sequence.len) return error.Corrupt;
        const next_id = if (length != null) std.mem.readInt(Id, &sequence, .little) else 1;
        if (next_id == 0) return error.Corrupt;
        self.next_id = next_id;
        self.checkpointed_id = next_id;
        return self;
    }

    pub fn allocate(allocator: std.mem.Allocator, io: std.Io, configuration: Configuration, deps: Dependencies) !*Entities {
        const self = try allocator.create(Entities);
        self.* = .{
            .deps = deps,
            .io = io,
            .next_id = 1,
            .checkpointed_id = 1,
            .pool = try .init(allocator, configuration.memory),
            .directory = undefined,
            .places = undefined,
        };
        // The most entities memory could hold, each at least its directory entry, its row and its
        // place: memory is the bound, and this only sizes what is kept by slot.
        self.directory = try .init(allocator, &self.pool, @min(configuration.memory / min_entity_bytes, std.math.maxInt(i32) - 1));
        self.places = try .init(allocator, &self.pool, &self.directory);
        return self;
    }

    /// Reserves a contiguous range of ids.
    pub fn reserveIds(self: *Entities, count: usize) !Id {
        if (count > std.math.maxInt(Id) - self.next_id) return error.IdExhausted;
        const first = self.next_id;
        self.next_id += count;
        return first;
    }

    /// A copy of an entity's body, if it has one.
    pub fn get(self: *Entities, entity: Id) !?State {
        const slot = self.directory.slotOf(entity) orelse return null;
        return (self.bodyAt(slot) orelse return null).*;
    }

    /// An entity's body where it lies, good until the tick's end.
    pub fn body(self: *Entities, entity: Id) !?*State {
        return self.bodyAt(self.directory.slotOf(entity) orelse return null);
    }

    /// Replaces the body of an entity that has one.
    pub fn set(self: *Entities, entity: Id, state: State) !void {
        ((try self.body(entity)) orelse unreachable).* = state;
    }

    pub fn has(self: *Entities, entity: Id) bool {
        const slot = self.directory.slotOf(entity) orelse return false;
        return self.bodyAt(slot) != null;
    }

    /// The directory slot of an entity coming into memory, made if it has none. A full
    /// directory is where vanilla would run out of heap.
    pub fn enter(self: *Entities, entity: Id, kind: u32) !u32 {
        if (self.directory.slotOf(entity)) |slot| return slot;
        return self.directory.add(entity, kind) catch |err| switch (err) {
            error.DirectoryFull => error.EntitiesFull,
            error.NetworkIdsExhausted => error.NetworkIdsExhausted,
            error.EntityMemoryExhausted => error.EntityMemoryExhausted,
        };
    }

    /// The id clients know an entity in memory by: its slot plus one, negated, as players take the
    /// positive ids.
    pub fn networkOf(self: *const Entities, entity: Id) ?i32 {
        return networkOfSlot(self.directory.slotOf(entity) orelse return null);
    }

    pub fn networkOfSlot(slot: u32) i32 {
        return -@as(i32, @intCast(slot + 1));
    }

    /// The entity in memory clients know by an id.
    pub fn entityOfNetwork(self: *const Entities, wire_id: i32) ?Id {
        if (wire_id >= 0) return null;
        const slot: u64 = @intCast(-@as(i64, wire_id) - 1);
        if (slot >= self.directory.high()) return null;
        const entity = self.directory.entry(@intCast(slot)).id;
        return if (entity == 0) null else entity;
    }

    /// An entity kept in a kind's table leaves memory, its row gone first.
    pub fn leave(self: *Entities, slot: u32) void {
        assert(self.directory.entry(slot).block == directory.none);
        self.places.order.leaveSlot(slot);
        self.directory.remove(slot);
    }

    /// The entity's entry, its records where they lie until the tick's end.
    pub fn resident(self: *Entities, slot: u32) *directory.Entry {
        return self.directory.entry(slot);
    }

    /// Why the server should stop after this tick, if a bound is nearly reached: past it, vanilla
    /// would crash, so stopping now checkpoints what the next tick might not finish.
    pub fn stopReason(self: *const Entities) ?anyerror {
        return self.stopping;
    }

    /// Pages kept free at the start of a tick: room for the tick to add entities in. Less than
    /// this, and the server stops after the tick rather than fail during the next.
    pub fn reservePages(self: *const Entities) usize {
        return @min(self.pool.pageCount() / 4, @max(8, self.pool.pageCount() / 32));
    }

    /// Looks again at how near each bound is.
    fn checkBounds(self: *Entities) void {
        const capacity = self.directory.capacity();
        self.stopping = if (capacity - self.directory.count() < @min(capacity / 2, @max(64, capacity / 256)))
            error.EntitiesFull
        else if (self.pool.freeCount() < self.reservePages())
            error.EntityMemoryExhausted
        else if (self.directory.high() - self.directory.free_count + 65536 > std.math.maxInt(i32))
            error.NetworkIdsExhausted
        else
            null;
    }

    /// Where nothing holds records, as at the start of a tick: tables are maintained, and how near
    /// each bound is is looked at again.
    pub fn settle(self: *Entities) !void {
        try self.maintainAll();
        self.checkBounds();
    }

    pub fn checkpoint(self: *Entities, at: storage.Space) !void {
        if (self.next_id == self.checkpointed_id) return;
        var sequence: [8]u8 = undefined;
        std.mem.writeInt(Id, &sequence, self.next_id, .little);
        try records.Table.init(at, self.deps.record_workspaces.resources).put(&.{0}, &sequence);
        self.checkpointed_id = self.next_id;
    }
};

pub const encoded_bytes = 81;

pub fn valid(state: State) bool {
    var finite = std.math.isFinite(state.yaw) and std.math.isFinite(state.pitch);
    for (state.position ++ state.velocity) |value| finite = finite and std.math.isFinite(value);
    return finite;
}

/// A body as kept in a kind's record.
pub fn encode(state: State, bytes: []u8) void {
    assert(bytes.len == encoded_bytes);
    assert(valid(state));
    std.mem.writeInt(u128, bytes[0..16], state.uuid, .little);
    std.mem.writeInt(u32, bytes[16..20], state.kind, .little);
    std.mem.writeInt(u32, bytes[20..24], state.world, .little);
    for (state.position ++ state.velocity, 0..) |value, i| std.mem.writeInt(u64, bytes[24 + i * 8 ..][0..8], @bitCast(value), .little);
    std.mem.writeInt(u32, bytes[72..76], @bitCast(state.yaw), .little);
    std.mem.writeInt(u32, bytes[76..80], @bitCast(state.pitch), .little);
    bytes[80] = state.flags;
}

pub fn decode(bytes: []const u8) !State {
    if (bytes.len != encoded_bytes) return error.Corrupt;
    var state: State = .{
        .uuid = std.mem.readInt(u128, bytes[0..16], .little),
        .kind = std.mem.readInt(u32, bytes[16..20], .little),
        .world = std.mem.readInt(u32, bytes[20..24], .little),
        .position = undefined,
        .velocity = undefined,
        .yaw = @bitCast(std.mem.readInt(u32, bytes[72..76], .little)),
        .pitch = @bitCast(std.mem.readInt(u32, bytes[76..80], .little)),
        .flags = bytes[80],
    };
    for (&state.position, 0..) |*value, i| value.* = @bitCast(std.mem.readInt(u64, bytes[24 + i * 8 ..][0..8], .little));
    for (&state.velocity, 0..) |*value, i| value.* = @bitCast(std.mem.readInt(u64, bytes[48 + i * 8 ..][0..8], .little));
    if (!valid(state)) return error.Corrupt;
    return state;
}

test "a body round trips through its encoding" {
    const original: State = .{ .uuid = 7, .kind = 3, .world = 1, .position = .{ 1.5, 64, -2 }, .velocity = .{ 0, -0.08, 0.25 }, .yaw = 90, .pitch = -5, .flags = 2 };
    var bytes: [encoded_bytes]u8 = undefined;
    encode(original, &bytes);
    try std.testing.expectEqual(original, try decode(&bytes));
}

/// Where in the tick entities take their turns: placed after what players do and the world's
/// own ticks, before what replicates entities, as ServerLevel ticks its entity list.
pub const EntityTicks = struct {
    pub const id = "lightning_rod:entity_ticks";
    pub const Configuration = struct {};
    pub const Dependencies = struct { entities: *Entities };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, _: Configuration, deps: Dependencies) !*EntityTicks {
        const self = try allocator.create(EntityTicks);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *EntityTicks) !void {
        try self.deps.entities.tickAll();
    }
};

test "memory near full stops the server cleanly at the next tick's start" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const held = try Entities.allocate(arena.allocator(), std.testing.io, .{ .memory = 64 * pool.page_bytes }, undefined);
    try held.settle();
    try std.testing.expectEqual(@as(?anyerror, null), held.stopReason());
    // Entities come until what is left is less than a tick's room.
    while (held.pool.freeCount() >= held.reservePages()) _ = try held.pool.take();
    try held.settle();
    try std.testing.expectEqual(@as(?anyerror, error.EntityMemoryExhausted), held.stopReason());
}
