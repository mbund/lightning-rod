const connection = @import("connection_api.zig");
const std = @import("std");

pub const Page = enum(u16) { _ };

pub const Limits = struct {
    to_core_pages: u16,
    to_sessions_pages: u16,
    to_core_page_bytes: u32,
    to_sessions_page_bytes: u32,
    to_core_messages: u16,
    to_sessions_messages: u16,

    pub fn valid(self: Limits) bool {
        return self.to_core_pages != 0 and self.to_sessions_pages != 0 and
            self.to_core_page_bytes != 0 and self.to_sessions_page_bytes != 0 and
            self.to_core_messages != 0 and self.to_sessions_messages != 0;
    }
};

pub fn Spsc(comptime T: type, comptime capacity: usize) type {
    if (capacity < 2) @compileError("an SPSC queue needs one usable slot and one sentinel");
    return struct {
        const Self = @This();
        slots: [capacity]T = undefined,
        write: std.atomic.Value(usize) align(64) = std.atomic.Value(usize).init(0),
        read: std.atomic.Value(usize) align(64) = std.atomic.Value(usize).init(0),

        pub fn canPush(self: *const Self) bool {
            const write = self.write.load(.monotonic);
            return (write + 1) % capacity != self.read.load(.acquire);
        }

        pub fn push(self: *Self, value: T) bool {
            const write = self.write.load(.monotonic);
            const next = (write + 1) % capacity;
            if (next == self.read.load(.acquire)) return false;
            self.slots[write] = value;
            self.write.store(next, .release);
            return true;
        }

        pub fn pop(self: *Self) ?T {
            const read = self.read.load(.monotonic);
            if (read == self.write.load(.acquire)) return null;
            const value = self.slots[read];
            self.read.store((read + 1) % capacity, .release);
            return value;
        }

        pub fn peek(self: *const Self, offset: usize) ?T {
            const read = self.read.load(.monotonic);
            const write = self.write.load(.acquire);
            const count = if (write >= read) write - read else capacity - read + write;
            if (offset >= count) return null;
            return self.slots[(read + offset) % capacity];
        }

        pub fn empty(self: *const Self) bool {
            return self.read.load(.acquire) == self.write.load(.acquire);
        }

        pub fn availableToPush(self: *const Self) usize {
            const write = self.write.load(.monotonic);
            const read = self.read.load(.acquire);
            return if (write >= read) capacity - (write - read) - 1 else read - write - 1;
        }

        pub fn availableToPop(self: *const Self) usize {
            return capacity - 1 - self.availableToPush();
        }
    };
}

