const std = @import("std");
const accounts = @import("ledger.zig");
const runtime = @import("lightning_rod").runtime;

pub const Name = struct {
    bytes: [accounts.maximum_name_bytes]u8 = @splat(0),
    len: u8,

    pub fn init(value: []const u8) error{InvalidName}!Name {
        if (value.len == 0 or value.len > accounts.maximum_name_bytes) return error.InvalidName;
        var name = Name{ .len = @intCast(value.len) };
        @memcpy(name.bytes[0..value.len], value);
        return name;
    }
};

pub const Operation = union(enum) {
    ensure: struct { uuid: u128, name: Name },
    balance: u128,
    ranking: void,
    deposit: struct { uuid: u128, name: Name, amount: u128 },
    withdraw: struct { uuid: u128, amount: u128 },
    transfer: struct { sender: u128, recipient: u128, amount: u128 },
    transfer_named: struct { sender: u128, recipient: Name, amount: u128 },
    reserve: struct { uuid: u128, amount: u128 },
    commit: u64,
    cancel: u64,
};
pub const Failure = error{ InvalidName, AccountCapacity, InsufficientFunds, InvalidAmount, CannotPaySelf, UnknownAccount, AmbiguousAccount, Overflow, ReservationCapacity, UnknownReservation };
pub const Ranked = struct { name: Name, balance: u128 };
pub const Ranking = struct { entries: [10]Ranked = @splat(.{ .name = .{ .len = 0 }, .balance = 0 }), count: u8 = 0 };
pub const Balances = struct { account: u128, recipient: u128 = 0, reservation: u64 = 0, ranking: Ranking = .{} };
pub const Reply = struct { id: u64, result: Failure!Balances };
const State = enum(u8) { free, submitted, complete };

pub const Slot = struct {
    state: std.atomic.Value(State) = .init(.free),
    id: u64 = 0,
    operation: Operation = undefined,
    result: Failure!Balances = undefined,
};

pub const Hold = struct {
    id: u64 = 0,
    owner: usize = 0,
    uuid: u128 = 0,
    amount: u128 = 0,
};

/// One producer owns submit/poll/ack/close; one service owner owns process.
/// Migrate the producer only after its previous Core tick has completed.
pub const Queue = struct {
    slots: []Slot,
    producer_write: usize = 0,
    producer_read: usize = 0,
    consumer_read: usize = 0,
    last_id: u64 = 0,
    closed: std.atomic.Value(bool) = .init(false),

    pub fn init(slots: []Slot) Queue {
        std.debug.assert(slots.len != 0);
        for (slots) |*slot| slot.* = .{};
        return .{ .slots = slots };
    }

    pub fn submit(self: *Queue, id: u64, operation: Operation) error{ Closed, InvalidId, AlreadySubmitted, Full }!void {
        if (self.closed.load(.acquire)) switch (operation) {
            .commit, .cancel => {},
            else => return error.Closed,
        };
        if (id == 0) return error.InvalidId;
        if (id <= self.last_id) return error.AlreadySubmitted;
        const slot = &self.slots[self.producer_write];
        if (slot.state.load(.acquire) != .free) return error.Full;
        slot.id = id;
        slot.operation = operation;
        slot.state.store(.submitted, .release);
        self.last_id = id;
        self.producer_write = (self.producer_write + 1) % self.slots.len;
    }

    pub fn poll(self: *Queue) ?Reply {
        const slot = &self.slots[self.producer_read];
        if (slot.state.load(.acquire) != .complete) return null;
        return .{ .id = slot.id, .result = slot.result };
    }

    pub fn ack(self: *Queue, id: u64) void {
        const slot = &self.slots[self.producer_read];
        std.debug.assert(slot.state.load(.acquire) == .complete and slot.id == id);
        slot.state.store(.free, .release);
        self.producer_read = (self.producer_read + 1) % self.slots.len;
    }

    /// Stop new transactions; outstanding holds still require commit or cancel.
    pub fn close(self: *Queue) void {
        self.closed.store(true, .release);
    }

    /// The owner must retain the queue and consume every reply before freeing it.
    pub fn drained(self: *const Queue) bool {
        if (!self.closed.load(.acquire)) return false;
        for (self.slots) |*slot| if (slot.state.load(.acquire) != .free) return false;
        return true;
    }
};

