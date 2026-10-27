const std = @import("std");

pub fn Mailbox(comptime Request: type) type {
    return struct {
        const Self = @This();
        pub const Call = struct {
            request: Request,
            completed: std.Io.Event = .unset,
            delivered: bool = false,
            claimed: bool = false,
            next: ?*Call = null,
        };

        io: std.Io = undefined,
        creator: std.Thread.Id = 0,
        owner: std.atomic.Value(std.Thread.Id) = .init(0),
        lifecycle: std.Io.Mutex = .init,
        ready: std.Io.Event = .unset,
        notification: ?*std.Io.Event = null,
        space: std.atomic.Value(u32) = .init(0),
        space_waiters: usize = 0,
        first: ?*Call = null,
        last: ?*Call = null,
        count: usize = 0,

        pub fn init(self: *Self, io: std.Io) void {
            self.* = .{ .io = io, .creator = if (self.creator == 0) std.Thread.getCurrentId() else self.creator, .notification = self.notification };
        }

        pub fn start(self: *Self) void {
            self.owner.store(std.Thread.getCurrentId(), .release);
        }

        pub fn stop(self: *Self) void {
            self.lifecycle.lockUncancelable(self.io);
            defer self.lifecycle.unlock(self.io);
            self.owner.store(0, .release);
            self.signalSpace();
            while (self.take()) |pending| {
                pending.completed.set(self.io);
            }
        }

        pub fn remote(self: *const Self) bool {
            const owner = self.owner.load(.acquire);
            return (if (owner == 0) self.creator else owner) != std.Thread.getCurrentId();
        }

        /// The caller retains its request and borrowed buffers until completion.
        pub fn call(self: *Self, request: *Call) error{Closed}!bool {
            return self.callBefore(request, null) catch |err| switch (err) {
                error.Closed => return error.Closed,
                error.Timeout => unreachable,
            };
        }

        pub fn callBefore(self: *Self, request: *Call, deadline: ?std.Io.Clock.Timestamp) error{ Closed, Timeout }!bool {
            if (!self.remote()) return false;
            const timeout: std.Io.Timeout = if (deadline) |until| .{ .deadline = until } else .none;
            while (true) {
                self.lifecycle.lockUncancelable(self.io);
                if (self.owner.load(.acquire) == 0) {
                    self.lifecycle.unlock(self.io);
                    return error.Closed;
                }
                if (deadline) |until| {
                    if (std.Io.Clock.Timestamp.now(self.io, until.clock).raw.nanoseconds >= until.raw.nanoseconds) {
                        self.lifecycle.unlock(self.io);
                        return error.Timeout;
                    }
                }
                if (self.count < 64) break;
                self.space_waiters += 1;
                const epoch = self.space.load(.monotonic);
                self.lifecycle.unlock(self.io);
                self.io.futexWaitTimeout(u32, &self.space.raw, epoch, timeout) catch {};
                self.lifecycle.lockUncancelable(self.io);
                self.space_waiters -= 1;
                self.lifecycle.unlock(self.io);
            }
            if (self.last) |last| last.next = request else self.first = request;
            self.last = request;
            self.count += 1;
            self.ready.set(self.io);
            if (self.notification) |event| event.set(self.io);
            self.lifecycle.unlock(self.io);
            while (true) {
                request.completed.waitTimeout(self.io, timeout) catch |err| switch (err) {
                    error.Canceled => request.completed.waitUncancelable(self.io),
                    error.Timeout => {
                        const until = deadline orelse continue;
                        if (std.Io.Clock.Timestamp.now(self.io, until.clock).raw.nanoseconds < until.raw.nanoseconds) continue;
                        self.lifecycle.lockUncancelable(self.io);
                        if (!request.claimed) {
                            var link = &self.first;
                            var previous: ?*Call = null;
                            while (link.* != request) {
                                previous = link.*.?;
                                link = &previous.?.next;
                            }
                            link.* = request.next;
                            if (self.last == request) self.last = previous;
                            self.count -= 1;
                            self.signalSpace();
                        }
                        const claimed = request.claimed;
                        self.lifecycle.unlock(self.io);
                        // An executing request still owns the caller's borrowed memory.
                        if (claimed) request.completed.waitUncancelable(self.io);
                        return error.Timeout;
                    },
                };
                break;
            }
            if (!request.delivered) return error.Closed;
            return true;
        }

        pub fn next(self: *Self) ?*Call {
            self.lifecycle.lockUncancelable(self.io);
            defer self.lifecycle.unlock(self.io);
            return self.take();
        }

        fn take(self: *Self) ?*Call {
            const request = self.first orelse return null;
            self.first = request.next;
            if (self.first == null) self.last = null;
            self.count -= 1;
            request.claimed = true;
            self.signalSpace();
            return request;
        }

        fn signalSpace(self: *Self) void {
            if (self.space_waiters == 0) return;
            _ = self.space.fetchAdd(1, .release);
            self.io.futexWake(u32, &self.space.raw, std.math.maxInt(u32));
        }

        pub fn complete(self: *Self, call_: *Call) void {
            call_.delivered = true;
            call_.completed.set(self.io);
        }
    };
}

