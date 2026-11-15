//! Exact light for the columns that block edits and gameplay touch, kept in memory.
//!
//! The engine derives light by solving a neighbourhood from blocks. This store keeps the
//! result so that a block edit patches it in place and gameplay samples it. It is the
//! memory stage of a two stage cache. Light that equals a baked frame leaves memory
//! without a trace. Light an edit has changed leaves as an overflow record, which the
//! caller writes to disk and reads back when the column is needed again.
//!
//! The simulation thread owns the store. Nothing here is locked and nothing here does
//! disk IO. The caller reads frames and records and hands their light in.
//!
//! A column the store knows is in one of three states. Resident light is in memory and
//! exact for the current blocks, less the edits the caller has not settled yet.
//! Overflowed light is the same, in a record on disk. An unlit column has no stored
//! light at all: an edit changed light around it that no patch could follow, and only a
//! solve from blocks can light it again.
//!
//! A column the store does not know may be lit from its baked frame. That is sound only
//! because every edit that makes a frame stale leaves the columns around it known here,
//! dirty or unlit, until a checkpoint has saved the edit. A saved edit changes the
//! revisions its frames were baked for, so they stop matching on their own. When the
//! table cannot keep such an entry the store stops trusting frames until the next
//! checkpoint.
const std = @import("std");
const assert = std.debug.assert;
const chunks = @import("chunks");
const lighting = @import("lighting");
const patch = lighting.patch;

pub const section_bytes = 2048;
pub const sections_max = patch.sections_max;

pub const Key = struct { world: u32, x: i32, z: i32 };

/// The dimension a column was lit for. Light of another shape is never mixed in.
pub const Shape = struct {
    minimum: i32,
    count: u8,
    skylight: bool,

    /// Light sections of one layer: the world sections and one beyond each end.
    pub fn sections(self: Shape) usize {
        return @as(usize, self.count) + 2;
    }
};

pub const Sample = packed struct(u8) { block: u4, sky: u4 };

pub const Configuration = struct {
    /// Dense light sections of 2 KiB each.
    sections: usize,
    /// Columns remembered, in any state.
    columns: usize,
    /// Players whose surroundings are protected from eviction.
    players: usize,
    /// Dense sections each player keeps around the column they stand in, whatever the
    /// other players do. The rest of the pool is shared, least recently used first.
    guaranteed: usize,
    /// Cells one patch may change in a layer. A larger patch is refused.
    patch_cells: usize = 1 << 15,
    /// Block state sections one patch may decode.
    state_sections: usize = 64,
    /// Light cells the patches of one tick may visit. The columns past that wait for the
    /// next tick, as light lags in vanilla, so a burst of edits spreads over ticks. A
    /// column waits no longer than it would for its blocks to be read.
    patch_steps: u64 = 1 << 15,
    /// Block edits whose light may wait to be settled at once. Past that, the light
    /// around an edit is dropped and solved again.
    edits: usize = edits_shared + edits_per_slot,

    /// Edits any player may use, for bursts such as explosions and fills.
    pub const edits_shared = 1024;
    /// Edits kept for each player slot, for what one player builds while the light
    /// around them is read.
    pub const edits_per_slot = 256;

    /// The policy for a server with this many player slots: 512 KiB of light per slot,
    /// a quarter of it guaranteed to the player in the slot.
    pub fn forPlayers(slots: usize) Configuration {
        assert(slots != 0);
        return .{ .sections = slots * 256, .columns = slots * 256, .players = slots, .guaranteed = 64, .edits = edits_shared + edits_per_slot * slots };
    }
};

/// Every light section of one column, by layer and section, held by someone else.
pub const Sections = struct {
    light: [2][sections_max]patch.Light = undefined,
};

