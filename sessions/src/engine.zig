const std = @import("std");
const network = @import("networking");
const protocols = @import("protocols");

const assert = std.debug.assert;
const support = protocols.support;
const compression = @import("compression.zig");
const Cipher = @import("cipher.zig").Cipher;

pub const Encryption = struct {
    /// The key provider and DER bytes outlive the Engine. Only the Session owner calls it.
    context: *anyopaque,
    public_key_der: []const u8,
    /// RSA PKCS#1 v1.5 decryption, exact plaintext length, with provider-owned blinding.
    decrypt: *const fn (*anyopaque, std.Io, []const u8, []u8) error{ InvalidCiphertext, CryptoFailure }!void,
};

const Trace = @import("metrics").Metrics(enum { pump, poll });

pub const KnownPack = struct {
    namespace: []const u8,
    id: []const u8,
    version: []const u8,
};

pub const Protocol = struct {
    number: i32,
    offered_packs: []const KnownPack,
    before_ack: []const []const u8,
    known: []const []const u8,
    full: []const []const u8,
};

pub const Profile = struct {
    connection: network.Handle,
    protocol: i32,
    uuid: u128,
    name: []const u8,
};

pub const Status = struct {
    description: []const u8 = "Lightning Rod",
    version: []const u8 = "Lightning Rod v0.1.0",
    favicon: ?[]const u8 = null,
};

pub const Disposition = enum { consumed, borrowed, blocked };

pub const Observer = struct {
    context: *anyopaque,
    attached: *const fn (*anyopaque, Profile) bool,
    /// Complete length-prefixed Play packets. One loan covers the whole batch.
    input: *const fn (*anyopaque, network.Handle, i32, []const u8) Disposition,
    detached: *const fn (*anyopaque, network.Handle) bool,
    sent: *const fn (*anyopaque, network.Handle, usize) void,
};

pub const Configuration = struct {
    connections: usize,
    max_players: ?usize = null,
    buffer_bytes: usize = 128 * 1024,
    max_packet: usize = 128 * 1024 - 3,
    protocols: []const Protocol,
    status: Status = .{},
    observer: Observer,
    compression_threshold: ?usize = null,
    metrics_cpu: bool = false,
    encryption: ?Encryption = null,
};

