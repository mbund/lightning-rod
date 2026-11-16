//! A topology is a classification of block states the store keeps per section in the derived
//! cache, beside the blocks, and builds when a section is written or first asked for. Systems on
//! the simulation thread ask for the column summaries of a topology here, and the background
//! thread answers them from the cached headers, one record per 32 sections, without reading
//! blocks. The queues are fixed: requests and answers are bounded at open.

const std = @import("std");
const classification = @import("classification.zig");

const assert = std.debug.assert;

pub const Column = classification.Column;
pub const Summary = classification.ColumnSummary;

pub const Answer = struct {
    column: Column,
    /// False when the store could not read the summary. The column may be asked for again.
    available: bool,
    summary: Summary,
};

pub const Topology = struct {
    properties: []const u8,
    selected: u8,
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    /// Set when requests are queued, to wake the background thread.
    wakeup: ?*std.Io.Event,
    /// Requests are a ring the simulation thread fills and the background thread empties.
    requests: []Column,
    request_head: usize = 0,
    request_count: usize = 0,
    /// Answers are a ring filled the other way.
    answers: []Answer,
    answer_head: usize = 0,
    answer_count: usize = 0,
    /// Requests the background thread has taken and not answered yet.
    in_flight: usize = 0,
    /// Background thread scratch for one batch.
    claimed: []Column,
    summaries: []Summary,
    next: ?*Topology = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, properties: []const u8, selected: u8, capacity: usize, wakeup: ?*std.Io.Event) !*Topology {
        if (capacity == 0) return error.InvalidConfiguration;
        const self = try allocator.create(Topology);
        self.* = .{
            .properties = properties,
            .selected = selected,
            .io = io,
            .wakeup = wakeup,
            .requests = try allocator.alloc(Column, capacity),
            .answers = try allocator.alloc(Answer, capacity),
            .claimed = try allocator.alloc(Column, classification.column_batch_max),
            .summaries = try allocator.alloc(Summary, classification.column_batch_max),
        };
        return self;
    }

    /// Asks for column summaries. Returns how many were queued, fewer when the queue is full.
    /// Every queued request is answered once, so a caller never has more out than the capacity.
    pub fn request(self: *Topology, columns: []const Column) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // Answers waiting to be taken and requests in flight hold room too.
        const room = self.requests.len - self.request_count - self.in_flight - self.answer_count;
        const count = @min(room, columns.len);
        for (columns[0..count]) |column| {
            self.requests[(self.request_head + self.request_count) % self.requests.len] = column;
            self.request_count += 1;
        }
        if (count != 0) if (self.wakeup) |event| event.set(self.io);
        return count;
    }

    /// Takes answers in the order they came.
    pub fn take(self: *Topology, output: []Answer) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const count = @min(output.len, self.answer_count);
        for (output[0..count]) |*taken| {
            taken.* = self.answers[self.answer_head];
            self.answer_head = (self.answer_head + 1) % self.answers.len;
            self.answer_count -= 1;
        }
        return count;
    }

    /// Background thread. Takes a batch of requests to answer.
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

    /// Background thread. Answers what `claim` took, in the same order.
    pub fn answer(self: *Topology, columns: []const Column, summaries: []const Summary, available: bool) void {
        assert(columns.len == summaries.len);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        assert(self.in_flight >= columns.len);
        self.in_flight -= columns.len;
        for (columns, summaries) |column, summary| {
            assert(self.answer_count < self.answers.len);
            self.answers[(self.answer_head + self.answer_count) % self.answers.len] = .{ .column = column, .available = available, .summary = summary };
            self.answer_count += 1;
        }
    }

    pub fn pending(self: *Topology) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.request_count != 0;
    }
};

test "requests are answered in order and never outgrow the queue" {
    const topology = try Topology.init(std.testing.allocator, std.testing.io, &.{1}, 1, 3, null);
    defer {
        std.testing.allocator.free(topology.requests);
        std.testing.allocator.free(topology.answers);
        std.testing.allocator.free(topology.claimed);
        std.testing.allocator.free(topology.summaries);
        std.testing.allocator.destroy(topology);
    }
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
    topology.answer(&claimed, &.{ .{}, .{} }, true);
    var answers: [4]Answer = undefined;
    try std.testing.expectEqual(@as(usize, 2), topology.take(&answers));
    try std.testing.expectEqual(@as(i32, 1), answers[1].column.x);
    try std.testing.expectEqual(@as(usize, 2), topology.request(columns[3..] ++ columns[0..1]));
}