pub const Service = struct {
    /// The whole service is allocated once by the coordinator at startup.  A
    /// producer owns exactly one Client and therefore exactly one queue.
    pub const Configuration = struct {
        maximum_accounts: usize,
        maximum_producers: usize,
        requests_per_producer: usize,
        maximum_holds: usize,
        process_examinations_per_tick: usize = 64,

        pub fn validate(self: Configuration) !void {
            if (self.maximum_accounts == 0 or self.maximum_accounts > std.math.maxInt(u16)) return error.InvalidAccountCapacity;
            if (self.maximum_producers == 0) return error.InvalidProducerCapacity;
            if (self.requests_per_producer == 0) return error.InvalidRequestCapacity;
            if (self.process_examinations_per_tick == 0) return error.InvalidProcessBudget;
            _ = try std.math.mul(usize, self.maximum_producers, self.requests_per_producer);
        }

        /// Bytes for accounts, producer queues, request slots and holds.  The
        /// ledger checkpoint buffer is deliberately owned by the persistence
        /// adapter, not hidden in this service reservation.
        pub fn memoryRequired(self: Configuration) !usize {
            try self.validate();
            const slots = try std.math.mul(usize, self.maximum_producers, self.requests_per_producer);
            var total = try std.math.mul(usize, self.maximum_accounts, @sizeOf(accounts.Account));
            total = try std.math.add(usize, total, try std.math.mul(usize, self.maximum_producers, @sizeOf(Queue)));
            total = try std.math.add(usize, total, try std.math.mul(usize, slots, @sizeOf(Slot)));
            return std.math.add(usize, total, try std.math.mul(usize, self.maximum_holds, @sizeOf(Hold)));
        }

    };

    pub const Storage = struct {
        accounts: []accounts.Account,
        queues: []Queue,
        slots: []Slot,
        holds: []Hold,
    };

    ledger: accounts.Ledger,
    queues: []Queue,
    holds: []Hold,
    next_queue: usize = 0,
    process_examinations_per_tick: usize,
    wake: ?runtime.Wake = null,

    pub fn init(configuration: Configuration, storage: Storage) !Service {
        try configuration.validate();
        const slot_count = try std.math.mul(usize, configuration.maximum_producers, configuration.requests_per_producer);
        if (storage.accounts.len != configuration.maximum_accounts or
            storage.queues.len != configuration.maximum_producers or
            storage.slots.len != slot_count or
            storage.holds.len != configuration.maximum_holds)
            return error.InvalidStorage;
        for (storage.queues, 0..) |*queue, index| {
            const first = index * configuration.requests_per_producer;
            queue.* = Queue.init(storage.slots[first..][0..configuration.requests_per_producer]);
        }
        @memset(storage.holds, .{});
        return .{
            .ledger = accounts.Ledger.init(storage.accounts),
            .queues = storage.queues,
            .holds = storage.holds,
            .process_examinations_per_tick = configuration.process_examinations_per_tick,
        };
    }

    /// A runtime auxiliary backend. `complete` executes a bounded owner pass;
    /// producers signal its readiness when they admit a request.
    pub fn backend(self: *Service) runtime.Backend {
        return .{ .context = self, .vtable = &backend_vtable, .readiness = .{ .context = self, .bind_fn = bindReadiness } };
    }

    fn from(raw: *anyopaque) *Service {
        return @ptrCast(@alignCast(raw));
    }

    fn bindReadiness(raw: *anyopaque, wake: runtime.Wake) runtime.Outcome {
        const self = from(raw);
        if (self.wake != null) return .failed;
        self.wake = wake;
        return .ok;
    }

    fn completeBackend(raw: *anyopaque, _: std.Io, limit: usize) runtime.Completion {
        const self = from(raw);
        return .{ .count = self.process(@min(limit, self.process_examinations_per_tick)) };
    }

    fn backendOk(_: *anyopaque, _: std.Io) runtime.Outcome {
        return .ok;
    }

    fn backendProgress(_: *anyopaque) runtime.Progress {
        // Shutdown/settlement policy belongs to the coordinator.  Reporting
        // complete here must not be mistaken for economic checkpointing.
        return .complete;
    }

    const backend_vtable: runtime.Backend.VTable = .{
        .complete = completeBackend,
        .submit = backendOk,
        .begin_shutdown = backendOk,
        .shutdown_progress = backendProgress,
    };

    pub fn available(self: *Service, uuid: u128) u128 {
        var result = self.ledger.balance(uuid);
        for (self.holds) |hold| if (hold.id != 0 and hold.uuid == uuid) {
            result -= hold.amount;
        };
        return result;
    }

    pub fn retired(self: *const Service, owner: usize) bool {
        if (!self.queues[owner].drained()) return false;
        for (self.holds) |hold| if (hold.id != 0 and hold.owner == owner) return false;
        return true;
    }

    /// Called by the service owner after the previous producer has stopped.
    pub fn reactivate(self: *Service, owner: usize) error{ Busy, RequestIdExhausted }!u64 {
        if (!self.retired(owner)) return error.Busy;
        const queue = &self.queues[owner];
        const next_id = std.math.add(u64, queue.last_id, 1) catch return error.RequestIdExhausted;
        queue.closed.store(false, .release);
        return next_id;
    }

    /// Returns completed requests; zero does not imply that unexamined queues are empty.
    pub fn process(self: *Service, maximum_examinations: usize) usize {
        var processed: usize = 0;
        var idle: usize = 0;
        var examined: usize = 0;
        while (examined < maximum_examinations and idle < self.queues.len) : (examined += 1) {
            const owner = self.next_queue;
            const queue = &self.queues[owner];
            self.next_queue = (self.next_queue + 1) % self.queues.len;
            const slot = &queue.slots[queue.consumer_read];
            if (slot.state.load(.acquire) != .submitted) {
                idle += 1;
                continue;
            }
            slot.result = switch (slot.operation) {
                .ensure => |op| ensure: {
                    if (op.name.len == 0 or op.name.len > op.name.bytes.len) break :ensure error.InvalidName;
                    self.ledger.ensure(op.uuid, op.name.bytes[0..op.name.len]) catch |err| break :ensure err;
                    break :ensure Balances{ .account = self.available(op.uuid) };
                },
                .balance => |uuid| Balances{ .account = self.available(uuid) },
                .ranking => ranking: {
                    var result: Ranking = .{};
                    for (self.ledger.accounts[0..self.ledger.account_count]) |account| {
                        var insert: usize = 0;
                        while (insert < result.count and result.entries[insert].balance >= account.balance) : (insert += 1) {}
                        if (insert >= result.entries.len) continue;
                        var index: usize = @min(@as(usize, result.count), result.entries.len - 1);
                        while (index > insert) : (index -= 1) result.entries[index] = result.entries[index - 1];
                        result.entries[insert] = .{ .name = .{ .bytes = account.name, .len = account.name_len }, .balance = account.balance };
                        if (result.count < result.entries.len) result.count += 1;
                    }
                    break :ranking Balances{ .account = 0, .ranking = result };
                },
                .deposit => |op| deposit: {
                    if (op.name.len == 0 or op.name.len > op.name.bytes.len) break :deposit error.InvalidName;
                    self.ledger.deposit(op.uuid, op.name.bytes[0..op.name.len], op.amount) catch |err| break :deposit err;
                    break :deposit Balances{ .account = self.available(op.uuid) };
                },
                .withdraw => |op| withdraw: {
                    if (self.available(op.uuid) < op.amount) break :withdraw error.InsufficientFunds;
                    self.ledger.withdraw(op.uuid, op.amount) catch |err| break :withdraw err;
                    break :withdraw Balances{ .account = self.available(op.uuid) };
                },
                .transfer => |op| transfer: {
                    if (self.available(op.sender) < op.amount) break :transfer error.InsufficientFunds;
                    self.ledger.transfer(op.sender, op.recipient, op.amount) catch |err| break :transfer err;
                    break :transfer Balances{ .account = self.available(op.sender), .recipient = self.available(op.recipient) };
                },
                .transfer_named => |op| transfer: {
                    if (op.recipient.len == 0 or op.recipient.len > op.recipient.bytes.len) break :transfer error.InvalidName;
                    const recipient = (self.ledger.findByName(op.recipient.bytes[0..op.recipient.len]) catch |err| break :transfer err) orelse break :transfer error.UnknownAccount;
                    if (self.available(op.sender) < op.amount) break :transfer error.InsufficientFunds;
                    self.ledger.transfer(op.sender, recipient, op.amount) catch |err| break :transfer err;
                    break :transfer Balances{ .account = self.available(op.sender), .recipient = self.available(recipient) };
                },
                .reserve => |op| reserve: {
                    if (op.amount == 0) break :reserve error.InvalidAmount;
                    const balance = self.available(op.uuid);
                    if (balance < op.amount) break :reserve error.InsufficientFunds;
                    for (self.holds) |*hold| if (hold.id == 0) {
                        hold.* = .{ .id = slot.id, .owner = owner, .uuid = op.uuid, .amount = op.amount };
                        break :reserve Balances{ .account = balance - op.amount, .reservation = slot.id };
                    };
                    break :reserve error.ReservationCapacity;
                },
                .commit, .cancel => |id| finish: {
                    for (self.holds) |*hold| if (hold.id == id and hold.id != 0 and hold.owner == owner) {
                        const uuid = hold.uuid;
                        if (slot.operation == .commit)
                            self.ledger.withdraw(uuid, hold.amount) catch unreachable;
                        hold.* = .{};
                        break :finish Balances{ .account = self.available(uuid) };
                    };
                    break :finish error.UnknownReservation;
                },
            };
            queue.consumer_read = (queue.consumer_read + 1) % queue.slots.len;
            slot.state.store(.complete, .release);
            processed += 1;
            idle = 0;
        }
        return processed;
    }
};

