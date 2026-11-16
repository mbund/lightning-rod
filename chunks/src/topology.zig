//! A topology finds, per section of a column, the cells a layer says act. Systems on the
//! simulation thread ask for columns as they enter their domain or as edits reach them, and the
//! terrain thread answers, so the simulation thread never reads blocks for it. The terrain thread
//! answers from the column's layer record in the derived cache while the revisions of the nine
//! columns around it still match. Otherwise it reads the sections around from memory where they
//! are there and from the store elsewhere, and saves what it found when nothing around the column
//! is edited in memory only. A restart reads one small record per column.
//!
//! An answer carries the count of every section and the acting cells of each section that has
//! any, in a second ring. Room for those is held from the request on, so an answer always fits.

const std = @import("std");
const classification = @import("classification.zig");
const encoding = @import("encoding.zig");
const layer = @import("layer.zig");

const assert = std.debug.assert;

pub const Column = classification.Column;
pub const sections_max = 32;
/// Columns the terrain thread answers in one batch.
pub const batch_max = 16;
pub const Mask = [64]u64;

pub const Answer = struct {
    column: Column,
    /// Unavailable when the store could not be read or a section around is still being
    /// generated. The column may be asked for again.
    result: enum { counted, unavailable },
    counts: [sections_max]u16 = @splat(0),
    /// The masks of the counted sections with acting cells follow in the mask ring, in order.
    masks: u8 = 0,
};

/// Record layout: fingerprint, nine column revisions, minimum section, section count, counts,
/// then the mask of every section with a count, in section order.
const record_header = 32 + 9 * 8 + 4 + 1;
pub const record_max = record_header + sections_max * (2 + @sizeOf(Mask));

pub fn encodeRecord(fingerprint: [32]u8, revisions: [9]u64, column: Column, counts: []const u16, masks: []const Mask, output: *[record_max]u8) []const u8 {
    assert(counts.len == column.count and column.count <= sections_max);
    output[0..32].* = fingerprint;
    for (revisions, 0..) |revision, index| std.mem.writeInt(u64, output[32 + index * 8 ..][0..8], revision, .little);
    std.mem.writeInt(i32, output[104..108], column.minimum, .little);
    output[108] = column.count;
    var at: usize = record_header;
    for (counts) |count| {
        std.mem.writeInt(u16, output[at..][0..2], count, .little);
        at += 2;
    }
    var used: usize = 0;
    for (counts) |count| {
        if (count == 0) continue;
        for (masks[used]) |word| {
            std.mem.writeInt(u64, output[at..][0..8], word, .little);
            at += 8;
        }
        used += 1;
    }
    assert(used == masks.len);
    return output[0..at];
}

/// The counts and masks a record holds, or false when it was made for other blocks or another
/// layer. Masks go to `masks` in section order, one per counted section.
pub fn decodeRecord(bytes: []const u8, fingerprint: [32]u8, revisions: [9]u64, column: Column, counts: *[sections_max]u16, masks: *[sections_max]Mask) ?u8 {
    const counts_end = record_header + @as(usize, column.count) * 2;
    if (bytes.len < counts_end) return null;
    if (!std.mem.eql(u8, bytes[0..32], &fingerprint)) return null;
    for (revisions, 0..) |revision, index| {
        if (std.mem.readInt(u64, bytes[32 + index * 8 ..][0..8], .little) != revision) return null;
    }
    if (std.mem.readInt(i32, bytes[104..108], .little) != column.minimum or bytes[108] != column.count) return null;
    counts.* = @splat(0);
    var acting: u8 = 0;
    for (counts[0..column.count], 0..) |*count, index| {
        count.* = std.mem.readInt(u16, bytes[record_header + index * 2 ..][0..2], .little);
        if (count.* > encoding.blocks) return null;
        if (count.* != 0) acting += 1;
    }
    if (bytes.len != counts_end + @as(usize, acting) * @sizeOf(Mask)) return null;
    var at = counts_end;
    for (masks[0..acting]) |*mask| for (mask) |*word| {
        word.* = std.mem.readInt(u64, bytes[at..][0..8], .little);
        at += 8;
    };
    return acting;
}

