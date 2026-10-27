const std = @import("std");
const network = @import("networking");
const engine = @import("engine.zig");
const protocol = @import("protocol.zig");
const handoff = @import("handoff.zig");
const framing = @import("shared.zig");
const routes = @import("router.zig");
const packet_codec = @import("codec.zig");
const Buffers = @import("buffers.zig").Buffers;
const packet_output = @import("output.zig");

const Gate = struct {
    started: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
};

const frozen_connection = "\x01\x00\x00\x00" ++
    "\x64\x00\x00\x00\x01\x00\x00\x00\x3f\x00\x00\x00" ++
    "\x04\x03\x00\x00\x08\x07\x06\x05\x04\x03\x02\x01\x01\x00\x00\x00\xcc" ++
    "\x00\xff\xee\xdd\xcc\xbb\xaa\x99\x88\x77\x66\x55\x44\x33\x22\x11" ++
    "\x05alice\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++
    "\x02\x00\x00\x00in\x03\x00\x00\x00out";

const Endpoint = struct {
    pub const Connection = u8;
    pub const Protocols = struct { values: [1]protocol.Protocol = .{.{ .number = 772 }} };
    pub const Workspaces = struct { gate: ?*Gate = null, gate_byte: ?u8 = null, framed_length: ?usize = null };
    pub fn initWorkspaces(_: std.mem.Allocator) !Workspaces {
        return .{};
    }
    pub fn deinitWorkspaces(_: *Workspaces) void {}
    pub fn needsDecoded(threshold: ?usize) bool {
        return threshold != null;
    }
    pub fn init(_: i32, _: protocol.Handshake.Intent) !Connection {
        return error.UnexpectedHandshake;
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
    pub fn sharedFrame(_: i32, workspaces: *Workspaces, storage: []u8, length: usize, _: ?usize, _: []u8) ![]const u8 {
        if (workspaces.gate) |gate| {
            if (workspaces.gate_byte == null or storage[framing.headroom] == workspaces.gate_byte.?) {
                gate.started.set(std.testing.io);
                gate.release.waitUncancelable(std.testing.io);
            }
        }
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
    configuration_remaining: usize = 0,
    polls: usize = 0,
    due: ?i96 = null,
    restored: usize = 0,
    sent_bytes: usize = 0,
    disconnects: usize = 0,
    payloads: [2][]const u8 = @splat(&.{}),
    pub fn closed(_: *Observer, _: network.Handle) void {}
    pub fn handshake(_: *Observer, _: []const u8) !protocol.Handshake {
        return error.UnexpectedHandshake;
    }
    pub fn input(self: *Observer, handle: network.Handle, _: i32, packets: protocol.Packets) engine.Disposition {
        self.payloads[handle.index] = switch (packets) {
            .framed => |bytes| bytes,
            .packets => |values| values[0],
        };
        return .borrowed;
    }
    pub fn detached(_: *Observer, _: network.Handle) bool {
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
    const Codec = packet_codec.Codec(Endpoint);
    const io = std.testing.io;
    for ([_]bool{ false, true }) |shutdown| {
        var native: Native = .{};
        const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
        var observer: Observer = .{};
        var catalog: Endpoint.Protocols = .{};
        const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
        defer owner.deinit();
        const codec = try Codec.init(std.testing.allocator, io, transport, 1, null);
        defer codec.deinit();
        try owner.attachCodec(codec);
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
        try std.testing.expectEqual(@as(usize, 0), codec.write.load(.acquire));
        try std.testing.expect(owner.drained());
    }
}

pub fn benchmarkSocketBatch() !void {
    const Engine = engine.Engine(Endpoint, Observer);
    const io = std.testing.io;
    var buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &buffer);
    try output.interface.writeAll("peers | packets per peer | queued sends | borrowed payload bytes\n");
    for ([_]usize{ 1, 2 }) |peers| for ([_]usize{ 1, 8, 32 }) |packets| {
        var native: Native = .{};
        const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
        var observer: Observer = .{};
        var catalog: Endpoint.Protocols = .{};
        const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = peers, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 8192, .protocols = &catalog, .observer = &observer });
        var budget: packet_output.SocketBudget = .init(2);
        var loan: Engine.Loan = .{ .payload = "abcdefgh", .references = 1 };
        defer {
            for (owner.connections, 0..) |*connection, index| {
                connection.receiving = false;
                connection.sending = false;
                owner.releaseBuffers(index);
                owner.setHandle(index, null);
            }
            owner.deinit();
            std.debug.assert(loan.references == 1 and budget.used == 0);
        }
        for (owner.connections, 0..) |*connection, index| {
            owner.setHandle(index, .{ .index = @intCast(index), .generation = 1 });
            connection.protocol = &catalog.values[0];
            connection.lifecycle = 0xff;
            connection.state.phase = .play;
            for (0..packets) |_| try owner.sendFramed(io, connection.handle.?, &loan, .{ .sockets = &budget });
        }
        owner.progress(io);
        var borrowed: usize = 0;
        for (native.send_vectors[0..peers]) |vectors| {
            try std.testing.expectEqual(packets, vectors.len);
            for (vectors) |vector| {
                try std.testing.expect(vector.base == loan.payload.ptr and vector.len == loan.payload.len);
                borrowed += vector.len;
            }
        }
        try std.testing.expectEqual(peers * packets * loan.payload.len, borrowed);
        try output.interface.print("{d:5} | {d:16} | {d:12} | {d}\n", .{ peers, packets, native.send_calls, borrowed });
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
        const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = peers, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 8192, .protocols = &catalog, .observer = &observer });
        var budget: packet_output.SocketBudget = .init(2);
        var loan: Engine.Loan = .{ .payload = "abcdefgh", .references = 1 };
        defer {
            for (owner.connections, 0..) |*connection, index| {
                connection.receiving = false;
                connection.sending = false;
                owner.releaseBuffers(index);
                owner.setHandle(index, null);
            }
            owner.deinit();
            std.debug.assert(loan.references == 1 and budget.used == 0);
        }
        for (owner.connections, 0..) |*connection, index| {
            owner.setHandle(index, .{ .index = @intCast(index), .generation = 1 });
            connection.protocol = &catalog.values[0];
            connection.lifecycle = 0xff;
            connection.state.phase = .play;
            if (control) {
                connection.output_control = true;
                connection.output = loan.payload;
                connection.control_write = packets;
                @memset(connection.control_packets[0..packets], loan.payload);
            } else {
                for (0..packets) |_| try owner.sendFramed(io, connection.handle.?, &loan, .{ .sockets = &budget });
            }
        }
        owner.reloading = true;
        try owner.spill(io);
        var spilled: usize = 0;
        for (owner.connections) |connection| {
            const span = connection.saved_output;
            var bytes: [256]u8 = undefined;
            try std.testing.expectEqual(packets * loan.payload.len, span.length);
            try std.testing.expectEqual(span.length, try owner.spool_file.?.readPositionalAll(io, bytes[0..span.length], span.offset));
            for (0..packets) |index| try std.testing.expectEqualSlices(u8, loan.payload, bytes[index * loan.payload.len ..][0..loan.payload.len]);
            spilled += span.length;
        }
        try std.testing.expectEqual(@as(usize, 1), loan.references);
        const writes = if (limit == 7) (packets * loan.payload.len + 6) / 7 else (packets + std.Io.Threaded.max_iovecs_len - 1) / std.Io.Threaded.max_iovecs_len;
        try std.testing.expectEqual(peers * writes, probe.writes);
        try output.interface.print("{s:7} | {d:12} | {d:16} | {d:11} | {d:17} | {d}\n", .{ if (control) "control" else "loan", peers, packets, limit, probe.writes, spilled });
    };
    try output.interface.flush();
}

