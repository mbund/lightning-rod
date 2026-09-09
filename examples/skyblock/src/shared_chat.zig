const std = @import("std");

pub const maximum_message_bytes = 4_096;

pub const Message = struct {
    sequence: u64 = 0,
    len: u16 = 0,
    bytes: [maximum_message_bytes]u8 = undefined,

    pub fn text(self: *const Message) []const u8 {
        return self.bytes[0..self.len];
    }
};

const Slot = struct {
    ready: std.atomic.Value(bool) = .init(false),
    message: Message = .{},
};

pub const Queue = struct {
    slots: []Slot,
    write: usize = 0,
    read: usize = 0,
    closed: std.atomic.Value(bool) = .init(false),

    pub fn capacity(self: *const Queue) usize {
        return self.slots.len;
    }

    pub fn send(self: *Queue, sequence: u64, text: []const u8) error{ Closed, Full, TooLong }!void {
        if (self.closed.load(.acquire)) return error.Closed;
        if (text.len > maximum_message_bytes) return error.TooLong;
        const slot = &self.slots[self.write];
        if (slot.ready.load(.acquire)) return error.Full;
        slot.message.sequence = sequence;
        slot.message.len = @intCast(text.len);
        @memcpy(slot.message.bytes[0..text.len], text);
        slot.ready.store(true, .release);
        self.write = (self.write + 1) % self.slots.len;
    }

    pub fn receive(self: *Queue) ?*const Message {
        const slot = &self.slots[self.read];
        return if (slot.ready.load(.acquire)) &slot.message else null;
    }

    pub fn release(self: *Queue) void {
        const slot = &self.slots[self.read];
        std.debug.assert(slot.ready.load(.acquire));
        slot.ready.store(false, .release);
        self.read = (self.read + 1) % self.slots.len;
    }

    /// Called by this queue's producer after its final send.
    pub fn close(self: *Queue) void {
        self.closed.store(true, .release);
    }

    pub fn drained(self: *const Queue) bool {
        if (!self.closed.load(.acquire)) return false;
        for (self.slots) |*slot| if (slot.ready.load(.acquire)) return false;
        return true;
    }
};