pub fn Pages(comptime page_count: usize, comptime page_bytes: usize) type {
    if (page_count == 0 or page_count > std.math.maxInt(u16) or page_bytes == 0) {
        @compileError("invalid exchange page pool");
    }
    return struct {
        const Self = @This();
        pub const capacity_bytes = page_bytes;
        const Ring = Spsc(Page, page_count + 1);

        const sealed = @as(u32, 1) << 31;

        bytes: [page_count][page_bytes]u8 = undefined,
        used: [page_count]u32 = @splat(0),
        state: [page_count]std.atomic.Value(u32) = @splat(.init(0)),
        free: Ring = .{},
        returned: Ring = .{},
        current: ?Page = null,
        publications: u64 = 0,

        pub fn initialize(self: *Self) void {
            self.free = .{};
            self.returned = .{};
            self.current = null;
            self.publications = 0;
            @memset(&self.used, 0);
            for (&self.state) |*value| value.* = .init(0);
            for (0..page_count) |index| std.debug.assert(self.free.push(@enumFromInt(index)));
        }

        pub fn acquireProducer(self: *Self, minimum: usize) ?Page {
            std.debug.assert(minimum != 0 and minimum <= page_bytes);
            self.recycleProducer();
            if (self.current) |page| {
                if (page_bytes - self.used[@intFromEnum(page)] >= minimum) return page;
                self.sealProducer();
            }
            const page = self.free.pop() orelse return null;
            self.current = page;
            return page;
        }

        pub fn availableProducerBytes(self: *Self) usize {
            self.recycleProducer();
            const current_bytes = if (self.current) |page|
                page_bytes - self.used[@intFromEnum(page)]
            else
                0;
            return current_bytes + self.free.availableToPop() * page_bytes;
        }

        pub fn producerPlan(self: *Self) struct { remaining: usize, pages: usize } {
            self.recycleProducer();
            return .{
                .remaining = if (self.current) |page| page_bytes - self.used[@intFromEnum(page)] else 0,
                .pages = self.free.availableToPop(),
            };
        }

        pub fn requiredMessages(self: *Self, bytes: usize) usize {
            if (bytes == 0) return 0;
            self.recycleProducer();
            const current_bytes = if (self.current) |page|
                page_bytes - self.used[@intFromEnum(page)]
            else
                0;
            if (bytes <= current_bytes) return 1;
            return @intFromBool(current_bytes != 0) +
                (bytes - current_bytes + page_bytes - 1) / page_bytes;
        }

        pub fn producerBytes(self: *Self, page: Page) []u8 {
            std.debug.assert(self.current == page);
            const index = @intFromEnum(page);
            return self.bytes[index][self.used[index]..];
        }

        pub fn producerOffset(self: *const Self, page: Page) u32 {
            std.debug.assert(self.current == page);
            return self.used[@intFromEnum(page)];
        }

        pub fn retainProducer(self: *Self, page: Page) void {
            const index = @intFromEnum(page);
            const previous = self.state[index].fetchAdd(1, .release);
            std.debug.assert(previous & sealed == 0 and previous & ~sealed < sealed - 1);
        }

        pub fn commitProducer(self: *Self, page: Page, len: usize) u32 {
            std.debug.assert(self.current == page);
            const index = @intFromEnum(page);
            const offset = self.used[index];
            std.debug.assert(len != 0 and len <= page_bytes - offset);
            self.used[index] += @intCast(len);
            const previous = self.state[index].fetchAdd(1, .release);
            std.debug.assert(previous & sealed == 0 and previous & ~sealed < sealed - 1);
            return offset;
        }

        pub fn consumerBytes(self: *const Self, page: Page, offset: u32, len: u32) []const u8 {
            const end = @as(usize, offset) + len;
            std.debug.assert(end <= page_bytes);
            return self.bytes[@intFromEnum(page)][offset..end];
        }

        pub fn releaseConsumer(self: *Self, page: Page) bool {
            const index = @intFromEnum(page);
            const previous = self.state[index].fetchSub(1, .acq_rel);
            std.debug.assert(previous & ~sealed != 0);
            return previous != (sealed | 1) or self.returned.push(page);
        }

        pub fn recycleProducer(self: *Self) void {
            while (self.returned.pop()) |page| {
                const index = @intFromEnum(page);
                std.debug.assert(self.state[index].load(.acquire) == sealed);
                self.state[index].store(0, .release);
                self.used[index] = 0;
                std.debug.assert(self.free.push(page));
            }
        }

        pub fn sealProducer(self: *Self) void {
            const page = self.current orelse return;
            const index = @intFromEnum(page);
            self.current = null;
            self.publications +%= 1;
            const previous = self.state[index].fetchOr(sealed, .acq_rel);
            std.debug.assert(previous & sealed == 0);
            if (previous == 0) {
                self.state[index].store(0, .release);
                self.used[index] = 0;
                std.debug.assert(self.free.push(page));
            }
        }

        pub fn publicationCount(self: *const Self) u64 {
            return self.publications;
        }
    };
}

pub const ToCoreKind = enum(u8) {
    input,
    attached,
    detached,
};

pub const ToSessionsKind = enum(u8) {
    packet,
    packet_shared,
    reconfigure,
    disconnect,
    status,
};

pub const Fragment = enum(u8) { whole, begin, continuation, end };

pub const Inbound = struct {
    connection: connection.Handle,
    kind: ToCoreKind,
    fragment: Fragment = .whole,
    total_len: u32 = 0,
    page: Page,
    offset: u32 = 0,
    len: u32,
};

pub const Outbound = struct {
    connection: connection.Handle,
    kind: ToSessionsKind,
    protocol: i32 = 0,
    phase: u8 = 0,
    delivery_class: u8 = 0,
    delivery_policy: u8 = 0,
    fragment: Fragment = .whole,
    total_len: u32 = 0,
    status_revision: u64 = 0,
    recipient_count: u16 = 0,
    page: Page,
    offset: u32 = 0,
    len: u32,
};

