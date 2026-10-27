const metrics = @import("metrics");
const system = @import("system");
const std = @import("std");
const network = @import("networking");
const engine = @import("engine.zig");
const session_protocol = @import("protocol.zig");
const session_protocol_input = @import("input.zig");
const Service = @import("service.zig").Service;
const Event = @import("service.zig").Event;
const shared = @import("shared.zig");
const packet_output = @import("output.zig");
const SingleSimulation = @import("router.zig").SingleSimulation;
pub const Route = @import("router.zig").Route;

const assert = std.debug.assert;

pub const Instrumentation = struct {
    iteration: metrics.Timer = .{},
    compression: metrics.Timer = .{},
    fanout: metrics.Timer = .{},
    networking: metrics.Timer = .{},
    encoded_packets: metrics.Counter = .{},
    encoded_bytes: metrics.Counter = .{},
    framed_bytes: metrics.Counter = .{},
    fanout_bytes: metrics.Counter = .{},
    empty_preparations: metrics.Counter = .{},

    pub fn init(registry: ?*metrics.Registry, namespace: []const u8) !Instrumentation {
        const owner = registry orelse return .{};
        return .{
            .iteration = try owner.timer(.{ .namespace = namespace, .name = "iteration", .description = "Session event loop iteration" }),
            .compression = try owner.timer(.{ .namespace = namespace, .name = "compression", .description = "Frame and compress packets" }),
            .fanout = try owner.timer(.{ .namespace = namespace, .name = "fanout", .description = "Deliver framed packets to recipients" }),
            .networking = try owner.timer(.{ .namespace = namespace, .name = "networking", .description = "Drive network engine" }),
            .encoded_packets = try owner.counter(.{ .namespace = namespace, .name = "encoded_packets", .description = "Packets framed" }),
            .encoded_bytes = try owner.counter(.{ .namespace = namespace, .name = "encoded_bytes", .description = "Bytes before framing", .unit = .bytes }),
            .framed_bytes = try owner.counter(.{ .namespace = namespace, .name = "framed_bytes", .description = "Bytes after framing", .unit = .bytes }),
            .fanout_bytes = try owner.counter(.{ .namespace = namespace, .name = "fanout_bytes", .description = "Framed bytes delivered", .unit = .bytes }),
            .empty_preparations = try owner.counter(.{ .namespace = namespace, .name = "empty_preparations", .description = "Batches without packets" }),
        };
    }
};

