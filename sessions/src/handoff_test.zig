const std = @import("std");
const network = @import("networking");
const engine = @import("engine.zig");
const protocol = @import("protocol.zig");
const handoff = @import("handoff.zig");
const framing = @import("shared.zig");
const routes = @import("router.zig");
const decoding = @import("decoding.zig");
const Buffers = @import("buffers.zig").Buffers;
const Profiles = @import("profiles.zig").Profiles;

// The released encoding of a connection in a reload's connections list: each field is its tag,
// its length and its value, and a list ends with tag 0. New state is a new tag, so these bytes stay
// valid for every later build.
const frozen_fields =
    "\x01\x00\x04\x00\x00\x00" ++ "\x64\x00\x00\x00" ++ // descriptor 100
    "\x02\x00\x04\x00\x00\x00" ++ "\x04\x03\x00\x00" ++ // protocol 772
    "\x03\x00\x08\x00\x00\x00" ++ "\x08\x07\x06\x05\x04\x03\x02\x01" ++ // codec format
    "\x04\x00\x01\x00\x00\x00" ++ "\xcc" ++ // codec state
    "\x05\x00\x10\x00\x00\x00" ++ "\x00\xff\xee\xdd\xcc\xbb\xaa\x99\x88\x77\x66\x55\x44\x33\x22\x11" ++ // uuid
    "\x06\x00\x05\x00\x00\x00" ++ "alice" ++
    "\x07\x00\x02\x00\x00\x00" ++ "in" ++
    "\x08\x00\x03\x00\x00\x00" ++ "out";
const frozen_end = "\x00\x00\x00\x00\x00\x00";
const frozen_profile =
    "\x01\x00\x01\x00\x00\x00" ++ "\x7f" ++ // skin parts
    "\x02\x00\x03\x00\x00\x00" ++ "tex" ++
    "\x03\x00\x02\x00\x00\x00" ++ "sg" ++
    "\x04\x00\x01\x00\x00\x00" ++ "\x0c" ++ // view distance
    frozen_end;

/// A connections list holding one connection of these fields.
fn connections(comptime record: []const u8) []const u8 {
    return "\x01\x00" ++ std.mem.toBytes(std.mem.nativeToLittle(u32, record.len)) ++ record ++ frozen_end;
}

const frozen_connection = connections(frozen_fields ++ frozen_end);
const frozen_profiled_connection = connections(frozen_fields ++ "\x09\x00\x25\x00\x00\x00" ++ frozen_profile ++ frozen_end);

const Endpoint = struct {
    pub const Connection = u8;
    pub const Encryption = protocol.Encryption(Connection);
    pub const maximum_encryption_batch_size = 4;
    pub fn encryptionBatchSize(_: i32) usize {
        return maximum_encryption_batch_size;
    }

    pub fn encryptBatch(_: i32, source: []const u8, targets: []const Encryption) void {
        for (targets) |target| {
            encrypt(target.connection, source[0..target.first.len], target.first);
            encrypt(target.connection, source[target.first.len..], target.second);
        }
    }
    pub const Protocols = struct { values: [1]protocol.Protocol = .{.{ .number = 772 }} };
    pub const Workspaces = struct { failure: ?anyerror = null, framed_length: ?usize = null };
    pub fn initWorkspaces(_: std.mem.Allocator) !Workspaces {
        return .{};
    }
    pub fn deinitWorkspaces(_: *Workspaces) void {}
    pub fn needsDecoded(threshold: ?usize) bool {
        return threshold != null;
    }
    pub fn init(number: i32, intent: protocol.Handshake.Intent) !Connection {
        if (number != 772 or intent != .login) return error.UnexpectedHandshake;
        return 0xff;
    }
    pub fn save(value: *const Connection, bytes: []u8) ![]const u8 {
        bytes[0] = value.*;
        return bytes[0..1];
    }
    pub fn resumeFormat(_: *const Connection) u64 {
        return 0x0102030405060708;
    }
    pub fn restore(number: i32, format: u64, bytes: []const u8) !Connection {
        if (number != 772 or format != 0x0102030405060708 or bytes.len != 1) return error.InvalidResume;
        return bytes[0];
    }
    pub fn encrypted(value: *const Connection) bool {
        return value.* != 0xff;
    }
    pub fn compressed(value: *const Connection) bool {
        return value.* == 0xfe;
    }
    pub fn clear(_: *Connection) void {}
    pub fn send(connection: *Connection, bytes: []u8) void {
        for (bytes) |*byte| {
            byte.* ^= connection.*;
            connection.* +%= 1;
        }
    }
    pub fn encrypt(connection: *Connection, source: []const u8, destination: []u8) void {
        for (source, destination) |byte, *target| {
            target.* = byte ^ connection.*;
            connection.* +%= 1;
        }
    }
    pub fn receive(value: *Connection, bytes: []u8) void {
        if (value.* == 0xff) return;
        for (bytes) |*byte| byte.* ^= 0x5a;
    }
    pub fn frame(_: ?*const Connection, bytes: []const u8, maximum: usize) !protocol.Frame {
        const parsed = try framing.frame(bytes, maximum);
        return .{ .body = parsed.body, .length = parsed.length };
    }
    pub fn playBorrowed(_: *const Connection) bool {
        return true;
    }
    pub fn decode(_: *Connection, _: *Workspaces, bytes: []const u8, _: []u8, _: ?usize) ![]const u8 {
        return bytes;
    }
    pub const Stream = struct { connection: *Connection, bytes: []u8 };
    pub fn encryptStreams(streams: []const Stream) void {
        for (streams) |stream| send(stream.connection, stream.bytes);
    }
    pub fn sharedFrame(_: i32, workspaces: *Workspaces, storage: []u8, length: usize, _: ?usize, _: []u8) ![]const u8 {
        if (workspaces.failure) |failure| return failure;
        return storage[framing.headroom..][0 .. workspaces.framed_length orelse length];
    }
    pub const Bootstrap = struct {
        pub fn control(packet: protocol.Packet, _: []u8) !protocol.Fragments {
            return .{ .first = switch (packet) {
                .buffered => |value| value.storage[framing.headroom..][0..value.length],
                .borrowed => |bytes| bytes,
            } };
        }
    };
    pub fn control(value: *Connection, _: *Workspaces, packet: protocol.Packet, output: []u8, _: ?usize) !protocol.Fragments {
        const result = try Bootstrap.control(packet, output);
        if (encrypted(value)) send(value, @constCast(result.first));
        return result;
    }
    pub fn advance(comptime ObserverType: type, _: *Connection, event: protocol.Event, context: protocol.Context(ObserverType)) !?[]const u8 {
        switch (event) {
            .restore => context.observer.restored += 1,
            .admitted => |rejection| context.state.phase = if (rejection == null) .attaching else .rejected,
            .poll => {
                context.observer.polls += 1;
                if (context.observer.due) |due| context.poll.wakeAt(due);
                if (context.observer.configuration_remaining != 0) {
                    context.observer.configuration_remaining -= 1;
                    context.output[0] = @intCast(context.observer.configuration_remaining);
                    return context.output[0..1];
                }
            },
            .packet => |bytes| if (context.state.phase == .negotiating) {
                @memcpy(context.output[0..bytes.len], bytes);
                return context.output[0..bytes.len];
            },
            .disconnect => {
                context.observer.disconnects += 1;
                context.output[0] = 0;
                return context.output[0..1];
            },
            else => return error.UnexpectedEvent,
        }
        return null;
    }
};

