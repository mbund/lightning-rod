//! Entities kept for good: one record each, under the column it was in when saved, so a column
//! comes back with one scan. Written at checkpoints and as a column leaves memory, read as one
//! comes back; nothing here is touched while entities tick.

const std = @import("std");
const records = @import("records");
const space_module = @import("space.zig");

pub const Id = u64;
pub const Column = space_module.Column;

pub const key_bytes = 1 + 4 + 4 + 4 + 8;

pub const Key = [key_bytes]u8;

/// Columns in key order by world, then x, then z, each flipped to sort as unsigned.
pub fn key(prefix: u8, column: Column, entity: Id) Key {
    var bytes: Key = undefined;
    bytes[0] = prefix;
    std.mem.writeInt(u32, bytes[1..5], column.world, .big);
    std.mem.writeInt(u32, bytes[5..9], @as(u32, @bitCast(column.x)) ^ 0x8000_0000, .big);
    std.mem.writeInt(u32, bytes[9..13], @as(u32, @bitCast(column.z)) ^ 0x8000_0000, .big);
    std.mem.writeInt(u64, bytes[13..21], entity, .big);
    return bytes;
}

pub fn idOf(bytes: []const u8) Id {
    return std.mem.readInt(u64, bytes[13..21], .big);
}

pub fn columnOf(bytes: []const u8) Column {
    return .{
        .world = std.mem.readInt(u32, bytes[1..5], .big),
        .x = @bitCast(std.mem.readInt(u32, bytes[5..9], .big) ^ 0x8000_0000),
        .z = @bitCast(std.mem.readInt(u32, bytes[9..13], .big) ^ 0x8000_0000),
    };
}

/// Writes gathered and put in batches.
pub fn Batch(comptime value_bytes: usize) type {
    return struct {
        const Self = @This();

        table: records.Table,
        keys: [records.Table.write_batch_size]Key = undefined,
        values: [records.Table.write_batch_size][value_bytes]u8 = undefined,
        lengths: [records.Table.write_batch_size]usize = undefined,
        writes: [records.Table.write_batch_size]records.Write = undefined,
        count: usize = 0,

        pub fn put(self: *Self, record: Key, value: []const u8) !void {
            std.debug.assert(value.len <= value_bytes);
            self.keys[self.count] = record;
            @memcpy(self.values[self.count][0..value.len], value);
            self.writes[self.count] = .{ .key = &self.keys[self.count], .value = self.values[self.count][0..value.len] };
            try self.advance();
        }

        pub fn delete(self: *Self, record: Key) !void {
            self.keys[self.count] = record;
            self.writes[self.count] = .{ .key = &self.keys[self.count], .value = null };
            try self.advance();
        }

        fn advance(self: *Self) !void {
            self.count += 1;
            if (self.count == self.writes.len) try self.flush();
        }

        pub fn flush(self: *Self) !void {
            if (self.count > 0) try self.table.putBatch(self.writes[0..self.count]);
            self.count = 0;
        }
    };
}

/// The records of one column, or of every column, a batch at a time: each row's key and value
/// are the reader's own.
pub fn ColumnReader(comptime value_bytes: usize) type {
    return struct {
        const Self = @This();

        table: records.Table,
        after: Key,
        after_len: usize,
        before: [13]u8,
        before_len: usize = 13,
        keys: [16]Key = undefined,
        values: [16][value_bytes]u8 = undefined,
        entries: [16]records.ScanEntry = undefined,
        more: bool = true,

        pub const Row = struct { id: Id, value: []const u8 };

        pub fn init(table: records.Table, prefix: u8, column: Column) Self {
            const first = key(prefix, column, 0);
            var self: Self = .{ .table = table, .after = undefined, .after_len = 13, .before = undefined };
            @memcpy(self.after[0..13], first[0..13]);
            // The next column's first key bounds this one's.
            var bound = first[0..13].*;
            var at: usize = 12;
            while (true) : (at -= 1) {
                bound[at], const overflow = @addWithOverflow(bound[at], 1);
                if (overflow == 0) break;
                if (at == 0) break;
            }
            self.before = bound;
            return self;
        }

        /// Every record under a prefix, column by column.
        pub fn all(table: records.Table, prefix: u8) Self {
            std.debug.assert(prefix < std.math.maxInt(u8));
            var self: Self = .{ .table = table, .after = undefined, .after_len = 1, .before = undefined, .before_len = 1 };
            self.after[0] = prefix;
            self.before[0] = prefix + 1;
            return self;
        }

        pub fn next(self: *Self, rows: []Row) ![]Row {
            if (!self.more) return rows[0..0];
            for (&self.entries, &self.keys, &self.values) |*entry, *row_key, *value| entry.* = .{ .key = row_key, .value = value };
            var cursor: records.ScanCursor = .{ .after = &self.after, .after_len = self.after_len, .before = self.before[0..self.before_len] };
            const count = @min(rows.len, self.entries.len);
            const result = try self.table.scan(&cursor, self.entries[0..count]);
            self.after_len = cursor.after_len;
            self.more = result.more;
            for (self.entries[0..result.count], rows[0..result.count]) |entry, *row| {
                if (entry.key_len != key_bytes) return error.Corrupt;
                row.* = .{ .id = idOf(entry.key[0..key_bytes]), .value = entry.value[0..entry.value_len] };
            }
            return rows[0..result.count];
        }
    };
}

test "keys sort columns by world, x and z, negatives before positives" {
    const a = key(5, .{ .world = 0, .x = -1, .z = 3 }, 9);
    const b = key(5, .{ .world = 0, .x = 0, .z = -7 }, 1);
    const c = key(5, .{ .world = 0, .x = 0, .z = 2 }, 1);
    try std.testing.expect(std.mem.order(u8, &a, &b) == .lt and std.mem.order(u8, &b, &c) == .lt);
    try std.testing.expectEqual(@as(Id, 9), idOf(&a));
    try std.testing.expectEqual(Column{ .world = 0, .x = -1, .z = 3 }, columnOf(&a));
}