/// One owner drives the Engine and all endpoints. Each endpoint has exactly one Simulation
/// producer. Different endpoints may run concurrently.
pub fn Worker(comptime Endpoint: type, comptime Hooks: type, comptime Router: type) type {
    if (!@hasDecl(Router, "route")) @compileError("Router must define route(self, profile)");
    return struct {
        const Self = @This();
        pub const Configuration = struct {
            connections: usize = 40,
            max_players: usize = 32,
            buffer_bytes: usize = 512 * 1024,
            connection_bytes: usize = 8 * 1024,
            input_burst_slots: usize = 8,
            output_burst_slots: usize = 8,
            configuration_slots: usize = 8,
            decode_slots: usize = 8,
            framing_slots: usize = 8,
            max_pending_wire_bytes: usize = 4 * 1024 * 1024,
            protocols: *const Endpoint.Protocols,
            compression_threshold: ?usize = 256,
            metrics: ?*metrics.Registry = null,
            hooks: *Hooks,
            router: *Router,
            destinations: []const Router.Destination,
        };

        const Engine = engine.Engine(Endpoint, Self);
        const Codec = Engine.Codec;
        comptime {
            assert(Service.batch_max <= @bitSizeOf(@FieldType(Codec.SendTarget, "packets")));
        }
        const Pending = struct {
            next: ?*Pending = null,
            order: u64 = 0,
            source: ?*Service = null,
            packet: shared.RawPacket = undefined,
            remaining: std.bit_set.DynamicBitSetUnmanaged,
            remaining_count: usize = 0,
            sizes: []usize,
            frame: ?*Frame = null,
            group: usize = 0,
            loans: usize = 0,

            fn complete(self: *Pending, recipient: usize) void {
                assert(self.remaining.isSet(recipient) and self.remaining_count > 0);
                self.remaining.unset(recipient);
                self.remaining_count -= 1;
            }
        };
        const Frame = struct {
            task: Codec.Task = .{},
            loan: Engine.Loan = .{},
            ready: bool = false,
            // A sequence child may complete before its parent can consume it.
            completion_observed: bool = false,
            packet: ?*Pending = null,
            protocol: i32 = 0,
            compressed: bool = false,
            bytes: []u8,
            targets: ?*Codec.SendTarget = null,
            sequence: ?Codec.Frame = null,
            sequence_count: usize = 1,
            sequence_next: ?*Frame = null,
            completion_owner: enum { network, sequence } = .network,
        };
        const Queue = struct { next_order: u64 = 1, pending_base: usize = 0, head: ?*Pending = null, tail: ?*Pending = null, next: ?usize = null };
        const Previous = struct {
            endpoint: *Service,
            handle: network.Handle,
        };

        const Binding = struct {
            endpoint: *Service,
            handle: network.Handle,
            native: network.Handle,
            configuring: bool = false,
            previous: ?Previous = null,
        };

        const SelectedRoute = struct {
            connection: network.Handle,
            destination: usize,
        };

        const SequenceCandidate = struct {
            handle: network.Handle,
            slot: usize,
            packets: u32,
            required: usize,
        };

        allocator: std.mem.Allocator,
        config: Configuration,
        hooks: *Hooks,
        router: *Router,
        engine: *Engine,
        endpoints: []const *Service,
        owner_token: Service.Owner = .{},
        bindings: []?Binding,
        selected_routes: []?SelectedRoute,
        pending: []Pending,
        recipient_masks: []usize,
        sequence_members: []SequenceCandidate,
        // Packet-local recipient ordinals stay borrowed until their sequence completes.
        sequence_slots: []usize,
        sequence_candidates: system.IndexSet,
        frame_sizes: []usize,
        queues: []Queue,
        blocked: std.DynamicBitSetUnmanaged,
        blocked_words: system.IndexSet,
        output_ready: []std.atomic.Value(usize),
        transfers_ready: []std.atomic.Value(usize),
        inputs_ready: []std.atomic.Value(usize),
        progress_ready: []usize,
        // Delivery itself can unblock later packets without another transport event.
        delivery_ready: bool = true,
        active_head: ?usize = null,
        active_tail: ?usize = null,
        stopping: std.atomic.Value(bool) = .init(false),
        reload_state: std.atomic.Value(enum(u8) { running, requested, parked }) = .init(.running),
        quiescing: bool = false,
        started: bool = false,
        reload_removed: [Endpoint.versions.len]bool = @splat(false),
        instruments: Instrumentation,
        frames: []Frame = &.{},
        socket_budget: packet_output.SocketBudget,
        send_targets: []Codec.SendTarget,
        target_free: []usize,
        target_free_count: usize,

        pub fn initCodec(self: *Self, io: std.Io, registry: ?*metrics.Registry) !void {
            assert(self.engine.codec == null);
            const codec = try Codec.init(self.allocator, io, self.engine.networking, self.config.connections + self.frames.len, registry);
            errdefer codec.deinit();
            try self.engine.attachCodec(codec);
        }

        pub fn init(allocator: std.mem.Allocator, transport: network.Transport, config: Configuration, endpoints: []const *Service) !*Self {
            if (endpoints.len == 0 or config.connections == 0 or config.max_players == 0 or config.max_players > config.connections)
                return error.InvalidConfiguration;
            if (config.destinations.len != endpoints.len) return error.InvalidConfiguration;
            for (config.destinations, 0..) |destination, index| {
                for (config.destinations[0..index]) |previous| {
                    if (std.meta.eql(destination, previous)) return error.DuplicateDestination;
                }
            }

            var maximum: usize = 0;

            for (endpoints, 0..) |endpoint, i| {
                if (endpoint.owner != null) return error.InvalidConfiguration;
                assert(endpoint.readiness == null);
                if (endpoint.config.buffer_bytes != config.buffer_bytes) return error.InvalidConfiguration;

                for (endpoint.config.protocols) |selected| {
                    var found = false;

                    for (config.protocols.values) |protocol| found = found or protocol.number == selected.number;
                    if (!found) return error.InvalidConfiguration;
                }

                for (endpoints[0..i]) |previous| if (previous == endpoint) return error.InvalidConfiguration;
                maximum = @max(maximum, endpoint.framedBound(endpoint.config.page_bytes));
            }

            if (config.framing_slots == 0 or config.framing_slots > 64) return error.InvalidCodecCapacity;
            const frames = try allocator.alloc(Frame, config.framing_slots);
            errdefer allocator.free(frames);
            var frames_initialized: usize = 0;
            errdefer for (frames[0..frames_initialized]) |frame| {
                allocator.free(frame.bytes);
            };
            for (frames) |*frame| {
                const bytes = try allocator.alloc(u8, maximum);
                frame.* = .{ .bytes = bytes };
                frames_initialized += 1;
            }
            const send_targets = try allocator.alloc(Codec.SendTarget, config.connections);
            errdefer allocator.free(send_targets);
            const target_free = try allocator.alloc(usize, config.connections);
            errdefer allocator.free(target_free);
            for (target_free, 0..) |*slot, i| slot.* = config.connections - i - 1;
            const instrumentation = try Instrumentation.init(config.metrics, "session.worker");
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const destinations = try allocator.dupe(Router.Destination, config.destinations);
            errdefer allocator.free(destinations);
            const bindings = try allocator.alloc(?Binding, config.connections);
            errdefer allocator.free(bindings);
            @memset(bindings, null);
            const selected_routes = try allocator.alloc(?SelectedRoute, config.connections);
            errdefer allocator.free(selected_routes);
            @memset(selected_routes, null);
            const queues = try allocator.alloc(Queue, endpoints.len);
            errdefer allocator.free(queues);
            @memset(queues, .{});
            var packet_capacity: usize = 0;
            var recipient_capacity: usize = 0;
            for (endpoints, 0..) |endpoint, index| {
                recipient_capacity = @max(recipient_capacity, endpoint.config.connections);
                queues[index].pending_base = packet_capacity;
                for (endpoints[0..index], 0..) |previous, prior| {
                    if (previous.output.pool == endpoint.output.pool) {
                        queues[index].pending_base = queues[prior].pending_base;
                        break;
                    }
                } else packet_capacity = try std.math.add(usize, packet_capacity, endpoint.output.pages.len);
            }
            const pending = try allocator.alloc(Pending, packet_capacity);
            errdefer allocator.free(pending);
            const sequence_members = try allocator.alloc(SequenceCandidate, recipient_capacity);
            errdefer allocator.free(sequence_members);
            const sequence_slots = try allocator.alloc(usize, try std.math.mul(usize, config.connections, @min(config.framing_slots, Service.batch_max)));
            errdefer allocator.free(sequence_slots);
            var sequence_candidates = try system.IndexSet.init(allocator, recipient_capacity);
            errdefer sequence_candidates.deinit(allocator);
            const recipient_words = std.math.divCeil(usize, recipient_capacity, @bitSizeOf(usize)) catch unreachable;
            const recipient_masks = try allocator.alloc(usize, try std.math.mul(usize, packet_capacity, recipient_words));
            errdefer allocator.free(recipient_masks);
            const groups = config.protocols.values.len * 2;
            const frame_sizes = try allocator.alloc(usize, try std.math.mul(usize, packet_capacity, groups));
            errdefer allocator.free(frame_sizes);
            for (pending, 0..) |*packet, index| packet.* = .{ .remaining = .{ .bit_length = recipient_capacity, .masks = recipient_masks[index * recipient_words ..][0..recipient_words].ptr }, .sizes = frame_sizes[index * groups ..][0..groups] };
            const words = std.math.divCeil(usize, endpoints.len, @bitSizeOf(usize)) catch unreachable;
            const output_ready = try allocator.alloc(std.atomic.Value(usize), words);
            errdefer allocator.free(output_ready);
            const transfers_ready = try allocator.alloc(std.atomic.Value(usize), words);
            errdefer allocator.free(transfers_ready);
            const inputs_ready = try allocator.alloc(std.atomic.Value(usize), words);
            errdefer allocator.free(inputs_ready);
            for (inputs_ready) |*word| word.* = .init(0);
            const progress_ready = try allocator.alloc(usize, words);
            errdefer allocator.free(progress_ready);
            @memset(progress_ready, 0);
            for (output_ready, transfers_ready) |*output, *transfers| {
                output.* = .init(0);
                transfers.* = .init(0);
            }
            var blocked = try std.DynamicBitSetUnmanaged.initEmpty(allocator, config.connections);
            errdefer blocked.deinit(allocator);
            var blocked_words = try system.IndexSet.init(allocator, std.math.divCeil(usize, config.connections, @bitSizeOf(usize)) catch unreachable);
            errdefer blocked_words.deinit(allocator);
            self.* = .{
                .allocator = allocator,
                .config = blk: {
                    var owned = config;
                    owned.destinations = destinations;
                    break :blk owned;
                },
                .hooks = config.hooks,
                .router = config.router,
                .engine = undefined,
                .endpoints = endpoints,
                .bindings = bindings,
                .selected_routes = selected_routes,
                .pending = pending,
                .recipient_masks = recipient_masks,
                .sequence_members = sequence_members,
                .sequence_slots = sequence_slots,
                .sequence_candidates = sequence_candidates,
                .frame_sizes = frame_sizes,
                .queues = queues,
                .output_ready = output_ready,
                .transfers_ready = transfers_ready,
                .inputs_ready = inputs_ready,
                .progress_ready = progress_ready,
                .blocked = blocked,
                .blocked_words = blocked_words,
                .frames = frames,
                .socket_budget = .init(frames.len),
                .send_targets = send_targets,
                .target_free = target_free,
                .target_free_count = target_free.len,
                .instruments = instrumentation,
            };
            assert(self.socket_budget.capacity < self.frames.len);
            self.engine = try Engine.init(allocator, transport, .{
                .connections = config.connections,
                .max_players = config.max_players,
                .buffer_bytes = config.buffer_bytes,
                .connection_bytes = config.connection_bytes,
                .input_burst_slots = config.input_burst_slots,
                .output_burst_slots = config.output_burst_slots,
                .configuration_slots = config.configuration_slots,
                .decode_slots = config.decode_slots,
                .max_packet = config.buffer_bytes - 3,
                .max_pending_wire_bytes = config.max_pending_wire_bytes,
                .protocols = config.protocols,
                .compression_threshold = config.compression_threshold,
                .metrics = config.metrics,
                .observer = self,
            });

            for (endpoints, 0..) |endpoint, index| {
                endpoint.owner = &self.owner_token;
                const ready: Service.Readiness = .{
                    .output = &output_ready[index / @bitSizeOf(usize)],
                    .transfers = &transfers_ready[index / @bitSizeOf(usize)],
                    .inputs = &inputs_ready[index / @bitSizeOf(usize)],
                    .progress = &progress_ready[index / @bitSizeOf(usize)],
                    .mask = @as(usize, 1) << @intCast(index % @bitSizeOf(usize)),
                };
                endpoint.readiness = ready;
                for (endpoint.activity) |*word| if (word.load(.acquire) != 0) {
                    _ = ready.inputs.fetchOr(ready.mask, .release);
                    break;
                };
                if (endpoint.visible_output.load(.acquire) != endpoint.output.ready.head.load(.acquire)) _ = ready.output.fetchOr(ready.mask, .release);
                for (endpoint.committed_moves) |*word| if (word.load(.acquire) != 0) {
                    _ = ready.transfers.fetchOr(ready.mask, .release);
                    break;
                };
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            assert(self.drained());
            assert(self.socket_budget.used == 0);
            assert(self.active_head == null and self.active_tail == null);

            if (self.engine.codec) |codec| codec.deinit();
            for (self.frames) |frame| {
                assert(frame.packet == null);
                self.allocator.free(frame.bytes);
            }
            self.allocator.free(self.frames);
            assert(self.target_free_count == self.target_free.len);
            self.allocator.free(self.send_targets);
            self.allocator.free(self.target_free);

            for (self.bindings) |binding| assert(binding == null);
            self.engine.deinit();

            for (self.endpoints) |endpoint| {
                endpoint.owner = null;
                endpoint.readiness = null;
            }
            for (self.pending) |packet| assert(packet.source == null);
            self.allocator.free(self.pending);
            self.allocator.free(self.recipient_masks);
            self.allocator.free(self.sequence_members);
            self.allocator.free(self.sequence_slots);
            self.sequence_candidates.deinit(self.allocator);
            self.allocator.free(self.frame_sizes);
            self.allocator.free(self.output_ready);
            self.allocator.free(self.inputs_ready);
            self.allocator.free(self.transfers_ready);
            self.allocator.free(self.progress_ready);
            self.allocator.free(self.queues);
            self.blocked_words.deinit(self.allocator);
            self.blocked.deinit(self.allocator);
            self.allocator.free(self.selected_routes);
            self.allocator.free(self.bindings);
            self.allocator.free(self.config.destinations);
            self.allocator.destroy(self);
        }

        /// Roll back initialization before any network operation can borrow a
        /// buffer. Transport retains ownership of adopted descriptors.
        pub fn deinitUnstarted(self: *Self) void {
            assert(!self.started);
            for (self.engine.connections, 0..) |*connection, index| if (connection.handle) |handle| {
                assert(!connection.receiving and !connection.sending and !connection.loan.load(.acquire));
                self.closed(handle);
                if (connection.lifecycle) |*lifecycle| Endpoint.clear(lifecycle);
                connection.lifecycle = null;
                self.engine.releaseBuffers(index);
                self.engine.setHandle(index, null);
            };
            assert(self.engine.admitted == 0);
            @memset(self.bindings, null);
            @memset(self.selected_routes, null);
            for (self.endpoints) |endpoint| {
                assert(!endpoint.tick_active and endpoint.preparing.load(.acquire) == 0);
                @memset(endpoint.routes, null);
                for (endpoint.occupied) |*occupied| occupied.store(false, .release);
                for (endpoint.releases) |*release| release.store(0, .release);
                endpoint.event_read.store(endpoint.event_write.load(.acquire), .release);
            }
            self.deinit();
        }

        /// Producers, packet work, and kernel operations must be stopped before abandoning loans.
        pub fn abort(self: *Self, io: std.Io) void {
            if (self.engine.codec) |codec| assert(codec.thread == null);
            for (self.endpoints) |endpoint| assert(!endpoint.tick_active);
            self.discardInputs();
            for (self.engine.connections, 0..) |*connection, index| {
                if (Codec.take(&connection.codec)) |result| {
                    if (result) |value| {
                        if (value.burst) |lease| lease.release();
                    } else |_| {}
                }
                assert(connection.codec.state.load(.acquire) == .idle);
                if (connection.send_loan) |loan| loan.release();
                connection.send_loan = null;
                connection.receiving = false;
                connection.sending = false;
                connection.loan.store(false, .release);
                if (connection.handle) |handle| {
                    self.closed(handle);
                    if (connection.lifecycle) |*lifecycle| Endpoint.clear(lifecycle);
                    connection.lifecycle = null;
                    self.engine.releaseBuffers(index);
                    self.engine.setHandle(index, null);
                }
            }
            assert(self.engine.admitted == 0);
            for (self.frames) |*frame| {
                if (Codec.take(&frame.task)) |_| {}
                assert(frame.task.state.load(.acquire) == .idle);
                assert(frame.loan.sockets == 0);
                if (frame.loan.references != 0) {
                    assert(frame.loan.references == 1);
                    frame.loan.release();
                }
                frame.ready = false;
                frame.packet = null;
                frame.targets = null;
                frame.completion_owner = .network;
                frame.sequence_next = null;
                frame.sequence_count = 1;
                frame.sequence = null;
            }
            self.target_free_count = self.target_free.len;
            for (self.target_free, 0..) |*slot, index| slot.* = index;
            for (self.endpoints) |endpoint| {
                var packets: [Service.batch_max]shared.RawPacket = undefined;
                var count: usize = 0;
                for (self.pending) |*pending| if (pending.source == endpoint) {
                    packets[count] = pending.packet;
                    count += 1;
                    pending.source = null;
                    pending.frame = null;
                    pending.loans = 0;
                    if (count == packets.len) {
                        endpoint.recycle(io, &packets);
                        count = 0;
                    }
                };
                var batch = endpoint.outputBatch();
                while (batch.next()) |packet| {
                    packets[count] = packet;
                    count += 1;
                    if (count == packets.len) {
                        endpoint.recycle(io, &packets);
                        count = 0;
                    }
                }
                endpoint.recycle(io, packets[0..count]);
                assert(endpoint.preparing.load(.acquire) == 0);
                @memset(endpoint.routes, null);
                for (endpoint.occupied) |*occupied| occupied.store(false, .release);
                for (endpoint.releases) |*release| release.store(0, .release);
                for (endpoint.moves) |*move| move.state.store(.idle, .release);
                for (endpoint.committed_moves) |*word| word.store(0, .release);
                for (endpoint.activity) |*word| word.store(0, .release);
            }
            for (self.output_ready, self.transfers_ready, self.inputs_ready) |*output, *transfers, *inputs| {
                output.store(0, .release);
                transfers.store(0, .release);
                inputs.store(0, .release);
            }
            @memset(self.progress_ready, 0);
            for (self.queues) |*queue| queue.* = .{ .pending_base = queue.pending_base };
            self.active_head = null;
            self.active_tail = null;
            @memset(self.bindings, null);
            @memset(self.selected_routes, null);
            assert(self.drained() and self.socket_budget.used == 0);
        }

        fn prepareSequence(self: *Self, origin: usize, pending: *Pending) !bool {
            const codec = self.engine.codec orelse return false;
            const group = pending.packet.group;
            if (group.index != 0 or group.count > self.frames.len) return false;
            var frames: [Service.batch_max]*Frame = undefined;
            var available: usize = 0;
            for (self.frames) |*frame| if (frame.packet == null and available < frames.len) {
                frames[available] = frame;
                available += 1;
            };
            if (available < group.count) return false;
            var members: [Service.batch_max]*Pending = undefined;
            var next: ?*Pending = pending;
            var count: usize = 0;
            var charge: usize = 0;
            while (count < (if (group.count > 1) group.count else available)) {
                const entry = next orelse break;
                if (group.count > 1) {
                    assert(entry.packet.group.first == group.first and entry.packet.group.generation == group.generation and entry.packet.group.index == count);
                    assert(entry.packet.group.count == group.count and entry.packet.recipients.len == pending.packet.recipients.len);
                    assert(entry.packet.sameAudience(pending.packet));
                } else {
                    if (entry.packet.group.count != 1 or entry.packet.group.protocol != group.protocol) break;
                }
                if (entry.frame != null) break;
                const bound = pending.source.?.framedBound(entry.packet.bytes.len);
                if (bound > self.config.buffer_bytes - charge) break;
                charge += bound;
                members[count] = entry;
                count += 1;
                next = entry.next;
            }
            if (count < 2 or (group.count > 1 and count != group.count)) return false;
            const endpoint = pending.source.?;
            var targets: ?*Codec.SendTarget = null;
            var compressed: ?bool = null;
            var protocol: ?i32 = group.protocol;
            const stride = @min(self.frames.len, Service.batch_max);
            self.sequence_candidates.clear();
            for (members[0..count], 0..) |member, position| {
                var remaining = member.remaining.iterator(.{});
                while (remaining.next()) |recipient| {
                    const handle = member.packet.recipients.at(recipient);
                    if (!self.sequence_candidates.contains(handle.index)) {
                        const credit = endpoint.credit[handle.index].load(.acquire);
                        if (credit >> 32 != handle.generation or credit & Service.active == 0) continue;
                        if (self.target_free_count == 0) continue;
                        const native = endpoint.routes[handle.index] orelse continue;
                        const connection = &self.engine.connections[native.index];
                        if (self.blocked.isSet(native.index) or !self.engine.groupReady(native, origin, group) or connection.codec.state.load(.acquire) != .idle or connection.received != 0 or !Endpoint.encrypted(&connection.lifecycle.?)) continue;
                        if (protocol) |number| if (connection.protocol.?.number != number) continue;
                        self.target_free_count -= 1;
                        self.sequence_members[handle.index] = .{ .handle = handle, .slot = self.target_free[self.target_free_count], .packets = 0, .required = 0 };
                        self.sequence_candidates.insert(handle.index);
                    }
                    const candidate = &self.sequence_members[handle.index];
                    if (candidate.handle.generation != handle.generation) continue;
                    const bit = @as(u32, 1) << @intCast(position);
                    assert(candidate.packets & bit == 0);
                    candidate.packets |= bit;
                    candidate.required += endpoint.framedBound(member.packet.bytes.len);
                    self.sequence_slots[candidate.slot * stride + position] = recipient;
                }
            }
            for (self.sequence_candidates.values()) |index| {
                const candidate = self.sequence_members[index];
                var retained = false;
                defer if (!retained) {
                    self.target_free[self.target_free_count] = candidate.slot;
                    self.target_free_count += 1;
                };
                if (group.count > 1 and @popCount(candidate.packets) != count) continue;
                const native = endpoint.routes[index].?;
                const connection = &self.engine.connections[native.index];
                if (protocol) |number| if (connection.protocol.?.number != number) continue;
                const compression = Endpoint.compressed(&connection.lifecycle.?);
                if (compressed) |selected| if (selected != compression) continue;
                self.engine.reserveOutput(native, candidate.required) catch continue;
                const destination = self.engine.prepareSend(native) catch continue;
                self.engine.claimGroup(native, origin, group);
                compressed = compression;
                protocol = connection.protocol.?.number;
                const target = &self.send_targets[candidate.slot];
                target.* = destination;
                target.index = candidate.slot;
                target.recipient = index;
                assert(@popCount(candidate.packets) > 0 and @popCount(candidate.packets) <= count);
                target.packets = candidate.packets;
                target.next = targets;
                targets = target;
                retained = true;
            }
            if (targets == null) return false;
            for (frames[0..count], members[0..count], 0..) |frame, member, index| {
                frame.completion_observed = false;
                frame.packet = member;
                member.frame = frame;
                member.loans += 1;
                frame.protocol = protocol.?;
                frame.compressed = compressed.?;
                frame.targets = if (index == 0) targets else null;
                frame.sequence_count = if (index == 0) count else 1;
                frame.sequence_next = if (index + 1 < count) frames[index + 1] else null;
                frame.completion_owner = if (index == 0) .network else .sequence;
                frame.sequence = .{ .task = &frame.task, .protocol = frame.protocol, .storage = endpoint.output.framingStorage(member.packet), .length = member.packet.bytes.len, .threshold = if (compressed.?) self.config.compression_threshold else null, .output = frame.bytes };
                if (index != 0) {
                    assert(frame.task.state.load(.acquire) == .idle);
                    frame.task.operation = .{ .frame = .{ .protocol = frame.protocol, .storage = frame.sequence.?.storage, .length = frame.sequence.?.length, .threshold = frame.sequence.?.threshold, .output = frame.bytes } };
                    frame.task.state.store(.queued, .release);
                    frames[index - 1].sequence.?.next = &frame.sequence.?;
                }
            }
            codec.submit(&frames[0].task, .{ .frame_sequence = .{ .first = &frames[0].sequence.?, .targets = targets.? } });
            return true;
        }

        pub fn stop(self: *Self) void {
            self.stopping.store(true, .release);

            for (self.endpoints) |endpoint| endpoint.stop();
        }

        pub fn requestReload(self: *Self, io: std.Io, removed: [Endpoint.versions.len]bool) void {
            assert(self.engine.networking.inheritance != null);
            assert(self.reload_state.load(.acquire) == .running);
            self.reload_removed = removed;
            assert(self.reload_state.swap(.requested, .acq_rel) == .running);
            self.engine.networking.notify(io);
        }

        /// Called after the service has joined and gameplay output reservations have returned.
        pub fn restart(self: *Self, io: std.Io) void {
            assert(self.reload_state.load(.acquire) == .parked);

            for (self.endpoints) |endpoint| {
                assert(endpoint.preparing.load(.acquire) == 0 and !endpoint.tick_active);
                assert(endpoint.event_read.load(.acquire) == endpoint.event_write.load(.acquire));

                for (endpoint.routes, endpoint.occupied, endpoint.credit) |*route, *occupied, *credit| {
                    route.* = null;
                    occupied.store(false, .release);
                    _ = credit.fetchAnd(~Service.active, .acq_rel);
                }
            }

            @memset(self.bindings, null);
            @memset(self.selected_routes, null);
            self.engine.restart(io);
            const native = self.engine.networking.inheritance.?;
            native.pause(io, false);
            self.quiescing = false;
            self.reload_state.store(.running, .release);
        }

        pub fn drained(self: *const Self) bool {
            for (self.endpoints) |endpoint| {
                if (endpoint.preparing.load(.acquire) != 0) return false;

                for (endpoint.moves) |*move| if (move.state.load(.acquire) != .idle) return false;
            }

            return self.engine.drained();
        }

        pub fn discardInputs(self: *Self) void {
            for (self.endpoints) |endpoint| while (endpoint.next()) |event| if (event == .input) endpoint.release(event.input.handle);
        }

        fn deliver(self: *Self, io: std.Io) !void {
            for (self.output_ready, 0..) |*word, word_index| {
                var ready = word.swap(0, .acq_rel);
                while (ready != 0) {
                    const index = word_index * @bitSizeOf(usize) + @ctz(ready);
                    ready &= ready - 1;
                    assert(index < self.endpoints.len);
                    const endpoint = self.endpoints[index];
                    const queue = &self.queues[index];
                    const was_empty = queue.head == null;
                    var batch = endpoint.outputBatch();
                    while (batch.next()) |packet| {
                        assert(packet.page < endpoint.output.pages.len);
                        const pending = &self.pending[queue.pending_base + packet.page];
                        assert(pending.source == null and pending.loans == 0);
                        self.delivery_ready = true;
                        pending.source = endpoint;
                        pending.order = queue.next_order;
                        queue.next_order += 1;
                        if (queue.tail) |tail| assert(tail.order < pending.order);
                        pending.packet = packet;
                        pending.next = null;
                        pending.frame = null;
                        pending.group = 0;
                        @memset(pending.sizes, 0);
                        assert(packet.recipients.handles.len <= self.sequence_members.len);
                        pending.remaining.bit_length = packet.recipients.handles.len;
                        pending.remaining.unsetAll();
                        if (packet.recipients.mask.len == 0) {
                            pending.remaining.setRangeValue(.{ .start = 0, .end = packet.recipients.len }, true);
                        } else {
                            const words = (pending.remaining.bit_length + @bitSizeOf(usize) - 1) / @bitSizeOf(usize);
                            assert(words == packet.recipients.mask.len);
                            @memcpy(pending.remaining.masks[0..words], packet.recipients.mask[0..words]);
                        }
                        pending.remaining_count = packet.recipients.len;
                        if (queue.tail) |tail| tail.next = pending else queue.head = pending;
                        queue.tail = pending;
                    }
                    if (was_empty and queue.head != null) self.activate(index);
                }
            }
            try self.deliverFrames(io);
        }

        fn activate(self: *Self, index: usize) void {
            const queue = &self.queues[index];
            assert(queue.head != null and queue.next == null);
            assert(queue.tail != null and queue.tail.?.next == null);
            assert(self.active_head != index and self.active_tail != index);
            if (self.active_tail) |tail| self.queues[tail].next = index else self.active_head = index;
            self.active_tail = index;
        }

        fn block(self: *Self, index: usize) void {
            assert(index < self.engine.connections.len);
            self.blocked.set(index);
            self.blocked_words.insert(index / @bitSizeOf(usize));
        }

        fn deliverFrames(self: *Self, io: std.Io) !void {
            self.delivery_ready = self.delivery_ready or self.engine.delivery_ready;
            self.engine.delivery_ready = false;
            for (self.frames) |*frame| {
                if (frame.task.state.load(.acquire) == .complete and !frame.completion_observed) {
                    assert(frame.packet != null);
                    frame.completion_observed = true;
                    self.delivery_ready = true;
                }
                if (frame.packet) |pending| {
                    if (pending.frame != frame and frame.loan.references == 0) {
                        assert(frame.task.state.load(.acquire) == .idle);
                        pending.loans -= 1;
                        frame.packet = null;
                        self.delivery_ready = true;
                    }
                }
            }
            if (!self.delivery_ready) return;
            self.delivery_ready = false;
            for (self.frames) |*frame| {
                if (frame.packet == null or frame.task.state.load(.acquire) != .queued) break;
                assert(!frame.ready);
            } else return;
            var capacity_waiting = false;
            var prepared = false;
            for (self.blocked_words.values()) |word| self.blocked.masks[word] = 0;
            self.blocked_words.clear();
            self.engine.output_pressure = false;
            const last = self.active_tail;
            while (self.active_head) |index| {
                const queue = &self.queues[index];
                assert(queue.head != null);
                self.active_head = queue.next;
                if (self.active_head == null) self.active_tail = null;
                queue.next = null;
                var recycled: [Service.batch_max]shared.RawPacket = undefined;
                var recycled_count: usize = 0;
                defer self.endpoints[index].recycle(io, recycled[0..recycled_count]);
                var previous: ?*Pending = null;
                var next = queue.head;
                while (next) |pending| {
                    assert(pending.order > 0);
                    var available = false;
                    var in_flight = false;
                    for (self.frames) |frame| {
                        const held = frame.packet orelse {
                            available = true;
                            break;
                        };
                        assert(held.source != null and held.order > 0);
                        if (held.source == self.endpoints[index] and held.order >= pending.order) in_flight = true;
                    }
                    // Later completions must still be consumed when the framing pool is full.
                    if (!available and !in_flight) {
                        capacity_waiting = true;
                        break;
                    }
                    prepared = true;
                    const endpoint = pending.source.?;
                    assert(endpoint == self.endpoints[index]);
                    const packet = pending.packet;
                    const charge = endpoint.framedBound(packet.bytes.len);
                    var checking = pending.remaining.iterator(.{});
                    while (checking.next()) |recipient| {
                        const handle = packet.recipients.at(recipient);
                        const credit = endpoint.credit[handle.index].load(.acquire);
                        if (credit >> 32 != handle.generation or credit & Service.active == 0) {
                            pending.complete(recipient);
                            self.delivery_ready = true;
                            continue;
                        }
                        const native = endpoint.routes[handle.index] orelse unreachable;
                        if (self.engine.discardGroup(native)) {
                            endpoint.refund(handle, charge);
                            pending.complete(recipient);
                            self.delivery_ready = true;
                        }
                    }
                    const needs_frame = pending.remaining_count != 0;
                    if (pending.frame == null and needs_frame) _ = try self.prepareSequence(index, pending);
                    if (pending.frame == null and needs_frame) {
                        const free = for (self.frames) |*frame| {
                            if (frame.packet == null) break frame;
                        } else null;
                        if (free) |frame| {
                            const known_protocol = if (packet.group.protocol) |number| selected: {
                                for (self.config.protocols.values, 0..) |value, protocol_index|
                                    if (value.number == number) break :selected protocol_index;
                                unreachable;
                            } else null;
                            const groups = if (known_protocol != null) @as(usize, 2) else self.config.protocols.values.len * 2;
                            for (0..groups) |offset| {
                                const group = if (known_protocol) |protocol_index|
                                    protocol_index * 2 + (pending.group + offset) % 2
                                else
                                    (pending.group + offset) % groups;
                                const selected = self.config.protocols.values[group / 2];
                                const compressed = group % 2 != 0;
                                var eligible = false;
                                assert(frame.targets == null);
                                var selecting = pending.remaining.iterator(.{});
                                while (selecting.next()) |recipient_index| {
                                    const handle = packet.recipients.at(recipient_index);
                                    const native = endpoint.routes[handle.index] orelse unreachable;
                                    const connection = &self.engine.connections[native.index];
                                    if (!self.engine.groupReady(native, index, packet.group)) continue;
                                    if (self.blocked.isSet(native.index) or connection.codec.state.load(.acquire) != .idle or connection.received != 0) continue;
                                    if (connection.protocol.?.number != selected.number or Endpoint.compressed(&connection.lifecycle.?) != compressed) continue;
                                    if (pending.sizes[group] != 0 and !self.engine.canSendFramed(native, pending.sizes[group], .{ .sockets = &self.socket_budget })) continue;
                                    if (self.engine.codec != null and Endpoint.encrypted(&connection.lifecycle.?)) {
                                        if (self.target_free_count == 0) continue;
                                        self.engine.reserveGroupOutput(native, packet.group) catch {
                                            self.block(native.index);
                                            continue;
                                        };
                                        const target = self.engine.prepareSend(native) catch |err| switch (err) {
                                            error.Full => {
                                                self.block(native.index);
                                                continue;
                                            },
                                            error.Closed => {
                                                endpoint.refund(handle, charge);
                                                pending.complete(recipient_index);
                                                self.delivery_ready = true;
                                                continue;
                                            },
                                        };
                                        self.engine.claimGroup(native, index, packet.group);
                                        self.target_free_count -= 1;
                                        const slot = self.target_free[self.target_free_count];
                                        const destination = &self.send_targets[slot];
                                        destination.* = target;
                                        destination.index = slot;
                                        destination.recipient = recipient_index;
                                        destination.next = frame.targets;
                                        frame.targets = destination;
                                    }
                                    eligible = true;
                                }
                                if (!eligible) continue;
                                frame.sequence = null;
                                frame.sequence_count = 1;
                                frame.sequence_next = null;
                                frame.completion_owner = .network;
                                frame.completion_observed = false;
                                frame.packet = pending;
                                pending.loans += 1;
                                frame.protocol = selected.number;
                                frame.compressed = compressed;
                                pending.frame = frame;
                                pending.group = if (known_protocol != null) (group + 1) % 2 else (group + 1) % groups;
                                if (self.engine.codec) |codec| {
                                    codec.submit(&frame.task, .{ .frame = .{ .protocol = selected.number, .storage = endpoint.output.framingStorage(packet), .length = packet.bytes.len, .threshold = if (compressed) self.config.compression_threshold else null, .output = frame.bytes, .targets = frame.targets } });
                                } else {
                                    assert(frame.loan.references == 0 and frame.loan.sockets == 0);
                                    frame.loan = Engine.Loan.framed(try Endpoint.sharedFrame(selected.number, &self.engine.workspaces, endpoint.output.framingStorage(packet), packet.bytes.len, if (compressed) self.config.compression_threshold else null, frame.bytes), packet.bytes);
                                    frame.ready = true;
                                    self.instruments.encoded_packets.add(1);
                                    self.instruments.encoded_bytes.add(packet.bytes.len);
                                    self.instruments.framed_bytes.add(frame.loan.length());
                                }
                                break;
                            }
                        }
                    }
                    if (pending.frame) |frame| {
                        if (!frame.ready and frame.completion_owner == .network) {
                            if (Codec.take(&frame.task)) |result| {
                                self.delivery_ready = true;
                                var next_target = frame.targets;
                                while (next_target) |target| {
                                    next_target = target.next;
                                    if (target.sent) {
                                        if (frame.sequence != null) {
                                            var member: ?*Frame = frame;
                                            var position: usize = 0;
                                            while (position < frame.sequence_count) : (position += 1) {
                                                const entry = member.?.packet.?;
                                                member = member.?.sequence_next;
                                                if (target.packets & (@as(u32, 1) << @intCast(position)) == 0) continue;
                                                const recipient = self.sequence_slots[target.index * @min(self.frames.len, Service.batch_max) + position];
                                                assert(entry.packet.group.index == (if (packet.group.count > 1) position else 0) and entry.remaining.isSet(recipient));
                                                const encoded = entry.frame.?.sequence.?.bytes;
                                                const handle = entry.packet.recipients.at(recipient);
                                                assert(handle.index == target.recipient);
                                                const native = endpoint.routes[handle.index].?;
                                                entry.complete(recipient);
                                                self.delivery_ready = true;
                                                self.engine.completeGroupPacket(native, index, entry.packet.group);
                                                endpoint.refund(handle, endpoint.framedBound(entry.packet.bytes.len) - encoded.len);
                                                self.instruments.fanout_bytes.add(encoded.len);
                                            }
                                            assert(member == null);
                                        } else {
                                            assert(pending.remaining.isSet(target.recipient));
                                            pending.complete(target.recipient);
                                            self.delivery_ready = true;
                                            const native = endpoint.routes[packet.recipients.at(target.recipient).index].?;
                                            self.engine.completeGroupPacket(native, index, packet.group);
                                            const bytes = (try result).bytes;
                                            endpoint.refund(packet.recipients.at(target.recipient), charge - bytes.len);
                                            self.instruments.fanout_bytes.add(bytes.len);
                                        }
                                    }
                                    self.target_free[self.target_free_count] = target.index;
                                    self.target_free_count += 1;
                                }
                                frame.targets = null;
                                var member = if (frame.sequence_count > 1) frame.sequence_next else null;
                                while (member) |entry| {
                                    assert(entry.completion_owner == .sequence and entry.packet != null);
                                    entry.completion_owner = .network;
                                    member = entry.sequence_next;
                                }
                                assert(frame.loan.references == 0 and frame.loan.sockets == 0);
                                frame.loan = Engine.Loan.framed((try result).bytes, packet.bytes);
                                frame.ready = true;
                                self.instruments.encoded_packets.add(1);
                                self.instruments.encoded_bytes.add(packet.bytes.len);
                                self.instruments.framed_bytes.add(frame.loan.length());
                            }
                        }
                        if (frame.ready) {
                            const length = frame.loan.length();
                            for (self.config.protocols.values, 0..) |selected, protocol_index| if (selected.number == frame.protocol) {
                                pending.sizes[protocol_index * 2 + @intFromBool(frame.compressed)] = length;
                            };
                            const fanout = self.instruments.fanout.start();
                            defer fanout.end();
                            var sending = pending.remaining.iterator(.{});
                            while (sending.next()) |recipient| {
                                const handle = packet.recipients.at(recipient);
                                const native = endpoint.routes[handle.index] orelse unreachable;
                                if (!self.engine.groupReady(native, index, packet.group) or self.blocked.isSet(native.index)) continue;
                                const connection = &self.engine.connections[native.index];
                                if (connection.protocol.?.number != frame.protocol or Endpoint.compressed(&connection.lifecycle.?) != frame.compressed) continue;
                                assert(frame.loan.references > frame.loan.sockets);
                                assert(self.socket_budget.used < self.frames.len);
                                self.engine.reserveGroupOutput(native, packet.group) catch {
                                    self.block(native.index);
                                    continue;
                                };
                                self.engine.claimGroup(native, index, packet.group);
                                self.engine.sendFramed(io, native, &frame.loan, .{ .sockets = &self.socket_budget }) catch |err| switch (err) {
                                    error.Full => {
                                        self.block(native.index);
                                        continue;
                                    },
                                    error.Closed => {
                                        endpoint.refund(handle, charge);
                                        pending.complete(recipient);
                                        self.delivery_ready = true;
                                        continue;
                                    },
                                    else => return err,
                                };
                                assert(frame.loan.references > frame.loan.sockets);
                                assert(self.socket_budget.used < self.frames.len);
                                pending.complete(recipient);
                                self.delivery_ready = true;
                                self.engine.completeGroupPacket(native, index, packet.group);
                                endpoint.refund(handle, charge - length);
                                self.instruments.fanout_bytes.add(length);
                            }
                            assert(frame.loan.references > frame.loan.sockets);
                            frame.loan.release();
                            assert(frame.loan.references >= frame.loan.sockets);
                            frame.ready = false;
                            pending.frame = null;
                            if (frame.loan.references == 0) {
                                assert(frame.completion_owner == .network);
                                frame.packet = null;
                                pending.loans -= 1;
                            }
                        }
                    }
                    if (pending.remaining_count == 0 and pending.frame == null and pending.loans == 0) {
                        next = pending.next;
                        if (previous) |before| before.next = next else queue.head = next;
                        if (queue.tail == pending) queue.tail = previous;
                        pending.source = null;
                        recycled[recycled_count] = packet;
                        recycled_count += 1;
                        if (recycled_count == recycled.len) {
                            endpoint.recycle(io, &recycled);
                            recycled_count = 0;
                        }
                        continue;
                    }
                    var blocking = pending.remaining.iterator(.{});
                    while (blocking.next()) |recipient| {
                        const handle = packet.recipients.at(recipient);
                        const native = endpoint.routes[handle.index].?;
                        if (self.engine.groupReady(native, index, packet.group)) self.block(native.index);
                    }
                    previous = pending;
                    next = pending.next;
                }
                if (queue.head != null) self.activate(index);
                if (index == last.?) break;
            }
            if (self.active_head) |first| if (self.active_tail.? != first) {
                const queue = &self.queues[first];
                self.active_head = queue.next;
                queue.next = null;
                self.activate(first);
            };
            if (capacity_waiting) for (self.frames) |frame| {
                if (frame.packet == null) {
                    self.delivery_ready = true;
                    self.engine.networking.notify(io);
                    break;
                }
            };
            self.instruments.empty_preparations.add(@intFromBool(!prepared));
        }

        pub fn run(self: *Self, io: std.Io) !void {
            while (try self.advance(io, null)) {}
        }

        pub fn advance(self: *Self, io: std.Io, deadline: ?std.Io.Clock.Timestamp) !bool {
            self.started = true;
            {
                const iteration = self.instruments.iteration.start();
                defer iteration.end();
                if (self.stopping.load(.acquire) or self.reload_state.load(.acquire) != .running) self.discardInputs();
                if (self.config.metrics) |registry| _ = registry.sequence.fetchAdd(1, .release);

                if (self.stopping.load(.acquire)) {
                    self.quiescing = false;
                    self.reload_state.store(.running, .release);
                    self.engine.beginShutdown(io);
                }

                if (self.reload_state.load(.acquire) == .requested and !self.quiescing) {
                    const native = self.engine.networking.inheritance.?;
                    self.engine.reloading = true;
                    self.engine.wakeAll();
                    native.pause(io, true);
                    self.quiescing = true;
                    for (self.engine.connections) |connection| {
                        const handle = connection.handle orelse continue;
                        const selected = connection.protocol orelse continue;
                        inline for (Endpoint.versions, 0..) |Version, index| {
                            if (selected.number == Version.protocol_number and self.reload_removed[index]) {
                                std.log.info("event=reload_protocol_removed connection={d}:{d} protocol={d}", .{ handle.index, handle.generation, selected.number });
                                self.engine.disconnect(io, handle);
                            }
                        }
                    }
                }

                for (self.inputs_ready, 0..) |*word, word_index| {
                    var ready = word.swap(0, .acq_rel);
                    while (ready != 0) {
                        const source_index = word_index * @bitSizeOf(usize) + @ctz(ready);
                        ready &= ready - 1;
                        const endpoint = self.endpoints[source_index];
                        for (endpoint.activity, 0..) |*activity, activity_index| {
                            var changed = activity.swap(0, .acq_rel);
                            while (changed != 0) {
                                const index = activity_index * @bitSizeOf(usize) + @ctz(changed);
                                changed &= changed - 1;
                                assert(index < endpoint.routes.len);
                                const native = endpoint.routes[index] orelse continue;
                                const binding = self.bindings[native.index].?;
                                assert(binding.endpoint == endpoint and binding.handle.index == index);
                                const release = endpoint.releases[index].swap(0, .acq_rel);
                                if (release != 0) {
                                    assert(release == binding.handle.generation);
                                    self.engine.releaseInput(io, binding.native);
                                }
                                const disconnect = endpoint.disconnects[index].swap(0, .acq_rel);
                                if (disconnect == binding.handle.generation or endpoint.stopping.load(.acquire)) self.engine.disconnect(io, binding.native);
                            }
                        }
                    }
                }

                for (self.transfers_ready, 0..) |*word, word_index| {
                    var ready = word.swap(0, .acq_rel);
                    while (ready != 0) {
                        const source_index = word_index * @bitSizeOf(usize) + @ctz(ready);
                        ready &= ready - 1;
                        assert(source_index < self.endpoints.len);
                        const source = self.endpoints[source_index];
                        for (source.committed_moves, 0..) |*moves, move_word| {
                            var committed = moves.swap(0, .acq_rel);
                            while (committed != 0) {
                                const index = move_word * @bitSizeOf(usize) + @ctz(committed);
                                assert(index < source.moves.len);
                                const bit = @as(usize, 1) << @intCast(index % @bitSizeOf(usize));
                                committed &= committed - 1;
                                const move = &source.moves[index];
                                assert(move.state.load(.acquire) == .committed);
                                assert(move.next_staged == null);
                                defer if (move.state.load(.acquire) == .committed) {
                                    _ = moves.fetchOr(bit, .release);
                                    _ = word.fetchOr(source.readiness.?.mask, .release);
                                };

                                const target = move.destination;
                                const credit = source.credit[index].load(.acquire);
                                if (credit >> 32 != move.generation or credit & Service.active == 0 or source.stopping.load(.acquire) or target.stopping.load(.acquire)) {
                                    const held = target.occupied[move.slot].swap(false, .release);
                                    assert(held);
                                    move.state.store(.idle, .release);
                                    continue;
                                }

                                const consumed = source.output.ready.head.load(.acquire);
                                if (consumed -% move.boundary > std.math.maxInt(usize) / 2 or credit & (Service.active - 1) != source.config.buffer_bytes) continue;
                                if (source.event_write.load(.monotonic) -% source.event_read.load(.acquire) == source.events.len) continue;

                                const native = source.routes[index].?;
                                const generation = (target.credit[move.slot].load(.acquire) >> 32) + 1;
                                if (generation > std.math.maxInt(u32)) {
                                    const held = target.occupied[move.slot].swap(false, .release);
                                    assert(held);
                                    move.state.store(.idle, .release);
                                    continue;
                                }

                                if (!try self.engine.reconfigure(io, native)) continue;

                                const connection = &self.engine.connections[native.index];
                                const protocol_number = connection.protocol.?.number;

                                for (target.config.protocols) |*protocol| {
                                    if (protocol.number == protocol_number) {
                                        connection.protocol = protocol;
                                        break;
                                    }
                                }

                                const old: network.Handle = .{ .index = @intCast(index), .generation = move.generation };
                                const next: network.Handle = .{ .index = move.slot, .generation = @intCast(generation) };
                                _ = source.credit[index].fetchAnd(~Service.active, .acq_rel);
                                source.routes[index] = null;
                                target.routes[move.slot] = native;
                                target.credit[move.slot].store(generation << 32, .release);
                                self.bindings[native.index] = .{
                                    .endpoint = target,
                                    .handle = next,
                                    .native = native,
                                    .configuring = true,
                                    .previous = .{ .endpoint = source, .handle = old },
                                };
                                move.state.store(.idle, .release);
                                const announced = source.push(.{ .left = old });
                                assert(announced);
                                const held = source.occupied[index].swap(false, .release);
                                assert(held);
                                std.log.info("event=session_transfer connection={d}:{d} source={d}:{d} destination={d}:{d}", .{ native.index, native.generation, old.index, old.generation, next.index, next.generation });
                            }
                        }
                    }
                }

                try self.deliver(io);
                const networking = self.instruments.networking.start();
                defer networking.end();
                self.engine.progress(io);
                if (deadline) |until| self.engine.poll.wakeAt(until.raw.nanoseconds);
                try self.engine.receive(io);
                self.engine.progress(io);
                for (self.progress_ready, 0..) |*word, word_index| {
                    var ready = word.*;
                    word.* = 0;
                    while (ready != 0) {
                        const index = word_index * @bitSizeOf(usize) + @ctz(ready);
                        ready &= ready - 1;
                        self.endpoints[index].notifyOutput(io);
                    }
                }

                if (self.quiescing) {
                    try self.engine.spill(io);
                    var empty_output = true;

                    for (self.endpoints) |endpoint| empty_output = empty_output and endpoint.preparing.load(.acquire) == 0;

                    if (empty_output) {
                        const parked = try self.engine.park(io);
                        const native = self.engine.networking.inheritance.?;

                        if (parked and native.ready()) self.reload_state.store(.parked, .release);
                    }
                }
                if (self.stopping.load(.acquire) and self.drained()) return false;
                if (self.reload_state.load(.acquire) == .parked) return false;
            }
            return true;
        }

        pub fn attached(self: *Self, io: std.Io, profile: engine.Profile) bool {
            if (self.bindings[profile.connection.index]) |*binding| {
                assert(binding.configuring and std.meta.eql(binding.native, profile.connection));
                if (binding.previous == null) {
                    const endpoint = binding.endpoint;
                    endpoint.credit[binding.handle.index].store((@as(u64, binding.handle.generation) << 32) | Service.active | endpoint.config.buffer_bytes, .release);
                    if (!endpoint.push(.{ .ready = binding.handle })) {
                        _ = endpoint.credit[binding.handle.index].fetchAnd(~Service.active, .acq_rel);
                        return false;
                    }
                    binding.configuring = false;
                    return true;
                }
                const previous = binding.previous.?;
                if (previous.endpoint.departed[previous.handle.index].load(.acquire) < previous.handle.generation) return false;

                const endpoint = binding.endpoint;
                var event: Event = .{ .joined = .{
                    .handle = binding.handle,
                    .protocol = profile.protocol,
                    .uuid = profile.uuid,
                    .name = undefined,
                    .name_len = @intCast(profile.name.len),
                    .cause = .transfer,
                } };
                @memcpy(event.joined.name[0..profile.name.len], profile.name);
                endpoint.credit[binding.handle.index].store((@as(u64, binding.handle.generation) << 32) | Service.active | endpoint.config.buffer_bytes, .release);
                if (!endpoint.push(event)) {
                    _ = endpoint.credit[binding.handle.index].fetchAnd(~Service.active, .acq_rel);
                    return false;
                }

                binding.configuring = false;
                binding.previous = null;
                return true;
            }

            return self.bind(io, profile, .play);
        }

        pub fn restorePlayers(self: *Self, io: std.Io) !void {
            for (self.engine.connections) |*connection| {
                const handle = connection.handle orelse continue;
                assert(connection.resumed);
                if (connection.closing) continue;
                if (!self.bind(io, .{ .connection = handle, .protocol = connection.protocol.?.number, .uuid = connection.state.uuid, .name = connection.state.name[0..connection.state.name_len] }, .configuring)) return error.ResumeRouteUnavailable;
                connection.attached = true;
            }
        }

        fn bind(self: *Self, io: std.Io, profile: engine.Profile, readiness: enum { configuring, play }) bool {
            assert(self.bindings[profile.connection.index] == null);
            const decision = self.select(profile);
            const selected = switch (decision) {
                .destination => |index| index,
                .pending => return false,
                .reject => {
                    self.engine.disconnect(io, profile.connection);
                    return false;
                },
            };
            if (selected >= self.endpoints.len) {
                self.engine.disconnect(io, profile.connection);
                return false;
            }
            const endpoint = self.endpoints[selected];
            if (endpoint.stopping.load(.acquire)) return false;

            var supported = false;

            for (endpoint.config.protocols) |protocol| supported = supported or protocol.number == profile.protocol;
            if (!supported) {
                self.engine.disconnect(io, profile.connection);
                return false;
            }

            for (endpoint.routes, 0..) |*route, index| {
                if (endpoint.occupied[index].cmpxchgStrong(false, true, .acq_rel, .acquire) != null) continue;
                assert(route.* == null);
                const generation = (endpoint.credit[index].load(.acquire) >> 32) + 1;
                if (generation > std.math.maxInt(u32)) {
                    endpoint.occupied[index].store(false, .release);
                    continue;
                }

                const handle: network.Handle = .{ .index = @intCast(index), .generation = @intCast(generation) };
                var event: Event = .{ .joined = .{
                    .handle = handle,
                    .protocol = profile.protocol,
                    .uuid = profile.uuid,
                    .name = undefined,
                    .name_len = @intCast(profile.name.len),
                    .ready = readiness == .play,
                } };

                if (self.engine.connections[profile.connection.index].resumed) event.joined.cause = .reload;
                @memcpy(event.joined.name[0..profile.name.len], profile.name);
                route.* = profile.connection;
                self.bindings[profile.connection.index] = .{ .endpoint = endpoint, .handle = handle, .native = profile.connection, .configuring = readiness == .configuring };
                endpoint.credit[index].store((generation << 32) | (if (readiness == .play) Service.active | endpoint.config.buffer_bytes else @as(u64, 0)), .release);
                if (endpoint.push(event)) {
                    std.log.info("event=session_routed endpoint={d} local={d}:{d} connection={d}:{d}", .{ selected, handle.index, handle.generation, profile.connection.index, profile.connection.generation });
                    return true;
                }

                endpoint.credit[index].store(generation << 32, .release);
                route.* = null;
                endpoint.occupied[index].store(false, .release);
                self.bindings[profile.connection.index] = null;
                return false;
            }

            return false;
        }

        pub fn input(self: *Self, handle: network.Handle, protocol: i32, packets: session_protocol.Packets) engine.Disposition {
            if (self.reload_state.load(.acquire) != .running) return .consumed;

            const binding = self.bindings[handle.index].?;
            assert(std.meta.eql(binding.native, handle));
            if (binding.endpoint.moves[binding.handle.index].state.load(.acquire) == .committed) return .consumed;
            return if (binding.endpoint.push(.{ .input = .{ .handle = binding.handle, .protocol = protocol, .packets = packets } })) .borrowed else .blocked;
        }

        pub fn status(self: *Self, protocol: i32, packet: []const u8, output: []u8) !?[]const u8 {
            const request: session_protocol.StatusRequest = .{
                .protocol = protocol,
                .online_players = self.engine.admitted,
                .maximum_players = self.config.max_players,
            };
            return self.hooks.statusPacket(request, packet, output);
        }

        pub fn handshake(self: *Self, packet: []const u8) !session_protocol.Handshake {
            return self.hooks.handshake(packet);
        }

        pub fn sessionInput(self: *Self, comptime phase_kind: session_protocol_input.Phase, profile: session_protocol.Profile, io: std.Io, now: i96, packet: []const u8, output: []u8) !session_protocol_input.Effect(phase_kind) {
            return self.hooks.input(phase_kind, .{ .profile = profile, .io = io, .now = now }, packet, output);
        }

        pub fn play(self: *Self, profile: session_protocol.Profile, event: session_protocol.PlayEvent, output: []u8) !?[]const u8 {
            return self.hooks.play(Endpoint.versions, profile, event, output);
        }

        pub fn select(self: *Self, profile: engine.Profile) Route(usize) {
            if (self.selected_routes[profile.connection.index]) |selected|
                if (std.meta.eql(selected.connection, profile.connection))
                    return .{ .destination = selected.destination };

            const selected = switch (self.router.route(profile)) {
                .destination => |id| blk: {
                    for (self.config.destinations, 0..) |destination, index| {
                        if (std.meta.eql(destination, id)) break :blk index;
                    }
                    return .reject;
                },
                .pending => return .pending,
                .reject => return .reject,
            };
            const endpoint = self.endpoints[selected];
            var supported = false;
            for (endpoint.config.protocols) |protocol| supported = supported or protocol.number == profile.protocol;
            if (!supported) return .reject;
            self.selected_routes[profile.connection.index] = .{ .connection = profile.connection, .destination = selected };
            return .{ .destination = selected };
        }

        pub fn login(self: *Self, io: std.Io, handle: network.Handle, state: *session_protocol.State, number: i32, event: session_protocol.PhaseEvent, output: []u8) !session_protocol.LoginStep {
            const scope: session_protocol.PhaseScope = .{
                .profile = .{ .connection = handle, .protocol = number, .uuid = state.uuid, .name = state.name[0..state.name_len] },
                .destination = null,
                .identity = &state.uuid,
                .io = io,
                .compression_threshold = self.config.compression_threshold,
            };
            inline for (Endpoint.versions) |Version| {
                if (number == Version.protocol_number)
                    return self.hooks.phase(.login, scope, event, output);
            }
            return error.UnsupportedProtocol;
        }

        pub fn configuration(self: *Self, io: std.Io, handle: network.Handle, state: *session_protocol.State, number: i32, event: session_protocol.PhaseEvent, output: []u8) !session_protocol.ConfigurationStep {
            var destination: ?usize = null;
            if (self.bindings[handle.index]) |binding| {
                for (self.endpoints, 0..) |endpoint, index| if (endpoint == binding.endpoint) {
                    destination = index;
                    break;
                };
            } else if (self.selected_routes[handle.index]) |selected| {
                if (std.meta.eql(selected.connection, handle)) destination = selected.destination;
            }
            const scope: session_protocol.PhaseScope = .{
                .profile = .{ .connection = handle, .protocol = number, .uuid = state.uuid, .name = state.name[0..state.name_len] },
                .destination = destination,
                .io = io,
            };
            inline for (Endpoint.versions) |Version| {
                if (number == Version.protocol_number)
                    return self.hooks.phase(.configuration, scope, event, output);
            }
            return error.UnsupportedProtocol;
        }

        pub fn detached(self: *Self, handle: network.Handle) bool {
            const binding = self.bindings[handle.index].?;
            assert(std.meta.eql(binding.native, handle));
            _ = binding.endpoint.credit[binding.handle.index].fetchAnd(~Service.active, .acq_rel);
            if ((!binding.configuring or binding.previous == null) and !binding.endpoint.push(.{ .left = binding.handle })) return false;
            binding.endpoint.routes[binding.handle.index] = null;
            self.bindings[handle.index] = null;
            const held = binding.endpoint.occupied[binding.handle.index].swap(false, .release);
            assert(held);
            return true;
        }

        pub fn closed(self: *Self, handle: network.Handle) void {
            if (self.selected_routes[handle.index]) |selected| {
                if (std.meta.eql(selected.connection, handle)) self.selected_routes[handle.index] = null;
            }
            self.hooks.closed(handle);
        }

        pub fn sent(self: *Self, _: std.Io, handle: network.Handle, bytes: usize) void {
            const binding = self.bindings[handle.index].?;
            assert(std.meta.eql(binding.native, handle));
            binding.endpoint.refund(binding.handle, bytes);
            const ready = binding.endpoint.readiness.?;
            ready.progress.* |= ready.mask;
        }
    };
}

const TestEndpoint = struct {
    pub const versions = .{};
    pub const Protocols = struct { values: [2]session_protocol.Protocol = .{ .{ .number = 1 }, .{ .number = 2 } } };
    pub const Connection = usize;
    pub const Workspaces = struct { headers: bool = false };
    pub fn initWorkspaces(_: std.mem.Allocator) !Workspaces {
        return .{};
    }
    pub fn deinitWorkspaces(_: *Workspaces) void {}
    pub fn clear(_: *Connection) void {}
    pub fn needsDecoded(_: ?usize) bool {
        return false;
    }
    pub fn compressed(_: *const Connection) bool {
        return false;
    }
    pub fn encrypted(connection: *const Connection) bool {
        return connection.* != std.math.maxInt(usize);
    }
    pub fn encrypt(connection: *Connection, source: []const u8, destination: []u8) void {
        @memcpy(destination, source);
        connection.* += source.len;
    }
    pub fn send(connection: *Connection, bytes: []u8) void {
        connection.* += bytes.len;
    }
    pub fn receive(_: *Connection, _: []u8) void {
        unreachable;
    }
    pub fn frame(_: ?*const Connection, _: []const u8, _: usize) anyerror!session_protocol.Frame {
        unreachable;
    }
    pub fn decode(_: *Connection, _: *Workspaces, _: []const u8, _: []u8, _: ?usize) anyerror![]const u8 {
        unreachable;
    }
    pub fn control(_: *Connection, _: *Workspaces, _: session_protocol.Packet, _: []u8, _: ?usize) anyerror!session_protocol.Fragments {
        unreachable;
    }
    pub fn sharedFrame(number: i32, workspace: *Workspaces, storage: []u8, length: usize, _: ?usize, _: []u8) ![]const u8 {
        if (workspace.headers) {
            storage[shared.headroom - 2] = @intCast(number);
            storage[shared.headroom - 1] = @intCast(length);
            return storage[shared.headroom - 2 ..][0 .. length + 2];
        }
        return storage[shared.headroom..][0..length];
    }
};
const TestHooks = struct {
    notifications: usize = 0,
    events: []const network.Event = &.{},
    pub fn closed(_: *@This(), _: network.Handle) void {}
    pub fn notify(self: *@This(), _: std.Io) void {
        self.notifications += 1;
    }
    pub fn queueReceive(_: *@This(), _: std.Io, _: network.Handle, _: []u8) network.QueueError!void {
        unreachable;
    }
    pub fn queueSend(_: *@This(), _: std.Io, _: network.Handle, _: []const std.posix.iovec_const) network.QueueError!void {
        unreachable;
    }
    pub fn close(_: *@This(), _: std.Io, _: network.Handle, _: network.CloseReason) void {
        unreachable;
    }
    pub fn releaseConnection(_: *@This(), _: std.Io, _: network.Handle) void {
        unreachable;
    }
    pub fn submit(_: *@This(), _: std.Io) !void {
        unreachable;
    }
    pub fn poll(self: *@This(), _: std.Io, _: ?std.Io.Timeout, events: []network.Event) !usize {
        assert(self.events.len <= events.len);
        const count = self.events.len;
        @memcpy(events[0..count], self.events);
        self.events = &.{};
        return count;
    }
};

test "framing and burst exhaustion preserve ordering and isolate slow recipients" {
    const Hooks = TestHooks;
    const Router = SingleSimulation;
    const Owner = Worker(TestEndpoint, Hooks, Router);
    var memory: [256 * 1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&memory);
    const allocator = fixed.allocator();
    var hooks: Hooks = .{};
    var router: Router = .{};
    var protocols: TestEndpoint.Protocols = .{};
    const transport: network.Transport = .{ .context = &hooks, .vtable = network.Transport.adapter(Hooks) };
    const endpoint = try Service.init(allocator, std.testing.io, transport, .{
        .connections = 3,
        .buffer_bytes = 4096,
        .pages = 4,
        .page_bytes = 1500,
        .protocols = &protocols.values,
    });
    defer endpoint.deinit();
    const owner = try Owner.init(allocator, transport, .{
        .connections = 3,
        .max_players = 3,
        .buffer_bytes = 4096,
        .connection_bytes = 512,
        .output_burst_slots = 1,
        .framing_slots = 2,
        .max_pending_wire_bytes = 8192,
        .compression_threshold = null,
        .protocols = &protocols,
        .hooks = &hooks,
        .router = &router,
        .destinations = &.{0},
    }, &.{endpoint});
    defer {
        owner.abort(std.testing.io);
        owner.deinit();
    }
    const assigned = fixed.end_index;
    const handles = [_]network.Handle{ .{ .index = 0, .generation = 1 }, .{ .index = 1, .generation = 1 }, .{ .index = 2, .generation = 1 } };
    for (handles) |handle| {
        const connection = &owner.engine.connections[handle.index];
        owner.engine.setHandle(handle.index, handle);
        connection.protocol = &protocols.values[0];
        connection.lifecycle = 0;
        connection.state.phase = .play;
        endpoint.routes[handle.index] = handle;
        endpoint.credit[handle.index].store((@as(u64, 1) << 32) | Service.active | 4096, .release);
    }
    var first = try endpoint.reserve(1000);
    @memset(first.bytes, 11);
    try first.publish(1000, handles[0..2]);
    var second = try endpoint.reserve(10);
    @memset(second.bytes, 22);
    try second.publish(10, handles[1..2]);
    var third = try endpoint.reserve(10);
    @memset(third.bytes, 33);
    try third.publish(10, handles[2..3]);
    var fourth = try endpoint.reserve(10);
    @memset(fourth.bytes, 44);
    try fourth.publish(10, handles[0..1]);
    endpoint.flush();
    try owner.deliver(std.testing.io);
    try std.testing.expectEqual(@as(usize, 3), endpoint.preparing.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1000), owner.engine.connections[0].lifecycle.?);
    try std.testing.expectEqual(@as(usize, 0), owner.engine.connections[1].lifecycle.?);
    try std.testing.expectEqual(@as(usize, 10), owner.engine.connections[2].lifecycle.?);
    for (0..2) |_| {
        try owner.deliver(std.testing.io);
        try std.testing.expect(owner.queues[0].head.?.frame == null);
        try std.testing.expectEqual(@as(usize, 1010), owner.engine.connections[0].lifecycle.?);
        try std.testing.expectEqual(@as(usize, 0), owner.engine.connections[1].lifecycle.?);
    }
    owner.engine.releaseBuffers(0);
    owner.engine.connections[0].output_read = 0;
    owner.engine.connections[0].output_write = 0;
    for (0..4) |_| try owner.deliver(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), endpoint.preparing.load(.acquire));
    const queued = owner.engine.connections[1].output_burst.?.bytes;
    for (queued[0..1000]) |byte| try std.testing.expectEqual(@as(u8, 11), byte);
    for (queued[1000..1010]) |byte| try std.testing.expectEqual(@as(u8, 22), byte);
    try std.testing.expectEqual(@as(usize, 1010), owner.engine.connections[1].lifecycle.?);
    for (owner.engine.connections, 0..) |*connection, index| {
        owner.engine.releaseBuffers(index);
        connection.output_read = 0;
        connection.output_write = 0;
        connection.lifecycle = std.math.maxInt(usize);
        endpoint.credit[index].store((@as(u64, 1) << 32) | Service.active | 4096, .release);
    }
    for (0..owner.frames.len - 1) |_| {
        var packet = try endpoint.reserve(10);
        @memset(packet.bytes, 55);
        try packet.publish(10, handles[1..2]);
        endpoint.flush();
        try owner.deliver(std.testing.io);
    }
    try std.testing.expectEqual(owner.frames.len - 1, owner.engine.connections[1].loan_write);
    for ([_]u8{ 77, 88 }, 0..) |value, index| {
        var packet = try endpoint.reserve(10);
        @memset(packet.bytes, value);
        try packet.publish(10, handles[0..1]);
        endpoint.flush();
        try owner.deliver(std.testing.io);
        try std.testing.expectEqual(@as(usize, 0), owner.engine.connections[0].loan_write - owner.engine.connections[0].loan_read);
        try std.testing.expectEqual((index + 1) * 10, owner.engine.connections[0].output_write);
        try std.testing.expect(std.mem.allEqual(u8, owner.engine.output[index * 10 ..][0..10], value));
    }
    owner.engine.releaseBuffers(1);
    try owner.deliver(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), endpoint.preparing.load(.acquire));
    for (owner.engine.connections, 0..) |*connection, index| {
        owner.engine.releaseBuffers(index);
        connection.output_read = 0;
        connection.output_write = 0;
        endpoint.credit[index].store((@as(u64, 1) << 32) | Service.active | 4096, .release);
    }
    owner.engine.connections[1].protocol = &protocols.values[1];
    owner.engine.connections[1].lifecycle = 0;
    owner.engine.connections[1].output_write = 500;
    var broadcast = try endpoint.reserve(1000);
    @memset(broadcast.bytes, 66);
    try broadcast.publish(1000, handles[0..2]);
    var independent = try endpoint.reserve(20);
    @memset(independent.bytes, 99);
    try independent.publish(20, handles[0..1]);
    endpoint.flush();
    try owner.deliver(std.testing.io);
    owner.engine.releaseBuffers(0);
    owner.engine.connections[0].output_read = 0;
    owner.engine.connections[0].output_write = 0;
    for (0..3) |_| try owner.deliver(std.testing.io);
    try std.testing.expectEqual(@as(usize, 500), owner.engine.connections[1].output_write);
    try std.testing.expectEqual(@as(usize, 20), owner.engine.connections[0].output_write);
    const fast = owner.engine.connections[0].output_loans[owner.engine.connections[0].loan_read % network.send_vectors_max];
    try std.testing.expect(std.mem.allEqual(u8, fast.bytes, 99));
    owner.engine.releaseBuffers(0);
    owner.engine.connections[1].output_read = 0;
    owner.engine.connections[1].output_write = 0;
    for (0..3) |_| try owner.deliver(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), endpoint.preparing.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), owner.socket_budget.used);
    for (owner.engine.connections, 0..) |*connection, index| {
        owner.engine.releaseBuffers(index);
        connection.output_read = 0;
        connection.output_write = 0;
        connection.lifecycle = std.math.maxInt(usize);
        endpoint.credit[index].store((@as(u64, 1) << 32) | Service.active | 4096, .release);
    }
    owner.engine.workspaces.headers = true;
    var mixed = try endpoint.reserve(10);
    @memset(mixed.bytes, 42);
    const payload = mixed.bytes.ptr;
    try mixed.publish(10, handles[0..2]);
    endpoint.flush();
    try owner.deliver(std.testing.io);
    const slow = owner.engine.connections[0].output_loans[owner.engine.connections[0].loan_read % network.send_vectors_max];
    try std.testing.expect(slow.bytes.ptr == payload);
    try std.testing.expectEqualSlices(u8, &.{ 1, 10 }, slow.prefix);
    for (0..3) |_| try owner.deliver(std.testing.io);
    try std.testing.expectEqual(@as(usize, 12), owner.engine.connections[1].output_write);
    const fast_bytes = owner.engine.output[owner.config.connection_bytes..][0..12];
    try std.testing.expectEqualSlices(u8, &.{ 2, 10 }, fast_bytes[0..2]);
    try std.testing.expect(std.mem.allEqual(u8, fast_bytes[2..], 42));
    try std.testing.expectEqualSlices(u8, &.{ 1, 10 }, slow.prefix);
    try std.testing.expect(std.mem.allEqual(u8, slow.bytes, 42));
    owner.engine.releaseBuffers(0);
    owner.engine.releaseBuffers(1);
    try owner.deliver(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), endpoint.preparing.load(.acquire));
    try std.testing.expectEqual(assigned, fixed.end_index);
    owner.engine.workspaces.headers = false;
    for (owner.engine.connections, 0..) |*connection, index| {
        owner.engine.releaseBuffers(index);
        connection.output_read = 0;
        connection.output_write = 0;
        connection.protocol = &protocols.values[0];
        connection.lifecycle = std.math.maxInt(usize);
        endpoint.credit[index].store((@as(u64, 1) << 32) | Service.active | 4096, .release);
    }
    const Version = struct {
        pub const protocol_number: i32 = 1;
    };
    const GroupEncoder = struct {
        pub fn writeGroup(comptime _: type, buffers: []const []u8, lengths: []usize, _: void) !void {
            for (buffers, lengths, 0..) |buffer, *length, index| {
                @memset(buffer, @intCast(index + 1));
                length.* = 1000;
            }
        }
    };
    var delivered: [1]Service.Delivery = undefined;
    try endpoint.fanout(.{Version}, GroupEncoder, &.{.{ .handle = handles[0], .protocol = 1 }}, {}, &.{ 1000, 1000 }, &delivered);
    try std.testing.expectEqual(Service.Delivery.queued, delivered[0]);
    var outside = try endpoint.reserve(20);
    @memset(outside.bytes, 99);
    try outside.publish(20, handles[0..2]);
    endpoint.flush();
    try owner.deliver(std.testing.io);
    try std.testing.expect(owner.engine.connections[0].group != null);
    try std.testing.expectEqual(@as(u8, 1), owner.engine.connections[0].group.?.next);
    try std.testing.expectEqual(@as(usize, 20), owner.engine.connections[1].output_write);
    try std.testing.expect(std.mem.allEqual(u8, owner.engine.output[owner.config.connection_bytes..][0..20], 99));
    const Drain = struct {
        fn run(worker: *Owner) void {
            const connection = &worker.engine.connections[0];
            while (connection.loan_read != connection.loan_write) {
                connection.output_loans[connection.loan_read % network.send_vectors_max].owner.releaseSocket();
                connection.loan_read +%= 1;
            }
            connection.output_read = connection.output_write;
        }
    };
    Drain.run(owner);
    try owner.deliver(std.testing.io);
    try std.testing.expect(owner.engine.connections[0].group == null);
    const tail = owner.engine.connections[0].output_loans[owner.engine.connections[0].loan_read % network.send_vectors_max];
    try std.testing.expect(std.mem.allEqual(u8, tail.bytes, 2));
    Drain.run(owner);
    try owner.deliver(std.testing.io);
    const outside_loan = owner.engine.connections[0].output_loans[owner.engine.connections[0].loan_read % network.send_vectors_max];
    try std.testing.expect(std.mem.allEqual(u8, outside_loan.bytes, 99));
    Drain.run(owner);
    try owner.deliver(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), endpoint.preparing.load(.acquire));
    try std.testing.expectEqual(assigned, fixed.end_index);
    var abandoned = try endpoint.reserve(10);
    @memset(abandoned.bytes, 42);
    try abandoned.publish(10, handles[0..1]);
    endpoint.flush();
    try owner.deliver(std.testing.io);
    var queued_packet = try endpoint.reserve(10);
    @memset(queued_packet.bytes, 43);
    try queued_packet.publish(10, handles[0..1]);
    endpoint.flush();
    owner.abort(std.testing.io);
    try owner.initCodec(std.testing.io, null);
    const codec = owner.engine.codec.?;
    defer {
        codec.read.store(codec.write.load(.acquire), .release);
        for (owner.frames) |*frame| if (frame.task.state.load(.acquire) == .queued) {
            frame.task.result = error.TestStopped;
            frame.task.state.store(.complete, .release);
        };
        for (owner.engine.connections) |*connection| if (connection.codec.state.load(.acquire) == .queued) {
            connection.codec.complete(error.TestStopped);
        };
    }
    for (handles[0..2]) |handle| {
        const connection = &owner.engine.connections[handle.index];
        owner.engine.setHandle(handle.index, handle);
        connection.protocol = &protocols.values[0];
        connection.lifecycle = 0;
        connection.state.phase = .play;
        connection.output_read = 0;
        connection.output_write = 0;
        endpoint.routes[handle.index] = handle;
        endpoint.credit[handle.index].store((@as(u64, 1) << 32) | Service.active | 4096, .release);
    }
    for (0..4) |index| {
        var packet = try endpoint.reserve(10);
        @memset(packet.bytes, @intCast(index + 1));
        try packet.publish(10, handles[index % 2 ..][0..1]);
    }
    endpoint.flush();
    try owner.deliver(std.testing.io);
    try std.testing.expectEqual(@as(u64, 1), codec.write.load(.acquire) - codec.read.load(.acquire));
    const sequence = owner.queues[0].head.?;
    try std.testing.expectEqual(@as(usize, 2), sequence.frame.?.sequence_count);
    try std.testing.expectEqual(@as(u8, 1), sequence.packet.group.count);
    try std.testing.expectEqual(@as(u8, 1), sequence.next.?.packet.group.count);
    try std.testing.expectEqual(sequence.next.?, sequence.frame.?.sequence_next.?.packet.?);
    const member = sequence.frame.?.sequence_next.?;
    member.task.result = .{ .bytes = "framed" };
    member.task.state.store(.complete, .release);
    try owner.deliver(std.testing.io);
    try std.testing.expectEqual(@as(@TypeOf(member.completion_owner), .sequence), member.completion_owner);
    try std.testing.expect(member.packet != null and sequence.frame.?.task.state.load(.acquire) == .queued);
}

