const metrics = @import("metrics");
const std = @import("std");
const network = @import("networking");
const protocol_api = @import("protocol.zig");
const framing = @import("shared.zig");
const Buffers = @import("buffers.zig").Buffers;
const system = @import("system");
const input_decoding = @import("decoding.zig");
const Readiness = @import("readiness.zig").Readiness;

const assert = std.debug.assert;

pub const Instrumentation = struct {
    poll: metrics.Timer = .{},
    sent_bytes: metrics.Counter = .{},
    seal: metrics.Timer = .{},
    sealed_bytes: metrics.Counter = .{},

    pub fn init(registry: ?*metrics.Registry, namespace: []const u8) !Instrumentation {
        const owner = registry orelse return .{};
        return .{
            .poll = try owner.timer(.{ .namespace = namespace, .name = "poll", .description = "Poll transport events" }),
            .sent_bytes = try owner.counter(.{ .namespace = namespace, .name = "sent_bytes", .description = "Bytes sent through transport", .unit = .bytes }),
            .seal = try owner.timer(.{ .namespace = namespace, .name = "seal", .description = "Encrypt every connection's new Play output and queue its send" }),
            .sealed_bytes = try owner.counter(.{ .namespace = namespace, .name = "sealed_bytes", .description = "Play output encrypted", .unit = .bytes }),
        };
    }
};

pub const Protocol = protocol_api.Protocol;

pub const Profile = protocol_api.Profile;

pub const Disposition = enum { consumed, borrowed, blocked };

/// Why the engine closed a connection.
pub const CloseReason = enum {
    none,
    /// The peer or the transport closed it.
    transport_closed,
    receive_failed,
    send_failed,
    transport_failed,
    verification_failed,
    restore_failed,
    saved_input_failed,
    saved_output_failed,
    /// It did not finish logging in in time.
    admission_timeout,
    admission_failed,
    attach_failed,
    rejected,
    reload,
    stopping,
    /// The server asked for it, and its last output went out.
    disconnected,
    disconnect_failed,
    invalid_frame,
    decode_rejected,
    decode_too_large,
    packet_rejected,
    protocol_rejected,
    input_rejected,
    input_overflow,
    output_rejected,
};