/// Core-side endpoint.  It contains no ledger or account data.  All plugins in
/// one Core share this one client and must only use it from that Core's tick.
pub const Client = struct {
    const RequestState = enum(u8) { free, pending, complete };

    /// These are producer-owned reply slots, distinct from the owner-owned
    /// queue.  They let dependency plugins share one Core client without one
    /// plugin accidentally consuming another plugin's reply.
    pub const Request = struct {
        id: u64 = 0,
        result: Failure!Balances = undefined,
        state: RequestState = .free,
    };

    pub const Configuration = struct {
        queue: *Queue,
        service: *Service,
        requests: []Request,
        first_request_id: u64,

        pub fn validate(self: Configuration) !void {
            if (self.first_request_id == 0) return error.InvalidRequestId;
            if (self.requests.len == 0) return error.InvalidRequestCapacity;
        }

        pub fn memoryRequired(request_capacity: usize) !usize {
            if (request_capacity == 0) return error.InvalidRequestCapacity;
            return std.math.mul(usize, request_capacity, @sizeOf(Request));
        }
    };

    pub const Ticket = struct { id: u64 };

    queue: *Queue,
    service: *Service,
    requests: []Request,
    next_request_id: u64,

    pub fn init(configuration: Configuration) !Client {
        try configuration.validate();
        for (configuration.requests) |*request| request.* = .{};
        return .{
            .queue = configuration.queue,
            .service = configuration.service,
            .requests = configuration.requests,
            .next_request_id = configuration.first_request_id,
        };
    }

    pub fn submit(self: *Client, operation: Operation) error{ Closed, InvalidId, AlreadySubmitted, Full, RequestIdExhausted, RequestCapacity }!Ticket {
        if (self.next_request_id == 0) return error.RequestIdExhausted;
        const request = for (self.requests) |*item| {
            if (item.state == .free) break item;
        } else return error.RequestCapacity;
        const id = self.next_request_id;
        try self.queue.submit(id, operation);
        request.* = .{ .id = id, .state = .pending };
        self.next_request_id = std.math.add(u64, id, 1) catch 0;
        if (self.next_request_id == 0) self.queue.close();
        if (self.service.wake) |wake| wake.signal();
        return .{ .id = id };
    }

    pub fn poll(self: *Client, ticket: Ticket) ?Failure!Balances {
        self.drainReplies();
        for (self.requests) |*request| if (request.id == ticket.id and request.state == .complete)
            return request.result;
        return null;
    }

    pub fn ack(self: *Client, ticket: Ticket) void {
        for (self.requests) |*request| if (request.id == ticket.id) {
            std.debug.assert(request.state == .complete);
            request.* = .{};
            return;
        };
        unreachable;
    }

    /// Call once per Core tick before consumers poll.  Calling from `poll` as
    /// well keeps a simple client useful to small plugins.
    pub fn drainReplies(self: *Client) void {
        while (self.queue.poll()) |reply| {
            for (self.requests) |*request| if (request.id == reply.id and request.state == .pending) {
                request.result = reply.result;
                request.state = .complete;
                self.queue.ack(reply.id);
                break;
            } else unreachable;
        }
    }
};