test "pending retries visit only unfinished recipients across bitmap words" {
    const Hooks = TestHooks;
    const Router = SingleSimulation;
    const Owner = Worker(TestEndpoint, Hooks, Router);
    for ([_]usize{ 8, 64, 256 }) |audience_size| for ([_]usize{ 32, 256 }) |packet_count| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var hooks: Hooks = .{};
        var router: Router = .{};
        var protocols: TestEndpoint.Protocols = .{};
        const transport: network.Transport = .{ .context = &hooks, .vtable = network.Transport.adapter(Hooks) };
        const endpoint = try Service.init(allocator, std.testing.io, transport, .{ .connections = audience_size, .buffer_bytes = 128 * 1024, .pages = packet_count, .page_bytes = 1500, .protocols = &protocols.values });
        defer endpoint.deinit();
        const owner = try Owner.init(allocator, transport, .{ .connections = audience_size, .max_players = audience_size, .buffer_bytes = 128 * 1024, .connection_bytes = 512, .framing_slots = 2, .max_pending_wire_bytes = 256 * 1024, .compression_threshold = null, .protocols = &protocols, .hooks = &hooks, .router = &router, .destinations = &.{0} }, &.{endpoint});
        defer {
            owner.abort(std.testing.io);
            owner.deinit();
        }
        const handles = try allocator.alloc(network.Handle, audience_size);
        for (handles, endpoint.credit, 0..) |*handle, *credit, index| {
            handle.* = .{ .index = @intCast(index), .generation = 1 };
            credit.store(@as(u64, 1) << 32 | Service.active | endpoint.config.buffer_bytes, .release);
        }
        const raw = try allocator.alloc(shared.RawPacket, packet_count);
        const retired = try allocator.dupe(network.Handle, handles);
        // Completed recipients are poisoned to catch retries that revisit them.
        for (retired[1..]) |*handle| handle.index = std.math.maxInt(@TypeOf(handle.index));

        endpoint.routes[0] = handles[0];
        owner.engine.setHandle(0, handles[0]);
        owner.engine.connections[0].protocol = &protocols.values[0];
        owner.engine.connections[0].lifecycle = 0;
        owner.engine.connections[0].state.phase = .play;
        for (raw, 0..) |*saved, index| {
            var packet = try endpoint.reserve(1);
            packet.bytes[0] = 1;
            try packet.publish(1, handles);
            endpoint.flush();
            saved.* = endpoint.output.takeReady().?;
            const pending = &owner.pending[saved.page];
            pending.source = endpoint;
            pending.order = index + 1;
            pending.packet = saved.*;
            pending.packet.recipients = shared.Recipients.all(retired);
            pending.next = null;
            pending.frame = null;
            pending.loans = 0;
            pending.remaining.unsetAll();
            pending.remaining.set(0);
            pending.remaining_count = 1;
            @memset(pending.sizes, 0);
            if (index > 0) owner.pending[raw[index - 1].page].next = pending;
            for (handles[1..]) |handle| endpoint.refund(handle, endpoint.framedBound(1));
        }
        owner.queues[0].head = &owner.pending[raw[0].page];
        owner.queues[0].tail = &owner.pending[raw[packet_count - 1].page];
        owner.activate(0);
        for (owner.frames) |*frame| {
            frame.packet = &owner.pending[raw[0].page];
            frame.loan.references = 1;
        }
        owner.pending[raw[0].page].frame = &owner.frames[0];
        owner.pending[raw[0].page].loans = owner.frames.len;
        const waiting = try allocator.dupe(network.Handle, retired);
        waiting[0].index = std.math.maxInt(@TypeOf(waiting[0].index));
        for (raw[1..]) |packet| owner.pending[packet.page].packet.recipients = shared.Recipients.all(waiting);
        for (0..64) |_| try owner.deliverFrames(std.testing.io);
        for (raw) |packet| {
            const pending = &owner.pending[packet.page];
            try std.testing.expectEqual(@as(usize, 1), pending.remaining_count);
            var remaining = pending.remaining.iterator(.{});
            try std.testing.expectEqual(@as(?usize, 0), remaining.next());
            try std.testing.expectEqual(null, remaining.next());
        }
        for (owner.frames) |*frame| {
            frame.packet = null;
            frame.loan.references = 0;
        }
        for (raw) |packet| {
            const pending = &owner.pending[packet.page];
            pending.source = null;
            pending.frame = null;
            pending.loans = 0;
        }
        owner.queues[0].head = null;
        owner.queues[0].tail = null;
        owner.active_head = null;
        owner.active_tail = null;
        endpoint.recycle(std.testing.io, raw);
        endpoint.routes[0] = null;
        owner.engine.setHandle(0, null);
    };
}