pub fn Lane(comptime Message: type, comptime page_count: usize, comptime page_bytes: usize, comptime message_count: usize) type {
    if (!@hasField(Message, "page") or @TypeOf(@field(@as(Message, undefined), "page")) != Page or
        !@hasField(Message, "len") or @TypeOf(@field(@as(Message, undefined), "len")) != u32)
    {
        @compileError("a session exchange lane message needs page: Page and len: u32");
    }
    return struct {
        const Self = @This();
        pub const capacity_bytes = page_bytes;
        pub const message_capacity = message_count;

        pub const Planner = struct {
            remaining: usize,
            pages: usize,
            messages: usize,

            pub fn record(self: *Planner, length: usize) bool {
                if (length == 0 or length > page_bytes or self.messages == 0) return false;
                if (self.remaining < length) {
                    if (self.pages == 0) return false;
                    self.pages -= 1;
                    self.remaining = page_bytes;
                }
                self.remaining -= length;
                self.messages -= 1;
                return true;
            }

            pub fn stream(self: *Planner, length: usize) bool {
                if (length == 0) return false;
                var pending = length;
                while (pending != 0) {
                    if (self.remaining == 0) {
                        if (self.pages == 0) return false;
                        self.pages -= 1;
                        self.remaining = page_bytes;
                    }
                    if (self.messages == 0) return false;
                    const fragment = @min(pending, self.remaining);
                    pending -= fragment;
                    self.remaining -= fragment;
                    self.messages -= 1;
                }
                return true;
            }
        };

        pages: Pages(page_count, page_bytes) = .{},
        messages: Spsc(Message, message_count + 1) = .{},

        pub fn initialize(self: *Self) void {
            self.pages.initialize();
            self.messages = .{};
        }

        pub fn acquire(self: *Self) ?Page {
            if (!self.messages.canPush()) return null;
            return self.pages.acquireProducer(1);
        }

        pub fn acquireFor(self: *Self, minimum: usize) ?Page {
            if (!self.messages.canPush()) return null;
            return self.pages.acquireProducer(minimum);
        }

        pub fn canSubmit(self: *Self, count: usize, bytes: usize) bool {
            return count <= self.messages.availableToPush() and bytes <= self.pages.availableProducerBytes();
        }

        pub fn planner(self: *Self) Planner {
            const pages = self.pages.producerPlan();
            return .{
                .remaining = pages.remaining,
                .pages = pages.pages,
                .messages = self.messages.availableToPush(),
            };
        }

        pub fn canSubmitBytes(self: *Self, bytes: usize) bool {
            return self.canSubmit(self.pages.requiredMessages(bytes), bytes);
        }

        pub fn producerBytes(self: *Self, page: Page) []u8 {
            return self.pages.producerBytes(page);
        }

        pub fn producerOffset(self: *const Self, page: Page) u32 {
            return self.pages.producerOffset(page);
        }

        pub fn submit(self: *Self, message: Message) bool {
            std.debug.assert(message.len <= page_bytes);
            if (!self.messages.canPush()) return false;
            var committed = message;
            committed.offset = self.pages.commitProducer(message.page, message.len);
            return self.messages.push(committed);
        }

        pub fn submitReference(self: *Self, message: Message, offset: u32) bool {
            std.debug.assert(message.len <= page_bytes and offset + message.len <= page_bytes);
            if (!self.messages.canPush()) return false;
            self.pages.retainProducer(message.page);
            var committed = message;
            committed.offset = offset;
            return self.messages.push(committed);
        }

        pub fn receive(self: *Self) ?Message {
            return self.messages.pop();
        }

        pub fn peek(self: *const Self, offset: usize) ?Message {
            return self.messages.peek(offset);
        }

        pub fn consumerBytes(self: *const Self, message: Message) []const u8 {
            return self.pages.consumerBytes(message.page, message.offset, message.len);
        }

        pub fn release(self: *Self, message: Message) bool {
            return self.pages.releaseConsumer(message.page);
        }

        pub fn flush(self: *Self) void {
            self.pages.sealProducer();
        }

        pub fn pendingMessages(self: *const Self) usize {
            return self.messages.availableToPop();
        }

        pub fn publicationCount(self: *const Self) u64 {
            return self.pages.publicationCount();
        }
    };
}

pub fn Exchange(comptime limits: Limits) type {
    if (!limits.valid()) @compileError("invalid session exchange limits");
    return struct {
        const Self = @This();

        to_core: Lane(Inbound, limits.to_core_pages, limits.to_core_page_bytes, limits.to_core_messages) = .{},
        to_sessions: Lane(Outbound, limits.to_sessions_pages, limits.to_sessions_page_bytes, limits.to_sessions_messages) = .{},
        direct_payload_bytes: std.atomic.Value(u64) = .init(0),
        copied_payload_bytes: std.atomic.Value(u64) = .init(0),
        fanout_payload_bytes: std.atomic.Value(u64) = .init(0),
        fanout_deliveries: std.atomic.Value(u64) = .init(0),

        pub fn initialize(self: *Self) void {
            self.to_core.initialize();
            self.to_sessions.initialize();
            self.direct_payload_bytes.store(0, .monotonic);
            self.copied_payload_bytes.store(0, .monotonic);
            self.fanout_payload_bytes.store(0, .monotonic);
            self.fanout_deliveries.store(0, .monotonic);
        }
    };
}