fn testService(storage: []accounts.Account, queues: []Queue, holds: []Hold) Service {
    @memset(holds, .{});
    return .{
        .ledger = accounts.Ledger.init(storage),
        .queues = queues,
        .holds = holds,
        .process_examinations_per_tick = queues.len,
    };
}

test "sparse Core queues obey the examination budget without starving late queues" {
    var storage: [1]accounts.Account = undefined;
    var slots: [17][2]Slot = undefined;
    var queues: [17]Queue = undefined;
    for (&queues, &slots) |*queue, *slot| queue.* = Queue.init(slot);
    var service = testService(&storage, &queues, &.{});
    try queues[16].submit(1, .{ .deposit = .{ .uuid = 11, .name = try Name.init("alice"), .amount = 5 } });
    try queues[16].submit(2, .{ .balance = 11 });
    try std.testing.expectEqual(@as(usize, 0), service.process(0));
    try std.testing.expectEqual(@as(usize, 0), service.next_queue);
    for (1..5) |pass| {
        try std.testing.expectEqual(@as(usize, 0), service.process(4));
        try std.testing.expectEqual(pass * 4, service.next_queue);
        try std.testing.expect(queues[16].poll() == null);
    }
    try std.testing.expectEqual(@as(usize, 1), service.process(4));
    try std.testing.expectEqual(@as(usize, 3), service.next_queue);
    try std.testing.expectEqual(@as(u128, 5), (try queues[16].poll().?.result).account);
    queues[16].ack(1);
    try std.testing.expect(queues[16].poll() == null);
    try std.testing.expectEqual(@as(usize, 1), service.process(17));
    try std.testing.expectEqual(@as(u64, 2), queues[16].poll().?.id);
    queues[16].ack(2);
}