const ConfigurationCounts = struct { submissions: u64, rounds: usize, passes: usize, bytes: usize };

fn configurationCounts(packets: usize, queued: bool) !ConfigurationCounts {
    const Engine = engine.Engine(Endpoint, Observer);
    const Codec = packet_codec.Codec(Endpoint);
    const io = std.testing.io;
    var native: Native = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    var observer: Observer = .{ .configuration_remaining = packets };
    var catalog: Endpoint.Protocols = .{};
    const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 8192, .protocols = &catalog, .observer = &observer });
    defer {
        owner.connections[0].receiving = false;
        owner.connections[0].sending = false;
        owner.releaseBuffers(0);
        owner.setHandle(0, null);
        owner.codec = null;
        owner.deinit();
    }
    const codec = try Codec.init(std.testing.allocator, io, transport, 2, null);
    defer codec.deinit();
    if (queued) try owner.attachCodec(codec);
    const connection = &owner.connections[0];
    owner.setHandle(0, .{ .index = 0, .generation = 1 });
    connection.protocol = &catalog.values[0];
    connection.lifecycle = 0xff;
    connection.state.phase = .negotiating;
    connection.admission_deadline = std.math.maxInt(i96);
    var rounds: usize = 0;
    var passes: usize = 0;
    while (native.sends[0] == null) {
        owner.progress(io);
        passes += 1;
        if (connection.codec.state.load(.acquire) == .queued) {
            const read = codec.read.load(.monotonic);
            const task = codec.tasks[read % codec.tasks.len];
            try std.testing.expect(task == &connection.codec);
            try Codec.controlBatch(&codec.workspaces, task.operation.control_batch);
            codec.read.store(read + 1, .release);
            task.complete(.{});
            rounds += 1;
        }
        if (passes > packets + 1 or connection.closing) return error.ConfigurationDidNotProgress;
    }
    try std.testing.expectEqual(@as(usize, 0), observer.configuration_remaining);
    try std.testing.expectEqual(packets, connection.control_wire);
    for (connection.control_packets[0..connection.control_write], 0..) |bytes, index| try std.testing.expectEqualSlices(u8, &.{@intCast(packets - index - 1)}, bytes);
    return .{ .submissions = codec.write.load(.acquire), .rounds = rounds, .passes = passes, .bytes = connection.control_wire };
}

pub fn benchmarkConfiguration() !void {
    var buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(std.testing.io, &buffer);
    try output.interface.writeAll("mode   | packets | codec submissions | completion rounds | engine passes | wire bytes\n");
    for ([_]bool{ false, true }) |queued| for ([_]usize{ 1, 8, 32, 128, 255 }) |packets| {
        const counts = try configurationCounts(packets, queued);
        try output.interface.print("{s:6} | {d:7} | {d:17} | {d:17} | {d:13} | {d}\n", .{ if (queued) "queued" else "inline", packets, counts.submissions, counts.rounds, counts.passes, counts.bytes });
    };
    try output.interface.flush();
}

test "configuration sequences retain their packets across bounded codec batches" {
    const Codec = packet_codec.Codec(Endpoint);
    for ([_]usize{ 1, 128, 255 }) |packets| {
        const inline_counts = try configurationCounts(packets, false);
        const queued = try configurationCounts(packets, true);
        const batches = try std.math.divCeil(usize, packets, Codec.control_batch_max);
        try std.testing.expectEqual(batches, queued.submissions);
        try std.testing.expectEqual(batches + 1, queued.passes);
        try std.testing.expectEqual(inline_counts.bytes, queued.bytes);
    }
}

test "status replies progress while the packet worker and shared buffers are occupied" {
    for ([_]bool{ false, true }) |verify_login| {
        const Engine = engine.Engine(Endpoint, Observer);
        const Codec = packet_codec.Codec(Endpoint);
        const io = std.testing.io;
        var native: Native = .{};
        const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
        var observer: Observer = .{};
        var catalog: Endpoint.Protocols = .{};
        const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer, .compression_threshold = 256 });
        defer {
            owner.connections[0].receiving = false;
            owner.connections[0].sending = false;
            owner.releaseBuffers(0);
            owner.setHandle(0, null);
            owner.codec = null;
            owner.deinit();
        }
        const decoded = owner.decoded.acquire().?;
        defer decoded.release();
        const control = owner.configurations.acquire().?;
        defer control.release();
        const codec = try Codec.init(std.testing.allocator, io, transport, 2, null);
        defer codec.deinit();
        var gate: Gate = .{};
        codec.workspaces.gate = &gate;
        try codec.start();
        defer codec.stop();
        defer gate.release.set(io);
        var task: Codec.Task = .{};
        var bytes: [framing.headroom + 1]u8 = @splat(0);
        var output: [64]u8 = undefined;
        const Verification = struct {
            gate: *Gate,
            caller: std.Thread.Id,
            fn run(self: *@This()) ![16]u8 {
                std.debug.assert(std.Thread.getCurrentId() != self.caller);
                self.gate.started.set(std.testing.io);
                self.gate.release.waitUncancelable(std.testing.io);
                return @splat(7);
            }
        };
        var verification: Verification = .{ .gate = &gate, .caller = std.Thread.getCurrentId() };
        if (verify_login) {
            codec.submit(&task, .{ .verify = protocol.LoginVerification.init(&verification, Verification.run) });
        } else {
            codec.submit(&task, .{ .frame = .{ .protocol = 772, .storage = &bytes, .length = 1, .threshold = null, .output = &output } });
        }
        try gate.started.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(2) } });
        var queued: Codec.Task = .{};
        codec.submit(&queued, .{ .frame = .{ .protocol = 772, .storage = &bytes, .length = 1, .threshold = null, .output = &output } });
        try owner.attachCodec(codec);
        const connection = &owner.connections[0];
        owner.setHandle(0, .{ .index = 0, .generation = 1 });
        connection.protocol = &catalog.values[0];
        connection.lifecycle = 0xff;
        connection.status = true;
        connection.state.phase = .negotiating;
        connection.admission_deadline = std.Io.Clock.now(.awake, io).nanoseconds + std.time.ns_per_s;
        owner.progress(io);
        native.feed(0, "\x02\x01\x2a");
        try owner.receive(io);
        owner.progress(io);
        try std.testing.expectEqualSlices(u8, "\x01\x2a", native.sends[0].?);
        try std.testing.expectEqual(.queued, task.state.load(.acquire));
        gate.release.set(io);
        codec.stop();
        var result = try Codec.take(&task).?;
        defer if (result.secret) |*secret| std.crypto.secureZero(u8, secret);
        if (verify_login) {
            try std.testing.expect(std.mem.allEqual(u8, &result.secret.?, 7));
            try std.testing.expect(std.mem.allEqual(u8, &(try task.result).secret.?, 0));
        } else try std.testing.expectEqual(@as(usize, 1), result.bytes.len);
        try std.testing.expectEqual(@as(usize, 1), (try Codec.take(&queued).?).bytes.len);
    }
}

