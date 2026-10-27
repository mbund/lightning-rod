const metrics = @import("metrics");
const std = @import("std");
const network = @import("networking");
const protocol_api = @import("protocol.zig");
const framing = @import("shared.zig");
const Buffers = @import("buffers.zig").Buffers;
const system = @import("system");
const packet_codec = @import("codec.zig");
const packet_output = @import("output.zig");
const Readiness = @import("readiness.zig").Readiness;

const assert = std.debug.assert;

pub const Instrumentation = struct {
    poll: metrics.Timer = .{},
    sent_bytes: metrics.Counter = .{},

    pub fn init(registry: ?*metrics.Registry, namespace: []const u8) !Instrumentation {
        const owner = registry orelse return .{};
        return .{
            .poll = try owner.timer(.{ .namespace = namespace, .name = "poll", .description = "Poll transport events" }),
            .sent_bytes = try owner.counter(.{ .namespace = namespace, .name = "sent_bytes", .description = "Bytes sent through transport", .unit = .bytes }),
        };
    }
};

pub const Protocol = protocol_api.Protocol;

pub const Profile = protocol_api.Profile;

pub const Disposition = enum { consumed, borrowed, blocked };

pub fn Engine(comptime Endpoint: type, comptime Observer: type) type {
    return struct {
        const Self = @This();
        pub const Codec = packet_codec.Codec(Endpoint);
        pub const Configuration = struct {
            connections: usize,
            max_players: ?usize = null,
            buffer_bytes: usize = 128 * 1024,
            connection_bytes: usize = 8 * 1024,
            input_burst_slots: usize = 8,
            output_burst_slots: usize = 8,
            configuration_slots: usize = 8,
            decode_slots: usize = 8,
            max_packet: usize = 128 * 1024 - 3,
            max_pending_wire_bytes: usize = 4 * 1024 * 1024,
            protocols: *const Endpoint.Protocols,
            observer: *Observer,
            compression_threshold: ?usize = null,
            metrics: ?*metrics.Registry = null,
        };

        pub const endpoint = Endpoint;
        pub const Loan = packet_output.Loan;
        const control_bytes_max = 256;
        const output_loans_max = network.send_vectors_max;
        const control_packets_max = Codec.control_batch_max * 2;
        const SendLoan = struct { owner: *Loan, prefix: []const u8, bytes: []const u8 };
        const Span = struct {
            source: enum { handoff, spool } = .spool,
            offset: u64 = 0,
            length: usize = 0,
        };
        const ActiveGroup = struct {
            source: usize,
            first: framing.PageId,
            generation: u64,
            next: u8 = 0,
            count: u8,
        };
        const absent = std.math.maxInt(usize);
        const Wait = enum { external, control, configuration, configuration_admitted, decoded, input };
        const Waiters = struct { head: usize = absent, tail: usize = absent, count: usize = 0 };
        const Connection = struct {
            handle: ?network.Handle = null,
            group: ?ActiveGroup = null,
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
            output_burst: ?Buffers.Lease = null,
            control_burst: ?Buffers.Lease = null,
            control_raw: ?Buffers.Lease = null,
            control_used: usize = 0,
            control_count: usize = 0,
            control_raw_start: usize = 0,
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
            output_read: usize = 0,
            output_write: usize = 0,
            active_previous: ?usize = null,
            active_next: ?usize = null,
            active: bool = false,
            closing: bool = false,
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
            // A queued task owns the codec and its borrowed slices until completion.
            codec: Codec.Task = .{},
            verification: ?protocol_api.LoginVerification = null,
            received: usize = 0,
            receive_tail: usize = 0,
            control_building: bool = false,
            decoded_result: ?Codec.Result = null,
            input_packets: [128][]const u8 = undefined,
            send_loan: ?*Loan = null,
            output_loans: [output_loans_max]SendLoan = undefined,
            loan_read: usize = 0,
            loan_write: usize = 0,
        };

        allocator: std.mem.Allocator,
        networking: network.Transport,
        config: Configuration,
        connections: []Connection,
        input: []align(64) u8,
        output: []align(64) u8,
        events: []network.Event,
        workspaces: Endpoint.Workspaces,
        decoded: Buffers,
        input_bursts: Buffers,
        output_bursts: Buffers,
        configurations: Buffers,
        control_raw: Buffers,
        scratch: []align(64) u8,
        control_storage: []u8,
        control_jobs: []Codec.Control = &.{},
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
        // Transport and protocol progress invalidate blocked Play delivery attempts.
        delivery_ready: bool = true,
        active_head: ?usize = null,
        active_tail: ?usize = null,
        active_count: usize = 0,
        output_pressure: bool = false,
        codec: ?*Codec = null,

        pub fn init(allocator: std.mem.Allocator, networking: network.Transport, config: Configuration) !*Self {
            if (config.protocols.values.len == 0 or config.decode_slots == 0 or config.connection_bytes < 512 or config.input_burst_slots == 0 or config.output_burst_slots == 0 or config.configuration_slots == 0) return error.InvalidConfiguration;
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
            const input = try allocator.alignedAlloc(u8, .@"64", bytes);
            errdefer allocator.free(input);
            const output = try allocator.alignedAlloc(u8, .@"64", bytes);
            errdefer allocator.free(output);
            const events = try allocator.alloc(network.Event, config.connections * 3);
            errdefer allocator.free(events);
            var decoded = try Buffers.init(allocator, if (Endpoint.needsDecoded(config.compression_threshold)) @min(config.decode_slots, config.connections) else 0, config.buffer_bytes);
            errdefer decoded.deinit(allocator);
            var input_bursts = try Buffers.init(allocator, if (small == config.buffer_bytes) 0 else @min(config.input_burst_slots, config.connections), config.buffer_bytes);
            errdefer input_bursts.deinit(allocator);
            var output_bursts = try Buffers.init(allocator, if (small == config.buffer_bytes) 0 else @min(config.output_burst_slots, config.connections), config.buffer_bytes);
            errdefer output_bursts.deinit(allocator);
            var configurations = try Buffers.init(allocator, @min(config.configuration_slots, config.connections), config.max_pending_wire_bytes);
            errdefer configurations.deinit(allocator);
            var control_raw = try Buffers.init(allocator, @min(config.configuration_slots, config.connections), config.max_pending_wire_bytes);
            errdefer control_raw.deinit(allocator);
            const scratch = try allocator.alignedAlloc(u8, .@"64", config.buffer_bytes);
            errdefer allocator.free(scratch);
            const control_storage = try allocator.alloc(u8, try std.math.mul(usize, config.connections, small));
            errdefer allocator.free(control_storage);

            for (connections, 0..) |*connection, index| connection.* = .{ .control_output = .{ .items = control_storage[index * small ..][0..0], .capacity = small } };

            self.* = .{
                .allocator = allocator,
                .networking = networking,
                .config = config,
                .connections = connections,
                .identities = identities,
                .readiness = readiness,
                .input = input,
                .transport_waiting = transport_waiting,
                .output = output,
                .events = events,
                .workspaces = try Endpoint.initWorkspaces(allocator),
                .decoded = decoded,
                .input_bursts = input_bursts,
                .output_bursts = output_bursts,
                .configurations = configurations,
                .control_raw = control_raw,
                .scratch = scratch,
                .control_storage = control_storage,
                .instruments = instrumentation,
            };
            return self;
        }

        pub fn attachCodec(self: *Self, codec: *Codec) !void {
            assert(self.codec == null and self.control_jobs.len == 0);
            self.control_jobs = try self.allocator.alloc(Codec.Control, self.configurations.slots.len * Codec.control_batch_max);
            self.codec = codec;
        }

        pub fn deinit(self: *Self) void {
            assert(self.drained());
            for (self.waiting) |queue| assert(queue.count == 0 and queue.head == absent and queue.tail == absent);
            assert(self.transport_waiting.count == 0);
            assert(self.admitted == 0 and self.identities.count() == 0);

            self.transport_waiting.deinit(self.allocator);
            self.identities.deinit(self.allocator);
            Endpoint.deinitWorkspaces(&self.workspaces);
            self.allocator.free(self.scratch);
            self.decoded.deinit(self.allocator);
            self.input_bursts.deinit(self.allocator);
            self.output_bursts.deinit(self.allocator);
            self.configurations.deinit(self.allocator);
            self.control_raw.deinit(self.allocator);
            if (self.resume_file) |file| file.close(self.file_io);
            if (self.spool_file) |file| file.close(self.file_io);
            self.allocator.free(self.events);
            self.allocator.free(self.output);
            self.allocator.free(self.input);
            self.allocator.free(self.control_storage);
            self.allocator.free(self.control_jobs);
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
                connection.codec.signal = self.readiness.signal(index);
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
                if (connection.closing or connection.receiving or connection.sending or connection.loan.load(.acquire) or connection.codec.state.load(.acquire) != .idle or connection.control_building or connection.received != 0 or connection.receive_tail != 0 or connection.group != null) {
                    ready = false;
                    continue;
                }
                if (connection.parked) continue;
                connection.decoded_result = null;
                if (connection.decoded) |lease| lease.release();
                connection.decoded = null;
                if (!self.reserveControl(index)) {
                    ready = false;
                    continue;
                }
                self.readiness.signal(index).notify();
                if (try self.advance(io, connection, .park)) |packet| {
                    try self.queueControl(io, connection, packet);
                    if (connection.control_building) {
                        ready = false;
                        continue;
                    }
                }
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
                    connection.closing = true;
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
                assert(connection.group == null);
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
                var loan_index = connection.loan_read;
                while (loan_index != connection.loan_write) : (loan_index +%= 1) {
                    const loan = connection.output_loans[loan_index % output_loans_max];
                    try writer.writeAll(loan.prefix);
                    try writer.writeAll(loan.bytes);
                }
                const ring = self.ringBuffer(index);
                const queued = if (connection.loan_read == connection.loan_write) connection.output_write -% connection.output_read else 0;
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
            if (self.connections[handle.index].codec.state.load(.acquire) != .idle or self.connections[handle.index].received != 0 or self.connections[handle.index].receive_tail != 0 or self.connections[handle.index].decoded_result != null) return false;
            const connection = &self.connections[handle.index];
            assert(connection.handle != null and std.meta.eql(connection.handle.?, handle));
            assert(connection.state.phase == .play and connection.attached);
            if (connection.closing or connection.disconnect_deadline != null or self.stopping or connection.group != null) return false;
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

        pub const SendOptions = struct { sockets: ?*packet_output.SocketBudget = null };

        pub fn canSendFramed(self: *Self, handle: network.Handle, length: usize, options: SendOptions) bool {
            const connection = &self.connections[handle.index];
            if (connection.codec.state.load(.acquire) != .idle or connection.received != 0) return false;
            const used = connection.output_write -% connection.output_read;
            if (length > self.config.buffer_bytes - used) return false;
            if (!Endpoint.encrypted(&connection.lifecycle.?)) {
                const borrowed = connection.loan_read != connection.loan_write;
                if (options.sockets) |budget| if (budget.available() and (used == 0 or borrowed)) return connection.loan_write -% connection.loan_read < output_loans_max;
                if (borrowed) return false;
            }
            const buffer = self.ringBuffer(handle.index);
            if (self.output_pressure and connection.output_burst != null and used >= self.smallBytes()) return false;
            return length <= buffer.len - used or (used == 0 and !connection.sending and !connection.output_control and self.output_bursts.available());
        }

        /// Full leaves the packet unconsumed so its shared reservation can be retried.
        pub fn sendFramed(self: *Self, io: std.Io, handle: network.Handle, loan: *Loan, options: SendOptions) !void {
            const packet = loan.fragments();
            const length = packet.length();
            assert(loan.references > 0);
            if (length == 0) return error.InvalidPacket;
            if (handle.index >= self.connections.len) return error.Closed;

            const connection = &self.connections[handle.index];
            if (connection.handle == null or !std.meta.eql(connection.handle.?, handle) or connection.closing or ((self.stopping or connection.disconnect_deadline != null) and connection.group == null) or connection.state.phase != .play)
                return error.Closed;
            if (connection.codec.state.load(.acquire) != .idle or connection.received != 0) return error.Full;

            defer self.readiness.signal(handle.index).notify();
            const used = connection.output_write -% connection.output_read;
            assert(used <= self.config.buffer_bytes and length <= self.config.buffer_bytes - used);
            const encrypted = Endpoint.encrypted(&connection.lifecycle.?);
            if (!encrypted) {
                if (connection.spooling) return self.appendSpoolFragments(io, handle.index, packet);
                const borrowed = connection.loan_read != connection.loan_write;
                if (options.sockets) |budget| if ((used == 0 or borrowed) and connection.loan_write -% connection.loan_read < output_loans_max and loan.retainSocket(budget)) {
                    assert(loan.sockets > 0 and loan.budget == budget);
                    assert(budget.used <= budget.capacity);
                    connection.output_loans[connection.loan_write % output_loans_max] = .{ .owner = loan, .prefix = packet.prefix, .bytes = packet.payload };
                    connection.loan_write +%= 1;
                    connection.output_write +%= length;
                    return;
                };
                if (borrowed) return error.Full;
            }
            const target = try self.encryptedDestination(handle.index, length);
            if (!encrypted) {
                packet.copyTo(target.first, target.second);
                connection.output_write +%= length;
                return;
            }

            if (self.codec) |codec| {
                loan.retain();
                connection.send_loan = loan;
                codec.submit(&connection.codec, .{ .send = .{ .connection = target.connection, .prefix = packet.prefix, .source = packet.payload, .first = target.first, .second = target.second } });
                return;
            }
            Codec.encrypt(target.connection, packet.prefix, packet.payload, target.first, target.second);
            if (connection.spooling) {
                try self.appendSpoolFragments(io, handle.index, .{ .prefix = target.first, .payload = target.second });
            } else connection.output_write +%= length;
        }

        pub fn groupReady(self: *Self, handle: network.Handle, origin: usize, group: framing.Group) bool {
            assert(group.count > 0 and group.index < group.count);
            assert(group.count == 1 or group.protocol != null);
            const connection = &self.connections[handle.index];
            if (group.protocol) |number| assert(connection.protocol.?.number == number);
            if (connection.group) |active| {
                return group.count > 1 and active.source == origin and active.first == group.first and
                    active.generation == group.generation and active.count == group.count and active.next == group.index;
            }
            return group.index == 0;
        }

        pub fn discardGroup(self: *Self, handle: network.Handle) bool {
            const connection = &self.connections[handle.index];
            return connection.closing or ((self.stopping or connection.disconnect_deadline != null) and connection.group == null);
        }

        pub fn reserveGroupOutput(self: *Self, handle: network.Handle, group: framing.Group) error{Full}!void {
            const connection = &self.connections[handle.index];
            if (group.count == 1 or connection.group != null or !Endpoint.encrypted(&connection.lifecycle.?)) return;
            assert(group.index == 0 and group.bytes <= self.config.buffer_bytes);
            try self.reserveOutput(handle, group.bytes);
        }

        pub fn reserveOutput(self: *Self, handle: network.Handle, bytes: usize) error{Full}!void {
            const connection = &self.connections[handle.index];
            assert(bytes > 0 and bytes <= self.config.buffer_bytes);
            assert(connection.codec.state.load(.acquire) == .idle);
            const buffer = self.ringBuffer(handle.index);
            const used = connection.output_write -% connection.output_read;
            if (bytes <= buffer.len - used) return;
            if (used != 0 or connection.sending or connection.output_control) return error.Full;
            assert(connection.output_burst == null);
            connection.output_burst = self.output_bursts.acquire() orelse return error.Full;
            connection.output_read = 0;
            connection.output_write = 0;
            connection.output = &.{};
        }

        pub fn claimGroup(self: *Self, handle: network.Handle, origin: usize, group: framing.Group) void {
            assert(self.groupReady(handle, origin, group));
            if (group.count == 1) return;
            const connection = &self.connections[handle.index];
            if (connection.group == null) connection.group = .{ .source = origin, .first = group.first, .generation = group.generation, .count = group.count };
        }

        pub fn completeGroupPacket(self: *Self, handle: network.Handle, origin: usize, group: framing.Group) void {
            assert(self.groupReady(handle, origin, group));
            if (group.count == 1) return;
            const connection = &self.connections[handle.index];
            const active = &connection.group.?;
            active.next += 1;
            self.delivery_ready = true;
            if (active.next == active.count) {
                connection.group = null;
                self.readiness.signal(handle.index).notify();
            }
        }

        pub fn prepareSend(self: *Self, handle: network.Handle) !Codec.SendTarget {
            if (handle.index >= self.connections.len) return error.Closed;
            const connection = &self.connections[handle.index];
            if (connection.handle == null or !std.meta.eql(connection.handle.?, handle) or connection.closing or ((self.stopping or connection.disconnect_deadline != null) and connection.group == null) or connection.state.phase != .play) return error.Closed;
            if (connection.codec.state.load(.acquire) != .idle or connection.received != 0) return error.Full;
            assert(self.codec != null and Endpoint.encrypted(&connection.lifecycle.?));
            const buffer = self.ringBuffer(handle.index);
            const used = connection.output_write -% connection.output_read;
            assert(used <= buffer.len);
            connection.codec.state.store(.queued, .release);
            return .{
                .task = &connection.codec,
                .connection = &connection.lifecycle.?,
                .bytes = buffer,
                .used = used,
                .offset = connection.output_write % buffer.len,
                .overflow = if (used == 0 and !connection.sending and !connection.output_control and connection.output_burst == null) &self.output_bursts else null,
            };
        }

        const SendBuffers = struct { connection: *Endpoint.Connection, first: []u8, second: []u8 };

        fn encryptedDestination(self: *Self, index: usize, length: usize) !SendBuffers {
            const connection = &self.connections[index];
            const used = connection.output_write -% connection.output_read;
            assert(used <= self.config.buffer_bytes and length <= self.config.buffer_bytes - used);
            if (self.output_pressure and connection.output_burst != null and used >= self.smallBytes()) return error.Full;
            var buffer = self.ringBuffer(index);
            if (length > buffer.len - used) {
                if (used != 0 or connection.sending or connection.output_control) return error.Full;
                const lease = self.output_bursts.acquire() orelse {
                    self.output_pressure = true;
                    return error.Full;
                };
                assert(connection.output_burst == null);
                connection.output_burst = lease;
                connection.output_read = 0;
                connection.output_write = 0;
                connection.output = &.{};
                buffer = self.ringBuffer(index);
            }
            const start = connection.output_write % buffer.len;
            const first = @min(length, buffer.len - start);
            return .{ .connection = &connection.lifecycle.?, .first = buffer[start..][0..first], .second = buffer[0 .. length - first] };
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
                        .control_output = .{ .items = connection.control_output.items.ptr[0..0], .capacity = self.smallBytes() },
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

                            if (!result.result.more and result.result.errno == @intFromEnum(std.posix.E.NOBUFS)) continue;
                            if (self.reloading and result.result.errno == @intFromEnum(std.posix.E.CANCELED)) continue;
                            if (result.result.errno != null or result.result.bytes == 0 or result.result.bytes > self.inputBuffer(handle.index).len - connection.input_end - connection.received) {
                                connection.closing = true;
                            } else {
                                if (self.codec != null and connection.lifecycle != null and Endpoint.encrypted(&connection.lifecycle.?)) {
                                    connection.received += result.result.bytes;
                                    continue;
                                }
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

                            if (self.reloading and result.result.errno == @intFromEnum(std.posix.E.CANCELED)) continue;
                            if (result.result.errno != null or result.result.bytes == 0 or result.result.bytes > connection.sending_bytes) {
                                connection.closing = true;
                            } else {
                                assert(result.result.bytes > 0 and result.result.bytes <= connection.sending_bytes);
                                self.instruments.sent_bytes.add(result.result.bytes);
                                self.sent(io, handle, result.result.bytes);
                            }
                        },
                        .closed => {
                            assert(!connection.receiving and !connection.sending);
                            connection.closed = true;
                            connection.closing = true;
                            std.log.info("event=session_closed connection={d}:{d} phase={s}", .{ handle.index, handle.generation, @tagName(connection.state.phase) });
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
                const queued = connection.output_write -% connection.output_read;
                const ring = self.ringBuffer(index);
                const at = connection.output_read % ring.len;
                // Equal byte quanta per ready connection, replenished on completion, not per tick.
                connection.output = if (connection.loan_read != connection.loan_write)
                    connection.output_loans[connection.loan_read % output_loans_max].bytes
                else
                    ring[at..][0..@min(queued, ring.len - at, 64 * 1024)];
            }

            if (connection.output.len != 0 and !connection.sending) {
                const count = self.sendVectors(connection);
                self.networking.queueSend(io, handle, connection.vectors[0..count]) catch |err| switch (err) {
                    error.Full => {
                        self.transport_waiting.insert(index);
                        return;
                    },
                    else => {
                        connection.closing = true;
                        return;
                    },
                };
                connection.sending = true;
            }
        }

        fn sendVectors(self: *Self, connection: *Connection) usize {
            var count: usize = 0;
            var bytes: usize = 0;
            if (!connection.output_control and connection.loan_read != connection.loan_write) {
                var index = connection.loan_read;
                while (index != connection.loan_write and count < connection.vectors.len and bytes < 64 * 1024) : (index +%= 1) {
                    const packet = connection.output_loans[index % output_loans_max];
                    for ([_][]const u8{ packet.prefix, packet.bytes }) |part| {
                        if (part.len == 0) continue;
                        if (count == connection.vectors.len or bytes == 64 * 1024) break;
                        const length = @min(part.len, 64 * 1024 - bytes);
                        connection.vectors[count] = .{ .base = part.ptr, .len = length };
                        count += 1;
                        bytes += length;
                    }
                }
            } else if (!connection.output_control) {
                const ring = self.ringBuffer(connection.handle.?.index);
                const at = connection.output_read % ring.len;
                bytes = @min(connection.output_write -% connection.output_read, 64 * 1024);
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
            if (!connection.output_control and connection.loan_read != connection.loan_write) {
                var remaining = count;
                while (remaining != 0) {
                    const head = &connection.output_loans[connection.loan_read % output_loans_max];
                    const prefix = @min(remaining, head.prefix.len);
                    remaining -= prefix;
                    head.prefix = head.prefix[prefix..];
                    const length = @min(remaining, head.bytes.len);
                    remaining -= length;
                    head.bytes = head.bytes[length..];
                    if (head.prefix.len == 0 and head.bytes.len == 0) {
                        assert(head.owner.sockets > 0 and head.owner.references >= head.owner.sockets);
                        head.owner.releaseSocket();
                        connection.loan_read +%= 1;
                    }
                }
                connection.output = if (connection.loan_read == connection.loan_write) &.{} else connection.output_loans[connection.loan_read % output_loans_max].bytes;
            } else if (!connection.output_control) {
                assert(count <= connection.output_write -% connection.output_read);
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
            if (self.connections[index].output_burst) |lease| return lease.bytes;
            const stride = self.smallBytes();
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
            connection.control_count = 0;
            connection.control_more = false;
            connection.control_read = 0;
            connection.control_write = 0;
            connection.control_wire = 0;
            const stride = self.smallBytes();
            connection.control_output = .{ .items = self.control_storage[index * stride ..][0..0], .capacity = stride };
        }

        pub fn releaseBuffers(self: *Self, index: usize) void {
            self.delivery_ready = true;
            const connection = &self.connections[index];
            connection.group = null;
            assert(connection.codec.state.load(.acquire) == .idle);
            assert(!connection.receiving and !connection.sending and !connection.loan.load(.acquire));
            if (connection.input_burst) |lease| lease.release();
            if (connection.output_burst) |lease| lease.release();
            if (connection.decoded) |lease| lease.release();
            connection.input_burst = null;
            connection.output_burst = null;
            connection.decoded = null;
            connection.output = &.{};
            while (connection.loan_read != connection.loan_write) {
                const owner = connection.output_loans[connection.loan_read % output_loans_max].owner;
                assert(owner.sockets > 0 and owner.references >= owner.sockets);
                owner.releaseSocket();
                connection.loan_read +%= 1;
            }
            self.releaseControl(index);
        }

        fn reserveControl(self: *Self, index: usize) bool {
            const connection = &self.connections[index];
            if (connection.control_raw == null) connection.control_raw = self.control_raw.acquire() orelse {
                connection.waiting_for = .control;
                self.wait(index);
                return false;
            };
            if (connection.control_burst != null or connection.control_output.capacity >= self.config.max_pending_wire_bytes) return true;
            // Keep one slot available for status and login while admitted clients drain configuration.
            const limit = self.configurations.slots.len - @intFromBool(connection.admitted and self.configurations.slots.len > 1);
            const lease = self.configurations.acquireWithin(limit) orelse {
                connection.waiting_for = if (connection.admitted) .configuration_admitted else .configuration;
                self.wait(index);
                return false;
            };
            assert(connection.control_output.items.len == 0);
            connection.control_burst = lease;
            connection.control_output = .{ .items = lease.bytes[0..0], .capacity = lease.bytes.len };
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
            try self.appendSpoolFragments(io, index, .{ .payload = bytes });
        }

        fn appendSpoolFragments(self: *Self, io: std.Io, index: usize, packet: packet_output.Fragments) !void {
            var parts = [_][]const u8{ packet.prefix, packet.payload };
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
                if (connection.handle == null or connection.spooling or connection.receiving or connection.sending or connection.loan.load(.acquire) or connection.codec.state.load(.acquire) != .idle or connection.control_building) continue;
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
                const borrowed = connection.loan_read != connection.loan_write;
                var parts: [output_loans_max * 2][]const u8 = undefined;
                var count: usize = 0;
                var loan_index = connection.loan_read;
                while (loan_index != connection.loan_write) : (loan_index +%= 1) {
                    const head = connection.output_loans[loan_index % output_loans_max];
                    assert(count + 2 <= parts.len);
                    parts[count] = head.prefix;
                    parts[count + 1] = head.bytes;
                    count += 2;
                }
                try self.appendSpoolParts(io, index, parts[0..count]);
                while (connection.loan_read != connection.loan_write) {
                    const head = &connection.output_loans[connection.loan_read % output_loans_max];
                    assert(head.owner.sockets > 0 and head.owner.references >= head.owner.sockets);
                    head.owner.releaseSocket();
                    connection.loan_read +%= 1;
                }
                const ring = self.ringBuffer(index);
                const queued = if (borrowed) 0 else connection.output_write -% connection.output_read;
                const at = connection.output_read % ring.len;
                const first = @min(queued, ring.len - at);
                try self.appendSpool(io, index, ring[at..][0..first]);
                try self.appendSpool(io, index, ring[0 .. queued - first]);
                connection.output_read = 0;
                connection.output_write = 0;
                connection.output = &.{};
                connection.output_control = false;
                if (connection.group == null) {
                    if (connection.output_burst) |lease| {
                        lease.release();
                        self.delivery_ready = true;
                    }
                    connection.output_burst = null;
                }
                self.releaseControl(index);
            }
        }

        fn removeWait(self: *Self, index: usize) void {
            self.transport_waiting.remove(index);
            const connection = &self.connections[index];
            const kind = connection.waiting orelse return;
            const queue = &self.waiting[@intFromEnum(kind)];
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
            const queue = &self.waiting[@intFromEnum(kind)];
            connection.waiting = kind;
            connection.wait_previous = queue.tail;
            if (queue.tail != absent) self.connections[queue.tail].wait_next = index else queue.head = index;
            queue.tail = index;
            queue.count += 1;
            assert(queue.count <= self.connections.len and connection.wait_next == absent);
            self.resources_ready = true;
        }

        fn wakeWaiters(self: *Self, kind: Wait, capacity: usize) void {
            const queue = &self.waiting[@intFromEnum(kind)];
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
            if (self.waiting[@intFromEnum(Wait.decoded)].count != 0) self.wakeWaiters(.decoded, self.decoded.availableCountWithin(self.decoded.slots.len));
            if (self.waiting[@intFromEnum(Wait.input)].count != 0) self.wakeWaiters(.input, self.input_bursts.availableCountWithin(self.input_bursts.slots.len));
            if (self.waiting[@intFromEnum(Wait.control)].count != 0) self.wakeWaiters(.control, self.control_raw.availableCountWithin(self.control_raw.slots.len));
            const admitted = &self.waiting[@intFromEnum(Wait.configuration_admitted)];
            const other = &self.waiting[@intFromEnum(Wait.configuration)];
            if (admitted.count != 0 or other.count != 0) {
                const capacity = self.configurations.availableCountWithin(self.configurations.slots.len);
                const limit = self.configurations.slots.len - @intFromBool(self.configurations.slots.len > 1);
                const count = @min(admitted.count, capacity, self.configurations.availableCountWithin(limit));
                self.wakeWaiters(.configuration_admitted, count);
                self.wakeWaiters(.configuration, capacity - count);
            }
        }

        pub fn progress(self: *Self, io: std.Io) void {
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
                if (!connection.loan.load(.acquire) and connection.codec.state.load(.acquire) == .idle and connection.decoded_result == null) {
                    if (connection.decoded) |lease| {
                        lease.release();
                        returned = true;
                    }
                    connection.decoded = null;
                }
            }
            // Admit waiting peers before the peers that just returned their decode buffers.
            if (returned and self.waiting[@intFromEnum(Wait.decoded)].count != 0) {
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
                if (!(self.progressCodec(io, index) catch {
                    connection.closing = true;
                    continue;
                })) {
                    if (connection.codec.state.load(.acquire) == .idle) self.wait(index);
                    self.sendOutput(io, index);
                    continue;
                }
                defer if (!connection.loan.load(.acquire) and connection.codec.state.load(.acquire) == .idle and connection.decoded_result == null) {
                    if (connection.decoded) |lease| lease.release();
                    connection.decoded = null;
                };
                const handle = connection.handle orelse continue;
                defer if (!connection.sending and connection.output.len == 0 and connection.codec.state.load(.acquire) == .idle and !connection.control_building) self.releaseControl(index);
                var decode_blocked = false;
                var frame_incomplete = false;
                if (!connection.receiving and !connection.loan.load(.acquire) and connection.decoded_result == null) {
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
                if (!connection.sending and connection.group == null) {
                    const queued = connection.output_write -% connection.output_read;
                    if (connection.output_burst) |lease| {
                        if (queued == 0) {
                            lease.release();
                            connection.output_burst = null;
                            connection.output_read = 0;
                            connection.output_write = 0;
                            if (!connection.output_control) connection.output = &.{};
                        }
                    } else if (connection.output.len == 0 and queued == 0) {
                        connection.output_read = 0;
                        connection.output_write = 0;
                    }
                }
                if (!connection.sending and connection.output.len == 0 and !connection.control_building) self.releaseControl(index);
                if (!self.reloading and connection.output.len == 0 and connection.saved_output.length != 0) {
                    const bytes = connection.control_output.unusedCapacitySlice();
                    const count = self.readSpan(&connection.saved_output, bytes) catch {
                        connection.closing = true;
                        continue;
                    };
                    connection.control_output.items.len = count;
                    connection.output = connection.control_output.items;
                    connection.output_control = true;
                }
                var input = self.inputBuffer(index);

                if (!self.reloading and !connection.closing and connection.state.phase != .play and connection.state.phase != .parked) {
                    if (now >= connection.admission_deadline) connection.closing = true else connection.poll.wakeAt(connection.admission_deadline);
                }

                if (self.reloading and (!connection.attached or connection.disconnect_deadline != null)) connection.closing = true;

                if (connection.state.phase == .rejected and connection.output.len == 0) connection.closing = true;
                const stopping = self.stopping or connection.disconnect_deadline != null;
                if (stopping) {
                    if (connection.state.phase != .play or now >= (connection.disconnect_deadline orelse self.stop_deadline)) {
                        connection.closing = true;
                    } else if (connection.group != null) {
                        self.sendOutput(io, index);
                    } else if (connection.disconnecting) {
                        if (connection.output.len == 0) connection.closing = true;
                    } else if (connection.output.len == 0 and connection.output_read == connection.output_write) {
                        if (!self.reserveControl(index)) {
                            self.wait(index);
                            continue;
                        }
                        const message = if (self.stopping) "Server shutting down" else "Disconnected by server";
                        const response = self.advance(io, connection, .{ .disconnect = message }) catch {
                            connection.closing = true;
                            continue;
                        };
                        const bytes = response orelse {
                            connection.closing = true;
                            continue;
                        };
                        self.queueControl(io, connection, bytes) catch {
                            connection.closing = true;
                            continue;
                        };
                        connection.disconnecting = true;
                    }
                    if (!connection.closing) connection.poll.wakeAt(connection.disconnect_deadline orelse self.stop_deadline);
                }

                if (connection.closing) {
                    if (!connection.closed) self.networking.close(io, handle, .local_close);

                    if (connection.closed and !connection.loan.load(.acquire)) {
                        if (!connection.attached or self.config.observer.detached(handle)) {
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

                while (!stopping and connection.group == null and connection.state.phase != .parked and (connection.state.phase == .play or connection.output.len == 0) and !connection.loan.load(.acquire)) {
                    if (connection.lifecycle != null and connection.output.len == 0 and connection.output_read == connection.output_write and (connection.status or self.reserveControl(index))) {
                        const response = self.advance(io, connection, .poll) catch |err| {
                            std.log.warn("event=session_poll_rejected connection={d}:{d} phase={s} reason={s}", .{ handle.index, handle.generation, @tagName(connection.state.phase), @errorName(err) });
                            connection.closing = true;
                            break;
                        };
                        if (response) |bytes| {
                            self.queueControl(io, connection, bytes) catch |err| {
                                std.log.warn("event=session_output_rejected reason={s}", .{@errorName(err)});
                                connection.closing = true;
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
                            connection.closing = true;
                            break;
                        };
                        if (rejection == null) self.admit(index);
                        if (response) |bytes| self.queueControl(io, connection, bytes) catch {
                            connection.closing = true;
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
                            connection.closing = true;
                            break;
                        };
                        std.log.info("event=session_play_attached connection={d}:{d} protocol={d} player={s}", .{ handle.index, handle.generation, connection.protocol.?.number, connection.state.name[0..connection.state.name_len] });
                        continue;
                    }

                    const frame = Endpoint.frame(if (connection.lifecycle) |*lifecycle| lifecycle else null, input[connection.input_start..connection.input_end], self.config.max_packet) catch |err| {
                        if (err == error.Incomplete) frame_incomplete = true else connection.closing = true;
                        break;
                    };
                    if (frame.body.len == 0 or frame.length > self.config.buffer_bytes or frame.body.len > self.config.max_packet) {
                        std.log.warn("event=session_invalid_frame connection={d}:{d} phase={s} length={d} limit={d}", .{ handle.index, handle.generation, @tagName(connection.state.phase), frame.body.len, self.config.max_packet });
                        connection.closing = true;
                        break;
                    }

                    var body = frame.body;
                    const borrowed = connection.lifecycle == null or Endpoint.playBorrowed(&connection.lifecycle.?);
                    const needs_decoded = connection.lifecycle != null and Endpoint.needsDecoded(self.config.compression_threshold) and (!borrowed or Endpoint.compressed(&connection.lifecycle.?));
                    if (needs_decoded and connection.decoded == null) {
                        connection.decoded = self.decoded.acquire();
                        if (connection.decoded == null) {
                            connection.waiting_for = .decoded;
                            decode_blocked = true;
                            self.wait(index);
                            break;
                        }
                    }
                    const decoded: []u8 = if (connection.decoded) |lease| lease.bytes else self.decoded.bytes[0..0];
                    if (self.codec) |codec| {
                        if (connection.lifecycle != null and needs_decoded and (connection.state.phase == .play or Endpoint.compressed(&connection.lifecycle.?))) {
                            if (connection.decoded_result == null) {
                                if (connection.state.phase == .play) {
                                    codec.submit(&connection.codec, .{ .decode_batch = .{ .connection = &connection.lifecycle.?, .bytes = input[connection.input_start..connection.input_end], .output = decoded, .packets = &connection.input_packets, .threshold = self.config.compression_threshold, .maximum = self.config.max_packet } });
                                } else {
                                    codec.submit(&connection.codec, .{ .decode = .{ .connection = &connection.lifecycle.?, .bytes = body, .output = decoded, .threshold = self.config.compression_threshold } });
                                }
                                break;
                            }
                            const result = connection.decoded_result.?;
                            if (connection.state.phase == .play) {
                                if (!self.observePlayPackets(io, connection, result.input.?)) {
                                    connection.closing = true;
                                    break;
                                }
                                connection.loan.store(true, .release);
                                const disposition = self.config.observer.input(handle, connection.protocol.?.number, result.input.?);
                                if (disposition != .borrowed) connection.loan.store(false, .release);
                                if (disposition == .blocked) {
                                    decode_blocked = true;
                                    break;
                                }
                                connection.decoded_result = null;
                                connection.input_start += result.consumed;
                                if (disposition == .borrowed) break;
                                continue;
                            }
                            body = result.bytes;
                            connection.decoded_result = null;
                        }
                    }
                    if (connection.lifecycle != null and connection.state.phase != .play and (self.codec == null or !Endpoint.compressed(&connection.lifecycle.?))) body = Endpoint.decode(&connection.lifecycle.?, &self.workspaces, body, decoded, self.config.compression_threshold) catch |err| {
                        std.log.warn("event=session_decode_rejected connection={d}:{d} phase={s} reason={s}", .{ handle.index, handle.generation, @tagName(connection.state.phase), @errorName(err) });
                        connection.closing = true;
                        break;
                    };

                    if (connection.state.phase == .play) {
                        if (!borrowed) {
                            const result = Codec.decodeBatch(&self.workspaces, .{ .connection = &connection.lifecycle.?, .bytes = input[connection.input_start..connection.input_end], .output = decoded, .packets = &connection.input_packets, .threshold = self.config.compression_threshold, .maximum = self.config.max_packet }) catch {
                                connection.closing = true;
                                break;
                            };
                            if (!self.observePlayPackets(io, connection, result.input.?)) {
                                connection.closing = true;
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
                            if (disposition == .borrowed) break;
                            continue;
                        }

                        var batch_end = connection.input_start + frame.length;

                        while (batch_end < connection.input_end) {
                            const next = Endpoint.frame(&connection.lifecycle.?, input[batch_end..connection.input_end], self.config.max_packet) catch |err| {
                                if (err != error.Incomplete) connection.closing = true;
                                break;
                            };
                            if (next.body.len == 0 or next.body.len > self.config.max_packet) {
                                connection.closing = true;
                                break;
                            }

                            batch_end += next.length;
                        }

                        if (connection.closing) break;
                        if (!self.observePlayPackets(io, connection, .{ .framed = input[connection.input_start..batch_end] })) {
                            connection.closing = true;
                            break;
                        }

                        connection.loan.store(true, .release);
                        const disposition = self.config.observer.input(handle, connection.protocol.?.number, .{ .framed = input[connection.input_start..batch_end] });

                        if (disposition != .borrowed) connection.loan.store(false, .release);
                        if (disposition == .blocked) {
                            decode_blocked = true;
                            break;
                        }
                        connection.input_start = batch_end;
                        if (disposition == .borrowed) break;
                        continue;
                    }

                    const previous = connection.state.phase;
                    const encrypted = connection.lifecycle != null and Endpoint.encrypted(&connection.lifecycle.?);
                    const response = self.advance(io, connection, .{ .packet = body }) catch |err| {
                        std.log.warn("event=session_packet_rejected connection={d}:{d} phase={s} bytes={d} reason={s}", .{ handle.index, handle.generation, @tagName(connection.state.phase), body.len, @errorName(err) });
                        connection.closing = true;
                        break;
                    };

                    if (connection.state.phase != previous)
                        std.log.debug("event=session_phase connection={d}:{d} previous={s} next={s}", .{ handle.index, handle.generation, @tagName(previous), @tagName(connection.state.phase) });
                    connection.input_start += frame.length;

                    if (!encrypted and Endpoint.encrypted(&connection.lifecycle.?)) {
                        std.log.info("event=session_encrypted connection={d}:{d}", .{ handle.index, handle.generation });
                        const tail = input[connection.input_start..connection.input_end];
                        if (self.codec != null) {
                            connection.receive_tail = tail.len;
                        } else Endpoint.receive(&connection.lifecycle.?, tail);
                    }

                    if (response) |bytes| {
                        self.queueControl(io, connection, bytes) catch |err| {
                            std.log.warn("event=session_output_rejected reason={s}", .{@errorName(err)});
                            connection.closing = true;
                            break;
                        };
                    }
                    if (connection.verification != null or connection.codec.state.load(.acquire) != .idle or connection.receive_tail != 0) break;
                }

                if (connection.verification != null or connection.codec.state.load(.acquire) != .idle or connection.control_building or connection.receive_tail != 0) {
                    if (connection.codec.state.load(.acquire) == .idle) self.readiness.signal(index).notify();
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
                if (decode_blocked or stopping or connection.state.phase == .parked or connection.receiving or connection.loan.load(.acquire)) continue;

                if (connection.input_start == connection.input_end) {
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
                        connection.closing = true;
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
                        connection.closing = true;
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
                        connection.closing = true;
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
            const packet_source = self.controlPacket(connection, packet);
            if (self.codec != null) {
                if (connection.lifecycle != null and !connection.status) {
                    assert(connection.codec.state.load(.acquire) == .idle);
                    assert(connection.control_count < Codec.control_batch_max);
                    if (connection.control_count == 0) connection.control_raw_start = connection.control_used;
                    const raw = self.rawControl(connection);
                    const address = @intFromPtr(packet.ptr);
                    const base = @intFromPtr(raw.ptr);
                    if (address >= base and address < base + raw.len) {
                        assert(packet.len <= raw.len - (address - base));
                        connection.control_used += address - base + packet.len;
                    }
                    const jobs = self.controlJobs(connection);
                    jobs[connection.control_count] = .{ .packet = packet_source, .bound = bound, .threshold = if (Endpoint.compressed(&connection.lifecycle.?)) self.config.compression_threshold else null };
                    connection.control_count += 1;
                    connection.control_building = true;
                    return;
                }
            }
            const result = try self.control(connection, packet_source, destination);
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
            assert(connection.control_count == 0 and connection.codec.state.load(.acquire) == .idle);
            connection.control_output.clearRetainingCapacity();
            connection.control_read = 0;
            connection.control_write = 0;
            connection.control_wire = 0;
            try self.appendControl(connection, packet, self.config.max_pending_wire_bytes - 2 * control_bytes_max);
            try self.buildControl(io, connection);
        }

        fn controlJobs(self: *Self, connection: *Connection) []Codec.Control {
            const lease = connection.control_burst.?;
            return self.control_jobs[lease.index * Codec.control_batch_max ..][0..Codec.control_batch_max];
        }

        fn buildControl(self: *Self, io: std.Io, connection: *Connection) !void {
            assert(connection.codec.state.load(.acquire) == .idle);
            connection.control_more = connection.state.phase == .negotiating;
            while (connection.control_more) {
                if (connection.control_count == Codec.control_batch_max) break;
                if (connection.control_count != 0 and self.rawControl(connection).len < self.config.max_packet + framing.headroom) break;
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
            if (connection.control_count != 0) {
                assert(connection.control_building and connection.lifecycle != null);
                self.codec.?.submit(&connection.codec, .{ .control_batch = .{
                    .connection = &connection.lifecycle.?,
                    .packets = self.controlJobs(connection)[0..connection.control_count],
                    .output = connection.control_output.unusedCapacitySlice(),
                } });
                return;
            }
            connection.control_building = false;
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

        fn progressCodec(self: *Self, io: std.Io, index: usize) !bool {
            const connection = &self.connections[index];
            if (self.codec == null) {
                if (connection.verification) |verification| {
                    connection.verification = null;
                    var secret = try verification.run();
                    defer std.crypto.secureZero(u8, &secret);
                    _ = try self.advance(io, connection, .{ .verified = secret });
                    Endpoint.receive(&connection.lifecycle.?, self.inputBuffer(index)[connection.input_start..connection.input_end]);
                }
                return true;
            }
            const codec = self.codec.?;
            if (connection.codec.state.load(.acquire) != .idle) {
                var result = try (Codec.take(&connection.codec) orelse return false);
                self.delivery_ready = true;
                defer if (result.secret) |*secret| std.crypto.secureZero(u8, secret);
                switch (connection.codec.operation) {
                    .verify => {
                        if (!connection.closing) {
                            _ = try self.advance(io, connection, .{ .verified = result.secret.? });
                            connection.receive_tail = connection.input_end - connection.input_start;
                        }
                    },
                    .send => {
                        if (connection.send_loan) |loan| loan.release();
                        connection.send_loan = null;
                        if (result.burst) |lease| {
                            assert(connection.output_burst == null and connection.output_write == connection.output_read and !connection.sending and !connection.output_control);
                            connection.output_burst = lease;
                            connection.output_read = 0;
                            connection.output_write = 0;
                            connection.output = &.{};
                        }
                        const count = result.consumed;
                        if (connection.spooling and count != 0) {
                            const ring = self.ringBuffer(index);
                            const at = connection.output_write % ring.len;
                            const first = @min(count, ring.len - at);
                            try self.appendSpool(io, index, ring[at..][0..first]);
                            try self.appendSpool(io, index, ring[0 .. count - first]);
                        } else connection.output_write +%= count;
                    },
                    .receive => {
                        if (connection.receive_tail != 0) {
                            connection.receive_tail = 0;
                        } else {
                            assert(result.received <= connection.received);
                            connection.input_end += result.received;
                            connection.received -= result.received;
                        }
                    },
                    .control_batch => |job| {
                        assert(connection.control_building and job.packets.len == connection.control_count);
                        connection.control_used = connection.control_raw_start;
                        for (job.packets) |packet| {
                            try self.recordControl(connection, packet.fragments.first);
                            try self.recordControl(connection, packet.fragments.second);
                        }
                        connection.control_count = 0;
                        if (!connection.control_more) {
                            connection.control_building = false;
                            try self.publishControl(io, connection);
                        }
                    },
                    .decode => connection.decoded_result = result,
                    .decode_batch => {
                        connection.input_end += result.received;
                        assert(result.received <= connection.received);
                        connection.received -= result.received;
                        if (result.consumed != 0) connection.decoded_result = result;
                    },
                    .frame, .frame_sequence => unreachable,
                }
            }
            if (connection.closing) return true;
            if (connection.verification) |verification| {
                connection.verification = null;
                codec.submit(&connection.codec, .{ .verify = verification });
                return false;
            }
            if (connection.received != 0 or connection.receive_tail != 0) {
                const buffer = self.inputBuffer(index);
                const bytes = if (connection.receive_tail != 0) buffer[connection.input_end - connection.receive_tail .. connection.input_end] else buffer[connection.input_end..][0..connection.received];
                if (!self.reloading and connection.received != 0 and connection.receive_tail == 0 and connection.state.phase == .play and connection.decoded_result == null and !connection.loan.load(.acquire) and Endpoint.compressed(&connection.lifecycle.?)) {
                    if (connection.decoded == null) connection.decoded = self.decoded.acquire();
                    const output = connection.decoded orelse {
                        connection.waiting_for = .decoded;
                        return false;
                    };
                    codec.submit(&connection.codec, .{ .decode_batch = .{
                        .connection = &connection.lifecycle.?,
                        .encrypted_tail = bytes,
                        .received = connection.received,
                        .bytes = buffer[connection.input_start .. connection.input_end + connection.received],
                        .output = output.bytes,
                        .packets = &connection.input_packets,
                        .threshold = self.config.compression_threshold,
                        .maximum = self.config.max_packet,
                    } });
                    return false;
                }
                codec.submit(&connection.codec, .{ .receive = .{ .connection = &connection.lifecycle.?, .bytes = bytes } });
                return false;
            }
            if (connection.control_building) {
                assert(connection.control_more and connection.control_count == 0);
                try self.buildControl(io, connection);
                if (connection.codec.state.load(.acquire) != .idle) return false;
            }
            return true;
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
    };
}
