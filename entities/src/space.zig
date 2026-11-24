//! Where every entity is, by column and section, as vanilla's entity sections keep them: each
//! entity has the place and size a lookup reads beside the others of its kind in its column, in
//! blocks of the entities' pool, one kind to a block, so a lookup reads only the kinds it is after
//! and meets them in vanilla's order. Like vanilla's ClassInstanceMultiMap, a column keeps a run
//! of blocks for each kind it holds; each run has a revision of its own, so what one kind does
//! leaves caches of another valid.
//!
//! Each column that holds entities, boxes or ticks has a dense index of its own, found from the
//! column by a hash, and the live ones are listed for walks over them all. An entity's
//! directory entry says where in its column's blocks it is.
//!
//! An entity that does not keep a place every tick, as a sleeping arrow along a path it planned,
//! may have a box instead: where its feet stay until a tick. A box is listed in every column its
//! entity's box reaches, and in a wheel by its tick; at the tick its kind places the entity
//! again. Lookups of entities pass boxes over; those who must know of boxes, as tracking and what
//! wakes a sleeper, ask for them.
//!
//! Whoever needs to know what changed takes the log: each entity placed, moved, removed or boxed,
//! once a tick each. What moved, for whoever asks what came near, is kept apart.

const std = @import("std");
const pool_module = @import("pool.zig");
const directory_module = @import("directory.zig");
const extras = @import("extras.zig");

const assert = std.debug.assert;
const Array = pool_module.Array;
const Directory = directory_module.Directory;

pub const Id = u64;

pub const Column = struct { world: u32, x: i32, z: i32 };

/// What a lookup needs of an entity to know whether its box meets: EntityDimensions'
/// makeBoundingBox, from half its width and its height, both floats as vanilla keeps them.
pub const Shape = struct { kind: u32, half_width: f32, height: f32 };

/// The kinds of entity a lookup is after, by their ids in the registry: every kind shares the
/// space, as vanilla's sections hold them all.
pub const Kinds = struct {
    bits: std.StaticBitSet(max_kinds) = .empty,

    pub const max_kinds = 256;
    pub const all: Kinds = .{ .bits = .full };

    pub fn of(kinds: []const u32) Kinds {
        var self: Kinds = .{};
        for (kinds) |kind| self.bits.set(kind);
        return self;
    }

    pub fn has(self: *const Kinds, kind: u32) bool {
        return self.bits.isSet(kind);
    }

    /// Each kind's bit folded onto 64: a column whose own fold shares none holds none of them.
    pub fn fold(self: *const Kinds) u64 {
        var folded: u64 = 0;
        for (self.bits.masks) |mask| folded |= mask;
        return folded;
    }
};

fn foldOf(kind: u32) u64 {
    return @as(u64, 1) << @intCast(kind % 64);
}

/// What happened to an entity's place, for whoever keeps track of what clients see.
pub const Change = struct {
    slot: u32,
    event: Event,

    /// `boxed`: its box valid until a tick was placed, taken back or replaced.
    pub const Event = enum(u8) { placed, moved, removed, boxed };
};

pub const Entry = struct {
    id: Id,
    /// Its directory slot.
    slot: u32 = 0,
    section: i32,
    /// When it entered its section, which orders a section's entities.
    entered: u64,
    position: [3]f64,
    shape: Shape,

    pub fn box(self: Entry) Box {
        const half: f64 = self.shape.half_width;
        const height: f64 = self.shape.height;
        return .{
            .min = .{ self.position[0] - half, self.position[1], self.position[2] - half },
            .max = .{ self.position[0] + half, self.position[1] + height, self.position[2] + half },
        };
    }
};

pub const Box = struct {
    min: [3]f64,
    max: [3]f64,

    /// AABB.intersects: overlapping, not merely touching.
    pub fn intersects(a: Box, b: Box) bool {
        return a.min[0] < b.max[0] and a.max[0] > b.min[0] and a.min[1] < b.max[1] and a.max[1] > b.min[1] and a.min[2] < b.max[2] and a.max[2] > b.min[2];
    }
};

/// Where an entity's feet may be: every point from `low` to `high`, both included.
pub const Feet = struct {
    low: [3]f64,
    high: [3]f64,

    pub fn contains(self: Feet, at: [3]f64) bool {
        for (0..3) |axis| if (at[axis] < self.low[axis] or at[axis] > self.high[axis]) return false;
        return true;
    }

    pub fn point(at: [3]f64) Feet {
        return .{ .low = at, .high = at };
    }
};

pub fn columnOf(world: u32, position: [3]f64) Column {
    return .{ .world = world, .x = coordinate(position[0]), .z = coordinate(position[2]) };
}

/// SectionPos.posToSectionCoord of a block coordinate's floor.
pub fn coordinate(value: f64) i32 {
    return @divFloor(@as(i32, @intFromFloat(@floor(value))), 16);
}

/// Sections in the order vanilla keeps them in a chunk: by SectionPos.asLong, whose low 20 bits
/// are y, so from 0 up and then the negative ones.
pub fn sectionOrder(section: i32) u20 {
    return @truncate(@as(u32, @bitCast(section)));
}

/// Columns of one x in the order vanilla keeps their sections: z as SectionPos.asLong's 22 bits
/// above y, so from 0 up and then the negative ones.
pub fn zOrder(z: i32) u22 {
    return @truncate(@as(u32, @bitCast(z)));
}

pub fn before(a: Entry, b: Entry) bool {
    if (a.section != b.section) return sectionOrder(a.section) < sectionOrder(b.section);
    return a.entered < b.entered;
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    return before(a, b);
}

pub const none = std.math.maxInt(u32);

/// Entities a block of a column holds.
pub const block_rows = 32;

/// Some of a column's entities of one kind, what lookups read of each side by side: each axis of
/// their feet apart, so a test over many reads only what it compares, a vector at a time.
pub const Block = struct {
    previous: u32,
    next: u32,
    count: u32,
    run: u32,
    x: [block_rows]f64,
    y: [block_rows]f64,
    z: [block_rows]f64,
    half_width: [block_rows]f32,
    height: [block_rows]f32,
    entered: [block_rows]u64,
    /// The entity's directory slot, and its id.
    slot: [block_rows]u32,
    id: [block_rows]Id,

    pub fn position(self: *const Block, row: u32) [3]f64 {
        return .{ self.x[row], self.y[row], self.z[row] };
    }
};

/// A column's entities of one kind: their blocks, how many, and when they last changed.
pub const Run = struct {
    kind: u32,
    column: u32,
    first: u32 = none,
    last: u32 = none,
    count: u32 = 0,
    /// The column's next run.
    next: u32 = none,
    revision: u64 = 0,
};

/// A column holding entities, boxes or ticking: its runs, how many it holds, and its revision.
pub const ColumnData = struct {
    column: Column,
    first_run: u32 = none,
    count: u32 = 0,
    /// Rises whenever the column's entities come, go or move, of any kind.
    revision: u64 = 0,
    /// Rises whenever a kind's last entity here goes, and its run with it.
    gone_revision: u64 = 0,
    /// The kinds of its runs folded, as `Kinds.fold`.
    folded: u64 = 0,
    /// The boxes listed here, by their links.
    box_first: u32 = none,
    box_count: u32 = 0,
    /// The space's columns made when this one was: a column made again at the same index is told
    /// apart.
    made: u64 = 0,
    /// Emptied this tick, and let go at its end unless filled again.
    emptied: bool = false,
    /// Where it is in the list of live columns.
    live_at: u32 = 0,
    /// Whether its entities tick, as the domains say.
    ticking: bool = false,
    /// For whoever walks the columns, to tell those seen.
    mark: bool = false,
};

/// Columns of a box's on each axis at most.
pub const box_span = 3;
const box_links = box_span * box_span;
/// Ticks the wheel tells apart; no box is longer.
pub const wheel_ticks = 32;

/// An entity's box: where its feet stay until a tick, and its own size, so its box anywhere along
/// is the feet's grown by it.
pub const Boxed = struct {
    // Two cache lines, all a box placed again in its columns reads and writes: its columns'
    // dense indices are in the links, for those that walk or leave them.
    feet: Feet align(64) = .{ .low = .{ 0, 0, 0 }, .high = .{ 0, 0, 0 } },
    until: u64 = 0,
    half_width: f32 = 0,
    height: f32 = 0,
    slot: u32 = 0,
    kind: u32 = 0,
    world: u32 = 0,
    /// Where it is in its tick's turn of the wheel.
    wheel_at: u32 = none,
    /// The columns it is listed in: x and z from these, so many of each, x first.
    x: i32 = 0,
    z: i32 = 0,
    x_count: u8 = 0,
    z_count: u8 = 0,
    column_count: u8 = 0,
    used: bool = false,
    /// In the wheel, or taken from it as due and waiting to be placed again or taken back.
    in_wheel: bool = false,
    due: bool = false,
    /// Placed again last in the columns it was in already.
    in_place: bool = false,

    /// The entity's box anywhere along.
    pub fn reach(self: *const Boxed) Feet {
        const half: f64 = self.half_width;
        return .{
            .low = .{ self.feet.low[0] - half, self.feet.low[1], self.feet.low[2] - half },
            .high = .{ self.feet.high[0] + half, self.feet.high[1] + self.height, self.feet.high[2] + half },
        };
    }
};