const Observer = struct {
    handshakes: bool = false,
    configuration_remaining: usize = 0,
    polls: usize = 0,
    due: ?i96 = null,
    restored: usize = 0,
    sent_bytes: usize = 0,
    disconnects: usize = 0,
    payloads: [2][]const u8 = @splat(&.{}),
    pub fn closed(_: *Observer, _: network.Handle) void {}
    pub fn handshake(self: *Observer, _: []const u8) !protocol.Handshake {
        if (!self.handshakes) return error.UnexpectedHandshake;
        return .{ .protocol = 772, .intent = .login };
    }
    pub fn input(self: *Observer, handle: network.Handle, _: i32, packets: protocol.Packets) engine.Disposition {
        self.payloads[handle.index] = switch (packets) {
            .framed => |bytes| bytes,
            .packets => |values| values[0],
        };
        return .borrowed;
    }
    pub fn detached(_: *Observer, _: std.Io, _: network.Handle) bool {
        return true;
    }
    pub fn attached(_: *Observer, _: std.Io, _: protocol.Profile) bool {
        return true;
    }
    pub fn select(_: *Observer, _: protocol.Profile) routes.Route(usize) {
        return .{ .destination = 0 };
    }
    pub fn sent(self: *Observer, _: std.Io, _: network.Handle, bytes: usize) void {
        self.sent_bytes += bytes;
    }
};

const Native = struct {
    receives: [2]?[]u8 = @splat(null),
    sends: [2]?[]const u8 = @splat(null),
    send_vectors: [2][]const std.posix.iovec_const = @splat(&.{}),
    send_calls: usize = 0,
    released: usize = 0,
    send_full: bool = false,
    wake: ?*std.Io.Event = null,
    events: [2]network.Event = undefined,
    count: usize = 0,
    pub fn notify(self: *Native, io: std.Io) void {
        if (self.wake) |event| event.set(io);
    }
    pub fn queueReceive(self: *Native, _: std.Io, handle: network.Handle, bytes: []u8) network.QueueError!void {
        std.debug.assert(self.receives[handle.index] == null);
        self.receives[handle.index] = bytes;
    }
    pub fn queueSend(self: *Native, _: std.Io, handle: network.Handle, vectors: []const std.posix.iovec_const) network.QueueError!void {
        self.send_calls += 1;
        if (self.send_full) return error.Full;
        self.sends[handle.index] = vectors[0].base[0..vectors[0].len];
        self.send_vectors[handle.index] = vectors;
    }
    pub fn close(_: *Native, _: std.Io, _: network.Handle, _: network.CloseReason) void {
        unreachable;
    }
    pub fn releaseConnection(self: *Native, _: std.Io, _: network.Handle) void {
        self.released += 1;
    }
    pub fn submit(_: *Native, _: std.Io) !void {}
    pub fn poll(self: *Native, _: std.Io, _: ?std.Io.Timeout, output: []network.Event) !usize {
        @memcpy(output[0..self.count], self.events[0..self.count]);
        defer self.count = 0;
        return self.count;
    }
    fn feed(self: *Native, index: usize, bytes: []const u8) void {
        self.feedMore(index, bytes, false);
    }
    fn feedMore(self: *Native, index: usize, bytes: []const u8, more: bool) void {
        const target = self.receives[index].?;
        std.debug.assert(bytes.len <= target.len);
        @memcpy(target[0..bytes.len], bytes);
        self.receives[index] = if (more) target[bytes.len..] else null;
        self.events[self.count] = .{ .received = .{ .handle = .{ .index = index, .generation = 1 }, .result = .{ .bytes = bytes.len, .more = more } } };
        self.count += 1;
    }
    pub fn pause(_: *Native, _: std.Io, _: bool) void {}
    pub fn paused(_: *Native) bool {
        return true;
    }
    pub fn listenerDescriptor(_: *Native) i32 {
        return 99;
    }
    pub fn descriptor(_: *Native, handle: network.Handle) i32 {
        return 100 + @as(i32, @intCast(handle.index));
    }
    pub fn adopt(_: *Native, fd: i32) !network.Handle {
        if (fd < 100 or fd >= 102) return error.InvalidResume;
        return .{ .index = @intCast(fd - 100), .generation = 1 };
    }
};

test "closed play connections cannot enqueue disconnect work during shutdown" {
    const Engine = engine.Engine(Endpoint, Observer);
    const io = std.testing.io;
    for ([_]bool{ false, true }) |shutdown| {
        var native: Native = .{};
        const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
        var observer: Observer = .{};
        var catalog: Endpoint.Protocols = .{};
        const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
        defer owner.deinit();
        owner.setHandle(0, .{ .index = 0, .generation = 1 });
        const connection = &owner.connections[0];
        connection.lifecycle = 0;
        connection.protocol = &catalog.values[0];
        connection.state.phase = .play;
        connection.closed = true;
        connection.closing = true;
        if (shutdown) owner.beginShutdown(io) else {
            connection.disconnect_deadline = std.Io.Clock.now(.awake, io).nanoseconds + std.time.ns_per_s;
            owner.wakeAll();
        }
        owner.progress(io);
        try std.testing.expectEqual(@as(usize, 0), observer.disconnects);
        try std.testing.expectEqual(@as(usize, 1), native.released);
        try std.testing.expect(owner.drained());
    }
}

pub fn benchmarkSocketBatch() !void {
    const Engine = engine.Engine(Endpoint, Observer);
    const io = std.testing.io;
    var buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &buffer);
    try output.interface.writeAll("peers | packets per peer | queued sends | ring bytes\n");
    const payload = "abcdefgh";
    for ([_]usize{ 1, 2 }) |peers| for ([_]usize{ 1, 8, 32 }) |packets| {
        var native: Native = .{};
        const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
        var observer: Observer = .{};
        var catalog: Endpoint.Protocols = .{};
        const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = peers, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 8192, .output_bytes = 4096, .protocols = &catalog, .observer = &observer });
        defer {
            for (owner.connections, 0..) |*connection, index| {
                connection.receiving = false;
                connection.sending = false;
                owner.releaseBuffers(index);
                owner.setHandle(index, null);
            }
            owner.deinit();
        }
        for (owner.connections, 0..) |*connection, index| {
            owner.setHandle(index, .{ .index = @intCast(index), .generation = 1 });
            connection.protocol = &catalog.values[0];
            connection.lifecycle = 0xff;
            connection.state.phase = .play;
            for (0..packets) |_| owner.writePlay(io, connection.handle.?, payload);
        }
        // Every packet a peer has goes out in one send of its ring.
        owner.sealPlay(io);
        var queued: usize = 0;
        for (native.send_vectors[0..peers]) |vectors| {
            try std.testing.expectEqual(@as(usize, 1), vectors.len);
            queued += vectors[0].len;
        }
        try std.testing.expectEqual(peers * packets * payload.len, queued);
        try std.testing.expectEqual(peers, native.send_calls);
        try output.interface.print("{d:5} | {d:16} | {d:12} | {d}\n", .{ peers, packets, native.send_calls, queued });
    };
    try output.interface.flush();
}