/// The light of one column copied into caller memory.
pub const Copy = struct {
    pub const capacity = 2 * sections_max;
    key: Key = undefined,
    shape: Shape = undefined,
    /// Sections that hold a buffer. The rest are one level.
    dense: [2]u32 = .{ 0, 0 },
    /// The level of a uniform section, or the index in `bytes` of a dense one.
    slots: [2][sections_max]u8 = undefined,
    bytes: *[capacity][section_bytes]u8,
    used: usize = 0,

    pub fn section(self: *const Copy, layer: usize, index: usize) patch.Light {
        assert(index < self.shape.sections());
        if (self.dense[layer] & (@as(u32, 1) << @intCast(index)) == 0) return .{ .uniform = @intCast(self.slots[layer][index]) };
        return .{ .dense = &self.bytes[self.slots[layer][index]] };
    }

    pub fn view(self: *const Copy) Sections {
        var result: Sections = .{};
        for (0..2) |layer| for (0..self.shape.sections()) |index| {
            result.light[layer][index] = self.section(layer, index);
        };
        return result;
    }

    /// Takes the light of a column from someone else's buffers.
    pub fn take(self: *Copy, key: Key, shape: Shape, source: *const Sections) void {
        self.key = key;
        self.shape = shape;
        self.dense = .{ 0, 0 };
        self.used = 0;
        for (0..2) |layer| for (0..shape.sections()) |index| switch (source.light[layer][index]) {
            .uniform => |level| self.slots[layer][index] = level,
            .dense => |bytes| if (uniformLevel(bytes)) |level| {
                self.slots[layer][index] = level;
            } else {
                @memcpy(&self.bytes[self.used], bytes);
                self.slots[layer][index] = @intCast(self.used);
                self.dense[layer] |= @as(u32, 1) << @intCast(index);
                self.used += 1;
            },
        };
    }

    const record_magic = 0x324c504c;
    const record_header = 4 + 8 + 4 + 1 + 1 + 2 * 4;
    /// The largest record a column can need.
    pub const record_bytes = record_header + capacity * section_bytes + 8;

    /// Writes the copy as an overflow record. The stamp ties it to the process that wrote
    /// it, since it describes blocks that may never have been saved.
    pub fn encode(self: *const Copy, stamp: u64, output: *[record_bytes]u8) []const u8 {
        var writer: std.Io.Writer = .fixed(output);
        writer.writeInt(u32, record_magic, .little) catch unreachable;
        writer.writeInt(u64, stamp, .little) catch unreachable;
        writer.writeInt(i32, self.shape.minimum, .little) catch unreachable;
        writer.writeByte(self.shape.count) catch unreachable;
        writer.writeByte(@intFromBool(self.shape.skylight)) catch unreachable;
        for (self.dense) |mask| writer.writeInt(u32, mask, .little) catch unreachable;
        for (0..2) |layer| for (0..self.shape.sections()) |index| switch (self.section(layer, index)) {
            .uniform => |value| writer.writeByte(value) catch unreachable,
            .dense => |bytes| writer.writeAll(bytes) catch unreachable,
        };
        writer.writeInt(u64, std.hash.Wyhash.hash(stamp, writer.buffered()), .little) catch unreachable;
        return writer.buffered();
    }

    /// Reads a record this process wrote for a column of this shape. False for anything else.
    pub fn decode(self: *Copy, key: Key, shape: Shape, stamp: u64, record: []const u8) bool {
        if (record.len < record_header + 8 or record.len > record_bytes) return false;
        const body = record[0 .. record.len - 8];
        if (std.mem.readInt(u64, record[record.len - 8 ..][0..8], .little) != std.hash.Wyhash.hash(stamp, body)) return false;
        if (std.mem.readInt(u32, body[0..4], .little) != record_magic or std.mem.readInt(u64, body[4..12], .little) != stamp) return false;
        const stored: Shape = .{ .minimum = std.mem.readInt(i32, body[12..16], .little), .count = body[16], .skylight = body[17] != 0 };
        if (!std.meta.eql(stored, shape) or shape.count == 0 or shape.sections() > sections_max) return false;
        const all = (@as(u32, 1) << @intCast(shape.sections())) - 1;
        const dense: [2]u32 = .{ std.mem.readInt(u32, body[18..22], .little), std.mem.readInt(u32, body[22..26], .little) };
        if ((dense[0] | dense[1]) & ~all != 0) return false;
        self.key = key;
        self.shape = shape;
        self.dense = dense;
        self.used = 0;
        var at: usize = record_header;
        for (0..2) |layer| for (0..shape.sections()) |index| {
            if (dense[layer] & (@as(u32, 1) << @intCast(index)) == 0) {
                if (at == body.len or body[at] > 15) return false;
                self.slots[layer][index] = body[at];
                at += 1;
                continue;
            }
            if (body.len - at < section_bytes) return false;
            @memcpy(&self.bytes[self.used], body[at..][0..section_bytes]);
            self.slots[layer][index] = @intCast(self.used);
            self.used += 1;
            at += section_bytes;
        };
        return at == body.len;
    }
};

/// A block edit that light is not settled for yet, with the state its cell held before.
pub const Pending = struct { section: chunks.Section, index: u12, previous: u16 };

/// The edits not settled yet, grouped by column. A patch sees their cells as they were.
pub const Waiting = struct {
    edits: []const Pending,
    columns: *const std.AutoHashMapUnmanaged(Key, Range),

    /// Where the edits of one column sit in `edits`, in the order they were made.
    pub const Range = struct { start: u32, len: u32, waiting: bool };

    /// The edits of this column that still wait, oldest first.
    pub fn of(self: Waiting, key: Key) []const Pending {
        const range = self.columns.get(key) orelse return &.{};
        if (!range.waiting) return &.{};
        assert(range.start + range.len <= self.edits.len);
        return self.edits[range.start..][0..range.len];
    }
};

pub const Presence = enum {
    /// The store knows nothing of the column. Its baked frame may light it.
    absent,
    resident,
    /// Its light is in an overflow record.
    overflowed,
    /// It has no stored light and its frame is not to be trusted.
    unlit,
    /// Its light is being read from disk.
    loading,
};

/// Where the light of a column being loaded is read from.
pub const Source = enum { frame, record };

/// A load the store has begun. The stamp names it to `admitLoaded` and `failLoad`.
pub const Load = struct { stamp: u64, source: Source };

pub const Outcome = union(enum) {
    /// Light the patch needed is not in memory, or the patch did not fit. Nothing changed.
    failed,
    /// The nine columns are settled. These light sections changed.
    patched: patch.Changes,
    /// Block states the patch needs are not in memory. These sections of the nine
    /// columns should be read, and the patch tried again. Nothing changed.
    waiting: u32,
};

/// What `darken` did to the nine columns around an edit.
pub const Darkened = struct {
    /// The request stamp of each column, zero for one outside the world.
    stamps: [9]u64 = @splat(0),
    /// Columns whose overflow record is now meaningless and should be deleted.
    records: [9]bool = @splat(false),
    /// The table was full and everything was forgotten. Every overflow record is
    /// meaningless now.
    reset: bool = false,
};

/// What the caller must do after `maintain` made room.
pub const Maintenance = union(enum) {
    idle,
    /// A patched column left memory. Write the copy to disk, or call `lose`.
    overflow,
    /// An overflowed column was forgotten. Delete its record.
    forgotten: Key,
};

pub const Stats = struct {
    resident: usize = 0,
    overflowed: usize = 0,
    unlit: usize = 0,
    loading: usize = 0,
    sections: usize = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    patches: u64 = 0,
    /// Patches run, counting every one a missing section cut short.
    attempts: u64 = 0,
    /// Cells the patches visited, across every attempt.
    steps: u64 = 0,
    failures: u64 = 0,
    waits: u64 = 0,
    darkened: u64 = 0,
    frames: u64 = 0,
    restores: u64 = 0,
    solves: u64 = 0,
    evictions: u64 = 0,
    overflows: u64 = 0,
    forgotten: u64 = 0,
    resets: u64 = 0,
};

const none = std.math.maxInt(u32);

