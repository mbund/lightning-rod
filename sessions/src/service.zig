const std = @import("std");
const system = @import("system");
const network = @import("networking");
const engine = @import("engine.zig");
const shared = @import("shared.zig");
const protocol_api = @import("protocol.zig");
const metrics = @import("metrics");
const broadcast = @import("broadcast.zig");
const PlayerProfile = @import("profiles.zig").PlayerProfile;

const assert = std.debug.assert;

pub const Instrumentation = struct {
    reserve_failures: metrics.Counter = .{},
    broadcast_reservations: metrics.Counter = .{},
    broadcast_exceptions: metrics.Counter = .{},
    input_packets: metrics.Counter = .{},
    input_bytes: metrics.Counter = .{},
    input_deferred: metrics.Counter = .{},
    input_pending: metrics.Gauge = .{},
    credit_waits: metrics.Counter = .{},
    credit_wait: metrics.Counter = .{},
    slow_clients: metrics.Counter = .{},

    pub fn init(registry: ?*metrics.Registry, namespace: []const u8) !Instrumentation {
        const owner = registry orelse return .{};
        return .{
            .reserve_failures = try owner.counter(.{ .namespace = namespace, .name = "reserve_failures", .description = "Output reservations denied" }),
            .broadcast_reservations = try owner.counter(.{ .namespace = namespace, .name = "broadcast_reservations", .description = "Recipient credit reservations for broadcast batches" }),
            .broadcast_exceptions = try owner.counter(.{ .namespace = namespace, .name = "broadcast_exceptions", .description = "Broadcast recipients requiring individual packet admission" }),
            .input_packets = try owner.counter(.{ .namespace = namespace, .name = "input_packets", .description = "Packets admitted to simulation ticks" }),
            .input_bytes = try owner.counter(.{ .namespace = namespace, .name = "input_bytes", .description = "Packet bytes admitted to simulation ticks", .unit = .bytes }),
            .input_deferred = try owner.counter(.{ .namespace = namespace, .name = "input_deferred", .description = "Input loans deferred by per-tick work limits" }),
            .input_pending = try owner.gauge(.{ .namespace = namespace, .name = "input_pending", .description = "Input loans retained for later ticks" }),
            .credit_waits = try owner.counter(.{ .namespace = namespace, .name = "credit_waits", .description = "Sends that waited for the worker to give back credit a client was taking" }),
            .credit_wait = try owner.counter(.{ .namespace = namespace, .name = "credit_wait", .description = "Time sends waited for credit", .unit = .nanoseconds }),
            .slow_clients = try owner.counter(.{ .namespace = namespace, .name = "slow_clients", .description = "Connections backpressured as their output stopped moving, once a tick" }),
        };
    }
};

