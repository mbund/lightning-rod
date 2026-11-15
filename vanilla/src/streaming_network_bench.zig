const std = @import("std");
const sessions = @import("sessions");
const protocols = @import("protocols");
const network = @import("networking");
const metrics = @import("metrics");
const minecraft_java = @import("minecraft_java");
const support = @import("protocol_support");
const fluid_wire = @import("wire_26_1");
const assert = std.debug.assert;

const Hooks = struct {
    pub fn closed(_: *Hooks, _: network.Handle) void {}
    pub fn handshake(_: *Hooks, _: []const u8) !sessions.protocol.Handshake {
        unreachable;
    }
    pub fn statusPacket(_: *Hooks, _: sessions.StatusRequest, _: []const u8, _: []u8) !?[]const u8 {
        unreachable;
    }
    pub fn input(_: *Hooks, comptime kind: sessions.InputPhase, _: sessions.InputScope, _: []const u8, _: []u8) !sessions.InputEffect(kind) {
        unreachable;
    }
    pub fn phase(_: *Hooks, comptime kind: enum { login, configuration }, _: sessions.PhaseScope, _: sessions.PhaseEvent, _: []u8) !(if (kind == .login) sessions.LoginStep else sessions.ConfigurationStep) {
        unreachable;
    }
    pub fn play(_: *Hooks, comptime _: @TypeOf(protocols.Endpoint.versions), _: sessions.Profile, _: sessions.protocol.PlayEvent, _: []u8) !?[]const u8 {
        return null;
    }
};

const Worker = sessions.Worker(protocols.Endpoint, Hooks, sessions.SingleSimulation);