const Column = struct {
    key: Key = undefined,
    shape: Shape = undefined,
    state: enum(u8) { vacant, resident, overflowed, unlit, loading } = .vacant,
    /// Where a loading column's light is read from.
    source: Source = .frame,
    /// An edit changed this light since it equalled a baked frame.
    dirty: bool = false,
    /// Sections that hold a pool section. The rest are one level.
    dense: [2]u32 = .{ 0, 0 },
    /// A pool index for a dense section, a level for a uniform one.
    slots: [2][sections_max]u32 = undefined,
    /// Neighbours in the list of its kind, by last use.
    newer: u32 = none,
    older: u32 = none,
    /// An edit changed this light or took it away, so the baked frame of the column is
    /// stale until a checkpoint later than `mark` has saved that edit.
    tainted: bool = false,
    /// The checkpoint count when that edit was made.
    mark: u64 = 0,
    /// The tick whose unsettled edits need this column to stay in memory.
    pinned: u64 = 0,
    /// The protection pass that kept this column for a player standing by it.
    protected: u64 = 0,
    /// The request a solve must answer to light an unlit column.
    stamp: u64 = 0,
    /// Whether an overflow record of this column is on disk, and whether it still
    /// equals the light.
    record: enum(u8) { none, stale, current } = .none,

    fn held(self: *const Column) usize {
        return @as(usize, @popCount(self.dense[0])) + @popCount(self.dense[1]);
    }
};

const List = struct {
    newest: u32 = none,
    oldest: u32 = none,
};