test "queued transfers are atomic, retained, deduplicated, and isolated from a stalled client" {
    var storage: [2]accounts.Account = undefined;
    var first_slots: [2]Slot = undefined;
    var second_slots: [1]Slot = undefined;
    var queues = [_]Queue{ Queue.init(&first_slots), Queue.init(&second_slots) };
    var service = testService(&storage, &queues, &.{});
    const first = &queues[0];
    const second = &queues[1];
    try first.submit(1, .{ .deposit = .{ .uuid = 11, .name = try Name.init("alice"), .amount = 100 } });
    try second.submit(1, .{ .ensure = .{ .uuid = 22, .name = try Name.init("bob") } });
    try std.testing.expect(first.poll() == null);
    try std.testing.expectEqual(@as(usize, 2), service.process(10));
    try std.testing.expectEqual(@as(u128, 100), (try first.poll().?.result).account);
    second.ack(1);
    try first.submit(2, .{ .transfer_named = .{ .sender = 11, .recipient = try Name.init("BoB"), .amount = 25 } });
    try std.testing.expectError(error.AlreadySubmitted, first.submit(2, .{ .withdraw = .{ .uuid = 11, .amount = 99 } }));
    try std.testing.expectError(error.Full, first.submit(3, .{ .balance = 11 }));
    try std.testing.expectEqual(@as(usize, 1), service.process(10));
    try second.submit(2, .{ .withdraw = .{ .uuid = 22, .amount = 100 } });
    try std.testing.expectEqual(@as(usize, 1), service.process(10));
    try std.testing.expectError(error.InsufficientFunds, second.poll().?.result);
    second.ack(2);
    try std.testing.expectError(error.AlreadySubmitted, second.submit(1, .{ .deposit = .{ .uuid = 22, .name = try Name.init("bob"), .amount = 999 } }));
    try std.testing.expectEqual(@as(u128, 75), service.ledger.balance(11));
    try std.testing.expectEqual(@as(u128, 25), service.ledger.balance(22));
    first.close();
    try std.testing.expect(!first.drained());
    first.ack(1);
    const transfer = first.poll().?;
    try std.testing.expectEqual(@as(u64, 2), transfer.id);
    try std.testing.expectEqual(@as(u128, 75), (try transfer.result).account);
    first.ack(2);
    try std.testing.expect(first.drained());
    try std.testing.expectError(error.Closed, first.submit(3, .{ .balance = 11 }));
    try second.submit(3, .{ .balance = 22 });
    second.close();
    try std.testing.expect(!second.drained());
    try std.testing.expectEqual(@as(usize, 1), service.process(10));
    try std.testing.expectEqual(@as(u128, 25), (try second.poll().?.result).account);
    second.ack(3);
    try std.testing.expect(second.drained());
}