/// The Core owns outgoing.send and incoming.receive/release. Only the service
/// owner uses the opposite ends. A Core may migrate after its tick has completed.
pub const Endpoint = struct {
    pub const Completion = struct {
        context: *anyopaque,
        finish: *const fn (*anyopaque) void,
    };
    const Retirement = enum(u8) { none, requested, complete };
    outgoing: Queue,
    incoming: Queue,
    missed: std.atomic.Value(u64) = .init(0),
    retirement: std.atomic.Value(Retirement) = .init(.none),
    completion: Completion = undefined,

    pub fn takeMissed(self: *Endpoint) u64 {
        return self.missed.swap(0, .acq_rel);
    }

    pub fn close(self: *Endpoint) void {
        self.outgoing.close();
    }

    /// Transfers both queue ends to the service. The Core must not access them
    /// again; completion releases its context after accepted messages are sent.
    pub fn retire(self: *Endpoint, completion: Completion) void {
        std.debug.assert(self.retirement.load(.monotonic) == .none);
        self.completion = completion;
        self.outgoing.close();
        self.retirement.store(.requested, .release);
    }

    pub fn retired(self: *const Endpoint) bool {
        return self.retirement.load(.acquire) != .requested and self.outgoing.drained() and self.incoming.drained();
    }
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    endpoints: []Endpoint,
    slots: []Slot,
    next: usize = 0,
    sequence: u64 = 0,

    pub fn requiredMemory(maximum_cores: usize, messages_per_core: usize) error{InvalidChatCapacity}!usize {
        if (maximum_cores == 0 or messages_per_core == 0) return error.InvalidChatCapacity;
        const messages = std.math.mul(usize, maximum_cores, messages_per_core) catch return error.InvalidChatCapacity;
        const slots = std.math.mul(usize, messages, 2 * @sizeOf(Slot)) catch return error.InvalidChatCapacity;
        const endpoints = std.math.mul(usize, maximum_cores, @sizeOf(Endpoint)) catch return error.InvalidChatCapacity;
        const storage = std.math.add(usize, slots, endpoints) catch return error.InvalidChatCapacity;
        return std.math.add(usize, storage, @sizeOf(Service)) catch return error.InvalidChatCapacity;
    }

    pub fn init(allocator: std.mem.Allocator, maximum_cores: usize, messages_per_core: usize) !Service {
        _ = try requiredMemory(maximum_cores, messages_per_core);
        const one_direction = maximum_cores * messages_per_core;
        const slot_count = one_direction * 2;
        const endpoints = try allocator.alloc(Endpoint, maximum_cores);
        errdefer allocator.free(endpoints);
        const slots = try allocator.alloc(Slot, slot_count);
        for (slots) |*slot| slot.* = .{};
        for (endpoints, 0..) |*endpoint, index| endpoint.* = .{
            .outgoing = .{ .slots = slots[index * messages_per_core ..][0..messages_per_core] },
            .incoming = .{ .slots = slots[one_direction + index * messages_per_core ..][0..messages_per_core] },
        };
        return .{ .allocator = allocator, .endpoints = endpoints, .slots = slots };
    }

    pub fn deinit(self: *Service) void {
        self.allocator.free(self.slots);
        self.allocator.free(self.endpoints);
        self.* = undefined;
    }

    pub fn memoryBytes(self: *const Service) usize {
        return @sizeOf(Service) + self.slots.len * @sizeOf(Slot) + self.endpoints.len * @sizeOf(Endpoint);
    }

    /// The service owner may reuse a drained endpoint after its Core has stopped.
    pub fn reactivate(self: *Service, index: usize) error{Busy}!void {
        const endpoint = &self.endpoints[index];
        if (!endpoint.retired()) return error.Busy;
        endpoint.retirement.store(.none, .monotonic);
        endpoint.missed.store(0, .monotonic);
        endpoint.incoming.closed.store(false, .release);
        endpoint.outgoing.closed.store(false, .release);
    }

    /// Bounds source examinations, including empty/closing endpoints. Each message
    /// fans out to at most endpoints.len destinations. Zero performs no work.
    pub fn process(self: *Service, maximum_checks: usize) usize {
        var handled: usize = 0;
        var empty: usize = 0;
        var checked: usize = 0;
        while (checked < maximum_checks and empty < self.endpoints.len) : (checked += 1) {
            const source = &self.endpoints[self.next];
            self.next = (self.next + 1) % self.endpoints.len;
            const retiring = source.retirement.load(.acquire) == .requested;
            if (retiring) {
                while (source.incoming.receive() != null) source.incoming.release();
            }
            const closed = source.outgoing.closed.load(.acquire);
            const message = source.outgoing.receive() orelse {
                if (closed) source.incoming.close();
                if (retiring) {
                    const completion = source.completion;
                    source.retirement.store(.complete, .release);
                    completion.finish(completion.context);
                }
                empty += 1;
                continue;
            };
            empty = 0;
            self.sequence += 1;
            for (self.endpoints) |*target| {
                if (target.outgoing.closed.load(.acquire)) continue;
                target.incoming.send(self.sequence, message.text()) catch |err| switch (err) {
                    error.Full => _ = target.missed.fetchAdd(1, .monotonic),
                    error.Closed, error.TooLong => unreachable,
                };
            }
            source.outgoing.release();
            if (closed and source.outgoing.receive() == null) source.incoming.close();
            handled += 1;
        }
        return handled;
    }
};

test "chat owns messages, preserves global order and isolates a stalled Core" {
    try std.testing.expectError(error.InvalidChatCapacity, Service.init(std.testing.allocator, 0, 2));
    try std.testing.expectError(error.InvalidChatCapacity, Service.init(std.testing.allocator, std.math.maxInt(usize), 2));
    var service = try Service.init(std.testing.allocator, 3, 2);
    defer service.deinit();
    try std.testing.expectEqual(try Service.requiredMemory(3, 2), service.memoryBytes());
    const oversized: [maximum_message_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.TooLong, service.endpoints[0].outgoing.send(0, &oversized));
    var text = [_]u8{ 'o', 'n', 'e' };
    try service.endpoints[0].outgoing.send(0, &text);
    @memset(&text, 'x');
    try service.endpoints[1].outgoing.send(0, "two");
    try service.endpoints[0].outgoing.send(0, "three");
    try std.testing.expectError(error.Full, service.endpoints[0].outgoing.send(0, "not admitted"));
    try std.testing.expectEqual(@as(usize, 2), service.process(2));
    for (service.endpoints[1..]) |*endpoint| {
        for ([_][]const u8{ "one", "two" }, 1..) |expected, sequence| {
            const message = endpoint.incoming.receive().?;
            try std.testing.expectEqual(sequence, message.sequence);
            try std.testing.expectEqualStrings(expected, message.text());
            endpoint.incoming.release();
        }
    }
    try std.testing.expectEqual(@as(usize, 1), service.process(2));
    try std.testing.expectEqual(@as(u64, 1), service.endpoints[0].takeMissed());
    try std.testing.expectEqual(@as(u64, 0), service.endpoints[0].takeMissed());
    for (service.endpoints[1..]) |*endpoint| {
        const message = endpoint.incoming.receive().?;
        try std.testing.expectEqual(@as(u64, 3), message.sequence);
        try std.testing.expectEqualStrings("three", message.text());
        endpoint.incoming.release();
    }
    for (0..2) |_| service.endpoints[0].incoming.release();
    try service.endpoints[2].outgoing.send(0, "after wrap");
    try std.testing.expectEqual(@as(usize, 1), service.process(2));
    for (service.endpoints) |*endpoint| {
        try std.testing.expectEqualStrings("after wrap", endpoint.incoming.receive().?.text());
        endpoint.incoming.release();
    }
}

