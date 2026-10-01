const std = @import("std");
const network = @import("networking");
const protocol_api = @import("protocol.zig");

const assert = std.debug.assert;
const framing = @import("shared.zig");

const Trace = @import("metrics").Metrics(enum { pump, poll });

pub const Protocol = protocol_api.Protocol;

pub const Profile = protocol_api.Profile;

pub const Disposition = enum { consumed, borrowed, blocked };

pub fn Engine(comptime Endpoint: type, comptime Observer: type) type {
    return struct {
        const Self = @This();
        pub const Configuration = struct {
            connections: usize,
            max_players: ?usize = null,
            buffer_bytes: usize = 128 * 1024,
            max_packet: usize = 128 * 1024 - 3,
            protocols: *const Endpoint.Protocols,
            observer: *Observer,
            compression_threshold: ?usize = null,
            metrics_cpu: bool = false,
        };

        pub const endpoint = Endpoint;
        const Connection = struct {
            handle: ?network.Handle = null,
            protocol: ?*const Protocol = null,
            state: protocol_api.State = .{},
            lifecycle: ?Endpoint.Connection = null,
            input_start: usize = 0,
            input_end: usize = 0,
            receiving: bool = false,
            loan: std.atomic.Value(bool) = .init(false),
            output: []const u8 = &.{},
            sending: bool = false,
            output_read: usize = 0,
            output_write: usize = 0,
            closing: bool = false,
            closed: bool = false,
            attached: bool = false,
            resumed: bool = false,
            control_bytes: [256]u8 = undefined,
            output_control: bool = false,
            disconnecting: bool = false,
            admitted: bool = false,
            admission_deadline: i96 = 0,
            disconnect_deadline: ?i96 = null,
        };

        allocator: std.mem.Allocator,
        io: std.Io,
        networking: network.Transport,
        config: Configuration,
        connections: []Connection,
        input: []u8,
        output: []u8,
        events: []network.Event,
        workspaces: Endpoint.Workspaces,
        decoded: []u8,
        scratch: []u8,
        stopping: bool = false,
        stop_deadline: i96 = 0,
        metrics: Trace,
        sent_bytes: u64 = 0,
        admitted: usize = 0,
        reloading: bool = false,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, networking: network.Transport, config: Configuration) !*Self {
            if (config.protocols.values.len == 0) return error.InvalidConfiguration;
            if ((config.max_players orelse config.connections) == 0 or (config.max_players orelse config.connections) > config.connections)
                return error.InvalidConfiguration;
            if (config.connections == 0 or config.connections > std.math.maxInt(u16) or config.buffer_bytes < 512 or
                config.max_packet == 0 or config.max_packet > config.buffer_bytes - 3 or
                (config.compression_threshold != null and config.compression_threshold.? > config.max_packet)) return error.InvalidConfiguration;

            for (config.protocols.values, 0..) |protocol, i| {
                for (config.protocols.values[0..i]) |previous| if (protocol.number == previous.number) return error.InvalidConfiguration;
            }

            const bytes = try std.math.mul(usize, config.connections, config.buffer_bytes);
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const connections = try allocator.alloc(Connection, config.connections);
            errdefer allocator.free(connections);
            const input = try allocator.alloc(u8, bytes);
            errdefer allocator.free(input);
            const output = try allocator.alloc(u8, bytes);
            errdefer allocator.free(output);
            const events = try allocator.alloc(network.Event, config.connections * 3);
            errdefer allocator.free(events);
            const decoded = try allocator.alloc(u8, if (Endpoint.needsDecoded(config.compression_threshold)) bytes else 0);
            errdefer allocator.free(decoded);
            const scratch = try allocator.alloc(u8, config.buffer_bytes);
            errdefer allocator.free(scratch);

            for (connections) |*connection| connection.* = .{};

            self.* = .{
                .allocator = allocator,
                .io = io,
                .networking = networking,
                .config = config,
                .connections = connections,
                .input = input,
                .output = output,
                .events = events,
                .workspaces = Endpoint.initWorkspaces(),
                .decoded = decoded,
                .scratch = scratch,
                .metrics = Trace.init(io, .{ .cpu = config.metrics_cpu }),
            };
            return self;
        }

        pub fn deinit(self: *Self) void {
            assert(self.drained());
            assert(self.admitted == 0);

            self.allocator.free(self.scratch);
            self.allocator.free(self.decoded);
            self.allocator.free(self.events);
            self.allocator.free(self.output);
            self.allocator.free(self.input);
            self.allocator.free(self.connections);
            self.allocator.destroy(self);
        }

        pub fn beginShutdown(self: *Self) void {
            if (self.stopping) return;
            self.stopping = true;
            self.stop_deadline = std.Io.Clock.now(.awake, self.io).nanoseconds + 3 * std.time.ns_per_s;
        }

        pub fn disconnect(self: *Self, handle: network.Handle) void {
            if (handle.index >= self.connections.len) return;

            const connection = &self.connections[handle.index];
            if (connection.handle == null or !std.meta.eql(connection.handle.?, handle)) return;
            if (connection.disconnect_deadline != null) return;
            connection.disconnect_deadline = std.Io.Clock.now(.awake, self.io).nanoseconds + 3 * std.time.ns_per_s;
        }

        pub fn drained(self: *const Self) bool {
            for (self.connections) |*connection| if (connection.handle != null) return false;
            return true;
        }

        pub fn park(self: *Self) !bool {
            self.reloading = true;
            var ready = true;

            for (self.connections) |*connection| {
                const handle = connection.handle orelse continue;

                if (connection.state.phase == .play and !connection.closing and connection.disconnect_deadline == null) _ = try self.reconfigure(handle);
                ready = ready and connection.state.phase == .parked and !connection.receiving and !connection.sending and connection.output.len == 0 and !connection.loan.load(.acquire);
            }

            return ready;
        }

        pub fn restart(self: *Self) void {
            self.reloading = false;

            for (self.connections) |*connection| {
                if (connection.handle == null) continue;
                assert(connection.state.phase == .parked);
                _ = self.advance(connection, .restore) catch |err| {
                    std.log.err("event=session_restore_failed reason={s}", .{@errorName(err)});
                    connection.closing = true;
                    continue;
                };
                connection.attached = false;
                connection.resumed = true;
                connection.admission_deadline = std.Io.Clock.now(.awake, self.io).nanoseconds + 30 * std.time.ns_per_s;
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
                assert(connection.state.phase == .parked and !connection.receiving and !connection.sending and !connection.loan.load(.acquire));
                const input = self.input[index * self.config.buffer_bytes ..][connection.input_start..connection.input_end];
                const state = try Endpoint.save(&connection.lifecycle.?, self.scratch);
                assert(state.len <= self.scratch.len);
                try writer.writeInt(i32, native.descriptor(native.context, handle), .little);
                try writer.writeInt(u32, 1, .little);
                try writer.writeInt(u32, @intCast(53 + state.len + input.len), .little);
                try writer.writeInt(i32, connection.protocol.?.number, .little);
                try writer.writeInt(u64, Endpoint.resumeFormat(&connection.lifecycle.?), .little);
                try writer.writeInt(u32, @intCast(state.len), .little);
                try writer.writeAll(state);
                try writer.writeInt(u128, connection.state.uuid, .little);
                try writer.writeByte(@intCast(connection.state.name_len));
                try writer.writeAll(&connection.state.name);
                try writer.writeInt(u32, @intCast(input.len), .little);
                try writer.writeAll(input);

                if (input.len != 0) std.log.info("event=reload_input_saved bytes={d} encrypted={}", .{ input.len, Endpoint.encrypted(&connection.lifecycle.?) });
            }
        }

        pub fn readResume(self: *Self, reader: *std.Io.Reader) !void {
            assert(self.admitted == 0);
            const native = self.networking.inheritance orelse return error.InheritanceUnavailable;
            const count = try reader.takeInt(u32, .little);
            if (count > (self.config.max_players orelse self.connections.len)) return error.ResumeCapacity;

            for (0..count) |_| {
                const fd = try reader.takeInt(i32, .little);
                const kind = try reader.takeInt(u32, .little);
                const length = try reader.takeInt(u32, .little);
                if (fd < 3 or kind != 1 or length < 53 or length - 53 > self.config.buffer_bytes + self.scratch.len) return error.InvalidResume;

                var connection: Connection = .{ .admitted = true, .resumed = true };
                const number = try reader.takeInt(i32, .little);
                const format = try reader.takeInt(u64, .little);
                const state_len = try reader.takeInt(u32, .little);
                if (state_len > self.scratch.len or state_len > length - 53) return error.InvalidResume;
                try reader.readSliceAll(self.scratch[0..state_len]);

                for (&self.config.protocols.values) |*protocol| if (protocol.number == number) {
                    connection.protocol = protocol;
                    break;
                };

                if (connection.protocol == null) return error.UnsupportedProtocol;
                connection.lifecycle = try Endpoint.restore(number, format, self.scratch[0..state_len]);
                connection.state.phase = .parked;
                connection.state.uuid = try reader.takeInt(u128, .little);

                for (self.connections) |previous| if (previous.handle) |handle| {
                    if (native.descriptor(native.context, handle) == fd or previous.state.uuid == connection.state.uuid) return error.InvalidResume;
                };

                connection.state.name_len = try reader.takeByte();
                try reader.readSliceAll(&connection.state.name);
                if (connection.state.name_len == 0 or connection.state.name_len > 16)
                    return error.InvalidResume;

                const input_len = try reader.takeInt(u32, .little);
                if (input_len > self.config.buffer_bytes or input_len != length - 53 - state_len) return error.InvalidResume;

                const handle = try native.adopt(native.context, fd);
                connection.handle = handle;
                _ = try self.advance(&connection, .restore);
                connection.input_end = input_len;
                connection.admission_deadline = std.Io.Clock.now(.awake, self.io).nanoseconds + 30 * std.time.ns_per_s;
                try reader.readSliceAll(self.input[@as(usize, handle.index) * self.config.buffer_bytes ..][0..input_len]);

                if (input_len != 0) std.log.info("event=reload_input_restored bytes={d} encrypted={}", .{ input_len, Endpoint.encrypted(&connection.lifecycle.?) });
                self.connections[handle.index] = connection;
                self.admitted += 1;
            }
        }

        /// The caller has stopped new Play output. Existing output and input loans must drain before
        /// changing the codec phase. Cipher streams stay intact.
        pub fn reconfigure(self: *Self, handle: network.Handle) !bool {
            const connection = &self.connections[handle.index];
            assert(connection.handle != null and std.meta.eql(connection.handle.?, handle));
            assert(connection.state.phase == .play and connection.attached);
            if (connection.closing or connection.disconnect_deadline != null or self.stopping) return false;
            if (connection.output.len != 0 or connection.sending or connection.output_read != connection.output_write or connection.loan.load(.acquire))
                return false;

            if (try self.advance(connection, .park)) |bytes| {
                connection.output = try self.control(connection, bytes, &connection.control_bytes);
                connection.output_control = true;
            }
            connection.admission_deadline = std.Io.Clock.now(.awake, self.io).nanoseconds + 10 * std.time.ns_per_s;
            return true;
        }

        /// The observer may release its single input loan from another thread.
        /// It must not access the payload after this call.
        pub fn releaseInput(self: *Self, handle: network.Handle) void {
            const transport = self.networking;
            const io = self.io;
            const connection = &self.connections[handle.index];
            assert(connection.handle != null);
            assert(std.meta.eql(connection.handle.?, handle));
            const borrowed = connection.loan.swap(false, .release);
            assert(borrowed);
            transport.notify(io);
        }

        /// Session-owner thread only. Admission has already reserved these bytes.
        /// Connection-owned storage prevents a slow peer from retaining shared pages.
        pub fn sendFramed(self: *Self, handle: network.Handle, bytes: []const u8) !void {
            if (self.stopping) return error.Closed;
            if (bytes.len == 0) return error.InvalidPacket;
            if (handle.index >= self.connections.len) return error.Closed;

            const connection = &self.connections[handle.index];
            if (connection.handle == null or !std.meta.eql(connection.handle.?, handle) or connection.closing or connection.disconnect_deadline != null or connection.state.phase != .play)
                return error.Closed;

            const used = connection.output_write -% connection.output_read;
            assert(used <= self.config.buffer_bytes and bytes.len <= self.config.buffer_bytes - used);
            const buffer = self.output[@as(usize, handle.index) * self.config.buffer_bytes ..][0..self.config.buffer_bytes];
            const start = connection.output_write % buffer.len;
            const first = @min(bytes.len, buffer.len - start);

            @memcpy(buffer[start..][0..first], bytes[0..first]);
            @memcpy(buffer[0 .. bytes.len - first], bytes[first..]);
            Endpoint.send(&connection.lifecycle.?, buffer[start..][0..first]);
            Endpoint.send(&connection.lifecycle.?, buffer[0 .. bytes.len - first]);

            connection.output_write +%= bytes.len;
        }

        pub fn pump(self: *Self, timeout: ?std.Io.Timeout) !usize {
            var pumping = self.metrics.begin(.pump);
            defer pumping.end();
            self.progress();
            const count = blk: {
                const polling = pumping.begin(.poll);
                defer polling.end();
                break :blk try self.networking.poll(self.io, timeout, self.events);
            };

            for (self.events[0..count]) |event| {
                const handle = switch (event) {
                    .accepted => |value| value,
                    .received, .sent => |value| value.handle,
                    .closed => |value| value.handle,
                };
                if (handle.index >= self.connections.len) {
                    if (event == .closed) self.networking.release(self.io, handle) else self.networking.close(self.io, handle, .capacity);
                    continue;
                }

                const connection = &self.connections[handle.index];

                if (event == .accepted) {
                    assert(connection.handle == null);
                    connection.* = .{
                        .handle = handle,
                        .admission_deadline = std.Io.Clock.now(.awake, self.io).nanoseconds + 30 * std.time.ns_per_s,
                    };
                    std.log.debug("event=session_accepted connection={d}:{d}", .{ handle.index, handle.generation });
                } else {
                    if (connection.handle == null or !std.meta.eql(connection.handle.?, handle)) continue;

                    switch (event) {
                        .received => |result| {
                            assert(connection.receiving);
                            connection.receiving = false;

                            if (result.result.errno != null or result.result.bytes == 0 or result.result.bytes > self.config.buffer_bytes - connection.input_end) {
                                connection.closing = true;
                            } else {
                                if (connection.lifecycle) |*lifecycle| {
                                    const bytes = self.input[@as(usize, handle.index) * self.config.buffer_bytes + connection.input_end ..][0..result.result.bytes];
                                    Endpoint.receive(lifecycle, bytes);
                                }

                                connection.input_end += result.result.bytes;
                            }
                        },
                        .sent => |result| {
                            assert(connection.sending);
                            connection.sending = false;

                            if (result.result.errno != null or result.result.bytes == 0 or result.result.bytes > connection.output.len) {
                                connection.closing = true;
                            } else {
                                self.sent_bytes += result.result.bytes;
                                connection.output = connection.output[result.result.bytes..];

                                if (connection.state.phase == .play and !connection.output_control) {
                                    connection.output_read +%= result.result.bytes;
                                    self.config.observer.sent(handle, result.result.bytes);
                                }

                                if (connection.output.len == 0) connection.output_control = false;
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

            self.progress();
            try self.networking.submit(self.io);
            return count;
        }

        fn progress(self: *Self) void {
            const now = std.Io.Clock.now(.awake, self.io).nanoseconds;

            for (self.connections, 0..) |*connection, index| {
                const handle = connection.handle orelse continue;
                const input = self.input[index * self.config.buffer_bytes ..][0..self.config.buffer_bytes];
                const output = self.output[index * self.config.buffer_bytes ..][0..self.config.buffer_bytes];

                if (connection.state.phase != .play and connection.state.phase != .parked and now >= connection.admission_deadline) connection.closing = true;

                if (self.reloading and !connection.attached) connection.closing = true;

                if (connection.state.phase == .rejected and connection.output.len == 0) connection.closing = true;
                const stopping = self.stopping or connection.disconnect_deadline != null;
                if (stopping) {
                    if (connection.state.phase != .play or now >= (connection.disconnect_deadline orelse self.stop_deadline)) {
                        connection.closing = true;
                    } else if (connection.disconnecting) {
                        if (connection.output.len == 0) connection.closing = true;
                    } else if (connection.output.len == 0 and connection.output_read == connection.output_write) {
                        const message = if (self.stopping) "Server shutting down" else "Disconnected by server";
                        const response = self.advance(connection, .{ .disconnect = message }) catch {
                            connection.closing = true;
                            continue;
                        };
                        const bytes = response orelse {
                            connection.closing = true;
                            continue;
                        };
                        connection.output = self.control(connection, bytes, &connection.control_bytes) catch {
                            connection.closing = true;
                            continue;
                        };
                        connection.output_control = true;
                        connection.disconnecting = true;
                    }
                }

                if (connection.closing) {
                    if (!connection.closed) self.networking.close(self.io, handle, .local_close);

                    if (connection.closed and !connection.loan.load(.acquire)) {
                        if (!connection.attached or self.config.observer.detached(handle)) {
                            self.config.observer.closed(handle);
                            self.networking.release(self.io, handle);

                            if (connection.admitted) {
                                assert(self.admitted > 0);
                                self.admitted -= 1;
                            }

                            if (connection.lifecycle) |*lifecycle| Endpoint.clear(lifecycle);
                            connection.* = .{};
                        }
                    }

                    continue;
                }

                while (!stopping and connection.state.phase != .parked and (connection.state.phase == .play or connection.output.len == 0) and !connection.loan.load(.acquire)) {
                    if (connection.lifecycle != null and connection.output.len == 0 and connection.output_read == connection.output_write) {
                        const response = self.advance(connection, .poll) catch |err| {
                            std.log.warn("event=session_poll_rejected connection={d}:{d} phase={s} reason={s}", .{ handle.index, handle.generation, @tagName(connection.state.phase), @errorName(err) });
                            connection.closing = true;
                            break;
                        };
                        if (response) |bytes| {
                            connection.output = self.control(connection, bytes, if (connection.state.phase == .play) &connection.control_bytes else output) catch {
                                connection.closing = true;
                                break;
                            };
                            connection.output_control = connection.state.phase == .play;
                            break;
                        }
                    }

                    if (connection.state.phase == .admitting) {
                        assert(!connection.admitted);
                        const maximum = self.config.max_players orelse self.config.connections;
                        assert(self.admitted <= maximum);
                        var duplicate = false;
                        for (self.connections) |*other| duplicate = duplicate or (other.admitted and other.state.uuid == connection.state.uuid);
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
                                .pending => break,
                                .reject => rejection = "Unable to route player",
                            }
                        }
                        const response = self.advance(connection, .{ .admitted = rejection }) catch {
                            connection.closing = true;
                            break;
                        };
                        if (rejection == null) {
                            self.admitted += 1;
                            connection.admitted = true;
                            assert(self.admitted <= maximum);
                        }
                        if (response) |bytes| connection.output = self.control(connection, bytes, output) catch {
                            connection.closing = true;
                            break;
                        };
                        break;
                    }

                    if (connection.state.phase == .attaching) {
                        if (!self.config.observer.attached(.{
                            .connection = handle,
                            .protocol = connection.protocol.?.number,
                            .uuid = connection.state.uuid,
                            .name = connection.state.name[0..connection.state.name_len],
                        }))
                            break;
                        connection.attached = true;
                        _ = self.advance(connection, .attached) catch {
                            connection.closing = true;
                            break;
                        };
                        std.log.info("event=session_play_attached connection={d}:{d} protocol={d} player={s}", .{ handle.index, handle.generation, connection.protocol.?.number, connection.state.name[0..connection.state.name_len] });
                    }

                    const frame = Endpoint.frame(if (connection.lifecycle) |*lifecycle| lifecycle else null, input[connection.input_start..connection.input_end], self.config.max_packet) catch |err| {
                        if (err != error.Incomplete) connection.closing = true;
                        break;
                    };
                    if (frame.body.len == 0 or frame.length > self.config.buffer_bytes or frame.body.len > self.config.max_packet) {
                        std.log.warn("event=session_invalid_frame connection={d}:{d} phase={s} length={d} limit={d}", .{ handle.index, handle.generation, @tagName(connection.state.phase), frame.body.len, self.config.max_packet });
                        connection.closing = true;
                        break;
                    }

                    var body = frame.body;
                    const borrowed = connection.lifecycle == null or Endpoint.playBorrowed(&connection.lifecycle.?);
                    const decoded: []u8 = if (Endpoint.needsDecoded(self.config.compression_threshold)) self.decoded[index * self.config.buffer_bytes ..][0..self.config.buffer_bytes] else self.decoded[0..0];
                    if (connection.lifecycle != null and connection.state.phase != .play) body = Endpoint.decode(&connection.lifecycle.?, &self.workspaces, body, decoded, self.config.compression_threshold) catch |err| {
                        std.log.warn("event=session_decode_rejected connection={d}:{d} phase={s} reason={s}", .{ handle.index, handle.generation, @tagName(connection.state.phase), @errorName(err) });
                        connection.closing = true;
                        break;
                    };

                    if (connection.state.phase == .play) {
                        if (!borrowed) {
                            var batch_end = connection.input_start;
                            var written: usize = 0;

                            while (batch_end < connection.input_end and decoded.len - written > 3) {
                                const next = Endpoint.frame(&connection.lifecycle.?, input[batch_end..connection.input_end], self.config.max_packet) catch |err| {
                                    if (err != error.Incomplete) connection.closing = true;
                                    break;
                                };
                                if (next.body.len == 0 or next.body.len > self.config.max_packet) {
                                    connection.closing = true;
                                    break;
                                }

                                const payload = Endpoint.decode(&connection.lifecycle.?, &self.workspaces, next.body, decoded[written + 3 ..], self.config.compression_threshold) catch |err| {
                                    if (err != error.BufferTooSmall or written == 0) connection.closing = true;
                                    break;
                                };
                                if (payload.len > self.config.max_packet or payload.len > decoded.len - written - 3) {
                                    if (written == 0) connection.closing = true;
                                    break;
                                }

                                // The loan owns a contiguous decoded batch, independent of receive bytes.
                                if (payload.ptr != decoded[written + 3 ..].ptr) @memcpy(decoded[written + 3 ..][0..payload.len], payload);
                                // Fixed-width VarInt avoids moving the decoded packet for its prefix.
                                const size: u32 = @intCast(payload.len);
                                decoded[written] = @as(u8, @truncate(size & 127)) | 128;
                                decoded[written + 1] = @as(u8, @truncate((size >> 7) & 127)) | 128;
                                decoded[written + 2] = @intCast(size >> 14);
                                written += 3 + payload.len;
                                batch_end += next.length;
                            }

                            if (connection.closing or written == 0) break;
                            if (!self.observePlayPackets(connection, decoded[0..written])) {
                                connection.closing = true;
                                break;
                            }

                            connection.loan.store(true, .release);
                            const disposition = self.config.observer.input(handle, connection.protocol.?.number, decoded[0..written]);

                            if (disposition != .borrowed) connection.loan.store(false, .release);
                            if (disposition == .blocked) break;
                            connection.input_start = batch_end;
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
                        if (!self.observePlayPackets(connection, input[connection.input_start..batch_end])) {
                            connection.closing = true;
                            break;
                        }

                        connection.loan.store(true, .release);
                        const disposition = self.config.observer.input(handle, connection.protocol.?.number, input[connection.input_start..batch_end]);

                        if (disposition != .borrowed) connection.loan.store(false, .release);
                        if (disposition == .blocked) break;
                        connection.input_start = batch_end;
                        if (disposition == .borrowed) break;
                        continue;
                    }

                    const previous = connection.state.phase;
                    const encrypted = connection.lifecycle != null and Endpoint.encrypted(&connection.lifecycle.?);
                    const response = self.advance(connection, .{ .packet = body }) catch |err| {
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
                        Endpoint.receive(&connection.lifecycle.?, tail);
                    }

                    if (response) |bytes| connection.output = self.control(connection, bytes, output) catch {
                        connection.closing = true;
                        break;
                    };
                }

                if (connection.closing) {
                    self.networking.close(self.io, handle, .io_failure);
                    continue;
                }

                if (connection.state.phase == .play and connection.output.len == 0) {
                    const queued = connection.output_write -% connection.output_read;
                    const at = connection.output_read % output.len;
                    // Equal byte quanta per ready connection, replenished on completion, not per tick.
                    connection.output = output[at..][0..@min(queued, output.len - at, 64 * 1024)];
                }

                if (connection.output.len != 0 and !connection.sending) {
                    self.networking.queueSend(self.io, handle, connection.output) catch |err| switch (err) {
                        error.Full => continue,
                        else => {
                            connection.closing = true;
                            continue;
                        },
                    };
                    connection.sending = true;
                }

                if (stopping or connection.state.phase == .parked or connection.receiving or connection.loan.load(.acquire)) continue;

                if (connection.input_start != 0) {
                    std.mem.copyForwards(u8, input, input[connection.input_start..connection.input_end]);
                    connection.input_end -= connection.input_start;
                    connection.input_start = 0;
                }

                if (connection.input_end == input.len) {
                    connection.closing = true;
                    continue;
                }

                self.networking.queueReceive(self.io, handle, input[connection.input_end..]) catch |err| switch (err) {
                    error.Full => continue,
                    else => {
                        connection.closing = true;
                        continue;
                    },
                };
                connection.receiving = true;
            }
        }

        fn control(self: *Self, connection: *Connection, bytes: []const u8, output: []u8) ![]const u8 {
            if (connection.lifecycle) |*lifecycle|
                return Endpoint.control(lifecycle, &self.workspaces, bytes, self.scratch, output, self.config.compression_threshold);
            return Endpoint.Bootstrap.control(bytes, self.scratch, output);
        }

        fn advance(self: *Self, connection: *Connection, event: protocol_api.Event) !?[]const u8 {
            if (connection.state.phase == .handshake) {
                if (event != .packet) return error.InvalidProtocolEvent;
                const handshake = try self.config.observer.handshake(event.packet);
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
            const context: protocol_api.Context(Observer) = .{
                .connection = connection.handle.?,
                .state = &connection.state,
                .protocol = connection.protocol.?,
                .output = self.scratch[framing.headroom..],
                .io = self.io,
                .now = std.Io.Clock.now(.awake, self.io).nanoseconds,
                .reloading = self.reloading,
                .compression_threshold = self.config.compression_threshold,
                .observer = self.config.observer,
            };
            return Endpoint.advance(Observer, &connection.lifecycle.?, event, context);
        }

        fn observePlayPackets(self: *Self, connection: *Connection, bytes: []const u8) bool {
            var rest = bytes;
            while (rest.len != 0) {
                const length, const body = framing.readVarint(rest) catch return false;
                if (length <= 0 or length > body.len) return false;
                rest = body[@intCast(length)..];
                const response = self.advance(connection, .{ .packet = body[0..@intCast(length)] }) catch return false;
                if (response != null) return false;
            }
            return true;
        }
    };
}