test "framing continues into recipient encryption without a networking reply" {
    const Codec = packet_codec.Codec(Endpoint);
    const io = std.testing.io;
    var native: Native = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    const codec = try Codec.init(std.testing.allocator, io, transport, 1, null);
    defer codec.deinit();
    var connections = [_]Endpoint.Connection{ 17, 33 };
    var destinations: [2][5]u8 = undefined;
    var sends: [2]Codec.Task = @splat(.{});
    var targets: [2]Codec.SendTarget = undefined;
    for (&targets, &connections, &destinations, &sends) |*target, *connection, *destination, *send| {
        send.state.store(.queued, .release);
        target.* = .{ .task = send, .connection = connection, .bytes = destination, .used = 0, .offset = 0 };
    }
    targets[0].next = &targets[1];
    var storage: [framing.headroom + 5]u8 = @splat(0);
    @memcpy(storage[framing.headroom..], "hello");
    var output: [64]u8 = undefined;
    var frame: Codec.Task = .{};
    try codec.start();
    defer codec.stop();
    codec.submit(&frame, .{ .frame = .{ .protocol = 772, .storage = &storage, .length = 5, .threshold = null, .output = &output, .targets = &targets[0] } });
    codec.stop();
    try std.testing.expectEqual(storage[framing.headroom..].ptr, (try Codec.take(&frame).?).bytes.ptr);
    for (&sends, destinations, connections, [_]u8{ 17, 33 }) |*send, destination, connection, initial| {
        try std.testing.expectEqual(@as(usize, 5), (try Codec.take(send).?).consumed);
        try std.testing.expectEqual(initial + 5, connection);
        for (destination, "hello", 0..) |actual, source, offset| try std.testing.expectEqual(source ^ (initial + @as(u8, @intCast(offset))), actual);
    }
    try std.testing.expectEqualStrings("hello", storage[framing.headroom..]);
}

test "asynchronous control retains its output loan and advances the cipher once" {
    const Engine = engine.Engine(Endpoint, Observer);
    const Codec = packet_codec.Codec(Endpoint);
    const io = std.testing.io;
    var wake: std.Io.Event = .unset;
    var native: Native = .{ .wake = &wake };
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
    defer {
        owner.connections[0].receiving = false;
        owner.connections[0].sending = false;
        owner.releaseBuffers(0);
        owner.setHandle(0, null);
        owner.codec = null;
        owner.deinit();
    }
    const codec = try Codec.init(std.testing.allocator, io, transport, 2, null);
    defer codec.deinit();
    try codec.start();
    defer codec.stop();
    try owner.attachCodec(codec);
    const connection = &owner.connections[0];
    owner.setHandle(0, .{ .index = 0, .generation = 1 });
    connection.protocol = &catalog.values[0];
    connection.lifecycle = 7;
    connection.state.phase = .negotiating;
    connection.admission_deadline = std.Io.Clock.now(.awake, io).nanoseconds + std.time.ns_per_s;
    owner.progress(io);
    native.feed(0, &.{ 2 ^ 0x5a, 1 ^ 0x5a, 42 ^ 0x5a });
    try owner.receive(io);
    while (native.sends[0] == null) {
        wake.reset();
        owner.progress(io);
        if (native.sends[0] == null) try wake.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(2) } });
    }
    try std.testing.expectEqualSlices(u8, &.{ 1 ^ 7, 42 ^ 8 }, native.sends[0].?);
    try std.testing.expect(native.sends[0].?.ptr == connection.control_raw.?.bytes[framing.headroom..].ptr);
    try std.testing.expectEqual(@as(u8, 9), connection.lifecycle.?);
    try std.testing.expectEqual(.idle, connection.codec.state.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), connection.received);
}

test "frozen sessions header preserves listener and compression encodings" {
    const cases = [_]struct { threshold: ?usize, bytes: []const u8 }{
        .{ .threshold = 256, .bytes = "\x63\x00\x00\x00\x00\x01\x00\x00" },
        .{ .threshold = null, .bytes = "\x63\x00\x00\x00\xff\xff\xff\xff" },
    };
    for (cases) |case| {
        const header: handoff.Header = .{ .listener = 99, .compression_threshold = case.threshold };
        var buffer: [8]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try header.write(&writer);
        try std.testing.expectEqualSlices(u8, case.bytes, writer.buffered());
        var reader: std.Io.Reader = .fixed(case.bytes);
        const restored = try handoff.Header.read(&reader);
        try std.testing.expectEqual(header.listener, restored.listener);
        try std.testing.expectEqual(header.compression_threshold, restored.compression_threshold);
        try std.testing.expectEqual(@as(usize, 8), reader.seek);
    }
}

test "frozen session connection records read and write the established bytes" {
    const Engine = engine.Engine(Endpoint, Observer);
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
    });
    defer {
        owner.setHandle(0, null);
        owner.deinit();
    }

    var reader: std.Io.Reader = .fixed(frozen_connection);
    try owner.readResume(std.testing.io, &reader, null);
    try std.testing.expectEqual(frozen_connection.len, reader.seek);
    try std.testing.expectEqual(@as(usize, 1), observer.restored);
    const connection = &owner.connections[0];
    try std.testing.expectEqual(@as(i32, 772), connection.protocol.?.number);
    try std.testing.expectEqual(@as(u8, 0xcc), connection.lifecycle.?);
    try std.testing.expectEqual(@as(u128, 0x112233445566778899aabbccddeeff00), connection.state.uuid);
    try std.testing.expectEqualSlices(u8, "alice", connection.state.name[0..connection.state.name_len]);
    try std.testing.expectEqualSlices(u8, "in", owner.input[0..connection.input_end]);
    try std.testing.expectEqualSlices(u8, "out", connection.output);

    owner.reloading = true;
    connection.parked = true;
    var buffer: [frozen_connection.len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try owner.writeResume(&writer);
    try std.testing.expectEqualSlices(u8, frozen_connection, writer.buffered());
}