test "sparse chat examination budgets bound scanning and advance retirement" {
    var service = try Service.init(std.testing.allocator, 17, 1);
    defer service.deinit();
    service.endpoints[0].close();
    try service.endpoints[16].outgoing.send(0, "late island");
    try std.testing.expectEqual(@as(usize, 0), service.process(0));
    try std.testing.expectEqual(@as(usize, 0), service.next);
    try std.testing.expect(!service.endpoints[0].retired());
    for (1..5) |round| {
        try std.testing.expectEqual(@as(usize, 0), service.process(4));
        try std.testing.expectEqual(round * 4, service.next);
        try std.testing.expectEqual(@as(u64, 0), service.sequence);
        try std.testing.expect(service.endpoints[16].outgoing.receive() != null);
    }
    try std.testing.expect(service.endpoints[0].retired());
    try std.testing.expectEqual(@as(usize, 1), service.process(1));
    try std.testing.expectEqual(@as(usize, 0), service.next);
    try std.testing.expectEqual(@as(u64, 1), service.sequence);
    try std.testing.expect(service.endpoints[0].incoming.receive() == null);
    for (service.endpoints[1..]) |*endpoint| {
        try std.testing.expectEqualStrings("late island", endpoint.incoming.receive().?.text());
        endpoint.incoming.release();
    }
}

test "retiring chat endpoints drain accepted messages before slot reuse" {
    var service = try Service.init(std.testing.allocator, 2, 2);
    defer service.deinit();
    const retiring = &service.endpoints[0];
    const active = &service.endpoints[1];
    try active.outgoing.send(0, "before retirement");
    try std.testing.expectEqual(@as(usize, 1), service.process(2));
    active.incoming.release();
    try retiring.outgoing.send(0, "accepted before close");
    retiring.close();
    try std.testing.expectError(error.Closed, retiring.outgoing.send(0, "rejected"));
    try std.testing.expectError(error.Busy, service.reactivate(0));
    try active.outgoing.send(0, "after retirement");
    try std.testing.expectEqual(@as(usize, 2), service.process(2));
    try std.testing.expect(!retiring.retired());
    try std.testing.expectEqualStrings("accepted before close", active.incoming.receive().?.text());
    active.incoming.release();
    try std.testing.expectEqualStrings("after retirement", active.incoming.receive().?.text());
    active.incoming.release();
    _ = service.process(service.endpoints.len);
    try std.testing.expect(retiring.incoming.closed.load(.acquire));
    try std.testing.expectError(error.Busy, service.reactivate(0));
    try std.testing.expectEqualStrings("before retirement", retiring.incoming.receive().?.text());
    retiring.incoming.release();
    try std.testing.expect(retiring.retired());
    try service.reactivate(0);
    try retiring.outgoing.send(0, "new island");
    try std.testing.expectEqual(@as(usize, 1), service.process(2));
    for (service.endpoints) |*endpoint| {
        try std.testing.expectEqualStrings("new island", endpoint.incoming.receive().?.text());
        endpoint.incoming.release();
        try std.testing.expectEqual(@as(?*const Message, null), endpoint.incoming.receive());
    }
}

