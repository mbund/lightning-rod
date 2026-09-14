const std = @import("std");
const network = @import("networking");
const engine = @import("engine.zig");
const shared = @import("shared.zig");
const compression = @import("compression.zig");

const assert = std.debug.assert;
const Metrics = @import("metrics").Metrics;

const ProducerTrace = Metrics(enum { output_wait });

pub const Configuration = struct {
    connections: usize = 32,
    buffer_bytes: usize = 512 * 1024,
    pages: usize = 32,
    page_bytes: usize = 384 * 1024,
    protocols: []const engine.Protocol,
    metrics_cpu: bool = false,
};

pub const Event = union(enum) {
    joined: struct {
        handle: network.Handle,
        protocol: i32,
        uuid: u128,
        name: [16]u8,
        name_len: u8,
        cause: enum { login, transfer, reload } = .login,
    },
    input: struct {
        handle: network.Handle,
        protocol: i32,
        bytes: []const u8,
    },
    left: network.Handle,
};

pub const Service = struct {
    pub const Move = struct {
        state: std.atomic.Value(enum(u8) { idle, staged, committed }) = .init(.idle),
        destination: *Service = undefined,
        slot: u16 = 0,
        generation: u32 = 0,
        boundary: usize = 0,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    transport: network.Transport,
    config: Configuration,
    output: shared.SharedPages,
    events: []Event,
    recipients: []network.Handle,
    batch: []Event,
    input_events: []const Event = &.{},
    tick_active: bool = false,
    published_since_flush: usize = 0,
    event_read: std.atomic.Value(usize) = .init(0),
    event_write: std.atomic.Value(usize) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    credit: []std.atomic.Value(u64),
    disconnects: []std.atomic.Value(u32),
    preparing: std.atomic.Value(usize) = .init(0),
    output_progress: std.Io.Event = .unset,
    releases: []std.atomic.Value(u32),
    departed: []std.atomic.Value(u32),
    routes: []?network.Handle,
    occupied: []std.atomic.Value(bool),
    moves: []Move,
    owner: ?*anyopaque = null,
    reserve_failures: u64 = 0,
    producer_metrics: ProducerTrace,

    pub const active: u64 = 1 << 31;

    pub fn init(allocator: std.mem.Allocator, io: std.Io, transport: network.Transport, config: Configuration) !*Service {
        if (config.page_bytes == 0 or config.page_bytes > compression.maximum or config.buffer_bytes < framedBound(config.page_bytes) or config.buffer_bytes >= active or config.connections == 0 or config.connections > std.math.maxInt(u16))
            return error.InvalidConfiguration;

        const self = try allocator.create(Service);
        errdefer allocator.destroy(self);
        var output = try shared.SharedPages.init(allocator, .{
            .pages = config.pages,
            .page_bytes = config.page_bytes,
            .recipients_per_page = config.connections,
        });
        errdefer output.deinit();
        const events = try allocator.alloc(Event, try std.math.ceilPowerOfTwo(usize, config.connections * 3));
        errdefer allocator.free(events);
        const recipients = try allocator.alloc(network.Handle, config.connections);
        errdefer allocator.free(recipients);
        const batch = try allocator.alloc(Event, events.len);
        errdefer allocator.free(batch);
        const credit = try allocator.alloc(std.atomic.Value(u64), config.connections);
        errdefer allocator.free(credit);

        for (credit) |*value| value.* = .init(0);
        const disconnects = try allocator.alloc(std.atomic.Value(u32), config.connections);
        errdefer allocator.free(disconnects);

        for (disconnects) |*value| value.* = .init(0);
        const releases = try allocator.alloc(std.atomic.Value(u32), config.connections);
        errdefer allocator.free(releases);

        for (releases) |*value| value.* = .init(0);
        const departed = try allocator.alloc(std.atomic.Value(u32), config.connections);
        errdefer allocator.free(departed);

        for (departed) |*value| value.* = .init(0);
        const routes = try allocator.alloc(?network.Handle, config.connections);
        errdefer allocator.free(routes);
        @memset(routes, null);
        const occupied = try allocator.alloc(std.atomic.Value(bool), config.connections);
        errdefer allocator.free(occupied);

        for (occupied) |*value| value.* = .init(false);
        const moves = try allocator.alloc(Move, config.connections);
        errdefer allocator.free(moves);

        for (moves) |*move| move.* = .{};

        self.* = .{
            .allocator = allocator,
            .io = io,
            .transport = transport,
            .config = config,
            .output = output,
            .events = events,
            .recipients = recipients,
            .batch = batch,
            .credit = credit,
            .disconnects = disconnects,
            .releases = releases,
            .departed = departed,
            .routes = routes,
            .occupied = occupied,
            .moves = moves,
            .producer_metrics = ProducerTrace.init(io, .{ .cpu = config.metrics_cpu }),
        };
        return self;
    }

    pub fn deinit(self: *Service) void {
        assert(!self.tick_active and self.preparing.load(.acquire) == 0);
        assert(self.owner == null);

        for (self.occupied) |*value| assert(!value.load(.acquire));

        for (self.moves) |*move| assert(move.state.load(.acquire) == .idle);

        for (self.routes) |route| assert(route == null);

        for (self.releases) |*value| assert(value.load(.acquire) == 0);
        self.producer_metrics.log("session_producer");
        self.output.deinit();
        self.allocator.free(self.moves);
        self.allocator.free(self.occupied);
        self.allocator.free(self.routes);
        self.allocator.free(self.releases);
        self.allocator.free(self.departed);
        self.allocator.free(self.credit);
        self.allocator.free(self.disconnects);
        self.allocator.free(self.events);
        self.allocator.free(self.recipients);
        self.allocator.free(self.batch);
        self.allocator.destroy(self);
    }

    pub const SendError = error{ InvalidPacketSize, Backpressured, Closed };

    pub fn memoryBytes(self: *const Service) usize {
        return @sizeOf(Service) - @sizeOf(shared.SharedPages) + self.output.memoryBytes() +
            (self.events.len + self.batch.len) * @sizeOf(Event) + self.recipients.len * @sizeOf(network.Handle) +
            self.credit.len * @sizeOf(std.atomic.Value(u64)) + (self.disconnects.len + self.releases.len + self.departed.len) * @sizeOf(std.atomic.Value(u32)) +
            self.routes.len * @sizeOf(?network.Handle) + self.occupied.len * @sizeOf(std.atomic.Value(bool)) + self.moves.len * @sizeOf(Move);
    }

    /// Reserves the destination now, publishes only after a successful tick.
    /// This moves the connection, not plugin data: Simulations have independent
    /// storage. Shared player data must have a shared owner supplied by the app.
    pub fn transfer(self: *Service, handle: network.Handle, destination: *Service) error{ Closed, Busy, Backpressured, InvalidDestination }!void {
        assert(self.tick_active);
        if (destination == self or self.owner == null or self.owner != destination.owner) return error.InvalidDestination;

        for (self.config.protocols) |protocol| {
            var supported = false;

            for (destination.config.protocols) |candidate| supported = supported or candidate.number == protocol.number;
            if (!supported) return error.InvalidDestination;
        }

        if (handle.index >= self.credit.len or destination.stopping.load(.acquire)) return error.Closed;

        const credit = self.credit[handle.index].load(.acquire);
        if (credit >> 32 != handle.generation or credit & active == 0) return error.Closed;

        const move = &self.moves[handle.index];
        if (move.state.load(.acquire) != .idle) return error.Busy;

        for (destination.occupied, 0..) |*occupied, index| {
            if (occupied.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) continue;
            move.destination = destination;
            move.slot = @intCast(index);
            move.generation = handle.generation;
            move.state.store(.staged, .release);
            return;
        }

        return error.Backpressured;
    }

    pub fn disconnect(self: *Service, handle: network.Handle) void {
        if (handle.index >= self.credit.len) return;

        var credit = self.credit[handle.index].load(.acquire);

        while (credit >> 32 == handle.generation and credit & active != 0) {
            credit = self.credit[handle.index].cmpxchgWeak(credit, credit & ~active, .acq_rel, .acquire) orelse {
                self.disconnects[handle.index].store(handle.generation, .release);
                self.transport.notify(self.io);
                return;
            };
        }
    }

    pub const Target = struct {
        handle: network.Handle,
        protocol: i32,
    };

    pub const Delivery = enum { queued, backpressured, closed };

    pub const Packet = struct {
        owner: *Service,
        reservation: ?shared.Reservation,
        bytes: []u8,

        pub fn cancel(self: *Packet) void {
            if (self.reservation) |reservation| self.owner.output.cancel(reservation);
            self.reservation = null;
            self.bytes = &.{};
        }

        /// Consumes the packet on success AND failure. Recipients must be unique.
        pub fn publish(self: *Packet, length: usize, recipients: []const network.Handle) SendError!void {
            defer self.cancel();
            var reservation = self.reservation.?;
            assert(self.bytes.ptr == reservation.bytes.ptr);
            assert(self.bytes.len == reservation.bytes.len);
            assert(length > 0);
            assert(length <= self.bytes.len);
            assert(recipients.len > 0);
            assert(recipients.len <= self.owner.config.connections);

            for (recipients, 0..) |handle, i| {
                for (recipients[0..i]) |previous| assert(!std.meta.eql(previous, handle));
            }

            reservation.bytes = reservation.bytes[0..length];
            try self.owner.publish(reservation, recipients);
            self.reservation = null;
        }

        /// Consumes the packet. Compacts recipients to exactly those admitted.
        pub fn publishReady(self: *Packet, length: usize, recipients: []network.Handle) []const network.Handle {
            defer self.cancel();
            assert(length > 0);
            assert(length <= self.bytes.len);
            var count: usize = 0;

            for (recipients) |handle| {
                if (!self.owner.canSend(handle, length)) continue;
                recipients[count] = handle;
                count += 1;
            }

            if (count == 0) return recipients[0..0];
            self.publish(length, recipients[0..count]) catch return recipients[0..0];
            assert(self.reservation == null);
            return recipients[0..count];
        }
    };

    pub fn reserve(self: *Service, length: usize) SendError!Packet {
        if (self.stopping.load(.acquire)) return error.Closed;
        if (length == 0 or length > self.config.page_bytes) return error.InvalidPacketSize;

        const reservation = self.output.reserve(length) orelse {
            self.reserve_failures += 1;
            return error.Backpressured;
        };
        assert(reservation.bytes.len == length);
        return .{ .owner = self, .reservation = reservation, .bytes = reservation.bytes };
    }

    fn publish(self: *Service, reservation: shared.Reservation, recipients: []const network.Handle) SendError!void {
        const charge = framedBound(reservation.bytes.len);
        var admitted: usize = 0;
        errdefer for (recipients[0..admitted]) |handle| self.refund(handle, charge);

        for (recipients) |handle| {
            if (handle.index >= self.credit.len) return error.Closed;
            if (self.moves[handle.index].state.load(.acquire) == .committed) return error.Closed;

            var value = self.credit[handle.index].load(.acquire);

            while (true) {
                if (value >> 32 != handle.generation or value & active == 0) return error.Closed;
                if (value & (active - 1) < charge) return error.Backpressured;
                value = self.credit[handle.index].cmpxchgWeak(value, value - charge, .acq_rel, .acquire) orelse break;
            }

            admitted += 1;
        }

        _ = self.preparing.fetchAdd(1, .release);
        const published = self.output.publish(reservation, recipients);
        assert(published);
        self.published_since_flush += 1;

        if (self.published_since_flush >= @max(1, self.config.pages / 2)) self.flush();
    }

    /// Adapts a normal (protocol, destination, arguments) encoder. No payload staging copy.
    pub fn send(self: *Service, comptime encode: anytype, protocol: i32, recipients: []const network.Handle, arguments: *const @typeInfo(@TypeOf(encode)).@"fn".params[2].type.?, maximum_bytes: usize) !void {
        var packet = try self.reserve(maximum_bytes);
        defer packet.cancel();
        const bytes = try encode(protocol, packet.bytes, arguments.*);
        assert(bytes.ptr == packet.bytes.ptr);
        assert(bytes.len <= packet.bytes.len);
        try packet.publish(bytes.len, recipients);
    }

    /// One encoding per protocol. Each target reports admission independently.
    pub fn fanout(self: *Service, comptime encode: anytype, targets: []const Target, arguments: *const @typeInfo(@TypeOf(encode)).@"fn".params[2].type.?, maximum_bytes: usize, delivered: []Delivery) !void {
        assert(targets.len == delivered.len);
        assert(targets.len <= self.config.connections);
        @memset(delivered, .backpressured);

        for (targets) |target| {
            var supported = false;

            for (self.config.protocols) |protocol| supported = supported or protocol.number == target.protocol;
            if (!supported) return error.UnsupportedProtocol;
        }

        for (self.config.protocols) |protocol| {
            var count: usize = 0;

            for (targets) |recipient| if (recipient.protocol == protocol.number) {
                self.recipients[count] = recipient.handle;
                count += 1;
            };

            if (count == 0) continue;

            var packet = self.reserve(maximum_bytes) catch |err| switch (err) {
                error.Backpressured => return,
                else => return err,
            };
            defer packet.cancel();
            const bytes = try encode(protocol.number, packet.bytes, arguments.*);
            assert(bytes.ptr == packet.bytes.ptr);
            assert(bytes.len <= packet.bytes.len);
            const accepted = packet.publishReady(bytes.len, self.recipients[0..count]);

            for (targets, delivered) |recipient, *result| {
                if (recipient.protocol != protocol.number) continue;
                if (recipient.handle.index >= self.credit.len) {
                    result.* = .closed;
                    continue;
                }

                const credit = self.credit[recipient.handle.index].load(.acquire);

                if (credit >> 32 != recipient.handle.generation or credit & active == 0) result.* = .closed;

                for (accepted) |handle| if (std.meta.eql(handle, recipient.handle)) {
                    result.* = .queued;
                };
            }
        }
    }

    pub fn outputCredit(self: *Service, handle: network.Handle) usize {
        if (handle.index >= self.credit.len) return 0;
        if (self.moves[handle.index].state.load(.acquire) == .committed) return 0;

        const value = self.credit[handle.index].load(.acquire);
        return if (value >> 32 == handle.generation and value & active != 0) @intCast(value & (active - 1)) else 0;
    }

    pub fn canSend(self: *Service, handle: network.Handle, length: usize) bool {
        return length <= self.config.page_bytes and self.outputCredit(handle) >= framedBound(length);
    }

    pub fn packetCapacity(self: *Service, handle: network.Handle, maximum_bytes: usize) usize {
        if (maximum_bytes > self.config.page_bytes) return 0;
        return self.outputCredit(handle) / framedBound(maximum_bytes);
    }

    /// Bounded by the caller's remaining work time, including socket stalls.
    pub fn waitOutput(self: *Service, deadline: std.Io.Timeout) bool {
        var pending = self.preparing.load(.acquire) != 0;

        for (self.credit) |*credit| {
            const value = credit.load(.acquire);
            pending = pending or (value & active != 0 and value & (active - 1) < self.config.buffer_bytes);
        }

        if (!pending) return false;

        const timing = self.producer_metrics.begin(.output_wait);
        defer timing.end();
        self.flush();
        self.output_progress.waitTimeout(self.io, deadline) catch return false;
        self.output_progress.reset();
        return true;
    }

    pub fn framedBound(length: usize) usize {
        return length + length / 1000 + 128 + compression.headroom;
    }

    pub fn refund(self: *Service, handle: network.Handle, bytes: usize) void {
        var value = self.credit[handle.index].load(.acquire);

        while (value >> 32 == handle.generation and value & active != 0) {
            assert((value & (active - 1)) + bytes <= self.config.buffer_bytes);
            value = self.credit[handle.index].cmpxchgWeak(value, value + bytes, .acq_rel, .acquire) orelse return;
        }
    }

    pub fn flush(self: *Service) void {
        if (self.published_since_flush == 0) return;
        self.published_since_flush = 0;
        self.transport.notify(self.io);
    }

    pub fn next(self: *Service) ?Event {
        const read = self.event_read.load(.monotonic);
        if (read == self.event_write.load(.acquire)) return null;

        const event = self.events[read % self.events.len];
        self.event_read.store(read +% 1, .release);
        return event;
    }

    pub fn release(self: *Service, handle: network.Handle) void {
        assert(handle.index < self.releases.len);
        const previous = self.releases[handle.index].cmpxchgStrong(0, handle.generation, .release, .monotonic);
        assert(previous == null);
        self.transport.notify(self.io);
    }

    /// All plugins may inspect this immutable batch until endTick. Packet
    /// payloads remain borrowed from Sessions, not copied into Simulation.
    pub fn beginTick(self: *Service) void {
        assert(!self.tick_active);
        self.tick_active = true;
        var count: usize = 0;

        while (count < self.batch.len) {
            const event = self.next() orelse break;
            if (event == .input and self.moves[event.input.handle.index].state.load(.acquire) == .committed) {
                self.release(event.input.handle);
                continue;
            }

            self.batch[count] = event;
            count += 1;
        }

        self.input_events = self.batch[0..count];
    }

    pub fn endTick(self: *Service, completed: bool) void {
        assert(self.tick_active);

        for (self.input_events) |event| if (event == .input) self.release(event.input.handle);

        if (completed) for (self.input_events) |event| {
            if (event == .left) {
                self.departed[event.left.index].store(event.left.generation, .release);
                self.transport.notify(self.io);
            }
        };

        self.input_events = &.{};
        self.tick_active = false;

        for (self.moves) |*move| {
            if (move.state.load(.acquire) != .staged) continue;

            if (completed) {
                move.boundary = self.output.ready.tail.load(.monotonic);
                move.state.store(.committed, .release);
                self.transport.notify(self.io);
            } else {
                const held = move.destination.occupied[move.slot].swap(false, .release);
                assert(held);
                move.state.store(.idle, .release);
            }
        }
    }

    pub fn stop(self: *Service) void {
        self.stopping.store(true, .release);
        self.transport.notify(self.io);
    }

    pub fn push(self: *Service, event: Event) bool {
        const write = self.event_write.load(.monotonic);
        if (write -% self.event_read.load(.acquire) == self.events.len) return false;
        self.events[write % self.events.len] = event;
        self.event_write.store(write +% 1, .release);
        return true;
    }
};