pub fn Engine(comptime Endpoint: type, comptime Observer: type) type {
    return struct {
        const Self = @This();
        const Decoding = input_decoding.Decoding(Endpoint);
        pub const Configuration = struct {
            connections: usize,
            max_players: ?usize = null,
            buffer_bytes: usize = 128 * 1024,
            connection_bytes: usize = 8 * 1024,
            input_burst_slots: usize = 2,
            /// Each connection's ring of Play output: framed packets, encrypted in place before
            /// they are sent. Producers can publish only what fits it, so it never fills.
            output_bytes: usize = 64 * 1024,
            configuration_slots: usize = 8,
            decode_slots: usize = 2,
            max_packet: usize = 128 * 1024 - 3,
            max_pending_wire_bytes: usize = 4 * 1024 * 1024,
            protocols: *const Endpoint.Protocols,
            observer: *Observer,
            compression_threshold: ?usize = null,
            metrics: ?*metrics.Registry = null,
        };

        pub const endpoint = Endpoint;
        const control_bytes_max = 256;
        const control_packets_max = 256;
        const Span = struct {
            source: enum { handoff, spool } = .spool,
            offset: u64 = 0,
            length: usize = 0,
        };
        const absent = std.math.maxInt(usize);
        const Wait = enum { external, control, control_admitted, configuration, configuration_admitted, decoded, input };
        const Waiters = struct { head: usize = absent, tail: usize = absent, count: usize = 0 };
        const Connection = struct {
            handle: ?network.Handle = null,
            protocol: ?*const Protocol = null,
            status: bool = false,
            state: protocol_api.State = .{},
            lifecycle: ?Endpoint.Connection = null,
            input_start: usize = 0,
            input_end: usize = 0,
            receiving: bool = false,
            loan: std.atomic.Value(bool) = .init(false),
            decoded: ?Buffers.Lease = null,
            input_burst: ?Buffers.Lease = null,
            control_burst: ?Buffers.Lease = null,
            control_raw: ?Buffers.Lease = null,
            control_used: usize = 0,
            control_more: bool = false,
            control_packets: [control_packets_max][]const u8 = undefined,
            control_read: usize = 0,
            control_write: usize = 0,
            control_wire: usize = 0,
            saved_input: Span = .{},
            saved_output: Span = .{},
            spooling: bool = false,
            output: []const u8 = &.{},
            control_output: std.ArrayList(u8) = .empty,
            sending: bool = false,
            sending_bytes: usize = 0,
            vectors: [network.send_vectors_max]std.posix.iovec_const = undefined,
            /// Positions in the Play ring, as counts of every byte through it: sent, encrypted,
            /// written. Bytes are encrypted in a batch with other connections' just before they
            /// are sent, so `output_sealed` trails `output_write` only within a pass.
            output_read: usize = 0,
            output_sealed: usize = 0,
            output_write: usize = 0,
            active_previous: ?usize = null,
            active_next: ?usize = null,
            active: bool = false,
            closing: bool = false,
            /// Why the connection is closing, for whoever reads the log.
            close_reason: CloseReason = .none,
            closed: bool = false,
            attached: bool = false,
            resumed: bool = false,
            parked: bool = false,
            output_control: bool = false,
            disconnecting: bool = false,
            admitted: bool = false,
            admission_deadline: i96 = 0,
            poll: protocol_api.Poll = .{},
            waiting_for: Wait = .external,
            waiting: ?Wait = null,
            resource_ready: bool = false,
            wait_previous: usize = absent,
            wait_next: usize = absent,
            disconnect_deadline: ?i96 = null,
            verification: ?protocol_api.LoginVerification = null,
            decode_large: bool = false,
            input_packets: [128][]const u8 = undefined,
            /// What the input lent to the observer holds while a tick has yet to take it, so input
            /// received meanwhile can join it rather than wait for it to come back.
            growing: ?Lent = null,
        };

        /// Whether a connection's lent batch may grow: one of the small packets players send
        /// every tick, while its input sits in its resident buffer, not one that outgrew it.
        fn canGrow(connection: *const Connection) bool {
            return @hasDecl(Observer, "extend") and connection.growing != null and connection.input_burst == null;
        }

        /// What a lent batch of input holds, which grows in place until a tick takes it.
        const Lent = union(enum) {
            packets: struct { count: usize, decoded: usize },
            framed: struct { start: usize, end: usize },
        };

        /// Marks a connection closing, keeping the first reason it was given.
        fn markClosing(connection: *Connection, reason: CloseReason) void {
            if (!connection.closing) connection.close_reason = reason;
            connection.closing = true;
        }

        allocator: std.mem.Allocator,
        networking: network.Transport,
        config: Configuration,

        connections: []Connection,
        input: []align(64) u8,
        output: []align(64) u8,
        decoded_storage: []align(64) u8,
        events: []network.Event,
        workspaces: Endpoint.Workspaces,
        decoded: Buffers,
        input_bursts: Buffers,
        packet_bursts: *Buffers,
        control_bursts: *Buffers,
        configurations: Buffers,
        control_raw: Buffers,
        scratch: []align(64) u8,
        control_storage: []u8,
        resume_file: ?std.Io.File = null,
        spool_file: ?std.Io.File = null,
        file_io: std.Io = undefined,
        stopping: bool = false,
        stop_deadline: i96 = 0,
        instruments: Instrumentation,
        admitted: usize = 0,
        identities: std.AutoArrayHashMapUnmanaged(u128, usize),
        reloading: bool = false,
        poll: protocol_api.Poll = .{},
        readiness: Readiness,
        progress_cursor: usize = 0,
        waiting: [std.enums.values(Wait).len]Waiters = @splat(.{}),
        resources_ready: bool = true,
        external_ready: bool = true,
        transport_waiting: system.IndexSet,
        /// Connections with Play output written since it was last encrypted.
        unsealed: system.IndexSet,
        // Transport and protocol progress invalidate blocked Play delivery attempts.
        delivery_ready: bool = true,
        active_head: ?usize = null,
        active_tail: ?usize = null,
        active_count: usize = 0,

        pub fn init(allocator: std.mem.Allocator, networking: network.Transport, config: Configuration) !*Self {
            if (config.protocols.values.len == 0 or config.decode_slots == 0 or config.connection_bytes < 512 or config.input_burst_slots == 0 or config.configuration_slots == 0) return error.InvalidConfiguration;
            // The ring holds whole packets' frames only in part, a large one passing through it in
            // pieces, but a pass must be able to move at least a send's worth.
            if (config.output_bytes < 4096 or config.output_bytes > std.math.maxInt(u32) / 4) return error.InvalidConfiguration;
            if ((config.max_players orelse config.connections) == 0 or (config.max_players orelse config.connections) > config.connections)
                return error.InvalidConfiguration;
            if (config.connections == 0 or config.buffer_bytes < 512 or config.buffer_bytes > std.math.maxInt(u32) / 4 or
                config.max_packet == 0 or config.max_packet > config.buffer_bytes - 3 or config.max_pending_wire_bytes < config.buffer_bytes + 2 * control_bytes_max or config.max_pending_wire_bytes > std.math.maxInt(u32) - 2 * config.buffer_bytes - 57 or
                (config.compression_threshold != null and config.compression_threshold.? > config.max_packet)) return error.InvalidConfiguration;

            for (config.protocols.values, 0..) |protocol, i| {
                for (config.protocols.values[0..i]) |previous| if (protocol.number == previous.number) return error.InvalidConfiguration;
            }

            const small = @min(config.connection_bytes, config.buffer_bytes);
            const bytes = try std.math.mul(usize, config.connections, small);
            const instrumentation = try Instrumentation.init(config.metrics, "session.engine");
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const connections = try allocator.alloc(Connection, config.connections);
            errdefer allocator.free(connections);
            var identities: std.AutoArrayHashMapUnmanaged(u128, usize) = .{};
            try identities.ensureTotalCapacity(allocator, config.max_players orelse config.connections);
            errdefer identities.deinit(allocator);
            var readiness = try Readiness.init(allocator, config.connections);
            errdefer readiness.deinit(allocator);
            var transport_waiting = try system.IndexSet.init(allocator, config.connections);
            errdefer transport_waiting.deinit(allocator);
            var unsealed = try system.IndexSet.init(allocator, config.connections);
            errdefer unsealed.deinit(allocator);
            const input = try allocator.alignedAlloc(u8, .@"64", bytes);
            errdefer allocator.free(input);
            const output = try allocator.alignedAlloc(u8, .@"64", try std.math.mul(usize, config.connections, config.output_bytes));
            errdefer allocator.free(output);
            const decoded_storage = try allocator.alignedAlloc(u8, .@"64", bytes);
            errdefer allocator.free(decoded_storage);
            const events = try allocator.alloc(network.Event, config.connections * 3);
            errdefer allocator.free(events);
            const decode_slots = if (Endpoint.needsDecoded(config.compression_threshold)) @min(config.decode_slots, config.connections) else 0;
            const input_slots = if (small == config.buffer_bytes) 0 else @min(config.input_burst_slots, config.connections);
            const packet_slots = @max(decode_slots, input_slots);
            const control_slots = @min(config.configuration_slots, config.connections);
            const packet_bursts = try allocator.create(Buffers);
            errdefer allocator.destroy(packet_bursts);
            packet_bursts.* = try Buffers.init(allocator, .{ .slots = packet_slots - @min(packet_slots, 1), .bytes = config.buffer_bytes });
            errdefer packet_bursts.deinit(allocator);
            const control_bursts = try allocator.create(Buffers);
            errdefer allocator.destroy(control_bursts);
            // One private control slot progresses configuration while another serves status and login.
            const control_guaranteed = @min(control_slots, 2);
            control_bursts.* = try Buffers.init(allocator, .{ .slots = control_slots - control_guaranteed, .bytes = config.max_pending_wire_bytes });
            errdefer control_bursts.deinit(allocator);
            var decoded = try Buffers.init(allocator, .{ .slots = decode_slots, .bytes = config.buffer_bytes, .guaranteed = @min(decode_slots, 1), .overflow = packet_bursts });
            errdefer decoded.deinit(allocator);
            var input_bursts = try Buffers.init(allocator, .{ .slots = input_slots, .bytes = config.buffer_bytes, .guaranteed = @min(input_slots, 1), .overflow = packet_bursts });
            errdefer input_bursts.deinit(allocator);
            var configurations = try Buffers.init(allocator, .{ .slots = control_slots, .bytes = config.max_pending_wire_bytes, .guaranteed = control_guaranteed, .overflow = control_bursts });
            errdefer configurations.deinit(allocator);
            var control_raw = try Buffers.init(allocator, .{ .slots = control_slots, .bytes = config.max_pending_wire_bytes, .guaranteed = control_guaranteed, .overflow = control_bursts });
            errdefer control_raw.deinit(allocator);
            try packet_bursts.instrument(config.metrics, "session.buffers.packet_shared");
            try control_bursts.instrument(config.metrics, "session.buffers.control_shared");
            try decoded.instrument(config.metrics, "session.buffers.decoded");
            try input_bursts.instrument(config.metrics, "session.buffers.input_bursts");
            try configurations.instrument(config.metrics, "session.buffers.configurations");
            try control_raw.instrument(config.metrics, "session.buffers.control_raw");
            const scratch = try allocator.alignedAlloc(u8, .@"64", config.buffer_bytes);
            errdefer allocator.free(scratch);
            const control_storage = try allocator.alloc(u8, try std.math.mul(usize, config.connections, small));
            errdefer allocator.free(control_storage);

            for (connections, 0..) |*connection, index| connection.* = .{ .control_output = .initBuffer(control_storage[index * small ..][0..small]) };

            self.* = .{
                .allocator = allocator,
                .networking = networking,
                .config = config,
                .connections = connections,
                .identities = identities,
                .readiness = readiness,
                .input = input,
                .transport_waiting = transport_waiting,
                .unsealed = unsealed,
                .output = output,
                .decoded_storage = decoded_storage,
                .events = events,
                .workspaces = try Endpoint.initWorkspaces(allocator),
                .decoded = decoded,
                .input_bursts = input_bursts,
                .packet_bursts = packet_bursts,
                .control_bursts = control_bursts,
                .configurations = configurations,
                .control_raw = control_raw,
                .scratch = scratch,
                .control_storage = control_storage,
                .instruments = instrumentation,
            };
            return self;
        }

        pub fn deinit(self: *Self) void {
            assert(self.drained());
            for (self.waiting) |queue| assert(queue.count == 0 and queue.head == absent and queue.tail == absent);
            assert(self.transport_waiting.count == 0);
            assert(self.admitted == 0 and self.identities.count() == 0);

            self.transport_waiting.deinit(self.allocator);
            self.unsealed.deinit(self.allocator);
            self.identities.deinit(self.allocator);
            Endpoint.deinitWorkspaces(&self.workspaces);
            self.allocator.free(self.scratch);
            self.allocator.free(self.decoded_storage);
            self.decoded.deinit(self.allocator);
            self.input_bursts.deinit(self.allocator);
            self.configurations.deinit(self.allocator);
            self.control_raw.deinit(self.allocator);
            self.packet_bursts.deinit(self.allocator);
            self.allocator.destroy(self.packet_bursts);
            self.control_bursts.deinit(self.allocator);
            self.allocator.destroy(self.control_bursts);
            if (self.resume_file) |file| file.close(self.file_io);
            if (self.spool_file) |file| file.close(self.file_io);
            self.allocator.free(self.events);
            self.allocator.free(self.output);
            self.allocator.free(self.input);
            self.allocator.free(self.control_storage);
            self.readiness.deinit(self.allocator);
            self.allocator.free(self.connections);
            self.allocator.destroy(self);
        }

        pub fn admit(self: *Self, index: usize) void {
            const connection = &self.connections[index];
            assert(connection.handle != null and !connection.admitted);
            assert(!self.identities.contains(connection.state.uuid));
            assert(self.admitted < (self.config.max_players orelse self.connections.len));
            self.identities.putAssumeCapacityNoClobber(connection.state.uuid, index);
            connection.admitted = true;
            self.admitted += 1;
            assert(self.identities.count() == self.admitted);
        }

        pub fn beginShutdown(self: *Self, io: std.Io) void {
            self.delivery_ready = true;
            if (self.stopping) return;
            self.stopping = true;
            self.wakeAll();
            self.stop_deadline = std.Io.Clock.now(.awake, io).nanoseconds + 3 * std.time.ns_per_s;
        }

        pub fn wakeAll(self: *Self) void {
            var current = self.active_head;
            while (current) |index| {
                self.readiness.signal(index).notify();
                current = self.connections[index].active_next;
            }
        }

        pub fn setHandle(self: *Self, index: usize, handle: ?network.Handle) void {
            self.delivery_ready = true;
            const connection = &self.connections[index];
            if (handle) |value| {
                assert(value.index == index and value.generation != 0);
                assert(connection.handle == null or std.meta.eql(connection.handle.?, value));
                connection.handle = value;
                self.readiness.signal(index).notify();
                if (connection.active) return;
                assert(connection.active_previous == null and connection.active_next == null);
                connection.active_previous = self.active_tail;
                if (self.active_tail) |tail| {
                    assert(self.connections[tail].active and self.connections[tail].active_next == null);
                    self.connections[tail].active_next = index;
                } else self.active_head = index;
                self.active_tail = index;
                connection.active = true;
                self.active_count += 1;
            } else {
                if (connection.admitted) {
                    assert(self.identities.get(connection.state.uuid).? == index and self.admitted > 0);
                    const removed = self.identities.swapRemove(connection.state.uuid);
                    assert(removed);
                    self.admitted -= 1;
                    connection.admitted = false;
                }
                if (connection.active) {
                    if (connection.active_previous) |previous| {
                        assert(self.connections[previous].active_next == index);
                        self.connections[previous].active_next = connection.active_next;
                    } else {
                        assert(self.active_head == index);
                        self.active_head = connection.active_next;
                    }
                    if (connection.active_next) |following| {
                        assert(self.connections[following].active_previous == index);
                        self.connections[following].active_previous = connection.active_previous;
                    } else {
                        assert(self.active_tail == index);
                        self.active_tail = connection.active_previous;
                    }
                    connection.active_previous = null;
                    connection.active_next = null;
                    connection.active = false;
                    assert(self.active_count > 0);
                    self.active_count -= 1;
                }
                connection.handle = null;
                self.readiness.update(index, null);
                self.removeWait(index);
            }
            assert(self.identities.count() == self.admitted);
            assert((self.active_count == 0) == (self.active_head == null));
            assert((self.active_head == null) == (self.active_tail == null));
            assert((connection.handle != null) == connection.active);
        }

        pub fn disconnect(self: *Self, io: std.Io, handle: network.Handle) void {
            self.delivery_ready = true;
            if (handle.index >= self.connections.len) return;

            const connection = &self.connections[handle.index];
            if (connection.handle == null or !std.meta.eql(connection.handle.?, handle)) return;
            if (connection.disconnect_deadline != null) return;
            self.readiness.signal(handle.index).notify();
            connection.disconnect_deadline = std.Io.Clock.now(.awake, io).nanoseconds + 3 * std.time.ns_per_s;
        }

        pub fn drained(self: *const Self) bool {
            return self.active_count == 0;
        }

        pub fn park(self: *Self, io: std.Io) !bool {
            assert(self.reloading);
            if (!self.networking.inheritance.?.ready()) return false;
            try self.spill(io);
            var ready = true;
            for (self.connections, 0..) |*connection, index| {
                if (connection.handle == null) continue;
                if (connection.closing or connection.receiving or connection.sending or connection.loan.load(.acquire)) {
                    ready = false;
                    continue;
                }
                if (connection.parked) continue;
                connection.growing = null;
                if (connection.decoded) |lease| lease.release();
                connection.decoded = null;
                if (!self.reserveControl(index)) {
                    ready = false;
                    continue;
                }
                self.readiness.signal(index).notify();
                if (try self.advance(io, connection, .park)) |packet| try self.queueControl(io, connection, packet);
                self.releaseControl(index);
                connection.parked = true;
            }
            return ready;
        }

        pub fn restart(self: *Self, io: std.Io) void {
            self.reloading = false;
            self.wakeAll();

            for (self.connections) |*connection| {
                if (connection.handle == null) continue;
                assert(connection.parked);
                _ = self.advance(io, connection, .restore) catch |err| {
                    std.log.err("event=session_restore_failed reason={s}", .{@errorName(err)});
                    markClosing(connection, .restore_failed);
                    continue;
                };
                connection.parked = false;
                connection.spooling = false;
                connection.attached = false;
                connection.resumed = true;
                connection.admission_deadline = std.Io.Clock.now(.awake, io).nanoseconds + 30 * std.time.ns_per_s;
            }
        }

        pub fn writeResume(self: *Self, writer: *std.Io.Writer) !void {
            assert(self.reloading);
            const native = self.networking.inheritance.?;
            var count: u32 = 0;

            for (self.connections) |connection| if (connection.handle != null) {
                count += 1;
            };

            try writer.writeInt(u32, count, .little);

            for (self.connections, 0..) |*connection, index| {
                const handle = connection.handle orelse continue;
                assert(connection.parked and !connection.receiving and !connection.sending and !connection.loan.load(.acquire));
                const input = self.inputBuffer(index)[connection.input_start..connection.input_end];
                const input_len = input.len + connection.saved_input.length;
                const output_len = self.queuedOutput(connection);
                const codec = try Endpoint.save(&connection.lifecycle.?, self.scratch);
                try writer.writeInt(i32, native.descriptor(handle), .little);
                try writer.writeInt(u32, 1, .little);
                try writer.writeInt(u32, @intCast(57 + codec.len + input_len + output_len), .little);
                try writer.writeInt(i32, connection.protocol.?.number, .little);
                try writer.writeInt(u64, Endpoint.resumeFormat(&connection.lifecycle.?), .little);
                try writer.writeInt(u32, @intCast(codec.len), .little);
                try writer.writeAll(codec);
                try writer.writeInt(u128, connection.state.uuid, .little);
                try writer.writeByte(@intCast(connection.state.name_len));
                try writer.writeAll(&connection.state.name);
                try writer.writeInt(u32, @intCast(input_len), .little);
                try writer.writeAll(input);
                try self.writeSpan(writer, connection.saved_input);
                try writer.writeInt(u32, @intCast(output_len), .little);
                if (connection.output_control) {
                    try writer.writeAll(connection.output);
                    if (connection.control_read < connection.control_write) {
                        for (connection.control_packets[connection.control_read + 1 .. connection.control_write]) |packet| try writer.writeAll(packet);
                    }
                }
                try self.writeSpan(writer, connection.saved_output);
                // Parking spilled and sealed the ring, so what is left in it is encrypted.
                assert(connection.output_sealed == connection.output_write);
                const ring = self.ringBuffer(index);
                const queued = connection.output_write -% connection.output_read;
                const at = connection.output_read % ring.len;
                const first = @min(queued, ring.len - at);
                try writer.writeAll(ring[at..][0..first]);
                try writer.writeAll(ring[0 .. queued - first]);

                if (input.len != 0) std.log.info("event=reload_input_saved bytes={d} encrypted={}", .{ input.len, Endpoint.encrypted(&connection.lifecycle.?) });
            }
        }

        pub fn readResume(self: *Self, io: std.Io, reader: *std.Io.Reader, file_reader: ?*std.Io.File.Reader) !void {
            assert(self.admitted == 0);
            const native = self.networking.inheritance orelse return error.InheritanceUnavailable;
            self.file_io = io;
            const count = try reader.takeInt(u32, .little);
            if (count > (self.config.max_players orelse self.connections.len)) return error.ResumeCapacity;

            for (0..count) |_| {
                const fd = try reader.takeInt(i32, .little);
                if (fd < 3) return error.InvalidResume;
                const handle = try native.adopt(fd);
                if (handle.index >= self.connections.len or self.connections[handle.index].handle != null) return error.InvalidResume;
                const kind = try reader.takeInt(u32, .little);
                const length = try reader.takeInt(u32, .little);
                if (kind != 1 or length < 57 or length - 57 > self.config.buffer_bytes + self.config.max_pending_wire_bytes + self.scratch.len) return error.InvalidResume;

                var connection: Connection = .{ .resumed = true };
                errdefer {
                    self.config.observer.closed(handle);
                    if (connection.lifecycle) |*lifecycle| Endpoint.clear(lifecycle);
                }
                const number = try reader.takeInt(i32, .little);
                const format = try reader.takeInt(u64, .little);
                const codec_len = try reader.takeInt(u32, .little);
                if (codec_len > self.scratch.len or codec_len > length - 57) return error.InvalidResume;
                try reader.readSliceAll(self.scratch[0..codec_len]);

                for (&self.config.protocols.values) |*protocol| if (protocol.number == number) {
                    connection.protocol = protocol;
                    break;
                };

                if (connection.protocol == null) return error.UnsupportedProtocol;
                connection.lifecycle = try Endpoint.restore(number, format, self.scratch[0..codec_len]);
                connection.state.phase = .parked;
                connection.state.uuid = try reader.takeInt(u128, .little);

                if (self.identities.contains(connection.state.uuid)) return error.InvalidResume;

                connection.state.name_len = try reader.takeByte();
                try reader.readSliceAll(&connection.state.name);
                if (connection.state.name_len == 0 or connection.state.name_len > 16)
                    return error.InvalidResume;

                const input_len = try reader.takeInt(u32, .little);
                if (input_len > self.config.buffer_bytes or input_len > length - 57 - codec_len) return error.InvalidResume;

                connection.control_output = self.connections[handle.index].control_output;
                connection.handle = handle;
                connection.admission_deadline = std.Io.Clock.now(.awake, io).nanoseconds + 30 * std.time.ns_per_s;
                if (input_len <= self.smallBytes()) {
                    try reader.readSliceAll(self.inputBuffer(handle.index)[0..input_len]);
                    connection.input_end = input_len;
                } else connection.saved_input = try self.captureSpan(io, reader, file_reader, self.spoolBase(handle.index) + self.config.max_pending_wire_bytes, input_len);
                const output_len = try reader.takeInt(u32, .little);
                if (output_len > self.config.max_pending_wire_bytes or output_len != length - 57 - codec_len - input_len) return error.InvalidResume;
                if (output_len <= connection.control_output.capacity) {
                    connection.control_output.items.len = output_len;
                    try reader.readSliceAll(connection.control_output.items);
                    connection.output = connection.control_output.items;
                    connection.output_control = true;
                } else connection.saved_output = try self.captureSpan(io, reader, file_reader, self.spoolBase(handle.index), output_len);
                if (!connection.closing) _ = try self.advance(io, &connection, .restore);

                if (input_len != 0) std.log.info("event=reload_input_restored bytes={d} encrypted={}", .{ input_len, Endpoint.encrypted(&connection.lifecycle.?) });
                self.connections[handle.index] = connection;
                self.setHandle(handle.index, handle);
                self.admit(handle.index);
            }
        }

        /// The caller has stopped new Play output. Existing output and input loans must drain before
        /// changing the codec phase. Cipher streams stay intact.
        pub fn reconfigure(self: *Self, io: std.Io, handle: network.Handle) !bool {
            const connection = &self.connections[handle.index];
            assert(connection.handle != null and std.meta.eql(connection.handle.?, handle));
            assert(connection.state.phase == .play and connection.attached);
            if (connection.closing or connection.disconnect_deadline != null or self.stopping) return false;
            if (connection.output.len != 0 or connection.saved_output.length != 0 or connection.sending or connection.output_read != connection.output_write or connection.loan.load(.acquire))
                return false;

            if (!self.reserveControl(handle.index)) return false;
            self.readiness.signal(handle.index).notify();
            if (try self.advance(io, connection, .park)) |bytes| try self.queueControl(io, connection, bytes);
            connection.admission_deadline = std.Io.Clock.now(.awake, io).nanoseconds + 10 * std.time.ns_per_s;
            return true;
        }

        /// The observer may release its single input loan from another thread.
        /// It must not access the payload after this call.
        pub fn releaseInput(self: *Self, io: std.Io, handle: network.Handle) void {
            const transport = self.networking;
            const connection = &self.connections[handle.index];
            assert(connection.handle != null);
            assert(std.meta.eql(connection.handle.?, handle));
            const borrowed = connection.loan.swap(false, .release);
            assert(borrowed);
            self.readiness.signal(handle.index).notify();
            transport.notify(io);
        }

        /// How many bytes of Play output a connection takes now, or null once it takes none: gone,
        /// closing, stopping or out of Play. While a reload spools output, the spool takes what
        /// the ring would.
        pub fn playRoom(self: *Self, handle: network.Handle) ?usize {
            if (handle.index >= self.connections.len) return null;
            const connection = &self.connections[handle.index];
            if (connection.handle == null or !std.meta.eql(connection.handle.?, handle) or connection.closing or self.stopping or connection.disconnect_deadline != null or connection.state.phase != .play)
                return null;
            if (connection.spooling) return self.config.max_pending_wire_bytes - connection.saved_output.length;
            const used = connection.output_write -% connection.output_read;
            assert(used <= self.config.output_bytes);
            return self.config.output_bytes - used;
        }

        /// Appends Play output as it goes on the wire, before encryption, no more than `playRoom`
        /// allowed. It is encrypted with every other connection's in `sealPlay`.
        pub fn writePlay(self: *Self, io: std.Io, handle: network.Handle, bytes: []const u8) void {
            assert(bytes.len <= self.playRoom(handle).?);
            if (bytes.len == 0) return;
            const connection = &self.connections[handle.index];
            if (connection.spooling) {
                // The ring went into the spool sealed, so the spool takes what follows encrypted.
                assert(connection.output_write == connection.output_read);
                var offset: usize = 0;
                while (offset < bytes.len) {
                    const length = @min(bytes.len - offset, self.scratch.len);
                    const chunk = self.scratch[0..length];
                    @memcpy(chunk, bytes[offset..][0..length]);
                    if (Endpoint.encrypted(&connection.lifecycle.?)) Endpoint.send(&connection.lifecycle.?, chunk);
                    self.appendSpool(io, handle.index, chunk) catch |err| {
                        std.log.warn("event=session_spool_failed connection={d}:{d} reason={s}", .{ handle.index, handle.generation, @errorName(err) });
                        markClosing(connection, .output_rejected);
                        return;
                    };
                    offset += length;
                }
                return;
            }
            const ring = self.ringBuffer(handle.index);
            const at = connection.output_write % ring.len;
            const first = @min(bytes.len, ring.len - at);
            @memcpy(ring[at..][0..first], bytes[0..first]);
            @memcpy(ring[0 .. bytes.len - first], bytes[first..]);
            connection.output_write +%= bytes.len;
            self.unsealed.insert(handle.index);
        }

        /// Streams encrypted in one batch, beyond which the lanes are long since full.
        const seal_batch = 128;

        /// Encrypts every connection's new Play output, side by side, then sends it. A connection
        /// whose control output is being sent waits, as that output took its cipher first and goes
        /// out first.
        pub fn sealPlay(self: *Self, io: std.Io) void {
            if (self.unsealed.count == 0) return;
            const timing = self.instruments.seal.start();
            defer timing.end();
            var streams: [seal_batch]Endpoint.Stream = undefined;
            var wrapped: [seal_batch]Endpoint.Stream = undefined;
            var sealed: [seal_batch]usize = undefined;
            var count: usize = 0;
            var wrapped_count: usize = 0;
            var at: usize = 0;
            while (at < self.unsealed.count) {
                const index = self.unsealed.indices[at];
                const connection = &self.connections[index];
                if (connection.output_control) {
                    at += 1;
                    continue;
                }
                self.unsealed.remove(index);
                const length = connection.output_write -% connection.output_sealed;
                if (length == 0) continue;
                self.instruments.sealed_bytes.add(length);
                const ring = self.ringBuffer(index);
                const start = connection.output_sealed % ring.len;
                const first = @min(length, ring.len - start);
                connection.output_sealed = connection.output_write;
                if (Endpoint.encrypted(&connection.lifecycle.?)) {
                    streams[count] = .{ .connection = &connection.lifecycle.?, .bytes = ring[start..][0..first] };
                    // The part past the end of the ring continues the same stream, so it goes in
                    // the batch after.
                    if (first != length) {
                        wrapped[wrapped_count] = .{ .connection = &connection.lifecycle.?, .bytes = ring[0 .. length - first] };
                        wrapped_count += 1;
                    }
                } else streams[count] = .{ .connection = &connection.lifecycle.?, .bytes = &.{} };
                sealed[count] = index;
                count += 1;
                if (count == seal_batch) {
                    self.finishSeal(io, streams[0..count], wrapped[0..wrapped_count], sealed[0..count]);
                    count = 0;
                    wrapped_count = 0;
                }
            }
            self.finishSeal(io, streams[0..count], wrapped[0..wrapped_count], sealed[0..count]);
        }

        fn finishSeal(self: *Self, io: std.Io, streams: []const Endpoint.Stream, wrapped: []const Endpoint.Stream, sealed: []const usize) void {
            Endpoint.encryptStreams(streams);
            Endpoint.encryptStreams(wrapped);
            for (sealed) |index| self.sendOutput(io, index);
        }

        pub fn receive(self: *Self, io: std.Io) !void {
            const timeout: ?std.Io.Timeout = if (self.poll.deadline) |nanoseconds|
                .{ .deadline = .{ .clock = .awake, .raw = .{ .nanoseconds = nanoseconds } } }
            else
                null;
            const count = blk: {
                const polling = self.instruments.poll.start();
                defer polling.end();
                break :blk try self.networking.poll(io, timeout, self.events);
            };
            assert(count <= self.events.len);
            self.external_ready = true;

            for (self.events[0..count]) |event| {
                const handle = switch (event) {
                    .accepted => |value| value,
                    .received, .sent => |value| value.handle,
                    .closed => |value| value.handle,
                };
                if (handle.index >= self.connections.len) {
                    if (event == .closed) self.networking.release(io, handle) else self.networking.close(io, handle, .capacity);
                    continue;
                }

                const connection = &self.connections[handle.index];
                self.readiness.signal(handle.index).notify();

                if (event == .accepted) {
                    assert(connection.handle == null and !connection.active);
                    connection.* = .{
                        .control_output = .initBuffer(connection.control_output.items.ptr[0..self.smallBytes()]),
                        .admission_deadline = std.Io.Clock.now(.awake, io).nanoseconds + 30 * std.time.ns_per_s,
                    };
                    self.setHandle(handle.index, handle);
                    std.log.debug("event=session_accepted connection={d}:{d}", .{ handle.index, handle.generation });
                } else {
                    if (connection.handle == null or !std.meta.eql(connection.handle.?, handle)) continue;

                    switch (event) {
                        .received => |result| {
                            assert(connection.receiving);
                            connection.receiving = result.result.more;

                            if (!result.result.more and result.result.errno == @backingInt(std.posix.E.NOBUFS)) continue;
                            if (self.reloading and result.result.errno == @backingInt(std.posix.E.CANCELED)) continue;
                            if (result.result.errno != null or result.result.bytes == 0 or result.result.bytes > self.inputBuffer(handle.index).len - connection.input_end) {
                                markClosing(connection, .receive_failed);
                            } else {
                                if (connection.lifecycle) |*lifecycle| {
                                    const bytes = self.inputBuffer(handle.index)[connection.input_end..][0..result.result.bytes];
                                    Endpoint.receive(lifecycle, bytes);
                                }

                                connection.input_end += result.result.bytes;
                            }
                        },
                        .sent => |result| {
                            assert(connection.sending);
                            connection.sending = false;

                            if (self.reloading and result.result.errno == @backingInt(std.posix.E.CANCELED)) continue;
                            if (result.result.errno != null or result.result.bytes == 0 or result.result.bytes > connection.sending_bytes) {
                                markClosing(connection, .send_failed);
                            } else {
                                assert(result.result.bytes > 0 and result.result.bytes <= connection.sending_bytes);
                                self.instruments.sent_bytes.add(result.result.bytes);
                                self.sent(io, handle, result.result.bytes);
                            }
                        },
                        .closed => {
                            assert(!connection.receiving and !connection.sending);
                            connection.closed = true;
                            // Closed with no reason of ours, the transport or the peer closed it.
                            markClosing(connection, .transport_closed);
                            std.log.info("event=session_closed connection={d}:{d} phase={s} reason={t}", .{ handle.index, handle.generation, @tagName(connection.state.phase), connection.close_reason });
                        },
                        .accepted => unreachable,
                    }
                }
            }
        }

        fn sendOutput(self: *Self, io: std.Io, index: usize) void {
            const connection = &self.connections[index];
            const handle = connection.handle orelse return;
            if (self.reloading or connection.closing or connection.closed or connection.state.phase == .parked) return;
            if (connection.state.phase == .play and connection.output.len == 0 and connection.saved_output.length == 0) {
                const queued = connection.output_sealed -% connection.output_read;
                const ring = self.ringBuffer(index);
                const at = connection.output_read % ring.len;
                // Equal byte quanta per ready connection, replenished on completion, not per tick.
                connection.output = ring[at..][0..@min(queued, ring.len - at, 64 * 1024)];
            }

            if (connection.output.len != 0 and !connection.sending) {
                const count = self.sendVectors(connection);
                self.networking.queueSend(io, handle, connection.vectors[0..count]) catch |err| switch (err) {
                    error.Full => {
                        self.transport_waiting.insert(index);
                        return;
                    },
                    else => {
                        markClosing(connection, .transport_failed);
                        return;
                    },
                };
                connection.sending = true;
            }
        }

        fn sendVectors(self: *Self, connection: *Connection) usize {
            var count: usize = 0;
            var bytes: usize = 0;
            if (!connection.output_control) {
                const ring = self.ringBuffer(connection.handle.?.index);
                const at = connection.output_read % ring.len;
                bytes = @min(connection.output_sealed -% connection.output_read, 64 * 1024);
                const first = @min(bytes, ring.len - at);
                connection.vectors[0] = .{ .base = ring[at..].ptr, .len = first };
                count = 1;
                if (bytes != first) {
                    connection.vectors[1] = .{ .base = ring.ptr, .len = bytes - first };
                    count = 2;
                }
            } else {
                const length = @min(connection.output.len, 64 * 1024);
                connection.vectors[0] = .{ .base = connection.output.ptr, .len = length };
                count = 1;
                bytes = length;
                if (length == connection.output.len and connection.output_control and connection.control_read < connection.control_write) {
                    for (connection.control_packets[connection.control_read + 1 .. connection.control_write]) |packet| {
                        if (count == connection.vectors.len or bytes == 64 * 1024) break;
                        const size = @min(packet.len, 64 * 1024 - bytes);
                        connection.vectors[count] = .{ .base = packet.ptr, .len = size };
                        count += 1;
                        bytes += size;
                    }
                }
            }
            connection.sending_bytes = bytes;
            return count;
        }

        fn sent(self: *Self, io: std.Io, handle: network.Handle, count: usize) void {
            self.delivery_ready = true;
            const connection = &self.connections[handle.index];
            assert(count > 0 and count <= connection.sending_bytes);
            if (!connection.output_control) {
                assert(count <= connection.output_sealed -% connection.output_read);
                connection.output = &.{};
            } else {
                var remaining = count;
                while (remaining != 0) {
                    const length = @min(remaining, connection.output.len);
                    remaining -= length;
                    connection.output = connection.output[length..];
                    if (connection.output.len == 0 and connection.control_read < connection.control_write) {
                        connection.control_read += 1;
                        if (connection.control_read < connection.control_write) connection.output = connection.control_packets[connection.control_read];
                    }
                }
            }
            if (connection.state.phase == .play and !connection.output_control) {
                connection.output_read +%= count;
                self.config.observer.sent(io, handle, count);
            }
            if (connection.output.len == 0) {
                connection.output_control = false;
                connection.control_output.clearRetainingCapacity();
            }
        }

        fn smallBytes(self: *const Self) usize {
            return @min(self.config.connection_bytes, self.config.buffer_bytes);
        }

        fn inputBuffer(self: *Self, index: usize) []u8 {
            if (self.connections[index].input_burst) |lease| return lease.bytes;
            const stride = self.smallBytes();
            return self.input[index * stride ..][0..stride];
        }

        fn ringBuffer(self: *Self, index: usize) []u8 {
            const stride = self.config.output_bytes;
            return self.output[index * stride ..][0..stride];
        }

        fn releaseControl(self: *Self, index: usize) void {
            const connection = &self.connections[index];
            assert(!connection.sending and connection.output.len == 0);
            if (connection.control_burst) |lease| lease.release();
            connection.control_burst = null;
            if (connection.control_raw) |lease| lease.release();
            connection.control_raw = null;
            connection.control_used = 0;
            connection.control_more = false;
            connection.control_read = 0;
            connection.control_write = 0;
            connection.control_wire = 0;
            const stride = self.smallBytes();
            connection.control_output = .initBuffer(self.control_storage[index * stride ..][0..stride]);
        }

        pub fn releaseBuffers(self: *Self, index: usize) void {
            self.delivery_ready = true;
            const connection = &self.connections[index];
            assert(!connection.receiving and !connection.sending and !connection.loan.load(.acquire));
            if (connection.input_burst) |lease| lease.release();
            if (connection.decoded) |lease| lease.release();
            connection.input_burst = null;
            connection.decoded = null;
            connection.output = &.{};
            connection.output_read = 0;
            connection.output_sealed = 0;
            connection.output_write = 0;
            self.unsealed.remove(index);
            self.releaseControl(index);
        }

        fn reserveControl(self: *Self, index: usize) bool {
            const connection = &self.connections[index];
            assert((connection.control_raw == null) == (connection.control_burst == null));
            if (connection.control_burst != null) return true;
            assert(self.control_raw.maximum == self.configurations.maximum);
            // Reserve both sides of a control operation before consuming input or holding shared capacity.
            const limit = self.configurations.maximum - @intFromBool(connection.admitted and self.configurations.maximum > 1);
            const raw = self.control_raw.acquireWithin(limit) orelse {
                connection.waiting_for = if (connection.admitted) .control_admitted else .control;
                self.wait(index);
                return false;
            };
            const lease = self.configurations.acquireWithin(limit) orelse {
                raw.release();
                connection.waiting_for = if (connection.admitted) .configuration_admitted else .configuration;
                self.wait(index);
                return false;
            };
            assert(connection.control_output.items.len == 0);
            connection.control_raw = raw;
            connection.control_burst = lease;
            connection.control_output = .initBuffer(lease.bytes);
            return true;
        }

        fn queuedOutput(_: *Self, connection: *const Connection) usize {
            var bytes = (if (connection.output_control) connection.output.len else @as(usize, 0)) + connection.saved_output.length + (connection.output_write -% connection.output_read);
            if (connection.output_control and connection.control_read < connection.control_write) {
                for (connection.control_packets[connection.control_read + 1 .. connection.control_write]) |packet| bytes += packet.len;
            }
            return bytes;
        }

        fn captureSpan(self: *Self, io: std.Io, reader: *std.Io.Reader, file_reader: ?*std.Io.File.Reader, offset: u64, length: usize) !Span {
            if (file_reader) |input| {
                assert(&input.interface == reader);
                const position = input.logicalPos();
                const size = try input.getSize();
                if (position > size or length > size - position) return error.InvalidResume;
                if (self.resume_file == null) {
                    const result = std.posix.system.fcntl(input.file.handle, std.posix.F.DUPFD_CLOEXEC, @as(usize, 3));
                    if (std.posix.errno(result) != .SUCCESS) return error.SystemResources;
                    self.resume_file = .{ .handle = @intCast(result), .flags = .{ .nonblocking = false } };
                }
                try input.seekBy(@intCast(length));
                return .{ .source = .handoff, .offset = position, .length = length };
            }
            const file = try self.spool(io);
            var copied: usize = 0;
            while (copied < length) {
                const count = @min(length - copied, self.scratch.len);
                try reader.readSliceAll(self.scratch[0..count]);
                try file.writePositionalAll(self.file_io, self.scratch[0..count], offset + copied);
                copied += count;
            }
            return .{ .offset = offset, .length = length };
        }

        fn spool(self: *Self, io: std.Io) !std.Io.File {
            if (self.spool_file) |file| return file;
            const result = std.os.linux.memfd_create("lightning-rod-session-wire", std.os.linux.MFD.CLOEXEC);
            if (std.os.linux.errno(result) != .SUCCESS) return error.SystemResources;
            const file: std.Io.File = .{ .handle = @intCast(result), .flags = .{ .nonblocking = false } };
            self.spool_file = file;
            self.file_io = io;
            return file;
        }

        fn source(self: *Self, span: Span) std.Io.File {
            return switch (span.source) {
                .handoff => self.resume_file.?,
                .spool => self.spool_file.?,
            };
        }

        fn readSpan(self: *Self, span: *Span, bytes: []u8) !usize {
            const length = @min(bytes.len, span.length);
            const read = try self.source(span.*).readPositionalAll(self.file_io, bytes[0..length], span.offset);
            if (read != length) return error.InvalidResume;
            span.offset += read;
            span.length -= read;
            return read;
        }

        fn writeSpan(self: *Self, writer: *std.Io.Writer, span: Span) !void {
            var remaining = span;
            while (remaining.length != 0) {
                const read = try self.readSpan(&remaining, self.scratch);
                try writer.writeAll(self.scratch[0..read]);
            }
        }

        fn spoolBase(self: *const Self, index: usize) u64 {
            return @as(u64, index) * (self.config.max_pending_wire_bytes + self.config.buffer_bytes);
        }

        fn appendSpool(self: *Self, io: std.Io, index: usize, bytes: []const u8) !void {
            var parts = [_][]const u8{bytes};
            try self.appendSpoolParts(io, index, &parts);
        }

        fn appendSpoolParts(self: *Self, io: std.Io, index: usize, parts: [][]const u8) !void {
            const connection = &self.connections[index];
            assert(connection.spooling);
            const span = &connection.saved_output;
            var length: usize = 0;
            for (parts) |bytes| length += bytes.len;
            if (length > self.config.max_pending_wire_bytes - span.length) return error.ConfigurationTooLarge;
            if (length == 0) return;
            const file = try self.spool(io);
            var part: usize = 0;
            var written: usize = 0;
            while (written < length) {
                while (part < parts.len and parts[part].len == 0) part += 1;
                const count = try file.writePositional(self.file_io, parts[part..], span.offset + span.length + written);
                assert(count > 0 and count <= length - written);
                written += count;
                var remaining = count;
                while (remaining != 0) {
                    const consumed = @min(parts[part].len, remaining);
                    parts[part] = parts[part][consumed..];
                    remaining -= consumed;
                    if (parts[part].len == 0) part += 1;
                }
            }
            assert(written == length);
            span.length += written;
        }

        /// Canceled socket loans must complete before moving their wire buffers.
        pub fn spill(self: *Self, io: std.Io) !void {
            assert(self.reloading);
            for (self.connections, 0..) |*connection, index| {
                if (connection.handle == null or connection.spooling or connection.receiving or connection.sending or connection.loan.load(.acquire)) continue;
                var previous = connection.saved_output;
                connection.saved_output = .{ .offset = self.spoolBase(index) };
                connection.spooling = true;
                if (connection.output_control) {
                    var control_parts: [control_packets_max][]const u8 = undefined;
                    control_parts[0] = connection.output;
                    const remaining = connection.control_write -| (connection.control_read + 1);
                    if (remaining != 0) @memcpy(control_parts[1..][0..remaining], connection.control_packets[connection.control_read + 1 .. connection.control_write]);
                    try self.appendSpoolParts(io, index, control_parts[0 .. 1 + remaining]);
                }
                while (previous.length != 0) {
                    const read = try self.readSpan(&previous, self.scratch);
                    try self.appendSpool(io, index, self.scratch[0..read]);
                }
                // The ring goes after, what it holds not yet encrypted encrypted now, after the
                // control output above, as it would have been sent.
                self.unsealed.remove(index);
                const ring = self.ringBuffer(index);
                const unsealed = connection.output_write -% connection.output_sealed;
                if (unsealed != 0 and Endpoint.encrypted(&connection.lifecycle.?)) {
                    const start = connection.output_sealed % ring.len;
                    const part = @min(unsealed, ring.len - start);
                    Endpoint.send(&connection.lifecycle.?, ring[start..][0..part]);
                    Endpoint.send(&connection.lifecycle.?, ring[0 .. unsealed - part]);
                }
                connection.output_sealed = connection.output_write;
                const queued = connection.output_write -% connection.output_read;
                const at = connection.output_read % ring.len;
                const first = @min(queued, ring.len - at);
                try self.appendSpool(io, index, ring[at..][0..first]);
                try self.appendSpool(io, index, ring[0 .. queued - first]);
                connection.output_read = 0;
                connection.output_sealed = 0;
                connection.output_write = 0;
                connection.output = &.{};
                connection.output_control = false;
                self.releaseControl(index);
            }
        }

        fn removeWait(self: *Self, index: usize) void {
            self.transport_waiting.remove(index);
            const connection = &self.connections[index];
            const kind = connection.waiting orelse return;
            const queue = &self.waiting[@backingInt(kind)];
            assert(queue.count > 0);
            if (connection.wait_previous != absent) self.connections[connection.wait_previous].wait_next = connection.wait_next else {
                assert(queue.head == index);
                queue.head = connection.wait_next;
            }
            if (connection.wait_next != absent) self.connections[connection.wait_next].wait_previous = connection.wait_previous else {
                assert(queue.tail == index);
                queue.tail = connection.wait_previous;
            }
            queue.count -= 1;
            connection.waiting = null;
            connection.wait_previous = absent;
            connection.wait_next = absent;
            assert((queue.count == 0) == (queue.head == absent));
            assert((queue.head == absent) == (queue.tail == absent));
        }

        fn wait(self: *Self, index: usize) void {
            const connection = &self.connections[index];
            const kind = connection.waiting_for;
            if (kind == .external) {
                self.transport_waiting.insert(index);
                return;
            }
            if (connection.waiting == kind) return;
            self.removeWait(index);
            const queue = &self.waiting[@backingInt(kind)];
            connection.waiting = kind;
            connection.wait_previous = queue.tail;
            if (queue.tail != absent) self.connections[queue.tail].wait_next = index else queue.head = index;
            queue.tail = index;
            queue.count += 1;
            assert(queue.count <= self.connections.len and connection.wait_next == absent);
            self.resources_ready = true;
        }

        fn wakeWaiters(self: *Self, kind: Wait, capacity: usize) void {
            const queue = &self.waiting[@backingInt(kind)];
            const count = @min(capacity, queue.count);
            for (0..count) |_| {
                const index = queue.head;
                assert(index != absent and self.connections[index].waiting == kind);
                self.removeWait(index);
                self.connections[index].resource_ready = true;
                self.readiness.signal(index).notify();
            }
        }

        fn wakeResources(self: *Self) void {
            const decoded = self.decoded.takeReleased();
            const input = self.input_bursts.takeReleased();
            const control_released = self.control_raw.takeReleased();
            const configuration = self.configurations.takeReleased();
            if (!(self.resources_ready or decoded or input or control_released or configuration)) return;
            self.resources_ready = false;
            if (self.waiting[@backingInt(Wait.decoded)].count != 0) self.wakeWaiters(.decoded, self.decoded.availableCountWithin(self.decoded.maximum));
            if (self.waiting[@backingInt(Wait.input)].count != 0) self.wakeWaiters(.input, self.input_bursts.availableCountWithin(self.input_bursts.maximum));
            const ControlWaiters = struct { pool: *Buffers, admitted: Wait, other: Wait };
            for ([_]ControlWaiters{
                .{ .pool = &self.control_raw, .admitted = .control_admitted, .other = .control },
                .{ .pool = &self.configurations, .admitted = .configuration_admitted, .other = .configuration },
            }) |waiting| {
                const admitted = &self.waiting[@backingInt(waiting.admitted)];
                const other = &self.waiting[@backingInt(waiting.other)];
                if (admitted.count == 0 and other.count == 0) continue;
                const capacity = waiting.pool.availableCountWithin(waiting.pool.maximum);
                const limit = waiting.pool.maximum - @intFromBool(waiting.pool.maximum > 1);
                const count = @min(admitted.count, capacity, waiting.pool.availableCountWithin(limit));
                self.wakeWaiters(waiting.admitted, count);
                self.wakeWaiters(waiting.other, capacity - count);
            }
        }

        pub fn progress(self: *Self, io: std.Io) void {
            defer {
                inline for (.{ "decoded", "input_bursts", "configurations", "control_raw" }) |name| @field(self, name).publishUsage();
                self.packet_bursts.publishUsage();
                self.control_bursts.publishUsage();
            }
            const now = std.Io.Clock.now(.awake, io).nanoseconds;
            self.poll = .{ .now = now };

            if (self.external_ready) {
                self.external_ready = false;
                for (self.transport_waiting.values()) |index| self.readiness.signal(index).notify();
                self.transport_waiting.clear();
            }
            self.wakeResources();
            var ready = self.readiness.take(now);
            var returned = false;
            for (ready) |index| {
                const connection = &self.connections[index];
                if (!connection.loan.load(.acquire)) {
                    if (connection.decoded) |lease| {
                        lease.release();
                        connection.decode_large = false;
                        returned = true;
                    }
                    connection.decoded = null;
                }
            }
            // Admit waiting peers before the peers that just returned their decode buffers.
            if (returned and self.waiting[@backingInt(Wait.decoded)].count != 0) {
                for (ready) |index| self.readiness.signal(index).notify();
                self.wakeResources();
                ready = self.readiness.take(now);
            }
            var priority: usize = 0;
            const ordered = self.readiness.ready[0..ready.len];
            for (0..ordered.len) |at| if (self.connections[ordered[at]].resource_ready) {
                std.mem.swap(usize, &ordered[priority], &ordered[at]);
                priority += 1;
            };
            var first: usize = 0;
            if (priority == 0) for (ready, 0..) |index, position| {
                if (index < self.progress_cursor) first = position + 1;
            };
            var ready_next = if (first == ready.len) 0 else first;
            var next_cursor: ?usize = null;
            defer if (ready.len != 0) {
                self.progress_cursor = next_cursor orelse ((ready[ready_next] + 1) % self.connections.len);
            };
            for (0..ready.len) |_| {
                const index = ready[ready_next];
                ready_next += 1;
                if (ready_next == ready.len) ready_next = 0;
                const connection = &self.connections[index];
                if (connection.handle == null) continue;
                assert(connection.active);
                if (connection.resource_ready) self.resources_ready = true;
                connection.resource_ready = false;
                self.removeWait(index);
                connection.waiting_for = .external;
                connection.poll.now = now;
                if (connection.poll.deadline) |expires| if (expires <= now) {
                    connection.poll.deadline = null;
                };
                const was_closing = connection.closing;
                defer if (connection.handle != null) {
                    self.readiness.update(index, connection.poll.deadline);
                    if (connection.waiting_for != .external and next_cursor == null) next_cursor = index;
                    if (!was_closing and connection.closing) {
                        self.delivery_ready = true;
                        self.readiness.signal(index).notify();
                    }
                };
                self.verifyLogin(io, index) catch {
                    markClosing(connection, .verification_failed);
                    continue;
                };
                defer if (!connection.loan.load(.acquire)) {
                    if (connection.decoded) |lease| lease.release();
                    connection.decoded = null;
                };
                const handle = connection.handle orelse continue;
                defer if (!connection.sending and connection.output.len == 0) self.releaseControl(index);
                var decode_blocked = false;
                var frame_incomplete = false;
                if (!connection.receiving and !connection.loan.load(.acquire)) {
                    const remaining = connection.input_end - connection.input_start;
                    if (connection.input_burst) |lease| {
                        if (remaining == 0) {
                            lease.release();
                            connection.input_burst = null;
                            connection.input_start = 0;
                            connection.input_end = remaining;
                        }
                    } else if (remaining == 0) {
                        connection.input_start = 0;
                        connection.input_end = 0;
                    }
                }
                // An empty ring starts again at its beginning, so output stays in one piece.
                if (!connection.sending and connection.output.len == 0 and connection.output_write == connection.output_read) {
                    connection.output_read = 0;
                    connection.output_sealed = 0;
                    connection.output_write = 0;
                }
                if (!connection.sending and connection.output.len == 0) self.releaseControl(index);
                if (!self.reloading and connection.output.len == 0 and connection.saved_output.length != 0) {
                    const bytes = connection.control_output.unusedCapacitySlice();
                    const count = self.readSpan(&connection.saved_output, bytes) catch {
                        markClosing(connection, .saved_output_failed);
                        continue;
                    };
                    connection.control_output.items.len = count;
                    connection.output = connection.control_output.items;
                    connection.output_control = true;
                }
                var input = self.inputBuffer(index);

                if (!self.reloading and !connection.closing and connection.state.phase != .play and connection.state.phase != .parked) {
                    if (now >= connection.admission_deadline) markClosing(connection, .admission_timeout) else connection.poll.wakeAt(connection.admission_deadline);
                }

                if (self.reloading and (!connection.attached or connection.disconnect_deadline != null)) markClosing(connection, .reload);

                if (connection.state.phase == .rejected and connection.output.len == 0) markClosing(connection, .rejected);
                const stopping = self.stopping or connection.disconnect_deadline != null;
                if (stopping and !connection.closing) {
                    if (connection.state.phase != .play or now >= (connection.disconnect_deadline orelse self.stop_deadline)) {
                        markClosing(connection, .stopping);
                    } else if (connection.disconnecting) {
                        if (connection.output.len == 0) markClosing(connection, .disconnected);
                    } else if (connection.output.len == 0 and connection.output_read == connection.output_write) {
                        if (!self.reserveControl(index)) {
                            self.wait(index);
                            continue;
                        }
                        const message = if (self.stopping) "Server shutting down" else "Disconnected by server";
                        const response = self.advance(io, connection, .{ .disconnect = message }) catch {
                            markClosing(connection, .disconnect_failed);
                            continue;
                        };
                        const bytes = response orelse {
                            markClosing(connection, .disconnect_failed);
                            continue;
                        };
                        self.queueControl(io, connection, bytes) catch {
                            markClosing(connection, .disconnect_failed);
                            continue;
                        };
                        connection.disconnecting = true;
                    }
                    if (!connection.closing) connection.poll.wakeAt(connection.disconnect_deadline orelse self.stop_deadline);
                }

                if (connection.closing) {
                    if (!connection.closed) self.networking.close(io, handle, .local_close);

                    if (connection.closed and !connection.loan.load(.acquire)) {
                        if (!connection.attached or self.config.observer.detached(io, handle)) {
                            self.config.observer.closed(handle);
                            self.networking.release(io, handle);

                            if (connection.lifecycle) |*lifecycle| Endpoint.clear(lifecycle);
                            self.releaseBuffers(index);
                            self.setHandle(index, null);
                            connection.* = .{ .control_output = connection.control_output };
                        } else self.wait(index);
                    }

                    continue;
                }

                if (self.reloading) continue;

                if (connection.state.phase != .play and !connection.status and connection.state.phase != .handshake and connection.output.len == 0 and !self.reserveControl(index)) {
                    self.wait(index);
                    continue;
                }

                // A lent batch grows by what arrived since, until it comes back.
                if (connection.loan.load(.acquire)) self.growLent(io, index) else connection.growing = null;

                while (!stopping and connection.state.phase != .parked and (connection.state.phase == .play or connection.output.len == 0) and !connection.loan.load(.acquire)) {
                    if (connection.lifecycle != null and connection.output.len == 0 and connection.output_read == connection.output_write) {
                        if (!connection.status and !self.reserveControl(index)) break;
                        const response = self.advance(io, connection, .poll) catch |err| {
                            std.log.warn("event=session_poll_rejected connection={d}:{d} phase={s} reason={s}", .{ handle.index, handle.generation, @tagName(connection.state.phase), @errorName(err) });
                            markClosing(connection, .protocol_rejected);
                            break;
                        };
                        if (response) |bytes| {
                            self.queueControl(io, connection, bytes) catch |err| {
                                std.log.warn("event=session_output_rejected reason={s}", .{@errorName(err)});
                                markClosing(connection, .output_rejected);
                                break;
                            };
                            break;
                        }
                        if (connection.state.phase != .play and !connection.status) self.wait(index);
                    }

                    if (connection.state.phase == .admitting) {
                        assert(!connection.admitted);
                        const maximum = self.config.max_players orelse self.config.connections;
                        assert(self.admitted <= maximum);
                        const duplicate = self.identities.contains(connection.state.uuid);
                        var rejection: ?[]const u8 = if (duplicate) "Player is already connected" else if (self.admitted == maximum) "Server is full" else null;
                        if (rejection == null) {
                            const profile: Profile = .{
                                .connection = handle,
                                .protocol = connection.protocol.?.number,
                                .uuid = connection.state.uuid,
                                .name = connection.state.name[0..connection.state.name_len],
                            };
                            switch (self.config.observer.select(profile)) {
                                .destination => {},
                                .pending => {
                                    self.wait(index);
                                    break;
                                },
                                .reject => rejection = "Unable to route player",
                            }
                        }
                        const response = self.advance(io, connection, .{ .admitted = rejection }) catch {
                            markClosing(connection, .admission_failed);
                            break;
                        };
                        if (rejection == null) self.admit(index);
                        if (response) |bytes| self.queueControl(io, connection, bytes) catch {
                            markClosing(connection, .admission_failed);
                            break;
                        };
                        break;
                    }

                    if (connection.state.phase == .attaching) {
                        if (!self.config.observer.attached(io, .{
                            .connection = handle,
                            .protocol = connection.protocol.?.number,
                            .uuid = connection.state.uuid,
                            .name = connection.state.name[0..connection.state.name_len],
                        })) {
                            self.wait(index);
                            break;
                        }
                        connection.attached = true;
                        _ = self.advance(io, connection, .attached) catch {
                            markClosing(connection, .attach_failed);
                            break;
                        };
                        std.log.info("event=session_play_attached connection={d}:{d} protocol={d} player={s}", .{ handle.index, handle.generation, connection.protocol.?.number, connection.state.name[0..connection.state.name_len] });
                        continue;
                    }

                    const frame = Endpoint.frame(if (connection.lifecycle) |*lifecycle| lifecycle else null, input[connection.input_start..connection.input_end], self.config.max_packet) catch |err| {
                        if (err == error.Incomplete) frame_incomplete = true else markClosing(connection, .invalid_frame);
                        break;
                    };
                    if (frame.body.len == 0 or frame.length > self.config.buffer_bytes or frame.body.len > self.config.max_packet) {
                        std.log.warn("event=session_invalid_frame connection={d}:{d} phase={s} length={d} limit={d}", .{ handle.index, handle.generation, @tagName(connection.state.phase), frame.body.len, self.config.max_packet });
                        markClosing(connection, .invalid_frame);
                        break;
                    }

                    var body = frame.body;
                    const borrowed = connection.lifecycle == null or Endpoint.playBorrowed(&connection.lifecycle.?);
                    const needs_decoded = connection.lifecycle != null and Endpoint.needsDecoded(self.config.compression_threshold) and (!borrowed or Endpoint.compressed(&connection.lifecycle.?));
                    if (connection.state.phase == .play and !connection.decode_large) {
                        if (connection.decoded) |lease| lease.release();
                        connection.decoded = null;
                    }
                    if (needs_decoded and connection.decode_large and connection.decoded == null) {
                        connection.decoded = self.decoded.acquire();
                        if (connection.decoded == null) {
                            connection.waiting_for = .decoded;
                            decode_blocked = true;
                            self.wait(index);
                            break;
                        }
                    }
                    const small = @min(self.config.connection_bytes, self.config.buffer_bytes);
                    const decoded: []u8 = if (connection.decoded) |lease| lease.bytes else self.decoded_storage[index * small ..][0..small];
                    if (connection.lifecycle != null and connection.state.phase != .play) {
                        const result = Decoding.decode(&self.workspaces, .{ .connection = &connection.lifecycle.?, .bytes = body, .output = decoded, .threshold = self.config.compression_threshold }) catch |err| {
                            std.log.warn("event=session_decode_rejected connection={d}:{d} phase={s} reason={s}", .{ handle.index, handle.generation, @tagName(connection.state.phase), @errorName(err) });
                            markClosing(connection, .decode_rejected);
                            break;
                        };
                        if (result.needs_output) {
                            if (connection.decode_large) {
                                markClosing(connection, .decode_too_large);
                                break;
                            }
                            connection.decode_large = true;
                            continue;
                        }
                        body = result.bytes;
                    }

                    if (connection.state.phase == .play) {
                        if (!borrowed) {
                            const result = Decoding.decodeBatch(&self.workspaces, .{ .connection = &connection.lifecycle.?, .bytes = input[connection.input_start..connection.input_end], .output = decoded, .packets = &connection.input_packets, .threshold = self.config.compression_threshold, .maximum = self.config.max_packet }) catch {
                                markClosing(connection, .decode_rejected);
                                break;
                            };
                            if (result.needs_output) {
                                if (connection.decode_large) {
                                    markClosing(connection, .decode_too_large);
                                    break;
                                }
                                connection.decode_large = true;
                                continue;
                            }
                            if (!self.observePlayPackets(io, connection, result.input.?)) {
                                markClosing(connection, .input_rejected);
                                break;
                            }
                            connection.loan.store(true, .release);
                            const disposition = self.config.observer.input(handle, connection.protocol.?.number, result.input.?);
                            if (disposition != .borrowed) connection.loan.store(false, .release);
                            if (disposition == .blocked) {
                                decode_blocked = true;
                                break;
                            }
                            connection.input_start += result.consumed;
                            if (disposition == .borrowed) {
                                connection.growing = self.lentPackets(index, connection, result.input.?.packets);
                                break;
                            }
                            continue;
                        }

                        var batch_end = connection.input_start + frame.length;

                        while (batch_end < connection.input_end) {
                            const next = Endpoint.frame(&connection.lifecycle.?, input[batch_end..connection.input_end], self.config.max_packet) catch |err| {
                                if (err != error.Incomplete) markClosing(connection, .invalid_frame);
                                break;
                            };
                            if (next.body.len == 0 or next.body.len > self.config.max_packet) {
                                markClosing(connection, .invalid_frame);
                                break;
                            }

                            batch_end += next.length;
                        }

                        if (connection.closing) break;
                        if (!self.observePlayPackets(io, connection, .{ .framed = input[connection.input_start..batch_end] })) {
                            markClosing(connection, .input_rejected);
                            break;
                        }

                        connection.loan.store(true, .release);
                        const disposition = self.config.observer.input(handle, connection.protocol.?.number, .{ .framed = input[connection.input_start..batch_end] });

                        if (disposition != .borrowed) connection.loan.store(false, .release);
                        if (disposition == .blocked) {
                            decode_blocked = true;
                            break;
                        }
                        if (disposition == .borrowed) connection.growing = .{ .framed = .{ .start = connection.input_start, .end = batch_end } };
                        connection.input_start = batch_end;
                        if (disposition == .borrowed) break;
                        continue;
                    }

                    const previous = connection.state.phase;
                    const encrypted = connection.lifecycle != null and Endpoint.encrypted(&connection.lifecycle.?);
                    const response = self.advance(io, connection, .{ .packet = body }) catch |err| {
                        std.log.warn("event=session_packet_rejected connection={d}:{d} phase={s} bytes={d} reason={s}", .{ handle.index, handle.generation, @tagName(connection.state.phase), body.len, @errorName(err) });
                        markClosing(connection, .packet_rejected);
                        break;
                    };

                    if (connection.state.phase != previous)
                        std.log.debug("event=session_phase connection={d}:{d} previous={s} next={s}", .{ handle.index, handle.generation, @tagName(previous), @tagName(connection.state.phase) });
                    connection.input_start += frame.length;

                    if (!encrypted and Endpoint.encrypted(&connection.lifecycle.?)) {
                        std.log.info("event=session_encrypted connection={d}:{d}", .{ handle.index, handle.generation });
                        const tail = input[connection.input_start..connection.input_end];
                        Endpoint.receive(&connection.lifecycle.?, tail);
                    }

                    if (response) |bytes| {
                        self.queueControl(io, connection, bytes) catch |err| {
                            std.log.warn("event=session_output_rejected reason={s}", .{@errorName(err)});
                            markClosing(connection, .output_rejected);
                            break;
                        };
                    }
                    if (connection.verification != null) break;
                }

                // Verification runs at the connection's next turn.
                if (connection.verification != null) {
                    self.readiness.signal(index).notify();
                    self.sendOutput(io, index);
                    continue;
                }
                if (connection.closing) {
                    self.networking.close(io, handle, .io_failure);
                    continue;
                }

                self.sendOutput(io, index);
                if (connection.closing) continue;

                if (decode_blocked) self.wait(index);
                // While a batch that can still grow is lent, input is received after it, so the batch
                // can grow, but nothing moves, as the batch points into the buffer: with no room
                // left, receiving waits for the batch to come back.
                const lent = connection.loan.load(.acquire);
                if (decode_blocked or stopping or connection.state.phase == .parked or connection.receiving or (lent and !canGrow(connection))) continue;
                if (lent and connection.input_end == input.len) continue;

                if (connection.input_start == connection.input_end and !lent) {
                    connection.input_start = 0;
                    connection.input_end = 0;
                }
                if (connection.input_end == input.len and !frame_incomplete) continue;
                // Contiguous packet decoders require coalescing a frame split across receive buffers.
                if (connection.input_start != 0 and connection.input_end == input.len) {
                    std.mem.copyForwards(u8, input, input[connection.input_start..connection.input_end]);
                    connection.input_end -= connection.input_start;
                    connection.input_start = 0;
                }

                if (connection.input_end == input.len) {
                    if (connection.input_burst != null) {
                        markClosing(connection, .input_overflow);
                        continue;
                    }
                    const lease = self.input_bursts.acquire() orelse {
                        connection.waiting_for = .input;
                        self.wait(index);
                        continue;
                    };
                    @memcpy(lease.bytes[0..connection.input_end], input[0..connection.input_end]);
                    connection.input_burst = lease;
                    input = lease.bytes;
                }

                if (connection.saved_input.length != 0) {
                    const count = self.readSpan(&connection.saved_input, input[connection.input_end..]) catch {
                        markClosing(connection, .saved_input_failed);
                        continue;
                    };
                    connection.input_end += count;
                    self.readiness.signal(index).notify();
                    continue;
                }

                self.networking.queueReceive(io, handle, input[connection.input_end..]) catch |err| switch (err) {
                    error.Full => {
                        self.wait(index);
                        continue;
                    },
                    else => {
                        markClosing(connection, .transport_failed);
                        continue;
                    },
                };
                connection.receiving = true;
            }
            self.wakeResources();
            self.poll.deadline = self.readiness.deadline(now);
            if (self.resume_file != null and !self.reloading) {
                var held = false;
                for (self.connections) |connection| held = held or (connection.saved_input.source == .handoff and connection.saved_input.length != 0) or (connection.saved_output.source == .handoff and connection.saved_output.length != 0);
                if (!held) {
                    self.resume_file.?.close(self.file_io);
                    self.resume_file = null;
                }
            }
            if (self.spool_file != null and !self.reloading) {
                var held = false;
                for (self.connections) |connection| held = held or (connection.saved_input.source == .spool and connection.saved_input.length != 0) or (connection.saved_output.source == .spool and connection.saved_output.length != 0);
                if (!held) {
                    self.spool_file.?.close(self.file_io);
                    self.spool_file = null;
                }
            }
        }

        fn rawControl(self: *Self, connection: *Connection) []u8 {
            if (connection.control_raw) |lease| return lease.bytes[connection.control_used..];
            if (connection.status) {
                const index = connection.handle.?.index;
                return self.control_storage[@as(usize, index) * self.smallBytes() ..][0..self.smallBytes()];
            }
            return self.scratch;
        }

        fn recordControl(self: *Self, connection: *Connection, bytes: []const u8) !void {
            if (bytes.len == 0) return;
            if (connection.control_write == control_packets_max or bytes.len > self.config.max_pending_wire_bytes - 2 * control_bytes_max - connection.control_wire) return error.ConfigurationTooLarge;
            connection.control_wire += bytes.len;
            const raw = self.rawControl(connection);
            const address = @intFromPtr(bytes.ptr);
            if (address >= @intFromPtr(raw.ptr) and address + bytes.len <= @intFromPtr(raw.ptr) + raw.len) {
                connection.control_used += address - @intFromPtr(raw.ptr) + bytes.len;
            } else {
                const base = @intFromPtr(connection.control_output.items.ptr);
                if (address >= base and address + bytes.len <= base + connection.control_output.capacity) {
                    assert(address >= base + connection.control_output.items.len);
                    connection.control_output.items.len = address - base + bytes.len;
                }
            }
            connection.control_packets[connection.control_write] = bytes;
            connection.control_write += 1;
        }

        fn appendControl(self: *Self, connection: *Connection, packet: []const u8, maximum: usize) !void {
            const bound = connection.protocol.?.frame_bound.bytes(packet.len);
            if (connection.control_output.items.len > maximum or bound > maximum - connection.control_output.items.len) return error.ConfigurationTooLarge;
            if (bound > connection.control_output.unusedCapacitySlice().len) return error.ConfigurationTooLarge;
            const destination = connection.control_output.unusedCapacitySlice()[0..bound];
            const result = try self.control(connection, self.controlPacket(connection, packet), destination);
            try self.recordControl(connection, result.first);
            try self.recordControl(connection, result.second);
        }

        fn publishControl(self: *Self, io: std.Io, connection: *Connection) !void {
            if (connection.spooling) {
                try self.appendSpoolParts(io, connection.handle.?.index, connection.control_packets[0..connection.control_write]);
                connection.control_write = 0;
                connection.control_read = 0;
                connection.control_used = 0;
                connection.control_wire = 0;
                connection.control_output.clearRetainingCapacity();
            } else if (connection.control_write != 0) {
                connection.output = connection.control_packets[0];
                connection.output_control = true;
            }
        }

        fn queueControl(self: *Self, io: std.Io, connection: *Connection, packet: []const u8) !void {
            assert(!connection.sending and connection.output.len == 0);
            connection.control_output.clearRetainingCapacity();
            connection.control_read = 0;
            connection.control_write = 0;
            connection.control_wire = 0;
            try self.appendControl(connection, packet, self.config.max_pending_wire_bytes - 2 * control_bytes_max);
            try self.buildControl(io, connection);
        }

        fn buildControl(self: *Self, io: std.Io, connection: *Connection) !void {
            connection.control_more = connection.state.phase == .negotiating;
            while (connection.control_more) {
                const encrypted = if (connection.lifecycle) |*lifecycle| Endpoint.encrypted(lifecycle) else false;
                const next = try self.advance(io, connection, .poll);
                assert(encrypted == (if (connection.lifecycle) |*lifecycle| Endpoint.encrypted(lifecycle) else false));
                const packet = next orelse {
                    connection.control_more = false;
                    break;
                };
                try self.appendControl(connection, packet, self.config.max_pending_wire_bytes - 2 * control_bytes_max);
                connection.control_more = connection.state.phase == .negotiating;
            }
            try self.publishControl(io, connection);
        }

        fn controlPacket(self: *Self, connection: *Connection, bytes: []const u8) protocol_api.Packet {
            const storage = self.rawControl(connection);
            return if (bytes.ptr == storage[framing.headroom..].ptr)
                .{ .buffered = .{ .storage = storage, .length = bytes.len } }
            else
                .{ .borrowed = bytes };
        }

        fn control(self: *Self, connection: *Connection, packet: protocol_api.Packet, destination: []u8) !protocol_api.Fragments {
            if (connection.lifecycle) |*lifecycle|
                return Endpoint.control(lifecycle, &self.workspaces, packet, destination, if (Endpoint.compressed(lifecycle)) self.config.compression_threshold else null);
            return Endpoint.Bootstrap.control(packet, destination);
        }

        /// Login verification, on the sessions thread when the connection's turn comes. What
        /// arrived after the encryption response is decrypted once the key is in.
        fn verifyLogin(self: *Self, io: std.Io, index: usize) !void {
            const connection = &self.connections[index];
            const verification = connection.verification orelse return;
            connection.verification = null;
            var secret = try verification.run();
            defer std.crypto.secureZero(u8, &secret);
            _ = try self.advance(io, connection, .{ .verified = secret });
            Endpoint.receive(&connection.lifecycle.?, self.inputBuffer(index)[connection.input_start..connection.input_end]);
        }

        fn advance(self: *Self, io: std.Io, connection: *Connection, event: protocol_api.Event) !?[]const u8 {
            const phase = connection.state.phase;
            defer if (phase != connection.state.phase) {
                self.delivery_ready = true;
            };
            if (connection.state.phase == .handshake) {
                if (event != .packet) return error.InvalidProtocolEvent;
                const handshake = try self.config.observer.handshake(event.packet);
                connection.status = handshake.intent == .status;
                if (handshake.intent == .status) {
                    connection.protocol = &self.config.protocols.values[0];
                    for (&self.config.protocols.values) |*selected| {
                        if (selected.number == handshake.protocol) {
                            connection.protocol = selected;
                            break;
                        }
                        if (selected.number > connection.protocol.?.number) connection.protocol = selected;
                    }
                } else {
                    for (&self.config.protocols.values) |*selected| if (selected.number == handshake.protocol) {
                        connection.protocol = selected;
                        break;
                    };
                    if (connection.protocol == null) return error.UnsupportedProtocol;
                }
                connection.lifecycle = try Endpoint.init(connection.protocol.?.number, handshake.intent);
                connection.state.phase = .negotiating;
                return null;
            }
            const storage = self.rawControl(connection);
            if (storage.len < framing.headroom) return error.ConfigurationTooLarge;
            const context: protocol_api.Context(Observer) = .{
                .connection = connection.handle.?,
                .state = &connection.state,
                .protocol = connection.protocol.?,
                .output = storage[framing.headroom..],
                .io = io,
                .now = std.Io.Clock.now(.awake, io).nanoseconds,
                .poll = &connection.poll,
                .reloading = self.reloading,
                .compression_threshold = self.config.compression_threshold,
                .observer = self.config.observer,
                .verification = &connection.verification,
            };
            return Endpoint.advance(Observer, &connection.lifecycle.?, event, context);
        }

        fn observePlayPackets(self: *Self, io: std.Io, connection: *Connection, packets: protocol_api.Packets) bool {
            var incoming = packets;
            while (incoming.next() catch return false) |packet| {
                const response = self.advance(io, connection, .{ .packet = packet }) catch return false;
                if (response != null) return false;
            }
            return true;
        }

        fn extendLent(self: *Self, handle: network.Handle, packets: protocol_api.Packets) bool {
            if (comptime @hasDecl(Observer, "extend")) return self.config.observer.extend(handle, packets);
            return false;
        }

        fn decodedBuffer(self: *Self, index: usize, connection: *const Connection) []u8 {
            const small = @min(self.config.connection_bytes, self.config.buffer_bytes);
            return if (connection.decoded) |lease| lease.bytes else self.decoded_storage[index * small ..][0..small];
        }

        /// What a lent batch of decoded packets holds: those first of `input_packets`, and the
        /// decoded buffer up to the end of the last it decompressed there. Packets sent
        /// uncompressed lie in the input buffer instead.
        fn lentPackets(self: *Self, index: usize, connection: *const Connection, packets: []const []const u8) Lent {
            assert(packets.ptr == @as([*]const []const u8, &connection.input_packets));
            const decoded = self.decodedBuffer(index, connection);
            const base = @intFromPtr(decoded.ptr);
            var end: usize = 0;
            for (packets) |packet| {
                const at = @intFromPtr(packet.ptr);
                if (at >= base and at < base + decoded.len) end = @max(end, at - base + packet.len);
            }
            return .{ .packets = .{ .count = packets.len, .decoded = end } };
        }

        /// Adds input received while a batch is lent to that batch, if no tick took it yet, so the
        /// input runs in the next tick rather than the one after the batch comes back. The batch
        /// grows in place, after what it holds, so nothing it holds moves. Session plugins see the
        /// added packets only once the batch holds them, and if a tick took the batch first, the
        /// packets are decoded again once it comes back, so none is handled twice.
        fn growLent(self: *Self, io: std.Io, index: usize) void {
            const connection = &self.connections[index];
            if (!canGrow(connection)) return;
            const lent = connection.growing.?;
            if (connection.closing or connection.state.phase != .play or connection.lifecycle == null or connection.input_start >= connection.input_end) return;
            const handle = connection.handle orelse return;
            const input = self.inputBuffer(index);
            // Nothing is decoded for a batch a tick already took.
            const current: protocol_api.Packets = switch (lent) {
                .packets => |packets| .{ .packets = connection.input_packets[0..packets.count] },
                .framed => |framed| .{ .framed = input[framed.start..framed.end] },
            };
            if (!self.extendLent(handle, current)) {
                connection.growing = null;
                return;
            }
            switch (lent) {
                .packets => |held| {
                    if (held.count == connection.input_packets.len) return;
                    const decoded = self.decodedBuffer(index, connection);
                    const result = Decoding.decodeBatch(&self.workspaces, .{
                        .connection = &connection.lifecycle.?,
                        .bytes = input[connection.input_start..connection.input_end],
                        .output = decoded[held.decoded..],
                        .packets = connection.input_packets[held.count..],
                        .threshold = self.config.compression_threshold,
                        .maximum = self.config.max_packet,
                    }) catch {
                        // Left for the batch after this one, which rejects it.
                        connection.growing = null;
                        return;
                    };
                    if (result.needs_output) {
                        connection.growing = null;
                        return;
                    }
                    const added = (result.input orelse return).packets;
                    if (added.len == 0) return;
                    const grown = connection.input_packets[0 .. held.count + added.len];
                    if (!self.extendLent(handle, .{ .packets = grown })) {
                        connection.growing = null;
                        return;
                    }
                    connection.input_start += result.consumed;
                    connection.growing = self.lentPackets(index, connection, grown);
                    if (!self.observePlayPackets(io, connection, .{ .packets = added })) markClosing(connection, .input_rejected);
                },
                .framed => |held| {
                    assert(held.end == connection.input_start);
                    var end = connection.input_start;
                    while (end < connection.input_end) {
                        const next = Endpoint.frame(&connection.lifecycle.?, input[end..connection.input_end], self.config.max_packet) catch break;
                        if (next.body.len == 0 or next.body.len > self.config.max_packet) break;
                        end += next.length;
                    }
                    if (end == connection.input_start) return;
                    if (!self.extendLent(handle, .{ .framed = input[held.start..end] })) {
                        connection.growing = null;
                        return;
                    }
                    const added = input[connection.input_start..end];
                    connection.input_start = end;
                    connection.growing = .{ .framed = .{ .start = held.start, .end = end } };
                    if (!self.observePlayPackets(io, connection, .{ .framed = added })) markClosing(connection, .input_rejected);
                },
            }
        }
    };
}