const Bucket = struct { key: u128 = 0, at: u32 = none };

fn keyOf(column: Column) u128 {
    const x: u32 = @bitCast(column.x);
    const z: u32 = @bitCast(column.z);
    return @as(u128, column.world) << 64 | @as(u128, x ^ 0x8000_0000) << 32 | (z ^ 0x8000_0000);
}

fn hashOf(key: u128) u64 {
    // A multiply and a fold: columns are small integers, near one another.
    const low: u64 = @truncate(key);
    const high: u64 = @truncate(key >> 64);
    const mixed = low *% 0x9e3779b97f4a7c15 ^ high *% 0xc2b2ae3d27d4eb4f;
    return mixed ^ (mixed >> 29);
}

pub const Space = struct {
    directory: *Directory,
    /// Columns by their dense indices, those live listed, and their indices by column, by hash.
    columns: extras.Records(ColumnData),
    live: Array(u32),
    buckets: Array(Bucket),
    bucket_mask: usize = 0,
    runs: extras.Records(Run),
    blocks: extras.Records(Block),
    placed: usize = 0,
    /// Of each kind.
    kind_placed: [Kinds.max_kinds]u32 = @splat(0),
    entered: u64 = 0,
    /// Rises with every change anywhere, so a revision is never seen twice, even of a column
    /// emptied and filled again.
    changes: u64 = 0,
    /// Rises whenever a column is made: one that comes into a column that held none.
    columns_made: u64 = 0,
    /// What each lookup found, one list for each lookup asked from inside another's visit.
    found: [max_depth]Array(Entry),
    /// Since the log was last taken: each entity placed, moved, removed or boxed, by slot, while
    /// the log is kept. Whoever needs to know what changed takes it once a tick.
    log: Array(Change),
    logging: bool = false,
    /// Kinds whose moves within their column go unlogged, as whoever reads the log is told of them
    /// some other way.
    unlogged_moves: Kinds = .{},
    /// Kinds that are only somewhere and never stored, as players as subjects: a column holding
    /// only them holds nothing to store.
    unstored: Kinds = .{},
    /// Whether a change could not be logged: whoever takes the log then looks over everything.
    log_overflowed: bool = false,
    /// The log's tick each slot was last noted in, so it is noted once.
    noted: []u32,
    log_epoch: u32 = 1,
    /// What was placed, moved or reshaped since last taken, by slot, once each, while kept: for
    /// whoever asks what came near.
    movers: Array(u32),
    keeping_movers: bool = false,
    movers_overflowed: bool = false,
    mover_noted: []u32,
    mover_epoch: u32 = 1,
    /// Boxes, their links into the columns' lists, the wheel of their ticks, and each slot's.
    boxes: extras.Records(Boxed),
    link_next: Array(u32),
    link_previous: Array(u32),
    /// The dense index of the column each link is in.
    link_column: Array(u32),
    /// The boxes due on each tick of a turn, in no order.
    wheel: [wheel_ticks]Array(u32),
    box_count: usize = 0,
    /// Of each kind.
    kind_boxed: [Kinds.max_kinds]u32 = @splat(0),
    /// Of each kind, those due and not yet placed again or taken back.
    kind_due: [Kinds.max_kinds]u32 = @splat(0),
    box_of: []u32,
    /// Columns emptied this tick, let go at its end.
    emptied: Array(u32),
    /// The column last found, which lookups mostly ask again.
    last_key: u128 = std.math.maxInt(u128),
    last_index: u32 = none,
    depth: usize = 0,

    const max_depth = 4;
    const initial_buckets = 1024;

    pub fn init(allocator: std.mem.Allocator, pool: *pool_module.Pool, directory: *Directory) !Space {
        var self: Space = .{
            .directory = directory,
            .columns = try .init(allocator, pool),
            .live = try .init(allocator, pool),
            .buckets = try .init(allocator, pool),
            .runs = try .init(allocator, pool),
            .blocks = try .init(allocator, pool),
            .log = try .init(allocator, pool),
            .noted = try allocator.alloc(u32, directory.capacity()),
            .movers = try .init(allocator, pool),
            .mover_noted = try allocator.alloc(u32, directory.capacity()),
            .boxes = try .init(allocator, pool),
            .link_next = try .init(allocator, pool),
            .link_previous = try .init(allocator, pool),
            .link_column = try .init(allocator, pool),
            .wheel = undefined,
            .box_of = try allocator.alloc(u32, directory.capacity()),
            .emptied = try .init(allocator, pool),
            .found = undefined,
        };
        for (&self.found) |*list| list.* = try .init(allocator, pool);
        for (&self.wheel) |*turn| turn.* = try .init(allocator, pool);
        @memset(self.noted, 0);
        @memset(self.mover_noted, 0);
        @memset(self.box_of, none);
        return self;
    }

    /// How many of some kinds are placed.
    pub fn countOf(self: *const Space, kinds: Kinds) usize {
        var total: usize = 0;
        var set = kinds.bits.iterator(.{});
        while (set.next()) |kind| total += self.kind_placed[kind];
        return total;
    }

    pub fn count(self: *const Space) usize {
        return self.placed;
    }

    // Columns.

    /// The bucket holding a key, or the empty one it would go in.
    fn bucketOf(self: *const Space, key: u128) usize {
        var at: usize = @as(usize, @truncate(hashOf(key))) & self.bucket_mask;
        while (true) : (at = (at + 1) & self.bucket_mask) {
            const bucket = self.buckets.at(at);
            if (bucket.at == none or bucket.key == key) return at;
        }
    }

    fn lookup(self: *const Space, key: u128) ?u32 {
        if (key == self.last_key) return self.last_index;
        if (self.buckets.len == 0) return null;
        const bucket = self.buckets.at(self.bucketOf(key));
        if (bucket.at == none) return null;
        const held = @constCast(self);
        held.last_key = key;
        held.last_index = bucket.at;
        return bucket.at;
    }

    /// The buckets made afresh, twice as many as the columns need at least.
    fn rehash(self: *Space, wanted: usize) !void {
        self.buckets.clear();
        const capacity = try std.math.ceilPowerOfTwo(usize, @max(initial_buckets, wanted * 2));
        try self.buckets.ensureFilled(capacity, .{});
        self.bucket_mask = capacity - 1;
        for (0..self.live.len) |at| {
            const index = self.live.at(at).*;
            const key = keyOf(self.columns.at(index).column);
            self.buckets.at(self.bucketOf(key)).* = .{ .key = key, .at = index };
        }
    }

    /// A key's bucket emptied, those after it in its probe moved up so every key stays found.
    fn unhash(self: *Space, key: u128) void {
        var hole = self.bucketOf(key);
        assert(self.buckets.at(hole).at != none);
        var at = hole;
        while (true) {
            at = (at + 1) & self.bucket_mask;
            const bucket = self.buckets.at(at);
            if (bucket.at == none) break;
            const home = @as(usize, @truncate(hashOf(bucket.key))) & self.bucket_mask;
            // Stays where it is when its home lies after the hole, cyclically, up to it.
            const stays = if (hole <= at) (home > hole and home <= at) else (home > hole or home <= at);
            if (stays) continue;
            self.buckets.at(hole).* = bucket.*;
            hole = at;
        }
        self.buckets.at(hole).* = .{};
    }

    /// A column's dense index, if it holds entities, boxes or ticks.
    pub fn indexOf(self: *const Space, column: Column) ?u32 {
        return self.lookup(keyOf(column));
    }

    pub fn data(self: *const Space, index: u32) *ColumnData {
        return self.columns.at(index);
    }

    /// A column's dense index, made if it had none.
    pub fn ensureColumn(self: *Space, column: Column) !u32 {
        const key = keyOf(column);
        if (self.lookup(key)) |index| return index;
        if ((self.live.len + 1) * 2 > self.buckets.len) try self.rehash(self.live.len + 1);
        try self.live.ensure(self.live.len + 1);
        self.columns_made += 1;
        const index = try self.columns.add(.{ .column = column, .made = self.columns_made, .live_at = @intCast(self.live.len - 1) });
        self.live.at(self.live.len - 1).* = index;
        self.buckets.at(self.bucketOf(key)).* = .{ .key = key, .at = index };
        return index;
    }

    /// A column that neither holds entities or boxes nor ticks lets its index go.
    pub fn releaseColumn(self: *Space, index: u32) void {
        const held = self.columns.at(index);
        // Listed as emptied, it goes when the list is.
        if (held.count != 0 or held.ticking or held.box_count != 0 or held.emptied) return;
        const key = keyOf(held.column);
        // The last live column takes its place in the list.
        const last = self.live.at(self.live.len - 1).*;
        self.live.at(held.live_at).* = last;
        self.columns.at(last).live_at = held.live_at;
        self.live.pop();
        self.unhash(key);
        if (self.last_key == key) {
            self.last_key = std.math.maxInt(u128);
            self.last_index = none;
        }
        self.columns.remove(index);
    }

    /// A column left with nothing waits for the tick's end to be let go: one emptied and filled
    /// again within a tick keeps its index.
    fn letGo(self: *Space, index: u32) void {
        const held = self.columns.at(index);
        if (held.count != 0 or held.ticking or held.box_count != 0 or held.emptied) return;
        _ = self.emptied.append(index) catch return self.releaseColumn(index);
        held.emptied = true;
    }

    /// The columns emptied this tick that are empty still are let go.
    pub fn releaseEmptied(self: *Space) void {
        for (0..self.emptied.len) |at| {
            const index = self.emptied.at(at).*;
            self.columns.at(index).emptied = false;
            self.releaseColumn(index);
        }
        self.emptied.reset();
    }

    /// Every column with an index, in no order: `columnCount` of them, the `at`th by `columnAt`.
    /// Walks that go in an order sort what they find.
    pub fn columnCount(self: *const Space) usize {
        return self.live.len;
    }

    pub fn columnAt(self: *const Space, at: usize) *ColumnData {
        return self.columns.at(self.live.at(at).*);
    }

    /// Whether a column holds entities of a kind that is stored.
    pub fn holdsStored(self: *const Space, held: *const ColumnData) bool {
        var at = held.first_run;
        while (at != none) {
            const run = self.runs.at(at);
            if (!self.unstored.has(run.kind)) return true;
            at = run.next;
        }
        return false;
    }

    /// Entities of every kind in a column.
    pub fn countIn(self: *const Space, column: Column) usize {
        return if (self.indexOf(column)) |index| self.columns.at(index).count else 0;
    }

    /// Rises whenever the column's entities come, go or move; zero for a column with none.
    pub fn revision(self: *const Space, column: Column) u64 {
        const index = self.indexOf(column) orelse return 0;
        const held = self.columns.at(index);
        return if (held.count == 0) 0 else held.revision;
    }

    /// Rises whenever the column's entities of some kinds come, go or move, and whenever a kind's
    /// last one here goes; zero for a column with none of them. What other kinds do leaves it.
    pub fn revisionOf(self: *const Space, column: Column, kinds: Kinds) u64 {
        const index = self.indexOf(column) orelse return 0;
        const held = self.columns.at(index);
        var latest: u64 = 0;
        if (held.folded & kinds.fold() != 0) {
            var at = held.first_run;
            while (at != none) {
                const run = self.runs.at(at);
                if (kinds.has(run.kind)) latest = @max(latest, run.revision);
                at = run.next;
            }
        }
        if (latest == 0) return 0;
        return @max(latest, held.gone_revision);
    }

    // Entities.

    fn placeOf(self: *const Space, entity: Id) ?*directory_module.Entry {
        const slot = self.directory.slotOf(entity) orelse return null;
        const entry = self.directory.entry(slot);
        return if (entry.space_column == none) null else entry;
    }

    pub fn contains(self: *const Space, entity: Id) bool {
        return self.placeOf(entity) != null;
    }

    fn entryAt(self: *const Space, block: *const Block, row: u32) Entry {
        return .{
            .id = block.id[row],
            .slot = block.slot[row],
            .section = coordinate(block.y[row]),
            .entered = block.entered[row],
            .position = block.position(row),
            .shape = .{ .kind = self.runs.at(block.run).kind, .half_width = block.half_width[row], .height = block.height[row] },
        };
    }

    pub const Placed = struct { entry: Entry, world: u32 };

    /// The entity in a slot, and its world, where it is placed.
    pub fn atSlot(self: *const Space, slot: u32) ?Placed {
        if (slot >= self.directory.high()) return null;
        const place = self.directory.entry(slot);
        if (place.space_column == none) return null;
        const block = self.blocks.at(place.space_block);
        const row = place.space_row;
        // The kind as its directory entry has it, which is in hand.
        return .{ .entry = .{
            .id = block.id[row],
            .slot = slot,
            .section = coordinate(block.y[row]),
            .entered = block.entered[row],
            .position = block.position(row),
            .shape = .{ .kind = place.kind, .half_width = block.half_width[row], .height = block.height[row] },
        }, .world = self.columns.at(place.space_column).column.world };
    }

    pub fn get(self: *const Space, entity: Id) ?Entry {
        const entry = self.placeOf(entity) orelse return null;
        return self.entryAt(self.blocks.at(entry.space_block), entry.space_row);
    }

    pub fn columnHolding(self: *const Space, entity: Id) ?Column {
        const entry = self.placeOf(entity) orelse return null;
        return self.columns.at(entry.space_column).column;
    }

    /// The runs of a column, to read their blocks.
    pub fn runAt(self: *const Space, index: u32) *const Run {
        return self.runs.at(index);
    }

    pub fn blockAt(self: *const Space, index: u32) *const Block {
        return self.blocks.at(index);
    }

    /// The entities of the kinds of the column at a dense index, in no order.
    pub fn entriesAt(self: *const Space, index: u32, kinds: Kinds) Entries {
        const held = self.columns.at(index);
        return .{ .space = self, .run = if (held.folded & kinds.fold() == 0) none else held.first_run, .kinds = kinds };
    }

    pub fn entries(self: *const Space, column: Column, kinds: Kinds) Entries {
        const index = self.indexOf(column) orelse return .{ .space = self, .run = none, .kinds = kinds };
        return self.entriesAt(index, kinds);
    }

    pub const Entries = struct {
        space: *const Space,
        run: u32,
        block: u32 = none,
        row: u32 = 0,
        kinds: Kinds,

        pub fn next(self: *Entries) ?Entry {
            while (true) {
                if (self.block != none) {
                    const block = self.space.blocks.at(self.block);
                    if (self.row < block.count) {
                        const row = self.row;
                        self.row += 1;
                        return self.space.entryAt(block, row);
                    }
                    self.block = block.next;
                    self.row = 0;
                    continue;
                }
                if (self.run == none) return null;
                const run = self.space.runs.at(self.run);
                self.run = run.next;
                if (self.kinds.has(run.kind)) self.block = run.first;
            }
        }
    };

    /// The runs of the kinds of the column at a dense index: each run's blocks are the entities
    /// of its kind there, to read a vector at a time.
    pub fn runsAt(self: *const Space, index: u32, kinds: Kinds) Runs {
        const held = self.columns.at(index);
        return .{ .space = self, .at = if (held.folded & kinds.fold() == 0) none else held.first_run, .kinds = kinds };
    }

    pub const Runs = struct {
        space: *const Space,
        at: u32,
        kinds: Kinds,

        pub fn next(self: *Runs) ?*const Run {
            while (self.at != none) {
                const run = self.space.runs.at(self.at);
                self.at = run.next;
                if (self.kinds.has(run.kind)) return run;
            }
            return null;
        }
    };

    /// The entities of some kinds in the column at a dense index whose horizontal distance from
    /// `a` is within `a_reach` and from `b` is not, or the other way round: those a circle that
    /// moved from one place to the other passed over. Only those are made entries and visited.
    pub fn eachCrossing(self: *const Space, index: u32, kinds: Kinds, a: [2]f64, a_reach: f64, b: [2]f64, b_reach: f64, context: anytype, comptime visit: fn (@TypeOf(context), Entry) anyerror!void) !void {
        const a_squared = a_reach * a_reach;
        const b_squared = b_reach * b_reach;
        var runs = self.runsAt(index, kinds);
        while (runs.next()) |run| {
            var at = run.first;
            while (at != none) {
                const block = self.blocks.at(at);
                for (0..block.count) |row| {
                    const ax = block.x[row] - a[0];
                    const az = block.z[row] - a[1];
                    const bx = block.x[row] - b[0];
                    const bz = block.z[row] - b[1];
                    if ((ax * ax + az * az <= a_squared) == (bx * bx + bz * bz <= b_squared)) continue;
                    try visit(context, self.entryAt(block, @intCast(row)));
                }
                at = block.next;
            }
        }
    }

    fn changed(self: *Space, held: *ColumnData, run: *Run) void {
        self.changes += 1;
        held.revision = self.changes;
        run.revision = self.changes;
    }

    /// The run of a kind in a column, made if it had none.
    fn runOf(self: *Space, index: u32, kind: u32) !u32 {
        const held = self.columns.at(index);
        var at = held.first_run;
        while (at != none) {
            const run = self.runs.at(at);
            if (run.kind == kind) return at;
            at = run.next;
        }
        const made = try self.runs.add(.{ .kind = kind, .column = index, .next = held.first_run });
        held.first_run = made;
        held.folded |= foldOf(kind);
        return made;
    }

    /// A run with nothing left goes, and the column says a kind went.
    fn dropRun(self: *Space, index: u32, dropped: u32) void {
        const held = self.columns.at(index);
        var link = &held.first_run;
        while (link.* != dropped) link = &self.runs.at(link.*).next;
        link.* = self.runs.at(dropped).next;
        self.runs.remove(dropped);
        self.changes += 1;
        held.gone_revision = self.changes;
        held.folded = 0;
        var at = held.first_run;
        while (at != none) {
            const run = self.runs.at(at);
            held.folded |= foldOf(run.kind);
            at = run.next;
        }
    }

    /// An entity comes into the world: last of its section.
    pub fn insert(self: *Space, entity: Id, world: u32, position: [3]f64, shape: Shape) !void {
        const slot = self.directory.slotOf(entity) orelse return error.NotInMemory;
        if (self.box_of[slot] != none) return error.AlreadyBoxed;
        const at = try self.reserve(slot);
        errdefer self.unreserve(slot, at);
        try self.putPlace(entity, world, position, shape);
        self.fill(at, slot, .placed);
        self.noteMover(slot);
    }

    fn putPlace(self: *Space, entity: Id, world: u32, position: [3]f64, shape: Shape) !void {
        const slot = self.directory.slotOf(entity) orelse return error.NotInMemory;
        return self.putPlaceSlot(slot, entity, world, position, shape);
    }

    fn putPlaceSlot(self: *Space, slot: u32, entity: Id, world: u32, position: [3]f64, shape: Shape) !void {
        assert(shape.kind < Kinds.max_kinds);
        const entry = self.directory.entry(slot);
        if (entry.space_column != none) return error.AlreadyPlaced;
        const index = try self.ensureColumn(columnOf(world, position));
        errdefer self.releaseColumn(index);
        const run_index = try self.runOf(index, shape.kind);
        const run = self.runs.at(run_index);
        errdefer if (run.count == 0) self.dropRun(index, run_index);
        if (run.last == none or self.blocks.at(run.last).count == block_rows) {
            const fresh = try self.blocks.add(undefined);
            const block = self.blocks.at(fresh);
            block.previous = run.last;
            block.next = none;
            block.count = 0;
            block.run = run_index;
            if (run.last == none) run.first = fresh else self.blocks.at(run.last).next = fresh;
            run.last = fresh;
        }
        const block = self.blocks.at(run.last);
        const row = block.count;
        block.count += 1;
        block.x[row] = position[0];
        block.y[row] = position[1];
        block.z[row] = position[2];
        block.half_width[row] = shape.half_width;
        block.height[row] = shape.height;
        block.entered[row] = self.entered;
        block.slot[row] = slot;
        block.id[row] = entity;
        entry.space_column = index;
        entry.space_block = run.last;
        entry.space_row = @intCast(row);
        const held = self.columns.at(index);
        held.count += 1;
        run.count += 1;
        self.placed += 1;
        self.kind_placed[shape.kind] += 1;
        self.entered += 1;
        self.changed(held, run);
    }

    // The log.

    /// Room in the log for the change about to be made, taken before making it so a change is
    /// never made unlogged.
    /// Once a tick for a slot: whoever takes the log looks at the slot as it then is.
    fn reserve(self: *Space, slot: u32) !?usize {
        if (!self.logging or self.noted[slot] == self.log_epoch) return null;
        const at = try self.log.grow();
        self.noted[slot] = self.log_epoch;
        return at;
    }

    fn unreserve(self: *Space, slot: u32, at: ?usize) void {
        if (at) |index| {
            assert(index + 1 == self.log.len);
            self.log.pop();
            self.noted[slot] = 0;
        }
    }

    fn fill(self: *Space, at: ?usize, slot: u32, event: Change.Event) void {
        if (at) |index| self.log.at(index).* = .{ .slot = slot, .event = event };
    }

    /// Takes the log: what changed since it was last taken. Good until the next change.
    pub fn logged(self: *const Space) Array(Change) {
        return self.log;
    }

    /// Notes a change that may not fail: past room, whoever takes the log looks over everything.
    fn note(self: *Space, slot: u32, event: Change.Event) void {
        const at = self.reserve(slot) catch {
            self.log_overflowed = true;
            return;
        };
        self.fill(at, slot, event);
    }

    pub fn clearLog(self: *Space) void {
        self.log.reset();
        self.log_epoch +%= 1;
        if (self.log_epoch == 0) {
            @memset(self.noted, 0);
            self.log_epoch = 1;
        }
        self.log_overflowed = false;
    }

    // Movers.

    /// Keeps what moves from now on, for whoever asks what came near.
    pub fn keepMovers(self: *Space) void {
        self.keeping_movers = true;
    }

    fn noteMover(self: *Space, slot: u32) void {
        if (!self.keeping_movers or self.mover_noted[slot] == self.mover_epoch) return;
        _ = self.movers.append(slot) catch {
            self.movers_overflowed = true;
            return;
        };
        self.mover_noted[slot] = self.mover_epoch;
    }

    /// What was placed, moved or reshaped since last taken, by slot, once each; and whether some
    /// could not be kept, when whoever asks must think everything moved. Good until the next
    /// change.
    pub fn moversSince(self: *const Space) struct { slots: Array(u32), overflowed: bool } {
        return .{ .slots = self.movers, .overflowed = self.movers_overflowed };
    }

    pub fn clearMovers(self: *Space) void {
        self.movers.reset();
        self.mover_epoch +%= 1;
        if (self.mover_epoch == 0) {
            @memset(self.mover_noted, 0);
            self.mover_epoch = 1;
        }
        self.movers_overflowed = false;
    }

    pub fn remove(self: *Space, entity: Id) void {
        const slot = self.directory.slotOf(entity) orelse return;
        if (self.directory.entry(slot).space_column == none) return;
        // A log that cannot grow is where vanilla runs out of heap: the removal still stands,
        // and whoever takes the log looks over everything.
        const at = self.reserve(slot) catch {
            self.log_overflowed = true;
            self.unplace(entity);
            return;
        };
        self.unplace(entity);
        self.fill(at, slot, .removed);
    }

    fn unplace(self: *Space, entity: Id) void {
        const slot = self.directory.slotOf(entity) orelse return;
        self.unplaceSlot(slot);
    }

    fn unplaceSlot(self: *Space, slot: u32) void {
        const entry = self.directory.entry(slot);
        if (entry.space_column == none) return;
        const index = entry.space_column;
        const held = self.columns.at(index);
        const hole = self.blocks.at(entry.space_block);
        const hole_row = entry.space_row;
        const run_index = hole.run;
        const run = self.runs.at(run_index);
        self.kind_placed[run.kind] -= 1;
        // The run's last entity fills the hole.
        const last = self.blocks.at(run.last);
        const last_row = last.count - 1;
        if (hole != last or hole_row != last_row) {
            hole.x[hole_row] = last.x[last_row];
            hole.y[hole_row] = last.y[last_row];
            hole.z[hole_row] = last.z[last_row];
            hole.half_width[hole_row] = last.half_width[last_row];
            hole.height[hole_row] = last.height[last_row];
            hole.entered[hole_row] = last.entered[last_row];
            hole.slot[hole_row] = last.slot[last_row];
            hole.id[hole_row] = last.id[last_row];
            const moved = self.directory.entry(last.slot[last_row]);
            moved.space_block = entry.space_block;
            moved.space_row = hole_row;
        }
        last.count -= 1;
        if (last.count == 0) {
            const emptied = run.last;
            run.last = last.previous;
            if (run.last == none) run.first = none else self.blocks.at(run.last).next = none;
            self.blocks.remove(emptied);
        }
        entry.space_column = none;
        held.count -= 1;
        run.count -= 1;
        self.placed -= 1;
        self.changed(held, run);
        if (run.count == 0) self.dropRun(index, run_index);
        self.letGo(index);
    }

    /// An entity moved: into another column or section it comes last there; within its section
    /// it keeps its turn.
    pub fn move(self: *Space, entity: Id, world: u32, position: [3]f64) !void {
        const slot = self.directory.slotOf(entity) orelse return error.NotPlaced;
        return self.moveSlot(slot, world, position);
    }

    /// The entity in a slot moved, as `move`.
    pub fn moveSlot(self: *Space, slot: u32, world: u32, position: [3]f64) !void {
        const entry = self.directory.entry(slot);
        if (entry.space_column == none) return error.NotPlaced;
        const entity = entry.id;
        const held = self.columns.at(entry.space_column);
        const block = self.blocks.at(entry.space_block);
        const row = entry.space_row;
        assert(block.slot[row] == slot);
        if (std.meta.eql(held.column, columnOf(world, position))) {
            if (block.x[row] == position[0] and block.y[row] == position[1] and block.z[row] == position[2]) return;
            const at = if (self.unlogged_moves.has(self.runs.at(block.run).kind)) null else try self.reserve(slot);
            if (coordinate(position[1]) != coordinate(block.y[row])) {
                block.entered[row] = self.entered;
                self.entered += 1;
            }
            block.x[row] = position[0];
            block.y[row] = position[1];
            block.z[row] = position[2];
            self.changed(held, self.runs.at(block.run));
            self.fill(at, slot, .moved);
            self.noteMover(slot);
            return;
        }
        const shape: Shape = .{ .kind = self.runs.at(block.run).kind, .half_width = block.half_width[row], .height = block.height[row] };
        const at = try self.reserve(slot);
        errdefer self.unreserve(slot, at);
        self.unplaceSlot(slot);
        try self.putPlaceSlot(slot, entity, world, position, shape);
        self.fill(at, slot, .moved);
        self.noteMover(slot);
    }

    /// A new size, as a baby grows up: its box changes, and its turn does not. Its kind stays.
    pub fn reshape(self: *Space, entity: Id, shape: Shape) void {
        const entry = self.placeOf(entity) orelse return;
        const block = self.blocks.at(entry.space_block);
        assert(self.runs.at(block.run).kind == shape.kind);
        block.half_width[entry.space_row] = shape.half_width;
        block.height[entry.space_row] = shape.height;
        self.changed(self.columns.at(entry.space_column), self.runs.at(block.run));
        self.noteMover(block.slot[entry.space_row]);
    }

    // Boxes.

    /// Columns along one axis a range reaches, or null where it is not finite or too far out.
    fn columnRange(low: f64, high: f64) ?[2]i32 {
        if (!std.math.isFinite(low) or !std.math.isFinite(high) or @abs(low) > 3e7 or @abs(high) > 3e7) return null;
        return .{ coordinate(low), coordinate(high) };
    }

    /// Whether an entity's feet staying in a box keep its box within the columns a box may reach.
    pub fn boxFits(feet: Feet, half_width: f32) bool {
        const half: f64 = half_width;
        const xs = columnRange(feet.low[0] - half, feet.high[0] + half) orelse return false;
        const zs = columnRange(feet.low[2] - half, feet.high[2] + half) orelse return false;
        return xs[1] - xs[0] < box_span and zs[1] - zs[0] < box_span;
    }

    /// An entity's feet stay in a box until a tick, when its kind places it again: it leaves its
    /// place, if it had one, for the box. False when the box reaches too far, and nothing changed.
    pub fn box(self: *Space, slot: u32, world: u32, feet: Feet, half_width: f32, height: f32, now: u64, until: u64) !bool {
        assert(until > now and until - now < wheel_ticks);
        const half: f64 = half_width;
        const xs = columnRange(feet.low[0] - half, feet.high[0] + half) orelse return false;
        const zs = columnRange(feet.low[2] - half, feet.high[2] + half) orelse return false;
        if (xs[1] - xs[0] >= box_span or zs[1] - zs[0] >= box_span) return false;
        // Room in its turn first, so nothing after can fail.
        const turn = &self.wheel[until % wheel_ticks];
        try turn.reserve(1);
        // Boxed already, as one due goes on to its next box: in its columns still, it stays
        // listed where it is.
        if (self.box_of[slot] != none) {
            const index = self.box_of[slot];
            const boxed = self.boxes.at(index);
            if (boxed.world == world and sameColumns(boxed, xs, zs)) {
                const at = self.reserve(slot) catch overflowed: {
                    self.log_overflowed = true;
                    break :overflowed null;
                };
                self.unwheel(index);
                if (boxed.due) self.kind_due[boxed.kind] -= 1;
                boxed.due = false;
                boxed.feet = feet;
                boxed.half_width = half_width;
                boxed.height = height;
                boxed.until = until;
                boxed.in_place = true;
                self.enwheel(index);
                self.fill(at, slot, .boxed);
                return true;
            }
            self.dropBox(index);
        }
        const kind = self.directory.entry(slot).kind;
        // Room for every link first: a box is listed in all its columns or none.
        const index = try self.boxes.add(.{ .slot = slot, .kind = kind, .world = world, .until = until, .feet = feet, .half_width = half_width, .height = height, .used = true });
        errdefer self.boxes.remove(index);
        try self.link_next.ensureFilled((@as(usize, index) + 1) * box_links, none);
        try self.link_previous.ensureFilled((@as(usize, index) + 1) * box_links, none);
        try self.link_column.ensureFilled((@as(usize, index) + 1) * box_links, none);
        var made: [box_links]u32 = undefined;
        var made_count: usize = 0;
        errdefer for (made[0..made_count]) |column| self.releaseColumn(column);
        var x = xs[0];
        while (x <= xs[1]) : (x += 1) {
            var z = zs[0];
            while (z <= zs[1]) : (z += 1) {
                made[made_count] = try self.ensureColumn(.{ .world = world, .x = x, .z = z });
                made_count += 1;
            }
        }
        // A log that cannot grow is where vanilla runs out of heap: the box still stands, and
        // whoever takes the log looks over everything.
        const at = self.reserve(slot) catch overflowed: {
            self.log_overflowed = true;
            break :overflowed null;
        };
        const boxed = self.boxes.at(index);
        for (made[0..made_count], 0..) |column, link_at| {
            const link: u32 = @intCast(@as(usize, index) * box_links + link_at);
            self.link_column.at(link).* = column;
            const held = self.columns.at(column);
            self.link_next.at(link).* = held.box_first;
            self.link_previous.at(link).* = none;
            if (held.box_first != none) self.link_previous.at(held.box_first).* = link;
            held.box_first = link;
            held.box_count += 1;
        }
        boxed.column_count = @intCast(made_count);
        boxed.x = xs[0];
        boxed.z = zs[0];
        boxed.x_count = @intCast(xs[1] - xs[0] + 1);
        boxed.z_count = @intCast(zs[1] - zs[0] + 1);
        // Listed first, so its place going lets none of its columns go.
        if (self.directory.entry(slot).space_column != none) self.unplace(self.directory.entry(slot).id);
        self.enwheel(index);
        self.box_count += 1;
        self.kind_boxed[kind] += 1;
        self.box_of[slot] = index;
        self.fill(at, slot, .boxed);
        return true;
    }

    /// Whether a box is listed in exactly the columns of a range.
    fn sameColumns(boxed: *const Boxed, xs: [2]i32, zs: [2]i32) bool {
        return boxed.x == xs[0] and boxed.z == zs[0] and boxed.x_count == xs[1] - xs[0] + 1 and boxed.z_count == zs[1] - zs[0] + 1;
    }

    /// Into its tick's turn, which has room for it.
    fn enwheel(self: *Space, index: u32) void {
        const boxed = self.boxes.at(index);
        assert(!boxed.in_wheel);
        const turn = &self.wheel[boxed.until % wheel_ticks];
        boxed.wheel_at = @intCast(turn.len);
        _ = turn.append(index) catch unreachable;
        boxed.in_wheel = true;
    }

    /// Out of its turn, the last of it taking its place.
    fn unwheel(self: *Space, index: u32) void {
        const boxed = self.boxes.at(index);
        if (!boxed.in_wheel) return;
        const turn = &self.wheel[boxed.until % wheel_ticks];
        const last = turn.at(turn.len - 1).*;
        if (last != index) {
            turn.at(boxed.wheel_at).* = last;
            self.boxes.at(last).wheel_at = boxed.wheel_at;
        }
        turn.pop();
        boxed.in_wheel = false;
    }

    /// How many of some kinds are boxed.
    pub fn boxCountOf(self: *const Space, kinds: Kinds) usize {
        var total: usize = 0;
        var set = kinds.bits.iterator(.{});
        while (set.next()) |kind| total += self.kind_boxed[kind];
        return total;
    }

    /// The box of the entity in a slot, if it has one.
    pub fn boxOf(self: *const Space, slot: u32) ?*const Boxed {
        if (slot >= self.box_of.len) return null;
        const index = self.box_of[slot];
        return if (index == none) null else self.boxes.at(index);
    }

    /// The box at an index, as a walk of boxes finds it.
    pub fn boxAt(self: *const Space, index: u32) *const Boxed {
        return self.boxes.at(index);
    }

    /// Takes the box of the entity in a slot back: its kind places it, or it is gone. Whether it
    /// had one.
    pub fn unbox(self: *Space, slot: u32) bool {
        const index = self.box_of[slot];
        if (index == none) return false;
        self.dropBox(index);
        return true;
    }

    fn dropBox(self: *Space, index: u32) void {
        const boxed = self.boxes.at(index);
        assert(boxed.used);
        const slot = boxed.slot;
        var columns: [box_links]u32 = undefined;
        const column_count = boxed.column_count;
        for (0..column_count) |link_at| {
            const link: u32 = @intCast(@as(usize, index) * box_links + link_at);
            const column = self.link_column.at(link).*;
            columns[link_at] = column;
            const held = self.columns.at(column);
            const previous = self.link_previous.at(link).*;
            const next = self.link_next.at(link).*;
            if (previous != none) self.link_next.at(previous).* = next else held.box_first = next;
            if (next != none) self.link_previous.at(next).* = previous;
            held.box_count -= 1;
        }
        self.unwheel(index);
        if (boxed.due) self.kind_due[boxed.kind] -= 1;
        self.kind_boxed[boxed.kind] -= 1;
        self.boxes.remove(index);
        self.box_count -= 1;
        self.box_of[slot] = none;
        self.note(slot, .boxed);
        for (columns[0..column_count]) |column| self.letGo(column);
    }

    /// Takes every box back.
    pub fn clearBoxes(self: *Space) void {
        for (0..self.box_of.len) |slot| if (self.box_of[slot] != none) self.dropBox(self.box_of[slot]);
    }

    /// The boxes of some kinds due on a tick, their slots written to `output`. Each stays listed
    /// where it is until its kind places it again, boxed or not, which it does this tick: a box
    /// placed again in the same columns is never taken out of them.
    pub fn takeDue(self: *Space, now: u64, kinds: Kinds, output: []u32, found: *usize) void {
        var waiting = kinds.bits.iterator(.{});
        while (waiting.next()) |kind| assert(self.kind_due[kind] == 0);
        // Every box in this turn is due now, as none is longer than the wheel: those of other
        // kinds stay, packed to the front.
        const turn = &self.wheel[now % wheel_ticks];
        var kept: usize = 0;
        for (0..turn.len) |at| {
            const index = turn.at(at).*;
            const boxed = self.boxes.at(index);
            assert(boxed.used and boxed.in_wheel and boxed.until == now);
            if (kinds.has(boxed.kind)) {
                assert(found.* < output.len);
                output[found.*] = boxed.slot;
                found.* += 1;
                boxed.in_wheel = false;
                boxed.due = true;
                self.kind_due[boxed.kind] += 1;
            } else {
                boxed.wheel_at = @intCast(kept);
                turn.at(kept).* = index;
                kept += 1;
            }
        }
        turn.shrink(kept);
    }

    /// Whether some box is overdue: none must be, as kinds place their entities again on time.
    pub fn overdue(self: *const Space, now: u64) bool {
        for (&self.wheel) |*turn| {
            for (0..turn.len) |at| if (self.boxes.at(turn.at(at).*).until < now) return true;
        }
        return false;
    }

    /// The boxes listed in the column at a dense index, by their indices: each box once, as each
    /// is listed once a column.
    pub fn boxesAt(self: *const Space, index: u32) BoxesAt {
        return .{ .space = self, .link = self.columns.at(index).box_first };
    }

    pub const BoxesAt = struct {
        space: *const Space,
        link: u32,

        pub fn next(self: *BoxesAt) ?u32 {
            if (self.link == none) return null;
            const link = self.link;
            self.link = self.space.link_next.at(link).*;
            return link / box_links;
        }
    };

    /// Visits the boxes of some kinds whose entity's box meets a box grown by `reach`,
    /// horizontally, and also vertically when `vertical`, each once; `visit` returning false
    /// stops the walk, which returns false.
    pub fn eachBox(self: *const Space, world: u32, query: Feet, reach: f64, kinds: Kinds, context: anytype, vertical: bool) bool {
        if (self.box_count == 0) return true;
        const low_x = query.low[0] - reach;
        const high_x = query.high[0] + reach;
        const low_z = query.low[2] - reach;
        const high_z = query.high[2] + reach;
        const xs = columnRange(low_x, high_x) orelse return false;
        const zs = columnRange(low_z, high_z) orelse return false;
        var x = xs[0];
        while (x <= xs[1]) : (x += 1) {
            var z = zs[0];
            while (z <= zs[1]) : (z += 1) {
                const index = self.indexOf(.{ .world = world, .x = x, .z = z }) orelse continue;
                var link = self.columns.at(index).box_first;
                while (link != none) : (link = self.link_next.at(link).*) {
                    const box_index = link / box_links;
                    const boxed = self.boxes.at(box_index);
                    if (!kinds.has(boxed.kind)) continue;
                    // Found once: in the first of its columns the walk meets.
                    if (!firstMet(boxed, xs, zs, link % box_links)) continue;
                    const c = boxed.reach();
                    if (c.low[0] > high_x or c.high[0] < low_x or c.low[2] > high_z or c.high[2] < low_z) continue;
                    if (vertical and (c.low[1] > query.high[1] or c.high[1] < query.low[1])) continue;
                    if (!context.visit(box_index)) return false;
                }
            }
        }
        return true;
    }

    /// Whether a box's column at `link_at` is the first of its columns within the walked ones, as
    /// the walk goes, so each box is visited once.
    fn firstMet(boxed: *const Boxed, xs: [2]i32, zs: [2]i32, link_at: usize) bool {
        for (0..link_at) |earlier| {
            const x = boxed.x + @as(i32, @intCast(earlier / boxed.z_count));
            const z = boxed.z + @as(i32, @intCast(earlier % boxed.z_count));
            if (x >= xs[0] and x <= xs[1] and z >= zs[0] and z <= zs[1]) return false;
        }
        return true;
    }

    // Lookups.

    /// Whether a column may hold some of the kinds whose fold is `fold`, as `Kinds.fold`: one
    /// lookup, for whoever would walk it, and false only where none is.
    pub fn holdsAny(self: *const Space, column: Column, fold: u64) bool {
        const index = self.indexOf(column) orelse return false;
        return self.columns.at(index).folded & fold != 0;
    }

    /// The entities of one column whose sections lie from `low` to `high`, in vanilla's order,
    /// a round at a time into `buffer`: between rounds the space may change, and the next round
    /// takes up after the last given.
    pub fn ordered(self: *const Space, column: Column, low: i32, high: i32, kinds: Kinds, buffer: []Entry) Ordered {
        assert(buffer.len >= 2 and low <= high);
        return .{ .space = self, .column = column, .low = low, .high = high, .kinds = kinds, .buffer = buffer };
    }

    /// As `ordered`, of those whose feet are within a box only: for a caller that takes no other,
    /// the rest are passed over before they are put in order.
    pub fn orderedWithin(self: *const Space, column: Column, low: i32, high: i32, kinds: Kinds, within: Feet, buffer: []Entry) Ordered {
        var walk = self.ordered(column, low, high, kinds, buffer);
        walk.within = within;
        return walk;
    }

    pub const Ordered = struct {
        space: *const Space,
        column: Column,
        low: i32,
        high: i32,
        kinds: Kinds,
        buffer: []Entry,
        after: ?Entry = null,
        done: bool = false,
        within: ?Feet = null,

        /// Each round keeps the least past the last given, halving when the buffer fills.
        pub fn next(self: *Ordered) ![]const Entry {
            if (self.done) return &.{};
            const buffer = self.buffer;
            var held: usize = 0;
            var cutoff: ?Entry = null;
            var more = false;
            var walk = self.space.entries(self.column, self.kinds);
            while (walk.next()) |entry| {
                if (entry.section < self.low or entry.section > self.high) continue;
                if (self.within) |feet| if (!feet.contains(entry.position)) continue;
                if (self.after) |last| if (!before(last, entry)) continue;
                if (cutoff) |limit| if (before(limit, entry)) {
                    more = true;
                    continue;
                };
                if (held == buffer.len) {
                    std.sort.pdq(Entry, buffer, {}, lessThan);
                    held = (buffer.len + 1) / 2;
                    cutoff = buffer[held - 1];
                    more = true;
                    if (before(cutoff.?, entry)) continue;
                }
                buffer[held] = entry;
                held += 1;
            }
            std.sort.pdq(Entry, buffer[0..held], {}, lessThan);
            self.done = !more or held == 0;
            if (held > 0) self.after = buffer[held - 1];
            return buffer[0..held];
        }
    };

    /// Visits the entities whose boxes meet a box, as EntitySectionStorage.getEntities finds
    /// them: in the sections from 2 blocks out of it in x and z and 4 below it, by column x up,
    /// then z as an unsigned field, then each column's sections by y as one, and in each
    /// section as they entered it. As vanilla's list, every one is found before the first is
    /// visited, so a visit may change the space and still the rest are met as found; one gone
    /// meanwhile is still met, for the visit to pass over. `visit` returns whether to stop.
    pub fn each(self: *Space, world: u32, query: Box, kinds: Kinds, context: anytype, comptime visit: fn (@TypeOf(context), Entry) anyerror!bool) !void {
        if (self.placed == 0) return;
        if (self.depth == max_depth) return error.LookupsTooDeep;
        const found = &self.found[self.depth];
        self.depth += 1;
        defer self.depth -= 1;
        var found_count: usize = 0;
        const folded = kinds.fold();
        const first: [3]i32 = .{ coordinate(query.min[0] - 2), coordinate(query.min[1] - 4), coordinate(query.min[2] - 2) };
        const last: [3]i32 = .{ coordinate(query.max[0] + 2), coordinate(query.max[1]), coordinate(query.max[2] + 2) };
        var x = first[0];
        while (x <= last[0]) : (x += 1) {
            const spans: [2][2]i32 = .{ .{ @max(first[2], 0), last[2] }, .{ first[2], @min(last[2], -1) } };
            for (spans) |span| {
                var z = span[0];
                while (z <= span[1]) : (z += 1) {
                    const index = self.indexOf(.{ .world = world, .x = x, .z = z }) orelse continue;
                    const held = self.columns.at(index);
                    if (held.folded & folded == 0) continue;
                    const start = found_count;
                    var runs = self.runsAt(index, kinds);
                    while (runs.next()) |run| {
                        var at = run.first;
                        while (at != none) {
                            const block = self.blocks.at(at);
                            for (0..block.count) |r| {
                                const row: u32 = @intCast(r);
                                const section = coordinate(block.y[row]);
                                if (section < first[1] or section > last[1]) continue;
                                const half: f64 = block.half_width[row];
                                const box_of_row: Box = .{
                                    .min = .{ block.x[row] - half, block.y[row], block.z[row] - half },
                                    .max = .{ block.x[row] + half, block.y[row] + block.height[row], block.z[row] + half },
                                };
                                if (!box_of_row.intersects(query)) continue;
                                try found.ensure(found_count + 1);
                                found.at(found_count).* = self.entryAt(block, row);
                                found_count += 1;
                            }
                            at = block.next;
                        }
                    }
                    sortFound(found, start, found_count);
                }
            }
        }
        for (0..found_count) |at| if (try visit(context, found.at(at).*)) return;
    }

    /// A column's finds in order: in place where they share a page, as most do.
    fn sortFound(found: *Array(Entry), start: usize, end: usize) void {
        if (found.run(start, end)) |values| return std.sort.pdq(Entry, values, {}, lessThan);
        const Order = struct {
            values: *Array(Entry),
            pub fn lessThan(order: @This(), a: usize, b: usize) bool {
                return before(order.values.at(a).*, order.values.at(b).*);
            }
            pub fn swap(order: @This(), a: usize, b: usize) void {
                std.mem.swap(Entry, order.values.at(a), order.values.at(b));
            }
        };
        std.sort.pdqContext(start, end, Order{ .values = found });
    }
};

