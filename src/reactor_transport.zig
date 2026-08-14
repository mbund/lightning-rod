const std = @import("std");
const abi = @import("hot_reload_abi.zig");
const config = @import("config.zig").value;
const connection = @import("reactor_connection.zig");
const crypto = @import("crypto_support.zig");
const reactor_output = @import("reactor_output.zig");
const protocol_support = @import("protocol_support");
const tick_input = @import("tick_input.zig");
const wire = @import("wire.zig");

const header_bytes = 3;
const body_offset = 6;

pub const State = struct {
    compression_window: []u8 = &.{},
    compression_buffer: []u8 = &.{},
    decompression_window: []u8 = &.{},
    input: tick_input.Arena = undefined,

    pub fn allocate(self: *State, allocator: std.mem.Allocator) !void {
        self.compression_window = try allocator.alloc(u8, std.compress.flate.max_window_len);
        self.compression_buffer = try allocator.alloc(u8, config.player_write_buffer_size);
        self.decompression_window = try allocator.alloc(u8, std.compress.flate.max_window_len);
        self.input = try tick_input.Arena.init();
    }

    pub fn deinit(self: *State) void {
        self.input.deinit();
    }

    pub fn finishTick(self: *State) !void {
        try self.input.finishTick();
    }

    pub fn appendInput(
        self: *State,
        connections: *connection.Table,
        handle: abi.ConnectionHandle,
        bytes: []const u8,
    ) abi.KernelStatus {
        _ = self;
        const slot = connections.lookup(handle) orelse return .invalid_connection;
        const client = &connections.items[slot];
        if (bytes.len > client.read_buffer.len -| client.read_len) return .rejected;
        const appended = client.read_buffer[client.read_len..][0..bytes.len];
        @memcpy(appended, bytes);
        if (client.decryptor) |*decryptor| decryptor.decrypt(appended);
        client.read_len += bytes.len;
        return .ok;
    }

    pub fn nextPacket(
        self: *State,
        connections: *connection.Table,
        handle: abi.ConnectionHandle,
        result: *abi.Bytes,
    ) abi.KernelStatus {
        const slot = connections.lookup(handle) orelse return .invalid_connection;
        const client = &connections.items[slot];
        const framed = (wire.nextPacket(client.read_buffer[0..client.read_len]) catch
            return .rejected) orelse return .incomplete;
        const payload = self.decodePayload(client, framed.payload) catch return .rejected;
        result.* = .{ .ptr = payload.ptr, .len = payload.len };
        const remaining = client.read_len - framed.total_len;
        if (remaining != 0)
            @memmove(client.read_buffer[0..remaining], client.read_buffer[framed.total_len..client.read_len]);
        client.read_len = remaining;
        return .ok;
    }

    pub fn setCompression(
        _: *State,
        connections: *connection.Table,
        handle: abi.ConnectionHandle,
        threshold: i32,
    ) abi.KernelStatus {
        if (threshold < 0) return .rejected;
        const slot = connections.lookup(handle) orelse return .invalid_connection;
        connections.items[slot].compression_threshold = threshold;
        return .ok;
    }

    pub fn setEncryption(
        _: *State,
        connections: *connection.Table,
        handle: abi.ConnectionHandle,
        secret: [16]u8,
    ) abi.KernelStatus {
        const slot = connections.lookup(handle) orelse return .invalid_connection;
        const client = &connections.items[slot];
        client.encryptor = crypto.Cfb8.init(secret);
        client.decryptor = crypto.Cfb8.init(secret);
        if (client.read_len != 0)
            client.decryptor.?.decrypt(client.read_buffer[0..client.read_len]);
        return .ok;
    }

    pub fn reserveOutput(
        _: *State,
        connections: *connection.Table,
        buffers: *reactor_output.Pool,
        handle: abi.ConnectionHandle,
        minimum_body_bytes: usize,
        lease: *abi.OutputLease,
    ) abi.KernelStatus {
        const slot = connections.lookup(handle) orelse return .invalid_connection;
        const client = &connections.items[slot];
        if (client.reload_transition_pending) return .backpressured;
        const minimum = std.math.add(usize, minimum_body_bytes, body_offset) catch
            return .backpressured;
        const bytes = buffers.reserve(connections.items, @intCast(slot), minimum);
        if (bytes.len < minimum) {
            buffers.abort(connections.items, @intCast(slot));
            return .backpressured;
        }
        lease.* = .{
            .id = handle.value(),
            .bytes = .{ .ptr = bytes[body_offset..].ptr, .len = bytes.len - body_offset },
            .protocol_number = client.protocol_number,
        };
        return .ok;
    }

    pub fn commitOutput(
        self: *State,
        connections: *connection.Table,
        buffers: *reactor_output.Pool,
        lease_id: u64,
        body_len: usize,
    ) abi.KernelStatus {
        const handle = unpackHandle(lease_id);
        const slot = connections.lookup(handle) orelse return .invalid_connection;
        const client = &connections.items[slot];
        if (!client.output_lease_active and !client.scratch_lease_active)
            return .invalid_lease;
        const reserved = buffers.reserved(client);
        if (body_len > reserved.len -| body_offset) return .invalid_lease;
        const stream_len = self.frame(client, reserved, body_len) catch
            return .backpressured;
        if (client.encryptor) |*encryptor| encryptor.encrypt(reserved[0..stream_len]);
        buffers.commit(connections.items, @intCast(slot), stream_len) catch
            return .backpressured;
        return .ok;
    }

    fn decodePayload(
        self: *State,
        client: *const connection.Connection,
        framed: []const u8,
    ) ![]const u8 {
        if (client.compression_threshold == null) {
            return self.copyInput(framed);
        }
        const data_len, const compressed = try protocol_support.read_varint(framed);
        if (data_len < 0) return error.MalformedPacketLength;
        if (data_len == 0) {
            return self.copyInput(compressed);
        }
        const output_len: usize = @intCast(data_len);
        const reservation = try self.input.reserve(output_len);
        errdefer self.input.cancelReservation(reservation);
        var source: std.Io.Reader = .fixed(compressed);
        var decompressor = std.compress.flate.Decompress.init(
            &source,
            .zlib,
            self.decompression_window,
        );
        try decompressor.reader.readSliceAll(reservation.bytes);
        return reservation.bytes;
    }

    fn copyInput(self: *State, source: []const u8) ![]const u8 {
        return self.input.copy(source);
    }

    fn frame(
        self: *State,
        client: *connection.Connection,
        bytes: []u8,
        body_len: usize,
    ) !usize {
        if (client.compression_threshold == null) {
            @memmove(bytes[header_bytes..][0..body_len], bytes[body_offset..][0..body_len]);
            writeFixedVarInt(bytes[0..header_bytes], body_len);
            return header_bytes + body_len;
        }
        const threshold: usize = @intCast(client.compression_threshold.?);
        if (body_len < threshold) {
            writeFixedVarInt(bytes[0..header_bytes], header_bytes + body_len);
            writeFixedVarInt(bytes[header_bytes..body_offset], 0);
            return body_offset + body_len;
        }
        var writer: std.Io.Writer = .fixed(self.compression_buffer);
        var compressor = try std.compress.flate.Compress.init(
            &writer,
            self.compression_window,
            .zlib,
            .level_1,
        );
        try compressor.writer.writeAll(bytes[body_offset..][0..body_len]);
        try compressor.finish();
        const compressed = writer.buffered();
        if (body_offset + compressed.len > bytes.len) return error.OutputBackpressure;
        writeFixedVarInt(bytes[0..header_bytes], header_bytes + compressed.len);
        writeFixedVarInt(bytes[header_bytes..body_offset], body_len);
        @memcpy(bytes[body_offset..][0..compressed.len], compressed);
        return body_offset + compressed.len;
    }
};