test "background publication retry covers both sides of the tick boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var hooks: TestHooks = .{};
    var protocols: TestEndpoint.Protocols = .{};
    const service = try Service.init(arena.allocator(), std.testing.io, .{ .context = &hooks, .vtable = network.Transport.adapter(TestHooks) }, .{ .connections = 1, .pages = 2, .page_bytes = 1500, .buffer_bytes = 4096, .protocols = &protocols.values });
    defer service.deinit();
    var changed: std.Io.Event = .unset;
    try service.subscribeOutput(&changed);
    defer service.unsubscribeOutput(&changed);
    const before = service.backgroundEpoch();
    service.retryBackground(before);
    try std.testing.expect(!changed.isSet());
    service.beginTick();
    service.retryBackground(before);
    try std.testing.expect(!changed.isSet());
    service.endTick(true);
    try std.testing.expect(changed.isSet());
    changed.reset();
    service.beginTick();
    service.endTick(true);
    try std.testing.expect(!changed.isSet());
    service.retryBackground(before);
    try std.testing.expect(changed.isSet());
    changed.reset();
    service.retryBackground(service.backgroundEpoch());
    try std.testing.expect(!changed.isSet());
}

test "queued codec work does not revisit borrowed recipient tables" {
    const Owner = Worker(TestEndpoint, TestHooks, SingleSimulation);
    const audience = 32;
    const packet_count = 32;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var hooks: TestHooks = .{};
    var router: SingleSimulation = .{};
    var protocols: TestEndpoint.Protocols = .{};
    const transport: network.Transport = .{ .context = &hooks, .vtable = network.Transport.adapter(TestHooks) };
    const endpoint = try Service.init(allocator, std.testing.io, transport, .{ .connections = audience, .buffer_bytes = 512 * 1024, .pages = packet_count, .page_bytes = 1500, .protocols = &protocols.values });
    defer endpoint.deinit();
    const owner = try Owner.init(allocator, transport, .{ .connections = audience, .max_players = audience, .buffer_bytes = 512 * 1024, .connection_bytes = 8192, .framing_slots = 8, .max_pending_wire_bytes = 1024 * 1024, .compression_threshold = null, .protocols = &protocols, .hooks = &hooks, .router = &router, .destinations = &.{0} }, &.{endpoint});
    defer {
        owner.abort(std.testing.io);
        owner.deinit();
    }
    try owner.initCodec(std.testing.io, null);
    const codec = owner.engine.codec.?;
    defer {
        codec.read.store(codec.write.load(.acquire), .release);
        for (owner.frames) |*frame| if (frame.task.state.load(.acquire) == .queued) {
            frame.task.result = error.TestStopped;
            frame.task.state.store(.complete, .release);
        };
        for (owner.engine.connections) |*connection| if (connection.codec.state.load(.acquire) == .queued) connection.codec.complete(error.TestStopped);
    }
    const handles = try allocator.alloc(network.Handle, audience);
    for (handles, 0..) |*handle, i| {
        handle.* = .{ .index = @intCast(i), .generation = 1 };
        endpoint.routes[i] = handle.*;
        endpoint.credit[i].store((@as(u64, 1) << 32) | Service.active | endpoint.config.buffer_bytes, .release);
        owner.engine.setHandle(i, handle.*);
        const connection = &owner.engine.connections[i];
        connection.protocol = &protocols.values[0];
        connection.lifecycle = 0;
        connection.state.phase = .play;
    }
    for (0..packet_count) |_| {
        var packet = try endpoint.reserve(10);
        @memset(packet.bytes, 1);
        try packet.publish(10, handles);
    }
    endpoint.flush();
    try owner.deliver(std.testing.io);
    const queued = codec.write.load(.acquire) - codec.read.load(.acquire);
    try std.testing.expect(queued > 0);

    for (owner.frames) |*frame| try std.testing.expect(frame.packet != null and frame.task.state.load(.acquire) == .queued);
    const invalid = [_]network.Handle{.{ .index = std.math.maxInt(u16), .generation = 1 }};
    for (owner.pending) |*pending| if (pending.source != null) {
        pending.packet.recipients = shared.Recipients.all(&invalid);
    };
    defer for (owner.pending) |*pending| if (pending.source != null) {
        pending.packet.recipients = shared.Recipients.all(handles);
    };
    for (0..64) |_| try owner.deliverFrames(std.testing.io);
    try std.testing.expectEqual(queued, codec.write.load(.acquire) - codec.read.load(.acquire));
    for (owner.engine.connections) |connection| try std.testing.expectEqual(@as(usize, 0), connection.output_write);
}