const testing = std.testing;

const cow: Shape = .{ .kind = 1, .half_width = 0.45, .height = 1.4 };
const pig: Shape = .{ .kind = 2, .half_width = 0.45, .height = 0.9 };

const Fixture = struct {
    pool: pool_module.Pool,
    directory: Directory,
    space: Space,

    fn init(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.pool = try .init(allocator, 256 * pool_module.page_bytes);
        self.directory = try .init(allocator, &self.pool, 4096);
        self.space = try .init(allocator, &self.pool, &self.directory);
    }

    fn insertAs(self: *Fixture, entity: Id, position: [3]f64, shape: Shape) !void {
        if (self.directory.slotOf(entity) == null) _ = try self.directory.add(entity, shape.kind);
        try self.space.insert(entity, 0, position, shape);
    }

    fn insert(self: *Fixture, entity: Id, position: [3]f64) !void {
        try self.insertAs(entity, position, cow);
    }
};

fn collectOf(space: *Space, query: Box, kinds: Kinds, output: []Id) ![]Id {
    var state: struct { output: []Id, count: usize = 0 } = .{ .output = output };
    try space.each(0, query, kinds, &state, struct {
        fn visit(s: *@TypeOf(state), entry: Entry) anyerror!bool {
            s.output[s.count] = entry.id;
            s.count += 1;
            return false;
        }
    }.visit);
    return output[0..state.count];
}