fn unpackHandle(value: u64) abi.ConnectionHandle {
    return .{ .index = @truncate(value), .generation = @truncate(value >> 32) };
}

fn writeFixedVarInt(output: *[header_bytes]u8, value: usize) void {
    if (value > 0x1f_ffff) @panic("packet exceeds fixed framing capacity");
    output[0] = @as(u8, @truncate(value)) | 0x80;
    output[1] = @as(u8, @truncate(value >> 7)) | 0x80;
    output[2] = @truncate(value >> 14);
}

test "stable transport retains framing compression and encryption state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var connections: connection.Table = .{};
    var buffers: reactor_output.Pool = .{};
    var transport: State = .{};
    try connections.allocate(arena.allocator());
    try buffers.allocate(arena.allocator());
    try transport.allocate(arena.allocator());
    defer transport.deinit();

    const client = &connections.items[0];
    client.phase = .play;
    client.generation = 7;
    client.protocol_number = 772;
    const handle = connections.handle(0);
    const body = [_]u8{ 0x2a, 0x10, 0x20, 0x30 };

    var lease: abi.OutputLease = undefined;
    try std.testing.expectEqual(
        abi.KernelStatus.ok,
        transport.reserveOutput(&connections, &buffers, handle, body.len, &lease),
    );
    @memcpy(lease.bytes.slice()[0..body.len], &body);
    try std.testing.expectEqual(
        abi.KernelStatus.ok,
        transport.commitOutput(&connections, &buffers, lease.id, body.len),
    );
    const segment = client.constOutputSegment(0);
    const bytes = buffers.buffers[segment.buffer_index][segment.offset..segment.len];
    const framed = (try wire.nextPacket(bytes)).?;
    try std.testing.expectEqual(bytes.len, framed.total_len);
    try std.testing.expectEqualSlices(u8, &body, framed.payload);

    try std.testing.expectEqual(
        abi.KernelStatus.ok,
        transport.appendInput(&connections, handle, bytes[0..2]),
    );
    var packet: abi.Bytes = undefined;
    try std.testing.expectEqual(
        abi.KernelStatus.incomplete,
        transport.nextPacket(&connections, handle, &packet),
    );
    try std.testing.expectEqual(
        abi.KernelStatus.ok,
        transport.appendInput(&connections, handle, bytes[2..]),
    );
    try std.testing.expectEqual(
        abi.KernelStatus.ok,
        transport.nextPacket(&connections, handle, &packet),
    );
    try std.testing.expectEqualSlices(u8, &body, packet.slice());
    try std.testing.expectEqual(
        abi.KernelStatus.incomplete,
        transport.nextPacket(&connections, handle, &packet),
    );

    try std.testing.expectEqual(
        abi.KernelStatus.ok,
        transport.setCompression(&connections, handle, 0),
    );
    const previous_len = client.constOutputSegment(0).len;
    try std.testing.expectEqual(
        abi.KernelStatus.ok,
        transport.reserveOutput(&connections, &buffers, handle, body.len, &lease),
    );
    @memcpy(lease.bytes.slice()[0..body.len], &body);
    try std.testing.expectEqual(
        abi.KernelStatus.ok,
        transport.commitOutput(&connections, &buffers, lease.id, body.len),
    );
    const compressed_segment = client.constOutputSegment(0);
    const compressed_frame = buffers.buffers[compressed_segment.buffer_index][previous_len..compressed_segment.len];
    try std.testing.expectEqual(
        abi.KernelStatus.ok,
        transport.appendInput(&connections, handle, compressed_frame),
    );
    try std.testing.expectEqual(
        abi.KernelStatus.ok,
        transport.nextPacket(&connections, handle, &packet),
    );
    try std.testing.expectEqualSlices(u8, &body, packet.slice());

    const secret = [_]u8{0x5a} ** 16;
    try std.testing.expectEqual(
        abi.KernelStatus.ok,
        transport.setEncryption(&connections, handle, secret),
    );
    var peer_encryptor = crypto.Cfb8.init(secret);
    var peer_decryptor = crypto.Cfb8.init(secret);
    for (0..2) |_| {
        const output_start = client.constOutputSegment(0).len;
        try std.testing.expectEqual(
            abi.KernelStatus.ok,
            transport.reserveOutput(&connections, &buffers, handle, body.len, &lease),
        );
        @memcpy(lease.bytes.slice()[0..body.len], &body);
        try std.testing.expectEqual(
            abi.KernelStatus.ok,
            transport.commitOutput(&connections, &buffers, lease.id, body.len),
        );
        const encrypted_segment = client.constOutputSegment(0);
        const encrypted = buffers.buffers[encrypted_segment.buffer_index][output_start..encrypted_segment.len];
        var wire_copy: [128]u8 = undefined;
        @memcpy(wire_copy[0..encrypted.len], encrypted);
        peer_decryptor.decrypt(wire_copy[0..encrypted.len]);
        const decrypted_frame = (try wire.nextPacket(wire_copy[0..encrypted.len])).?;
        const decrypted_body = try transport.decodePayload(client, decrypted_frame.payload);
        try std.testing.expectEqualSlices(u8, &body, decrypted_body);

        peer_encryptor.encrypt(wire_copy[0..encrypted.len]);
        try std.testing.expectEqual(
            abi.KernelStatus.ok,
            transport.appendInput(&connections, handle, wire_copy[0..encrypted.len]),
        );
        try std.testing.expectEqual(
            abi.KernelStatus.ok,
            transport.nextPacket(&connections, handle, &packet),
        );
        try std.testing.expectEqualSlices(u8, &body, packet.slice());
    }

    client.reload_transition_pending = true;
    try std.testing.expectEqual(
        abi.KernelStatus.backpressured,
        transport.reserveOutput(&connections, &buffers, handle, body.len, &lease),
    );
}