test "capacity released by a later endpoint wakes an earlier waiting endpoint" {
    const Owner = Worker(TestEndpoint, TestHooks, SingleSimulation);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var hooks: TestHooks = .{};
    var router: SingleSimulation = .{};
    var protocols: TestEndpoint.Protocols = .{};
    const transport: network.Transport = .{ .context = &hooks, .vtable = network.Transport.adapter(TestHooks) };
    var endpoints: [2]*Service = undefined;
    for (&endpoints) |*endpoint| endpoint.* = try Service.init(allocator, std.testing.io, transport, .{ .connections = 1, .buffer_bytes = 4096, .pages = 2, .page_bytes = 1500, .protocols = &protocols.values });
    defer for (endpoints) |endpoint| endpoint.deinit();
    const owner = try Owner.init(allocator, transport, .{ .connections = 2, .max_players = 2, .buffer_bytes = 4096, .connection_bytes = 512, .framing_slots = 2, .max_pending_wire_bytes = 8192, .compression_threshold = null, .protocols = &protocols, .hooks = &hooks, .router = &router, .destinations = &.{ 0, 1 } }, &endpoints);
    defer {
        owner.abort(std.testing.io);
        owner.deinit();
    }
    const local: network.Handle = .{ .index = 0, .generation = 1 };
    for (endpoints, 0..) |endpoint, index| {
        const native: network.Handle = .{ .index = @intCast(index), .generation = 1 };
        endpoint.routes[0] = native;
        endpoint.credit[0].store((@as(u64, 1) << 32) | Service.active | endpoint.config.buffer_bytes, .release);
        owner.engine.setHandle(index, native);
        owner.engine.connections[index].protocol = &protocols.values[0];
        owner.engine.connections[index].lifecycle = 0;
        owner.engine.connections[index].state.phase = .play;
        for (0..index + 1) |number| {
            var packet = try endpoint.reserve(1);
            packet.bytes[0] = 1;
            try packet.publish(1, &.{local});
            endpoint.flush();
            const raw = endpoint.output.takeReady().?;
            const pending = &owner.pending[owner.queues[index].pending_base + raw.page];
            pending.source = endpoint;
            pending.order = number + 1;
            pending.packet = raw;
            pending.remaining.unsetAll();
            pending.remaining.set(0);
            pending.remaining_count = 1;
            @memset(pending.sizes, 0);
            if (owner.queues[index].tail) |tail| tail.next = pending else owner.queues[index].head = pending;
            owner.queues[index].tail = pending;
            if (index == 1) {
                const frame = &owner.frames[number];
                pending.frame = frame;
                pending.loans = 1;
                frame.packet = pending;
                frame.loan = Owner.Engine.Loan.framed(raw.bytes, raw.bytes);
                frame.protocol = 1;
                frame.ready = true;
            }
        }
        owner.activate(index);
    }
    hooks.notifications = 0;
    try owner.deliverFrames(std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), hooks.notifications);
    try std.testing.expect(owner.queues[0].head != null and owner.queues[1].head == null);
    try owner.deliverFrames(std.testing.io);
    try std.testing.expect(owner.queues[0].head == null);
    try std.testing.expectEqual(@as(usize, 1), owner.engine.connections[0].output_write);
    try std.testing.expectEqual(@as(usize, 2), owner.engine.connections[1].output_write);
}