fn collect(space: *Space, query: Box, output: []Id) ![]Id {
    return collectOf(space, query, .all, output);
}

test "lookups meet entities in vanilla's order and pass over what does not meet" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator());
    const space = &fixture.space;
    // Section y 4, then 0, then -1: vanilla takes 0 first, then 4, then the negative.
    try fixture.insert(1, .{ 8, 70, 8 });
    try fixture.insert(2, .{ 8.5, 2, 8 });
    try fixture.insert(3, .{ 9, -3, 8 });
    // Another column at a negative z comes after every positive one.
    try fixture.insert(4, .{ 8, 70, -1 });
    try fixture.insert(5, .{ 9, 70, 8.5 });
    // Far, and found by no query.
    try fixture.insert(6, .{ 200, 70, 8 });
    var buffer: [8]Id = undefined;
    const all: Box = .{ .min = .{ 0, -10, -5 }, .max = .{ 15, 80, 15 } };
    try testing.expectEqualSlices(Id, &.{ 2, 1, 5, 3, 4 }, try collect(space, all, &buffer));
    // Touching is not meeting.
    try testing.expectEqualSlices(Id, &.{}, try collect(space, .{ .min = .{ 8.45, 71.4, 7 }, .max = .{ 9, 72, 9 } }, &buffer));
    // A move within its section keeps its turn; into another, it comes last there.
    try space.move(1, 0, .{ 8.2, 71, 8 });
    try testing.expectEqualSlices(Id, &.{ 2, 1, 5, 3, 4 }, try collect(space, all, &buffer));
    try space.move(2, 0, .{ 8.5, 70, 8 });
    try testing.expectEqualSlices(Id, &.{ 1, 5, 2, 3, 4 }, try collect(space, all, &buffer));
    space.remove(5);
    try testing.expectEqualSlices(Id, &.{ 1, 2, 3, 4 }, try collect(space, all, &buffer));
    try testing.expectEqual(@as(usize, 5), space.count());
    // Many in one column span blocks; holes are filled as they go.
    for (0..100) |at| try fixture.insert(100 + at, .{ 1, 64, 1 });
    for (0..100) |at| if (at % 3 == 0) space.remove(100 + at);
    var many: [128]Id = undefined;
    const in_column = try collect(space, .{ .min = .{ 0, 60, 0 }, .max = .{ 2, 70, 2 } }, &many);
    try testing.expectEqual(@as(usize, 66), in_column.len);
    for (in_column[1..], in_column[0 .. in_column.len - 1]) |later, earlier| try testing.expect(later > earlier);
}