test "stopping a mailbox releases a caller whose request has not executed" {
    const Request = struct {};
    const Channel = Mailbox(Request);
    const Caller = struct {
        channel: *Channel,
        call_: Channel.Call = .{ .request = .{} },
        result: error{Closed}!bool = false,
        fn run(self: *@This()) void {
            self.result = self.channel.call(&self.call_);
        }
    };
    var channel: Channel = .{};
    channel.init(std.testing.io);
    channel.start();
    var caller: Caller = .{ .channel = &channel };
    const thread = try std.Thread.spawn(.{}, Caller.run, .{&caller});
    channel.ready.waitUncancelable(std.testing.io);
    channel.stop();
    thread.join();
    try std.testing.expectError(error.Closed, caller.result);
}

test "a mailbox deadline removes a queued request before returning its memory" {
    const Channel = Mailbox(struct {});
    const Caller = struct {
        channel: *Channel,
        result: error{ Closed, Timeout }!bool = false,
        fn run(self: *@This()) void {
            var request: Channel.Call = .{ .request = .{} };
            self.result = self.channel.callBefore(&request, .{
                .clock = .awake,
                .raw = .{ .nanoseconds = std.Io.Clock.now(.awake, std.testing.io).nanoseconds + std.time.ns_per_ms },
            });
        }
    };
    var channel: Channel = .{};
    channel.init(std.testing.io);
    channel.start();
    defer channel.stop();
    var caller: Caller = .{ .channel = &channel };
    const thread = try std.Thread.spawn(.{}, Caller.run, .{&caller});
    thread.join();
    try std.testing.expectError(error.Timeout, caller.result);
    try std.testing.expectEqual(@as(usize, 0), channel.count);
    try std.testing.expectEqual(null, channel.next());
}

test "a full mailbox respects the admission deadline" {
    const Channel = Mailbox(struct {});
    const Caller = struct {
        channel: *Channel,
        result: error{ Closed, Timeout }!bool = false,
        fn run(self: *@This()) void {
            var request: Channel.Call = .{ .request = .{} };
            self.result = self.channel.callBefore(&request, .{
                .clock = .awake,
                .raw = .{ .nanoseconds = std.Io.Clock.now(.awake, std.testing.io).nanoseconds + std.time.ns_per_ms },
            });
        }
    };
    var channel: Channel = .{};
    channel.init(std.testing.io);
    channel.start();
    var requests: [64]Channel.Call = @splat(.{ .request = .{} });
    for (requests[0..63], 1..) |*request, index| request.next = &requests[index];
    channel.first = &requests[0];
    channel.last = &requests[63];
    channel.count = requests.len;
    defer channel.stop();
    var caller: Caller = .{ .channel = &channel };
    const thread = try std.Thread.spawn(.{}, Caller.run, .{&caller});
    thread.join();
    try std.testing.expectError(error.Timeout, caller.result);
    try std.testing.expectEqual(requests.len, channel.count);
}

test "a claimed request retains its borrowed memory until acknowledgment" {
    const Channel = Mailbox(struct { value: *u32 });
    const Caller = struct {
        channel: *Channel,
        returned: std.Io.Event = .unset,
        result: error{ Closed, Timeout }!bool = false,
        value: u32 = 0,
        fn run(self: *@This()) void {
            defer self.returned.set(std.testing.io);
            var request: Channel.Call = .{ .request = .{ .value = &self.value } };
            self.result = self.channel.callBefore(&request, .{
                .clock = .awake,
                .raw = .{ .nanoseconds = std.Io.Clock.now(.awake, std.testing.io).nanoseconds + 100 * std.time.ns_per_ms },
            });
        }
    };
    var channel: Channel = .{};
    channel.init(std.testing.io);
    channel.start();
    defer channel.stop();
    var caller: Caller = .{ .channel = &channel };
    const thread = try std.Thread.spawn(.{}, Caller.run, .{&caller});
    channel.ready.waitUncancelable(std.testing.io);
    const request = channel.next() orelse {
        thread.join();
        return error.RequestExpiredBeforeExecution;
    };
    std.Io.sleep(std.testing.io, .fromMilliseconds(200), .awake) catch {};
    const retained = !caller.returned.isSet();
    request.request.value.* = 42;
    channel.complete(request);
    thread.join();
    try std.testing.expect(retained);
    try std.testing.expectError(error.Timeout, caller.result);
    try std.testing.expectEqual(@as(u32, 42), caller.value);
}