pub fn benchmarkSpill() !void {
    const Engine = engine.Engine(Endpoint, Observer);
    const Probe = struct {
        threaded: std.Io.Threaded,
        vtable: std.Io.VTable,
        writes: usize = 0,
        write_limit: usize,
        fn write(raw: ?*anyopaque, file: std.Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) std.Io.File.WritePositionalError!usize {
            const threaded: *std.Io.Threaded = @ptrCast(@alignCast(raw.?));
            const self: *@This() = @fieldParentPtr("threaded", threaded);
            self.writes += 1;
            const io = self.threaded.io();
            std.debug.assert(header.len == 0 and splat == 1);
            var parts: [network.send_vectors_max * 2][]const u8 = undefined;
            var count: usize = 0;
            var remaining = self.write_limit;
            for (data) |bytes| {
                if (remaining == 0) break;
                if (bytes.len == 0) continue;
                const length = @min(remaining, bytes.len);
                parts[count] = bytes[0..length];
                count += 1;
                remaining -= length;
            }
            return io.vtable.fileWritePositional(io.userdata, file, header, parts[0..count], splat, offset);
        }
    };
    var buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(std.testing.io, &buffer);
    try output.interface.writeAll("source  | reload peers | packets per peer | write limit | positional writes | spilled bytes\n");
    for ([_]bool{ false, true }) |control| for ([_]usize{ std.math.maxInt(usize), 7 }) |limit| for ([_]usize{ 1, 2 }) |peers| for ([_]usize{ 1, 8, 32 }) |packets| {
        var probe: Probe = .{ .threaded = .init(std.testing.allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing }), .vtable = undefined, .write_limit = limit };
        defer probe.threaded.deinit();
        probe.vtable = probe.threaded.io().vtable.*;
        probe.vtable.fileWritePositional = Probe.write;
        const io: std.Io = .{ .userdata = &probe.threaded, .vtable = &probe.vtable };
        var native: Native = .{};
        const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
        var observer: Observer = .{};
        var catalog: Endpoint.Protocols = .{};
        const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = peers, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 8192, .output_bytes = 4096, .protocols = &catalog, .observer = &observer });
        const payload = "abcdefgh";
        defer {
            for (owner.connections, 0..) |*connection, index| {
                connection.receiving = false;
                connection.sending = false;
                owner.releaseBuffers(index);
                owner.setHandle(index, null);
            }
            owner.deinit();
        }
        for (owner.connections, 0..) |*connection, index| {
            owner.setHandle(index, .{ .index = @intCast(index), .generation = 1 });
            connection.protocol = &catalog.values[0];
            connection.lifecycle = 0xff;
            connection.state.phase = .play;
            if (control) {
                connection.output_control = true;
                connection.output = payload;
                connection.control_write = packets;
                @memset(connection.control_packets[0..packets], payload);
            } else {
                for (0..packets) |_| owner.writePlay(io, connection.handle.?, payload);
            }
        }
        owner.reloading = true;
        try owner.spill(io);
        var spilled: usize = 0;
        for (owner.connections) |connection| {
            const span = connection.saved_output;
            var bytes: [256]u8 = undefined;
            try std.testing.expectEqual(packets * payload.len, span.length);
            try std.testing.expectEqual(span.length, try owner.spool_file.?.readPositionalAll(io, bytes[0..span.length], span.offset));
            for (0..packets) |index| try std.testing.expectEqualSlices(u8, payload, bytes[index * payload.len ..][0..payload.len]);
            spilled += span.length;
        }
        // Control output spools as its packets, the ring in one piece.
        const writes = if (limit == 7) (packets * payload.len + 6) / 7 else if (control) (packets + std.Io.Threaded.max_iovecs_len - 1) / std.Io.Threaded.max_iovecs_len else 1;
        try std.testing.expectEqual(peers * writes, probe.writes);
        try output.interface.print("{s:7} | {d:12} | {d:16} | {d:11} | {d:17} | {d}\n", .{ if (control) "control" else "ring", peers, packets, limit, probe.writes, spilled });
    };
    try output.interface.flush();
}

test "control output goes out from its raw buffer and advances the cipher once" {
    const Engine = engine.Engine(Endpoint, Observer);
    const io = std.testing.io;
    var native: Native = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
    defer {
        owner.connections[0].receiving = false;
        owner.connections[0].sending = false;
        owner.releaseBuffers(0);
        owner.setHandle(0, null);
        owner.deinit();
    }
    const connection = &owner.connections[0];
    owner.setHandle(0, .{ .index = 0, .generation = 1 });
    connection.protocol = &catalog.values[0];
    connection.lifecycle = 7;
    connection.state.phase = .negotiating;
    connection.admission_deadline = std.Io.Clock.now(.awake, io).nanoseconds + std.time.ns_per_s;
    owner.progress(io);
    native.feed(0, &.{ 2 ^ 0x5a, 1 ^ 0x5a, 42 ^ 0x5a });
    try owner.receive(io);
    // The reply is built and encrypted on the sessions thread, in the pass that read the request.
    owner.progress(io);
    try std.testing.expectEqualSlices(u8, &.{ 1 ^ 7, 42 ^ 8 }, native.sends[0].?);
    try std.testing.expect(native.sends[0].?.ptr == connection.control_raw.?.bytes[framing.headroom..].ptr);
    try std.testing.expectEqual(@as(u8, 9), connection.lifecycle.?);
}

test "frozen sessions header preserves listener and compression encodings" {
    const listener = "\x01\x00\x04\x00\x00\x00" ++ "\x63\x00\x00\x00";
    const cases = comptime [_]struct { threshold: ?usize, bytes: []const u8 }{
        .{ .threshold = 256, .bytes = listener ++ "\x02\x00\x04\x00\x00\x00" ++ "\x00\x01\x00\x00" ++ frozen_end },
        // Uncompressed connections leave the threshold out.
        .{ .threshold = null, .bytes = listener ++ frozen_end },
    };
    inline for (cases) |case| {
        const header: handoff.Header = .{ .listener = 99, .compression_threshold = case.threshold };
        var buffer: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try header.write(&writer);
        try std.testing.expectEqualSlices(u8, case.bytes, writer.buffered());
        var reader: std.Io.Reader = .fixed(case.bytes ++ "connections");
        const restored = try handoff.Header.read(&reader);
        try std.testing.expectEqual(header.listener, restored.listener);
        try std.testing.expectEqual(header.compression_threshold, restored.compression_threshold);
        try std.testing.expectEqual(case.bytes.len, reader.seek);
    }
    // A field from a newer build is skipped; a header without a listener is refused.
    var reader: std.Io.Reader = .fixed("\x63\x00\x02\x00\x00\x00ab" ++ listener ++ frozen_end);
    try std.testing.expectEqual(@as(i32, 99), (try handoff.Header.read(&reader)).listener);
    reader = .fixed(frozen_end);
    try std.testing.expectError(error.InvalidResume, handoff.Header.read(&reader));
}

test "frozen session connection records read and write the established bytes" {
    try expectFrozenRecord(frozen_connection, false);
    try expectFrozenRecord(frozen_profiled_connection, true);
}

test "connection records skip fields from newer builds and require their identity" {
    const Engine = engine.Engine(Endpoint, Observer);
    const unknown = "\x63\x00\x05\x00\x00\x00" ++ "later";
    const cases = comptime [_]struct { bytes: []const u8, valid: bool }{
        // Unknown fields in the list, in the connection and in its profile.
        .{ .bytes = unknown ++ connections(frozen_fields ++ unknown ++ "\x09\x00\x18\x00\x00\x00" ++ unknown ++ "\x01\x00\x01\x00\x00\x00\x7f" ++ frozen_end ++ frozen_end), .valid = true },
        // Without the uuid.
        .{ .bytes = connections(frozen_fields[0..41] ++ frozen_fields[63..] ++ frozen_end), .valid = false },
    };
    inline for (cases) |case| {
        var profiles = try Profiles.init(std.testing.allocator, 1);
        defer profiles.deinit(std.testing.allocator);
        var native: Native = .{};
        const transport: network.Transport = .{ .context = &native, .vtable = undefined, .inheritance = network.Inheritance.init(Native, &native) };
        var observer: Observer = .{};
        var catalog: Endpoint.Protocols = .{};
        const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer, .profiles = &profiles });
        defer {
            owner.setHandle(0, null);
            owner.deinit();
        }
        var reader: std.Io.Reader = .fixed(case.bytes);
        if (!case.valid) {
            try std.testing.expectError(error.InvalidResume, owner.readResume(std.testing.io, &reader, null));
            continue;
        }
        try owner.readResume(std.testing.io, &reader, null);
        try std.testing.expectEqual(case.bytes.len, reader.seek);
        try std.testing.expectEqualSlices(u8, "alice", owner.connections[0].state.name[0..owner.connections[0].state.name_len]);
        try std.testing.expectEqual(@as(u8, 0x7f), profiles.get(owner.connections[0].handle.?).skin_parts);
    }
}