test "kinds keep runs of their own, met in one order, each with its revision" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator());
    const space = &fixture.space;
    // Entered in turn, kinds alternating: a lookup of both meets them as they entered.
    for (0..40) |at| try fixture.insertAs(at + 1, .{ 1 + @as(f64, @floatFromInt(at % 5)), 64, 1 }, if (at % 2 == 0) cow else pig);
    var buffer: [64]Id = undefined;
    const box: Box = .{ .min = .{ 0, 60, 0 }, .max = .{ 16, 70, 16 } };
    const both = try collect(space, box, &buffer);
    try testing.expectEqual(@as(usize, 40), both.len);
    for (both, 1..) |entity, expected| try testing.expectEqual(@as(Id, expected), entity);
    const cows = try collectOf(space, box, .of(&.{cow.kind}), &buffer);
    try testing.expectEqual(@as(usize, 20), cows.len);
    for (cows) |entity| try testing.expect(entity % 2 == 1);
    // A pig moving leaves the cows' revision; a cow moving does not leave it.
    const at: Column = .{ .world = 0, .x = 0, .z = 0 };
    const cows_then = space.revisionOf(at, .of(&.{cow.kind}));
    const pigs_then = space.revisionOf(at, .of(&.{pig.kind}));
    try space.move(2, 0, .{ 2, 65, 1 });
    try testing.expectEqual(cows_then, space.revisionOf(at, .of(&.{cow.kind})));
    try testing.expect(space.revisionOf(at, .of(&.{pig.kind})) != pigs_then);
    try space.move(1, 0, .{ 2, 65, 1 });
    try testing.expect(space.revisionOf(at, .of(&.{cow.kind})) != cows_then);
    // The last pig going is a change to whoever asks of pigs, never a revision seen before.
    const seen_with_pigs = space.revisionOf(at, .of(&.{ cow.kind, pig.kind }));
    for (0..40) |gone| if (gone % 2 == 1) space.remove(gone + 1);
    try testing.expectEqual(@as(u64, 0), space.revisionOf(at, .of(&.{pig.kind})));
    try testing.expect(space.revisionOf(at, .of(&.{ cow.kind, pig.kind })) != seen_with_pigs);
    var walk = space.entries(at, .of(&.{pig.kind}));
    try testing.expect(walk.next() == null);
}