test "wire spill preserves full peers without waiting and restores beyond burst capacity" {
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
        .output_burst_slots = 1,
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
    var loan: Engine.Loan = .{ .payload = &packet, .references = 1 };
    try owner.sendFramed(std.testing.io, owner.connections[0].handle.?, &loan, .{});
    try std.testing.expectError(error.Full, owner.sendFramed(std.testing.io, owner.connections[1].handle.?, &loan, .{}));
    try std.testing.expectEqual(@as(u8, 7), owner.connections[1].lifecycle.?);
    const input = owner.input_bursts.acquire().?;
    owner.connections[0].input_burst = input;
    owner.connections[0].input_end = 1024;
    @memset(input.bytes[0..1024], 99);
    owner.reloading = true;
    try owner.spill(std.testing.io);
    try std.testing.expect(owner.connections[0].output_burst == null);
    try owner.sendFramed(std.testing.io, owner.connections[1].handle.?, &loan, .{});
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
        try std.testing.expect(connection.output_burst == null and connection.control_burst == null);
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

test "plaintext fanout lends the original bytes through partial sends cancellation and spill" {
    const Engine = engine.Engine(Endpoint, Observer);
    const io = std.testing.io;
    var native: Native = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native), .inheritance = network.Inheritance.init(Native, &native) };
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    const owner = try Engine.init(std.testing.allocator, transport, .{
        .connections = 2,
        .buffer_bytes = 4096,
        .connection_bytes = 512,
        .max_packet = 4093,
        .max_pending_wire_bytes = 8192,
        .protocols = &catalog,
        .observer = &observer,
    });
    var budget: packet_output.SocketBudget = .init(3);
    var first: Engine.Loan = .framed("Hfirst", "Hfirst"[1..]);
    var second: Engine.Loan = .framed("JKsecond", "JKsecond"[2..]);
    defer {
        for (owner.connections, 0..) |*connection, index| {
            connection.sending = false;
            connection.receiving = false;
            owner.releaseBuffers(index);
            owner.setHandle(index, null);
        }
        owner.deinit();
        std.debug.assert(first.references == 1 and second.references == 1);
    }
    for (owner.connections, 0..) |*connection, index| {
        owner.setHandle(index, .{ .index = @intCast(index), .generation = 1 });
        connection.protocol = &catalog.values[0];
        connection.lifecycle = 0xff;
        connection.state.phase = .play;
        try owner.sendFramed(io, connection.handle.?, &first, .{ .sockets = &budget });
        try owner.sendFramed(io, connection.handle.?, &second, .{ .sockets = &budget });
    }
    owner.progress(io);
    for (owner.connections, 0..) |*connection, index| {
        try std.testing.expect(native.sends[index].?.ptr == &first.header);
        try std.testing.expect(connection.vectors[1].base == first.payload.ptr);
        try std.testing.expectEqual(first.length() + second.length(), connection.sending_bytes);
    }
    try std.testing.expectEqual(@as(usize, 3), first.references);
    native.events[0] = .{ .sent = .{ .handle = owner.connections[0].handle.?, .result = .{ .bytes = 7 } } };
    native.events[1] = .{ .sent = .{ .handle = owner.connections[1].handle.?, .result = .{ .bytes = 0, .errno = @intFromEnum(std.posix.E.CANCELED) } } };
    native.count = 2;
    owner.reloading = true;
    try owner.receive(io);
    try std.testing.expectEqual(@as(usize, 2), first.references);
    try std.testing.expectEqual(@as(usize, 3), second.references);
    try std.testing.expectEqualStrings("K", owner.connections[0].output_loans[owner.connections[0].loan_read % network.send_vectors_max].prefix);
    try std.testing.expectEqualStrings("second", owner.connections[0].output);
    // A canceled send retains its entire original loan until spill consumes it.
    for (owner.connections) |*connection| connection.receiving = false;
    try owner.spill(io);
    try std.testing.expectEqual(@as(usize, 1), first.references);
    try std.testing.expectEqual(@as(usize, 1), second.references);
    var bytes: [16]u8 = undefined;
    const file = owner.spool_file.?;
    const partial = owner.connections[0].saved_output;
    try std.testing.expectEqual(@as(usize, 7), try file.readPositionalAll(io, bytes[0..partial.length], partial.offset));
    try std.testing.expectEqualStrings("Ksecond", bytes[0..partial.length]);
    const canceled = owner.connections[1].saved_output;
    try std.testing.expectEqual(@as(usize, 14), try file.readPositionalAll(io, bytes[0..canceled.length], canceled.offset));
    try std.testing.expectEqualStrings("HfirstJKsecond", bytes[0..canceled.length]);
}

test "decoding a plaintext batch borrows every input packet without changing either buffer" {
    const Codec = packet_codec.Codec(Endpoint);
    var workspaces: Endpoint.Workspaces = .{};
    var connection: Endpoint.Connection = 0xff;
    const bytes = "\x02\x01\x2a\x02\x01\x2b";
    var destination: [64]u8 = @splat(0xcc);
    var descriptors: [4][]const u8 = undefined;
    const result = try Codec.decodeBatch(&workspaces, .{ .connection = &connection, .bytes = bytes, .output = &destination, .packets = &descriptors, .threshold = null, .maximum = 61 });
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

test "codec uses actual framed size and defers exhausted destinations without advancing ciphers" {
    const Codec = packet_codec.Codec(Endpoint);
    const io = std.testing.io;
    var native: Native = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    const codec = try Codec.init(std.testing.allocator, io, transport, 1, null);
    defer codec.deinit();
    codec.workspaces.framed_length = 5;
    var pool = try Buffers.init(std.testing.allocator, 1, 64);
    defer pool.deinit(std.testing.allocator);
    var connections = [_]Endpoint.Connection{ 17, 33, 49, 65 };
    var destinations: [4][8]u8 = @splat(@splat(0));
    var sends: [4]Codec.Task = @splat(.{});
    var targets: [4]Codec.SendTarget = undefined;
    for (&targets, &connections, &destinations, &sends, 0..) |*target, *connection, *destination, *send, index| {
        send.state.store(.queued, .release);
        target.* = .{
            .next = if (index + 1 < targets.len) &targets[index + 1] else null,
            .task = send,
            .connection = connection,
            .bytes = if (index == 0) destination else destination[0..2],
            .used = if (index == 0) 3 else 0,
            .offset = if (index == 0) 6 else 0,
            .overflow = if (index == 1 or index == 2) &pool else null,
        };
    }
    var storage: [framing.headroom + 40]u8 = @splat(0);
    @memcpy(storage[framing.headroom..][0..5], "hello");
    var output: [64]u8 = undefined;
    var frame: Codec.Task = .{};
    try codec.start();
    defer codec.stop();
    codec.submit(&frame, .{ .frame = .{ .protocol = 772, .storage = &storage, .length = 40, .threshold = 1, .output = &output, .targets = &targets[0] } });
    codec.stop();
    try std.testing.expectEqualStrings("hello", (try Codec.take(&frame).?).bytes);
    for (&sends, &targets, connections, [_]u8{ 17, 33, 49, 65 }, 0..) |*send, target, connection, initial, index| {
        const result = try Codec.take(send).?;
        defer if (result.burst) |lease| lease.release();
        if (index < 2) {
            try std.testing.expect(target.sent);
            try std.testing.expectEqual(@as(usize, 5), result.consumed);
            try std.testing.expectEqual(initial + 5, connection);
            const bytes = if (result.burst) |lease| lease.bytes else target.bytes;
            const offset = if (result.burst != null) 0 else target.offset;
            for ("hello", 0..) |source, at| try std.testing.expectEqual(source ^ (initial + @as(u8, @intCast(at))), bytes[(offset + at) % bytes.len]);
            try std.testing.expectEqual(index == 1, result.burst != null);
        } else {
            try std.testing.expect(!target.sent);
            try std.testing.expectEqual(@as(usize, 0), result.consumed);
            try std.testing.expectEqual(initial, connection);
            try std.testing.expectEqual(null, result.burst);
        }
    }
}

test "engine commits codec destinations using actual output size" {
    const Engine = engine.Engine(Endpoint, Observer);
    const Codec = packet_codec.Codec(Endpoint);
    const io = std.testing.io;
    for ([_]usize{ 5, 700 }) |length| {
        var native: Native = .{};
        const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
        var observer: Observer = .{};
        var catalog: Endpoint.Protocols = .{};
        const owner = try Engine.init(std.testing.allocator, transport, .{
            .connections = 1,
            .buffer_bytes = 4096,
            .connection_bytes = 512,
            .max_packet = 4093,
            .max_pending_wire_bytes = 8192,
            .output_burst_slots = 1,
            .protocols = &catalog,
            .observer = &observer,
        });
        defer {
            owner.connections[0].receiving = false;
            owner.connections[0].sending = false;
            owner.releaseBuffers(0);
            owner.setHandle(0, null);
            owner.codec = null;
            owner.deinit();
        }
        const codec = try Codec.init(std.testing.allocator, io, transport, 1, null);
        defer codec.deinit();
        try owner.attachCodec(codec);
        codec.workspaces.framed_length = length;
        const connection = &owner.connections[0];
        const handle: network.Handle = .{ .index = 0, .generation = 1 };
        owner.setHandle(handle.index, handle);
        connection.protocol = &catalog.values[0];
        connection.lifecycle = 7;
        connection.state.phase = .play;
        var target = try owner.prepareSend(handle);
        try std.testing.expectEqual(null, connection.output_burst);
        var storage: [framing.headroom + 1000]u8 = @splat(42);
        var output: [1024]u8 = undefined;
        var frame: Codec.Task = .{};
        try codec.start();
        defer codec.stop();
        codec.submit(&frame, .{ .frame = .{ .protocol = 772, .storage = &storage, .length = 1000, .threshold = 1, .output = &output, .targets = &target } });
        codec.stop();
        try std.testing.expectEqual(length, (try Codec.take(&frame).?).bytes.len);
        owner.progress(io);
        try std.testing.expectEqual(length > 512, connection.output_burst != null);
        try std.testing.expectEqual(length, connection.output_write);
        try std.testing.expectEqual(length, native.sends[0].?.len);
        try std.testing.expectEqual(.idle, connection.codec.state.load(.acquire));
        for (native.sends[0].?, 0..) |byte, offset| try std.testing.expectEqual(@as(u8, 42) ^ (7 +% @as(u8, @truncate(offset))), byte);
    }
}

test "committed output progresses while the same connection waits for the codec" {
    const Engine = engine.Engine(Endpoint, Observer);
    const Codec = packet_codec.Codec(Endpoint);
    const io = std.testing.io;
    var native: Native = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
    defer {
        owner.connections[0].codec.state.store(.idle, .release);
        owner.connections[0].receiving = false;
        owner.connections[0].sending = false;
        owner.releaseBuffers(0);
        owner.setHandle(0, null);
        owner.codec = null;
        owner.deinit();
    }
    const codec = try Codec.init(std.testing.allocator, io, transport, 1, null);
    defer codec.deinit();
    try owner.attachCodec(codec);
    const connection = &owner.connections[0];
    owner.setHandle(0, .{ .index = 0, .generation = 1 });
    connection.protocol = &catalog.values[0];
    connection.lifecycle = 7;
    connection.state.phase = .play;
    @memcpy(owner.output[0..5], "ready");
    connection.output_write = 5;
    connection.codec.state.store(.queued, .release);
    owner.progress(io);
    try std.testing.expectEqualStrings("ready", native.sends[0].?);
    try std.testing.expect(native.sends[0].?.ptr == owner.output.ptr);
    try std.testing.expectEqual(.queued, connection.codec.state.load(.acquire));
    try std.testing.expectEqual(@as(u8, 7), connection.lifecycle.?);
}

test "completed codec tasks notify before the rest of their batch finishes" {
    const Codec = packet_codec.Codec(Endpoint);
    const io = std.testing.io;
    var wake: std.Io.Event = .unset;
    var native: Native = .{ .wake = &wake };
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    const codec = try Codec.init(std.testing.allocator, io, transport, 2, null);
    defer codec.deinit();
    var gate: Gate = .{};
    codec.workspaces = .{ .gate = &gate, .gate_byte = 1 };
    var storage: [2][framing.headroom + 1]u8 = @splat(@splat(0));
    storage[1][framing.headroom] = 1;
    var output: [2][64]u8 = undefined;
    var tasks: [2]Codec.Task = @splat(.{});
    for (&tasks, &storage, &output) |*task, *bytes, *destination| codec.submit(task, .{ .frame = .{ .protocol = 772, .storage = bytes, .length = 1, .threshold = null, .output = destination } });
    try codec.start();
    defer codec.stop();
    defer gate.release.set(io);
    try gate.started.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(2) } });
    try std.testing.expect(wake.isSet());
    try std.testing.expectEqual(.complete, tasks[0].state.load(.acquire));
    try std.testing.expectEqual(.queued, tasks[1].state.load(.acquire));
    gate.release.set(io);
    codec.stop();
    for (&tasks) |*task| _ = try Codec.take(task).?;
}