pub const Configuration = struct {
    connections: usize = 32,
    /// Output credit of each connection: the bytes of its ring of Play output, so what is
    /// published to it always fits there when the worker takes it, but for a packet larger
    /// than the ring, which takes all of it.
    credit_bytes: usize = 64 * 1024,
    /// The least credit a packet takes of each recipient however small it is, which bounds how
    /// many packets a connection can have waiting: its credit over this. Packets are otherwise
    /// charged the most they take on the wire, so this bounds their count, not their bytes.
    packet_charge: usize = 64,
    pages: usize = 32,
    page_bytes: usize = 384 * 1024,
    output_pool: ?*shared.Pool = null,
    max_input_bytes: usize = 512 * 1024 - 3,
    input_work: system.work.Limits = Service.default_input_work,
    protocols: []const engine.Protocol,
    metrics: ?*metrics.Registry = null,
    /// The threshold the worker compresses output at, which decides how a prepared packet goes
    /// out: as stored when compressed, otherwise decoded.
    compression_threshold: ?usize = null,
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
    /// By player slot, what the player's login and client settings said: their skin and cape,
    /// and the skin layers shown. The worker writes a slot before the event that tells the game
    /// the player joined or is ready, so the game reads it after that event.
    profiles: []PlayerProfile,
    /// The recipients a group of packets is published to, gathered before it is.
    group_recipients: []network.Handle,
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
    /// Credit each connection slot has had back from sent output, ever, which tells a
    /// connection that is draining from one that takes nothing.
    returned: []std.atomic.Value(u64),
    /// What each connection waited for credit this tick, under `publication`.
    waits: []Wait,
    /// Whether the worker runs on a thread of its own, which gives credit back while a send
    /// waits for it. Without one, nothing would, so a send short of credit never waits.
    concurrent: std.atomic.Value(bool) = .init(false),
    disconnects: []std.atomic.Value(u32),
    preparing: std.atomic.Value(usize) = .init(0),
    output_notifications: [16]?*std.Io.Event = @splat(null),
    output_notification_mutex: std.Io.Mutex = .init,
    releases: []std.atomic.Value(u32),
    departed: []std.atomic.Value(u32),
    routes: []?network.Handle,
    occupied: []std.atomic.Value(bool),
    /// Slots the game still owes their departed player's goodbyes for: kept from new players
    /// until the game lets them go. Only the game's thread touches these two.
    held: []bool,
    /// Slots whose player left while held, freed once let go.
    vacated: []bool,
    moves: []Move,
    staged_move: ?usize = null,
    owner: ?*const Owner = null,
    readiness: ?Readiness = null,
    committed_moves: []std.atomic.Value(usize),
    activity: []std.atomic.Value(usize),
    instruments: Instrumentation,
    pending_inputs: []PendingInput,
    /// Each connection's batch of input waiting for a tick, which may still grow by the input the
    /// connection receives meanwhile: its length, with `open_input` set, until the tick takes it.
    /// Input arriving before a tick then runs in that tick, rather than waiting for the batch
    /// ahead of it to come back.
    open_inputs: []std.atomic.Value(u64),
    input_head: ?usize = null,
    input_tail: ?usize = null,
    pending_input_count: usize = 0,

    pub const active: u64 = 1 << 31;
    pub const default_input_work: system.work.Limits = .{
        .guaranteed = .{ .operations = 8, .bytes = 8 * 1024 },
        .burst = .{ .operations = 128, .bytes = 512 * 1024 },
    };

    const PendingInput = struct {
        handle: ?network.Handle = null,
        protocol: i32 = 0,
        original: protocol_api.Packets = .{ .packets = &.{} },
        remaining: protocol_api.Packets = .{ .packets = &.{} },
        allowance: system.work.Cost = .{},
        selected: usize = 0,
        previous: ?usize = null,
        next: ?usize = null,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, transport: network.Transport, config: Configuration) !*Service {
        if (config.page_bytes == 0 or config.protocols.len == 0 or config.packet_charge == 0 or config.credit_bytes < 2 * chargeFor(config, 1) or config.credit_bytes >= active or config.connections == 0)
            return error.InvalidConfiguration;
        if (config.max_input_bytes == 0) return error.InvalidConfiguration;
        try config.input_work.validate(config.connections, .{ .operations = 1, .bytes = config.max_input_bytes });

        const instrumentation = try Instrumentation.init(config.metrics, "session.producer");
        const self = try allocator.create(Service);
        errdefer allocator.destroy(self);
        var output = try shared.SharedPages.init(allocator, io, .{
            .pages = config.pages,
            .page_bytes = config.page_bytes,
            .recipients_per_page = config.connections,
            // Every recipient of every packet not yet taken charges at least the smallest charge
            // of its connection's credit. A connection gone before what was published to it is
            // taken leaves its slot to one with all its credit again, so a slot may have two
            // credits' worth waiting.
            .recipient_handles = try std.math.mul(usize, 2 * config.connections, config.credit_bytes / chargeFor(config, 1)),
            .pool = config.output_pool,
            .compression_threshold = config.compression_threshold,
        });
        errdefer output.deinit();
        const events = try allocator.alloc(Event, try std.math.ceilPowerOfTwo(usize, config.connections * 3));
        errdefer allocator.free(events);
        const recipient_marks = try allocator.alloc(u64, config.connections);
        errdefer allocator.free(recipient_marks);
        const profiles = try allocator.alloc(PlayerProfile, config.connections);
        errdefer allocator.free(profiles);
        @memset(profiles, .{});
        @memset(recipient_marks, 0);
        const group_recipients = try allocator.alloc(network.Handle, config.connections);
        errdefer allocator.free(group_recipients);
        const batch = try allocator.alloc(Event, try std.math.add(usize, events.len, config.connections));
        errdefer allocator.free(batch);
        const pending_inputs = try allocator.alloc(PendingInput, config.connections);
        errdefer allocator.free(pending_inputs);
        @memset(pending_inputs, .{});
        const open_inputs = try allocator.alloc(std.atomic.Value(u64), config.connections);
        errdefer allocator.free(open_inputs);
        for (open_inputs) |*value| value.* = .init(0);
        const credit = try allocator.alloc(std.atomic.Value(u64), config.connections);
        errdefer allocator.free(credit);

        for (credit) |*value| value.* = .init(0);
        const returned = try allocator.alloc(std.atomic.Value(u64), config.connections);
        errdefer allocator.free(returned);
        for (returned) |*value| value.* = .init(0);
        const waits = try allocator.alloc(Wait, config.connections);
        errdefer allocator.free(waits);
        @memset(waits, .{});
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
        const held = try allocator.alloc(bool, config.connections);
        errdefer allocator.free(held);
        @memset(held, false);
        const vacated = try allocator.alloc(bool, config.connections);
        errdefer allocator.free(vacated);
        @memset(vacated, false);
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
            .profiles = profiles,
            .group_recipients = group_recipients,
            .batch = batch,
            .pending_inputs = pending_inputs,
            .open_inputs = open_inputs,
            .credit = credit,
            .returned = returned,
            .waits = waits,
            .disconnects = disconnects,
            .releases = releases,
            .departed = departed,
            .routes = routes,
            .occupied = occupied,
            .held = held,
            .vacated = vacated,
            .moves = moves,
            .committed_moves = committed_moves,
            .activity = activity,
            .instruments = instrumentation,
        };
        return self;
    }

    pub fn deinit(self: *Service) void {
        assert(self.pending_input_count == 0 and self.input_head == null and self.input_tail == null);
        for (self.output_notifications) |event| assert(event == null);
        assert(!self.tick_active and self.staged_move == null and self.preparing.load(.acquire) == 0);
        assert(self.owner == null and self.readiness == null);

        // A slot may still be draining, or its player's departure unheard by a game that stopped:
        // with every connection gone, as the routes say, nothing holds it.
        for (self.moves) |*move| assert(move.state.load(.acquire) == .idle);

        for (self.routes) |route| assert(route == null);

        for (self.releases) |*value| assert(value.load(.acquire) == 0);
        self.output.deinit();
        self.allocator.free(self.activity);
        self.allocator.free(self.committed_moves);
        self.allocator.free(self.moves);
        self.allocator.free(self.occupied);
        self.allocator.free(self.held);
        self.allocator.free(self.vacated);
        self.allocator.free(self.routes);
        self.allocator.free(self.releases);
        self.allocator.free(self.departed);
        self.allocator.free(self.credit);
        self.allocator.free(self.returned);
        self.allocator.free(self.waits);
        self.allocator.free(self.disconnects);
        self.allocator.free(self.events);
        self.allocator.free(self.recipient_marks);
        self.allocator.free(self.profiles);
        self.allocator.free(self.group_recipients);
        self.allocator.free(self.batch);
        self.allocator.free(self.pending_inputs);
        self.allocator.free(self.open_inputs);
        self.allocator.destroy(self);
    }

    pub const SendError = error{ InvalidPacketSize, Backpressured, Closed };

    pub fn memoryBytes(self: *const Service) usize {
        return @sizeOf(Service) - @sizeOf(shared.SharedPages) + self.output.memoryBytes() +
            (self.events.len + self.batch.len) * @sizeOf(Event) + self.pending_inputs.len * @sizeOf(PendingInput) +
            (self.recipient_marks.len + self.group_recipients.len) * @sizeOf(u64) +
            self.credit.len * @sizeOf(std.atomic.Value(u64)) + (self.disconnects.len + self.releases.len + self.departed.len) * @sizeOf(std.atomic.Value(u32)) +
            self.routes.len * @sizeOf(?network.Handle) + self.occupied.len * @sizeOf(std.atomic.Value(bool)) + self.moves.len * @sizeOf(Move) + (self.committed_moves.len + self.activity.len) * @sizeOf(std.atomic.Value(usize)) +
            self.profiles.len * @sizeOf(PlayerProfile) + self.waits.len * @sizeOf(Wait);
    }

    /// What a player's login and client settings said, from the event that announced them on.
    /// A slot past what the service holds, as a test's service may be, says nothing.
    pub fn profile(self: *const Service, handle: network.Handle) *const PlayerProfile {
        if (handle.index >= self.profiles.len) return &no_profile;
        return &self.profiles[handle.index];
    }

    const no_profile: PlayerProfile = .{};

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
        credit: ?struct { handle: network.Handle, bytes: usize } = null,

        pub fn limit(self: *Packet, maximum: usize) void {
            assert(self.reservation != null and self.credit == null);
            assert(maximum > 0 and maximum <= self.bytes.len);
            self.bytes = self.bytes[0..maximum];
            self.reservation.?.bytes = self.bytes;
        }

        /// Prepared bytes belong to the selected protocol. Reserve for their decoded bound too.
        pub fn prepare(self: *Packet, decoded_length: usize) void {
            assert(self.reservation != null and self.credit == null);
            assert(decoded_length > 0 and decoded_length <= self.bytes.len);
            self.reservation.?.decoded_length = decoded_length;
        }

        fn boundLength(self: *const Packet, length: usize) usize {
            return self.owner.chargedLength(length, self.reservation.?.decoded_length);
        }

        pub fn cancel(self: *Packet) void {
            if (self.credit) |held| self.owner.refund(held.handle, held.bytes);
            self.credit = null;
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
            try self.owner.admitPacket(self, length, recipients);
            const published = self.owner.output.publish(reservation, recipients);
            assert(published);
            _ = self.owner.published_since_flush.fetchAdd(1, .release);
            self.reservation = null;
        }

        /// Consumes the packet. Compacts recipients to exactly those admitted.
        pub fn publishReady(self: *Packet, length: usize, recipients: []network.Handle) []const network.Handle {
            defer self.cancel();
            assert(length > 0);
            assert(length <= self.bytes.len);
            var count: usize = 0;

            for (recipients) |handle| {
                const prepaid = if (self.credit) |held| std.meta.eql(held.handle, handle) else false;
                if (!prepaid and !self.owner.canSend(handle, self.boundLength(length))) continue;
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

    /// Whether shutdown began, after which every reservation fails as closed.
    pub fn stopped(self: *const Service) bool {
        return self.stopping.load(.acquire);
    }

    /// How many of `wanted` packets the shared output pool can hold right now if each takes
    /// one unit. A shortfall publishes pending output, as a failed reservation does, so the
    /// pool can drain.
    /// How many of these reservations, taken in order, the output pool has room for
    /// now. Asked before the work a packet needs is done, so that none of it is done
    /// for a packet that cannot be reserved.
    pub fn outputFit(self: *Service, lengths: []const usize) usize {
        const room = self.output.fit(lengths);
        if (room != lengths.len) {
            self.instruments.reserve_failures.add(1);
            self.flushPressure();
        }
        return room;
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

    pub const RecipientReservation = struct {
        const Credit = struct { handle: network.Handle, bytes: usize };
        owner: *Service,
        credits: [batch_max]Credit = undefined,
        count: usize = 0,

        pub fn available(self: *const RecipientReservation, handle: network.Handle) usize {
            for (self.credits[0..self.count]) |held| if (std.meta.eql(held.handle, handle)) return held.bytes;
            return 0;
        }

        pub fn canWrite(self: *const RecipientReservation, packet: *const Packet, handle: network.Handle) bool {
            assert(packet.owner == self.owner and packet.reservation != null and packet.credit == null);
            if (packet.epoch) |epoch| if (epoch & 1 != 0 or self.owner.epoch.load(.acquire) != epoch) return false;
            return self.available(handle) >= self.owner.creditCharge(packet.bytes.len);
        }

        pub fn finish(self: *RecipientReservation, packet: *Packet, handle: network.Handle, length: usize) void {
            assert(packet.owner == self.owner and packet.reservation != null and packet.credit == null);
            assert(length > 0 and length <= packet.bytes.len);
            const bytes = self.owner.creditCharge(packet.boundLength(length));
            for (self.credits[0..self.count]) |*held| if (std.meta.eql(held.handle, handle)) {
                assert(held.bytes >= self.owner.creditCharge(packet.bytes.len));
                held.bytes -= bytes;
                packet.credit = .{ .handle = handle, .bytes = bytes };
                return;
            };
            unreachable;
        }

        pub fn release(self: *RecipientReservation) void {
            for (self.credits[0..self.count]) |held| self.owner.refund(held.handle, held.bytes);
            self.count = 0;
        }
    };

    /// Hold each recipient's available credit once. Actual packet lengths consume the reservation.
    pub fn reserveRecipients(self: *Service, packets: []const Packet, recipients: []const network.Handle) RecipientReservation {
        assert(packets.len == recipients.len and packets.len <= batch_max);
        var reservation: RecipientReservation = .{ .owner = self };
        self.publication.lockUncancelable(self.output.producer_io);
        defer self.publication.unlock(self.output.producer_io);
        for (packets, recipients, 0..) |packet, handle, index| {
            assert(packet.owner == self and packet.reservation != null and packet.credit == null);
            var duplicate = false;
            for (recipients[0..index]) |previous| duplicate = duplicate or std.meta.eql(previous, handle);
            if (duplicate) continue;
            var maximum: usize = 0;
            for (packets[index..], recipients[index..]) |candidate, recipient| {
                if (std.meta.eql(recipient, handle)) maximum = @min(self.config.credit_bytes, maximum + self.creditCharge(candidate.bytes.len));
            }
            // Whatever is held here is out of reach of the simulation until the batch
            // ends, so the floor stays where it is, but for packets too large to fit above
            // it, which only an idle connection takes.
            const bytes = @min(maximum, self.backgroundRoom(handle, maximum));
            if (bytes == 0) continue;
            self.chargeRecipients(bytes, &.{handle}) catch continue;
            reservation.credits[reservation.count] = .{ .handle = handle, .bytes = bytes };
            reservation.count += 1;
        }
        return reservation;
    }

    pub const Publication = struct { packet: *Packet, length: usize, recipients: []network.Handle };

    pub const GroupPacket = struct { packet: *Packet, length: usize };

    pub const GroupPublication = struct {
        packets: []const GroupPacket,
        protocol: i32,
        targets: []const Target,
        delivered: []Delivery,
    };

    pub fn publishGroups(self: *Service, groups: []const GroupPublication) void {
        // As in `fanout`: its scratch is written before it is read.
        @setRuntimeSafety(false);
        var pending: [batch_max]shared.SharedPages.Publication = undefined;
        self.publishGroupsWith(groups, &pending);
    }

    fn publishGroupsWith(self: *Service, groups: []const GroupPublication, pending: *[batch_max]shared.SharedPages.Publication) void {
        self.publication.lockUncancelable(self.output.producer_io);
        defer self.publication.unlock(self.output.producer_io);
        var published: usize = 0;
        for (groups) |group| {
            const packets = group.packets;
            assert(packets.len > 0 and packets.len <= batch_max - published);
            assert(group.targets.len <= self.config.connections and group.targets.len == group.delivered.len);
            var charge: usize = 0;
            var stale = false;
            for (packets) |entry| {
                assert(entry.packet.epoch == packets[0].packet.epoch);
                assert(entry.packet.owner == self and entry.packet.credit == null and entry.length > 0 and entry.length <= entry.packet.bytes.len);
                if (entry.packet.epoch) |epoch| stale = stale or epoch & 1 != 0 or self.epoch.load(.acquire) != epoch;
                charge += self.creditCharge(entry.packet.boundLength(entry.length));
            }
            if (stale) continue;
            assert(charge <= self.config.credit_bytes);
            const first = packets[0].packet.reservation.?;
            const recipients = self.group_recipients;
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
                if (self.moves[target.handle.index].state.load(.acquire) == .committed) continue;
                if (credit & (active - 1) < charge and (packets[0].packet.epoch != null or !self.awaitCreditLocked(target.handle, charge))) continue;
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
            for (packets, pending[0..packets.len], 0..) |entry, *publication, index| {
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
            // Each group goes out as it is admitted, as the next one gathers its recipients in
            // the same place.
            _ = self.preparing.fetchAdd(packets.len, .release);
            self.output.publishMany(pending[0..packets.len]);
            published += packets.len;
        }
        if (published == 0) return;
        _ = self.published_since_flush.fetchAdd(published, .release);
    }

    pub fn cancelPackets(self: *Service, packets: []Packet) void {
        // As in `fanout`: its scratch is written before it is read.
        @setRuntimeSafety(false);
        var reservations: [batch_max]shared.Reservation = undefined;
        self.cancelPacketsWith(packets, &reservations);
    }

    fn cancelPacketsWith(self: *Service, packets: []Packet, reservations: *[batch_max]shared.Reservation) void {
        assert(packets.len <= batch_max);
        var count: usize = 0;
        for (packets) |*packet| {
            if (packet.credit) |held| self.refund(held.handle, held.bytes);
            packet.credit = null;
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
                if (publication.packet.credit) |held| self.refund(held.handle, held.bytes);
                publication.packet.credit = null;
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
                const prepaid = if (packet.credit) |held| std.meta.eql(held.handle, handle) else false;
                if (!prepaid and !self.creditFor(handle, packet.boundLength(publication.length), packet.epoch == null)) continue;
                publication.recipients[recipients] = handle;
                recipients += 1;
            }
            if (recipients == 0) continue;
            var reservation = packet.reservation.?;
            reservation.bytes = reservation.bytes[0..publication.length];
            self.admitPacket(packet, publication.length, publication.recipients[0..recipients]) catch continue;
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

    fn admitPacket(self: *Service, packet: *Packet, length: usize, recipients: []const network.Handle) SendError!void {
        const bytes = self.creditCharge(packet.boundLength(length));
        // The simulation's packets wait for credit on its way back; background work's never do.
        const waiting = packet.epoch == null;
        if (packet.credit) |held| {
            assert(bytes <= held.bytes);
            var found: usize = 0;
            for (recipients) |handle| found += @intFromBool(std.meta.eql(handle, held.handle));
            assert(found == 1);
            const value = self.credit[held.handle.index].load(.acquire);
            if (value >> 32 != held.handle.generation or value & active == 0) return error.Closed;
            if (self.moves[held.handle.index].state.load(.acquire) == .committed) return error.Closed;
            try self.chargeRecipientsWaiting(bytes, recipients, held.handle, waiting);
            packet.credit = null;
            self.refund(held.handle, held.bytes - bytes);
        } else try self.chargeRecipientsWaiting(bytes, recipients, null, waiting);
        _ = self.preparing.fetchAdd(1, .release);
    }

    fn chargeRecipients(self: *Service, charge_bytes: usize, recipients: []const network.Handle) SendError!void {
        return self.chargeRecipientsExcept(charge_bytes, recipients, null);
    }

    /// What a connection waited for credit in a tick, and whether it was found slow in it.
    pub const Wait = struct {
        epoch: u64 = std.math.maxInt(u64),
        waited_ns: u64 = 0,
        slow: bool = false,
    };

    /// How long a connection's output may stand still, nothing of it taken and no credit back,
    /// before it is slow: far longer than the worker takes to frame what was published and the
    /// socket to take it from a client that reads.
    pub const stall_ns: u64 = std.time.ns_per_ms;
    /// How long a connection may wait for credit in a tick, all its waits together: a client
    /// that reads keeps its waits to the worker's turns, far shorter.
    pub const wait_budget_ns: u64 = 2 * std.time.ns_per_ms;

    /// Waits, holding `publication`, until a connection has `needed` credit, as long as its
    /// credit is only held by output on its way: published and not yet taken by the worker, or
    /// in its ring and not yet taken by the socket. A client that reads keeps that moving, so
    /// a send waits for it as a socket write would. One whose output stops moving, or that
    /// waited its budget for the tick, is slow: true only when the credit came.
    pub fn awaitCreditLocked(self: *Service, handle: network.Handle, needed: usize) bool {
        if (!self.concurrent.load(.acquire) or needed > self.config.credit_bytes or handle.index >= self.credit.len) return false;
        const wait = &self.waits[handle.index];
        const epoch = self.epoch.load(.acquire);
        if (wait.epoch != epoch) wait.* = .{ .epoch = epoch };
        if (wait.slow) return false;
        // What waits to be taken goes to the worker now, rather than when the tick ends.
        self.flushLocked();
        const start = now(self.io);
        var moved = start;
        var taken = self.output.ready.head.load(.acquire);
        var returned = self.returned[handle.index].load(.acquire);
        while (true) {
            const value = self.credit[handle.index].load(.acquire);
            if (value >> 32 != handle.generation or value & active == 0) return false;
            const moment = now(self.io);
            if (value & (active - 1) >= needed) {
                wait.waited_ns += moment - start;
                self.instruments.credit_waits.add(1);
                self.instruments.credit_wait.add(moment - start);
                return true;
            }
            const head = self.output.ready.head.load(.acquire);
            const back = self.returned[handle.index].load(.acquire);
            if (head != taken or back != returned) {
                taken = head;
                returned = back;
                moved = moment;
            }
            if (moment - moved >= stall_ns or wait.waited_ns + (moment - start) >= wait_budget_ns) {
                wait.waited_ns += moment - start;
                wait.slow = true;
                self.instruments.slow_clients.add(1);
                self.instruments.credit_wait.add(moment - start);
                return false;
            }
            std.atomic.spinLoopHint();
        }
    }

    /// Whether a send to a connection short of credit may wait for it this tick: the worker
    /// gives credit back while it waits, and the connection was not found slow.
    pub fn mayWait(self: *const Service, handle: network.Handle) bool {
        if (!self.concurrent.load(.acquire) or handle.index >= self.waits.len) return false;
        const wait = self.waits[handle.index];
        return wait.epoch != self.epoch.load(.acquire) or !wait.slow;
    }

    fn now(io: std.Io) u64 {
        return @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds);
    }

    /// Whether charging took a connection's credit below half, which hands what waits to the
    /// worker during the tick, so a client that reads has it back long before it runs out. A
    /// worker that runs only between ticks would take nothing sooner: its output stays one
    /// batch after the tick.
    pub fn crossedHalf(self: *const Service, before: u64, after: u64) bool {
        if (!self.concurrent.load(.acquire)) return false;
        const half = self.config.credit_bytes / 2;
        return before & (active - 1) >= half and after & (active - 1) < half;
    }

    /// Charges each recipient, waiting for credit on its way back when `waiting` and the
    /// connection is not slow, as the simulation's sends do; background work never waits.
    fn chargeRecipientsExcept(self: *Service, charge_bytes: usize, recipients: []const network.Handle, prepaid: ?network.Handle) SendError!void {
        return self.chargeRecipientsWaiting(charge_bytes, recipients, prepaid, false);
    }

    fn chargeRecipientsWaiting(self: *Service, charge_bytes: usize, recipients: []const network.Handle, prepaid: ?network.Handle, waiting: bool) SendError!void {
        if (self.stopping.load(.acquire)) return error.Closed;
        var halved = false;
        defer if (halved) self.flushLocked();
        self.publication_sequence +%= 1;
        if (self.publication_sequence == 0) {
            @memset(self.recipient_marks, 0);
            self.publication_sequence = 1;
        }
        var admitted: usize = 0;
        errdefer for (recipients[0..admitted]) |handle| {
            if (prepaid) |held| if (std.meta.eql(handle, held)) continue;
            self.refund(handle, charge_bytes);
        };

        for (recipients) |handle| {
            if (prepaid) |held| if (std.meta.eql(handle, held)) {
                admitted += 1;
                continue;
            };
            if (handle.index >= self.credit.len) return error.Closed;
            if (self.moves[handle.index].state.load(.acquire) == .committed) return error.Closed;

            var value = self.credit[handle.index].load(.acquire);
            if (value >> 32 != handle.generation or value & active == 0) return error.Closed;
            assert(self.recipient_marks[handle.index] != self.publication_sequence);
            self.recipient_marks[handle.index] = self.publication_sequence;

            while (true) {
                if (value >> 32 != handle.generation or value & active == 0) return error.Closed;
                if (value & (active - 1) < charge_bytes) {
                    if (waiting and self.awaitCreditLocked(handle, charge_bytes)) {
                        value = self.credit[handle.index].load(.acquire);
                        continue;
                    }
                    self.flushLocked();
                    return error.Backpressured;
                }
                if (self.credit[handle.index].cmpxchgWeak(value, value - charge_bytes, .acq_rel, .acquire)) |changed| {
                    value = changed;
                    continue;
                }
                halved = halved or self.crossedHalf(value, value - charge_bytes);
                break;
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
    /// A version a fanout encodes for, and its protocol number.
    const FanoutProtocol = struct { version: usize, number: i32 };

    /// What a fanout fills before it reads, kept apart so filling it is not paid for.
    fn FanoutScratch(comptime versions: usize) type {
        return struct {
            protocols: [versions]FanoutProtocol,
            sizes: [batch_max]usize,
            packets: [batch_max]Packet,
            publications: [batch_max]GroupPublication,
            members: [batch_max]GroupPacket,
            buffers: [batch_max][]u8,
            lengths: [batch_max]usize,
        };
    }

    pub fn fanout(self: *Service, comptime implementations: anytype, comptime Encoder: type, targets: []const Target, arguments: anytype, capacities: []const usize, delivered: []Delivery) !void {
        // Release builds keep safety, which fills undefined memory: its scratch is written before
        // it is read, and filling it cost more than the rest. Safety stays on for the work.
        @setRuntimeSafety(false);
        var scratch: FanoutScratch(implementations.len) = undefined;
        return self.fanoutWith(&scratch, implementations, Encoder, targets, arguments, capacities, delivered);
    }

    fn fanoutWith(self: *Service, scratch: anytype, comptime implementations: anytype, comptime Encoder: type, targets: []const Target, arguments: anytype, capacities: []const usize, delivered: []Delivery) !void {
        assert(targets.len == delivered.len and targets.len <= self.config.connections);
        assert(capacities.len > 0 and capacities.len <= batch_max);
        @memset(delivered, .backpressured);
        var units: usize = 0;
        for (capacities) |capacity| {
            if (capacity == 0 or capacity > self.config.page_bytes) return error.InvalidPacketSize;
            units += self.output.unitsFor(capacity);
        }
        if (units > self.output.pool.units() or capacities.len > self.output.slots.len) return error.GroupTooLarge;
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
        const protocols = &scratch.protocols;
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
            const sizes = &scratch.sizes;
            for (0..count) |index| @memcpy(sizes[index * capacities.len ..][0..capacities.len], capacities);
            const packets = &scratch.packets;
            const reserved = try self.reserveBatch(sizes[0 .. count * capacities.len], packets[0 .. count * capacities.len]);
            defer self.cancelPackets(packets[0..reserved]);
            const complete = reserved / capacities.len;
            if (complete == 0) return;
            const publications = &scratch.publications;
            const members = &scratch.members;
            var ready: usize = 0;
            for (protocols[begin..][0..complete], 0..) |protocol, index| {
                const first = index * capacities.len;
                const selected = packets[first..][0..capacities.len];
                const buffers = &scratch.buffers;
                const lengths = &scratch.lengths;
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
                for (lengths[0..selected.len]) |length| charge += self.creditCharge(length);
                if (charge > self.config.credit_bytes) return error.GroupTooLarge;
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
        return length <= self.config.page_bytes and self.outputCredit(handle) >= self.creditCharge(length);
    }

    /// As `canSend`, holding `publication`, but waiting for credit on its way back when
    /// `waiting`, as `awaitCreditLocked` does.
    fn creditFor(self: *Service, handle: network.Handle, length: usize, waiting: bool) bool {
        if (self.canSend(handle, length)) return true;
        return waiting and length <= self.config.page_bytes and self.awaitCreditLocked(handle, self.creditCharge(length));
    }

    /// How many packets of this size background work may still send a connection.
    pub fn packetCapacity(self: *Service, handle: network.Handle, maximum_bytes: usize) usize {
        if (maximum_bytes > self.config.page_bytes) return 0;
        const each = self.creditCharge(maximum_bytes);
        return self.backgroundRoom(handle, each) / each;
    }

    /// The credit background work may take of a connection for packets charged `wanted`
    /// between them: what is above the floor, or all of it for packets too large to fit above
    /// the floor once the connection is idle, as nothing else then waits for it. Otherwise a
    /// packet charged between the floor's room and the whole credit would never go.
    fn backgroundRoom(self: *Service, handle: network.Handle, wanted: usize) usize {
        const credit = self.outputCredit(handle);
        const floor = self.backgroundFloor();
        if (wanted > self.config.credit_bytes - floor and credit == self.config.credit_bytes) return credit;
        return credit -| floor;
    }

    /// Output credit of each connection that background work leaves alone: an eighth of it.
    /// Terrain is prepared on another thread and holds the credit of its players while it is.
    /// A player whose whole credit was held then looked hopelessly behind to whatever the
    /// simulation sent at that moment, and chat disconnected them for it.
    pub fn backgroundFloor(self: *const Service) usize {
        return self.config.credit_bytes / 8;
    }

    /// The bytes a packet of `length` stored bytes goes out as before framing. A prepared packet,
    /// stored compressed and `decoded_length` long decoded, goes out as stored when the worker
    /// compresses packets of its size, otherwise decoded.
    pub fn chargedLength(self: *const Service, length: usize, decoded_length: usize) usize {
        if (decoded_length == 0) return length;
        if (self.config.compression_threshold) |threshold| if (decoded_length >= threshold) return length;
        return @max(length, decoded_length);
    }

    /// The credit a packet of `length` bytes takes of each recipient until it is delivered: the
    /// most it takes on the wire, but never less than `packet_charge`, or all of the credit for
    /// a packet larger than it, which goes out in pieces while nothing else can be published to
    /// the connection.
    pub fn creditCharge(self: *const Service, length: usize) usize {
        return chargeFor(self.config, length);
    }

    /// The credit a packet of pieces takes, each framed on its own without compressing, as
    /// `Broadcast` packs small packets: what `pieceBound` gave for each of them together, but
    /// never less than `packet_charge`.
    pub fn piecesCharge(self: *const Service, bound: usize) usize {
        return @min(@max(self.config.packet_charge, bound), self.config.credit_bytes);
    }

    /// The most a piece of `length` bytes takes on the wire framed without compressing, or null
    /// where a frame could outgrow the headroom before the piece, which it is framed into.
    pub fn pieceBound(self: *const Service, length: usize) ?usize {
        var maximum: usize = 0;
        for (self.config.protocols) |protocol| {
            const overhead = protocol.frame_bound.plain_overhead orelse return null;
            if (overhead > shared.headroom) return null;
            maximum = @max(maximum, protocol.frame_bound.plain(length));
        }
        return maximum;
    }

    /// The most a packet of `length` bytes can take on the wire, compressed or not.
    pub fn framedBound(self: *const Service, length: usize) usize {
        return frameBound(self.config.protocols, length);
    }

    pub fn refund(self: *Service, handle: network.Handle, bytes: usize) void {
        var value = self.credit[handle.index].load(.acquire);

        while (value >> 32 == handle.generation and value & active != 0) {
            assert((value & (active - 1)) + bytes <= self.config.credit_bytes);
            value = self.credit[handle.index].cmpxchgWeak(value, value + bytes, .acq_rel, .acquire) orelse {
                _ = self.returned[handle.index].fetchAdd(bytes, .monotonic);
                return;
            };
        }
    }

    /// Credit a connection has had back from sent output, counted over its slot's life, so
    /// two readings tell whether it sent anything between them.
    pub fn returnedCredit(self: *const Service, handle: network.Handle) u64 {
        if (handle.index >= self.returned.len) return 0;
        return self.returned[handle.index].load(.monotonic);
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

    pub fn flushLocked(self: *Service) void {
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

        var events: usize = 0;
        while (events < self.events.len) : (events += 1) {
            const event = self.next() orelse break;
            if (event == .input and self.moves[event.input.handle.index].state.load(.acquire) == .committed) {
                _ = self.sealInput(event.input);
                self.release(event.input.handle);
                continue;
            }
            if (event == .input) {
                const input = event.input;
                const pending = &self.pending_inputs[input.handle.index];
                assert(pending.handle == null and !input.packets.empty());
                // From here the tick reads the batch, so it grows no more.
                const packets = self.sealInput(input);
                pending.* = .{ .handle = input.handle, .protocol = input.protocol, .original = packets, .remaining = packets };
                self.appendInput(input.handle.index);
                continue;
            }
            self.batch[count] = event;
            count += 1;
        }

        var cursor = self.input_head;
        var admitted: system.work.Cost = .{};
        while (cursor) |index| {
            const pending = &self.pending_inputs[index];
            cursor = pending.next;
            pending.original = pending.remaining;
            pending.selected = 0;
            pending.allowance = self.config.input_work.guaranteed;
            var burst: system.work.Cost = .{};
            self.selectInput(index, &burst, &admitted);
        }
        var burst = self.config.input_work.burst;
        cursor = self.input_head;
        const waiting = self.pending_input_count;
        for (0..waiting) |_| {
            const index = cursor.?;
            const pending = &self.pending_inputs[index];
            cursor = pending.next;
            const selected = pending.selected;
            self.selectInput(index, &burst, &admitted);
            if (pending.selected != selected and index != self.input_tail) {
                self.unlinkInput(index);
                self.appendInput(index);
            }
        }
        cursor = self.input_head;
        var deferred: usize = 0;
        while (cursor) |index| {
            const pending = &self.pending_inputs[index];
            cursor = pending.next;
            deferred += @intFromBool(!pending.remaining.empty());
            if (pending.selected == 0) continue;
            assert(count < self.batch.len);
            self.batch[count] = .{ .input = .{ .handle = pending.handle.?, .protocol = pending.protocol, .packets = pending.original.before(pending.remaining) } };
            count += 1;
        }

        self.input_events = self.batch[0..count];
        const maximum = self.config.input_work.maximum(self.pending_inputs.len) catch unreachable;
        assert(admitted.operations <= maximum.operations and admitted.bytes <= maximum.bytes);
        self.instruments.input_packets.add(admitted.operations);
        self.instruments.input_bytes.add(admitted.bytes);
        self.instruments.input_deferred.add(deferred);
        self.instruments.input_pending.set(deferred);
    }

    fn appendInput(self: *Service, index: usize) void {
        const pending = &self.pending_inputs[index];
        assert(pending.previous == null and pending.next == null);
        pending.previous = self.input_tail;
        if (self.input_tail) |tail| self.pending_inputs[tail].next = index else self.input_head = index;
        self.input_tail = index;
        self.pending_input_count += 1;
        assert(self.pending_input_count <= self.pending_inputs.len);
    }

    fn unlinkInput(self: *Service, index: usize) void {
        const pending = &self.pending_inputs[index];
        if (pending.previous) |previous| self.pending_inputs[previous].next = pending.next else self.input_head = pending.next;
        if (pending.next) |following| self.pending_inputs[following].previous = pending.previous else self.input_tail = pending.previous;
        pending.previous = null;
        pending.next = null;
        assert(self.pending_input_count > 0);
        self.pending_input_count -= 1;
    }

    fn selectInput(self: *Service, index: usize, burst: *system.work.Cost, admitted: *system.work.Cost) void {
        const pending = &self.pending_inputs[index];
        const allowance: system.work.Allowance = .{ .guaranteed = &pending.allowance, .burst = burst };
        while (!pending.remaining.empty()) {
            var rest = pending.remaining;
            const packet = (rest.next() catch unreachable).?;
            assert(packet.len <= self.config.max_input_bytes);
            if (!allowance.take(.{ .operations = 1, .bytes = packet.len })) break;
            pending.remaining = rest;
            pending.selected += 1;
            admitted.operations += 1;
            admitted.bytes += packet.len;
        }
    }

    /// Keeps a slot from new players while the game still owes others the departure of the
    /// player in it, or lets it go. A slot let go after its player left is free again at once.
    pub fn holdSlot(self: *Service, index: usize, hold: bool) void {
        self.held[index] = hold;
        if (!hold and self.vacated[index]) {
            self.vacated[index] = false;
            self.occupied[index].store(false, .release);
        }
    }

    /// A slot's player left and the game heard it: free unless the game still holds it.
    fn vacate(self: *Service, index: usize, held: bool) void {
        if (held) {
            self.vacated[index] = true;
            return;
        }
        self.held[index] = false;
        const occupied = self.occupied[index].swap(false, .release);
        assert(occupied);
    }

    /// The simulation consumer must be quiescent before abandoning its loans.
    pub fn discardInputs(self: *Service) void {
        assert(!self.tick_active);
        var notify = false;
        while (self.input_head) |index| {
            const handle = self.pending_inputs[index].handle.?;
            self.unlinkInput(index);
            self.pending_inputs[index] = .{};
            self.releaseInput(handle);
            notify = true;
        }
        while (self.next()) |event| switch (event) {
            .input => {
                _ = self.sealInput(event.input);
                self.releaseInput(event.input.handle);
                notify = true;
            },
            // Nothing is owed for a departure the game never heard of.
            .left => self.vacate(event.left.index, false),
            else => {},
        };
        if (notify) self.transport.notify(self.io);
        self.instruments.input_pending.set(0);
    }

    pub fn endTick(self: *Service, completed: bool) void {
        assert(self.tick_active);

        var notify = false;
        for (self.input_events) |event| if (event == .input) {
            const index = event.input.handle.index;
            const pending = &self.pending_inputs[index];
            assert(std.meta.eql(pending.handle.?, event.input.handle));
            if (pending.remaining.empty() or !completed or self.moves[index].state.load(.acquire) == .staged) {
                self.unlinkInput(index);
                pending.* = .{};
                self.releaseInput(event.input.handle);
                notify = true;
            }
        };

        if (completed) for (self.input_events) |event| {
            if (event == .left) {
                self.departed[event.left.index].store(event.left.generation, .release);
                self.vacate(event.left.index, self.held[event.left.index]);
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
        var pending_cursor = self.input_head;
        while (pending_cursor) |index| {
            const pending = &self.pending_inputs[index];
            pending_cursor = pending.next;
            const handle = pending.handle.?;
            if (!completed or self.moves[index].state.load(.acquire) == .committed or self.disconnects[index].load(.acquire) == handle.generation) {
                self.unlinkInput(index);
                pending.* = .{};
                self.releaseInput(handle);
                notify = true;
            }
        }
        const epoch = self.epoch.fetchAdd(1, .release);
        assert(epoch & 1 != 0);
        if (self.background_retry.swap(false, .acq_rel)) self.notifyOutput(self.io);
        if (notify) self.transport.notify(self.io);
        self.instruments.input_pending.set(self.pending_input_count);
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
        if (event == .input) self.open_inputs[event.input.handle.index].store(open_input | event.input.packets.units(), .release);
        self.events[write % self.events.len] = event;
        self.event_write.store(write +% 1, .release);
        return true;
    }

    const open_input: u64 = 1 << 63;

    /// Grows a connection's batch of input waiting for a tick to `units`, by input placed right
    /// after it, if no tick took the batch yet. The input must be in place before the call.
    pub fn extendInput(self: *Service, index: usize, units: usize) bool {
        var value = self.open_inputs[index].load(.acquire);
        while (value & open_input != 0) {
            assert(units >= value & ~open_input and units < open_input);
            value = self.open_inputs[index].cmpxchgWeak(value, open_input | units, .acq_rel, .acquire) orelse return true;
        }
        return false;
    }

    /// Closes a connection's batch of input to growing, giving how long it grew.
    fn sealInput(self: *Service, input: anytype) protocol_api.Packets {
        const value = self.open_inputs[input.handle.index].swap(0, .acq_rel);
        if (value & open_input == 0) return input.packets;
        return input.packets.grownTo(@intCast(value & ~open_input));
    }
};

fn frameBound(protocols: []const engine.Protocol, length: usize) usize {
    var maximum: usize = 0;
    for (protocols) |protocol| maximum = @max(maximum, protocol.frame_bound.bytes(length));
    return maximum;
}

/// The most a packet of `length` bytes takes on the wire: framed as it is below the compression
/// threshold or without one, otherwise as compressing it may grow it.
fn wireBound(config: Configuration, length: usize) usize {
    const compresses = if (config.compression_threshold) |threshold| length >= threshold else false;
    var maximum: usize = 0;
    for (config.protocols) |protocol| maximum = @max(maximum, if (compresses) protocol.frame_bound.bytes(length) else protocol.frame_bound.plain(length));
    return maximum;
}

/// What a packet of `length` bytes charges each recipient, as `Service.creditCharge`.
fn chargeFor(config: Configuration, length: usize) usize {
    return @min(@max(config.packet_charge, wireBound(config, length)), config.credit_bytes);
}

test "a held slot stays taken after its player leaves until the game lets it go" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const service = try Service.init(arena.allocator(), std.testing.io, undefined, .{ .connections = 2, .pages = 4, .page_bytes = 4096, .credit_bytes = 4096, .protocols = &.{.{ .number = 772 }} });
    for (service.occupied) |*occupied| occupied.store(true, .release);
    // A slot nobody holds is free as soon as the departure is heard.
    service.vacate(0, service.held[0]);
    try std.testing.expect(!service.occupied[0].load(.acquire));
    // A held slot waits for the game to let it go.
    service.holdSlot(1, true);
    service.vacate(1, service.held[1]);
    try std.testing.expect(service.occupied[1].load(.acquire));
    service.holdSlot(1, true);
    try std.testing.expect(service.occupied[1].load(.acquire));
    service.holdSlot(1, false);
    try std.testing.expect(!service.occupied[1].load(.acquire));
    try std.testing.expect(!service.held[1] and !service.vacated[1]);
}
