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
const Profiles = @import("profiles.zig").Profiles;
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
            input_burst_slots: usize = 2,
            /// Each connection's ring of Play output, see `Engine.Configuration.output_bytes`.
            output_bytes: usize = 64 * 1024,
            configuration_slots: usize = 8,
            decode_slots: usize = 2,
            max_pending_wire_bytes: usize = 4 * 1024 * 1024,
            protocols: *const Endpoint.Protocols,
            compression_threshold: ?usize = 256,
            /// Profiles the session plugins fill in, handed to the endpoint a player joins.
            profiles: ?*Profiles = null,
            metrics: ?*metrics.Registry = null,
            hooks: *Hooks,
            router: *Router,
            destinations: []const Router.Destination,
        };

        const Engine = engine.Engine(Endpoint, Self);

        /// A packet a source published, from when this takes it until every recipient's ring
        /// holds its bytes. Most go out in the pass that takes them. A recipient whose ring cannot
        /// take one yet has it in its backlog, which the packet waits on.
        const Packet = struct {
            raw: shared.RawPacket = undefined,
            source: ?usize = null,
            /// The packet as it goes on the wire, framed and compressed in its own storage.
            framed: []const u8 = &.{},
            /// What publishing charged each recipient's credit, refunded but for the bytes sent.
            charge: usize = 0,
            /// Backlogs holding the packet.
            waiting: u32 = 0,
        };
        /// Where a source's packets are among `packets`. Sources sharing a pool share the range.
        const Source = struct { packet_base: usize = 0 };
        /// A connection's packets its ring could not take yet, oldest first, the oldest in part
        /// when `offset` is not zero.
        /// What a connection waits to write: a packet larger than its ring, in pieces, and what
        /// was published behind it. `absorb` is how much more such a packet takes on the wire
        /// than it charged, which its sent bytes pay back before any credit returns.
        const Backlog = struct { head: usize = 0, count: usize = 0, offset: usize = 0, absorb: usize = 0 };
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

        allocator: std.mem.Allocator,
        config: Configuration,
        hooks: *Hooks,
        router: *Router,
        engine: *Engine,
        endpoints: []const *Service,
        owner_token: Service.Owner = .{},
        bindings: []?Binding,
        selected_routes: []?SelectedRoute,
        sources: []Source,
        packets: []Packet,
        backlogs: []Backlog,
        /// Each connection's backlog: `backlog_capacity` packet indices.
        backlog_entries: []u32,
        backlog_capacity: usize,
        /// Connections whose backlog is not empty.
        backlogged: system.IndexSet,
        /// Where packets compress before they go back into their own storage.
        compressed: []u8,
        /// Packets every recipient has, per source, returned to it a batch at a time.
        recycled: [][Service.batch_max]shared.RawPacket,
        recycled_counts: []usize,
        output_ready: []std.atomic.Value(usize),
        transfers_ready: []std.atomic.Value(usize),
        inputs_ready: []std.atomic.Value(usize),
        progress_ready: []usize,
        stopping: std.atomic.Value(bool) = .init(false),
        reload_state: std.atomic.Value(enum(u8) { running, requested, parked }) = .init(.running),
        quiescing: bool = false,
        started: bool = false,
        reload_removed: [Endpoint.versions.len]bool = @splat(false),
        instruments: Instrumentation,

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
                // Credit is no more than the ring's room, so what is published always fits it.
                if (endpoint.config.credit_bytes > config.output_bytes) return error.InvalidConfiguration;

                for (endpoint.config.protocols) |selected| {
                    var found = false;

                    for (config.protocols.values) |protocol| found = found or protocol.number == selected.number;
                    if (!found) return error.InvalidConfiguration;
                }

                for (endpoints[0..i]) |previous| if (previous == endpoint) return error.InvalidConfiguration;
                maximum = @max(maximum, endpoint.framedBound(endpoint.config.page_bytes));
            }

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
            const sources = try allocator.alloc(Source, endpoints.len);
            errdefer allocator.free(sources);
            var packet_capacity: usize = 0;
            for (endpoints, 0..) |endpoint, index| {
                sources[index] = .{ .packet_base = packet_capacity };
                for (endpoints[0..index], 0..) |previous, prior| {
                    if (previous.output.pool == endpoint.output.pool) {
                        sources[index].packet_base = sources[prior].packet_base;
                        break;
                    }
                } else packet_capacity = try std.math.add(usize, packet_capacity, endpoint.output.slots.len);
            }
            if (packet_capacity > std.math.maxInt(u32)) return error.InvalidConfiguration;
            const packets = try allocator.alloc(Packet, packet_capacity);
            errdefer allocator.free(packets);
            @memset(packets, .{});
            // Only a packet larger than its ring and what was published behind it wait, and each
            // charges at least the bound of the smallest frame, so credit bounds how many.
            var smallest: usize = std.math.maxInt(usize);
            for (endpoints) |endpoint| smallest = @min(smallest, endpoint.framedBound(1));
            const backlog_capacity = config.output_bytes / smallest + 1;
            const backlogs = try allocator.alloc(Backlog, config.connections);
            errdefer allocator.free(backlogs);
            @memset(backlogs, .{});
            const backlog_entries = try allocator.alloc(u32, try std.math.mul(usize, config.connections, backlog_capacity));
            errdefer allocator.free(backlog_entries);
            var backlogged = try system.IndexSet.init(allocator, config.connections);
            errdefer backlogged.deinit(allocator);
            const compressed = try allocator.alloc(u8, maximum + shared.headroom);
            errdefer allocator.free(compressed);
            const recycled = try allocator.alloc([Service.batch_max]shared.RawPacket, endpoints.len);
            errdefer allocator.free(recycled);
            const recycled_counts = try allocator.alloc(usize, endpoints.len);
            errdefer allocator.free(recycled_counts);
            @memset(recycled_counts, 0);
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
                .sources = sources,
                .packets = packets,
                .backlogs = backlogs,
                .backlog_entries = backlog_entries,
                .backlog_capacity = backlog_capacity,
                .backlogged = backlogged,
                .compressed = compressed,
                .recycled = recycled,
                .recycled_counts = recycled_counts,
                .output_ready = output_ready,
                .transfers_ready = transfers_ready,
                .inputs_ready = inputs_ready,
                .progress_ready = progress_ready,
                .instruments = instrumentation,
            };
            self.engine = try Engine.init(allocator, transport, .{
                .connections = config.connections,
                .max_players = config.max_players,
                .buffer_bytes = config.buffer_bytes,
                .connection_bytes = config.connection_bytes,
                .input_burst_slots = config.input_burst_slots,
                .output_bytes = config.output_bytes,
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
            for (self.bindings) |binding| assert(binding == null);
            self.engine.deinit();

            for (self.endpoints) |endpoint| {
                endpoint.owner = null;
                endpoint.readiness = null;
            }
            for (self.packets) |packet| assert(packet.source == null);
            assert(self.backlogged.count == 0);
            self.allocator.free(self.packets);
            self.allocator.free(self.backlogs);
            self.allocator.free(self.backlog_entries);
            self.backlogged.deinit(self.allocator);
            self.allocator.free(self.compressed);
            self.allocator.free(self.recycled);
            self.allocator.free(self.recycled_counts);
            self.allocator.free(self.output_ready);
            self.allocator.free(self.inputs_ready);
            self.allocator.free(self.transfers_ready);
            self.allocator.free(self.progress_ready);
            self.allocator.free(self.sources);
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
            for (self.endpoints) |endpoint| assert(!endpoint.tick_active);
            self.discardInputs();
            while (self.backlogged.count != 0) self.dropBacklog(io, self.backlogged.indices[0]);
            for (self.engine.connections, 0..) |*connection, index| {
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
            assert(self.backlogged.count == 0);
            for (self.endpoints, 0..) |endpoint, index| {
                var batch = endpoint.outputBatch();
                while (batch.next()) |packet| {
                    endpoint.output.releaseRecipients(packet);
                    self.recycle(io, index, packet);
                }
                self.flushRecycled(io, index);
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
            @memset(self.bindings, null);
            @memset(self.selected_routes, null);
            assert(self.drained());
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
            for (self.endpoints) |endpoint| endpoint.discardInputs();
        }

        /// Takes what every source published, frames each packet once and writes it into each
        /// recipient's ring, then encrypts every ring's new bytes side by side and sends them.
        /// Credit guarantees the rings room for what was published, but for packets larger than
        /// a ring, which go out in pieces, and what waits behind them in a backlog.
        fn deliver(self: *Self, io: std.Io) !void {
            for (self.output_ready, 0..) |*word, word_index| {
                var ready = word.swap(0, .acq_rel);
                while (ready != 0) {
                    const index = word_index * @bitSizeOf(usize) + @ctz(ready);
                    ready &= ready - 1;
                    assert(index < self.endpoints.len);
                    var batch = self.endpoints[index].outputBatch();
                    while (batch.next()) |packet| self.take(io, index, packet);
                }
            }
            self.drainBacklogs(io);
            for (self.endpoints, 0..) |_, index| self.flushRecycled(io, index);
            self.engine.sealPlay(io);
        }

        fn take(self: *Self, io: std.Io, source: usize, raw: shared.RawPacket) void {
            const endpoint = self.endpoints[source];
            // Nothing reads its recipients once it is taken, so their room is reused.
            defer endpoint.output.releaseRecipients(raw);
            assert(raw.page < endpoint.output.slots.len);
            const packet_index = self.sources[source].packet_base + raw.page;
            const packet = &self.packets[packet_index];
            assert(packet.source == null and packet.waiting == 0);
            packet.* = .{ .raw = raw, .source = source, .charge = endpoint.creditCharge(endpoint.chargedLength(raw.bytes.len, raw.decoded_length)) };
            packet.framed = self.frame(endpoint, raw) catch |err| {
                std.log.warn("event=session_packet_unframed bytes={d} reason={s}", .{ raw.bytes.len, @errorName(err) });
                var recipients = raw.recipients.iterator();
                while (recipients.next()) |handle| endpoint.refund(handle, packet.charge);
                self.recycle(io, source, raw);
                packet.* = .{};
                return;
            };
            self.instruments.encoded_packets.add(1);
            self.instruments.encoded_bytes.add(raw.bytes.len);
            self.instruments.framed_bytes.add(packet.framed.len);
            const fanout = self.instruments.fanout.start();
            defer fanout.end();
            var recipients = raw.recipients.iterator();
            while (recipients.next()) |handle| {
                // A recipient gone since took its credit with it.
                const credit = endpoint.credit[handle.index].load(.acquire);
                if (credit >> 32 != handle.generation or credit & Service.active == 0) continue;
                const native = endpoint.routes[handle.index] orelse continue;
                const room = self.engine.playRoom(native) orelse {
                    endpoint.refund(handle, packet.charge);
                    continue;
                };
                const backlog = &self.backlogs[native.index];
                if (backlog.count == 0 and room >= packet.framed.len) {
                    self.engine.writePlay(io, native, packet.framed);
                    endpoint.refund(handle, packet.charge - packet.framed.len);
                    self.instruments.fanout_bytes.add(packet.framed.len);
                    continue;
                }
                assert(backlog.count < self.backlog_capacity);
                // A packet larger than its charge is paid back from its own sent bytes.
                backlog.absorb += packet.framed.len -| packet.charge;
                self.backlog_entries[native.index * self.backlog_capacity + (backlog.head + backlog.count) % self.backlog_capacity] = @intCast(packet_index);
                backlog.count += 1;
                packet.waiting += 1;
                self.backlogged.insert(native.index);
            }
            if (packet.waiting == 0) {
                self.recycle(io, source, raw);
                packet.* = .{};
            }
        }

        /// The packet as it goes on the wire: its frame length, and with compression on, its
        /// decoded length, in the headroom before it, compressing it first when it reaches the
        /// threshold. Compressed bytes go back into the packet's own storage, which publishing
        /// reserved room for, as they wait there for every recipient.
        fn frame(self: *Self, endpoint: *Service, raw: shared.RawPacket) ![]const u8 {
            const storage = endpoint.output.packetStorage(raw);
            const number = raw.group.protocol orelse endpoint.config.protocols[0].number;
            const threshold = self.config.compression_threshold;
            const compressing = self.instruments.compression.start();
            defer compressing.end();
            const framed = if (raw.decoded_length != 0)
                try Endpoint.preparedFrame(number, &self.engine.workspaces, storage, raw.bytes.len, raw.decoded_length, threshold, self.compressed)
            else
                try Endpoint.sharedFrame(number, &self.engine.workspaces, storage, raw.bytes.len, threshold, self.compressed);
            const start = @intFromPtr(storage.ptr);
            if (@intFromPtr(framed.ptr) >= start and @intFromPtr(framed.ptr) < start + storage.len) return framed;
            if (framed.len > storage.len) return error.FrameTooLarge;
            @memcpy(storage[0..framed.len], framed);
            return storage[0..framed.len];
        }

        fn drainBacklogs(self: *Self, io: std.Io) void {
            var at: usize = 0;
            while (at < self.backlogged.count) {
                const index = self.backlogged.indices[at];
                if (self.drain(io, index)) self.backlogged.remove(index) else at += 1;
            }
        }

        /// Writes as much of a connection's backlog as its ring takes, true once it is empty.
        fn drain(self: *Self, io: std.Io, index: usize) bool {
            const backlog = &self.backlogs[index];
            // A connection keeps its binding while anything published to it waits, since moving
            // it waits for all of its credit back.
            const binding = self.bindings[index] orelse {
                self.dropBacklog(io, index);
                return true;
            };
            while (backlog.count != 0) {
                const packet_index = self.backlog_entries[index * self.backlog_capacity + backlog.head];
                const packet = &self.packets[packet_index];
                const room = self.engine.playRoom(binding.native) orelse {
                    self.dropBacklog(io, index);
                    return true;
                };
                const rest = packet.framed[backlog.offset..];
                const count = @min(room, rest.len);
                if (count == 0) return false;
                self.engine.writePlay(io, binding.native, rest[0..count]);
                self.instruments.fanout_bytes.add(count);
                backlog.offset += count;
                if (backlog.offset < packet.framed.len) return false;
                binding.endpoint.refund(binding.handle, packet.charge -| packet.framed.len);
                backlog.offset = 0;
                backlog.head = (backlog.head + 1) % self.backlog_capacity;
                backlog.count -= 1;
                self.releasePacket(io, packet_index);
            }
            return true;
        }

        /// Gives up what a connection that takes no more output was waiting for.
        fn dropBacklog(self: *Self, io: std.Io, index: usize) void {
            const backlog = &self.backlogs[index];
            const binding = self.bindings[index];
            while (backlog.count != 0) {
                const packet_index = self.backlog_entries[index * self.backlog_capacity + backlog.head];
                if (binding) |bound| bound.endpoint.refund(bound.handle, self.packets[packet_index].charge);
                backlog.head = (backlog.head + 1) % self.backlog_capacity;
                backlog.count -= 1;
                self.releasePacket(io, packet_index);
            }
            // What was to be absorbed went with the packets.
            backlog.* = .{};
            self.backlogged.remove(index);
        }

        fn releasePacket(self: *Self, io: std.Io, packet_index: u32) void {
            const packet = &self.packets[packet_index];
            assert(packet.waiting > 0);
            packet.waiting -= 1;
            if (packet.waiting != 0) return;
            self.recycle(io, packet.source.?, packet.raw);
            packet.* = .{};
        }

        fn recycle(self: *Self, io: std.Io, source: usize, raw: shared.RawPacket) void {
            const count = &self.recycled_counts[source];
            self.recycled[source][count.*] = raw;
            count.* += 1;
            if (count.* == Service.batch_max) self.flushRecycled(io, source);
        }

        fn flushRecycled(self: *Self, io: std.Io, source: usize) void {
            const count = &self.recycled_counts[source];
            self.endpoints[source].recycle(io, self.recycled[source][0..count.*]);
            count.* = 0;
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
                                if (consumed -% move.boundary > std.math.maxInt(usize) / 2 or credit & (Service.active - 1) != source.config.credit_bytes) continue;
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

        /// Gives the endpoint the profile the connection's login and configuration filled in, ahead
        /// of the event that tells the game about the player, which its queue orders after it.
        fn handOverProfile(self: *Self, endpoint: *Service, handle: network.Handle, native: network.Handle) void {
            const profiles = self.config.profiles orelse return;
            endpoint.profiles[handle.index] = profiles.get(native);
        }

        pub fn attached(self: *Self, io: std.Io, profile: engine.Profile) bool {
            if (self.bindings[profile.connection.index]) |*binding| {
                assert(binding.configuring and std.meta.eql(binding.native, profile.connection));
                if (binding.previous == null) {
                    const endpoint = binding.endpoint;
                    self.handOverProfile(endpoint, binding.handle, profile.connection);
                    endpoint.credit[binding.handle.index].store((@as(u64, binding.handle.generation) << 32) | Service.active | endpoint.config.credit_bytes, .release);
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
                self.handOverProfile(endpoint, binding.handle, profile.connection);
                endpoint.credit[binding.handle.index].store((@as(u64, binding.handle.generation) << 32) | Service.active | endpoint.config.credit_bytes, .release);
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
                self.handOverProfile(endpoint, handle, profile.connection);
                self.bindings[profile.connection.index] = .{ .endpoint = endpoint, .handle = handle, .native = profile.connection, .configuring = readiness == .configuring };
                endpoint.credit[index].store((generation << 32) | (if (readiness == .play) Service.active | endpoint.config.credit_bytes else @as(u64, 0)), .release);
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

        /// Grows the input a connection lent, before a tick takes it, to `packets`: the same input
        /// from the same start with more placed after it. False once a tick took it.
        pub fn extend(self: *Self, handle: network.Handle, packets: session_protocol.Packets) bool {
            if (self.reload_state.load(.acquire) != .running) return false;
            const binding = self.bindings[handle.index] orelse return false;
            assert(std.meta.eql(binding.native, handle));
            if (binding.endpoint.moves[binding.handle.index].state.load(.acquire) == .committed) return false;
            return binding.endpoint.extendInput(binding.handle.index, packets.units());
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

        pub fn detached(self: *Self, io: std.Io, handle: network.Handle) bool {
            // What waited for its ring goes back, refunded while its binding still holds.
            self.dropBacklog(io, handle.index);
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
            // Bytes of a packet larger than its charge pay back what it took beyond it first.
            const backlog = &self.backlogs[handle.index];
            const absorbed = @min(bytes, backlog.absorb);
            backlog.absorb -= absorbed;
            if (bytes > absorbed) binding.endpoint.refund(binding.handle, bytes - absorbed);
            const ready = binding.endpoint.readiness.?;
            ready.progress.* |= ready.mask;
        }
    };
}

const TestEndpoint = struct {
    pub const versions = .{};
    pub const Protocols = struct { values: [2]session_protocol.Protocol = .{ .{ .number = 1 }, .{ .number = 2 } } };
    pub const Connection = usize;
    pub const Encryption = session_protocol.Encryption(Connection);
    pub const maximum_encryption_batch_size = 8;
    pub fn encryptionBatchSize(number: i32) usize {
        return if (number == 2) 8 else 4;
    }

    pub fn encryptBatch(number: i32, source: []const u8, targets: []const Encryption) void {
        std.debug.assert(targets.len <= encryptionBatchSize(number));
        for (targets) |target| {
            encrypt(target.connection, source[0..target.first.len], target.first);
            encrypt(target.connection, source[target.first.len..], target.second);
        }
    }
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
    pub const Stream = struct { connection: *Connection, bytes: []u8 };
    pub fn encryptStreams(streams: []const Stream) void {
        for (streams) |stream| send(stream.connection, stream.bytes);
    }
    pub fn preparedFrame(_: i32, _: *Workspaces, storage: []u8, length: usize, _: usize, _: ?usize, _: []u8) ![]const u8 {
        return storage[shared.headroom..][0..length];
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
    sends: usize = 0,
    events: []const network.Event = &.{},
    pub fn closed(_: *@This(), _: network.Handle) void {}
    pub fn notify(self: *@This(), _: std.Io) void {
        self.notifications += 1;
    }
    pub fn queueReceive(_: *@This(), _: std.Io, _: network.Handle, _: []u8) network.QueueError!void {
        unreachable;
    }
    pub fn queueSend(self: *@This(), _: std.Io, _: network.Handle, _: []const std.posix.iovec_const) network.QueueError!void {
        self.sends += 1;
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
test "background publication retry covers both sides of the tick boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var hooks: TestHooks = .{};
    var protocols: TestEndpoint.Protocols = .{};
    const service = try Service.init(arena.allocator(), std.testing.io, .{ .context = &hooks, .vtable = network.Transport.adapter(TestHooks) }, .{ .connections = 1, .pages = 2, .page_bytes = 1500, .credit_bytes = 4096, .protocols = &protocols.values });
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

/// One source and three connections in Play, each bound and with all its credit, to publish to
/// and deliver. Credit is the ring's room, as `Core` gives it.
const DeliveryTest = struct {
    const Owner = Worker(TestEndpoint, TestHooks, SingleSimulation);
    hooks: TestHooks = .{},
    router: SingleSimulation = .{},
    protocols: TestEndpoint.Protocols = .{},
    endpoints: [1]*Service = undefined,
    owner: *Owner = undefined,
    credit_bytes: usize = 0,
    handles: [3]network.Handle = .{ .{ .index = 0, .generation = 1 }, .{ .index = 1, .generation = 1 }, .{ .index = 2, .generation = 1 } },
    events: [1]network.Event = undefined,

    fn init(self: *DeliveryTest, output_bytes: usize) !void {
        const transport: network.Transport = .{ .context = &self.hooks, .vtable = network.Transport.adapter(TestHooks) };
        self.credit_bytes = output_bytes;
        self.endpoints[0] = try Service.init(std.testing.allocator, std.testing.io, transport, .{ .connections = 3, .credit_bytes = output_bytes, .pages = 8, .page_bytes = 6000, .protocols = &self.protocols.values });
        errdefer self.endpoints[0].deinit();
        self.owner = try Owner.init(std.testing.allocator, transport, .{
            .connections = 3,
            .max_players = 3,
            .buffer_bytes = 16 * 1024,
            .connection_bytes = 512,
            .output_bytes = output_bytes,
            .max_pending_wire_bytes = 32 * 1024,
            .compression_threshold = null,
            .protocols = &self.protocols,
            .hooks = &self.hooks,
            .router = &self.router,
            .destinations = &.{0},
        }, &self.endpoints);
        for (self.handles) |handle| {
            const connection = &self.owner.engine.connections[handle.index];
            self.owner.engine.setHandle(handle.index, handle);
            connection.protocol = &self.protocols.values[0];
            connection.lifecycle = 0;
            connection.state.phase = .play;
            self.endpoints[0].routes[handle.index] = handle;
            self.endpoints[0].credit[handle.index].store((@as(u64, 1) << 32) | Service.active | output_bytes, .release);
            self.owner.bindings[handle.index] = .{ .endpoint = self.endpoints[0], .handle = handle, .native = handle };
        }
    }

    fn deinit(self: *DeliveryTest) void {
        for (self.owner.engine.connections) |*connection| connection.sending = false;
        self.owner.abort(std.testing.io);
        self.owner.deinit();
        self.endpoints[0].deinit();
    }

    fn publish(self: *DeliveryTest, value: u8, length: usize, recipients: []const network.Handle) !void {
        var packet = try self.endpoints[0].reserve(length);
        @memset(packet.bytes, value);
        try packet.publish(length, recipients);
        self.endpoints[0].flush();
    }

    fn deliver(self: *DeliveryTest) !void {
        try self.owner.deliver(std.testing.io);
    }

    /// The send in flight to a connection completes, all of it.
    fn sent(self: *DeliveryTest, index: usize) !void {
        const connection = &self.owner.engine.connections[index];
        assert(connection.sending);
        self.events[0] = .{ .sent = .{ .handle = self.handles[index], .result = .{ .bytes = connection.sending_bytes } } };
        self.hooks.events = &self.events;
        try self.owner.engine.receive(std.testing.io);
    }

    fn ring(self: *DeliveryTest, index: usize) []const u8 {
        const connection = &self.owner.engine.connections[index];
        const bytes = self.owner.engine.output[index * self.owner.config.output_bytes ..][0..self.owner.config.output_bytes];
        return bytes[connection.output_read % bytes.len ..][0 .. connection.output_write - connection.output_read];
    }

    fn credit(self: *DeliveryTest, index: usize) usize {
        return @intCast(self.endpoints[0].credit[index].load(.acquire) & (Service.active - 1));
    }

    fn preparing(self: *DeliveryTest) usize {
        return self.endpoints[0].preparing.load(.acquire);
    }
};

test "fan-out writes each packet into every recipient's ring once, in publication order" {
    var delivery: DeliveryTest = .{};
    try delivery.init(4096);
    defer delivery.deinit();
    const handles = delivery.handles;
    try delivery.publish(11, 100, handles[0..2]);
    try delivery.publish(22, 10, handles[1..2]);
    try delivery.publish(33, 10, handles[2..3]);
    try delivery.publish(44, 10, handles[0..1]);
    try delivery.deliver();
    // Every packet reached every recipient in the pass that took it, and went back to the pool.
    try std.testing.expectEqual(@as(usize, 0), delivery.preparing());
    const rings = [_][]const u8{ delivery.ring(0), delivery.ring(1), delivery.ring(2) };
    try std.testing.expect(std.mem.allEqual(u8, rings[0][0..100], 11) and std.mem.allEqual(u8, rings[0][100..], 44) and rings[0].len == 110);
    try std.testing.expect(std.mem.allEqual(u8, rings[1][0..100], 11) and std.mem.allEqual(u8, rings[1][100..], 22) and rings[1].len == 110);
    try std.testing.expect(std.mem.allEqual(u8, rings[2], 33) and rings[2].len == 10);
    // Each ring was encrypted once, in one batch, and sent in one send.
    for ([_]usize{ 110, 110, 10 }, 0..) |length, index| {
        try std.testing.expectEqual(length, delivery.owner.engine.connections[index].lifecycle.?);
        // Credit stays out for exactly what waits to be sent.
        try std.testing.expectEqual(delivery.credit_bytes - length, delivery.credit(index));
    }
    try std.testing.expectEqual(@as(usize, 3), delivery.hooks.sends);
    try delivery.sent(0);
    try std.testing.expectEqual(delivery.credit_bytes, delivery.credit(0));
}

test "credit refuses what a ring could not hold, and everything taken fits it at once" {
    var delivery: DeliveryTest = .{};
    try delivery.init(4096);
    defer delivery.deinit();
    const handles = delivery.handles;
    try delivery.publish(11, 1500, handles[0..1]);
    try delivery.publish(22, 1500, handles[0..1]);
    // A third would charge more than the ring has room for, so it is refused, not queued.
    try std.testing.expectError(error.Backpressured, delivery.publish(33, 1500, handles[0..1]));
    // The other recipient is not held back.
    try delivery.publish(55, 10, handles[1..2]);
    try delivery.deliver();
    const first = delivery.ring(0);
    try std.testing.expectEqual(@as(usize, 3000), first.len);
    try std.testing.expect(std.mem.allEqual(u8, first[0..1500], 11) and std.mem.allEqual(u8, first[1500..], 22));
    try std.testing.expect(std.mem.allEqual(u8, delivery.ring(1), 55) and delivery.ring(1).len == 10);
    // Nothing waits: every packet was in its ring in the pass that took it.
    try std.testing.expectEqual(@as(usize, 0), delivery.preparing());
    try std.testing.expectEqual(@as(usize, 0), delivery.owner.backlogged.count);
    try delivery.sent(0);
    try std.testing.expectEqual(delivery.credit_bytes, delivery.credit(0));
}

test "a packet larger than the ring takes all its credit and goes out in pieces, in order" {
    var delivery: DeliveryTest = .{};
    try delivery.init(4096);
    defer delivery.deinit();
    const handles = delivery.handles;
    try delivery.publish(77, 6000, handles[0..1]);
    try std.testing.expectEqual(@as(usize, 0), delivery.credit(0));
    // Nothing more goes to its recipient meanwhile, while the others are not held back.
    try std.testing.expectError(error.Backpressured, delivery.publish(88, 10, handles[0..1]));
    try delivery.publish(99, 10, handles[1..2]);
    try delivery.deliver();
    try std.testing.expectEqual(@as(usize, 4096), delivery.ring(0).len);
    try std.testing.expectEqual(@as(usize, 1), delivery.preparing());
    // Its first piece sent pays back first what the packet took beyond its charge.
    try delivery.sent(0);
    try std.testing.expectEqual(@as(usize, 4096 - (6000 - 4096)), delivery.credit(0));
    // What is published now waits behind the rest of it.
    try delivery.publish(88, 10, handles[0..1]);
    try delivery.deliver();
    const rest = delivery.ring(0);
    try std.testing.expectEqual(@as(usize, 6000 - 4096 + 10), rest.len);
    try std.testing.expect(std.mem.allEqual(u8, rest[0 .. 6000 - 4096], 77) and std.mem.allEqual(u8, rest[6000 - 4096 ..], 88));
    try std.testing.expectEqual(@as(usize, 0), delivery.preparing());
    // Once all of it is sent, the connection has exactly its credit back.
    try delivery.sent(0);
    try std.testing.expectEqual(delivery.credit_bytes, delivery.credit(0));
}

test "a connection that takes no more output gives its backlog back" {
    var delivery: DeliveryTest = .{};
    try delivery.init(4096);
    defer delivery.deinit();
    try delivery.publish(11, 5000, delivery.handles[0..1]);
    try delivery.publish(22, 100, delivery.handles[1..2]);
    try delivery.deliver();
    try std.testing.expectEqual(@as(usize, 1), delivery.preparing());
    delivery.owner.engine.connections[0].closing = true;
    try delivery.deliver();
    try std.testing.expectEqual(@as(usize, 0), delivery.preparing());
    try std.testing.expectEqual(@as(usize, 0), delivery.owner.backlogged.count);
}