test "named transfers resolve at the owner and reject ambiguous accounts without moving funds" {
    const Request = struct {
        fn run(service: *Service, id: u64, operation: Operation) !Balances {
            const queue = &service.queues[0];
            try queue.submit(id, operation);
            try std.testing.expectEqual(@as(usize, 1), service.process(1));
            const reply = queue.poll().?;
            defer queue.ack(reply.id);
            return reply.result;
        }
    };
    var storage: [3]accounts.Account = undefined;
    var slots: [1]Slot = undefined;
    var queues = [_]Queue{Queue.init(&slots)};
    var holds: [1]Hold = undefined;
    var service = testService(&storage, &queues, &holds);
    _ = try Request.run(&service, 1, .{ .deposit = .{ .uuid = 1, .name = try Name.init("alice"), .amount = 100 } });
    _ = try Request.run(&service, 2, .{ .ensure = .{ .uuid = 2, .name = try Name.init("bob") } });
    _ = try Request.run(&service, 3, .{ .ensure = .{ .uuid = 3, .name = try Name.init("BOB") } });
    const transfer = Operation{ .transfer_named = .{ .sender = 1, .recipient = try Name.init("Bob"), .amount = 25 } };
    try std.testing.expectError(error.AmbiguousAccount, Request.run(&service, 4, transfer));
    try std.testing.expectEqual(@as(u128, 100), service.ledger.balance(1));
    try std.testing.expectEqual(@as(u128, 0), service.ledger.balance(2));
    try std.testing.expectEqual(@as(u128, 0), service.ledger.balance(3));
    _ = try Request.run(&service, 5, .{ .ensure = .{ .uuid = 3, .name = try Name.init("charlie") } });
    const result = try Request.run(&service, 6, transfer);
    try std.testing.expectEqual(@as(u128, 75), result.account);
    try std.testing.expectEqual(@as(u128, 25), result.recipient);
    _ = try Request.run(&service, 7, .{ .reserve = .{ .uuid = 1, .amount = 60 } });
    try std.testing.expectError(error.InsufficientFunds, Request.run(&service, 8, transfer));
    try std.testing.expectEqual(@as(u128, 75), service.ledger.balance(1));
    try std.testing.expectEqual(@as(u128, 25), service.ledger.balance(2));
    _ = try Request.run(&service, 9, .{ .cancel = 7 });
    try std.testing.expectError(error.InvalidName, Request.run(&service, 10, .{ .transfer_named = .{ .sender = 1, .recipient = .{ .len = 255 }, .amount = 1 } }));
    try std.testing.expectError(error.UnknownAccount, Request.run(&service, 11, .{ .transfer_named = .{ .sender = 1, .recipient = try Name.init("missing"), .amount = 1 } }));
    try std.testing.expectEqual(@as(u128, 75), service.available(1));
    try std.testing.expectEqual(@as(u128, 25), service.available(2));
}

