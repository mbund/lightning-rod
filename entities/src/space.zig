//! Where every entity is, by column and section, as vanilla's entity sections keep them: each
//! entity has the place, kind and size a lookup reads beside the others of its column, in blocks
//! of the entities' pool, so lookups pass over the far and the wrong kind without reading
//! anything else, and meet the rest in vanilla's order.
//!
//! Each column that holds entities or ticks has a dense index of its own, found from the column
//! by a binary search of the columns in order; an entity's directory entry says where in its
//! column's blocks it is.

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
};

/// What happened to an entity's place, for whoever keeps track of what clients see.
pub const Change = struct {
    slot: u32,
    event: Event,

    /// `swept`: its box valid until a tick was placed, taken back or replaced.
    pub const Event = enum(u8) { placed, moved, removed, swept };
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

const none = std.math.maxInt(u32);

/// Entities a block of a column holds.
pub const block_rows = 32;

/// A column's entities, a block at a time: what lookups read of each, side by side.
const Block = struct {
    previous: u32,
    next: u32,
    count: u32,
    position: [block_rows][3]f64,
    half_width: [block_rows]f32,
    height: [block_rows]f32,
    kind: [block_rows]u32,
    section: [block_rows]i32,
    entered: [block_rows]u64,
    /// The entity's directory slot, and its id.
    slot: [block_rows]u32,
    id: [block_rows]Id,
};

/// A column holding entities or ticking: its blocks, how many it holds, and its revision.
pub const ColumnData = struct {
    column: Column,
    first: u32 = none,
    last: u32 = none,
    count: u32 = 0,
    revision: u64 = 0,
    /// Whether its entities tick, as the domains say.
    ticking: bool = false,
    /// For whoever walks the columns, to tell those seen.
    mark: bool = false,
};

const Key = struct { key: u128, at: u32 };

fn keyOf(column: Column) u128 {
    const x: u32 = @bitCast(column.x);
    const z: u32 = @bitCast(column.z);
    return @as(u128, column.world) << 64 | @as(u128, x ^ 0x8000_0000) << 32 | (z ^ 0x8000_0000);
}

pub const Space = struct {
    directory: *Directory,
    /// Columns by their dense indices, and their indices by column, in order.
    columns: extras.Records(ColumnData),
    keys: Array(Key),
    blocks: extras.Records(Block),
    placed: usize = 0,
    /// Of each kind.
    kind_placed: [Kinds.max_kinds]u32 = @splat(0),
    entered: u64 = 0,
    /// Rises with every change anywhere, so a column's revision is never seen twice, even one
    /// emptied and filled again.
    changes: u64 = 0,
    /// Rises whenever an entity comes into a column that held none.
    columns_made: u64 = 0,
    /// What each lookup found, one list for each lookup asked from inside another's visit.
    found: [max_depth]Array(Entry),
    /// Since the log was last taken: each entity placed, moved or removed, by slot, while the
    /// log is kept. Whoever needs to know what changed takes it once a tick.
    log: Array(Change),
    logging: bool = false,
    /// Whether a removal could not be logged: whoever takes the log then looks over everything.
    log_overflowed: bool = false,
    /// The log's tick each slot was last noted in, so it is noted once.
    noted: []u32,
    log_epoch: u32 = 1,
    /// The column last found, which lookups mostly ask again.
    last_key: u128 = std.math.maxInt(u128),
    last_place: usize = 0,
    depth: usize = 0,

    const max_depth = 4;

    pub fn init(allocator: std.mem.Allocator, pool: *pool_module.Pool, directory: *Directory) !Space {
        var self: Space = .{
            .directory = directory,
            .columns = try .init(allocator, pool),
            .keys = try .init(allocator, pool),
            .blocks = try .init(allocator, pool),
            .log = try .init(allocator, pool),
            .noted = try allocator.alloc(u32, directory.capacity()),
            .found = undefined,
        };
        for (&self.found) |*list| list.* = try .init(allocator, pool);
        @memset(self.noted, 0);
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

    /// Where a column's index is among the keys, or would go.
    fn search(self: *const Space, key: u128) struct { at: usize, found: bool } {
        if (key == self.last_key and self.last_place < self.keys.len and self.keys.at(self.last_place).key == key) return .{ .at = self.last_place, .found = true };
        var low: usize = 0;
        var high: usize = self.keys.len;
        while (low < high) {
            const middle = (low + high) / 2;
            if (self.keys.at(middle).key < key) low = middle + 1 else high = middle;
        }
        const found = low < self.keys.len and self.keys.at(low).key == key;
        if (found) {
            const held = @constCast(self);
            held.last_key = key;
            held.last_place = low;
        }
        return .{ .at = low, .found = found };
    }

    /// A column's dense index, if it holds entities or ticks.
    pub fn indexOf(self: *const Space, column: Column) ?u32 {
        const place = self.search(keyOf(column));
        return if (place.found) self.keys.at(place.at).at else null;
    }

    pub fn data(self: *const Space, index: u32) *ColumnData {
        return self.columns.at(index);
    }

    /// A column's dense index, made if it had none.
    pub fn ensureColumn(self: *Space, column: Column) !u32 {
        const key = keyOf(column);
        const place = self.search(key);
        if (place.found) return self.keys.at(place.at).at;
        const index = try self.columns.add(.{ .column = column });
        errdefer self.columns.remove(index);
        try self.keys.ensure(self.keys.len + 1);
        var at = self.keys.len - 1;
        while (at > place.at) : (at -= 1) self.keys.at(at).* = self.keys.at(at - 1).*;
        self.keys.at(place.at).* = .{ .key = key, .at = index };
        return index;
    }

    /// A column that neither holds entities nor ticks lets its index go.
    pub fn releaseColumn(self: *Space, index: u32) void {
        const held = self.columns.at(index);
        if (held.count != 0 or held.ticking) return;
        const place = self.search(keyOf(held.column));
        assert(place.found);
        for (place.at..self.keys.len - 1) |at| self.keys.at(at).* = self.keys.at(at + 1).*;
        self.keys.pop();
        self.columns.remove(index);
    }

    /// Every column with an index, in order: `columnCount` of them, the `at`th by `columnAt`.
    /// The columns holding entities in a world along one x, from z `low` to `high`, in order:
    /// one search, then a step for each column kept there.
    pub fn columnsAlong(self: *const Space, world: u32, x: i32, low: i32, high: i32) Along {
        if (low > high) return .{ .space = self, .at = self.keys.len, .end = 0 };
        const start = self.search(keyOf(.{ .world = world, .x = x, .z = low }));
        return .{ .space = self, .at = start.at, .end = keyOf(.{ .world = world, .x = x, .z = high }) };
    }

    pub const Along = struct {
        space: *const Space,
        at: usize,
        end: u128,

        pub const Found = struct { column: Column, index: u32 };

        pub fn next(self: *Along) ?Found {
            if (self.at >= self.space.keys.len) return null;
            while (self.at < self.space.keys.len) {
                const key = self.space.keys.at(self.at);
                if (key.key > self.end) return null;
                self.at += 1;
                // A column kept for ticking with nothing in it is no column here.
                const held = self.space.columns.at(key.at);
                if (held.count != 0) return .{ .column = held.column, .index = key.at };
            }
            return null;
        }
    };

    pub fn columnCount(self: *const Space) usize {
        return self.keys.len;
    }

    pub fn columnAt(self: *const Space, at: usize) *ColumnData {
        return self.columns.at(self.keys.at(at).at);
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

    fn placeOf(self: *const Space, entity: Id) ?*directory_module.Entry {
        const slot = self.directory.slotOf(entity) orelse return null;
        const entry = self.directory.entry(slot);
        return if (entry.space_column == none) null else entry;
    }

    pub fn contains(self: *const Space, entity: Id) bool {
        return self.placeOf(entity) != null;
    }

    fn entryAt(_: *const Space, block: *const Block, row: u32) Entry {
        return .{
            .id = block.id[row],
            .slot = block.slot[row],
            .section = block.section[row],
            .entered = block.entered[row],
            .position = block.position[row],
            .shape = .{ .kind = block.kind[row], .half_width = block.half_width[row], .height = block.height[row] },
        };
    }

    pub const Placed = struct { entry: Entry, world: u32 };

    /// The entity in a slot, and its world, where it is placed.
    pub fn atSlot(self: *const Space, slot: u32) ?Placed {
        if (slot >= self.directory.high()) return null;
        const place = self.directory.entry(slot);
        if (place.space_column == none) return null;
        return .{ .entry = self.entryAt(self.blocks.at(place.space_block), place.space_row), .world = self.columns.at(place.space_column).column.world };
    }

    pub fn get(self: *const Space, entity: Id) ?Entry {
        const entry = self.placeOf(entity) orelse return null;
        return self.entryAt(self.blocks.at(entry.space_block), entry.space_row);
    }

    pub fn columnHolding(self: *const Space, entity: Id) ?Column {
        const entry = self.placeOf(entity) orelse return null;
        return self.columns.at(entry.space_column).column;
    }

    /// The entities of the kinds of a column, in no order.
    /// The entities of the column at a dense index, as `columnsAlong` finds it.
    pub fn entriesAt(self: *const Space, index: u32, kinds: Kinds) Entries {
        return .{ .space = self, .block = self.columns.at(index).first, .kinds = kinds };
    }

    pub fn entries(self: *const Space, column: Column, kinds: Kinds) Entries {
        const index = self.indexOf(column) orelse return .{ .space = self, .block = none, .kinds = kinds };
        return .{ .space = self, .block = self.columns.at(index).first, .kinds = kinds };
    }

    pub const Entries = struct {
        space: *const Space,
        block: u32,
        row: u32 = 0,
        kinds: Kinds,

        pub fn next(self: *Entries) ?Entry {
            while (self.block != none) {
                const block = self.space.blocks.at(self.block);
                while (self.row < block.count) {
                    const row = self.row;
                    self.row += 1;
                    if (self.kinds.has(block.kind[row])) return self.space.entryAt(block, row);
                }
                self.block = block.next;
                self.row = 0;
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
        var at = self.columns.at(index).first;
        while (at != none) {
            const block = self.blocks.at(at);
            for (0..block.count) |row| {
                const position = block.position[row];
                const ax = position[0] - a[0];
                const az = position[2] - a[1];
                const bx = position[0] - b[0];
                const bz = position[2] - b[1];
                if ((ax * ax + az * az <= a_squared) == (bx * bx + bz * bz <= b_squared)) continue;
                if (!kinds.has(block.kind[row])) continue;
                try visit(context, self.entryAt(block, @intCast(row)));
            }
            at = block.next;
        }
    }

    fn changed(self: *Space, held: *ColumnData) void {
        self.changes += 1;
        held.revision = self.changes;
    }

    /// An entity comes into the world: last of its section.
    pub fn insert(self: *Space, entity: Id, world: u32, position: [3]f64, shape: Shape) !void {
        const slot = self.directory.slotOf(entity) orelse return error.NotInMemory;
        const at = try self.reserve(slot);
        errdefer self.unreserve(slot, at);
        try self.putPlace(entity, world, position, shape);
        self.fill(at, slot, .placed);
    }

    fn putPlace(self: *Space, entity: Id, world: u32, position: [3]f64, shape: Shape) !void {
        assert(shape.kind < Kinds.max_kinds);
        const slot = self.directory.slotOf(entity) orelse return error.NotInMemory;
        const entry = self.directory.entry(slot);
        if (entry.space_column != none) return error.AlreadyPlaced;
        const index = try self.ensureColumn(columnOf(world, position));
        errdefer self.releaseColumn(index);
        const held = self.columns.at(index);
        if (held.last == none or self.blocks.at(held.last).count == block_rows) {
            const fresh = try self.blocks.add(undefined);
            const block = self.blocks.at(fresh);
            block.previous = held.last;
            block.next = none;
            block.count = 0;
            if (held.last == none) held.first = fresh else self.blocks.at(held.last).next = fresh;
            held.last = fresh;
        }
        const block = self.blocks.at(held.last);
        const row = block.count;
        block.count += 1;
        block.position[row] = position;
        block.half_width[row] = shape.half_width;
        block.height[row] = shape.height;
        block.kind[row] = shape.kind;
        block.section[row] = coordinate(position[1]);
        block.entered[row] = self.entered;
        block.slot[row] = slot;
        block.id[row] = entity;
        entry.space_column = index;
        entry.space_block = held.last;
        entry.space_row = @intCast(row);
        if (held.count == 0) self.columns_made += 1;
        held.count += 1;
        self.placed += 1;
        self.kind_placed[shape.kind] += 1;
        self.entered += 1;
        self.changed(held);
    }

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

    /// Notes a change of an entity's place kept outside the space, as its sweep.
    pub fn note(self: *Space, slot: u32, event: Change.Event) void {
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
        const entry = self.placeOf(entity) orelse return;
        const index = entry.space_column;
        const held = self.columns.at(index);
        const hole = self.blocks.at(entry.space_block);
        const hole_row = entry.space_row;
        self.kind_placed[hole.kind[hole_row]] -= 1;
        // The column's last entity fills the hole.
        const last = self.blocks.at(held.last);
        const last_row = last.count - 1;
        if (hole != last or hole_row != last_row) {
            hole.position[hole_row] = last.position[last_row];
            hole.half_width[hole_row] = last.half_width[last_row];
            hole.height[hole_row] = last.height[last_row];
            hole.kind[hole_row] = last.kind[last_row];
            hole.section[hole_row] = last.section[last_row];
            hole.entered[hole_row] = last.entered[last_row];
            hole.slot[hole_row] = last.slot[last_row];
            hole.id[hole_row] = last.id[last_row];
            const moved = self.directory.entry(last.slot[last_row]);
            moved.space_block = entry.space_block;
            moved.space_row = hole_row;
        }
        last.count -= 1;
        if (last.count == 0) {
            const emptied = held.last;
            held.last = last.previous;
            if (held.last == none) held.first = none else self.blocks.at(held.last).next = none;
            self.blocks.remove(emptied);
        }
        entry.space_column = none;
        held.count -= 1;
        self.placed -= 1;
        self.changed(held);
        self.releaseColumn(index);
    }

    /// An entity moved: into another column or section it comes last there; within its section
    /// it keeps its turn.
    pub fn move(self: *Space, entity: Id, world: u32, position: [3]f64) !void {
        const entry = self.placeOf(entity) orelse return error.NotPlaced;
        const held = self.columns.at(entry.space_column);
        const block = self.blocks.at(entry.space_block);
        const row = entry.space_row;
        if (std.meta.eql(held.column, columnOf(world, position))) {
            if (std.meta.eql(block.position[row], position)) return;
            const at = try self.reserve(block.slot[row]);
            const section = coordinate(position[1]);
            if (section != block.section[row]) {
                block.section[row] = section;
                block.entered[row] = self.entered;
                self.entered += 1;
            }
            block.position[row] = position;
            self.changed(held);
            self.fill(at, block.slot[row], .moved);
            return;
        }
        const shape: Shape = .{ .kind = block.kind[row], .half_width = block.half_width[row], .height = block.height[row] };
        const slot = block.slot[row];
        const at = try self.reserve(slot);
        errdefer self.unreserve(slot, at);
        self.unplace(entity);
        try self.putPlace(entity, world, position, shape);
        self.fill(at, slot, .moved);
    }

    /// A new size, as a baby grows up: its box changes, and its turn does not.
    pub fn reshape(self: *Space, entity: Id, shape: Shape) void {
        const entry = self.placeOf(entity) orelse return;
        const block = self.blocks.at(entry.space_block);
        block.kind[entry.space_row] = shape.kind;
        block.half_width[entry.space_row] = shape.half_width;
        block.height[entry.space_row] = shape.height;
        self.changed(self.columns.at(entry.space_column));
    }

    /// The entities of one column whose sections lie from `low` to `high`, in vanilla's order,
    /// a round at a time into `buffer`: between rounds the space may change, and the next round
    /// takes up after the last given.
    pub fn ordered(self: *const Space, column: Column, low: i32, high: i32, kinds: Kinds, buffer: []Entry) Ordered {
        assert(buffer.len >= 2 and low <= high);
        return .{ .space = self, .column = column, .low = low, .high = high, .kinds = kinds, .buffer = buffer };
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
        const first: [3]i32 = .{ coordinate(query.min[0] - 2), coordinate(query.min[1] - 4), coordinate(query.min[2] - 2) };
        const last: [3]i32 = .{ coordinate(query.max[0] + 2), coordinate(query.max[1]), coordinate(query.max[2] + 2) };
        var x = first[0];
        while (x <= last[0]) : (x += 1) {
            const spans: [2][2]i32 = .{ .{ @max(first[2], 0), last[2] }, .{ first[2], @min(last[2], -1) } };
            for (spans) |span| {
                var z = span[0];
                while (z <= span[1]) : (z += 1) {
                    const index = self.indexOf(.{ .world = world, .x = x, .z = z }) orelse continue;
                    const start = found_count;
                    var at = self.columns.at(index).first;
                    while (at != none) {
                        const block = self.blocks.at(at);
                        for (0..block.count) |r| {
                            const row: u32 = @intCast(r);
                            if (!kinds.has(block.kind[row]) or block.section[row] < first[1] or block.section[row] > last[1]) continue;
                            const half: f64 = block.half_width[row];
                            const position = block.position[row];
                            const box: Box = .{
                                .min = .{ position[0] - half, position[1], position[2] - half },
                                .max = .{ position[0] + half, position[1] + block.height[row], position[2] + half },
                            };
                            if (!box.intersects(query)) continue;
                            try found.ensure(found_count + 1);
                            found.at(found_count).* = self.entryAt(block, row);
                            found_count += 1;
                        }
                        at = block.next;
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

const Fixture = struct {
    pool: pool_module.Pool,
    directory: Directory,
    space: Space,

    fn init(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.pool = try .init(allocator, 32 * pool_module.page_bytes);
        self.directory = try .init(allocator, &self.pool, 256);
        self.space = try .init(allocator, &self.pool, &self.directory);
    }

    fn insert(self: *Fixture, entity: Id, position: [3]f64) !void {
        if (self.directory.slotOf(entity) == null) _ = try self.directory.add(entity, cow.kind);
        try self.space.insert(entity, 0, position, cow);
    }
};

fn collect(space: *Space, query: Box, output: []Id) ![]Id {
    var state: struct { output: []Id, count: usize = 0 } = .{ .output = output };
    try space.each(0, query, .all, &state, struct {
        fn visit(s: *@TypeOf(state), entry: Entry) anyerror!bool {
            s.output[s.count] = entry.id;
            s.count += 1;
            return false;
        }
    }.visit);
    return output[0..state.count];
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
    try testing.expectEqual(@as(?u32, null), space.indexOf(at));
    try fixture.insert(2, .{ 1, 64, 1 });
    try testing.expect(space.revision(at) != first and space.revision(at) != 0);
}