test "receive chaining decrypts only the new suffix and retains incomplete frames" {
    const Codec = packet_codec.Codec(Endpoint);
    var workspace: Endpoint.Workspaces = .{};
    var connection: Endpoint.Connection = 7;
    var bytes: [7]u8 = undefined;
    for ("\x02ab\x03q", bytes[0..5]) |byte, *destination| destination.* = byte ^ 0x5a;
    var output: [16]u8 = undefined;
    var packets: [8][]const u8 = undefined;
    const first = try Codec.decodeBatch(&workspace, .{ .connection = &connection, .encrypted_tail = bytes[0..5], .received = 5, .bytes = bytes[0..5], .output = &output, .packets = &packets, .threshold = 256, .maximum = 16 });
    try std.testing.expectEqual(@as(usize, 5), first.received);
    try std.testing.expectEqual(@as(usize, 3), first.consumed);
    try std.testing.expectEqualStrings("ab", first.input.?.packets[0]);
    bytes[5] = 'r' ^ 0x5a;
    bytes[6] = 's' ^ 0x5a;
    const second = try Codec.decodeBatch(&workspace, .{ .connection = &connection, .encrypted_tail = bytes[5..], .received = 2, .bytes = bytes[3..], .output = &output, .packets = &packets, .threshold = 256, .maximum = 16 });
    try std.testing.expectEqual(@as(usize, 4), second.consumed);
    try std.testing.expectEqualStrings("qrs", second.input.?.packets[0]);
    bytes[0] = 3 ^ 0x5a;
    const partial = try Codec.decodeBatch(&workspace, .{ .connection = &connection, .encrypted_tail = bytes[0..1], .received = 1, .bytes = bytes[0..1], .output = &output, .packets = &packets, .threshold = 256, .maximum = 16 });
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
    const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
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
    connection.output_read = 500;
    connection.output_write = 500;
    var loan: Engine.Loan = .{ .payload = "abcdefghijklmnopqrst", .references = 1 };
    try owner.sendFramed(io, handle, &loan, .{});
    try std.testing.expectEqual(@as(usize, 1), loan.references);
    owner.progress(io);
    try std.testing.expectEqual(@as(usize, 2), native.send_vectors[0].len);
    try std.testing.expectEqualSlices(u8, "abcdefghijkl", native.send_vectors[0][0].base[0..native.send_vectors[0][0].len]);
    try std.testing.expectEqualSlices(u8, "mnopqrst", native.send_vectors[0][1].base[0..native.send_vectors[0][1].len]);
    native.events[0] = .{ .sent = .{ .handle = handle, .result = .{ .bytes = 15 } } };
    native.count = 1;
    try owner.receive(io);
    owner.progress(io);
    try std.testing.expectEqual(@as(usize, 1), native.send_vectors[0].len);
    try std.testing.expectEqualStrings("pqrst", native.sends[0].?);
    try std.testing.expectEqual(@as(usize, 515), connection.output_read);
}

test "encryption preserves cipher order across owned headers and every ring wrap" {
    const Codec = packet_codec.Codec(Endpoint);
    const wire = "header-payload";
    for (0..wire.len + 1) |header| {
        var loan: packet_output.Loan = .framed(wire, wire[header..]);
        for (0..wire.len + 1) |wrap| {
            var expected: [wire.len]u8 = undefined;
            var actual: [wire.len]u8 = undefined;
            var continuous: Endpoint.Connection = 0;
            var fragmented: Endpoint.Connection = 0;
            Endpoint.encrypt(&continuous, wire, &expected);
            const packet = loan.fragments();
            Codec.encrypt(&fragmented, packet.prefix, packet.payload, actual[0..wrap], actual[wrap..]);
            try std.testing.expectEqualSlices(u8, &expected, &actual);
            try std.testing.expectEqual(continuous, fragmented);
        }
    }
}