pub const Topology = struct {
    layer: *const layer.Layer,
    fingerprint: [32]u8,
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    /// Set when requests are queued, to wake the terrain thread.
    wakeup: ?*std.Io.Event,
    /// Requests are a ring the simulation thread fills and the terrain thread empties.
    requests: []Column,
    request_head: usize = 0,
    request_count: usize = 0,
    /// Answers are a ring filled the other way.
    answers: []Answer,
    answer_head: usize = 0,
    answer_count: usize = 0,
    /// The masks answers carry.
    masks: []Mask,
    mask_head: usize = 0,
    mask_count: usize = 0,
    /// Mask room held for requests not answered or answers not taken, one per section asked for.
    masks_held: usize = 0,
    /// Requests the terrain thread has taken and not answered yet.
    in_flight: usize = 0,
    /// Terrain thread scratch for one batch.
    claimed: [batch_max]Column = undefined,
    found: [batch_max]Answer = undefined,
    found_masks: *[batch_max][sections_max]Mask,
    workspace: *layer.Workspace,
    /// The 27 sections around one section.
    around_bytes: *[27][encoding.maximum_decoded_bytes]u8,
    record_bytes: *[batch_max * record_max]u8,
    next: ?*Topology = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, counted: *const layer.Layer, fingerprint: [32]u8, capacity: usize, mask_capacity: usize, wakeup: ?*std.Io.Event) !*Topology {
        if (capacity == 0 or mask_capacity < sections_max) return error.InvalidConfiguration;
        const self = try allocator.create(Topology);
        self.* = .{
            .layer = counted,
            .fingerprint = fingerprint,
            .io = io,
            .wakeup = wakeup,
            .requests = try allocator.alloc(Column, capacity),
            .answers = try allocator.alloc(Answer, capacity),
            .masks = try allocator.alloc(Mask, mask_capacity),
            .found_masks = try allocator.create([batch_max][sections_max]Mask),
            .workspace = try allocator.create(layer.Workspace),
            .around_bytes = try allocator.create([27][encoding.maximum_decoded_bytes]u8),
            .record_bytes = try allocator.create([batch_max * record_max]u8),
        };
        return self;
    }

    /// Asks for columns. Returns how many were queued, fewer when the queues are full. Every
    /// queued request is answered once, so a caller never has more out than the capacity.
    pub fn request(self: *Topology, columns: []const Column) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        for (columns) |column| {
            assert(column.count > 0 and column.count <= sections_max);
            // Answers waiting to be taken and requests in flight hold room too.
            if (self.request_count + self.in_flight + self.answer_count == self.requests.len) break;
            if (self.masks_held + column.count > self.masks.len) break;
            self.requests[(self.request_head + self.request_count) % self.requests.len] = column;
            self.request_count += 1;
            self.masks_held += column.count;
            count += 1;
        }
        if (count != 0) if (self.wakeup) |event| event.set(self.io);
        return count;
    }

    /// Takes one answer and copies its masks out, in section order.
    pub fn take(self: *Topology, masks: *[sections_max]Mask) ?Answer {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.answer_count == 0) return null;
        const taken = self.answers[self.answer_head];
        self.answer_head = (self.answer_head + 1) % self.answers.len;
        self.answer_count -= 1;
        assert(self.mask_count >= taken.masks);
        for (masks[0..taken.masks]) |*mask| {
            mask.* = self.masks[self.mask_head];
            self.mask_head = (self.mask_head + 1) % self.masks.len;
            self.mask_count -= 1;
        }
        self.masks_held -= taken.masks;
        return taken;
    }

    /// Terrain thread. Takes a batch of requests to answer.
    pub fn claim(self: *Topology, output: []Column) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const count = @min(output.len, self.request_count);
        for (output[0..count]) |*column| {
            column.* = self.requests[self.request_head];
            self.request_head = (self.request_head + 1) % self.requests.len;
            self.request_count -= 1;
        }
        self.in_flight += count;
        return count;
    }

    /// Terrain thread. Answers what `claim` took, each with the masks it counts.
    pub fn answer(self: *Topology, answers: []const Answer, masks: []const [sections_max]Mask) void {
        assert(answers.len == masks.len);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        assert(self.in_flight >= answers.len);
        self.in_flight -= answers.len;
        for (answers, masks) |found, found_masks| {
            assert(self.answer_count < self.answers.len and found.masks <= found.column.count);
            self.answers[(self.answer_head + self.answer_count) % self.answers.len] = found;
            self.answer_count += 1;
            for (found_masks[0..found.masks]) |mask| {
                assert(self.mask_count < self.masks.len);
                self.masks[(self.mask_head + self.mask_count) % self.masks.len] = mask;
                self.mask_count += 1;
            }
            // Room for sections without masks is free again at once.
            self.masks_held -= found.column.count - found.masks;
        }
    }

    pub fn pending(self: *Topology) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.request_count != 0;
    }
};