pub const Engine = struct {
    const Phase = enum {
        handshake,
        status,
        login,
        encryption_response,
        login_success,
        login_ack,
        before_ack,
        known_packs,
        configuring,
        configuration_ack,
        attaching,
        play,
        reconfiguration_ack,
        parked,
        rejected,
    };

    const Connection = struct {
        handle: ?network.Handle = null,
        protocol: ?*const Protocol = null,
        phase: Phase = .handshake,
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
        configuration_index: usize = 0,
        known: bool = false,
        name: [16]u8 = undefined,
        name_len: usize = 0,
        uuid: u128 = 0,
        compressed: bool = false,
        receive_cipher: ?Cipher = null,
        send_cipher: ?Cipher = null,
        verify_token: [4]u8 = undefined,
        control_bytes: [256]u8 = undefined,
        output_control: bool = false,
        keepalive: ?i64 = null,
        keepalive_due: i96 = 0,
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
    codec: ?*compression.Workspace,
    decoded: []u8,
    scratch: []u8,
    stopping: bool = false,
    stop_deadline: i96 = 0,
    metrics: Trace,
    sent_bytes: u64 = 0,
    admitted: usize = 0,
    reloading: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, networking: network.Transport, config: Configuration) !*Engine {
        if (config.protocols.len == 0) return error.InvalidConfiguration;
        if ((config.max_players orelse config.connections) == 0 or (config.max_players orelse config.connections) > config.connections)
            return error.InvalidConfiguration;
        if (config.connections == 0 or config.connections > std.math.maxInt(u16) or config.buffer_bytes < 512 or
            config.max_packet == 0 or config.max_packet > (1 << 21) - 1 or config.max_packet > config.buffer_bytes - 3 or
            config.status.description.len > 1024 or config.status.version.len > 256 or
            (config.status.favicon != null and config.status.favicon.?.len > 16 * 1024) or
            (config.compression_threshold != null and config.compression_threshold.? > compression.maximum)) return error.InvalidConfiguration;
        if (config.encryption) |key| if (key.public_key_der.len == 0 or key.public_key_der.len > 512) return error.InvalidConfiguration;

        for (config.protocols, 0..) |protocol, i| {
            for (config.protocols[0..i]) |previous| if (protocol.number == previous.number) return error.InvalidConfiguration;
        }

        const bytes = try std.math.mul(usize, config.connections, config.buffer_bytes);
        const self = try allocator.create(Engine);
        errdefer allocator.destroy(self);
        const connections = try allocator.alloc(Connection, config.connections);
        errdefer allocator.free(connections);
        const input = try allocator.alloc(u8, bytes);
        errdefer allocator.free(input);
        const output = try allocator.alloc(u8, bytes);
        errdefer allocator.free(output);
        const events = try allocator.alloc(network.Event, config.connections * 3);
        errdefer allocator.free(events);
        const decoded = try allocator.alloc(u8, if (config.compression_threshold != null) bytes else 0);
        errdefer allocator.free(decoded);
        const scratch = try allocator.alloc(u8, config.buffer_bytes);
        errdefer allocator.free(scratch);
        const codec = if (config.compression_threshold != null) try allocator.create(compression.Workspace) else null;

        if (codec) |workspace| workspace.* = .{};

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
            .codec = codec,
            .decoded = decoded,
            .scratch = scratch,
            .metrics = Trace.init(io, .{ .cpu = config.metrics_cpu }),
        };
        return self;
    }

    pub fn deinit(self: *Engine) void {
        assert(self.drained());
        assert(self.admitted == 0);

        if (self.codec) |codec| self.allocator.destroy(codec);
        self.allocator.free(self.scratch);
        self.allocator.free(self.decoded);
        self.allocator.free(self.events);
        self.allocator.free(self.output);
        self.allocator.free(self.input);
        self.allocator.free(self.connections);
        self.allocator.destroy(self);
    }

    pub fn beginShutdown(self: *Engine) void {
        if (self.stopping) return;
        self.stopping = true;
        self.stop_deadline = std.Io.Clock.now(.awake, self.io).nanoseconds + 3 * std.time.ns_per_s;
    }

    pub fn disconnect(self: *Engine, handle: network.Handle) void {
        if (handle.index >= self.connections.len) return;

        const connection = &self.connections[handle.index];
        if (connection.handle == null or !std.meta.eql(connection.handle.?, handle)) return;
        if (connection.disconnect_deadline != null) return;
        connection.disconnect_deadline = std.Io.Clock.now(.awake, self.io).nanoseconds + 3 * std.time.ns_per_s;
    }

    pub fn drained(self: *const Engine) bool {
        for (self.connections) |*connection| if (connection.handle != null) return false;
        return true;
    }

    pub fn park(self: *Engine) !bool {
        self.reloading = true;
        var ready = true;

        for (self.connections) |*connection| {
            const handle = connection.handle orelse continue;

            if (connection.phase == .play and !connection.closing and connection.disconnect_deadline == null) _ = try self.reconfigure(handle);
            ready = ready and connection.phase == .parked and !connection.receiving and !connection.sending and connection.output.len == 0 and !connection.loan.load(.acquire);
        }

        return ready;
    }

    pub fn restart(self: *Engine) void {
        self.reloading = false;

        for (self.connections) |*connection| {
            if (connection.handle == null) continue;
            assert(connection.phase == .parked);
            connection.phase = .before_ack;
            connection.attached = false;
            connection.resumed = true;
            connection.admission_deadline = std.Io.Clock.now(.awake, self.io).nanoseconds + 30 * std.time.ns_per_s;
        }
    }

    pub fn writeResume(self: *Engine, writer: *std.Io.Writer) !void {
        assert(self.reloading);
        const native = self.networking.inheritance.?;
        var count: u32 = 0;

        for (self.connections) |connection| if (connection.handle != null) {
            count += 1;
        };

        try writer.writeInt(u32, count, .little);

        for (self.connections, 0..) |*connection, index| {
            const handle = connection.handle orelse continue;
            assert(connection.phase == .parked and !connection.receiving and !connection.sending and !connection.loan.load(.acquire));
            const input = self.input[index * self.config.buffer_bytes ..][connection.input_start..connection.input_end];
            try writer.writeInt(i32, native.descriptor(native.context, handle), .little);
            try writer.writeInt(u32, 1, .little);
            try writer.writeInt(u32, @intCast(91 + input.len), .little);
            try writer.writeInt(i32, connection.protocol.?.number, .little);
            try writer.writeInt(u128, connection.uuid, .little);
            try writer.writeByte(@intCast(connection.name_len));
            try writer.writeAll(&connection.name);
            try writer.writeByte(@intFromBool(connection.compressed));
            try writer.writeByte(@intFromBool(connection.receive_cipher != null));

            if (connection.receive_cipher) |*cipher| {
                try writer.writeAll(&cipher.secret);
                try writer.writeAll(&cipher.feedback);
                try writer.writeAll(&connection.send_cipher.?.feedback);
            } else try writer.splatByteAll(0, 48);
            try writer.writeInt(u32, @intCast(input.len), .little);
            try writer.writeAll(input);

            if (input.len != 0) std.log.info("event=reload_input_saved bytes={d} encrypted={}", .{ input.len, connection.receive_cipher != null });
        }
    }

    pub fn readResume(self: *Engine, reader: *std.Io.Reader) !void {
        assert(self.admitted == 0);
        const native = self.networking.inheritance orelse return error.InheritanceUnavailable;
        const count = try reader.takeInt(u32, .little);
        if (count > (self.config.max_players orelse self.connections.len)) return error.ResumeCapacity;

        for (0..count) |_| {
            const fd = try reader.takeInt(i32, .little);
            const kind = try reader.takeInt(u32, .little);
            const length = try reader.takeInt(u32, .little);
            if (fd < 3 or kind != 1 or length < 91 or length - 91 > self.config.buffer_bytes) return error.InvalidResume;

            var connection: Connection = .{ .phase = .before_ack, .admitted = true, .resumed = true };
            const number = try reader.takeInt(i32, .little);

            for (self.config.protocols) |*protocol| if (protocol.number == number) {
                connection.protocol = protocol;
                break;
            };

            if (connection.protocol == null) return error.UnsupportedProtocol;
            connection.uuid = try reader.takeInt(u128, .little);

            for (self.connections) |previous| if (previous.handle) |handle| {
                if (native.descriptor(native.context, handle) == fd or previous.uuid == connection.uuid) return error.InvalidResume;
            };

            connection.name_len = try reader.takeByte();
            try reader.readSliceAll(&connection.name);
            const compressed = try reader.takeByte();
            const encrypted = try reader.takeByte();
            var secret: [16]u8 = undefined;
            defer std.crypto.secureZero(u8, &secret);
            var receive: [16]u8 = undefined;
            var send: [16]u8 = undefined;
            try reader.readSliceAll(&secret);
            try reader.readSliceAll(&receive);
            try reader.readSliceAll(&send);
            if (connection.name_len == 0 or connection.name_len > 16 or compressed > 1 or encrypted > 1 or (compressed == 1) != (self.config.compression_threshold != null))
                return error.InvalidResume;
            connection.compressed = compressed == 1;

            if (encrypted == 1) {
                connection.receive_cipher = Cipher.init(secret);
                connection.receive_cipher.?.feedback = receive;
                connection.send_cipher = Cipher.init(secret);
                connection.send_cipher.?.feedback = send;
            }

            const input_len = try reader.takeInt(u32, .little);
            if (input_len != length - 91) return error.InvalidResume;

            const handle = try native.adopt(native.context, fd);
            connection.handle = handle;
            connection.input_end = input_len;
            connection.admission_deadline = std.Io.Clock.now(.awake, self.io).nanoseconds + 30 * std.time.ns_per_s;
            try reader.readSliceAll(self.input[@as(usize, handle.index) * self.config.buffer_bytes ..][0..input_len]);

            if (input_len != 0) std.log.info("event=reload_input_restored bytes={d} encrypted={}", .{ input_len, connection.receive_cipher != null });
            self.connections[handle.index] = connection;
            self.admitted += 1;
        }
    }

    /// The caller has stopped new Play output. Existing output and input loans must drain before
    /// changing the codec phase. Cipher streams stay intact.
    pub fn reconfigure(self: *Engine, handle: network.Handle) !bool {
        const connection = &self.connections[handle.index];
        assert(connection.handle != null and std.meta.eql(connection.handle.?, handle));
        assert(connection.phase == .play and connection.attached);
        if (connection.closing or connection.disconnect_deadline != null or self.stopping) return false;
        if (connection.output.len != 0 or connection.sending or connection.output_read != connection.output_write or connection.loan.load(.acquire))
            return false;

        const bytes = (try protocols.wire.play.toClient.write(self.scratch[compression.headroom..]).start_configuration()).finish();
        connection.output = try self.control(connection, bytes, &connection.control_bytes);
        connection.output_control = true;
        connection.phase = .reconfiguration_ack;
        connection.configuration_index = 0;
        connection.known = false;
        connection.keepalive = null;
        connection.admission_deadline = std.Io.Clock.now(.awake, self.io).nanoseconds + 10 * std.time.ns_per_s;
        return true;
    }

    /// The observer may release its single input loan from another thread.
    /// It must not access the payload after this call.
    pub fn releaseInput(self: *Engine, handle: network.Handle) void {
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
    pub fn sendFramed(self: *Engine, handle: network.Handle, bytes: []const u8) !void {
        if (self.stopping) return error.Closed;
        if (bytes.len == 0) return error.InvalidPacket;
        if (handle.index >= self.connections.len) return error.Closed;

        const connection = &self.connections[handle.index];
        if (connection.handle == null or !std.meta.eql(connection.handle.?, handle) or connection.closing or connection.disconnect_deadline != null or connection.phase != .play)
            return error.Closed;

        const used = connection.output_write -% connection.output_read;
        assert(used <= self.config.buffer_bytes and bytes.len <= self.config.buffer_bytes - used);
        const buffer = self.output[@as(usize, handle.index) * self.config.buffer_bytes ..][0..self.config.buffer_bytes];
        const start = connection.output_write % buffer.len;
        const first = @min(bytes.len, buffer.len - start);

        if (connection.send_cipher) |*cipher| {
            cipher.transform(.encrypt, bytes[0..first], buffer[start..][0..first]);
            cipher.transform(.encrypt, bytes[first..], buffer[0 .. bytes.len - first]);
        } else {
            @memcpy(buffer[start..][0..first], bytes[0..first]);
            @memcpy(buffer[0 .. bytes.len - first], bytes[first..]);
        }

        connection.output_write +%= bytes.len;
    }

    pub fn pump(self: *Engine, timeout: ?std.Io.Timeout) !usize {
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
                            if (connection.receive_cipher) |*cipher| {
                                const bytes = self.input[@as(usize, handle.index) * self.config.buffer_bytes + connection.input_end ..][0..result.result.bytes];
                                cipher.transform(.decrypt, bytes, bytes);
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

                            if (connection.phase == .play and !connection.output_control) {
                                connection.output_read +%= result.result.bytes;
                                self.config.observer.sent(self.config.observer.context, handle, result.result.bytes);
                            }

                            if (connection.output.len == 0) connection.output_control = false;
                        }
                    },
                    .closed => {
                        assert(!connection.receiving and !connection.sending);
                        connection.closed = true;
                        connection.closing = true;
                        std.log.info("event=session_closed connection={d}:{d} phase={s}", .{ handle.index, handle.generation, @tagName(connection.phase) });
                    },
                    .accepted => unreachable,
                }
            }
        }

        self.progress();
        try self.networking.submit(self.io);
        return count;
    }

    fn progress(self: *Engine) void {
        const now = std.Io.Clock.now(.awake, self.io).nanoseconds;

        for (self.connections, 0..) |*connection, index| {
            const handle = connection.handle orelse continue;
            assert((connection.receive_cipher == null) == (connection.send_cipher == null));
            const input = self.input[index * self.config.buffer_bytes ..][0..self.config.buffer_bytes];
            const output = self.output[index * self.config.buffer_bytes ..][0..self.config.buffer_bytes];

            if (connection.phase != .play and connection.phase != .parked and now >= connection.admission_deadline) connection.closing = true;

            if (self.reloading and !connection.attached) connection.closing = true;

            if (connection.phase == .rejected and connection.output.len == 0) connection.closing = true;
            const stopping = self.stopping or connection.disconnect_deadline != null;
            if (stopping) {
                if (connection.phase != .play or now >= (connection.disconnect_deadline orelse self.stop_deadline)) {
                    connection.closing = true;
                } else if (connection.disconnecting) {
                    if (connection.output.len == 0) connection.closing = true;
                } else if (connection.output.len == 0 and connection.output_read == connection.output_write) {
                    const message = if (self.stopping) "Server shutting down" else "Disconnected by server";
                    var component: [128]u8 = undefined;
                    component[0] = 8;
                    std.mem.writeInt(u16, component[1..3], @intCast(message.len), .big);
                    @memcpy(component[3..][0..message.len], message);
                    const packet = protocols.wire.play.toClient.write(self.scratch[compression.headroom..]).kick_disconnect() catch unreachable;
                    const bytes = (packet.reason(component[0 .. 3 + message.len]) catch unreachable).finish();
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
                    if (!connection.attached or self.config.observer.detached(self.config.observer.context, handle)) {
                        self.networking.release(self.io, handle);

                        if (connection.admitted) {
                            assert(self.admitted > 0);
                            self.admitted -= 1;
                        }

                        if (connection.receive_cipher) |*cipher| std.crypto.secureZero(u8, std.mem.asBytes(cipher));

                        if (connection.send_cipher) |*cipher| std.crypto.secureZero(u8, std.mem.asBytes(cipher));
                        connection.* = .{};
                    }
                }

                continue;
            }

            while (!stopping and connection.phase != .parked and (connection.phase == .play or connection.output.len == 0) and !connection.loan.load(.acquire)) {
                if (connection.phase == .login_success) {
                    connection.compressed = self.config.compression_threshold != null;
                    assert(!connection.admitted);
                    const maximum = self.config.max_players orelse self.config.connections;
                    assert(self.admitted <= maximum);
                    var duplicate = false;

                    for (self.connections) |*other| duplicate = duplicate or (other.admitted and other.uuid == connection.uuid);
                    if (self.admitted == maximum or duplicate) {
                        var rest = support.write_varint(self.scratch[compression.headroom..], protocols.wire.login.toClient.packetId(.disconnect)) catch unreachable;
                        rest = support.write_pstring(rest, if (duplicate) "{\"text\":\"Player is already connected\"}" else "{\"text\":\"Server is full\"}", i32) catch unreachable;
                        const bytes = self.scratch[compression.headroom .. self.scratch.len - rest.len];
                        connection.output = self.control(connection, bytes, output) catch {
                            connection.closing = true;
                            break;
                        };
                        connection.phase = .rejected;
                        break;
                    }

                    self.admitted += 1;
                    connection.admitted = true;
                    assert(self.admitted <= maximum);
                    const writer = protocols.wire.login.toClient.write(self.scratch[compression.headroom..]).success() catch unreachable;
                    const identity = writer.uuid(connection.uuid) catch unreachable;
                    const named = identity.username(connection.name[0..connection.name_len]) catch unreachable;
                    const properties = named.properties(0) catch unreachable;
                    const bytes = (properties.finish() catch unreachable).finish();
                    connection.output = self.control(connection, bytes, output) catch {
                        connection.closing = true;
                        break;
                    };
                    connection.phase = .login_ack;
                    break;
                }

                if (connection.phase == .before_ack or connection.phase == .configuring) {
                    const selected = connection.protocol.?;
                    const packets = if (connection.phase == .before_ack) selected.before_ack else if (connection.known) selected.known else selected.full;
                    if (connection.configuration_index == packets.len) {
                        connection.phase = if (connection.phase == .before_ack) .known_packs else .configuration_ack;
                        connection.configuration_index = 0;
                        continue;
                    }

                    const bytes = packets[connection.configuration_index];
                    if (bytes.len > self.scratch.len - compression.headroom) {
                        connection.closing = true;
                        break;
                    }

                    @memcpy(self.scratch[compression.headroom..][0..bytes.len], bytes);
                    connection.output = self.control(connection, self.scratch[compression.headroom..][0..bytes.len], output) catch {
                        connection.closing = true;
                        break;
                    };
                    connection.configuration_index += 1;
                    break;
                }

                if (connection.phase == .attaching) {
                    if (!self.config.observer.attached(self.config.observer.context, .{
                        .connection = handle,
                        .protocol = connection.protocol.?.number,
                        .uuid = connection.uuid,
                        .name = connection.name[0..connection.name_len],
                    }))
                        break;
                    connection.attached = true;
                    connection.phase = .play;
                    connection.keepalive_due = now + 10 * std.time.ns_per_s;
                    std.log.info("event=session_play_attached connection={d}:{d} protocol={d} player={s}", .{ handle.index, handle.generation, connection.protocol.?.number, connection.name[0..connection.name_len] });
                }

                const length, const rest = support.read_varint(input[connection.input_start..connection.input_end]) catch |err| {
                    if (err != error.EndOfStream) connection.closing = true;
                    break;
                };
                const prefix = connection.input_end - connection.input_start - rest.len;
                if (length <= 0 or prefix > 3 or length > self.config.max_packet) {
                    std.log.warn("event=session_invalid_frame connection={d}:{d} phase={s} length={d} limit={d}", .{ handle.index, handle.generation, @tagName(connection.phase), length, self.config.max_packet });
                    connection.closing = true;
                    break;
                }

                const body_len: usize = @intCast(length);
                if (rest.len < body_len) break;

                var body = rest[0..body_len];
                const decoded: []u8 = if (connection.compressed) self.decoded[index * self.config.buffer_bytes ..][0..self.config.buffer_bytes] else self.decoded[0..0];
                if (connection.compressed and connection.phase != .play) body = self.codec.?.decode(body, self.config.compression_threshold, decoded) catch {
                    connection.closing = true;
                    break;
                };

                if (connection.phase == .play) {
                    if (connection.compressed) {
                        var batch_end = connection.input_start;
                        var written: usize = 0;

                        while (batch_end < connection.input_end and decoded.len - written > 3) {
                            const n, const tail = support.read_varint(input[batch_end..connection.input_end]) catch |err| {
                                if (err != error.EndOfStream) connection.closing = true;
                                break;
                            };
                            const p = connection.input_end - batch_end - tail.len;
                            if (n <= 0 or n > self.config.max_packet or p > 3) {
                                connection.closing = true;
                                break;
                            }

                            const count: usize = @intCast(n);
                            if (tail.len < count) break;

                            const payload = self.codec.?.decode(tail[0..count], self.config.compression_threshold, decoded[written + 3 ..]) catch |err| {
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
                            batch_end += p + count;
                        }

                        if (connection.closing or written == 0) break;
                        if (!checkKeepalive(connection, decoded[0..written], now)) {
                            connection.closing = true;
                            break;
                        }

                        connection.loan.store(true, .release);
                        const disposition = self.config.observer.input(self.config.observer.context, handle, connection.protocol.?.number, decoded[0..written]);

                        if (disposition != .borrowed) connection.loan.store(false, .release);
                        if (disposition == .blocked) break;
                        connection.input_start = batch_end;
                        if (disposition == .borrowed) break;
                        continue;
                    }

                    var batch_end = connection.input_start + prefix + body_len;

                    while (batch_end < connection.input_end) {
                        const next_length, const tail = support.read_varint(input[batch_end..connection.input_end]) catch |err| {
                            if (err != error.EndOfStream) connection.closing = true;
                            break;
                        };
                        const next_prefix = connection.input_end - batch_end - tail.len;
                        if (next_length <= 0 or next_length > self.config.max_packet or next_prefix > 3) {
                            connection.closing = true;
                            break;
                        }

                        if (tail.len < next_length) break;
                        batch_end += next_prefix + @as(usize, @intCast(next_length));
                    }

                    if (connection.closing) break;
                    if (!checkKeepalive(connection, input[connection.input_start..batch_end], now)) {
                        connection.closing = true;
                        break;
                    }

                    connection.loan.store(true, .release);
                    const disposition = self.config.observer.input(self.config.observer.context, handle, connection.protocol.?.number, input[connection.input_start..batch_end]);

                    if (disposition != .borrowed) connection.loan.store(false, .release);
                    if (disposition == .blocked) break;
                    connection.input_start = batch_end;
                    if (disposition == .borrowed) break;
                    continue;
                }

                const previous = connection.phase;
                const response = advance(connection, body, self.scratch[compression.headroom..], self.config, self.io, self.admitted) catch |err| {
                    std.log.warn("event=session_packet_rejected connection={d}:{d} phase={s} bytes={d} reason={s}", .{ handle.index, handle.generation, @tagName(connection.phase), body.len, @errorName(err) });
                    connection.closing = true;
                    break;
                };

                if (connection.phase != previous)
                    std.log.debug("event=session_phase connection={d}:{d} previous={s} next={s}", .{ handle.index, handle.generation, @tagName(previous), @tagName(connection.phase) });
                connection.input_start += prefix + body_len;

                if (self.reloading and previous == .reconfiguration_ack and connection.phase == .before_ack) connection.phase = .parked;

                if (previous == .encryption_response) {
                    assert(connection.receive_cipher != null);
                    assert(connection.send_cipher != null);
                    const tail = input[connection.input_start..connection.input_end];
                    connection.receive_cipher.?.transform(.decrypt, tail, tail);
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

            if (!stopping and connection.phase == .play and now >= connection.keepalive_due) {
                if (connection.keepalive != null) {
                    connection.closing = true;
                    continue;
                }

                if (connection.output.len == 0 and connection.output_read == connection.output_write) {
                    const id: i64 = @intCast(@divTrunc(now, std.time.ns_per_ms));
                    const packet = protocols.wire.play.toClient.write(self.scratch[compression.headroom..]).keep_alive() catch unreachable;
                    const bytes = (packet.keepAliveId(id) catch unreachable).finish();
                    connection.output = self.control(connection, bytes, &connection.control_bytes) catch {
                        connection.closing = true;
                        continue;
                    };
                    connection.output_control = true;
                    connection.keepalive = id;
                    connection.keepalive_due = now + 30 * std.time.ns_per_s;
                }
            }

            if (connection.phase == .play and connection.output.len == 0) {
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

            if (stopping or connection.phase == .parked or connection.receiving or connection.loan.load(.acquire)) continue;

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

    fn control(self: *Engine, connection: *Connection, bytes: []const u8, output: []u8) ![]const u8 {
        assert(bytes.ptr == self.scratch[compression.headroom..].ptr);
        const result = if (connection.compressed and bytes.len >= self.config.compression_threshold.?)
            try self.codec.?.encode(self.scratch, bytes.len, self.config.compression_threshold, output)
        else blk: {
            const zero: usize = @intFromBool(connection.compressed);
            if (bytes.len + zero > output.len - 3) return error.BufferTooSmall;
            output[3] = 0;
            // Control scratch is shared. Transport must retain its own output until completion.
            @memcpy(output[3 + zero ..][0..bytes.len], bytes);
            break :blk framed(output, bytes.len + zero);
        };

        if (connection.send_cipher) |*cipher| cipher.transform(.encrypt, result, @constCast(result));
        return result;
    }

    fn advance(connection: *Connection, body: []const u8, output: []u8, config: Configuration, io: std.Io, online: usize) !?[]const u8 {
        switch (connection.phase) {
            .handshake => {
                const packet = try protocols.wire.handshaking.toServer.readBody(.set_protocol, try protocols.wire.handshaking.toServer.readHeader(body));
                const number, const a = try packet.protocolVersion();
                const host, const b = try a.serverHost();
                const port, const c = try b.serverPort();
                const intent, const done = try c.nextState();
                try done.finish();
                _ = port;
                if (host.len > 255) return error.BadHandshake;
                if (intent == 1) {
                    connection.protocol = &config.protocols[0];

                    for (config.protocols) |*protocol| {
                        if (protocol.number == number) {
                            connection.protocol = protocol;
                            break;
                        }

                        if (protocol.number > connection.protocol.?.number) connection.protocol = protocol;
                    }

                    connection.phase = .status;
                    return null;
                }

                if (intent != 2) return error.BadHandshake;

                for (config.protocols) |*protocol| if (protocol.number == number) {
                    connection.protocol = protocol;
                    break;
                };

                if (connection.protocol == null) return error.UnsupportedProtocol;
                connection.phase = .login;
                return null;
            },
            .status => {
                const header = try protocols.wire.status.toServer.readHeader(body);
                if (header.id == protocols.wire.status.toServer.packetId(.ping_start)) {
                    try (try protocols.wire.status.toServer.readBody(.ping_start, header)).finish();
                    var json_buffer: [32 * 1024]u8 = undefined;
                    var json = std.Io.Writer.fixed(&json_buffer);
                    try std.json.Stringify.value(.{
                        .version = .{ .name = config.status.version, .protocol = connection.protocol.?.number },
                        .players = .{ .max = config.max_players orelse config.connections, .online = online },
                        .description = .{ .text = config.status.description },
                        .favicon = config.status.favicon,
                    }, .{ .emit_null_optional_fields = false }, &json);
                    return (try (try protocols.wire.status.toClient.write(output).server_info()).response(json.buffered())).finish();
                }

                const value, const done = try (try protocols.wire.status.toServer.readBody(.ping, header)).time();
                try done.finish();
                return (try (try protocols.wire.status.toClient.write(output).ping()).time(value)).finish();
            },
            .login => {
                const packet = try protocols.wire.login.toServer.readBody(.login_start, try protocols.wire.login.toServer.readHeader(body));
                const name, const a = try packet.username();
                const uuid, const done = try a.playerUUID();
                _ = uuid;
                try done.finish();
                if (name.len == 0 or name.len > connection.name.len) return error.InvalidName;

                for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidName;
                @memset(&connection.name, 0);
                @memcpy(connection.name[0..name.len], name);
                connection.name_len = name.len;
                var hash = std.crypto.hash.Md5.init(.{});
                hash.update("OfflinePlayer:");
                hash.update(name);
                var digest: [16]u8 = undefined;
                hash.final(&digest);
                digest[6] = (digest[6] & 15) | 0x30;
                digest[8] = (digest[8] & 63) | 0x80;
                connection.uuid = std.mem.readInt(u128, &digest, .big);
                if (config.encryption) |encryption| {
                    assert(connection.receive_cipher == null and connection.send_cipher == null);
                    try io.randomSecure(&connection.verify_token);
                    var rest = try support.write_varint(output, protocols.wire.login.toClient.packetId(.encryption_begin));
                    rest = try support.write_pstring(rest, "", i32);
                    rest = try support.write_buffer_counted(rest, encryption.public_key_der, i32);
                    rest = try support.write_buffer_counted(rest, &connection.verify_token, i32);
                    rest = try support.write_bool(rest, false);
                    connection.phase = .encryption_response;
                    return output[0 .. output.len - rest.len];
                }

                connection.phase = .login_success;
                if (config.compression_threshold) |threshold|
                    return (try (try protocols.wire.login.toClient.write(output).compress()).threshold(@intCast(threshold))).finish();
                return null;
            },
            .encryption_response => {
                assert(connection.receive_cipher == null and connection.send_cipher == null);
                const id, const a = try support.read_varint(body);
                if (id != protocols.wire.login.toServer.packetId(.encryption_begin)) return error.InvalidEncryption;
                const encrypted_secret, const b = try support.read_buffer_counted(a, i32);
                const encrypted_token, const rest = try support.read_buffer_counted(b, i32);
                if (rest.len != 0 or encrypted_secret.len == 0 or encrypted_secret.len > 512 or encrypted_token.len != encrypted_secret.len)
                    return error.InvalidEncryption;

                var secret: [16]u8 = undefined;
                defer std.crypto.secureZero(u8, &secret);
                var token: [4]u8 = undefined;
                defer std.crypto.secureZero(u8, &token);
                const encryption = config.encryption.?;
                encryption.decrypt(encryption.context, io, encrypted_secret, &secret) catch return error.InvalidEncryption;
                encryption.decrypt(encryption.context, io, encrypted_token, &token) catch return error.InvalidEncryption;
                if (!std.crypto.timing_safe.eql([4]u8, token, connection.verify_token)) return error.InvalidEncryption;
                connection.receive_cipher = Cipher.init(secret);
                connection.send_cipher = Cipher.init(secret);
                connection.phase = .login_success;
                std.log.info("event=session_encrypted connection={d}:{d}", .{ connection.handle.?.index, connection.handle.?.generation });
                if (config.compression_threshold) |threshold|
                    return (try (try protocols.wire.login.toClient.write(output).compress()).threshold(@intCast(threshold))).finish();
                return null;
            },
            .login_ack => {
                try (try protocols.wire.login.toServer.readBody(.login_acknowledged, try protocols.wire.login.toServer.readHeader(body))).finish();
                connection.phase = .before_ack;
                return null;
            },
            .reconfiguration_ack => {
                const header = try protocols.wire.play.toServer.readHeader(body);
                if (header.id != protocols.wire.play.toServer.packetId(.configuration_acknowledged)) return null;
                try (try protocols.wire.play.toServer.readBody(.configuration_acknowledged, header)).finish();
                connection.phase = .before_ack;
                return null;
            },
            .known_packs => {
                const header = try protocols.wire.configuration.toServer.readHeader(body);
                if (header.id != protocols.wire.configuration.toServer.packetId(.select_known_packs)) return null;

                var packs = try (try protocols.wire.configuration.toServer.readBody(.select_known_packs, header)).packs();
                if (packs.remaining > 64) return error.BadKnownPacks;

                while (try packs.next()) |pack_cursor| {
                    const namespace, const a = try pack_cursor.namespace();
                    const id, const b = try a.id();
                    const version, const done = try b.version();
                    try packs.advance(done);
                    var offered = false;

                    for (connection.protocol.?.offered_packs) |pack| {
                        offered = offered or (std.mem.eql(u8, namespace, pack.namespace) and std.mem.eql(u8, id, pack.id) and std.mem.eql(u8, version, pack.version));
                    }

                    if (!offered) return error.BadKnownPacks;
                    connection.known = true;
                }

                try (try packs.finish()).finish();
                connection.phase = .configuring;
                return null;
            },
            .configuration_ack => {
                const header = try protocols.wire.configuration.toServer.readHeader(body);
                if (header.id != protocols.wire.configuration.toServer.packetId(.finish_configuration)) return null;
                try (try protocols.wire.configuration.toServer.readBody(.finish_configuration, header)).finish();
                connection.phase = .attaching;
                return null;
            },
            else => unreachable,
        }
    }
};

fn checkKeepalive(connection: *Engine.Connection, bytes: []const u8, now: i96) bool {
    var rest = bytes;

    while (rest.len != 0) {
        const length, const body = support.read_varint(rest) catch return false;
        if (length <= 0 or length > body.len) return false;
        const id, const payload = support.read_varint(body[0..@intCast(length)]) catch return false;
        rest = body[@intCast(length)..];
        if (id != protocols.wire.play.toServer.packetId(.keep_alive)) continue;
        if (payload.len != 8) return false;

        const value = std.mem.readInt(i64, payload[0..8], .big);
        if (connection.keepalive) |expected| {
            if (value != expected) return false;
            connection.keepalive = null;
            connection.keepalive_due = now + 10 * std.time.ns_per_s;
        }
    }

    return true;
}

fn framed(storage: []u8, length: usize) []const u8 {
    assert(length > 0 and length <= (1 << 21) - 1 and length <= storage.len - 3);
    const prefix: usize = if (length < 128) 1 else if (length < 16384) 2 else 3;
    _ = support.write_varint(storage[3 - prefix .. 3], @intCast(length)) catch unreachable;
    return storage[3 - prefix .. 3 + length];
}