pub const Network = struct {
    const Receiver = struct {
        wire: minecraft_java.Wire = .{ .compressed = true },
        buffer: []u8,
        used: usize = 0,
        protocol: i32,
        columns: []Column,
    };
    const Column = struct { x: i32 = 0, z: i32 = 0, hash: ?u64 = null, biomes: u64 = 0 };
    io: std.Io,
    worker: *Worker = undefined,
    endpoints: [1]*sessions.Service,
    hooks: Hooks = .{},
    router: sessions.SingleSimulation = .{},
    events: []network.Event,
    receiving: []bool,
    closing: []bool,
    hashes: []std.hash.Wyhash,
    bytes: []usize,
    receivers: []Receiver,
    validation_cpu_ns: i96 = 0,
    decoded: []u8,
    decoder: ?minecraft_java.Wire.Workspace,
    column_side: i32,
    pending: usize = 0,
    ready: std.Io.Event = .unset,
    launched: std.Io.Event = .unset,
    producer_ready: *std.Io.Event = undefined,
    finished: std.Io.Event = .unset,
    draining: std.atomic.Value(bool) = .init(false),
    drained: std.Io.Event = .unset,
    thread: ?std.Thread = null,
    failure: ?anyerror = null,
    workers: usize,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, endpoint: *sessions.Service, catalog: *const protocols.Endpoint.Protocols, registry: *metrics.Registry, workers: usize, encryption: bool, radius: usize, verify: bool) !*Network {
        const self = try allocator.create(Network);
        const count = endpoint.config.connections;
        self.* = .{
            .io = io,
            .endpoints = .{endpoint},
            .workers = workers,
            .events = try allocator.alloc(network.Event, count * 3),
            .receiving = try allocator.alloc(bool, count),
            .closing = try allocator.alloc(bool, count),
            .hashes = try allocator.alloc(std.hash.Wyhash, count),
            .bytes = try allocator.alloc(usize, count),
            .receivers = try allocator.alloc(Receiver, if (verify) count else 0),
            .decoded = try allocator.alloc(u8, if (verify) endpoint.config.buffer_bytes else 0),
            .decoder = if (verify) try minecraft_java.Wire.Workspace.init(allocator) else null,
            .column_side = @intCast(radius * 2 + 3),
        };
        @memset(self.receiving, false);
        @memset(self.closing, false);
        @memset(self.bytes, 0);
        for (self.hashes) |*hash| hash.* = .init(0);
        const receive_bytes = try allocator.alloc(u8, if (verify) count * endpoint.config.buffer_bytes else 0);
        for (self.receivers, 0..) |*receiver, index| {
            receiver.* = .{ .buffer = receive_bytes[index * endpoint.config.buffer_bytes ..][0..endpoint.config.buffer_bytes], .protocol = catalog.values[index % catalog.values.len].number, .columns = try allocator.alloc(Column, (radius * 2 + 3) * (radius * 2 + 3)) };
            @memset(receiver.columns, .{});
            if (encryption) {
                var secret: [16]u8 = @splat(0x37);
                std.mem.writeInt(u64, secret[0..8], index, .little);
                receiver.wire.install(secret);
            }
        }
        endpoint.transport = .{ .context = self, .vtable = network.Transport.adapter(Network) };
        self.worker = try Worker.init(allocator, .{ .context = self, .vtable = network.Transport.adapter(Network) }, .{
            .connections = count,
            .max_players = count,
            .buffer_bytes = endpoint.config.buffer_bytes,
            .framing_slots = 8,
            .codec_workers = @max(workers, 1),
            .protocols = catalog,
            .hooks = &self.hooks,
            .router = &self.router,
            .destinations = &.{0},
            .metrics = registry,
        }, &self.endpoints);
        if (workers != 0) try self.worker.initCodec(io, registry);
        for (self.worker.engine.connections, 0..) |*connection, index| {
            const handle: network.Handle = .{ .index = index, .generation = 1 };
            connection.state = .{ .phase = .play, .uuid = index + 1 };
            connection.protocol = &catalog.values[index % catalog.values.len];
            connection.lifecycle = try protocols.Endpoint.init(connection.protocol.?.number, .login);
            switch (connection.lifecycle.?) {
                inline else => |*state| {
                    state.phase = .play;
                    state.wire.compressed = true;
                    if (encryption) {
                        var secret: [16]u8 = @splat(0x37);
                        std.mem.writeInt(u64, secret[0..8], index, .little);
                        state.wire.install(secret);
                    }
                },
            }
            self.worker.engine.setHandle(index, handle);
            self.worker.engine.admit(index);
            connection.attached = true;
            self.worker.bindings[index] = .{ .endpoint = endpoint, .handle = handle, .native = handle };
            endpoint.routes[index] = handle;
            endpoint.occupied[index].store(true, .release);
        }
        return self;
    }

    pub fn start(self: *Network, producer_ready: *std.Io.Event) !void {
        self.producer_ready = producer_ready;
        if (self.workers == 0) return;
        try self.worker.engine.codec.?.start();
        errdefer self.worker.engine.codec.?.stop();
        self.thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, run, .{self});
    }
    pub fn begin(self: *Network) void {
        self.launched.set(self.io);
    }
    fn run(self: *Network) void {
        self.launched.waitUncancelable(self.io);
        self.execute() catch |err| {
            self.failure = err;
        };
        self.finished.set(self.io);
        self.producer_ready.set(self.io);
    }
    fn execute(self: *Network) !void {
        while (try self.worker.advance(self.io, null)) {
            if (self.draining.load(.acquire) and self.idle()) self.drained.set(self.io);
        }
    }
    fn idle(self: *Network) bool {
        if (self.endpoints[0].preparing.load(.acquire) != 0 or self.pending != 0) return false;
        for (self.worker.queues) |queue| if (queue.head != null) return false;
        for (self.worker.frames) |frame| if (frame.packet != null) return false;
        for (self.worker.engine.connections) |connection| {
            if (connection.sending or connection.loan.load(.acquire) or connection.frame_targets != 0 or connection.output.len != 0 or connection.output_read != connection.output_write or connection.codec.state.load(.acquire) != .idle) return false;
        }
        return true;
    }
    pub fn drain(self: *Network) !void {
        self.draining.store(true, .release);
        self.notify(self.io);
        if (self.workers == 0) {
            while (!self.idle()) try self.pollInline();
        } else {
            try self.drained.waitTimeout(self.io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(60) } });
        }
        if (self.failure) |err| return err;
        for (self.receivers) |receiver| if (receiver.used != 0) return error.IncompleteOutput;
    }
    pub fn terrainHash(self: *const Network) u64 {
        return self.hashColumns(.blocks);
    }
    pub fn biomeHash(self: *const Network) u64 {
        return self.hashColumns(.biomes);
    }
    fn hashColumns(self: *const Network, comptime field: enum { blocks, biomes }) u64 {
        var hash = std.hash.Wyhash.init(0);
        for (self.receivers) |receiver| {
            for (receiver.columns) |column| if (column.hash) |value| {
                var values: [16]u8 = undefined;
                std.mem.writeInt(i32, values[0..4], column.x, .little);
                std.mem.writeInt(i32, values[4..8], column.z, .little);
                std.mem.writeInt(u64, values[8..16], if (field == .blocks) value else column.biomes, .little);
                hash.update(&values);
            };
        }
        return hash.final();
    }
    fn paletteEnd(input: []const u8, count: usize, indirect_bits: u8) !usize {
        if (input.len == 0) return error.IncompletePalette;
        const bits = input[0];
        var rest = input[1..];
        if (bits == 0) {
            _, rest = try support.read_varint(rest);
        } else {
            if (bits > 32) return error.InvalidPalette;
            if (bits <= indirect_bits) {
                const length, const values = try support.read_varint(rest);
                if (length < 0 or length > count) return error.InvalidPalette;
                rest = values;
                for (0..@intCast(length)) |_| {
                    _, rest = try support.read_varint(rest);
                }
            }
            const per_word = 64 / @as(usize, bits);
            const bytes = (count + per_word - 1) / per_word * 8;
            if (bytes > rest.len) return error.IncompletePalette;
            rest = rest[bytes..];
        }
        return input.len - rest.len;
    }
    fn observe(self: *Network, receiver: *Receiver, body: []const u8) !void {
        const packet = try receiver.wire.decode(body, self.decoded, &self.decoder.?, 256);
        inline for (protocols.Endpoint.versions) |Version| {
            if (Version.protocol_number == receiver.protocol) {
                const header = try Version.Protocol.play.toClient.readHeader(packet);
                if (header.id != Version.Protocol.play.toClient.packetId(.map_chunk)) return;
                try (try Version.Protocol.play.toClient.packet_map_chunk.read(header.body).scan()).finish();
                const x, const rz = try Version.Protocol.play.toClient.packet_map_chunk.read(header.body).x();
                const z, const rh = try rz.z();
                var heightmaps = try rh.heightmaps();
                const rd = if (@hasDecl(@TypeOf(heightmaps), "encoded")) (try heightmaps.encoded())[1] else heightmaps[1];
                const blocks, const re = try rd.chunkData();
                var entities = try re.blockEntities();
                const block_entities, const lights = try entities.encoded();
                _ = lights;
                var hash = std.hash.Wyhash.init(0);
                var biomes = std.hash.Wyhash.init(0);
                const header_bytes: usize = if (Version.protocol_number >= fluid_wire.protocol_number) 4 else 2;
                var remaining = blocks;
                while (remaining.len != 0) {
                    if (remaining.len < header_bytes) return error.IncompleteSection;
                    const end = header_bytes + try paletteEnd(remaining[header_bytes..], 4096, 8);
                    hash.update(remaining[0..end]);
                    remaining = remaining[end..];
                    const biome_end = try paletteEnd(remaining, 64, 3);
                    biomes.update(remaining[0..biome_end]);
                    remaining = remaining[biome_end..];
                }
                hash.update(block_entities);
                const slot: usize = @intCast(@mod(z, self.column_side) * self.column_side + @mod(x, self.column_side));
                const entry = &receiver.columns[slot];
                if (entry.hash != null and (entry.x != x or entry.z != z)) return error.ColumnCollision;
                entry.* = .{ .x = x, .z = z, .hash = hash.final(), .biomes = biomes.final() };
                return;
            }
        }
        return error.UnsupportedProtocol;
    }
    fn validate(self: *Network, recipient: usize, input: []const u8) !void {
        const receiver = &self.receivers[recipient];
        var remaining = input;
        while (remaining.len != 0) {
            const count = @min(remaining.len, receiver.buffer.len - receiver.used);
            if (count == 0) return error.OutputFrameTooLarge;
            const bytes = receiver.buffer[receiver.used..][0..count];
            @memcpy(bytes, remaining[0..count]);
            receiver.wire.receive(bytes);
            receiver.used += count;
            remaining = remaining[count..];
            var consumed: usize = 0;
            while (consumed < receiver.used) {
                const frame = minecraft_java.Wire.frame(receiver.buffer[consumed..receiver.used], receiver.buffer.len) catch |err| switch (err) {
                    error.Incomplete => break,
                    else => return err,
                };
                if (frame.body.len == 0) return error.EmptyOutputFrame;
                try self.observe(receiver, frame.body);
                consumed += frame.length;
            }
            std.mem.copyForwards(u8, receiver.buffer[0 .. receiver.used - consumed], receiver.buffer[consumed..receiver.used]);
            receiver.used -= consumed;
        }
    }
    pub fn pollInline(self: *Network) !void {
        if (self.workers == 0) _ = try self.worker.advance(self.io, std.Io.Clock.Timestamp.now(self.io, .awake));
        if (self.finished.isSet()) return self.failure orelse error.NetworkStopped;
    }
    pub fn wait(self: *Network) !void {
        if (self.workers == 0) return;
        if (self.finished.isSet()) return self.failure orelse error.NetworkStopped;
        try self.producer_ready.waitTimeout(self.io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(60) } });
    }
    pub fn stop(self: *Network) !void {
        self.worker.stop();
        self.launched.set(self.io);
        self.notify(self.io);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
            self.worker.engine.codec.?.stop();
            if (self.failure) |err| return err;
        } else while (try self.worker.advance(self.io, std.Io.Clock.Timestamp.now(self.io, .awake))) {}
        self.worker.deinit();
        if (self.decoder) |*decoder| decoder.deinit();
    }
    fn push(self: *Network, event: network.Event) void {
        assert(self.pending < self.events.len);
        self.events[self.pending] = event;
        self.pending += 1;
    }
    pub fn notify(self: *Network, io: std.Io) void {
        self.ready.set(io);
    }
    pub fn queueReceive(self: *Network, _: std.Io, handle: network.Handle, _: []u8) network.QueueError!void {
        assert(!self.receiving[handle.index]);
        self.receiving[handle.index] = true;
    }
    pub fn queueSend(self: *Network, io: std.Io, handle: network.Handle, vectors: []const std.posix.iovec_const) network.QueueError!void {
        var length: usize = 0;
        const started = std.Io.Clock.now(.cpu_thread, io).nanoseconds;
        for (vectors) |vector| {
            self.hashes[handle.index].update(vector.base[0..vector.len]);
            if (self.failure == null and self.receivers.len != 0) self.validate(handle.index, vector.base[0..vector.len]) catch |err| {
                self.failure = err;
            };
            length += vector.len;
        }
        self.validation_cpu_ns += std.Io.Clock.now(.cpu_thread, io).nanoseconds - started;
        self.bytes[handle.index] += length;
        self.push(.{ .sent = .{ .handle = handle, .result = .{ .bytes = length } } });
        self.ready.set(io);
    }
    pub fn close(self: *Network, io: std.Io, handle: network.Handle, reason: network.CloseReason) void {
        if (self.closing[handle.index]) return;
        self.closing[handle.index] = true;
        if (self.receiving[handle.index]) {
            self.receiving[handle.index] = false;
            self.push(.{ .received = .{ .handle = handle, .result = .{ .bytes = 0 } } });
        }
        self.push(.{ .closed = .{ .handle = handle, .reason = reason } });
        self.ready.set(io);
    }
    pub fn releaseConnection(_: *Network, _: std.Io, _: network.Handle) void {}
    pub fn submit(_: *Network, _: std.Io) !void {}
    pub fn poll(self: *Network, io: std.Io, timeout: ?std.Io.Timeout, output: []network.Event) !usize {
        const signaled = @atomicRmw(std.Io.Event, &self.ready, .Xchg, .unset, .acq_rel);
        if (self.pending == 0 and !signaled.isSet()) {
            if (timeout) |until| self.ready.waitTimeout(io, until) catch |err| switch (err) {
                error.Timeout => {},
                else => return err,
            } else self.ready.waitUncancelable(io);
        }
        const count = @min(output.len, self.pending);
        @memcpy(output[0..count], self.events[0..count]);
        std.mem.copyForwards(network.Event, self.events[0 .. self.pending - count], self.events[count..self.pending]);
        self.pending -= count;
        return count;
    }
};
