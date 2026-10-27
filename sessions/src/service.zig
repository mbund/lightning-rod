const std = @import("std");
const system = @import("system");
const network = @import("networking");
const engine = @import("engine.zig");
const shared = @import("shared.zig");
const protocol_api = @import("protocol.zig");
const metrics = @import("metrics");
const broadcast = @import("broadcast.zig");

const assert = std.debug.assert;

pub const Instrumentation = struct {
    reserve_failures: metrics.Counter = .{},
    broadcast_reservations: metrics.Counter = .{},
    broadcast_exceptions: metrics.Counter = .{},

    pub fn init(registry: ?*metrics.Registry, namespace: []const u8) !Instrumentation {
        const owner = registry orelse return .{};
        return .{
            .reserve_failures = try owner.counter(.{ .namespace = namespace, .name = "reserve_failures", .description = "Output reservations denied" }),
            .broadcast_reservations = try owner.counter(.{ .namespace = namespace, .name = "broadcast_reservations", .description = "Recipient credit reservations for broadcast batches" }),
            .broadcast_exceptions = try owner.counter(.{ .namespace = namespace, .name = "broadcast_exceptions", .description = "Broadcast recipients requiring individual packet admission" }),
        };
    }
};

pub const Configuration = struct {
    connections: usize = 32,
    buffer_bytes: usize = 512 * 1024,
    pages: usize = 32,
    page_bytes: usize = 384 * 1024,
    output_pool: ?*shared.Pool = null,
    protocols: []const engine.Protocol,
    metrics: ?*metrics.Registry = null,
};

pub const Event = union(enum) {
    joined: struct {
        handle: network.Handle,
        protocol: i32,
        uuid: u128,
        name: [16]u8,
        name_len: u8,
        cause: enum { login, transfer, reload } = .login,
        ready: bool = true,
    },
    input: struct {
        handle: network.Handle,
        protocol: i32,
        packets: protocol_api.Packets,
    },
    left: network.Handle,
    ready: network.Handle,
};