pub const LightStore = struct {
    bytes: [][section_bytes]u8,
    free: []u32,
    free_count: usize,
    columns: []Column,
    vacant: []u32,
    vacant_count: usize,
    map: std.AutoHashMapUnmanaged(Key, u32) = .empty,
    /// Columns in memory, by last use.
    resident: List = .{},
    /// Columns remembered without light in memory, whose frame an unsaved edit made
    /// stale, in the order they got here. Only the oldest is ever looked at for
    /// forgetting. One that waits behind an older arrival with a newer edit is let go
    /// a checkpoint later than it could be, which costs room and nothing else.
    tainted: List = .{},
    /// Columns remembered without light in memory that may be forgotten at any time,
    /// by last use.
    loose: List = .{},
    patcher: patch.Patcher,
    states: [][4096]u16,
    spare: []*[section_bytes]u8,
    /// Free sections and vacant columns `maintain` keeps ready for the next tick.
    reserve_sections: usize,
    reserve_columns: usize,
    guaranteed: usize,
    /// Checkpoints the chunks have completed, as last told.
    flush_mark: u64 = 0,
    /// Frames are trusted again once a checkpoint completes after this one.
    distrust: ?u64 = null,
    tick: u64 = 1,
    pass: u64 = 1,
    stamps: u64 = 0,
    stats: Stats = .{},

    const spare_max = 64;

    pub fn init(allocator: std.mem.Allocator, registry: lighting.Registry, config: Configuration) !*LightStore {
        if (config.sections < 2 * Copy.capacity or config.columns < 32 or config.state_sections == 0 or config.players == 0) return error.InvalidLightStoreCapacity;
        if (config.sections >= none or config.columns >= none) return error.InvalidLightStoreCapacity;
        // The guaranteed shares together leave most of the pool to be shared.
        if (config.guaranteed > config.sections / config.players / 2) return error.InvalidLightStoreCapacity;
        const self = try allocator.create(LightStore);
        self.* = .{
            .bytes = try allocator.alloc([section_bytes]u8, config.sections),
            .free = try allocator.alloc(u32, config.sections),
            .free_count = config.sections,
            .columns = try allocator.alloc(Column, config.columns),
            .vacant = try allocator.alloc(u32, config.columns),
            .vacant_count = config.columns,
            .patcher = try patch.Patcher.init(allocator, registry, config.patch_cells),
            .states = try allocator.alloc([4096]u16, config.state_sections),
            .spare = try allocator.alloc(*[section_bytes]u8, spare_max),
            // Room for the nine columns of an edit somewhere new, for a few such edits.
            .reserve_sections = @min(config.sections / 4, @max(2 * Copy.capacity, config.sections / 8)),
            .reserve_columns = @max(config.columns / 8, 9),
            .guaranteed = config.guaranteed,
        };
        for (self.free, 0..) |*slot, index| slot.* = @intCast(config.sections - 1 - index);
        for (self.vacant, 0..) |*slot, index| slot.* = @intCast(config.columns - 1 - index);
        @memset(self.columns, .{});
        try self.map.ensureTotalCapacity(allocator, @intCast(config.columns));
        return self;
    }

    /// Bytes this store holds for its whole life.
    pub fn memory(self: *const LightStore) usize {
        return self.bytes.len * section_bytes + self.free.len * 4 + self.columns.len * @sizeOf(Column) + self.vacant.len * 4 +
            self.map.capacity() * (@sizeOf(Key) + 4 + 1) + self.spare.len * @sizeOf(usize) +
            self.states.len * @sizeOf([4096]u16) + self.patcher.seen.len * 8 + (self.patcher.log.len + self.patcher.removals.len + self.patcher.increases.len) * 4;
    }

    pub fn snapshot(self: *const LightStore) Stats {
        var result = self.stats;
        result.sections = self.bytes.len - self.free_count;
        return result;
    }

    /// Tells the store how many checkpoints the chunks have completed. An edit made
    /// before a checkpoint is saved by it.
    pub fn noteFlush(self: *LightStore, mark: u64) void {
        assert(mark >= self.flush_mark);
        self.flush_mark = mark;
    }

    /// Whether the baked frame of an absent column may light it.
    pub fn framesTrusted(self: *const LightStore) bool {
        const since = self.distrust orelse return true;
        return self.flush_mark > since;
    }

    pub fn presence(self: *LightStore, key: Key, shape: Shape) Presence {
        const column = self.find(key) orelse return .absent;
        // Light for another shape of the world says nothing about this one.
        if (!std.meta.eql(column.shape, shape)) self.extinguish(column, shape);
        return switch (column.state) {
            .vacant => unreachable,
            .resident => .resident,
            .overflowed => .overflowed,
            .unlit => .unlit,
            .loading => .loading,
        };
    }

    /// Begins reading the light of a column from disk: from its overflow record when it
    /// has one, from its baked frame when the store knows nothing of it. Null when
    /// neither may light it, or it cannot be remembered.
    pub fn beginLoad(self: *LightStore, key: Key, shape: Shape) ?Load {
        if (self.find(key)) |column| {
            if (column.state != .overflowed or column.record != .current or !std.meta.eql(column.shape, shape)) return null;
            self.detach(column);
            self.stats.overflowed -= 1;
            column.state = .loading;
            column.source = .record;
            self.stamps += 1;
            column.stamp = self.stamps;
            self.attach(column);
            self.stats.loading += 1;
            return .{ .stamp = column.stamp, .source = .record };
        }
        if (!self.framesTrusted() or self.vacant_count == 0) return null;
        self.vacant_count -= 1;
        const slot = self.vacant[self.vacant_count];
        const column = &self.columns[slot];
        assert(column.state == .vacant);
        self.stamps += 1;
        column.* = .{ .key = key, .shape = shape, .state = .loading, .source = .frame, .stamp = self.stamps };
        self.map.putAssumeCapacityNoClobber(key, slot);
        self.attach(column);
        self.stats.loading += 1;
        return .{ .stamp = self.stamps, .source = .frame };
    }

    /// Lights a loading column with what was read for it. Refused when the load is not
    /// the one the column waits for, because an edit has darkened it since, or when
    /// there is no room.
    pub fn admitLoaded(self: *LightStore, key: Key, shape: Shape, stamp: u64, light: *const Sections) bool {
        assert(stamp != 0);
        const column = self.find(key) orelse return false;
        if (column.state != .loading or column.stamp != stamp or !std.meta.eql(column.shape, shape)) return false;
        if (!self.reserve(denseCount(shape, light))) return false;
        self.detach(column);
        self.stats.loading -= 1;
        column.state = .resident;
        column.stamp = 0;
        switch (column.source) {
            .frame => {
                column.dirty = false;
                self.stats.frames += 1;
            },
            .record => {
                // The record is the only copy of this light, and it is still current.
                column.dirty = true;
                self.stats.restores += 1;
            },
        }
        self.attach(column);
        self.stats.resident += 1;
        self.fill(column, light);
        self.pin(key);
        return true;
    }

    /// Gives up the load a column waits for. It has no light and only a solve can light
    /// it, since what it waited for may describe blocks it no longer has. Whether its
    /// frame may be stale is what it was before: no edit could settle near it meanwhile.
    pub fn failLoad(self: *LightStore, key: Key, stamp: u64) void {
        const column = self.find(key) orelse return;
        if (column.state != .loading or column.stamp != stamp) return;
        const tainted = column.tainted;
        const mark = column.mark;
        self.extinguish(column, column.shape);
        if (tainted) return;
        self.detach(column);
        column.tainted = false;
        column.mark = mark;
        self.attach(column);
    }

    /// Lights an unlit column from a solve of the current blocks. Refused when the
    /// solve answers an older request, because an edit has darkened the column since.
    pub fn admitSolved(self: *LightStore, key: Key, shape: Shape, stamp: u64, light: *const Sections) bool {
        assert(stamp != 0);
        const column = self.find(key) orelse return false;
        if (column.state != .unlit or column.stamp != stamp or !std.meta.eql(column.shape, shape)) return false;
        if (!self.reserve(denseCount(shape, light))) return false;
        self.detach(column);
        self.stats.unlit -= 1;
        column.state = .resident;
        // A solve near an unsaved edit is the only copy of its light. Where no edit made
        // the frame stale, a frame of the current blocks would hold the same light.
        column.dirty = column.tainted;
        column.stamp = 0;
        self.attach(column);
        self.stats.resident += 1;
        self.fill(column, light);
        self.stats.solves += 1;
        return true;
    }

    fn denseCount(shape: Shape, light: *const Sections) usize {
        assert(shape.count != 0 and shape.sections() <= sections_max);
        var needed: usize = 0;
        for (0..2) |layer| for (0..shape.sections()) |index| switch (light.light[layer][index]) {
            .uniform => {},
            .dense => |bytes| needed += @intFromBool(uniformLevel(bytes) == null),
        };
        return needed;
    }

    fn fill(self: *LightStore, column: *Column, light: *const Sections) void {
        assert(column.state == .resident and column.dense[0] | column.dense[1] == 0);
        for (0..2) |layer| for (0..column.shape.sections()) |index| {
            const level: ?u4 = switch (light.light[layer][index]) {
                .uniform => |value| value,
                .dense => |bytes| uniformLevel(bytes),
            };
            if (level) |value| {
                column.slots[layer][index] = value;
                continue;
            }
            self.free_count -= 1;
            const slot = self.free[self.free_count];
            @memcpy(&self.bytes[slot], light.light[layer][index].dense);
            column.slots[layer][index] = slot;
            column.dense[layer] |= @as(u32, 1) << @intCast(index);
        };
    }

    /// Frees sections until `needed` are free, by taking columns out of memory whose
    /// light is on disk already: as their baked frame, or as an overflow record that
    /// still equals it. Columns that unsettled edits or players need stay.
    fn reserve(self: *LightStore, needed: usize) bool {
        var index = self.resident.oldest;
        while (self.free_count < needed and index != none) {
            const column = &self.columns[index];
            index = column.newer;
            if (column.pinned == self.tick or column.protected == self.pass or column.held() == 0) continue;
            if (!column.dirty) {
                self.release(column);
            } else if (column.record == .current) {
                self.overflow(column);
            } else continue;
            self.stats.evictions += 1;
        }
        return self.free_count >= needed;
    }

    /// Takes a patched column out of memory. Its record must hold its light.
    fn overflow(self: *LightStore, column: *Column) void {
        assert(column.state == .resident and column.dirty);
        self.freeSections(column);
        self.detach(column);
        column.state = .overflowed;
        self.attach(column);
        self.stats.resident -= 1;
        self.stats.overflowed += 1;
        self.stats.overflows += 1;
    }

    /// Keeps a column in memory until `unpin`, for an edit that is not settled yet.
    pub fn pin(self: *LightStore, key: Key) void {
        const column = self.find(key).?;
        assert(column.state == .resident);
        column.pinned = self.tick;
        self.touch(column);
    }

    /// Releases every pin. Called once no edit is unsettled.
    pub fn unpin(self: *LightStore) void {
        self.tick += 1;
    }

    /// Starts a pass over the players. What the pass before protected is no longer
    /// protected unless this one asks again.
    pub fn beginProtection(self: *LightStore) void {
        self.pass += 1;
    }

    /// Protects the light around the column a player stands in from being evicted for
    /// others, nearest columns first, up to the guaranteed share.
    pub fn protect(self: *LightStore, key: Key) void {
        const order = [9]u8{ 4, 1, 3, 5, 7, 0, 2, 6, 8 };
        var budget = self.guaranteed;
        for (order) |index| {
            const column = self.find(neighbour(key, index) orelse continue) orelse continue;
            if (column.state != .resident or column.protected == self.pass) continue;
            const cost = column.held();
            if (cost > budget) break;
            budget -= cost;
            column.protected = self.pass;
        }
    }

    /// Takes the stored light of the nine columns around an edit away, in memory and on
    /// disk. Each stays known as unlit until a solve lights it or a checkpoint saves the
    /// edit. The stamps name the solves that may light them.
    pub fn darken(self: *LightStore, key: Key, shape: Shape) Darkened {
        var result: Darkened = .{};
        for (0..9) |index| {
            const at = neighbour(key, index) orelse continue;
            self.stamps += 1;
            result.stamps[index] = self.stamps;
            self.stats.darkened += 1;
            if (self.find(at)) |column| {
                result.records[index] = column.record != .none;
                self.extinguish(column, shape);
                column.record = .none;
                column.stamp = self.stamps;
                continue;
            }
            if (self.vacant_count == 0) {
                // Nothing can be remembered about this column, so nothing may be assumed
                // about any column until the edits so far are saved.
                self.reset();
                result.reset = true;
            }
            self.vacant_count -= 1;
            const slot = self.vacant[self.vacant_count];
            const column = &self.columns[slot];
            assert(column.state == .vacant);
            column.* = .{ .key = at, .shape = shape, .state = .unlit, .tainted = true, .mark = self.flush_mark, .stamp = self.stamps };
            self.map.putAssumeCapacityNoClobber(at, slot);
            self.attach(column);
            self.stats.unlit += 1;
        }
        return result;
    }

    /// Remembers a column that is wanted in memory, which no stage has light for, as
    /// unlit so that a solve can light it. The stamp names that solve. A column that
    /// was darkened keeps the stamp it got then. Zero when the column has light or
    /// cannot be remembered.
    pub fn request(self: *LightStore, key: Key, shape: Shape) u64 {
        if (self.find(key)) |column| {
            if (column.state != .unlit or !std.meta.eql(column.shape, shape)) return 0;
            if (column.stamp == 0) {
                self.stamps += 1;
                column.stamp = self.stamps;
            }
            return column.stamp;
        }
        if (self.vacant_count == 0) return 0;
        self.stamps += 1;
        self.vacant_count -= 1;
        const slot = self.vacant[self.vacant_count];
        const column = &self.columns[slot];
        assert(column.state == .vacant);
        // No edit made its frame stale, so it may be forgotten at any time.
        column.* = .{ .key = key, .shape = shape, .state = .unlit, .stamp = self.stamps };
        self.map.putAssumeCapacityNoClobber(key, slot);
        self.attach(column);
        self.stats.unlit += 1;
        return self.stamps;
    }

    /// Makes one column unlit, whatever it was.
    fn extinguish(self: *LightStore, column: *Column, shape: Shape) void {
        self.detach(column);
        switch (column.state) {
            .vacant => unreachable,
            .resident => {
                self.freeSections(column);
                self.stats.resident -= 1;
            },
            .overflowed => self.stats.overflowed -= 1,
            .unlit => self.stats.unlit -= 1,
            .loading => self.stats.loading -= 1,
        }
        column.state = .unlit;
        column.shape = shape;
        column.dirty = false;
        column.dense = .{ 0, 0 };
        column.tainted = true;
        column.mark = self.flush_mark;
        column.stamp = 0;
        // A record that is on disk stays known, so that forgetting the column deletes it.
        if (column.record == .current) column.record = .stale;
        self.attach(column);
        self.stats.unlit += 1;
    }

    /// Marks an overflowed column unlit after its record could not be written or read.
    pub fn lose(self: *LightStore, key: Key) void {
        const column = self.find(key) orelse return;
        if (column.state != .overflowed) return;
        self.extinguish(column, column.shape);
    }

    /// Forgets everything and stops trusting frames until the edits made so far are saved.
    pub fn reset(self: *LightStore) void {
        self.clear();
        self.distrust = self.flush_mark;
        self.stats.resets += 1;
    }

    /// Forgets everything, as after a change of block definitions. Frames baked under
    /// other definitions do not match the new ones, so they need no distrust.
    pub fn clear(self: *LightStore) void {
        for (self.columns) |*column| if (column.state != .vacant) self.release(column);
        assert(self.free_count == self.bytes.len and self.vacant_count == self.columns.len);
        assert(self.resident.newest == none and self.tainted.newest == none and self.loose.newest == none);
    }

    /// Samples one column. `cells` index its light, a section of 4096 cells at a time
    /// from the one below the world. False when the column is not in memory.
    pub fn sample(self: *LightStore, key: Key, shape: Shape, cells: []const u32, output: []Sample) bool {
        assert(cells.len == output.len);
        const column = self.find(key) orelse {
            self.stats.misses += 1;
            return false;
        };
        if (column.state != .resident or !std.meta.eql(column.shape, shape)) {
            self.stats.misses += 1;
            return false;
        }
        for (cells, output) |cell, *result| {
            const index = cell / 4096;
            assert(index < shape.sections());
            var levels: [2]u4 = undefined;
            for (0..2) |layer| {
                const slot = column.slots[layer][index];
                levels[layer] = if (column.dense[layer] & (@as(u32, 1) << @intCast(index)) == 0) @intCast(slot) else nibble(&self.bytes[slot], cell % 4096);
            }
            result.* = .{ .block = levels[0], .sky = levels[1] };
        }
        self.touch(column);
        self.stats.hits += 1;
        return true;
    }

    /// The light of a resident column, borrowed until the store next changes.
    pub fn lightOf(self: *LightStore, key: Key, shape: Shape, output: *Sections) bool {
        const column = self.find(key) orelse return false;
        if (column.state != .resident or !std.meta.eql(column.shape, shape)) return false;
        self.borrow(column, output);
        return true;
    }

    fn borrow(self: *LightStore, column: *const Column, output: *Sections) void {
        for (0..2) |layer| for (0..column.shape.sections()) |index| {
            const slot = column.slots[layer][index];
            output.light[layer][index] = if (column.dense[layer] & (@as(u32, 1) << @intCast(index)) == 0) .{ .uniform = @intCast(slot) } else .{ .dense = &self.bytes[slot] };
        };
    }

    /// Settles the light around edits already made to one column. Every one of the nine
    /// columns must be resident, which the caller arranges when the edit is made.
    ///
    /// `waiting` holds the edits to other columns that are not settled yet. The patch sees
    /// their cells as they were, because the light it starts from was exact for that.
    /// The edits being settled are not among them.
    pub fn settle(self: *LightStore, terrain: *chunks.Chunks, key: Key, shape: Shape, edits: []const patch.Edit, waiting: Waiting) Outcome {
        assert(edits.len != 0);
        assert(waiting.of(key).len == 0);
        var members: [9]*Column = undefined;
        for (&members, 0..) |*member, index| {
            const column = self.find(neighbour(key, index) orelse return self.fail()) orelse return self.fail();
            if (column.state != .resident or !std.meta.eql(column.shape, shape)) return self.fail();
            member.* = column;
        }
        var states: [9][sections_max - 2]?patch.States = @splat(@splat(null));
        var decoded: usize = 0;
        // Every section read later restarts the patch, so the ones it is sure to read
        // are fetched first and together.
        var likely: u32 = 0;
        const centre = members[4];
        for (edits) |edit| {
            const section: usize = edit.section;
            likely |= @as(u32, 1) << @intCast(section);
            if (section + 1 < shape.count) likely |= @as(u32, 1) << @intCast(section + 1);
            var below = section;
            while (below != 0) {
                below -= 1;
                // Light reaches one section down. Sky light an edit lets in or shuts out
                // runs down to the ground, so the walk goes on through every section with
                // some sky light. One with none lies under the ground.
                if (below + 1 != section) {
                    const bit = @as(u32, 1) << @intCast(below + 1);
                    const dark = centre.dense[1] & bit == 0 and centre.slots[1][below + 1] == 0;
                    if (!shape.skylight or dark) break;
                }
                likely |= @as(u32, 1) << @intCast(below);
            }
        }
        var absent: [9]u32 = @splat(0);
        absent[4] = self.loadColumn(terrain, key, shape, likely, waiting, &states[4], &decoded);
        var neighbours_read = false;
        while (true) {
            const wanted = switch (self.attempt(shape, &members, edits, &states) orelse return self.fail()) {
                .patched => |changes| return .{ .patched = changes },
                .states => |wanted| wanted,
            };
            assert(wanted.kind == .states and wanted.column < 9 and wanted.section < shape.count);
            // The patch reached this column. What the edits reach in the centre column
            // they tend to reach here too, and each section asked for alone would
            // restart the patch once more. A patch that reaches one neighbour mostly
            // reaches the others, so the first time it does, all eight are read together.
            for (0..9) |column| {
                if (column != wanted.column and (neighbours_read or column == 4)) continue;
                const at = neighbour(key, column) orelse return self.fail();
                var sections = likely;
                if (column == wanted.column) sections |= @as(u32, 1) << @intCast(wanted.section);
                for (states[column][0..shape.count], 0..) |loaded, section| {
                    if (loaded != null) sections &= ~(@as(u32, 1) << @intCast(section));
                }
                sections &= ~absent[column];
                if (sections != 0) absent[column] |= self.loadColumn(terrain, at, shape, sections, waiting, &states[column], &decoded);
            }
            neighbours_read = true;
            if (states[wanted.column][wanted.section] != null) continue;
            // A section that is not in memory is read by the terrain thread, with what
            // the patch is likely to want beside it, and the patch is tried again later.
            if (absent[wanted.column] & (@as(u32, 1) << @intCast(wanted.section)) != 0) {
                self.stats.waits += 1;
                return .{ .waiting = likely | (@as(u32, 1) << @intCast(wanted.section)) };
            }
            return self.fail();
        }
    }

    fn fail(self: *LightStore) Outcome {
        self.stats.failures += 1;
        return .failed;
    }

    const Attempt = union(enum) { patched: patch.Changes, states: patch.Missing };

    /// One try at the patch with the block states read so far. Null when it does not fit.
    fn attempt(self: *LightStore, shape: Shape, members: *const [9]*Column, edits: []const patch.Edit, states: *const [9][sections_max - 2]?patch.States) ?Attempt {
        var region: patch.Region = .{ .count = shape.count, .skylight = shape.skylight, .states = states.* };
        for (members, 0..) |column, index| {
            for (0..2) |layer| for (0..shape.sections()) |section| {
                const slot = column.slots[layer][section];
                region.light[layer][index][section] = if (column.dense[layer] & (@as(u32, 1) << @intCast(section)) == 0) .{ .uniform = @intCast(slot) } else .{ .dense = &self.bytes[slot] };
            };
        }
        const offered = @min(self.spare.len, self.free_count);
        for (self.spare[0..offered], 0..) |*entry, index| entry.* = &self.bytes[self.free[self.free_count - offered + index]];
        region.spare = self.spare[0..offered];
        const result = self.patcher.apply(&region, edits);
        self.stats.attempts += 1;
        self.stats.steps += self.patcher.work.visited + self.patcher.work.removed;
        const changes = result catch |err| {
            assert(region.spare.len == offered);
            if (err != error.MissingSection) return null;
            const missing = self.patcher.missing.?;
            return if (missing.kind == .states) .{ .states = missing } else null;
        };
        // The patch took the last of the offered sections first, as the free list gives them.
        self.free_count -= offered - region.spare.len;
        for (members, 0..) |column, index| {
            for (0..2) |layer| {
                for (0..shape.sections()) |section| {
                    // A section that stopped being one level took a pool section.
                    const bit = @as(u32, 1) << @intCast(section);
                    const lit = region.light[layer][index][section].?;
                    if (lit != .dense or column.dense[layer] & bit != 0) continue;
                    column.slots[layer][section] = @intCast((@intFromPtr(lit.dense) - @intFromPtr(self.bytes.ptr)) / section_bytes);
                    column.dense[layer] |= bit;
                }
                // A section that became one level gives its pool section back.
                var bits = changes.sections[layer][index] & column.dense[layer];
                while (bits != 0) : (bits &= bits - 1) {
                    const section = @ctz(bits);
                    const slot = column.slots[layer][section];
                    const value = uniformLevel(&self.bytes[slot]) orelse continue;
                    self.free[self.free_count] = slot;
                    self.free_count += 1;
                    column.slots[layer][section] = value;
                    column.dense[layer] &= ~(@as(u32, 1) << @intCast(section));
                }
            }
            // The frames of all nine were baked for blocks that have now changed, so none
            // of them vouches for this light any more, changed or not.
            column.dirty = true;
            column.tainted = true;
            column.mark = self.flush_mark;
            if (changes.column(index) != 0 and column.record == .current) column.record = .stale;
            self.touch(column);
        }
        self.stats.patches += 1;
        return .{ .patched = changes };
    }

    /// Reads block state sections of one of the nine columns that are in memory, as far
    /// as the scratch for decoded states lasts. Nothing is read from disk: the sections
    /// that are not in memory stay unloaded and are answered. Outside the centre column,
    /// cells that other unsettled edits changed read as they were before those edits.
    /// The centre column's own edits are what the patch settles.
    fn loadColumn(self: *LightStore, terrain: *chunks.Chunks, at: Key, shape: Shape, sections: u32, waiting: Waiting, states: *[sections_max - 2]?patch.States, decoded: *usize) u32 {
        var absent: u32 = 0;
        const pending = waiting.of(at);
        var positions: [sections_max - 2]chunks.Section = undefined;
        var indices: [sections_max - 2]usize = undefined;
        var leases: [sections_max - 2]chunks.Lease = undefined;
        var count: usize = 0;
        var bits = sections;
        while (bits != 0) : (bits &= bits - 1) {
            const section = @ctz(bits);
            assert(section < shape.count);
            positions[count] = .{ .world = at.world, .x = at.x, .y = shape.minimum + @as(i32, @intCast(section)), .z = at.z };
            indices[count] = section;
            count += 1;
        }
        // A batch may ask for no more than the share the simulation is sure to get.
        var begin: usize = 0;
        while (begin < count) {
            var end = begin + @min(count - begin, @max(1, terrain.demandCapacity()));
            // Named now. The release runs after the cursor has moved on.
            var held = leases[begin..end];
            if (!terrain.acquireCached(positions[begin..end], held)) {
                // Some are not in memory. One at a time tells which.
                end = begin + 1;
                held = leases[begin..end];
                if (!terrain.acquireCached(positions[begin..end], held)) {
                    absent |= @as(u32, 1) << @intCast(indices[begin]);
                    begin = end;
                    continue;
                }
            }
            defer terrain.releaseMany(held);
            for (held, positions[begin..end], indices[begin..end]) |lease, position, section| {
                const view = lease.view();
                var edited = false;
                for (pending) |edit| {
                    edited = edited or std.meta.eql(edit.section, position);
                }
                if (view == .uniform and !edited) {
                    states[section] = .{ .uniform = view.uniform };
                    continue;
                }
                if (decoded.* == self.states.len) continue;
                const buffer = &self.states[decoded.*];
                if (view == .uniform) @memset(buffer, view.uniform) else for (0..128) |group| {
                    view.pair(@intCast(group), buffer[group * 32 ..][0..16], buffer[group * 32 + 16 ..][0..16]);
                }
                if (edited) {
                    // Oldest last, so a cell edited twice reads as it was before the first edit.
                    var index = pending.len;
                    while (index != 0) {
                        index -= 1;
                        if (std.meta.eql(pending[index].section, position)) buffer[pending[index].index] = pending[index].previous;
                    }
                }
                states[section] = .{ .dense = buffer };
                decoded.* += 1;
            }
            begin = end;
        }
        return absent;
    }

    /// Makes room for the next tick, one step at a time. Call until it reports idle and
    /// do what each step asks. Columns a player stands by go last.
    pub fn maintain(self: *LightStore, output: *Copy) Maintenance {
        while (self.free_count < self.reserve_sections) {
            const column = self.evictable() orelse break;
            self.stats.evictions += 1;
            if (!column.dirty) {
                self.release(column);
                continue;
            }
            if (column.record == .current) {
                self.overflow(column);
                continue;
            }
            var sections: Sections = .{};
            self.borrow(column, &sections);
            output.take(column.key, column.shape, &sections);
            self.overflow(column);
            column.record = .current;
            return .overflow;
        }
        while (self.vacant_count < self.reserve_columns) {
            // Until its edits are saved, the frame of a tainted column must stay untrusted.
            // A loading column is waited for and stays as well.
            const saved = self.tainted.oldest != none and self.flush_mark > self.columns[self.tainted.oldest].mark and self.columns[self.tainted.oldest].state != .loading;
            const index = if (saved) self.tainted.oldest else self.oldestLoose() orelse self.oldestClean() orelse break;
            if (index == none) break;
            const column = &self.columns[index];
            self.stats.forgotten += 1;
            const recorded = column.record != .none;
            const key = column.key;
            self.release(column);
            if (recorded) return .{ .forgotten = key };
        }
        return .idle;
    }

    /// The least recently used column in memory whose light a frame can give back, and
    /// that no unsettled edit or player needs. Columns lit one level throughout hold no pool
    /// section and are never evicted for room, so only this lets them go.
    fn oldestClean(self: *const LightStore) ?u32 {
        var index = self.resident.oldest;
        var looked: usize = 0;
        while (index != none and looked < 64) : (looked += 1) {
            const column = &self.columns[index];
            // Patched light whose edits are saved may go too. A frame baked from here on
            // holds those edits, and an older one no longer matches the saved blocks.
            const replaceable = !column.dirty or (column.tainted and self.flush_mark > column.mark);
            if (replaceable and column.pinned != self.tick and column.protected != self.pass) return index;
            index = column.newer;
        }
        return null;
    }

    /// The least recently used column that may be forgotten at any time. Loading ones are
    /// passed over, as far as a short look goes.
    fn oldestLoose(self: *const LightStore) ?u32 {
        var index = self.loose.oldest;
        var looked: usize = 0;
        while (index != none and looked < 64) : (looked += 1) {
            if (self.columns[index].state != .loading) return index;
            index = self.columns[index].newer;
        }
        return null;
    }

    /// The least recently used column that holds sections, passing over the protected
    /// ones while any other is left. A column an unsettled edit waits on never goes:
    /// the edit would have to be dropped and solved again.
    fn evictable(self: *LightStore) ?*Column {
        var protected: ?*Column = null;
        var index = self.resident.oldest;
        while (index != none) {
            const column = &self.columns[index];
            index = column.newer;
            if (column.held() == 0 or column.pinned == self.tick) continue;
            if (column.protected != self.pass) return column;
            protected = protected orelse column;
        }
        return protected;
    }

    fn neighbour(key: Key, index: usize) ?Key {
        const x = std.math.add(i32, key.x, @as(i32, @intCast(index % 3)) - 1) catch return null;
        const z = std.math.add(i32, key.z, @as(i32, @intCast(index / 3)) - 1) catch return null;
        return .{ .world = key.world, .x = x, .z = z };
    }

    fn find(self: *LightStore, key: Key) ?*Column {
        const index = self.map.get(key) orelse return null;
        const column = &self.columns[index];
        assert(column.state != .vacant and std.meta.eql(column.key, key));
        return column;
    }

    fn indexOf(self: *const LightStore, column: *const Column) u32 {
        return @intCast((@intFromPtr(column) - @intFromPtr(self.columns.ptr)) / @sizeOf(Column));
    }

    fn link(self: *LightStore, list: *List, column: *Column) void {
        const index = self.indexOf(column);
        column.newer = none;
        column.older = list.newest;
        if (list.newest != none) self.columns[list.newest].newer = index else list.oldest = index;
        list.newest = index;
    }

    fn unlink(self: *LightStore, list: *List, column: *Column) void {
        if (column.newer != none) self.columns[column.newer].older = column.older else list.newest = column.older;
        if (column.older != none) self.columns[column.older].newer = column.newer else list.oldest = column.newer;
        column.newer = none;
        column.older = none;
    }

    /// The list a column belongs in as it is now.
    fn listOf(self: *LightStore, column: *const Column) *List {
        assert(column.state != .vacant);
        if (column.state == .resident) return &self.resident;
        return if (column.tainted) &self.tainted else &self.loose;
    }

    /// Call after a change of state or taint, and `detach` before it.
    fn attach(self: *LightStore, column: *Column) void {
        self.link(self.listOf(column), column);
    }

    fn detach(self: *LightStore, column: *Column) void {
        self.unlink(self.listOf(column), column);
    }

    /// Notes a use. Tainted columns keep the order they arrived in.
    fn touch(self: *LightStore, column: *Column) void {
        const list = self.listOf(column);
        if (list == &self.tainted or list.newest == self.indexOf(column)) return;
        self.unlink(list, column);
        self.link(list, column);
    }

    fn freeSections(self: *LightStore, column: *Column) void {
        for (0..2) |layer| {
            var bits = column.dense[layer];
            while (bits != 0) : (bits &= bits - 1) {
                self.free[self.free_count] = column.slots[layer][@ctz(bits)];
                self.free_count += 1;
            }
        }
        column.dense = .{ 0, 0 };
    }

    fn release(self: *LightStore, column: *Column) void {
        switch (column.state) {
            .vacant => unreachable,
            .resident => {
                self.detach(column);
                self.freeSections(column);
                self.stats.resident -= 1;
            },
            .overflowed => {
                self.detach(column);
                self.stats.overflowed -= 1;
            },
            .unlit => {
                self.detach(column);
                self.stats.unlit -= 1;
            },
            .loading => {
                self.detach(column);
                self.stats.loading -= 1;
            },
        }
        assert(self.map.remove(column.key));
        const index = self.indexOf(column);
        column.* = .{};
        self.vacant[self.vacant_count] = index;
        self.vacant_count += 1;
    }

    /// The column in one slot of the table when its light is in memory. For tests that
    /// walk everything the store holds.
    pub fn residentAt(self: *const LightStore, slot: usize) ?Key {
        const column = &self.columns[slot];
        return if (column.state == .resident) column.key else null;
    }

    /// Checks the bookkeeping of the whole store. For tests.
    pub fn check(self: *const LightStore) void {
        var held: usize = 0;
        var counts: [5]usize = @splat(0);
        for (self.columns) |*column| {
            counts[@backingInt(column.state)] += 1;
            if (column.state == .resident) held += column.held() else assert(column.dense[0] | column.dense[1] == 0);
        }
        assert(held + self.free_count == self.bytes.len);
        assert(counts[0] == self.vacant_count and counts[1] == self.stats.resident and counts[2] == self.stats.overflowed and counts[3] == self.stats.unlit and counts[4] == self.stats.loading);
        assert(self.map.count() == self.columns.len - self.vacant_count);
        var listed: usize = 0;
        for ([_]*const List{ &self.resident, &self.tainted, &self.loose }, 0..) |list, kind| {
            var index = list.newest;
            var newer: u32 = none;
            while (index != none) : (listed += 1) {
                const column = &self.columns[index];
                const belongs: usize = if (column.state == .resident) 0 else if (column.tainted) 1 else 2;
                assert(column.state != .vacant and belongs == kind and column.newer == newer);
                newer = index;
                index = column.older;
            }
            assert(list.oldest == newer);
        }
        assert(listed == self.map.count());
    }
};

fn nibble(bytes: *const [section_bytes]u8, cell: u32) u4 {
    return @truncate(bytes[cell / 2] >> @as(u3, @intCast(cell % 2 * 4)));
}

/// The one level a section holds, or null when its cells differ.
pub fn uniformLevel(bytes: *const [section_bytes]u8) ?u4 {
    const first = bytes[0];
    if (first >> 4 != first & 15) return null;
    return if (std.mem.allEqual(u8, bytes, first)) @truncate(first) else null;
}