fn expectFrozenRecord(comptime frozen: []const u8, comptime profiled: bool) !void {
    const Engine = engine.Engine(Endpoint, Observer);
    var profiles = try Profiles.init(std.testing.allocator, 1);
    defer profiles.deinit(std.testing.allocator);
    var native: Native = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = undefined, .inheritance = network.Inheritance.init(Native, &native) };
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    const owner = try Engine.init(std.testing.allocator, transport, .{
        .connections = 1,
        .buffer_bytes = 512,
        .max_packet = 509,
        .max_pending_wire_bytes = 1024,
        .protocols = &catalog,
        .observer = &observer,
        .profiles = &profiles,
    });
    defer {
        owner.setHandle(0, null);
        owner.deinit();
    }

    var reader: std.Io.Reader = .fixed(frozen);
    try owner.readResume(std.testing.io, &reader, null);
    try std.testing.expectEqual(frozen.len, reader.seek);
    try std.testing.expectEqual(@as(usize, 1), observer.restored);
    const connection = &owner.connections[0];
    try std.testing.expectEqual(@as(i32, 772), connection.protocol.?.number);
    try std.testing.expectEqual(@as(u8, 0xcc), connection.lifecycle.?);
    try std.testing.expectEqual(@as(u128, 0x112233445566778899aabbccddeeff00), connection.state.uuid);
    try std.testing.expectEqualSlices(u8, "alice", connection.state.name[0..connection.state.name_len]);
    try std.testing.expectEqualSlices(u8, "in", owner.input[0..connection.input_end]);
    try std.testing.expectEqualSlices(u8, "out", connection.output);

    if (profiled) {
        const restored = profiles.get(connection.handle.?);
        try std.testing.expectEqual(@as(u8, 0x7f), restored.skin_parts);
        try std.testing.expectEqualStrings("tex", restored.textures().?.value);
        try std.testing.expectEqualStrings("sg", restored.textures().?.signature);
        try std.testing.expectEqual(@as(u8, 12), restored.view_distance);
    } else try std.testing.expect(profiles.get(connection.handle.?).textures() == null);

    owner.reloading = true;
    connection.parked = true;
    // What was read is written back byte for byte.
    var buffer: [frozen.len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try owner.writeResume(&writer);
    try std.testing.expectEqualSlices(u8, frozen, writer.buffered());
}

test "wire spill seals ring output and spools later output encrypted, and restores both" {
    const Engine = engine.Engine(Endpoint, Observer);
    var native: Native = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = undefined, .inheritance = network.Inheritance.init(Native, &native) };
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    const config: Engine.Configuration = .{
        .connections = 2,
        .buffer_bytes = 4096,
        .connection_bytes = 512,
        .max_packet = 4093,
        .max_pending_wire_bytes = 8192,
        .input_burst_slots = 1,
        .output_bytes = 4096,
        .configuration_slots = 1,
        .protocols = &catalog,
        .observer = &observer,
    };
    const owner = try Engine.init(std.testing.allocator, transport, config);
    defer {
        for (owner.connections, 0..) |_, index| {
            owner.releaseBuffers(index);
            owner.setHandle(index, null);
        }
        owner.deinit();
    }
    for (owner.connections, 0..) |*connection, index| {
        owner.setHandle(index, .{ .index = @intCast(index), .generation = 1 });
        connection.protocol = &catalog.values[0];
        connection.lifecycle = 7;
        connection.state = .{ .phase = .play, .uuid = index + 1, .name = @splat('a'), .name_len = 1 };
    }
    for (0..2) |index| owner.admit(index);
    const packet: [2048]u8 = @splat(42);
    // Written before the spill, so still in the ring, not yet encrypted.
    owner.writePlay(std.testing.io, owner.connections[0].handle.?, &packet);
    try std.testing.expectEqual(@as(u8, 7), owner.connections[0].lifecycle.?);
    const input = owner.input_bursts.acquire().?;
    owner.connections[0].input_burst = input;
    owner.connections[0].input_end = 1024;
    @memset(input.bytes[0..1024], 99);
    owner.reloading = true;
    try owner.spill(std.testing.io);
    // The spill encrypted the ring into the spool.
    try std.testing.expect(owner.connections[0].output_write == 0 and owner.unsealed.count == 0);
    try std.testing.expectEqual(@as(u8, 7 +% @as(u8, @truncate(2048))), owner.connections[0].lifecycle.?);
    // Written after, so straight into the spool, encrypted.
    owner.writePlay(std.testing.io, owner.connections[1].handle.?, &packet);
    try std.testing.expectEqual(@as(usize, 2048), owner.connections[1].saved_output.length);
    for (owner.connections) |*connection| connection.parked = true;
    var snapshot: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer snapshot.deinit();
    try owner.writeResume(&snapshot.writer);
    const file = owner.spool_file.?;
    const offset: u64 = 32 * 1024;
    try file.writePositionalAll(std.testing.io, snapshot.written(), offset);
    var reader_buffer: [128]u8 = undefined;
    var file_reader = file.reader(std.testing.io, &reader_buffer);
    try file_reader.seekTo(offset);
    const restored = try Engine.init(std.testing.allocator, transport, config);
    defer {
        for (restored.connections, 0..) |_, index| {
            restored.releaseBuffers(index);
            restored.setHandle(index, null);
        }
        restored.deinit();
    }
    try restored.readResume(std.testing.io, &file_reader.interface, &file_reader);
    try std.testing.expect(restored.resume_file != null and restored.spool_file == null);
    try std.testing.expect(restored.resume_file.?.handle != file.handle);
    file.close(std.testing.io);
    owner.spool_file = null;
    try std.testing.expectEqual(@as(usize, 1024), restored.connections[0].saved_input.length);
    for (restored.connections) |*connection| {
        try std.testing.expectEqual(@as(usize, 2048), connection.saved_output.length);
        try std.testing.expect(connection.control_burst == null);
        connection.parked = true;
    }
    restored.reloading = true;
    var repeated: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer repeated.deinit();
    try restored.writeResume(&repeated.writer);
    try std.testing.expectEqualSlices(u8, snapshot.written(), repeated.written());
}