test "columns are found by hash among many, made and let go" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator());
    const space = &fixture.space;
    // More columns than the first buckets hold, then most gone, then back.
    for (0..3000) |at| try fixture.insert(at + 1, .{ @as(f64, @floatFromInt(at % 60)) * 16 + 1, 64, @as(f64, @floatFromInt(at / 60)) * 16 - 400 });
    for (0..3000) |at| try testing.expectEqual(@as(usize, 1), space.countIn(columnOf(0, .{ @as(f64, @floatFromInt(at % 60)) * 16 + 1, 64, @as(f64, @floatFromInt(at / 60)) * 16 - 400 })));
    for (0..3000) |at| if (at % 7 != 0) space.remove(at + 1);
    space.releaseEmptied();
    for (0..3000) |at| {
        const column = columnOf(0, .{ @as(f64, @floatFromInt(at % 60)) * 16 + 1, 64, @as(f64, @floatFromInt(at / 60)) * 16 - 400 });
        try testing.expectEqual(@as(usize, if (at % 7 == 0) 1 else 0), space.countIn(column));
        try testing.expectEqual(at % 7 == 0, space.indexOf(column) != null);
    }
    try testing.expectEqual(@as(usize, 429), space.columnCount());
    // Each live column listed once, and found by hash where it is.
    for (0..space.columnCount()) |at| {
        const held = space.columnAt(at);
        try testing.expectEqual(at, held.live_at);
        try testing.expectEqual(space.live.at(at).*, space.indexOf(held.column).?);
    }
}

