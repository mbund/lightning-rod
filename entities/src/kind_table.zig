//! One kind's entities, a row each: the columns of a row side by side in blocks of the entities'
//! pool, each block one page holding a power of two of rows, every field a column of its own.
//!
//! Two parts. The ticking part holds the entities in the tick order, in its sequence: its blocks
//! are kept in that order and so are the rows in each, so going down the order goes down the
//! columns. The dormant part holds entities that sleep long or whose column stopped ticking, in no
//! order; nothing walks it.
//!
//! Where an entity stands in the order is its directory entry's: its sequence, and whether it is
//! awake. The table follows. Nothing moves while a tick runs: an entity joining the order is
//! appended last, one leaving is marked dead, one going dormant or coming back is noted.
//! `maintain`, once at the end of the tick, applies all of it: each block with something to change
//! is written out once, those coming back merged in at their sequences, and the directory told
//! where every moved row went. A record's address holds until then.
//!
//! `Core` is the table without its row type, which the tick order walks; `Table(Row)` gives typed
//! columns over it.

const std = @import("std");
const pool_module = @import("pool.zig");
const directory_module = @import("directory.zig");

const assert = std.debug.assert;
const Pool = pool_module.Pool;
const Array = pool_module.Array;
const Directory = directory_module.Directory;
const Id = directory_module.Id;
const page_bytes = pool_module.page_bytes;
const none = directory_module.none;

pub const Page = *align(page_bytes) [page_bytes]u8;

/// Where a block's columns lie in its page.
pub const Layout = struct {
    rows: u32,
    words: u32,
    alive: usize,
    awake: usize,
    moving: usize,
    slot: usize,
    sequence: usize,
    columns: []const ColumnAt,

    pub const ColumnAt = struct { offset: usize, size: usize };

    /// The layout for rows of `Row`: the most rows, a power of two, whose columns fit a page.
    pub fn of(comptime Row: type) Layout {
        @setEvalBranchQuota(100_000);
        var count: u32 = 4096;
        while (count > 1 and bytesFor(Row, count) > page_bytes) count /= 2;
        if (bytesFor(Row, count) > page_bytes) @compileError("a row of " ++ @typeName(Row) ++ " does not fit a page");
        const words: u32 = (count + 63) / 64;
        const alive = 8;
        const awake = alive + words * 8;
        const moving = awake + words * 8;
        const slot = moving + words * 8;
        const sequence = std.mem.alignForward(usize, slot + count * 4, 8);
        const fields = @typeInfo(Row).@"struct".field_types;
        var columns: [fields.len]ColumnAt = undefined;
        var at: usize = sequence + count * 8;
        for (fields, 0..) |T, index| {
            at = std.mem.alignForward(usize, at, @alignOf(T));
            columns[index] = .{ .offset = at, .size = @sizeOf(T) };
            at += count * @sizeOf(T);
        }
        const final = columns;
        return .{ .rows = count, .words = words, .alive = alive, .awake = awake, .moving = moving, .slot = slot, .sequence = sequence, .columns = &final };
    }

    fn bytesFor(comptime Row: type, count: usize) usize {
        const words = (count + 63) / 64;
        var at = 8 + 3 * words * 8;
        at += count * 4;
        at = std.mem.alignForward(usize, at, 8) + count * 8;
        for (@typeInfo(Row).@"struct".field_types) |T| at = std.mem.alignForward(usize, at, @alignOf(T)) + count * @sizeOf(T);
        return at;
    }
};

/// An entity coming back to the ticking part at the next `maintain`, at its sequence; the id
/// tells it from a later entity in the slot.
pub const Wake = struct { sequence: u64, id: Id, slot: u32 };

/// Where a row lies.
pub const Spot = struct { block: Page, row: u32 };