test "chat retirement transfers queue ownership until the completion callback" {
    const Observer = struct {
        completions: usize = 0,
        fn finish(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.completions += 1;
        }
    };
    var service = try Service.init(std.testing.allocator, 2, 2);
    defer service.deinit();
    const retiring = &service.endpoints[0];
    const active = &service.endpoints[1];
    try active.outgoing.send(0, "old incoming");
    _ = service.process(2);
    active.incoming.release();
    try retiring.outgoing.send(0, "final one");
    try retiring.outgoing.send(0, "final two");
    var observer = Observer{};
    retiring.retire(.{ .context = &observer, .finish = Observer.finish });
    try std.testing.expectError(error.Closed, retiring.outgoing.send(0, "too late"));
    try std.testing.expectError(error.Busy, service.reactivate(0));
    _ = service.process(0);
    try std.testing.expectEqual(@as(usize, 0), observer.completions);
    for ([_][]const u8{ "final one", "final two" }) |expected| {
        try std.testing.expectEqual(@as(usize, 1), service.process(2));
        try std.testing.expectEqualStrings(expected, active.incoming.receive().?.text());
        active.incoming.release();
        try std.testing.expectEqual(@as(usize, 0), observer.completions);
        try std.testing.expect(!retiring.retired());
    }
    try active.outgoing.send(0, "other Core continues");
    try std.testing.expectEqual(@as(usize, 1), service.process(2));
    try std.testing.expectEqual(@as(usize, 1), observer.completions);
    try std.testing.expect(retiring.retired());
    try std.testing.expect(retiring.incoming.receive() == null);
    active.incoming.release();
    _ = service.process(4);
    try std.testing.expectEqual(@as(usize, 1), observer.completions);
    try service.reactivate(0);
    try retiring.outgoing.send(0, "replacement Core");
    _ = service.process(2);
    try std.testing.expectEqualStrings("replacement Core", retiring.incoming.receive().?.text());
}

test "independent Core producers and consumers share one ordered chat service" {
    const Worker = struct {
        endpoint: *Endpoint,
        stop: *std.atomic.Value(bool),
        done: std.atomic.Value(bool) = .init(false),
        ordered: bool = true,
        received: u64 = 0,
        missed: u64 = 0,

        fn finish(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.done.store(true, .release);
        }

        fn run(self: *@This()) void {
            var sent: usize = 0;
            var previous: u64 = 0;
            while (!self.stop.load(.acquire)) {
                if (sent != 200) {
                    if (self.endpoint.outgoing.send(0, "shared")) {
                        sent += 1;
                    } else |_| {}
                }
                while (self.endpoint.incoming.receive()) |message| {
                    self.ordered = self.ordered and message.sequence > previous and std.mem.eql(u8, message.text(), "shared");
                    previous = message.sequence;
                    self.received += 1;
                    self.endpoint.incoming.release();
                }
                self.missed += self.endpoint.takeMissed();
                if (sent == 200 and self.received + self.missed == 400) {
                    self.endpoint.retire(.{ .context = self, .finish = finish });
                    return;
                }
                std.Thread.yield() catch {};
            }
        }
    };
    var service = try Service.init(std.testing.allocator, 2, 4);
    defer service.deinit();
    var stop = std.atomic.Value(bool).init(false);
    var workers = [_]Worker{
        .{ .endpoint = &service.endpoints[0], .stop = &stop },
        .{ .endpoint = &service.endpoints[1], .stop = &stop },
    };
    var threads: [2]?std.Thread = @splat(null);
    defer {
        stop.store(true, .release);
        for (&threads) |*thread| if (thread.*) |value| value.join();
    }
    for (&workers, &threads) |*worker, *thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
    const started = std.Io.Clock.awake.now(std.testing.io).toNanoseconds();
    while (std.Io.Clock.awake.now(std.testing.io).toNanoseconds() - started < 5 * std.time.ns_per_s) {
        _ = service.process(8);
        if (workers[0].done.load(.acquire) and workers[1].done.load(.acquire)) break;
        std.Thread.yield() catch {};
    }
    stop.store(true, .release);
    for (&threads) |*thread| {
        thread.*.?.join();
        thread.* = null;
    }
    try std.testing.expectEqual(@as(u64, 400), service.sequence);
    _ = service.process(service.endpoints.len);
    for (workers) |worker| {
        try std.testing.expect(worker.done.load(.acquire));
        try std.testing.expect(worker.ordered);
        try std.testing.expectEqual(@as(u64, 400), worker.received + worker.missed);
        try std.testing.expect(worker.endpoint.retired());
    }
}