test "a visit may change the space, and the rest are still met once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator());
    const space = &fixture.space;
    for (0..100) |at| try fixture.insert(at + 1, .{ 1 + @as(f64, @floatFromInt(at % 10)), 64, 1 + @as(f64, @floatFromInt(at / 10)) });
    var seen: [128]Id = undefined;
    var state: struct { space: *Space, seen: []Id, count: usize = 0, nested: usize = 0 } = .{ .space = space, .seen = &seen };
    try space.each(0, .{ .min = .{ 0, 60, 0 }, .max = .{ 16, 90, 16 } }, .all, &state, struct {
        fn visit(s: *@TypeOf(state), entry: Entry) anyerror!bool {
            s.seen[s.count] = entry.id;
            s.count += 1;
            // The next one goes before it is met, and one moves on ahead: both met as found.
            if (entry.id % 2 == 1) s.space.remove(entry.id + 1);
            if (entry.id == 51) try s.space.move(51, 0, .{ 2, 80, 2 });
            // A lookup from inside a visit finds afresh.
            if (entry.id == 10) {
                var inner: struct { count: usize = 0 } = .{};
                try s.space.each(0, .{ .min = .{ 0, 60, 0 }, .max = .{ 16, 90, 16 } }, .all, &inner, struct {
                    fn tally(c: *@TypeOf(inner), _: Entry) anyerror!bool {
                        c.count += 1;
                        return false;
                    }
                }.tally);
                s.nested = inner.count;
            }
            return false;
        }
    }.visit);
    try testing.expectEqual(@as(usize, 100), state.count);
    for (seen[0..100], 1..) |entity, expected| try testing.expectEqual(@as(Id, expected), entity);
    try testing.expectEqual(@as(usize, 50), space.count());
    try testing.expectEqual(@as(usize, 95), state.nested);
}