pub const Core = struct {
    pool: *Pool,
    directory: *Directory,
    layout: *const Layout,
    /// The ticking part's blocks in sequence order, and the sequence of each one's first row.
    ticking: Array(u32),
    firsts: Array(u64),
    /// The dormant part's blocks, every one full but the last.
    dormant: Array(u32),
    /// Those coming back from the dormant part at the next `maintain`.
    waking: Array(Wake),
    waking_count: usize = 0,
    /// Whether anything waits for `maintain`.
    changed: bool = false,
    /// Rows standing in the ticking part and in the dormant part.
    ticking_rows: usize = 0,
    dormant_rows: usize = 0,
    /// Where the tick order's pass is in this table.
    cursor: Cursor = .{},

    /// The pass's place in the ticking part, and the next awake row there, if found yet; and how
    /// far it is through those coming back, of which those from `waking_sorted` on are not yet
    /// in sequence order.
    pub const Cursor = struct {
        block_at: usize = 0,
        row: u32 = 0,
        head: ?Head = null,
        waking_at: usize = 0,
        waking_sorted: usize = 0,
    };

    pub const Head = struct { sequence: u64, slot: u32, id: Id };

    pub fn init(allocator: std.mem.Allocator, pool: *Pool, directory: *Directory, layout: *const Layout) !Core {
        return .{
            .pool = pool,
            .directory = directory,
            .layout = layout,
            .ticking = try .init(allocator, pool),
            .firsts = try .init(allocator, pool),
            .dormant = try .init(allocator, pool),
            .waking = try .init(allocator, pool),
        };
    }

    pub fn page(self: *const Core, number: u32) Page {
        return self.pool.bytes(number);
    }

    pub fn counter(block: Page) *u32 {
        return @ptrCast(@alignCast(block[0..4]));
    }

    pub fn slots(self: *const Core, block: Page) [*]u32 {
        return @ptrCast(@alignCast(block[self.layout.slot..]));
    }

    pub fn sequences(self: *const Core, block: Page) [*]u64 {
        return @ptrCast(@alignCast(block[self.layout.sequence..]));
    }

    pub fn word(_: *const Core, block: Page, offset: usize, at: usize) *u64 {
        const words: [*]u64 = @ptrCast(@alignCast(block[offset..]));
        return &words[at];
    }

    pub fn bit(self: *const Core, block: Page, offset: usize, row: u32) bool {
        return self.word(block, offset, row / 64).* & (@as(u64, 1) << @intCast(row % 64)) != 0;
    }

    pub fn setBit(self: *const Core, block: Page, offset: usize, row: u32, value: bool) void {
        const mask = @as(u64, 1) << @intCast(row % 64);
        const at = self.word(block, offset, row / 64);
        if (value) at.* |= mask else at.* &= ~mask;
    }

    /// The awake rows standing in a word of a block.
    pub fn awakeWord(self: *const Core, block: Page, at: usize) u64 {
        return self.word(block, self.layout.awake, at).* & self.word(block, self.layout.alive, at).*;
    }

    fn fresh(self: *Core) !u32 {
        const number = self.pool.take() catch return error.EntityMemoryExhausted;
        const block = self.page(number);
        counter(block).* = 0;
        for (0..self.layout.words) |at| {
            self.word(block, self.layout.alive, at).* = 0;
            self.word(block, self.layout.awake, at).* = 0;
            self.word(block, self.layout.moving, at).* = 0;
        }
        return number;
    }

    /// Where an entity's row lies, good until the next `maintain`.
    pub fn spot(self: *const Core, slot: u32) Spot {
        const entry = self.directory.entry(slot);
        assert(entry.block != none);
        return .{ .block = self.page(entry.block), .row = entry.row };
    }

    fn copyRow(self: *const Core, from: Page, from_row: u32, to: Page, to_row: u32) void {
        for (self.layout.columns) |column| {
            const source = from[column.offset + from_row * column.size ..][0..column.size];
            @memcpy(to[column.offset + to_row * column.size ..][0..column.size], source);
        }
    }

    /// A row for an entity coming into memory, where its directory entry says it stands: last
    /// in the ticking part if it is in the order and `dormant` is not asked for, else in the
    /// dormant part. Its columns are the caller's to fill.
    pub fn addRow(self: *Core, slot: u32, dormant: bool) !Spot {
        const entry = self.directory.entry(slot);
        assert(entry.block == none);
        if (dormant or entry.sequence == 0) {
            // Awake in the order, it comes back at its place at `maintain`.
            const back = entry.sequence != 0 and entry.awake;
            const at = try self.appendDormant(slot, entry.sequence, back);
            if (back) try self.pushWaking(slot, entry.id, entry.sequence);
            return at;
        }
        var number: u32 = if (self.ticking.len > 0) self.ticking.at(self.ticking.len - 1).* else none;
        if (number != none) {
            const block = self.page(number);
            const count = counter(block).*;
            // Joined before rows added since: it comes back at its place at `maintain`.
            if (count > 0 and self.sequences(block)[count - 1] > entry.sequence) {
                const at = try self.appendDormant(slot, entry.sequence, true);
                try self.pushWaking(slot, entry.id, entry.sequence);
                return at;
            }
            if (count == self.layout.rows) number = none;
        }
        if (number == none) {
            number = try self.fresh();
            errdefer self.pool.give(number);
            try self.ticking.ensure(self.ticking.len + 1);
            try self.firsts.ensure(self.firsts.len + 1);
            self.ticking.at(self.ticking.len - 1).* = number;
            self.firsts.at(self.firsts.len - 1).* = entry.sequence;
        }
        self.ticking_rows += 1;
        return self.place(number, slot, entry.sequence, entry.awake, false);
    }

    fn appendDormant(self: *Core, slot: u32, sequence: u64, moving: bool) !Spot {
        var number: u32 = if (self.dormant.len > 0) self.dormant.at(self.dormant.len - 1).* else none;
        if (number != none and counter(self.page(number)).* == self.layout.rows) number = none;
        if (number == none) {
            number = try self.fresh();
            errdefer self.pool.give(number);
            _ = try self.dormant.append(number);
        }
        self.dormant_rows += 1;
        const at = self.place(number, slot, sequence, false, true);
        self.setBit(at.block, self.layout.moving, at.row, moving);
        return at;
    }

    fn place(self: *Core, number: u32, slot: u32, sequence: u64, awake: bool, dormant: bool) Spot {
        const block = self.page(number);
        const row = counter(block).*;
        counter(block).* = row + 1;
        self.slots(block)[row] = slot;
        self.sequences(block)[row] = sequence;
        self.setBit(block, self.layout.alive, row, true);
        self.setBit(block, self.layout.awake, row, awake);
        self.setBit(block, self.layout.moving, row, false);
        const entry = self.directory.entry(slot);
        entry.block = number;
        entry.row = @intCast(row);
        entry.dormant = dormant;
        return .{ .block = block, .row = row };
    }

    fn pushWaking(self: *Core, slot: u32, id: Id, sequence: u64) !void {
        try self.waking.ensure(self.waking_count + 1);
        self.waking.at(self.waking_count).* = .{ .sequence = sequence, .id = id, .slot = slot };
        self.waking_count += 1;
        self.changed = true;
    }

    /// The entity leaves: its row stays until `maintain`, passed over.
    pub fn remove(self: *Core, slot: u32) void {
        const entry = self.directory.entry(slot);
        assert(entry.block != none);
        const block = self.page(entry.block);
        self.setBit(block, self.layout.alive, entry.row, false);
        self.setBit(block, self.layout.awake, entry.row, false);
        self.setBit(block, self.layout.moving, entry.row, false);
        if (entry.dormant) self.dormant_rows -= 1 else self.ticking_rows -= 1;
        entry.block = none;
        self.changed = true;
    }

    /// The order says whether the entity is walked; for one in the ticking part, its bit.
    pub fn showAwake(self: *Core, slot: u32) void {
        const entry = self.directory.entry(slot);
        if (entry.block == none or entry.dormant) return;
        self.setBit(self.page(entry.block), self.layout.awake, entry.row, entry.awake);
    }

    /// The entity sleeps long or left the order: its row goes to the dormant part at the next
    /// `maintain`. One coming back this tick simply stays.
    pub fn goDormant(self: *Core, slot: u32) void {
        const entry = self.directory.entry(slot);
        if (entry.block == none) return;
        const block = self.page(entry.block);
        if (entry.dormant) {
            self.setBit(block, self.layout.moving, entry.row, false);
            return;
        }
        self.setBit(block, self.layout.awake, entry.row, entry.awake);
        self.setBit(block, self.layout.moving, entry.row, true);
        self.changed = true;
    }

    /// The entity is in the order again, at its entry's sequence: a ticking row stays where it is
    /// (or, joined again under a later sequence, moves at `maintain`), a dormant one comes back at
    /// the next `maintain`. True if it is among those coming back.
    pub fn comeBack(self: *Core, slot: u32) !bool {
        const entry = self.directory.entry(slot);
        if (entry.block == none) return false;
        const block = self.page(entry.block);
        if (!entry.dormant) {
            const again = self.sequences(block)[entry.row] != entry.sequence;
            self.setBit(block, self.layout.moving, entry.row, again);
            if (again) self.changed = true;
            self.setBit(block, self.layout.awake, entry.row, entry.awake);
            return false;
        }
        if (self.bit(block, self.layout.moving, entry.row) and self.sequences(block)[entry.row] == entry.sequence) return true;
        self.sequences(block)[entry.row] = entry.sequence;
        self.setBit(block, self.layout.moving, entry.row, true);
        try self.pushWaking(slot, entry.id, entry.sequence);
        return true;
    }

    /// Whether an entity is in the dormant part.
    pub fn isDormant(self: *const Core, slot: u32) bool {
        return self.directory.entry(slot).dormant;
    }

    /// Once a tick, when nothing holds a row: the dead go, those going dormant move there, and
    /// those coming back come among the ticking at their sequences. Each block with something to
    /// change is written out once; the rest are not touched.
    pub fn maintain(self: *Core) !void {
        self.cursor = .{};
        if (!self.changed) return;
        self.changed = false;
        // Those going dormant: copied to the dormant part, their ticking rows dead. Those joined
        // again under a later sequence come back at it.
        for (0..self.ticking.len) |at| {
            const block = self.page(self.ticking.at(at).*);
            const count = counter(block).*;
            for (0..self.layout.words) |w| {
                var moving = self.word(block, self.layout.moving, w).* & self.word(block, self.layout.alive, w).*;
                while (moving != 0) : (moving &= moving - 1) {
                    const row: u32 = @intCast(w * 64 + @ctz(moving));
                    if (row >= count) break;
                    const slot = self.slots(block)[row];
                    const entry = self.directory.entry(slot);
                    const again = entry.sequence != 0 and entry.sequence != self.sequences(block)[row];
                    const to = try self.appendDormant(slot, if (again) entry.sequence else self.sequences(block)[row], again);
                    self.copyRow(block, row, to.block, to.row);
                    if (again) try self.pushWaking(slot, entry.id, entry.sequence);
                    self.setBit(block, self.layout.alive, row, false);
                    self.setBit(block, self.layout.moving, row, false);
                    self.ticking_rows -= 1;
                }
            }
        }
        self.changed = false;
        // Those coming back still standing and still coming, once each, by sequence.
        var inserts: usize = 0;
        for (0..self.waking_count) |at| {
            const wake = self.waking.at(at).*;
            const entry = self.directory.entry(wake.slot);
            if (entry.id != wake.id or entry.block == none or !entry.dormant) continue;
            const block = self.page(entry.block);
            if (!self.bit(block, self.layout.moving, entry.row) or self.sequences(block)[entry.row] != wake.sequence) continue;
            self.setBit(block, self.layout.moving, entry.row, false);
            self.waking.at(inserts).* = wake;
            inserts += 1;
        }
        self.waking_count = inserts;
        self.sortWakingFrom(0);
        self.waking_count = 0;
        try self.rebuild(.{ .values = &self.waking, .start = 0, .end = inserts });
        self.compactDormant();
    }

    pub fn wakeBefore(_: void, a: Wake, b: Wake) bool {
        return a.sequence < b.sequence;
    }

    /// Some of those coming back, by sequence, where they lie in the pool.
    const Inserts = struct {
        values: *const Array(Wake),
        start: usize,
        end: usize,

        fn len(self: Inserts) usize {
            return self.end - self.start;
        }

        fn at(self: Inserts, index: usize) Wake {
            return self.values.at(self.start + index).*;
        }

        fn part(self: Inserts, from: usize, to: usize) Inserts {
            return .{ .values = self.values, .start = self.start + from, .end = self.start + to };
        }
    };

    /// The ticking part again: each block with dead rows or some coming back into its range
    /// written once to fresh blocks in its place, those with nothing to change left alone.
    fn rebuild(self: *Core, inserts: Inserts) !void {
        var at: usize = 0;
        var next_insert: usize = 0;
        while (at < self.ticking.len) {
            const block = self.page(self.ticking.at(at).*);
            // Those whose place is in this block: before the next block's first row.
            const ending = self.insertsBefore(inserts, next_insert, at + 1);
            const mine = inserts.part(next_insert, ending);
            next_insert = ending;
            if (!self.hasDead(block) and mine.len() == 0) {
                at += 1;
                continue;
            }
            at = try self.rewrite(at, mine);
            // A thin block written takes in the next if both fit in one and none of those coming
            // back belong between the next's rows.
            if (at < self.ticking.len) {
                const thin = self.page(self.ticking.at(at - 1).*);
                const next = self.page(self.ticking.at(at).*);
                const theirs = self.insertsBefore(inserts, next_insert, at + 1) - next_insert;
                if (theirs == 0 and counter(thin).* < self.layout.rows / 2 and counter(thin).* + self.standing(next) <= self.layout.rows) {
                    self.mergeInto(self.ticking.at(at - 1).*, next);
                    at += 1;
                }
            }
        }
        // Those coming back with no block at all.
        for (next_insert..inserts.len()) |index| try self.moveIn(inserts.at(index).slot);
        // Blocks left empty go back, and every block's first sequence is set again.
        var kept: usize = 0;
        for (0..self.ticking.len) |index| {
            const number = self.ticking.at(index).*;
            if (counter(self.page(number)).* == 0) {
                self.pool.give(number);
                continue;
            }
            self.ticking.at(kept).* = number;
            self.firsts.at(kept).* = self.sequences(self.page(number))[0];
            kept += 1;
        }
        while (self.ticking.len > kept) {
            self.ticking.pop();
            self.firsts.pop();
        }
    }

    /// Where those coming back from `from` on stop belonging before block `at`: those placed
    /// before its first row, all of them past the last block.
    fn insertsBefore(self: *const Core, inserts: Inserts, from: usize, at: usize) usize {
        const end: u64 = if (at < self.ticking.len) self.firsts.at(at).* else std.math.maxInt(u64);
        var ending = from;
        while (ending < inserts.len() and inserts.at(ending).sequence < end) ending += 1;
        return ending;
    }

    fn hasDead(self: *const Core, block: Page) bool {
        const count = counter(block).*;
        for (0..self.layout.words) |w| {
            const used: u64 = if ((w + 1) * 64 <= count) std.math.maxInt(u64) else if (w * 64 >= count) 0 else (@as(u64, 1) << @intCast(count - w * 64)) - 1;
            if (self.word(block, self.layout.alive, w).* & used != used) return true;
        }
        return false;
    }

    fn standing(self: *const Core, block: Page) u32 {
        var total: u32 = 0;
        for (0..self.layout.words) |w| total += @popCount(self.word(block, self.layout.alive, w).*);
        return total;
    }

    /// A block's standing rows appended to another, which is left after it; the block emptied.
    fn mergeInto(self: *Core, target: u32, from: Page) void {
        for (0..counter(from).*) |r| {
            const row: u32 = @intCast(r);
            if (!self.bit(from, self.layout.alive, row)) continue;
            const to = self.place(target, self.slots(from)[row], self.sequences(from)[row], self.bit(from, self.layout.awake, row), false);
            self.copyRow(from, row, to.block, to.row);
        }
        counter(from).* = 0;
        for (0..self.layout.words) |w| self.word(from, self.layout.alive, w).* = 0;
    }

    /// One block's standing rows merged with those coming back placed in it, by sequence,
    /// written to fresh blocks taking its place; the block given back. The position after the
    /// last written.
    fn rewrite(self: *Core, at: usize, inserts: Inserts) !usize {
        const old_number = self.ticking.at(at).*;
        const old = self.page(old_number);
        const count = counter(old).*;
        var position = at;
        var target: u32 = try self.fresh();
        self.ticking.at(position).* = target;
        var row: u32 = 0;
        var from_insert: usize = 0;
        while (true) {
            // Dead rows are passed over.
            while (row < count and !self.bit(old, self.layout.alive, row)) row += 1;
            const have_row = row < count;
            const have_insert = from_insert < inserts.len();
            if (!have_row and !have_insert) break;
            if (counter(self.page(target)).* == self.layout.rows) {
                target = try self.fresh();
                position += 1;
                try self.insertBlock(position, target);
            }
            if (have_insert and (!have_row or inserts.at(from_insert).sequence < self.sequences(old)[row])) {
                const wake = inserts.at(from_insert);
                from_insert += 1;
                self.takeIn(target, wake.slot);
            } else {
                const to = self.place(target, self.slots(old)[row], self.sequences(old)[row], self.bit(old, self.layout.awake, row), false);
                self.copyRow(old, row, to.block, to.row);
                row += 1;
            }
        }
        self.pool.give(old_number);
        return position + 1;
    }

    /// A dormant row coming back, written into a ticking block.
    fn takeIn(self: *Core, target: u32, slot: u32) void {
        const entry = self.directory.entry(slot);
        const source = self.page(entry.block);
        const source_row: u32 = entry.row;
        const sequence = self.sequences(source)[source_row];
        self.setBit(source, self.layout.alive, source_row, false);
        self.setBit(source, self.layout.moving, source_row, false);
        self.dormant_rows -= 1;
        const to = self.place(target, slot, sequence, entry.awake, false);
        self.copyRow(source, source_row, to.block, to.row);
        self.ticking_rows += 1;
    }

    /// A block put in the ticking part at a position, those from it on moved along.
    fn insertBlock(self: *Core, position: usize, number: u32) !void {
        try self.ticking.ensure(self.ticking.len + 1);
        try self.firsts.ensure(self.firsts.len + 1);
        var index = self.ticking.len - 1;
        while (index > position) : (index -= 1) {
            self.ticking.at(index).* = self.ticking.at(index - 1).*;
            self.firsts.at(index).* = self.firsts.at(index - 1).*;
        }
        self.ticking.at(position).* = number;
    }

    /// One coming back whose place is after every ticking row.
    fn moveIn(self: *Core, slot: u32) !void {
        var number: u32 = if (self.ticking.len > 0) self.ticking.at(self.ticking.len - 1).* else none;
        if (number != none and counter(self.page(number)).* == self.layout.rows) number = none;
        if (number == none) {
            number = try self.fresh();
            errdefer self.pool.give(number);
            try self.ticking.ensure(self.ticking.len + 1);
            try self.firsts.ensure(self.firsts.len + 1);
            self.ticking.at(self.ticking.len - 1).* = number;
        }
        self.takeIn(number, slot);
    }

    /// The dormant part without its dead: each hole, from the front, filled with the last row
    /// standing; blocks left empty at the end given back.
    fn compactDormant(self: *Core) void {
        var at: usize = 0;
        while (at < self.dormant.len) : (at += 1) {
            const block = self.page(self.dormant.at(at).*);
            var row: u32 = 0;
            while (row < counter(block).*) : (row += 1) {
                if (self.bit(block, self.layout.alive, row)) continue;
                if (!self.fillFromLast(at, row)) {
                    // Nothing stands after the hole.
                    counter(block).* = row;
                    break;
                }
            }
        }
        while (self.dormant.len > 0 and counter(self.page(self.dormant.at(self.dormant.len - 1).*)).* == 0) {
            self.pool.give(self.dormant.at(self.dormant.len - 1).*);
            self.dormant.pop();
        }
    }

    /// The last dormant row standing moved into a hole; false if none stands after the hole.
    fn fillFromLast(self: *Core, hole_at: usize, hole: u32) bool {
        const hole_number = self.dormant.at(hole_at).*;
        const hole_block = self.page(hole_number);
        while (self.dormant.len > hole_at) {
            const last_at = self.dormant.len - 1;
            const last = self.page(self.dormant.at(last_at).*);
            while (counter(last).* > 0) {
                const row = counter(last).* - 1;
                if (last_at == hole_at and row <= hole) return false;
                counter(last).* = row;
                if (!self.bit(last, self.layout.alive, row)) continue;
                const slot = self.slots(last)[row];
                self.slots(hole_block)[hole] = slot;
                self.sequences(hole_block)[hole] = self.sequences(last)[row];
                self.setBit(hole_block, self.layout.alive, hole, true);
                self.setBit(hole_block, self.layout.awake, hole, false);
                self.setBit(hole_block, self.layout.moving, hole, self.bit(last, self.layout.moving, row));
                self.copyRow(last, row, hole_block, hole);
                self.setBit(last, self.layout.alive, row, false);
                self.setBit(last, self.layout.moving, row, false);
                const entry = self.directory.entry(slot);
                entry.block = hole_number;
                entry.row = @intCast(hole);
                return true;
            }
            if (last_at == hole_at) return false;
            self.pool.give(self.dormant.at(last_at).*);
            self.dormant.pop();
        }
        return false;
    }

    fn sortWakingFrom(self: *Core, from: usize) void {
        if (self.waking.run(from, self.waking_count)) |pending| return std.sort.pdq(Wake, pending, {}, wakeBefore);
        const Sort = struct {
            values: *Array(Wake),
            pub fn lessThan(sort: @This(), a: usize, b: usize) bool {
                return sort.values.at(a).sequence < sort.values.at(b).sequence;
            }
            pub fn swap(sort: @This(), a: usize, b: usize) void {
                std.mem.swap(Wake, sort.values.at(a), sort.values.at(b));
            }
        };
        std.sort.pdqContext(from, self.waking_count, Sort{ .values = &self.waking });
    }

    /// The pass begins at the first row and the first of those coming back.
    pub fn beginPass(self: *Core) void {
        self.cursor = .{};
    }

    /// The next awake row standing in the ticking part at or after the cursor.
    pub fn head(self: *Core) ?Head {
        if (self.cursor.head) |found| return found;
        while (self.cursor.block_at < self.ticking.len) {
            const block = self.page(self.ticking.at(self.cursor.block_at).*);
            const count = counter(block).*;
            while (self.cursor.row < count) {
                const w = self.cursor.row / 64;
                const shift: u6 = @intCast(self.cursor.row % 64);
                const bits = self.awakeWord(block, w) >> shift;
                if (bits == 0) {
                    self.cursor.row = (w + 1) * 64;
                    continue;
                }
                const row = self.cursor.row + @ctz(bits);
                if (row >= count) break;
                self.cursor.row = row;
                const slot = self.slots(block)[row];
                self.cursor.head = .{ .sequence = self.sequences(block)[row], .slot = slot, .id = self.directory.entry(slot).id };
                return self.cursor.head;
            }
            self.cursor.block_at += 1;
            self.cursor.row = 0;
        }
        return null;
    }

    /// The pass took the head: on to the row after it.
    pub fn takeHead(self: *Core) void {
        self.cursor.head = null;
        self.cursor.row += 1;
    }

    /// The next of those coming back, by sequence, not yet met by the pass.
    pub fn wakingHead(self: *Core) ?Wake {
        if (self.cursor.waking_sorted < self.waking_count) {
            self.sortWakingFrom(self.cursor.waking_at);
            self.cursor.waking_sorted = self.waking_count;
        }
        if (self.cursor.waking_at >= self.waking_count) return null;
        return self.waking.at(self.cursor.waking_at).*;
    }

    pub fn takeWakingHead(self: *Core) void {
        self.cursor.waking_at += 1;
    }

    /// An entity in the ticking part woke during the pass: if the cursor looked past it, it goes
    /// back to it.
    pub fn rewind(self: *Core, slot: u32) void {
        const entry = self.directory.entry(slot);
        if (entry.block == none or entry.dormant) return;
        const sequence = self.sequences(self.page(entry.block))[entry.row];
        if (self.cursor.head) |found| if (found.sequence <= sequence) return;
        // The block holding it: the last whose first row comes no later.
        var low: usize = 0;
        var high: usize = self.ticking.len;
        while (high - low > 1) {
            const middle = (low + high) / 2;
            if (self.firsts.at(middle).* <= sequence) low = middle else high = middle;
        }
        assert(self.ticking.at(low).* == entry.block);
        if (self.cursor.head == null and (low > self.cursor.block_at or (low == self.cursor.block_at and entry.row >= self.cursor.row))) return;
        self.cursor.block_at = low;
        self.cursor.row = entry.row;
        self.cursor.head = null;
    }

    /// Every standing entity's slot, ticking or dormant, into `output`.
    pub fn slotsInto(self: *const Core, output: []u32) []u32 {
        var found: usize = 0;
        for ([_]*const Array(u32){ &self.ticking, &self.dormant }) |list| {
            for (0..list.len) |at| {
                const block = self.page(list.at(at).*);
                for (0..counter(block).*) |r| {
                    const row: u32 = @intCast(r);
                    if (!self.bit(block, self.layout.alive, row)) continue;
                    output[found] = self.slots(block)[row];
                    found += 1;
                }
            }
        }
        return output[0..found];
    }

    /// Every standing entity's id, ticking or dormant, sorted, into `output`.
    pub fn idsInto(self: *const Core, output: []u64) []u64 {
        var found: usize = 0;
        for ([_]*const Array(u32){ &self.ticking, &self.dormant }) |list| {
            for (0..list.len) |at| {
                const block = self.page(list.at(at).*);
                for (0..counter(block).*) |r| {
                    const row: u32 = @intCast(r);
                    if (!self.bit(block, self.layout.alive, row)) continue;
                    output[found] = self.directory.entry(self.slots(block)[row]).id;
                    found += 1;
                }
            }
        }
        std.sort.pdq(u64, output[0..found], {}, std.sort.asc(u64));
        return output[0..found];
    }

    /// Everything goes: the rows' entries told so, and the entries left for the caller to let go.
    pub fn clear(self: *Core) void {
        for ([_]*Array(u32){ &self.ticking, &self.dormant }) |list| {
            for (0..list.len) |at| {
                const block = self.page(list.at(at).*);
                for (0..counter(block).*) |r| {
                    const row: u32 = @intCast(r);
                    if (self.bit(block, self.layout.alive, row)) self.directory.entry(self.slots(block)[row]).block = none;
                }
                self.pool.give(list.at(at).*);
            }
            list.clear();
        }
        self.firsts.clear();
        self.waking_count = 0;
        self.changed = false;
        self.ticking_rows = 0;
        self.dormant_rows = 0;
        self.cursor = .{};
    }

    pub fn standingCount(self: *const Core) usize {
        return self.ticking_rows + self.dormant_rows;
    }
};