pub const Service = struct {
    pub const Broadcast = broadcast.Broadcast;
    pub const batch_max = 32;
    pub const Move = struct {
        next_staged: ?usize = null,
        state: std.atomic.Value(enum(u8) { idle, staged, committed }) = .init(.idle),
        destination: *Service = undefined,
        slot: usize = 0,
        generation: u32 = 0,
        boundary: usize = 0,
    };

    pub const Owner = struct { marker: u8 = 0 };

    pub const Readiness = struct {
        output: *std.atomic.Value(usize),
        transfers: *std.atomic.Value(usize),
        inputs: *std.atomic.Value(usize),
        // Only the network owner writes progress.
        progress: *usize,
        mask: usize,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    transport: network.Transport,
    config: Configuration,
    output: shared.SharedPages,
    events: []Event,
    recipient_marks: []u64,
    publication_sequence: u64 = 0,
    batch: []Event,
    input_events: []const Event = &.{},
    tick_active: bool = false,
    published_since_flush: std.atomic.Value(usize) = .init(0),
    visible_output: std.atomic.Value(usize) = .init(0),
    publication: std.Io.Mutex = .init,
    epoch: std.atomic.Value(u64) = .init(0),
    background_retry: std.atomic.Value(bool) = .init(false),

    event_read: std.atomic.Value(usize) = .init(0),
    event_write: std.atomic.Value(usize) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    credit: []std.atomic.Value(u64),
    disconnects: []std.atomic.Value(u32),
    preparing: std.atomic.Value(usize) = .init(0),
    output_notifications: [16]?*std.Io.Event = @splat(null),
    output_notification_mutex: std.Io.Mutex = .init,
    releases: []std.atomic.Value(u32),
    departed: []std.atomic.Value(u32),
    routes: []?network.Handle,
    occupied: []std.atomic.Value(bool),
    moves: []Move,
    staged_move: ?usize = null,
    owner: ?*const Owner = null,
    readiness: ?Readiness = null,
    committed_moves: []std.atomic.Value(usize),
    activity: []std.atomic.Value(usize),
    instruments: Instrumentation,

    pub const active: u64 = 1 << 31;

    pub fn init(allocator: std.mem.Allocator, io: std.Io, transport: network.Transport, config: Configuration) !*Service {
        if (config.page_bytes == 0 or config.protocols.len == 0 or config.buffer_bytes < frameBound(config.protocols, config.page_bytes) or config.buffer_bytes >= active or config.connections == 0)
            return error.InvalidConfiguration;

        const instrumentation = try Instrumentation.init(config.metrics, "session.producer");
        const self = try allocator.create(Service);
        errdefer allocator.destroy(self);
        var output = try shared.SharedPages.init(allocator, io, .{
            .pages = config.pages,
            .page_bytes = config.page_bytes,
            .recipients_per_page = config.connections,
            .pool = config.output_pool,
        });
        errdefer output.deinit();
        const events = try allocator.alloc(Event, try std.math.ceilPowerOfTwo(usize, config.connections * 3));
        errdefer allocator.free(events);
        const recipient_marks = try allocator.alloc(u64, config.connections);
        errdefer allocator.free(recipient_marks);
        @memset(recipient_marks, 0);
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
        const committed_moves = try allocator.alloc(std.atomic.Value(usize), std.math.divCeil(usize, moves.len, @bitSizeOf(usize)) catch unreachable);
        errdefer allocator.free(committed_moves);
        for (committed_moves) |*word| word.* = .init(0);
        const activity = try allocator.alloc(std.atomic.Value(usize), committed_moves.len);
        errdefer allocator.free(activity);
        for (activity) |*word| word.* = .init(0);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .transport = transport,
            .config = config,
            .output = output,
            .events = events,
            .recipient_marks = recipient_marks,
            .batch = batch,
            .credit = credit,
            .disconnects = disconnects,
            .releases = releases,
            .departed = departed,
            .routes = routes,
            .occupied = occupied,
            .moves = moves,
            .committed_moves = committed_moves,
            .activity = activity,
            .instruments = instrumentation,
        };
        return self;
    }

    pub fn deinit(self: *Service) void {
        for (self.output_notifications) |event| assert(event == null);
        assert(!self.tick_active and self.staged_move == null and self.preparing.load(.acquire) == 0);
        assert(self.owner == null and self.readiness == null);

        for (self.occupied) |*value| assert(!value.load(.acquire));

        for (self.moves) |*move| assert(move.state.load(.acquire) == .idle);

        for (self.routes) |route| assert(route == null);

        for (self.releases) |*value| assert(value.load(.acquire) == 0);
        self.output.deinit();
        self.allocator.free(self.activity);
        self.allocator.free(self.committed_moves);
        self.allocator.free(self.moves);
        self.allocator.free(self.occupied);
        self.allocator.free(self.routes);
        self.allocator.free(self.releases);
        self.allocator.free(self.departed);
        self.allocator.free(self.credit);
        self.allocator.free(self.disconnects);
        self.allocator.free(self.events);
        self.allocator.free(self.recipient_marks);
        self.allocator.free(self.batch);
        self.allocator.destroy(self);
    }

    pub const SendError = error{ InvalidPacketSize, Backpressured, Closed };

    pub fn memoryBytes(self: *const Service) usize {
        return @sizeOf(Service) - @sizeOf(shared.SharedPages) + self.output.memoryBytes() +
            (self.events.len + self.batch.len) * @sizeOf(Event) +
            self.recipient_marks.len * @sizeOf(u64) +
            self.credit.len * @sizeOf(std.atomic.Value(u64)) + (self.disconnects.len + self.releases.len + self.departed.len) * @sizeOf(std.atomic.Value(u32)) +
            self.routes.len * @sizeOf(?network.Handle) + self.occupied.len * @sizeOf(std.atomic.Value(bool)) + self.moves.len * @sizeOf(Move) + (self.committed_moves.len + self.activity.len) * @sizeOf(std.atomic.Value(usize));
    }

    pub fn hasConnections(self: *const Service) bool {
        for (self.occupied) |*slot| if (slot.load(.acquire)) return true;
        return false;
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
            assert(move.next_staged == null);
            move.next_staged = self.staged_move;
            self.staged_move = handle.index;
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
                self.markActivity(handle.index);
                self.transport.notify(self.io);
                return;
            };
        }
    }

    pub const Target = struct {
        handle: network.Handle,
        protocol: i32,
    };

    pub const Delivery = enum { queued, backpressured, closed, unsupported };

    pub const Packet = struct {
        owner: *Service,
        reservation: ?shared.Reservation,
        bytes: []u8,
        epoch: ?u64 = null,

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

            self.owner.publication.lockUncancelable(self.owner.output.producer_io);
            defer self.owner.publication.unlock(self.owner.output.producer_io);
            if (self.epoch) |epoch| {
                if (epoch & 1 != 0 or self.owner.epoch.load(.acquire) != epoch) return error.Backpressured;
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
            self.instruments.reserve_failures.add(1);
            self.flushPressure();
            return error.Backpressured;
        };
        assert(reservation.bytes.len == length);
        return .{ .owner = self, .reservation = reservation, .bytes = reservation.bytes };
    }

    pub fn reserveMany(self: *Service, length: usize, packets: []Packet) SendError!usize {
        assert(packets.len <= batch_max);
        if (self.stopping.load(.acquire)) return error.Closed;
        if (length == 0 or length > self.config.page_bytes) return error.InvalidPacketSize;
        var reservations: [batch_max]shared.Reservation = undefined;
        const count = self.output.reserveMany(length, reservations[0..packets.len]);
        for (reservations[0..count], packets[0..count]) |reservation, *packet| packet.* = .{ .owner = self, .reservation = reservation, .bytes = reservation.bytes };
        if (count < packets.len) {
            self.instruments.reserve_failures.add(packets.len - count);
            self.flushPressure();
        }
        return count;
    }

    pub fn reserveBatch(self: *Service, lengths: []const usize, packets: []Packet) SendError!usize {
        assert(lengths.len == packets.len and packets.len <= batch_max);
        if (self.stopping.load(.acquire)) return error.Closed;
        for (lengths) |length| if (length == 0 or length > self.config.page_bytes) return error.InvalidPacketSize;
        var reservations: [batch_max]shared.Reservation = undefined;
        const count = self.output.reserveBatch(lengths, reservations[0..packets.len]);
        for (reservations[0..count], packets[0..count]) |reservation, *packet| packet.* = .{ .owner = self, .reservation = reservation, .bytes = reservation.bytes };
        if (count != packets.len) {
            self.instruments.reserve_failures.add(1);
            self.flushPressure();
        }
        return count;
    }

    pub const Publication = struct { packet: *Packet, length: usize, recipients: []network.Handle };

    const GroupPacket = struct { packet: *Packet, length: usize };

    const GroupPublication = struct {
        packets: []const GroupPacket,
        protocol: i32,
        targets: []const Target,
        delivered: []Delivery,
    };

    fn publishGroups(self: *Service, groups: []const GroupPublication) void {
        self.publication.lockUncancelable(self.output.producer_io);
        defer self.publication.unlock(self.output.producer_io);
        var pending: [batch_max]shared.SharedPages.Publication = undefined;
        var published: usize = 0;
        for (groups) |group| {
            const packets = group.packets;
            assert(packets.len > 0 and packets.len <= batch_max - published);
            assert(group.targets.len <= self.config.connections and group.targets.len == group.delivered.len);
            var charge: usize = 0;
            var stale = false;
            for (packets) |entry| {
                assert(entry.packet.owner == self and entry.length > 0 and entry.length <= entry.packet.bytes.len);
                if (entry.packet.epoch) |epoch| stale = stale or epoch & 1 != 0 or self.epoch.load(.acquire) != epoch;
                charge += self.framedBound(entry.length);
            }
            if (stale) continue;
            assert(charge <= self.config.buffer_bytes);
            const first = packets[0].packet.reservation.?;
            const recipients = self.output.recipientBuffer(first);
            var count: usize = 0;
            for (group.targets, group.delivered) |target, *result| {
                if (target.protocol != group.protocol) continue;
                if (target.handle.index >= self.credit.len) {
                    result.* = .closed;
                    continue;
                }
                const credit = self.credit[target.handle.index].load(.acquire);
                if (credit >> 32 != target.handle.generation or credit & active == 0) {
                    result.* = .closed;
                    continue;
                }
                if (credit & (active - 1) < charge or self.moves[target.handle.index].state.load(.acquire) == .committed) continue;
                recipients[count] = target.handle;
                count += 1;
            }
            if (count == 0) continue;
            self.chargeRecipients(charge, recipients[0..count]) catch continue;
            var at: usize = 0;
            for (group.targets, group.delivered) |target, *result| {
                if (target.protocol != group.protocol) continue;
                if (at < count and std.meta.eql(recipients[at], target.handle)) {
                    result.* = .queued;
                    at += 1;
                }
            }
            assert(at == count);
            for (packets, pending[published..][0..packets.len], 0..) |entry, *publication, index| {
                var reservation = entry.packet.reservation.?;
                reservation.bytes = reservation.bytes[0..entry.length];
                publication.* = .{ .reservation = reservation, .recipients = recipients[0..count], .group = .{
                    .protocol = group.protocol,
                    .first = first.page,
                    .generation = first.generation,
                    .bytes = @intCast(charge),
                    .index = @intCast(index),
                    .count = @intCast(packets.len),
                } };
                entry.packet.reservation = null;
                entry.packet.bytes = &.{};
            }
            published += packets.len;
        }
        if (published == 0) return;
        _ = self.preparing.fetchAdd(published, .release);
        self.output.publishMany(pending[0..published]);
        _ = self.published_since_flush.fetchAdd(published, .release);
    }

    fn cancelPackets(self: *Service, packets: []Packet) void {
        assert(packets.len <= batch_max);
        var reservations: [batch_max]shared.Reservation = undefined;
        var count: usize = 0;
        for (packets) |*packet| {
            if (packet.reservation) |reservation| {
                reservations[count] = reservation;
                count += 1;
            }
            packet.reservation = null;
            packet.bytes = &.{};
        }
        if (count != 0) self.output.cancelMany(reservations[0..count]);
    }

    pub fn publishManyReady(self: *Service, publications: []const Publication, accepted: []usize) void {
        assert(publications.len <= batch_max and publications.len == accepted.len);
        var pending: [batch_max]shared.SharedPages.Publication = undefined;
        var count: usize = 0;
        @memset(accepted, 0);
        self.publication.lockUncancelable(self.output.producer_io);
        defer {
            self.publication.unlock(self.output.producer_io);
            var canceled: [batch_max]shared.Reservation = undefined;
            var cancel_count: usize = 0;
            for (publications) |publication| {
                if (publication.packet.reservation) |reservation| {
                    canceled[cancel_count] = reservation;
                    cancel_count += 1;
                }
                publication.packet.reservation = null;
                publication.packet.bytes = &.{};
            }
            if (cancel_count != 0) self.output.cancelMany(canceled[0..cancel_count]);
        }
        for (publications, accepted) |publication, *admitted| {
            const packet = publication.packet;
            assert(packet.owner == self and publication.length > 0 and publication.length <= packet.bytes.len);
            if (packet.epoch) |epoch| if (epoch & 1 != 0 or self.epoch.load(.acquire) != epoch) continue;
            var recipients: usize = 0;
            for (publication.recipients) |handle| {
                if (!self.canSend(handle, publication.length)) continue;
                publication.recipients[recipients] = handle;
                recipients += 1;
            }
            if (recipients == 0) continue;
            var reservation = packet.reservation.?;
            reservation.bytes = reservation.bytes[0..publication.length];
            self.admit(reservation, publication.recipients[0..recipients]) catch continue;
            pending[count] = .{ .reservation = reservation, .recipients = publication.recipients[0..recipients] };
            count += 1;
            packet.reservation = null;
            admitted.* = recipients;
        }
        if (count != 0) {
            self.output.publishMany(pending[0..count]);
            _ = self.published_since_flush.fetchAdd(count, .release);
        }
    }

    pub fn backgroundEpoch(self: *const Service) u64 {
        return self.epoch.load(.acquire);
    }

    pub fn reserveBackground(self: *Service, length: usize, epoch: u64) SendError!Packet {
        if (epoch & 1 != 0 or self.epoch.load(.acquire) != epoch) return error.Backpressured;
        var packet = try self.reserve(length);
        packet.epoch = epoch;
        return packet;
    }

    fn publish(self: *Service, reservation: shared.Reservation, recipients: []const network.Handle) SendError!void {
        try self.admit(reservation, recipients);
        const published = self.output.publish(reservation, recipients);
        assert(published);
        _ = self.published_since_flush.fetchAdd(1, .release);
    }

    fn admit(self: *Service, reservation: shared.Reservation, recipients: []const network.Handle) SendError!void {
        try self.chargeRecipients(self.framedBound(reservation.bytes.len), recipients);
        _ = self.preparing.fetchAdd(1, .release);
    }

    fn chargeRecipients(self: *Service, charge_bytes: usize, recipients: []const network.Handle) SendError!void {
        if (self.stopping.load(.acquire)) return error.Closed;
        self.publication_sequence +%= 1;
        if (self.publication_sequence == 0) {
            @memset(self.recipient_marks, 0);
            self.publication_sequence = 1;
        }
        var admitted: usize = 0;
        errdefer for (recipients[0..admitted]) |handle| self.refund(handle, charge_bytes);

        for (recipients) |handle| {
            if (handle.index >= self.credit.len) return error.Closed;
            if (self.moves[handle.index].state.load(.acquire) == .committed) return error.Closed;

            var value = self.credit[handle.index].load(.acquire);
            if (value >> 32 != handle.generation or value & active == 0) return error.Closed;
            assert(self.recipient_marks[handle.index] != self.publication_sequence);
            self.recipient_marks[handle.index] = self.publication_sequence;

            while (true) {
                if (value >> 32 != handle.generation or value & active == 0) return error.Closed;
                if (value & (active - 1) < charge_bytes) {
                    self.flushLocked();
                    return error.Backpressured;
                }
                value = self.credit[handle.index].cmpxchgWeak(value, value - charge_bytes, .acq_rel, .acquire) orelse break;
            }

            admitted += 1;
        }
    }

    pub fn recycle(self: *Service, io: std.Io, packets: []const shared.RawPacket) void {
        if (packets.len == 0) return;
        self.output.releaseMany(packets);
        const preparing = self.preparing.fetchSub(packets.len, .release);
        assert(preparing >= packets.len);
        self.notifyOutput(io);
    }

    pub fn send(self: *Service, comptime implementations: anytype, comptime Encoder: type, protocol: i32, recipient: network.Handle, arguments: anytype, maximum_bytes: usize) !void {
        try self.checkRecipients(&.{recipient});
        var packet = try self.reserve(maximum_bytes);
        defer packet.cancel();
        inline for (implementations) |Version| {
            if (protocol == Version.protocol_number) {
                const bytes = try Encoder.write(Version, packet.bytes, arguments);
                assert(bytes.ptr == packet.bytes.ptr);
                assert(bytes.len <= packet.bytes.len);
                return packet.publish(bytes.len, &.{recipient});
            }
        }
        return error.UnsupportedProtocol;
    }

    // Credit can change after this check. Publication still validates handles and charges the actual framed size.
    fn checkRecipients(self: *Service, recipients: []const network.Handle) !void {
        for (recipients) |handle| {
            if (handle.index >= self.credit.len) return error.Closed;
            const value = self.credit[handle.index].load(.acquire);
            if (value >> 32 != handle.generation or value & active == 0 or self.moves[handle.index].state.load(.acquire) == .committed) return error.Closed;
            if (value & (active - 1) == 0) return error.Backpressured;
        }
    }

    /// The encoder may run twice if the small reservation fills.
    pub fn sendRetrying(self: *Service, comptime implementations: anytype, comptime Encoder: type, protocol: i32, recipient: network.Handle, arguments: anytype, maximum_bytes: usize) !void {
        try self.checkRecipients(&.{recipient});
        inline for (implementations) |Version| {
            if (protocol == Version.protocol_number) {
                var capacity: usize = @min(maximum_bytes, 4096);
                while (true) {
                    var packet = try self.reserve(capacity);
                    defer packet.cancel();
                    const bytes = Encoder.write(Version, packet.bytes, arguments) catch |err| {
                        if (err != error.EndOfStream or capacity == maximum_bytes) return err;
                        capacity = maximum_bytes;
                        continue;
                    };
                    assert(bytes.ptr == packet.bytes.ptr);
                    assert(bytes.len <= packet.bytes.len);
                    return packet.publish(bytes.len, &.{recipient});
                }
            }
        }
        return error.UnsupportedProtocol;
    }

    /// Admit recipients independently. Groups with no eligible recipients never invoke the encoder.
    /// Encode each protocol group directly into owned output storage before publishing it.
    pub fn fanout(self: *Service, comptime implementations: anytype, comptime Encoder: type, targets: []const Target, arguments: anytype, capacities: []const usize, delivered: []Delivery) !void {
        assert(targets.len == delivered.len and targets.len <= self.config.connections);
        assert(capacities.len > 0 and capacities.len <= batch_max);
        @memset(delivered, .backpressured);
        var units: usize = 0;
        for (capacities) |capacity| {
            if (capacity == 0 or capacity > self.config.page_bytes) return error.InvalidPacketSize;
            units += std.math.divCeil(usize, capacity + shared.headroom, self.output.unit_bytes) catch unreachable;
        }
        if (units > self.output.pages.len) return error.GroupTooLarge;
        for (targets) |target| {
            var supported = false;
            inline for (implementations) |Version| supported = supported or Version.protocol_number == target.protocol;
            if (!supported) return error.UnsupportedProtocol;
        }
        var wanted: [implementations.len]bool = @splat(false);
        for (targets, delivered) |target, *result| {
            self.checkRecipients(&.{target.handle}) catch |err| switch (err) {
                error.Closed => {
                    result.* = .closed;
                    continue;
                },
                error.Backpressured => continue,
            };
            inline for (implementations, 0..) |Version, version| {
                if (target.protocol == Version.protocol_number) wanted[version] = true;
            }
        }
        const ProtocolGroup = struct { version: usize, number: i32 };
        var protocols: [implementations.len]ProtocolGroup = undefined;
        var protocol_count: usize = 0;
        inline for (implementations, 0..) |Version, version| {
            if (wanted[version]) {
                protocols[protocol_count] = .{ .version = version, .number = Version.protocol_number };
                protocol_count += 1;
            }
        }
        var begin: usize = 0;
        while (begin < protocol_count) {
            const count = @min(batch_max / capacities.len, protocol_count - begin);
            var sizes: [batch_max]usize = undefined;
            for (0..count) |index| @memcpy(sizes[index * capacities.len ..][0..capacities.len], capacities);
            var packets: [batch_max]Packet = undefined;
            const reserved = try self.reserveBatch(sizes[0 .. count * capacities.len], packets[0 .. count * capacities.len]);
            defer self.cancelPackets(packets[0..reserved]);
            const complete = reserved / capacities.len;
            if (complete == 0) return;
            var publications: [batch_max]GroupPublication = undefined;
            var members: [batch_max]GroupPacket = undefined;
            var ready: usize = 0;
            for (protocols[begin..][0..complete], 0..) |protocol, index| {
                const first = index * capacities.len;
                const selected = packets[first..][0..capacities.len];
                var buffers: [batch_max][]u8 = undefined;
                var lengths: [batch_max]usize = undefined;
                for (selected, buffers[0..selected.len]) |packet, *buffer| buffer.* = packet.bytes;
                var encoded = true;
                inline for (implementations, 0..) |Version, version| if (protocol.version == version) {
                    Encoder.writeGroup(Version, buffers[0..selected.len], lengths[0..selected.len], arguments) catch |err| {
                        if (err != error.UnsupportedEncoding) return err;
                        encoded = false;
                    };
                };
                if (!encoded) {
                    for (targets, delivered) |target, *result| if (target.protocol == protocol.number) {
                        result.* = .unsupported;
                    };
                    continue;
                }
                var charge: usize = 0;
                for (lengths[0..selected.len]) |length| charge += self.framedBound(length);
                if (charge > self.config.buffer_bytes) return error.GroupTooLarge;
                const entries = members[first..][0..selected.len];
                for (selected, lengths[0..selected.len], entries) |*packet, length, *entry| entry.* = .{ .packet = packet, .length = length };
                publications[ready] = .{ .packets = entries, .protocol = protocol.number, .targets = targets, .delivered = delivered };
                ready += 1;
            }
            self.publishGroups(publications[0..ready]);
            begin += complete;
        }
    }

    pub fn outputCredit(self: *Service, handle: network.Handle) usize {
        if (self.stopping.load(.acquire)) return 0;
        if (handle.index >= self.credit.len) return 0;
        if (self.moves[handle.index].state.load(.acquire) == .committed) return 0;

        const value = self.credit[handle.index].load(.acquire);
        return if (value >> 32 == handle.generation and value & active != 0) @intCast(value & (active - 1)) else 0;
    }

    pub fn canSend(self: *Service, handle: network.Handle, length: usize) bool {
        return length <= self.config.page_bytes and self.outputCredit(handle) >= self.framedBound(length);
    }

    pub fn packetCapacity(self: *Service, handle: network.Handle, maximum_bytes: usize) usize {
        if (maximum_bytes > self.config.page_bytes) return 0;
        return self.outputCredit(handle) / self.framedBound(maximum_bytes);
    }

    pub fn framedBound(self: *const Service, length: usize) usize {
        return frameBound(self.config.protocols, length);
    }

    pub fn refund(self: *Service, handle: network.Handle, bytes: usize) void {
        var value = self.credit[handle.index].load(.acquire);

        while (value >> 32 == handle.generation and value & active != 0) {
            assert((value & (active - 1)) + bytes <= self.config.buffer_bytes);
            value = self.credit[handle.index].cmpxchgWeak(value, value + bytes, .acq_rel, .acquire) orelse return;
        }
    }

    /// The event must remain valid until unsubscribeOutput returns.
    pub fn subscribeOutput(self: *Service, event: *std.Io.Event) !void {
        self.output_notification_mutex.lockUncancelable(self.output.producer_io);
        defer self.output_notification_mutex.unlock(self.output.producer_io);
        for (self.output_notifications) |previous| if (previous == event) return error.DuplicateOutputSubscription;
        for (&self.output_notifications) |*slot| if (slot.* == null) {
            slot.* = event;
            return;
        };
        return error.OutputSubscriptionCapacity;
    }

    pub fn unsubscribeOutput(self: *Service, event: *std.Io.Event) void {
        self.output_notification_mutex.lockUncancelable(self.output.producer_io);
        defer self.output_notification_mutex.unlock(self.output.producer_io);
        for (&self.output_notifications) |*slot| if (slot.* == event) {
            slot.* = null;
            return;
        };
        unreachable;
    }

    pub fn notifyOutput(self: *Service, io: std.Io) void {
        self.output_notification_mutex.lockUncancelable(self.output.producer_io);
        defer self.output_notification_mutex.unlock(self.output.producer_io);
        for (self.output_notifications) |event| if (event) |target| target.set(io);
    }

    /// Retry after a tick invalidates a background publication epoch.
    pub fn retryBackground(self: *Service, epoch: u64) void {
        const current = self.epoch.load(.acquire);
        if (current == epoch and current & 1 == 0) return;
        // The exchange orders registration against endTick's epoch publication.
        _ = self.background_retry.swap(true, .acq_rel);
        if (self.epoch.load(.acquire) & 1 == 0 and self.background_retry.swap(false, .acq_rel)) self.notifyOutput(self.io);
    }

    pub fn flush(self: *Service) void {
        self.publication.lockUncancelable(self.output.producer_io);
        defer self.publication.unlock(self.output.producer_io);
        if (self.epoch.load(.acquire) & 1 != 0) return;
        self.flushLocked();
    }

    fn flushPressure(self: *Service) void {
        self.publication.lockUncancelable(self.output.producer_io);
        defer self.publication.unlock(self.output.producer_io);
        self.flushLocked();
    }

    fn flushLocked(self: *Service) void {
        if (self.published_since_flush.swap(0, .acq_rel) == 0) return;
        self.visible_output.store(self.output.ready.tail.load(.acquire), .release);
        if (self.readiness) |ready| _ = ready.output.fetchOr(ready.mask, .release);
        self.transport.notify(self.io);
    }

    pub const OutputBatch = struct {
        service: *Service,
        end: usize,

        pub fn next(self: *OutputBatch) ?shared.RawPacket {
            if (self.service.output.ready.head.load(.monotonic) == self.end) return null;
            return self.service.output.takeReady().?;
        }
    };

    pub fn outputBatch(self: *Service) OutputBatch {
        return .{ .service = self, .end = self.visible_output.load(.acquire) };
    }

    pub fn next(self: *Service) ?Event {
        const read = self.event_read.load(.monotonic);
        const write = self.event_write.load(.acquire);
        if (read == write) return null;

        const event = self.events[read % self.events.len];
        self.event_read.store(read +% 1, .release);
        if (write -% read == self.events.len) self.transport.notify(self.io);
        return event;
    }

    pub fn release(self: *Service, handle: network.Handle) void {
        self.releaseInput(handle);
        self.transport.notify(self.io);
    }

    fn markActivity(self: *Service, index: usize) void {
        assert(index < self.releases.len);
        _ = self.activity[index / @bitSizeOf(usize)].fetchOr(@as(usize, 1) << @intCast(index % @bitSizeOf(usize)), .release);
        if (self.readiness) |ready| _ = ready.inputs.fetchOr(ready.mask, .release);
    }

    fn releaseInput(self: *Service, handle: network.Handle) void {
        assert(handle.index < self.releases.len);
        const previous = self.releases[handle.index].cmpxchgStrong(0, handle.generation, .release, .monotonic);
        assert(previous == null);
        self.markActivity(handle.index);
    }

    /// All plugins may inspect this immutable batch until endTick. Packet
    /// payloads remain borrowed from Sessions, not copied into Simulation.
    pub fn beginTick(self: *Service) void {
        assert(!self.tick_active and self.staged_move == null);
        self.publication.lockUncancelable(self.output.producer_io);
        const epoch = self.epoch.fetchAdd(1, .acq_rel);
        assert(epoch & 1 == 0);
        self.publication.unlock(self.output.producer_io);
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

        var notify = false;
        for (self.input_events) |event| if (event == .input) {
            self.releaseInput(event.input.handle);
            notify = true;
        };

        if (completed) for (self.input_events) |event| {
            if (event == .left) {
                self.departed[event.left.index].store(event.left.generation, .release);
                notify = true;
            }
        };

        self.input_events = &.{};
        self.tick_active = false;

        while (self.staged_move) |index| {
            const move = &self.moves[index];
            assert(move.state.load(.acquire) == .staged);
            self.staged_move = move.next_staged;
            move.next_staged = null;

            if (completed) {
                move.boundary = self.output.ready.tail.load(.monotonic);
                move.state.store(.committed, .release);
                _ = self.committed_moves[index / @bitSizeOf(usize)].fetchOr(@as(usize, 1) << @intCast(index % @bitSizeOf(usize)), .release);
                if (self.readiness) |ready| _ = ready.transfers.fetchOr(ready.mask, .release);
                notify = true;
            } else {
                const held = move.destination.occupied[move.slot].swap(false, .release);
                assert(held);
                move.state.store(.idle, .release);
            }
        }
        const epoch = self.epoch.fetchAdd(1, .release);
        assert(epoch & 1 != 0);
        if (self.background_retry.swap(false, .acq_rel)) self.notifyOutput(self.io);
        if (notify) self.transport.notify(self.io);
    }

    pub fn stop(self: *Service) void {
        self.publication.lockUncancelable(self.output.producer_io);
        self.stopping.store(true, .release);
        for (self.activity, 0..) |*word, index| {
            const count = @min(@bitSizeOf(usize), self.credit.len - index * @bitSizeOf(usize));
            const mask = @as(usize, std.math.maxInt(usize)) >> @intCast(@bitSizeOf(usize) - count);
            _ = word.fetchOr(mask, .release);
        }
        if (self.readiness) |ready| _ = ready.inputs.fetchOr(ready.mask, .release);
        self.flushLocked();
        self.publication.unlock(self.output.producer_io);
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

fn frameBound(protocols: []const engine.Protocol, length: usize) usize {
    var maximum: usize = 0;
    for (protocols) |protocol| maximum = @max(maximum, protocol.frame_bound.bytes(length));
    return maximum;
}