test "SPSC preserves producer order" {
    var queue = Spsc(u16, 4){};
    try std.testing.expect(queue.push(4));
    try std.testing.expect(queue.push(9));
    try std.testing.expectEqual(@as(?u16, 4), queue.pop());
    try std.testing.expect(queue.push(12));
    try std.testing.expectEqual(@as(?u16, 9), queue.pop());
    try std.testing.expectEqual(@as(?u16, 12), queue.pop());
    try std.testing.expect(queue.empty());
}

test "a lane transfers page ownership without payload pointers" {
    const TestLane = Lane(Inbound, 3, 32, 2);
    var lane = TestLane{};
    lane.initialize();
    const page = lane.acquire().?;
    @memcpy(lane.producerBytes(page)[0..4], "core");
    try std.testing.expect(lane.submit(.{ .connection = .{ .index = 1, .generation = 2 }, .kind = .input, .page = page, .len = 4 }));
    const message = lane.receive().?;
    try std.testing.expectEqual(page, message.page);
    try std.testing.expectEqualStrings("core", lane.consumerBytes(message));
    try std.testing.expect(lane.release(message));
    try std.testing.expect(lane.acquire() != null);
}

test "two exchange directions have independent page ownership" {
    const TestExchange = Exchange(.{
        .to_core_pages = 2,
        .to_sessions_pages = 2,
        .to_core_page_bytes = 16,
        .to_sessions_page_bytes = 16,
        .to_core_messages = 1,
        .to_sessions_messages = 1,
    });
    var exchange = TestExchange{};
    exchange.initialize();
    const input_page = exchange.to_core.acquire().?;
    const output_page = exchange.to_sessions.acquire().?;
    @memcpy(exchange.to_core.producerBytes(input_page)[0..2], "in");
    @memcpy(exchange.to_sessions.producerBytes(output_page)[0..3], "out");
    try std.testing.expect(exchange.to_core.submit(.{ .connection = .{ .index = 1, .generation = 1 }, .kind = .input, .page = input_page, .len = 2 }));
    try std.testing.expect(exchange.to_sessions.submit(.{ .connection = .{ .index = 1, .generation = 1 }, .kind = .packet, .page = output_page, .len = 3 }));
    const input = exchange.to_core.receive().?;
    const output = exchange.to_sessions.receive().?;
    try std.testing.expectEqualStrings("in", exchange.to_core.consumerBytes(input));
    try std.testing.expectEqualStrings("out", exchange.to_sessions.consumerBytes(output));
    try std.testing.expect(exchange.to_core.release(input));
    try std.testing.expect(exchange.to_sessions.release(output));
}

test "status updates are owned after Core publication" {
    const TestExchange = Exchange(.{
        .to_core_pages = 1,
        .to_sessions_pages = 1,
        .to_core_page_bytes = 32,
        .to_sessions_page_bytes = 32,
        .to_core_messages = 1,
        .to_sessions_messages = 1,
    });
    var exchange = TestExchange{};
    exchange.initialize();
    const page = exchange.to_sessions.acquire().?;
    @memcpy(exchange.to_sessions.producerBytes(page)[0..16], "{\"text\":\"ready\"}");
    try std.testing.expect(exchange.to_sessions.submit(.{
        .connection = .{ .index = 0, .generation = 0 },
        .kind = .status,
        .status_revision = 9,
        .total_len = 16,
        .page = page,
        .len = 16,
    }));
    const message = exchange.to_sessions.receive().?;
    try std.testing.expectEqual(ToSessionsKind.status, message.kind);
    try std.testing.expectEqual(@as(u64, 9), message.status_revision);
    try std.testing.expectEqualStrings("{\"text\":\"ready\"}", exchange.to_sessions.consumerBytes(message));
    try std.testing.expect(exchange.to_sessions.release(message));
}

test "a full message lane retains producer page ownership" {
    const TestLane = Lane(Outbound, 2, 16, 1);
    var lane = TestLane{};
    lane.initialize();
    const page = lane.acquire().?;
    lane.producerBytes(page)[0] = 1;
    try std.testing.expect(lane.submit(.{ .connection = .{ .index = 9, .generation = 1 }, .kind = .packet, .page = page, .len = 1 }));
    try std.testing.expect(lane.acquire() == null);
    const message = lane.receive().?;
    try std.testing.expect(lane.release(message));
    try std.testing.expect(lane.acquire() != null);
}