test "partial encrypted input waits for burst capacity and retains borrowed bytes" {
    const Engine = engine.Engine(Endpoint, Observer);
    var native: Native = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    var memory: [128 * 1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&memory);
    const owner = try Engine.init(fixed.allocator(), transport, .{
        .connections = 2,
        .buffer_bytes = 4096,
        .connection_bytes = 512,
        .max_packet = 4093,
        .input_burst_slots = 1,
        .output_bytes = 4096,
        .max_pending_wire_bytes = 8192,
        .protocols = &catalog,
        .observer = &observer,
    });
    defer {
        for (owner.connections, 0..) |*connection, index| {
            connection.receiving = false;
            connection.loan.store(false, .release);
            owner.releaseBuffers(index);
            owner.setHandle(index, null);
        }
        owner.deinit();
    }
    const assigned = fixed.end_index;
    for (owner.connections, 0..) |*connection, index| {
        owner.setHandle(index, .{ .index = @intCast(index), .generation = 1 });
        connection.protocol = &catalog.values[0];
        connection.lifecycle = 0;
        connection.state.phase = .play;
        connection.state.uuid = index + 1;
    }
    for (0..2) |index| owner.admit(index);
    var plaintext: [1002]u8 = @splat(7);
    plaintext[0] = 0xe8;
    plaintext[1] = 0x07;
    var wire = plaintext;
    for (&wire) |*byte| byte.* ^= 0x5a;
    owner.progress(std.testing.io);
    for (owner.configurations.slots) |*slot| try std.testing.expect(slot.state.load(.acquire) & 1 == 0);
    native.feed(0, wire[0..512]);
    try owner.receive(std.testing.io);
    owner.progress(std.testing.io);
    try std.testing.expect(owner.connections[0].input_burst != null);
    native.feed(1, wire[0..512]);
    try owner.receive(std.testing.io);
    owner.progress(std.testing.io);
    try std.testing.expect(!owner.connections[1].closing and !owner.connections[1].receiving);
    try std.testing.expect(owner.connections[1].input_burst == null);
    native.feed(0, wire[512..]);
    try owner.receive(std.testing.io);
    owner.progress(std.testing.io);
    try std.testing.expect(owner.connections[0].loan.load(.acquire));
    try std.testing.expectEqualSlices(u8, &plaintext, observer.payloads[0]);
    owner.progress(std.testing.io);
    try std.testing.expect(owner.connections[0].input_burst != null);
    owner.releaseInput(std.testing.io, owner.connections[0].handle.?);
    owner.progress(std.testing.io);
    owner.progress(std.testing.io);
    try std.testing.expect(owner.connections[0].input_burst == null);
    try std.testing.expect(owner.connections[1].input_burst != null);
    native.feed(1, wire[512..]);
    try owner.receive(std.testing.io);
    owner.progress(std.testing.io);
    try std.testing.expectEqualSlices(u8, &plaintext, observer.payloads[1]);
    owner.releaseInput(std.testing.io, owner.connections[1].handle.?);
    owner.progress(std.testing.io);
    try std.testing.expect(owner.connections[1].input_burst == null);
    try std.testing.expectEqual(assigned, fixed.end_index);
}
test "decoding a plaintext batch borrows every input packet without changing either buffer" {
    const Decoding = decoding.Decoding(Endpoint);
    var workspaces: Endpoint.Workspaces = .{};
    var connection: Endpoint.Connection = 0xff;
    const bytes = "\x02\x01\x2a\x02\x01\x2b";
    var destination: [64]u8 = @splat(0xcc);
    var descriptors: [4][]const u8 = undefined;
    const result = try Decoding.decodeBatch(&workspaces, .{ .connection = &connection, .bytes = bytes, .output = &destination, .packets = &descriptors, .threshold = null, .maximum = 61 });
    var packets = result.input.?;
    const packet = (try packets.next()).?;
    try std.testing.expect(packet.ptr == bytes.ptr + 1);
    try std.testing.expectEqualStrings("\x01\x2a", packet);
    const second = (try packets.next()).?;
    try std.testing.expect(second.ptr == bytes.ptr + 4);
    try std.testing.expectEqualStrings("\x01\x2b", second);
    try std.testing.expect(try packets.next() == null);
    try std.testing.expectEqual(bytes.len, result.consumed);
    try std.testing.expect(std.mem.allEqual(u8, &destination, 0xcc));
}

test "a fragmented packet outgrows the resident buffer and retains its burst until consumed" {
    const Engine = engine.Engine(Endpoint, Observer);
    const io = std.testing.io;
    var native: Native = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    const owner = try Engine.init(std.testing.allocator, transport, .{
        .connections = 1,
        .buffer_bytes = 4096,
        .connection_bytes = 512,
        .input_burst_slots = 1,
        .max_packet = 4093,
        .max_pending_wire_bytes = 8192,
        .protocols = &catalog,
        .observer = &observer,
    });
    const connection = &owner.connections[0];
    defer {
        connection.receiving = false;
        connection.loan.store(false, .release);
        owner.releaseBuffers(0);
        owner.setHandle(0, null);
        owner.deinit();
    }
    owner.setHandle(0, .{ .index = 0, .generation = 1 });
    connection.protocol = &catalog.values[0];
    connection.lifecycle = 0xff;
    connection.state.phase = .play;
    var packet: [702]u8 = @splat(42);
    packet[0..3].* = .{ 0xbc, 5, 1 };
    owner.progress(io);
    native.feed(0, packet[0..512]);
    try owner.receive(io);
    owner.progress(io);
    const burst = connection.input_burst.?;
    try std.testing.expectEqualSlices(u8, packet[0..512], burst.bytes[0..512]);
    native.feed(0, packet[512..]);
    try owner.receive(io);
    owner.progress(io);
    try std.testing.expect(connection.loan.load(.acquire));
    try std.testing.expect(observer.payloads[0].ptr == burst.bytes.ptr);
    try std.testing.expectEqualSlices(u8, &packet, observer.payloads[0]);
    owner.releaseInput(io, connection.handle.?);
    owner.progress(io);
    try std.testing.expect(connection.input_burst == null);
    try std.testing.expect(native.receives[0].?.ptr == owner.input.ptr);
}
test "decoded batches leave an incomplete frame for when the rest arrives" {
    const Decoding = decoding.Decoding(Endpoint);
    var workspace: Endpoint.Workspaces = .{};
    var connection: Endpoint.Connection = 7;
    // Input is decrypted as it arrives, so batches decode plaintext.
    var bytes: [7]u8 = undefined;
    @memcpy(bytes[0..5], "\x02ab\x03q");
    var output: [16]u8 = undefined;
    var packets: [8][]const u8 = undefined;
    const first = try Decoding.decodeBatch(&workspace, .{ .connection = &connection, .bytes = bytes[0..5], .output = &output, .packets = &packets, .threshold = 256, .maximum = 16 });
    try std.testing.expectEqual(@as(usize, 3), first.consumed);
    try std.testing.expectEqualStrings("ab", first.input.?.packets[0]);
    bytes[5] = 'r';
    bytes[6] = 's';
    const second = try Decoding.decodeBatch(&workspace, .{ .connection = &connection, .bytes = bytes[3..], .output = &output, .packets = &packets, .threshold = 256, .maximum = 16 });
    try std.testing.expectEqual(@as(usize, 4), second.consumed);
    try std.testing.expectEqualStrings("qrs", second.input.?.packets[0]);
    bytes[0] = 3;
    const partial = try Decoding.decodeBatch(&workspace, .{ .connection = &connection, .bytes = bytes[0..1], .output = &output, .packets = &packets, .threshold = 256, .maximum = 16 });
    try std.testing.expectEqual(@as(usize, 0), partial.consumed);
    try std.testing.expectEqual(@as(usize, 0), partial.input.?.packets.len);
}
test "wrapped output submits both ring spans and resumes after a partial send" {
    const Engine = engine.Engine(Endpoint, Observer);
    const io = std.testing.io;
    var native: Native = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .output_bytes = 4096, .protocols = &catalog, .observer = &observer });
    defer {
        owner.connections[0].receiving = false;
        owner.connections[0].sending = false;
        owner.releaseBuffers(0);
        owner.setHandle(0, null);
        owner.deinit();
    }
    const connection = &owner.connections[0];
    const handle: network.Handle = .{ .index = 0, .generation = 1 };
    owner.setHandle(handle.index, handle);
    connection.protocol = &catalog.values[0];
    connection.lifecycle = 0xff;
    connection.state.phase = .play;
    connection.output_read = 4084;
    connection.output_sealed = 4084;
    connection.output_write = 4084;
    owner.writePlay(io, handle, "abcdefghijklmnopqrst");
    // Nothing goes out before it is sealed.
    owner.progress(io);
    try std.testing.expectEqual(@as(usize, 0), native.send_calls);
    owner.sealPlay(io);
    try std.testing.expectEqual(@as(usize, 2), native.send_vectors[0].len);
    try std.testing.expectEqualSlices(u8, "abcdefghijkl", native.send_vectors[0][0].base[0..native.send_vectors[0][0].len]);
    try std.testing.expectEqualSlices(u8, "mnopqrst", native.send_vectors[0][1].base[0..native.send_vectors[0][1].len]);
    native.events[0] = .{ .sent = .{ .handle = handle, .result = .{ .bytes = 15 } } };
    native.count = 1;
    try owner.receive(io);
    owner.progress(io);
    try std.testing.expectEqual(@as(usize, 1), native.send_vectors[0].len);
    try std.testing.expectEqualStrings("pqrst", native.sends[0].?);
    try std.testing.expectEqual(@as(usize, 4099), connection.output_read);
    try std.testing.expectEqual(@as(usize, 15), observer.sent_bytes);
}

