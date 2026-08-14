const std = @import("std");
const config = @import("config.zig").value;
const connection = @import("reactor_connection.zig");

const Connection = connection.Connection;
const Segment = connection.OutputSegment;

pub const Pool = struct {
    buffers: [][]u8 = &.{},
    free: []u16 = &.{},
    free_count: usize = 0,
    scratch: []u8 = &.{},

    pub fn allocate(self: *Pool, allocator: std.mem.Allocator) !void {
        self.buffers = try allocator.alloc([]u8, config.output_buffer_count);
        for (self.buffers) |*buffer|
            buffer.* = try allocator.alloc(u8, config.output_buffer_size);
        self.free = try allocator.alloc(u16, config.output_buffer_count);
        self.scratch = try allocator.alloc(u8, config.player_write_buffer_size);
        self.reset();
    }

    pub fn reset(self: *Pool) void {
        self.free_count = self.free.len;
        for (0..self.free.len) |index|
            self.free[index] = @intCast(self.free.len - 1 - index);
    }

    pub fn reserve(
        self: *Pool,
        clients: []Connection,
        slot: u16,
        minimum: usize,
    ) []u8 {
        const client = &clients[slot];
        if (minimum > config.output_buffer_size) {
            if (minimum > self.scratch.len or client.output_lease_active or
                client.scratch_lease_active)
                return self.scratch[0..0];
            client.scratch_lease_active = true;
            return self.scratch;
        }
        const segment = self.writableTail(client, minimum) catch
            return self.scratch[0..0];
        client.output_lease_segment = client.output_segment_count - 1;
        client.output_lease_start = segment.len;
        client.output_lease_active = true;
        return self.buffers[segment.buffer_index][segment.len..];
    }

    pub fn commit(
        self: *Pool,
        clients: []Connection,
        slot: u16,
        byte_count: usize,
    ) !void {
        const client = &clients[slot];
        if (client.scratch_lease_active) {
            if (byte_count > self.scratch.len) return error.OutputBackpressure;
            client.scratch_lease_active = false;
            try self.ensure(client, byte_count);
            return self.appendBytes(client, self.scratch[0..byte_count]);
        }
        if (!client.output_lease_active) return error.OutputBackpressure;
        const segment = client.outputSegment(client.output_lease_segment);
        if (byte_count > config.output_buffer_size - client.output_lease_start)
            return error.OutputBackpressure;
        segment.len = client.output_lease_start + byte_count;
        client.output_lease_active = false;
    }

    pub fn reserved(self: *Pool, client: *Connection) []u8 {
        if (client.scratch_lease_active) return self.scratch;
        std.debug.assert(client.output_lease_active);
        const segment = client.outputSegment(client.output_lease_segment);
        return self.buffers[segment.buffer_index][client.output_lease_start..];
    }

    pub fn abort(self: *Pool, clients: []Connection, slot: u16) void {
        const client = &clients[slot];
        client.scratch_lease_active = false;
        if (!client.output_lease_active) return;
        const segment_index = client.output_lease_segment;
        if (segment_index < client.output_segment_count) {
            client.outputSegment(segment_index).len = client.output_lease_start;
            for (0..config.max_client_output_segments) |_| {
                if (client.output_segment_count <= segment_index + 1) break;
                client.output_segment_count -= 1;
                self.release(client.outputSegment(client.output_segment_count).buffer_index);
            } else @panic("output cancellation exceeded its fixed bound");
            if (client.outputSegment(segment_index).len == 0 and
                segment_index >= client.send_segment_count)
            {
                self.release(client.outputSegment(segment_index).buffer_index);
                client.output_segment_count = segment_index;
            }
        }
        client.output_lease_active = false;
    }

    pub fn releaseSent(
        self: *Pool,
        client: *Connection,
        sent_bytes: usize,
    ) void {
        var remaining = sent_bytes;
        for (0..config.max_client_output_segments) |_| {
            if (remaining == 0 or client.output_segment_count == 0) break;
            const segment = client.outputSegment(0);
            const available = segment.len - segment.offset;
            if (remaining < available) {
                segment.offset += remaining;
                remaining = 0;
                break;
            }
            remaining -= available;
            self.release(segment.buffer_index);
            client.output_segment_start =
                (client.output_segment_start + 1) % client.output_segments.len;
            client.output_segment_count -= 1;
            client.send_segment_count -= 1;
        }
        std.debug.assert(remaining == 0);
    }

    pub fn freeClient(self: *Pool, client: *Connection, first: usize) void {
        var index = first;
        while (index < client.output_segment_count) : (index += 1)
            self.release(client.outputSegment(index).buffer_index);
        client.output_segment_count = first;
        if (client.output_segment_count < client.send_segment_count)
            client.send_segment_count = client.output_segment_count;
        if (client.output_segment_count == 0) client.output_segment_start = 0;
    }

    pub fn backpressured(self: *const Pool, client: *const Connection) bool {
        return client.output_lease_active or client.scratch_lease_active or
            client.output_segment_count >= config.chunk_output_high_water_segments or
            self.free_count == 0;
    }

    pub fn canReservePlayBatch(
        self: *const Pool,
        clients: []const Connection,
        minimum: usize,
    ) bool {
        if (minimum > config.output_buffer_size) return false;
        var required_buffers: usize = 0;
        for (clients) |*client| {
            if (client.phase != .play or !client.player_reserved) continue;
            if (client.output_lease_active or client.scratch_lease_active) return false;
            if (client.output_segment_count > client.send_segment_count) {
                const tail = client.constOutputSegment(client.output_segment_count - 1);
                if (config.output_buffer_size - tail.len >= minimum) continue;
            }
            if (client.output_segment_count == client.output_segments.len) return false;
            required_buffers += 1;
            if (required_buffers > self.free_count) return false;
        }
        return true;
    }

    fn appendBytes(self: *Pool, client: *Connection, bytes: []const u8) !void {
        var remaining = bytes;
        for (0..config.max_client_output_segments) |_| {
            if (remaining.len == 0) return;
            const segment = try self.writableTail(client, 1);
            const count = @min(config.output_buffer_size - segment.len, remaining.len);
            @memcpy(self.buffers[segment.buffer_index][segment.len..][0..count], remaining[0..count]);
            segment.len += count;
            remaining = remaining[count..];
        }
        return error.OutputBackpressure;
    }

    fn ensure(self: *const Pool, client: *const Connection, byte_count: usize) !void {
        var tail_capacity: usize = 0;
        if (client.output_segment_count > client.send_segment_count) {
            const tail = client.constOutputSegment(client.output_segment_count - 1);
            tail_capacity = config.output_buffer_size - tail.len;
        }
        if (byte_count <= tail_capacity) return;
        const remaining = byte_count - tail_capacity;
        const needed = (remaining + config.output_buffer_size - 1) /
            config.output_buffer_size;
        if (needed > self.free_count or
            client.output_segment_count + needed > client.output_segments.len)
            return error.OutputBackpressure;
    }

    fn writableTail(
        self: *Pool,
        client: *Connection,
        minimum: usize,
    ) !*Segment {
        if (client.output_segment_count > client.send_segment_count) {
            const tail = client.outputSegment(client.output_segment_count - 1);
            if (config.output_buffer_size - tail.len >= minimum) return tail;
        }
        if (client.output_segment_count == client.output_segments.len)
            return error.OutputBackpressure;
        const buffer_index = try self.acquire();
        const logical = client.output_segment_count;
        client.output_segment_count += 1;
        const segment = client.outputSegment(logical);
        segment.* = .{ .buffer_index = buffer_index };
        return segment;
    }

    fn acquire(self: *Pool) !u16 {
        if (self.free_count == 0) return error.OutputBackpressure;
        self.free_count -= 1;
        return self.free[self.free_count];
    }

    fn release(self: *Pool, buffer_index: u16) void {
        std.debug.assert(self.free_count < self.free.len);
        self.free[self.free_count] = buffer_index;
        self.free_count += 1;
    }
};