test "encrypted sequences batch rotating exclusions without extra handoffs" {
    for ([_]bool{ false, true }) |compact| {
        for ([_]bool{ false, true }) |exclude_self| {
            const Owner = Worker(TestEndpoint, TestHooks, SingleSimulation);
            const audience = 32;
            const packet_count = 8;
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            var hooks: TestHooks = .{};
            var router: SingleSimulation = .{};
            var protocols: TestEndpoint.Protocols = .{};
            const transport: network.Transport = .{ .context = &hooks, .vtable = network.Transport.adapter(TestHooks) };
            const endpoint = try Service.init(allocator, std.testing.io, transport, .{ .connections = audience, .buffer_bytes = 512 * 1024, .pages = packet_count, .page_bytes = 1500, .protocols = &protocols.values });
            defer endpoint.deinit();
            const owner = try Owner.init(allocator, transport, .{ .connections = audience, .max_players = audience, .buffer_bytes = 512 * 1024, .connection_bytes = 8192, .framing_slots = 8, .max_pending_wire_bytes = 1024 * 1024, .compression_threshold = null, .protocols = &protocols, .hooks = &hooks, .router = &router, .destinations = &.{0} }, &.{endpoint});
            defer {
                owner.abort(std.testing.io);
                owner.deinit();
            }
            try owner.initCodec(std.testing.io, null);
            const codec = owner.engine.codec.?;
            defer {
                codec.read.store(codec.write.load(.acquire), .release);
                for (owner.frames) |*frame| if (frame.task.state.load(.acquire) == .queued) {
                    frame.task.result = error.TestStopped;
                    frame.task.state.store(.complete, .release);
                };
                for (owner.engine.connections) |*connection| if (connection.codec.state.load(.acquire) == .queued) connection.codec.complete(error.TestStopped);
            }
            const handles = try allocator.alloc(network.Handle, audience);
            for (handles, 0..) |*handle, i| {
                handle.* = .{ .index = @intCast(i), .generation = 1 };
                endpoint.routes[i] = handle.*;
                endpoint.credit[i].store((@as(u64, 1) << 32) | Service.active | endpoint.config.buffer_bytes, .release);
                owner.engine.setHandle(i, handle.*);
                const connection = &owner.engine.connections[i];
                connection.protocol = &protocols.values[0];
                connection.lifecycle = 0;
                connection.state.phase = .play;
            }
            const Version = struct {
                pub const protocol_number = 1;
            };
            const Encoder = struct {
                pub fn writeGroup(comptime _: type, buffers: []const []u8, lengths: []usize, value: u8) !void {
                    for (buffers, lengths) |buffer, *length| {
                        @memset(buffer[0..10], value);
                        length.* = 10;
                    }
                }
            };
            var broadcast = try Service.Broadcast.init(allocator, endpoint, packet_count);
            defer broadcast.deinit();
            const targets = try allocator.alloc(Service.Target, audience);
            for (handles, targets) |handle, *target| target.* = .{ .handle = handle, .protocol = 1 };
            if (compact) {
                var delivered: [audience]Service.Delivery = undefined;
                for (0..packet_count) |packet_index| {
                    var selected: usize = 0;
                    for (0..audience) |offset| {
                        const index = (offset + packet_index) % audience;
                        if (exclude_self and index == packet_index) continue;
                        targets[selected] = .{ .handle = handles[index], .protocol = 1 };
                        selected += 1;
                    }
                    try endpoint.fanout(.{Version}, Encoder, targets[0..selected], @as(u8, @intCast(packet_index)), &.{10}, delivered[0..selected]);
                    for (delivered[0..selected]) |delivery| try std.testing.expectEqual(Service.Delivery.queued, delivery);
                }
            } else {
                try broadcast.begin(targets);
                for (0..packet_count) |packet_index| {
                    _ = try broadcast.write(.{Version}, Encoder, if (exclude_self) handles[packet_index % audience] else null, null, @as(u8, @intCast(packet_index)), 10);
                }
                broadcast.finish();
            }
            endpoint.flush();
            try owner.deliver(std.testing.io);
            const queued = codec.write.load(.acquire) - codec.read.load(.acquire);

            var framed: usize = 0;
            for (owner.frames) |frame| framed += @intFromBool(frame.packet != null);
            try std.testing.expectEqual(@as(u64, 1), queued);
            try std.testing.expectEqual(owner.frames.len, framed);
            const first = owner.queues[0].head.?.frame.?;
            try std.testing.expectEqual(owner.frames.len, first.sequence_count);
            var target = first.targets;
            while (target) |destination| : (target = destination.next) {
                const count = @popCount(destination.packets);
                try std.testing.expectEqual(owner.frames.len - @intFromBool(exclude_self and destination.recipient < owner.frames.len), count);
            }
            try codec.start();
            codec.stop();
            for (owner.engine.connections, 0..) |*connection, recipient| {
                const result = try (Owner.Codec.take(&connection.codec) orelse return error.MissingSendCompletion);
                var offset: usize = 0;
                const bytes = owner.engine.output[recipient * owner.config.connection_bytes ..][0..owner.config.connection_bytes];
                for (0..packet_count) |packet_index| {
                    if (exclude_self and recipient == packet_index) continue;
                    try std.testing.expect(std.mem.allEqual(u8, bytes[offset..][0..10], @intCast(packet_index)));
                    offset += 10;
                }
                try std.testing.expectEqual(offset, result.consumed);
            }
            try owner.deliver(std.testing.io);
            try owner.deliver(std.testing.io);
            try std.testing.expectEqual(@as(usize, 0), endpoint.preparing.load(.acquire));
            try std.testing.expect(owner.queues[0].head == null);
        }
    }
}