test "sealing encrypts every byte once, in order, wherever the ring wraps" {
    const Engine = engine.Engine(Endpoint, Observer);
    const io = std.testing.io;
    const packets = [_][]const u8{ "header-", "payload", "-and-more" };
    var plaintext: [packets[0].len + packets[1].len + packets[2].len]u8 = undefined;
    var length: usize = 0;
    for (packets) |packet| {
        @memcpy(plaintext[length..][0..packet.len], packet);
        length += packet.len;
    }
    var expected: [plaintext.len]u8 = undefined;
    var continuous: Endpoint.Connection = 3;
    Endpoint.encrypt(&continuous, &plaintext, &expected);
    for (0..plaintext.len + 1) |wrap| {
        var native: Native = .{};
        const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
        var observer: Observer = .{};
        var catalog: Endpoint.Protocols = .{};
        const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .output_bytes = 4096, .protocols = &catalog, .observer = &observer });
        defer {
            owner.connections[0].receiving = false;
            owner.connections[0].sending = false;
            owner.releaseBuffers(0);
            owner.setHandle(0, null);
            owner.deinit();
        }
        const connection = &owner.connections[0];
        const handle: network.Handle = .{ .index = 0, .generation = 1 };
        owner.setHandle(handle.index, handle);
        connection.protocol = &catalog.values[0];
        connection.lifecycle = 3;
        connection.state.phase = .play;
        const start = 4096 - wrap;
        connection.output_read = start;
        connection.output_sealed = start;
        connection.output_write = start;
        for (packets) |packet| owner.writePlay(io, handle, packet);
        owner.sealPlay(io);
        var actual: [plaintext.len]u8 = undefined;
        for (&actual, 0..) |*byte, offset| byte.* = owner.output[(start + offset) % 4096];
        try std.testing.expectEqualSlices(u8, &expected, &actual);
        try std.testing.expectEqual(continuous, connection.lifecycle.?);
        try std.testing.expectEqual(connection.output_write, connection.output_sealed);
    }
}

test "the ring and the spool keep their own copy of output whose source is reused" {
    const Engine = engine.Engine(Endpoint, Observer);
    const io = std.testing.io;
    for ([_]enum { plain, encrypted, spool }{ .plain, .encrypted, .spool }) |mode| {
        var native: Native = .{};
        var observer: Observer = .{};
        var catalog: Endpoint.Protocols = .{};
        const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
        const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .output_bytes = 4096, .protocols = &catalog, .observer = &observer });
        defer {
            owner.connections[0].sending = false;
            owner.connections[0].receiving = false;
            owner.releaseBuffers(0);
            owner.setHandle(0, null);
            owner.deinit();
        }
        const connection = &owner.connections[0];
        const handle: network.Handle = .{ .index = 0, .generation = 1 };
        owner.setHandle(handle.index, handle);
        connection.protocol = &catalog.values[0];
        connection.lifecycle = if (mode == .plain) 0xff else 0;
        connection.state.phase = .play;
        connection.spooling = mode == .spool;
        const expected = "HDpayload";
        var wire = expected.*;
        owner.writePlay(io, handle, &wire);
        @memset(&wire, 255);
        var encrypted: [expected.len]u8 = expected.*;
        if (mode != .plain) {
            var cipher: Endpoint.Connection = 0;
            Endpoint.encrypt(&cipher, expected, &encrypted);
        }
        var actual: [expected.len]u8 = undefined;
        switch (mode) {
            .plain, .encrypted => {
                owner.sealPlay(io);
                @memcpy(&actual, owner.output[0..expected.len]);
            },
            .spool => {
                try std.testing.expectEqual(expected.len, connection.saved_output.length);
                try std.testing.expectEqual(actual.len, try owner.spool_file.?.readPositionalAll(io, &actual, connection.saved_output.offset));
            },
        }
        try std.testing.expectEqualSlices(u8, &encrypted, &actual);
    }
}

test "network progress only revisits signaled or due connections" {
    const Engine = engine.Engine(Endpoint, Observer);
    for ([_]usize{ 32, 4096 }) |capacity| {
        var native: Native = .{};
        var observer: Observer = .{};
        var catalog: Endpoint.Protocols = .{};
        const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
        const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = capacity, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
        defer owner.deinit();
        for (0..128) |_| owner.progress(std.testing.io);
        try std.testing.expect(owner.drained());
        for ([_]usize{ 0, capacity - 1 }) |index| {
            owner.setHandle(index, .{ .index = @intCast(index), .generation = 1 });
            owner.connections[index].protocol = &catalog.values[0];
            owner.connections[index].lifecycle = 0xff;
            owner.connections[index].state.phase = .parked;
        }
        try std.testing.expectEqual(@as(usize, 2), owner.active_count);
        owner.progress(std.testing.io);
        for (0..128) |_| {
            try std.testing.expectEqual(@as(?i96, null), owner.readiness.deadline(0));
            owner.progress(std.testing.io);
        }
        owner.setHandle(0, null);
        try std.testing.expectEqual(capacity - 1, owner.active_head.?);
        try std.testing.expectEqual(owner.active_head, owner.active_tail);
        owner.setHandle(0, .{ .index = 0, .generation = 2 });
        try std.testing.expectEqual(@as(usize, 2), owner.active_count);
        try std.testing.expectEqual(@as(usize, 0), owner.active_tail.?);
        owner.setHandle(capacity - 1, null);
        owner.setHandle(0, null);
        try std.testing.expect(owner.drained());
    }
}

test "idle play connections retain timers without protocol polls on unrelated wakeups" {
    const Engine = engine.Engine(Endpoint, Observer);
    const io = std.testing.io;
    for ([_]usize{ 1, 32, 256, 4096 }) |capacity| for ([_]bool{ false, true }) |timed| {
        var native: Native = .{};
        var observer: Observer = .{};
        var catalog: Endpoint.Protocols = .{};
        const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
        const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = capacity, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
        defer owner.deinit();
        defer for (owner.connections, 0..) |*connection, index| {
            connection.receiving = false;
            owner.releaseBuffers(index);
            owner.setHandle(index, null);
        };
        if (timed) observer.due = std.Io.Clock.now(.awake, io).nanoseconds + 10 * std.time.ns_per_s;
        for (owner.connections, 0..) |*connection, index| {
            owner.setHandle(index, .{ .index = @intCast(index), .generation = 1 });
            connection.protocol = &catalog.values[0];
            connection.lifecycle = 0xff;
            connection.state.phase = .play;
            connection.receiving = true;
        }
        owner.progress(io);
        try std.testing.expectEqual(capacity, observer.polls);
        observer.polls = 0;
        for (0..64) |_| owner.progress(io);
        try std.testing.expectEqual(@as(usize, 0), observer.polls);
        try std.testing.expectEqual(observer.due, owner.poll.deadline);
        const last = capacity - 1;
        owner.readiness.signal(last).notify();
        owner.progress(io);
        try std.testing.expectEqual(@as(usize, 1), observer.polls);
        const expired = std.Io.Clock.now(.awake, io).nanoseconds - 1;
        owner.connections[last].poll.deadline = expired;
        owner.readiness.update(last, expired);
        owner.progress(io);
        try std.testing.expectEqual(@as(usize, 2), observer.polls);
        try std.testing.expectEqual(observer.due, owner.poll.deadline);
    };
}