test "owned headers survive source reuse through copying socket loans encryption and spool" {
    const Engine = engine.Engine(Endpoint, Observer);
    const io = std.testing.io;
    for ([_]enum { copy, loan, encrypted, spool }{ .copy, .loan, .encrypted, .spool }) |mode| {
        var native: Native = .{};
        var observer: Observer = .{};
        var catalog: Endpoint.Protocols = .{};
        const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
        const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
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
        connection.lifecycle = if (mode == .encrypted) 0 else 0xff;
        connection.state.phase = .play;
        connection.output_read = 508;
        connection.output_write = 508;
        connection.spooling = mode == .spool;
        const expected = "HDpayload";
        var wire = expected.*;
        var loan: packet_output.Loan = .framed(&wire, wire[2..]);
        @memset(wire[0..2], 255);
        var budget: packet_output.SocketBudget = .init(2);
        try owner.sendFramed(io, handle, &loan, .{ .sockets = if (mode == .loan) &budget else null });
        var actual: [expected.len]u8 = undefined;
        switch (mode) {
            .copy, .encrypted => {
                @memcpy(actual[0..4], owner.output[508..512]);
                @memcpy(actual[4..], owner.output[0..5]);
                if (mode == .encrypted) {
                    var cipher: Endpoint.Connection = 0;
                    var encrypted: [expected.len]u8 = undefined;
                    Endpoint.encrypt(&cipher, expected, &encrypted);
                    try std.testing.expectEqualSlices(u8, &encrypted, &actual);
                    try std.testing.expectEqual(cipher, connection.lifecycle.?);
                    continue;
                }
            },
            .loan => {
                owner.progress(io);
                var written: usize = 0;
                for (native.send_vectors[0]) |vector| {
                    @memcpy(actual[written..][0..vector.len], vector.base[0..vector.len]);
                    written += vector.len;
                }
                try std.testing.expectEqual(actual.len, written);
                try std.testing.expect(connection.output_loans[0].bytes.ptr == wire[2..].ptr);
            },
            .spool => {
                try std.testing.expectEqual(expected.len, connection.saved_output.length);
                try std.testing.expectEqual(actual.len, try owner.spool_file.?.readPositionalAll(io, &actual, connection.saved_output.offset));
            },
        }
        try std.testing.expectEqualSlices(u8, expected, &actual);
    }
}

test "an active group gates its connection while other status connections keep progressing" {
    const Engine = engine.Engine(Endpoint, Observer);
    const io = std.testing.io;
    var native: Native = .{};
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 2, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
    defer {
        for (owner.connections, 0..) |*connection, index| {
            connection.receiving = false;
            connection.sending = false;
            connection.loan.store(false, .release);
            owner.releaseBuffers(index);
            owner.setHandle(index, null);
        }
        owner.deinit();
    }
    const handle: network.Handle = .{ .index = 0, .generation = 1 };
    const connection = &owner.connections[0];
    owner.setHandle(handle.index, handle);
    connection.protocol = &catalog.values[0];
    connection.lifecycle = 0xff;
    connection.state.phase = .play;
    connection.attached = true;
    var group: framing.Group = .{ .protocol = catalog.values[0].number, .first = 3, .generation = 7, .count = 3 };
    try std.testing.expect(owner.groupReady(handle, 0, group));
    owner.claimGroup(handle, 0, group);
    try std.testing.expect(!owner.groupReady(handle, 1, group));
    try std.testing.expect(!owner.groupReady(handle, 0, .{}));
    try std.testing.expect(!try owner.reconfigure(io, handle));
    owner.progress(io);
    native.feed(0, "\x02\x01\x2a");
    try owner.receive(io);
    owner.progress(io);
    try std.testing.expectEqual(@as(usize, 0), observer.payloads[0].len);
    const status = &owner.connections[1];
    owner.setHandle(1, .{ .index = 1, .generation = 1 });
    status.protocol = &catalog.values[0];
    status.lifecycle = 0xff;
    status.status = true;
    status.state.phase = .negotiating;
    status.admission_deadline = std.Io.Clock.now(.awake, io).nanoseconds + std.time.ns_per_s;
    owner.progress(io);
    native.feed(1, "\x02\x01\x2b");
    try owner.receive(io);
    owner.progress(io);
    try std.testing.expectEqualSlices(u8, "\x01\x2b", native.sends[1].?);
    try std.testing.expectEqual(@as(usize, 0), observer.payloads[0].len);
    for (0..3) |index| {
        group.index = @intCast(index);
        try std.testing.expect(owner.groupReady(handle, 0, group));
        if (index != 2) {
            var future = group;
            future.index += 1;
            try std.testing.expect(!owner.groupReady(handle, 0, future));
        }
        owner.completeGroupPacket(handle, 0, group);
    }
    try std.testing.expect(connection.group == null);
    owner.progress(io);
    try std.testing.expect(observer.payloads[0].len != 0);
    owner.releaseInput(io, handle);
    group.index = 0;
    owner.claimGroup(handle, 0, group);
    owner.beginShutdown(io);
    try std.testing.expect(!owner.discardGroup(handle));
    try std.testing.expect(owner.discardGroup(status.handle.?));
}

test "reload spools a partially emitted group and preserves its remaining packet order" {
    for ([_]bool{ false, true }) |encrypted| {
        const Engine = engine.Engine(Endpoint, Observer);
        const io = std.testing.io;
        var native: Native = .{};
        var observer: Observer = .{};
        var catalog: Endpoint.Protocols = .{};
        const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
        const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
        defer {
            owner.connections[0].receiving = false;
            owner.connections[0].sending = false;
            owner.releaseBuffers(0);
            owner.setHandle(0, null);
            owner.deinit();
        }
        const handle: network.Handle = .{ .index = 0, .generation = 1 };
        const connection = &owner.connections[0];
        owner.setHandle(handle.index, handle);
        connection.protocol = &catalog.values[0];
        connection.lifecycle = if (encrypted) 0 else 0xff;
        connection.state.phase = .play;
        var group: framing.Group = .{ .protocol = catalog.values[0].number, .first = 2, .generation = 9, .count = 3, .bytes = 3 };
        owner.claimGroup(handle, 0, group);
        var first = packet_output.Loan.framed("a", "a");
        try owner.sendFramed(io, handle, &first, .{});
        first.release();
        owner.completeGroupPacket(handle, 0, group);
        owner.reloading = true;
        try owner.spill(io);
        try std.testing.expect(connection.spooling and connection.group != null);
        try std.testing.expectEqual(@as(usize, 1), connection.saved_output.length);
        for ([_][]const u8{ "b", "c" }, 1..) |bytes, index| {
            group.index = @intCast(index);
            try std.testing.expect(owner.groupReady(handle, 0, group));
            var loan = packet_output.Loan.framed(bytes, bytes);
            try owner.sendFramed(io, handle, &loan, .{});
            loan.release();
            owner.completeGroupPacket(handle, 0, group);
        }
        try std.testing.expect(connection.group == null);
        var bytes: [3]u8 = undefined;
        try std.testing.expectEqual(bytes.len, try owner.spool_file.?.readPositionalAll(io, &bytes, connection.saved_output.offset));
        try std.testing.expectEqualSlices(u8, if (encrypted) &.{ 'a', 'b' ^ 1, 'c' ^ 2 } else "abc", &bytes);
    }
}