test "a backpressured connection cannot retain the shared output pool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var pool: Pool = .{};
    try pool.allocate(allocator);
    var clients: [2]Connection = .{ .{}, .{} };
    for (&clients) |*client| try client.allocate(allocator);

    for (0..config.max_client_output_segments) |_| {
        const bytes = pool.reserve(&clients, 0, config.output_buffer_size);
        try std.testing.expectEqual(config.output_buffer_size, bytes.len);
        try pool.commit(&clients, 0, config.output_buffer_size);
    }
    try std.testing.expectEqual(@as(usize, 0), pool.reserve(&clients, 0, 1).len);

    const fast = pool.reserve(&clients, 1, 1);
    try std.testing.expect(fast.len >= 1);
    try pool.commit(&clients, 1, 1);
    try std.testing.expectEqual(@as(usize, 1), clients[1].output_segment_count);
}

test "play batch reservation is checked without mutating output state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var pool: Pool = .{};
    try pool.allocate(allocator);
    var clients: [2]Connection = .{ .{}, .{} };
    for (&clients) |*client| {
        try client.allocate(allocator);
        client.phase = .play;
        client.player_reserved = true;
    }
    try std.testing.expect(pool.canReservePlayBatch(&clients, 22));
    try std.testing.expectEqual(@as(usize, 0), clients[0].output_segment_count);

    clients[0].output_lease_active = true;
    try std.testing.expect(!pool.canReservePlayBatch(&clients, 22));
    clients[0].output_lease_active = false;

    pool.free_count = 1;
    try std.testing.expect(!pool.canReservePlayBatch(&clients, 22));
}