test "multishot ciphertext arriving while input is lent is decrypted exactly once" {
    const Engine = engine.Engine(Endpoint, Observer);
    const io = std.testing.io;
    var native: Native = .{};
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
    defer owner.deinit();
    const connection = &owner.connections[0];
    defer {
        connection.receiving = false;
        connection.loan.store(false, .release);
        owner.releaseBuffers(0);
        owner.setHandle(0, null);
    }
    owner.setHandle(0, .{ .index = 0, .generation = 1 });
    connection.protocol = &catalog.values[0];
    connection.lifecycle = 0;
    connection.state.phase = .play;
    owner.progress(io);
    // A frame split across two receives is decrypted as each piece arrives.
    native.feedMore(0, "\x58\x5b", true);
    try owner.receive(io);
    owner.progress(io);
    try std.testing.expectEqualSlices(u8, "\x02\x01", owner.input[0..connection.input_end]);
    native.feedMore(0, "\x70", true);
    try owner.receive(io);
    owner.progress(io);
    try std.testing.expect(connection.receiving and connection.loan.load(.acquire));
    try std.testing.expectEqualSlices(u8, "\x02\x01\x2a", observer.payloads[0]);
    const borrowed = observer.payloads[0];
    // More arrives while the first is lent: it is decrypted once, after what is lent.
    native.feedMore(0, "\x58\x5b\x71", true);
    try owner.receive(io);
    owner.progress(io);
    try std.testing.expectEqualSlices(u8, "\x02\x01\x2a", borrowed);
    try std.testing.expect(borrowed.ptr == observer.payloads[0].ptr);
    owner.releaseInput(io, connection.handle.?);
    owner.progress(io);
    try std.testing.expectEqualSlices(u8, "\x02\x01\x2b", observer.payloads[0]);
    try std.testing.expect(connection.receiving);
}

test "reload drains ciphertext without waiting for a gameplay decode buffer" {
    const Engine = engine.Engine(Endpoint, Observer);
    const io = std.testing.io;
    var native: Native = .{};
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 1, .decode_slots = 1, .compression_threshold = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
    defer owner.deinit();
    const held = owner.decoded.acquire().?;
    defer held.release();
    const connection = &owner.connections[0];
    defer {
        connection.receiving = false;
        connection.loan.store(false, .release);
        owner.releaseBuffers(0);
        owner.setHandle(0, null);
    }
    owner.setHandle(0, .{ .index = 0, .generation = 1 });
    connection.protocol = &catalog.values[0];
    connection.lifecycle = 0xfe;
    connection.state.phase = .play;
    connection.decode_large = true;
    owner.progress(io);
    native.feedMore(0, "\x58\x5b\x70", true);
    try owner.receive(io);
    owner.progress(io);
    // Decrypted as it arrived, while decoding waits for the buffer someone else holds.
    try std.testing.expect(connection.waiting == .decoded);
    try std.testing.expectEqualSlices(u8, "\x02\x01\x2a", owner.input[0..connection.input_end]);
    owner.reloading = true;
    connection.attached = true;
    owner.wakeAll();
    owner.progress(io);
    try std.testing.expectEqualSlices(u8, "\x02\x01\x2a", owner.input[0..connection.input_end]);
    try std.testing.expectEqual(@as(usize, 0), observer.payloads[0].len);
}

test "admission identities reject duplicates and return capacity on slot release" {
    const Engine = engine.Engine(Endpoint, Observer);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var native: Native = .{};
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    const owner = try Engine.init(failing.allocator(), transport, .{ .connections = 2, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
    defer {
        for (owner.connections, 0..) |*connection, index| {
            connection.receiving = false;
            owner.releaseBuffers(index);
            owner.setHandle(index, null);
        }
        owner.deinit();
    }
    failing.fail_index = failing.alloc_index;
    for (owner.connections, 0..) |*connection, index| {
        owner.setHandle(index, .{ .index = index, .generation = 1 });
        connection.state = .{ .phase = if (index == 0) .play else .admitting, .uuid = 123 };
        connection.protocol = &catalog.values[0];
        connection.lifecycle = 0xff;
        connection.receiving = true;
        connection.admission_deadline = std.math.maxInt(i96);
    }
    owner.admit(0);
    owner.progress(std.testing.io);
    try std.testing.expectEqual(.rejected, owner.connections[1].state.phase);
    try std.testing.expectEqual(@as(usize, 1), owner.admitted);
    try std.testing.expectEqual(@as(usize, 0), owner.identities.get(123).?);
    owner.setHandle(0, null);
    try std.testing.expectEqual(@as(usize, 0), owner.identities.count());
    owner.connections[1].state.phase = .admitting;
    owner.readiness.signal(1).notify();
    owner.progress(std.testing.io);
    try std.testing.expectEqual(.attaching, owner.connections[1].state.phase);
    try std.testing.expectEqual(@as(usize, 1), owner.identities.get(123).?);
    try std.testing.expectEqual(@as(usize, 1), owner.admitted);
}

test "resume rejects duplicate identities and preserves ownership of preceding records" {
    const Engine = engine.Engine(Endpoint, Observer);
    var native: Native = .{};
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native), .inheritance = network.Inheritance.init(Native, &native) };
    const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 2, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
    defer {
        for (0..2) |index| {
            owner.releaseBuffers(index);
            owner.setHandle(index, null);
        }
        owner.deinit();
    }
    // Two connections with the same uuid on different sockets.
    const first = comptime connections(frozen_fields ++ frozen_end);
    const second = comptime connections("\x01\x00\x04\x00\x00\x00" ++ "\x65\x00\x00\x00" ++ frozen_fields[10..] ++ frozen_end);
    var reader: std.Io.Reader = .fixed(first[0 .. first.len - frozen_end.len] ++ second);
    try std.testing.expectError(error.InvalidResume, owner.readResume(std.testing.io, &reader, null));
    try std.testing.expectEqual(@as(usize, 1), owner.admitted);
    try std.testing.expectEqual(@as(usize, 1), owner.identities.count());
    try std.testing.expectEqual(@as(usize, 0), owner.identities.get(owner.connections[0].state.uuid).?);
}

/// Puts a whole play frame in a connection's resident input, as if it had arrived and been
/// decrypted, and marks it receiving so the engine queues no receive for it.
fn pendFrame(owner: anytype, index: usize, frame: []const u8) void {
    const stride = @min(owner.config.connection_bytes, owner.config.buffer_bytes);
    @memcpy(owner.input[index * stride ..][0..frame.len], frame);
    owner.connections[index].input_end = frame.len;
    owner.connections[index].receiving = true;
}