test "encrypted groups reserve output capacity before opening and retain it between packets" {
    const Engine = engine.Engine(Endpoint, Observer);
    const io = std.testing.io;
    var native: Native = .{};
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 1, .buffer_bytes = 4096, .connection_bytes = 512, .max_packet = 4093, .max_pending_wire_bytes = 8192, .output_burst_slots = 1, .protocols = &catalog, .observer = &observer });
    defer {
        owner.connections[0].receiving = false;
        owner.connections[0].sending = false;
        owner.releaseBuffers(0);
        owner.setHandle(0, null);
        owner.deinit();
    }
    const handle: network.Handle = .{ .index = 0, .generation = 1 };
    const connection = &owner.connections[0];
    owner.setHandle(handle.index, handle);
    connection.protocol = &catalog.values[0];
    connection.lifecycle = 0;
    connection.state.phase = .play;
    const group: framing.Group = .{ .protocol = catalog.values[0].number, .first = 3, .generation = 1, .count = 3, .bytes = 2000 };
    const held = owner.output_bursts.acquire().?;
    try std.testing.expectError(error.Full, owner.reserveGroupOutput(handle, group));
    try std.testing.expect(connection.group == null and connection.output_burst == null);
    held.release();
    try owner.reserveGroupOutput(handle, group);
    const reserved = connection.output_burst.?.bytes.ptr;
    owner.claimGroup(handle, 0, group);
    owner.progress(io);
    try std.testing.expectEqual(reserved, connection.output_burst.?.bytes.ptr);
    try std.testing.expect(connection.group != null);
}