/// A kind's table with typed columns.
pub fn Table(comptime Row: type) type {
    return struct {
        const Self = @This();
        const names = @typeInfo(Row).@"struct".field_names;
        const types = @typeInfo(Row).@"struct".field_types;
        pub const layout: Layout = Layout.of(Row);
        pub const rows = layout.rows;
        pub const word_count = layout.words;

        core: Core,

        pub fn init(allocator: std.mem.Allocator, pool: *Pool, directory: *Directory) !Self {
            return .{ .core = try .init(allocator, pool, directory, &layout) };
        }

        /// Where one entity's row lies, good until the next `maintain`.
        pub const Ref = struct {
            block: Page,
            row: u32,

            pub fn field(self: Ref, comptime name: []const u8) *@FieldType(Row, name) {
                return &columnOf(self.block, name)[self.row];
            }

            pub fn get(self: Ref) Row {
                var value: Row = undefined;
                inline for (names, 0..) |name, index| @field(value, name) = column(self.block, index)[self.row];
                return value;
            }

            pub fn set(self: Ref, value: Row) void {
                inline for (names, 0..) |name, index| column(self.block, index)[self.row] = @field(value, name);
            }
        };

        pub fn column(block: Page, comptime index: usize) *[rows]types[index] {
            return @ptrCast(@alignCast(block[layout.columns[index].offset..][0 .. rows * @sizeOf(types[index])]));
        }

        pub fn columnOf(block: Page, comptime name: []const u8) *[rows]@FieldType(Row, name) {
            return column(block, comptime std.meta.fieldIndex(Row, name).?);
        }

        pub fn ref(self: *const Self, slot: u32) Ref {
            const at = self.core.spot(slot);
            return .{ .block = at.block, .row = at.row };
        }

        /// An entity's row, where its directory entry says it stands; `dormant` puts it in the
        /// dormant part whatever the order says.
        pub fn add(self: *Self, slot: u32, value: Row, dormant: bool) !void {
            const at = try self.core.addRow(slot, dormant);
            (Ref{ .block = at.block, .row = at.row }).set(value);
        }

        pub fn remove(self: *Self, slot: u32) void {
            self.core.remove(slot);
        }

        pub fn maintain(self: *Self) !void {
            try self.core.maintain();
        }

        pub fn idsInto(self: *const Self, output: []u64) []u64 {
            return self.core.idsInto(output);
        }

        pub fn slotsInto(self: *const Self, output: []u32) []u32 {
            return self.core.slotsInto(output);
        }

        pub fn clear(self: *Self) void {
            self.core.clear();
        }

        pub fn standingCount(self: *const Self) usize {
            return self.core.standingCount();
        }

        pub fn isDormant(self: *const Self, slot: u32) bool {
            return self.core.isDormant(slot);
        }
    };
}