test "exhausted decode pools retain waiters and wake only available capacity" {
    const Engine = engine.Engine(Endpoint, Observer);
    const io = std.testing.io;
    var native: Native = .{};
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 64, .decode_slots = 1, .compression_threshold = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
    defer owner.deinit();
    defer for (owner.connections, 0..) |*connection, index| {
        connection.receiving = false;
        connection.sending = false;
        connection.loan.store(false, .release);
        owner.releaseBuffers(index);
        owner.setHandle(index, null);
    };
    var held: ?Buffers.Lease = owner.decoded.acquire().?;
    defer if (held) |lease| lease.release();
    for (owner.connections, 0..) |*connection, index| {
        owner.setHandle(index, .{ .index = index, .generation = 1 });
        connection.protocol = &catalog.values[0];
        connection.lifecycle = 0xfe;
        connection.state.phase = .play;
        connection.decode_large = true;
        pendFrame(owner, index, "\x02\x01\x2a");
    }
    for (0..64) |_| owner.progress(io);
    for (owner.connections) |connection| try std.testing.expect(connection.waiting == .decoded);
    try std.testing.expectEqual(@as(usize, 0), observer.payloads[0].len);
    held.?.release();
    held = null;
    owner.progress(io);
    // The one buffer went to one waiter, which decoded and lent its input; the rest still wait.
    try std.testing.expect(owner.connections[0].loan.load(.acquire));
    try std.testing.expectEqualSlices(u8, "\x02\x01\x2a", observer.payloads[0]);
    for (0..64) |_| owner.progress(io);
    for (owner.connections[1..]) |connection| try std.testing.expect(connection.waiting == .decoded);
}

test "transport capacity wakes outbound delivery while inbound decoding stays blocked" {
    const Engine = engine.Engine(Endpoint, Observer);
    const io = std.testing.io;
    var native: Native = .{ .send_full = true };
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 1, .decode_slots = 1, .compression_threshold = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
    defer owner.deinit();
    defer {
        const connection = &owner.connections[0];
        connection.receiving = false;
        connection.sending = false;
        owner.releaseBuffers(0);
        owner.setHandle(0, null);
    }
    const held = owner.decoded.acquire().?;
    defer held.release();
    owner.setHandle(0, .{ .index = 0, .generation = 1 });
    const connection = &owner.connections[0];
    connection.protocol = &catalog.values[0];
    connection.lifecycle = 0xfe;
    connection.state.phase = .play;
    connection.decode_large = true;
    pendFrame(owner, 0, "\x02\x01\x2a");
    connection.output_sealed = 10;
    connection.output_write = 10;
    @memset(owner.output[0..10], 17);
    owner.progress(io);
    try std.testing.expect(connection.waiting == .decoded);
    try std.testing.expectEqual(@as(usize, 1), owner.transport_waiting.count);
    try std.testing.expectEqual(@as(usize, 1), native.send_calls);
    owner.progress(io);
    try std.testing.expectEqual(@as(usize, 1), native.send_calls);
    native.send_full = false;
    try owner.receive(io);
    owner.progress(io);
    try std.testing.expectEqual(@as(usize, 2), native.send_calls);
    try std.testing.expect(connection.sending and connection.waiting == .decoded);
    try std.testing.expectEqual(@as(usize, 0), observer.payloads[0].len);
}

test "resident decode capacity remains available when every shared decode buffer is held" {
    const Engine = engine.Engine(Endpoint, Observer);
    const io = std.testing.io;
    var native: Native = .{};
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 2, .decode_slots = 1, .compression_threshold = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
    defer owner.deinit();
    defer for (owner.connections, 0..) |*connection, index| {
        connection.receiving = false;
        connection.sending = false;
        connection.loan.store(false, .release);
        owner.releaseBuffers(index);
        owner.setHandle(index, null);
    };
    const held = owner.decoded.acquire().?;
    defer held.release();
    for (owner.connections, 0..) |*connection, index| {
        owner.setHandle(index, .{ .index = index, .generation = 1 });
        connection.protocol = &catalog.values[0];
        connection.lifecycle = 0xfe;
        connection.state.phase = .play;
        pendFrame(owner, index, "\x02\x01\x2a");
    }
    owner.progress(io);
    // Small packets need no shared decode buffer, so both are lent while it is held.
    for (owner.connections, 0..) |connection, index| {
        try std.testing.expect(connection.decoded == null);
        try std.testing.expect(connection.loan.load(.acquire));
        try std.testing.expectEqualSlices(u8, "\x02\x01\x2a", observer.payloads[index]);
    }
}

test "decode retry asks for a larger output and leaves the input whole" {
    const Decoder = struct {
        pub const Connection = usize;
        pub const Workspaces = struct {};
        pub fn frame(_: *Connection, bytes: []const u8, maximum: usize) !protocol.Frame {
            const value = try framing.frame(bytes, maximum);
            return .{ .body = value.body, .length = value.length };
        }
        pub fn decode(_: *Connection, _: *Workspaces, bytes: []const u8, output: []u8, _: ?usize) ![]const u8 {
            if (bytes.len > output.len) return error.BufferTooSmall;
            @memcpy(output[0..bytes.len], bytes);
            return output[0..bytes.len];
        }
    };
    const Decoding = decoding.Decoding(Decoder);
    var connection: Decoder.Connection = 0;
    var workspace: Decoder.Workspaces = .{};
    const bytes = [_]u8{ 3, 'a', 'b', 'c' };
    var small: [1]u8 = undefined;
    var large: [3]u8 = undefined;
    var packets: [1][]const u8 = undefined;
    const pending = try Decoding.decodeBatch(&workspace, .{ .connection = &connection, .bytes = &bytes, .output = &small, .packets = &packets, .threshold = null, .maximum = 512 });
    try std.testing.expect(pending.needs_output and pending.consumed == 0);
    const complete = try Decoding.decodeBatch(&workspace, .{ .connection = &connection, .bytes = &bytes, .output = &large, .packets = &packets, .threshold = null, .maximum = 512 });
    try std.testing.expect(!complete.needs_output);
    try std.testing.expectEqual(@as(usize, 4), complete.consumed);
    try std.testing.expectEqualStrings("abc", complete.input.?.packets[0]);
    const pending_single = try Decoding.decode(&workspace, .{ .connection = &connection, .bytes = "abc", .output = &small, .threshold = null });
    try std.testing.expect(pending_single.needs_output);
    const complete_single = try Decoding.decode(&workspace, .{ .connection = &connection, .bytes = "abc", .output = &large, .threshold = null });
    try std.testing.expect(!complete_single.needs_output);
    try std.testing.expectEqualStrings("abc", complete_single.bytes);
}

test "coalesced handshake and login wait for both control leases before consuming login" {
    const Engine = engine.Engine(Endpoint, Observer);
    const io = std.testing.io;
    for ([_]bool{ false, true }) |hold_raw| {
        var native: Native = .{};
        var observer: Observer = .{ .handshakes = true };
        var catalog: Endpoint.Protocols = .{};
        const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
        const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 1, .configuration_slots = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
        defer owner.deinit();
        defer {
            owner.connections[0].receiving = false;
            owner.connections[0].sending = false;
            owner.releaseBuffers(0);
            owner.setHandle(0, null);
        }
        const held = if (hold_raw) owner.control_raw.acquire().? else owner.configurations.acquire().?;
        var released = false;
        defer if (!released) held.release();
        owner.setHandle(0, .{ .index = 0, .generation = 1 });
        const connection = &owner.connections[0];
        connection.receiving = true;
        connection.admission_deadline = std.math.maxInt(i96);
        @memcpy(owner.input[0..4], "\x01h\x01a");
        connection.input_end = 4;
        owner.progress(io);
        try std.testing.expectEqual(.negotiating, connection.state.phase);
        try std.testing.expectEqual(@as(usize, 2), connection.input_start);
        try std.testing.expectEqual(@as(usize, 0), observer.polls);
        try std.testing.expect(!connection.closing and connection.control_burst == null);
        try std.testing.expect(connection.control_raw == null);
        held.release();
        released = true;
        owner.progress(io);
        try std.testing.expect(observer.polls != 0);
        try std.testing.expectEqual(connection.input_end, connection.input_start);
        try std.testing.expect(connection.sending and !connection.closing);
    }
}