test "requests are answered in order and never outgrow the queues" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const counted: layer.Layer = .init(&.{1});
    const topology = try Topology.init(arena.allocator(), std.testing.io, &counted, @splat(0), 3, 32, null);
    const columns = [_]Column{
        .{ .world = 0, .x = 0, .z = 0, .minimum = 0, .count = 1 },
        .{ .world = 0, .x = 1, .z = 0, .minimum = 0, .count = 1 },
        .{ .world = 0, .x = 2, .z = 0, .minimum = 0, .count = 1 },
        .{ .world = 0, .x = 3, .z = 0, .minimum = 0, .count = 1 },
    };
    try std.testing.expectEqual(@as(usize, 3), topology.request(&columns));
    var claimed: [2]Column = undefined;
    try std.testing.expectEqual(@as(usize, 2), topology.claim(&claimed));
    // Claimed requests still hold their room until their answers are taken.
    try std.testing.expectEqual(@as(usize, 0), topology.request(columns[3..]));
    var masks: [2][sections_max]Mask = undefined;
    masks[0][0] = @splat(5);
    topology.answer(&.{ .{ .column = claimed[0], .result = .counted, .masks = 1 }, .{ .column = claimed[1], .result = .unavailable } }, &masks);
    var taken: [sections_max]Mask = undefined;
    try std.testing.expectEqual(@as(u8, 1), topology.take(&taken).?.masks);
    try std.testing.expectEqual(@as(u64, 5), taken[0][0]);
    try std.testing.expectEqual(@as(i32, 1), topology.take(&taken).?.column.x);
    try std.testing.expect(topology.take(&taken) == null);
    try std.testing.expectEqual(@as(usize, 2), topology.request(columns[3..] ++ columns[0..1]));
    // Mask room bounds requests too: tall columns hold one mask per section.
    const tall = try Topology.init(arena.allocator(), std.testing.io, &counted, @splat(0), 8, 32, null);
    const column: Column = .{ .world = 0, .x = 0, .z = 0, .minimum = 0, .count = 24 };
    try std.testing.expectEqual(@as(usize, 1), tall.request(&.{ column, column }));
}

test "records hold only for the layer and the blocks they were counted from" {
    const column: Column = .{ .world = 2, .x = -3, .z = 5, .minimum = -4, .count = 3 };
    const revisions: [9]u64 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    var bytes: [record_max]u8 = undefined;
    const masks = [_]Mask{ @splat(3), @splat(9) };
    const record = encodeRecord(@splat(7), revisions, column, &.{ 0, 12, 4096 }, &masks, &bytes);
    var counts: [sections_max]u16 = undefined;
    var read: [sections_max]Mask = undefined;
    try std.testing.expectEqual(@as(?u8, 2), decodeRecord(record, @splat(7), revisions, column, &counts, &read));
    try std.testing.expectEqualSlices(u16, &.{ 0, 12, 4096 }, counts[0..3]);
    try std.testing.expectEqual(@as(u64, 9), read[1][63]);
    try std.testing.expect(decodeRecord(record, @splat(8), revisions, column, &counts, &read) == null);
    var changed = revisions;
    changed[4] += 1;
    try std.testing.expect(decodeRecord(record, @splat(7), changed, column, &counts, &read) == null);
    var taller = column;
    taller.count = 4;
    try std.testing.expect(decodeRecord(record, @splat(7), revisions, taller, &counts, &read) == null);
    try std.testing.expect(decodeRecord(record[0 .. record.len - 1], @splat(7), revisions, column, &counts, &read) == null);
}