test "worker recipient masks and blocked cleanup follow active spans" {
    const Owner = Worker(TestEndpoint, TestHooks, SingleSimulation);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var hooks: TestHooks = .{};
    var router: SingleSimulation = .{};
    var protocols: TestEndpoint.Protocols = .{};
    const transport: network.Transport = .{ .context = &hooks, .vtable = network.Transport.adapter(TestHooks) };
    const endpoint = try Service.init(allocator, std.testing.io, transport, .{ .connections = 129, .buffer_bytes = 512, .pages = 2, .page_bytes = 64, .protocols = &protocols.values });
    defer endpoint.deinit();
    const owner = try Owner.init(allocator, transport, .{
        .connections = 2,
        .max_players = 2,
        .buffer_bytes = 512,
        .connection_bytes = 512,
        .framing_slots = 2,
        .max_pending_wire_bytes = 1024,
        .compression_threshold = null,
        .protocols = &protocols,
        .hooks = &hooks,
        .router = &router,
        .destinations = &.{0},
    }, &.{endpoint});
    defer {
        owner.abort(std.testing.io);
        owner.deinit();
    }
    owner.block(0);
    owner.block(1);
    try std.testing.expectEqual(@as(usize, 1), owner.blocked_words.count);
    try owner.deliver(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), owner.blocked_words.count);
    try std.testing.expectEqual(@as(usize, 0), owner.blocked.count());
    const handles = [_]network.Handle{ .{ .index = 128, .generation = 1 }, .{ .index = 3, .generation = 1 } };
    for (handles, 0..) |handle, index| {
        const native: network.Handle = .{ .index = index, .generation = 1 };
        owner.engine.setHandle(index, native);
        owner.engine.connections[index].protocol = &protocols.values[0];
        owner.engine.connections[index].lifecycle = 0;
        owner.engine.connections[index].state.phase = .play;
        endpoint.routes[handle.index] = native;
        endpoint.credit[handle.index].store((@as(u64, 1) << 32) | Service.active | 512, .release);
    }
    @memset(owner.recipient_masks, 42);
    var packet = try endpoint.reserve(2);
    const page = packet.reservation.?.page;
    packet.bytes[0..2].* = .{ 11, 22 };
    try packet.publish(2, &handles);
    endpoint.flush();
    try owner.deliver(std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), owner.pending[page].remaining.bit_length);
    var written: usize = 0;
    for (owner.recipient_masks) |word| written += @intFromBool(word != 42);
    try std.testing.expectEqual(@as(usize, 1), written);
    try std.testing.expectEqual(@as(usize, 0), endpoint.preparing.load(.acquire));
    for (owner.engine.connections, 0..) |connection, index| {
        try std.testing.expectEqual(@as(usize, 2), connection.lifecycle.?);
        try std.testing.expectEqualSlices(u8, &.{ 11, 22 }, owner.engine.output[index * owner.config.connection_bytes ..][0..2]);
    }
}