test "a column's revision is never seen twice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator());
    const space = &fixture.space;
    const at: Column = .{ .world = 0, .x = 0, .z = 0 };
    try fixture.insert(1, .{ 1, 64, 1 });
    const first = space.revision(at);
    space.remove(1);
    try testing.expectEqual(@as(u64, 0), space.revision(at));
    // Let go at the tick's end.
    space.releaseEmptied();
    try testing.expectEqual(@as(?u32, null), space.indexOf(at));
    try fixture.insert(2, .{ 1, 64, 1 });
    try testing.expect(space.revision(at) != first and space.revision(at) != 0);
}

test "boxes are found by what meets them and by their tick, and leave when taken" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator());
    const space = &fixture.space;
    space.logging = true;
    const arrow: Shape = .{ .kind = 3, .half_width = 0.25, .height = 0.5 };
    try fixture.insertAs(7, .{ 60, 80, 15 }, arrow);
    try fixture.insertAs(8, .{ 300, 80, 15 }, arrow);
    _ = try fixture.directory.add(9, arrow.kind);
    const seven = fixture.directory.slotOf(7).?;
    const eight = fixture.directory.slotOf(8).?;
    const nine = fixture.directory.slotOf(9).?;
    try testing.expect(try space.box(seven, 0, .{ .low = .{ 60, 70, 10 }, .high = .{ 70, 90, 20 } }, 0.25, 0.5, 100, 105));
    try testing.expect(try space.box(eight, 0, .{ .low = .{ 300, 70, 10 }, .high = .{ 310, 90, 20 } }, 0.25, 0.5, 100, 110));
    // Too far for a box: nothing changes.
    try testing.expect(!try space.box(nine, 0, .{ .low = .{ 0, 0, 0 }, .high = .{ 200, 1, 1 } }, 0.25, 0.5, 100, 101));
    // A boxed entity has no place, and lookups of entities pass it.
    try testing.expect(space.atSlot(seven) == null);
    var buffer: [8]Id = undefined;
    try testing.expectEqualSlices(Id, &.{}, try collect(space, .{ .min = .{ 0, 0, 0 }, .max = .{ 400, 100, 30 } }, &buffer));
    const Gather = struct {
        output: []u32,
        found: *usize,
        fn visit(context: @This(), index: u32) bool {
            context.output[context.found.*] = index;
            context.found.* += 1;
            return true;
        }
    };
    var output: [8]u32 = undefined;
    var found: usize = 0;
    try testing.expect(space.eachBox(0, .{ .low = .{ 65, 80, 15 }, .high = .{ 66, 81, 16 } }, 0, .all, Gather{ .output = &output, .found = &found }, true));
    try testing.expectEqual(@as(usize, 1), found);
    try testing.expectEqual(seven, space.boxAt(output[0]).slot);
    found = 0;
    try testing.expect(space.eachBox(0, .{ .low = .{ 65, 200, 15 }, .high = .{ 66, 201, 16 } }, 0, .all, Gather{ .output = &output, .found = &found }, true));
    try testing.expectEqual(@as(usize, 0), found);
    found = 0;
    try testing.expect(space.eachBox(0, .{ .low = .{ 0, 80, 0 }, .high = .{ 400, 81, 30 } }, 0, .of(&.{2}), Gather{ .output = &output, .found = &found }, true));
    try testing.expectEqual(@as(usize, 0), found);
    var slots: [4]u32 = undefined;
    var due: usize = 0;
    space.takeDue(104, .all, &slots, &due);
    try testing.expectEqual(@as(usize, 0), due);
    space.takeDue(105, .all, &slots, &due);
    try testing.expectEqualSlices(u32, &.{seven}, slots[0..due]);
    // Due, it stays where it is until placed again: in its columns still, it is not moved.
    const index = space.box_of[seven];
    const first_column = space.link_column.at(@as(usize, index) * box_links).*;
    try testing.expect(try space.box(seven, 0, .{ .low = .{ 61, 70, 10 }, .high = .{ 69, 90, 20 } }, 0.25, 0.5, 105, 110));
    try testing.expectEqual(index, space.box_of[seven]);
    try testing.expectEqual(first_column, space.link_column.at(@as(usize, index) * box_links).*);
    try testing.expect(space.unbox(seven));
    try testing.expect(space.boxOf(seven) == null);
    try testing.expect(space.unbox(eight));
    try testing.expectEqual(@as(usize, 0), space.box_count);
    // Every column the boxes made is let go with them, at the tick's end.
    space.releaseEmptied();
    try testing.expectEqual(@as(usize, 0), space.columnCount());
}

test "movers are kept once each until taken" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator());
    const space = &fixture.space;
    space.keepMovers();
    try fixture.insert(1, .{ 1, 64, 1 });
    try fixture.insert(2, .{ 1, 64, 1 });
    try space.move(1, 0, .{ 2, 64, 1 });
    try space.move(1, 0, .{ 40, 64, 1 });
    try testing.expectEqual(@as(usize, 2), space.moversSince().slots.len);
    space.clearMovers();
    try space.move(2, 0, .{ 2, 64, 1 });
    // Standing still is not moving.
    try space.move(1, 0, .{ 40, 64, 1 });
    const movers = space.moversSince().slots;
    try testing.expectEqual(@as(usize, 1), movers.len);
    try testing.expectEqual(fixture.directory.slotOf(2).?, movers.at(0).*);
}