test "independent Core producers wrap their queues while one service owns the ledger" {
    const Producer = struct {
        queue: *Queue,
        incoming: *std.Io.Event,
        reply: std.Io.Event = .unset,
        uuid: u128,

        fn run(self: *@This()) void {
            for (1..301) |id| {
                self.reply.reset();
                self.queue.submit(id, .{ .deposit = .{
                    .uuid = self.uuid,
                    .name = Name.init("player") catch unreachable,
                    .amount = id,
                } }) catch unreachable;
                self.incoming.set(std.testing.io);
                while (self.queue.poll() == null) {
                    self.reply.waitUncancelable(std.testing.io);
                    self.reply.reset();
                }
                const response = self.queue.poll().?;
                std.debug.assert(response.id == id);
                const value = response.result catch unreachable;
                std.debug.assert(value.account == id * (id + 1) / 2);
                self.queue.ack(response.id);
            }
            self.queue.close();
            self.incoming.set(std.testing.io);
        }
    };
    var storage: [2]accounts.Account = undefined;
    var first_slots: [3]Slot = undefined;
    var second_slots: [7]Slot = undefined;
    var queues = [_]Queue{ Queue.init(&first_slots), Queue.init(&second_slots) };
    var service = testService(&storage, &queues, &.{});
    var incoming: std.Io.Event = .unset;
    var producers = [_]Producer{
        .{ .queue = &queues[0], .incoming = &incoming, .uuid = 11 },
        .{ .queue = &queues[1], .incoming = &incoming, .uuid = 22 },
    };
    const first = try std.Thread.spawn(.{}, Producer.run, .{&producers[0]});
    const second = std.Thread.spawn(.{}, Producer.run, .{&producers[1]}) catch |err| {
        while (!queues[0].drained()) {
            incoming.reset();
            if (service.process(3) != 0) producers[0].reply.set(std.testing.io);
            if (!queues[0].drained()) incoming.waitUncancelable(std.testing.io);
        }
        first.join();
        return err;
    };
    var processed: usize = 0;
    while (true) {
        incoming.reset();
        const count = service.process(3);
        processed += count;
        for (&producers) |*producer| producer.reply.set(std.testing.io);
        if (queues[0].drained() and queues[1].drained()) break;
        if (count == 0) incoming.waitUncancelable(std.testing.io);
    }
    first.join();
    second.join();
    try std.testing.expectEqual(@as(usize, 600), processed);
    try std.testing.expectEqual(@as(u128, 45_150), service.ledger.balance(11));
    try std.testing.expectEqual(@as(u128, 45_150), service.ledger.balance(22));
}