test "one codec submission frames and encrypts a whole sequence into wrapped recipient buffers" {
    const Codec = packet_codec.Codec(Endpoint);
    for ([_]bool{ false, true }) |masked| {
        var native: Native = .{};
        const codec = try Codec.init(std.testing.allocator, std.testing.io, .{ .context = &native, .vtable = network.Transport.adapter(Native) }, 8, null);
        defer codec.deinit();
        var storage: [3][framing.headroom + 3]u8 = undefined;
        const payloads = [_][]const u8{ "ab", "cde", "f" };
        var scratch: [3][8]u8 = undefined;
        var tasks: [3]Codec.Task = @splat(.{});
        var frames: [3]Codec.Frame = undefined;
        for (&frames, &tasks, &storage, &scratch, payloads, 0..) |*frame, *task, *bytes, *output, payload, index| {
            @memcpy(bytes[framing.headroom..][0..payload.len], payload);
            frame.* = .{ .task = task, .protocol = 772, .storage = bytes, .length = payload.len, .threshold = null, .output = output };
            if (index != 0) {
                tasks[index].state.store(.queued, .release);
                frames[index - 1].next = frame;
            }
        }
        var connections: [2]Endpoint.Connection = .{ 0, 40 };
        var destinations: [2][12]u8 = @splat(@splat(0));
        var sent: [2]Codec.Task = @splat(.{});
        var targets: [2]Codec.SendTarget = undefined;
        for (&targets, &sent, &connections, &destinations, 0..) |*target, *task, *connection, *output, index| {
            task.state.store(.queued, .release);
            target.* = .{ .task = task, .connection = connection, .bytes = output, .used = 0, .offset = 10, .packets = if (!masked) 0b111 else if (index == 0) 0b101 else 0b110 };
            if (index != 0) targets[index - 1].next = target;
        }
        codec.submit(&tasks[0], .{ .frame_sequence = .{ .first = &frames[0], .targets = &targets[0] } });
        try std.testing.expectEqual(@as(usize, 1), codec.write.load(.acquire));
        try codec.start();
        codec.stop();
        for (&tasks, payloads) |*task, payload| {
            const result = try (Codec.take(task) orelse return error.MissingFrameCompletion);
            try std.testing.expectEqualSlices(u8, payload, result.bytes);
        }
        for (&sent, destinations, 0..) |*task, output, index| {
            const result = try (Codec.take(task) orelse return error.MissingSendCompletion);
            const expected: []const u8 = if (!masked) "abcdef" else if (index == 0) "abf" else "cdef";
            try std.testing.expectEqual(expected.len, result.consumed);
            for (expected, 0..) |byte, offset| try std.testing.expectEqual(byte ^ @as(u8, @intCast(index * 40 + offset)), output[(10 + offset) % output.len]);
        }
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

test "multishot ciphertext arriving during a codec loan is consumed exactly once" {
    const Engine = engine.Engine(Endpoint, Observer);
    const Codec = Engine.Codec;
    const io = std.testing.io;
    var native: Native = .{};
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
    defer owner.deinit();
    const codec = try Codec.init(std.testing.allocator, io, transport, 2, null);
    defer codec.deinit();
    try owner.attachCodec(codec);
    const connection = &owner.connections[0];
    defer {
        codec.read.store(codec.write.load(.acquire), .release);
        if (connection.codec.state.load(.acquire) == .queued) connection.codec.complete(error.TestStopped);
        if (Codec.take(&connection.codec)) |result| _ = result catch .{};
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
    native.feedMore(0, "\x58\x5b", true);
    try owner.receive(io);
    owner.progress(io);
    try std.testing.expectEqual(@as(usize, 2), connection.received);
    try std.testing.expectEqual(@as(usize, 2), connection.codec.operation.receive.bytes.len);
    native.feedMore(0, "\x70", true);
    try owner.receive(io);
    try std.testing.expectEqual(@as(usize, 3), connection.received);
    for (0..2) |round| {
        const read = codec.read.load(.monotonic);
        const task = codec.tasks[read % codec.tasks.len];
        const job = task.operation.receive;
        try std.testing.expectEqual(@as(usize, if (round == 0) 2 else 1), job.bytes.len);
        Endpoint.receive(job.connection, job.bytes);
        codec.read.store(read + 1, .release);
        task.complete(.{ .received = job.bytes.len });
        owner.progress(io);
    }
    try std.testing.expectEqual(@as(usize, 0), connection.received);
    try std.testing.expect(connection.receiving and connection.loan.load(.acquire));
    try std.testing.expectEqualSlices(u8, "\x02\x01\x2a", observer.payloads[0]);
    const borrowed = observer.payloads[0];
    native.feedMore(0, "\x58\x5b\x71", true);
    try owner.receive(io);
    owner.progress(io);
    const read = codec.read.load(.monotonic);
    const task = codec.tasks[read % codec.tasks.len];
    const job = task.operation.receive;
    Endpoint.receive(job.connection, job.bytes);
    codec.read.store(read + 1, .release);
    task.complete(.{ .received = job.bytes.len });
    owner.progress(io);
    try std.testing.expectEqualSlices(u8, "\x02\x01\x2a", borrowed);
    try std.testing.expect(borrowed.ptr == observer.payloads[0].ptr);
    owner.releaseInput(io, connection.handle.?);
    owner.progress(io);
    try std.testing.expectEqualSlices(u8, "\x02\x01\x2b", observer.payloads[0]);
    try std.testing.expect(connection.receiving);
    try std.testing.expectEqual(@as(usize, 0), connection.received);
    try std.testing.expectEqual(codec.write.load(.acquire), codec.read.load(.acquire));
}

test "returned decode loans go to waiting peers before a busy peer can reacquire them" {
    const Engine = engine.Engine(Endpoint, Observer);
    const Codec = Engine.Codec;
    const io = std.testing.io;
    var native: Native = .{};
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 2, .decode_slots = 1, .compression_threshold = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
    defer owner.deinit();
    const codec = try Codec.init(std.testing.allocator, io, transport, 2, null);
    defer codec.deinit();
    try owner.attachCodec(codec);
    defer {
        codec.read.store(codec.write.load(.acquire), .release);
        for (owner.connections, 0..) |*connection, index| {
            if (connection.codec.state.load(.acquire) == .queued) connection.codec.complete(error.TestStopped);
            if (Codec.take(&connection.codec)) |result| _ = result catch .{};
            connection.receiving = false;
            connection.loan.store(false, .release);
            owner.releaseBuffers(index);
            owner.setHandle(index, null);
        }
    }
    for (owner.connections, 0..) |*connection, index| {
        owner.setHandle(index, .{ .index = @intCast(index), .generation = 1 });
        connection.protocol = &catalog.values[0];
        connection.lifecycle = 0xfe;
        connection.state.phase = .play;
    }
    owner.progress(io);
    native.feedMore(0, "\x58\x5b\x70", true);
    native.feedMore(1, "\x58\x5b\x71", true);
    try owner.receive(io);
    owner.progress(io);
    const first = codec.tasks[0];
    const holder: u16 = if (first == &owner.connections[0].codec) 0 else 1;
    const waiter: u16 = 1 - holder;
    const result = try Codec.decodeBatch(&codec.workspaces, first.operation.decode_batch);
    codec.read.store(1, .release);
    first.complete(result);
    owner.progress(io);
    try std.testing.expect(owner.connections[holder].loan.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), observer.payloads[waiter].len);
    owner.releaseInput(io, owner.connections[holder].handle.?);
    native.feedMore(holder, "\x58\x5b\x72", true);
    try owner.receive(io);
    owner.progress(io);
    const next = codec.tasks[1];
    try std.testing.expect(next == &owner.connections[waiter].codec);
    const next_result = try Codec.decodeBatch(&codec.workspaces, next.operation.decode_batch);
    codec.read.store(2, .release);
    next.complete(next_result);
    owner.progress(io);
    try std.testing.expect(observer.payloads[waiter].len != 0);
    try std.testing.expect(owner.connections[waiter].loan.load(.acquire));
    try std.testing.expectEqual(@as(usize, 3), owner.connections[holder].received);
}

test "reload drains ciphertext without waiting for a gameplay decode buffer" {
    const Engine = engine.Engine(Endpoint, Observer);
    const Codec = Engine.Codec;
    const io = std.testing.io;
    var native: Native = .{};
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 1, .decode_slots = 1, .compression_threshold = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
    defer owner.deinit();
    const codec = try Codec.init(std.testing.allocator, io, transport, 2, null);
    defer codec.deinit();
    try owner.attachCodec(codec);
    const held = owner.decoded.acquire().?;
    defer held.release();
    const connection = &owner.connections[0];
    defer {
        codec.read.store(codec.write.load(.acquire), .release);
        if (connection.codec.state.load(.acquire) == .queued) connection.codec.complete(error.TestStopped);
        if (Codec.take(&connection.codec)) |result| _ = result catch .{};
        connection.receiving = false;
        connection.loan.store(false, .release);
        owner.releaseBuffers(0);
        owner.setHandle(0, null);
    }
    owner.setHandle(0, .{ .index = 0, .generation = 1 });
    connection.protocol = &catalog.values[0];
    connection.lifecycle = 0xfe;
    connection.state.phase = .play;
    owner.progress(io);
    native.feedMore(0, "\x58\x5b\x70", true);
    try owner.receive(io);
    owner.progress(io);
    try std.testing.expectEqual(.idle, connection.codec.state.load(.acquire));
    try std.testing.expectEqual(@as(usize, 3), connection.received);
    owner.reloading = true;
    connection.attached = true;
    owner.wakeAll();
    owner.progress(io);
    try std.testing.expectEqual(.queued, connection.codec.state.load(.acquire));
    try std.testing.expectEqual(.receive, std.meta.activeTag(connection.codec.operation));
    const task = codec.tasks[0];
    const job = task.operation.receive;
    Endpoint.receive(job.connection, job.bytes);
    codec.read.store(1, .release);
    task.complete(.{ .received = job.bytes.len });
    owner.progress(io);
    try std.testing.expectEqual(@as(usize, 0), connection.received);
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
    var bytes: [4 + (frozen_connection.len - 4) * 2]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try writer.writeInt(u32, 2, .little);
    try writer.writeAll(frozen_connection[4..]);
    try writer.writeInt(i32, 101, .little);
    try writer.writeAll(frozen_connection[8..]);
    var reader: std.Io.Reader = .fixed(writer.buffered());
    try std.testing.expectError(error.InvalidResume, owner.readResume(std.testing.io, &reader, null));
    try std.testing.expectEqual(@as(usize, 1), owner.admitted);
    try std.testing.expectEqual(@as(usize, 1), owner.identities.count());
    try std.testing.expectEqual(@as(usize, 0), owner.identities.get(owner.connections[0].state.uuid).?);
}

test "exhausted decode pools retain waiters and wake only available capacity" {
    const Engine = engine.Engine(Endpoint, Observer);
    const Codec = Engine.Codec;
    const io = std.testing.io;
    var native: Native = .{};
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 64, .decode_slots = 1, .compression_threshold = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
    defer owner.deinit();
    const codec = try Codec.init(std.testing.allocator, io, transport, 64, null);
    defer codec.deinit();
    try owner.attachCodec(codec);
    defer {
        codec.read.store(codec.write.load(.acquire), .release);
        for (owner.connections, 0..) |*connection, index| {
            if (connection.codec.state.load(.acquire) == .queued) connection.codec.complete(error.TestStopped);
            if (Codec.take(&connection.codec)) |result| _ = result catch .{};
            connection.receiving = false;
            connection.sending = false;
            owner.releaseBuffers(index);
            owner.setHandle(index, null);
        }
    }
    var held: ?Buffers.Lease = owner.decoded.acquire().?;
    defer if (held) |lease| lease.release();
    for (owner.connections, 0..) |*connection, index| {
        owner.setHandle(index, .{ .index = index, .generation = 1 });
        connection.protocol = &catalog.values[0];
        connection.lifecycle = 0xfe;
        connection.state.phase = .play;
        connection.received = 1;
    }
    for (0..64) |_| owner.progress(io);
    try std.testing.expectEqual(@as(u64, 0), codec.write.load(.acquire));
    for (owner.connections) |connection| try std.testing.expect(connection.waiting == .decoded);
    held.?.release();
    held = null;
    owner.progress(io);
    try std.testing.expectEqual(@as(u64, 1), codec.write.load(.acquire));
    try std.testing.expect(codec.tasks[0] == &owner.connections[0].codec);
    for (0..64) |_| owner.progress(io);
    try std.testing.expectEqual(@as(u64, 1), codec.write.load(.acquire));
    for (owner.connections[1..]) |connection| try std.testing.expect(connection.waiting == .decoded);
}

test "transport capacity wakes outbound delivery while inbound decoding stays blocked" {
    const Engine = engine.Engine(Endpoint, Observer);
    const Codec = Engine.Codec;
    const io = std.testing.io;
    var native: Native = .{ .send_full = true };
    var observer: Observer = .{};
    var catalog: Endpoint.Protocols = .{};
    const transport: network.Transport = .{ .context = &native, .vtable = network.Transport.adapter(Native) };
    const owner = try Engine.init(std.testing.allocator, transport, .{ .connections = 1, .decode_slots = 1, .compression_threshold = 1, .buffer_bytes = 512, .max_packet = 509, .max_pending_wire_bytes = 1024, .protocols = &catalog, .observer = &observer });
    defer owner.deinit();
    const codec = try Codec.init(std.testing.allocator, io, transport, 1, null);
    defer codec.deinit();
    try owner.attachCodec(codec);
    defer {
        const connection = &owner.connections[0];
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
    connection.received = 1;
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
    try std.testing.expectEqual(@as(u64, 0), codec.write.load(.acquire));
}