test "blocked delivery sleeps until capacity changes and preserves new output ordering" {
    const Owner = Worker(TestEndpoint, TestHooks, SingleSimulation);
    for ([_]usize{ 2, 64 }) |clients| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var hooks: TestHooks = .{};
        var router: SingleSimulation = .{};
        var protocols: TestEndpoint.Protocols = .{};
        const transport: network.Transport = .{ .context = &hooks, .vtable = network.Transport.adapter(TestHooks) };
        const endpoint = try Service.init(allocator, std.testing.io, transport, .{
            .connections = clients,
            .buffer_bytes = 128 * 1024,
            .pages = 33,
            .page_bytes = 1500,
            .protocols = &protocols.values,
        });
        defer endpoint.deinit();
        const owner = try Owner.init(allocator, transport, .{
            .connections = clients,
            .max_players = clients,
            .buffer_bytes = 128 * 1024,
            .connection_bytes = 512,
            .output_burst_slots = 1,
            .framing_slots = 2,
            .max_pending_wire_bytes = 256 * 1024,
            .compression_threshold = null,
            .protocols = &protocols,
            .hooks = &hooks,
            .router = &router,
            .destinations = &.{0},
        }, &.{endpoint});
        defer {
            owner.abort(std.testing.io);
            owner.deinit();
        }
        const held_burst = owner.engine.output_bursts.acquire().?;
        defer held_burst.release();
        const handles = try allocator.alloc(network.Handle, clients);
        for (handles, 0..) |*handle, index| {
            handle.* = .{ .index = index, .generation = 1 };
            owner.engine.setHandle(index, handle.*);
            const connection = &owner.engine.connections[index];
            connection.protocol = &protocols.values[0];
            connection.lifecycle = 0;
            connection.state.phase = .play;
            connection.output_write = 512;
            endpoint.routes[index] = handle.*;
            endpoint.occupied[index].store(true, .release);
            endpoint.credit[index].store((@as(u64, 1) << 32) | Service.active | (endpoint.config.buffer_bytes - 512), .release);
            owner.bindings[index] = .{ .native = handle.*, .endpoint = endpoint, .handle = handle.* };
        }
        for (0..32) |_| {
            var packet = try endpoint.reserve(10);
            @memset(packet.bytes, 17);
            try packet.publish(10, handles);
        }
        endpoint.flush();
        try owner.deliver(std.testing.io);
        const notifications = hooks.notifications;
        for (0..64) |_| {
            try owner.deliver(std.testing.io);
            try std.testing.expect(!owner.delivery_ready and !owner.engine.delivery_ready);
        }
        try std.testing.expectEqual(notifications, hooks.notifications);
        for (owner.pending) |pending| if (pending.source != null) {
            try std.testing.expectEqual(clients, pending.remaining_count);
        };

        const healthy = clients - 1;
        owner.engine.connections[healthy].sending = true;
        owner.engine.connections[healthy].sending_bytes = 512;
        hooks.events = &.{.{ .sent = .{ .handle = handles[healthy], .result = .{ .bytes = 512 } } }};
        try owner.engine.receive(std.testing.io);
        try std.testing.expect(owner.engine.delivery_ready);
        var new = try endpoint.reserve(10);
        @memset(new.bytes, 99);
        try new.publish(10, handles[healthy..]);
        endpoint.flush();
        try owner.deliver(std.testing.io);
        try owner.deliver(std.testing.io);
        try owner.deliver(std.testing.io);
        try std.testing.expect(!owner.delivery_ready and !owner.engine.delivery_ready);
        const connection = &owner.engine.connections[healthy];
        try std.testing.expectEqual(@as(usize, 330), connection.lifecycle.?);
        const output = owner.engine.output[healthy * 512 ..][0..330];
        try std.testing.expect(std.mem.allEqual(u8, output[0..320], 17));
        try std.testing.expect(std.mem.allEqual(u8, output[320..], 99));
        for (owner.pending) |pending| if (pending.source != null) {
            try std.testing.expectEqual(clients - 1, pending.remaining_count);
        };
    }
}