test "purchase holds prevent overspending and cancel without a compensating deposit" {
    const Test = struct {
        fn request(service: *Service, owner: usize, id: u64, operation: Operation) !Balances {
            const queue = &service.queues[owner];
            try queue.submit(id, operation);
            try std.testing.expectEqual(@as(usize, 1), service.process(service.queues.len));
            const reply = queue.poll().?;
            queue.ack(reply.id);
            return reply.result;
        }
    };
    var storage: [2]accounts.Account = undefined;
    var first_slots: [1]Slot = undefined;
    var second_slots: [1]Slot = undefined;
    var holds: [1]Hold = undefined;
    var queues = [_]Queue{ Queue.init(&first_slots), Queue.init(&second_slots) };
    var service = testService(&storage, &queues, &holds);
    _ = try Test.request(&service, 0, 1, .{ .deposit = .{ .uuid = 11, .name = try Name.init("alice"), .amount = std.math.maxInt(u128) - 100 } });
    _ = try Test.request(&service, 1, 1, .{ .ensure = .{ .uuid = 22, .name = try Name.init("bob") } });
    const held = try Test.request(&service, 0, 2, .{ .reserve = .{ .uuid = 11, .amount = 50 } });
    try std.testing.expectEqual(@as(u64, 2), held.reservation);
    try std.testing.expectEqual(std.math.maxInt(u128) - 150, held.account);
    try std.testing.expectError(error.UnknownReservation, Test.request(&service, 1, 2, .{ .commit = held.reservation }));
    try std.testing.expectError(error.InsufficientFunds, Test.request(&service, 1, 3, .{ .transfer = .{ .sender = 11, .recipient = 22, .amount = std.math.maxInt(u128) - 100 } }));
    try std.testing.expectError(error.ReservationCapacity, Test.request(&service, 0, 3, .{ .reserve = .{ .uuid = 11, .amount = 1 } }));
    _ = try Test.request(&service, 0, 4, .{ .deposit = .{ .uuid = 11, .name = try Name.init("alice"), .amount = 100 } });
    const canceled = try Test.request(&service, 0, 5, .{ .cancel = held.reservation });
    try std.testing.expectEqual(std.math.maxInt(u128), canceled.account);
    const purchase = try Test.request(&service, 0, 6, .{ .reserve = .{ .uuid = 11, .amount = 10 } });
    const paid = try Test.request(&service, 0, 7, .{ .commit = purchase.reservation });
    try std.testing.expectEqual(std.math.maxInt(u128) - 10, paid.account);
    try std.testing.expectError(error.UnknownReservation, Test.request(&service, 0, 8, .{ .commit = purchase.reservation }));
    try std.testing.expectEqual(std.math.maxInt(u128) - 10, service.ledger.balance(11));
    try std.testing.expectEqual(@as(u128, 0), service.ledger.balance(22));
    try queues[0].submit(9, .{ .reserve = .{ .uuid = 11, .amount = 1 } });
    queues[0].close();
    queues[1].close();
    try std.testing.expect(!service.retired(0));
    try std.testing.expectError(error.Busy, service.reactivate(0));
    try std.testing.expectEqual(@as(usize, 1), service.process(service.queues.len));
    const final_hold = try queues[0].poll().?.result;
    queues[0].ack(9);
    try std.testing.expect(queues[0].drained());
    try std.testing.expect(!service.retired(0));
    try std.testing.expect(service.retired(1));
    try std.testing.expectError(error.Busy, service.reactivate(0));
    try std.testing.expectError(error.Closed, queues[0].submit(10, .{ .reserve = .{ .uuid = 11, .amount = 1 } }));
    try queues[0].submit(10, .{ .cancel = final_hold.reservation });
    try std.testing.expect(!service.retired(0));
    try std.testing.expectEqual(@as(usize, 1), service.process(service.queues.len));
    try std.testing.expect(!service.retired(0));
    try std.testing.expectEqual(std.math.maxInt(u128) - 10, (try queues[0].poll().?.result).account);
    queues[0].ack(10);
    try std.testing.expect(service.retired(0));
    const next_id = try service.reactivate(0);
    try std.testing.expectEqual(@as(u64, 11), next_id);
    try std.testing.expectError(error.AlreadySubmitted, queues[0].submit(9, .{ .reserve = .{ .uuid = 11, .amount = 1 } }));
    _ = try Test.request(&service, 0, next_id, .{ .balance = 11 });
    try std.testing.expectError(error.Busy, service.reactivate(0));
    _ = try Test.request(&service, 0, std.math.maxInt(u64), .{ .balance = 11 });
    queues[0].close();
    try std.testing.expectError(error.RequestIdExhausted, service.reactivate(0));
    try std.testing.expect(queues[0].closed.load(.acquire));
}
