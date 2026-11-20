const std = @import("std");
const java = @import("java");
const sessions = @import("sessions");
const Wire = java.Wire;
const headroom = sessions.shared_headroom;

fn allocateWorkspace(allocator: std.mem.Allocator) !void {
    var workspace = try Wire.Workspace.init(allocator);
    defer workspace.deinit();
    try std.testing.expect(workspace.memory_bytes > 0);
    try std.testing.expect(workspace.memory_bytes <= Wire.Workspace.memory_limit);
}

test "workspace allocation failures release the caller's allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocateWorkspace, .{});
}

test "independent packets round trip through reused compression and decode workspaces" {
    const allocator = std.testing.allocator;
    const maximum = (1 << 21) - 1;
    const storage = try allocator.alloc(u8, maximum + headroom);
    defer allocator.free(storage);
    const output = try allocator.alloc(u8, maximum + maximum / 8 + 1024);
    defer allocator.free(output);
    const decoded = try allocator.alloc(u8, maximum);
    defer allocator.free(decoded);
    var workspace = try Wire.Workspace.init(allocator);
    defer workspace.deinit();
    var random = std.Random.DefaultPrng.init(0);
    for ([_]usize{ 1, 127, 128, 255, 256, 1024, 16383, 16384, 65536, maximum }) |length| {
        for ([_]bool{ false, true }) |noise| {
            // A maximum-size random packet cannot fit within Minecraft's outer-frame limit.
            if (noise and length == maximum) continue;
            const payload = storage[headroom..][0..length];
            if (noise) random.random().bytes(payload) else @memset(payload, 0);
            payload[0] = 0; // A valid one-byte Minecraft packet ID.
            for ([_]?usize{ null, 256 }) |threshold| {
                const framed = try workspace.encode(storage, length, threshold, output);
                const parsed = try Wire.frame(framed, output.len);
                try std.testing.expectEqual(framed.len, parsed.length);
                const actual = try workspace.decode(parsed.body, threshold, decoded);
                try std.testing.expectEqualSlices(u8, payload, actual);
            }
        }
    }
}

test "compression respects output bounds and rejects corrupted checksums" {
    var workspace = try Wire.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    var packet: [512]u8 = @splat(0);
    var output: [1024]u8 = @splat(0xa5);
    try std.testing.expectError(error.BufferTooSmall, workspace.compress(&packet, output[0 .. headroom + 9]));
    try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(0xa5)), output[headroom + 9 ..][0..16]);
    const framed = try workspace.compress(&packet, &output);
    const parsed = try Wire.frame(framed, output.len);
    var decoded: [512]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &packet, try workspace.decode(parsed.body, 256, &decoded));
    output[@intFromPtr(framed.ptr) + framed.len - @intFromPtr(&output) - 1] ^= 1;
    try std.testing.expectError(error.InvalidPacket, workspace.decode(parsed.body, 256, &decoded));
}

test "compressed frames reject inconsistent lengths, trailing data and truncation" {
    var workspace = try Wire.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    var packet: [512]u8 = undefined;
    var random = std.Random.DefaultPrng.init(5);
    random.random().bytes(&packet);
    var output: [1024]u8 = undefined;
    const framed = try workspace.compress(&packet, &output);
    const parsed = try Wire.frame(framed, output.len);
    var decoded: [513]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, workspace.decode(parsed.body, 256, decoded[0..511]));
    for ([_]usize{ 511, 513 }) |declared| {
        var body: [1024]u8 = undefined;
        @memcpy(body[0..parsed.body.len], parsed.body);
        body[0] = @as(u8, @intCast(declared & 127)) | 128;
        body[1] = @intCast(declared >> 7);
        try std.testing.expectError(error.InvalidPacket, workspace.decode(body[0..parsed.body.len], 256, &decoded));
    }
    for (0..parsed.body.len) |length| {
        try std.testing.expectError(error.InvalidPacket, workspace.decode(parsed.body[0..length], 256, &decoded));
    }
    var trailing: [1024]u8 = undefined;
    @memcpy(trailing[0..parsed.body.len], parsed.body);
    trailing[parsed.body.len] = 0;
    try std.testing.expectError(error.InvalidPacket, workspace.decode(trailing[0 .. parsed.body.len + 1], 256, &decoded));

    // Independently verify libdeflate output using Zig's decoder.
    var source: std.Io.Reader = .fixed(parsed.body[2..]);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflater = std.compress.flate.Decompress.init(&source, .zlib, &window);
    try inflater.reader.readSliceAll(decoded[0..packet.len]);
    try std.testing.expectEqualSlices(u8, &packet, decoded[0..packet.len]);
    try std.testing.expectError(error.EndOfStream, inflater.reader.takeByte());
    try std.testing.expectEqual(parsed.body.len - 2, source.seek);
    try std.testing.expectEqual(std.hash.Adler32.hash(&packet), inflater.container_metadata.zlib.adler);
}

test "control packets retain their framing settings across compression transitions" {
    var workspace = try Wire.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    var wire: Wire = .{ .compressed = true };
    const packet = "\x01\x2a";
    var plain: [64]u8 = undefined;
    var compressed: [64]u8 = undefined;
    const before = try wire.control(.{ .borrowed = packet }, &plain, &workspace, null);
    try std.testing.expectEqualSlices(u8, &.{2}, before.first);
    try std.testing.expect(before.second.ptr == packet.ptr);
    wire.compressed = false;
    const after = try wire.control(.{ .borrowed = packet }, &compressed, &workspace, 256);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0 }, after.first);
    try std.testing.expect(after.second.ptr == packet.ptr);
}

test "control framing borrows immutable packets and prefixes without concatenation" {
    var workspace = try Wire.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    const packet = "\x01\x2a\x2b";
    var output: [64]u8 = @splat(0xcc);
    var wire: Wire = .{ .compressed = true };
    const result = try wire.control(.{ .borrowed = packet }, &output, &workspace, 256);
    try std.testing.expectEqualSlices(u8, &.{ 4, 0 }, result.first);
    try std.testing.expect(result.second.ptr == packet.ptr);
    try std.testing.expectEqualStrings(packet, result.second);
    try std.testing.expect(std.mem.allEqual(u8, output[2..], 0xcc));
}

test "control framing uses reserved headroom without touching the destination" {
    var workspace = try Wire.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    var storage: [headroom + 3]u8 = @splat(0);
    storage[headroom..].* = .{ 1, 42, 43 };
    var output: [64]u8 = @splat(0xcc);
    var wire: Wire = .{};
    const result = try wire.control(.{ .buffered = .{ .storage = &storage, .length = 3 } }, &output, &workspace, null);
    try std.testing.expect(result.first.ptr == storage[headroom - 1 ..].ptr);
    try std.testing.expectEqualSlices(u8, &.{ 3, 1, 42, 43 }, result.first);
    try std.testing.expectEqual(@as(usize, 0), result.second.len);
    try std.testing.expect(std.mem.allEqual(u8, &output, 0xcc));
}

test "encrypted immutable control writes ciphertext directly into its destination" {
    var workspace = try Wire.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    const packet = "\x01\x2a\x2b";
    var output: [64]u8 = @splat(0xcc);
    var wire: Wire = .{};
    wire.install(@splat(17));
    const result = try wire.control(.{ .borrowed = packet }, &output, &workspace, null);
    try std.testing.expect(result.first.ptr == output[0..].ptr);
    try std.testing.expectEqual(@as(usize, 0), result.second.len);
    wire.receive(output[0..result.first.len]);
    const frame = try Wire.frame(result.first, 61);
    try std.testing.expectEqualStrings(packet, frame.body);
    try std.testing.expectEqualSlices(u8, &.{ 1, 42, 43 }, packet);
}

test "encryption fanout reads the shared source directly across destination wrap" {
    const packet = "\x01\x2a\x2b\x2c";
    var expected: [packet.len]u8 = undefined;
    var first: [2]u8 = undefined;
    var second: [2]u8 = undefined;
    var reference: Wire = .{};
    reference.install(@splat(23));
    reference.encrypt(packet, &expected);
    var wrapped: Wire = .{};
    wrapped.install(@splat(23));
    wrapped.encrypt(packet[0..2], &first);
    wrapped.encrypt(packet[2..], &second);
    try std.testing.expectEqualSlices(u8, expected[0..2], &first);
    try std.testing.expectEqualSlices(u8, expected[2..], &second);
    try std.testing.expectEqualSlices(u8, &reference.send_cipher.?.feedback, &wrapped.send_cipher.?.feedback);
    try std.testing.expectEqualSlices(u8, &.{ 1, 42, 43, 44 }, packet);
}

test "batched encryption preserves independent keys wrapped destinations and resumed streams" {
    var random = std.Random.DefaultPrng.init(493);
    var source: [1024]u8 = undefined;
    var actual: [9][1024]u8 = undefined;
    var expected: [9][1024]u8 = undefined;
    var wires: [9]Wire = undefined;
    var references: [9]Wire = undefined;
    var jobs: [9]Wire.Encryption = undefined;
    for (0..10) |_| {
        for (&wires, &references) |*wire, *reference| {
            var secret: [16]u8 = undefined;
            random.random().bytes(&secret);
            wire.* = .{};
            wire.install(secret);
            reference.* = wire.*;
        }
        for (0..20) |iteration| {
            random.random().bytes(&source);
            const length = if (iteration == 0) 0 else random.random().intRangeAtMost(usize, 1, source.len);
            const count = iteration % (wires.len + 1);
            var splits: [9]usize = undefined;
            for (wires[0..count], references[0..count], jobs[0..count], splits[0..count], 0..) |*wire, *reference, *job, *split, index| {
                split.* = random.random().intRangeAtMost(usize, 0, length);
                @memset(&actual[index], 0xcc);
                job.* = wire.encryption(actual[index][length - split.* ..][0..split.*], actual[index][0 .. length - split.*]);
                reference.encrypt(source[0..length], expected[index][0..length]);
            }
            var begin: usize = 0;
            while (begin < count) {
                const end = @min(count, begin + Wire.encryption_batch_size);
                Wire.encryptBatch(source[0..length], jobs[begin..end]);
                begin = end;
            }
            for (wires[0..count], references[0..count], jobs[0..count], splits[0..count], 0..) |*wire, reference, job, split, index| {
                try std.testing.expectEqualSlices(u8, expected[index][0..split], job.first);
                try std.testing.expectEqualSlices(u8, expected[index][split..length], job.second);
                try std.testing.expectEqual(reference.send_cipher.?.feedback, wire.send_cipher.?.feedback);
                try std.testing.expect(std.mem.allEqual(u8, actual[index][length..], 0xcc));
                var saved: [Wire.saved_max]u8 = undefined;
                wire.* = try Wire.restore(try wire.save(&saved));
            }
        }
    }
}

test "CFB8 matches NIST SP 800-38A F.3.7" {
    var secret: [16]u8 = undefined;
    var iv: [16]u8 = undefined;
    var plaintext: [18]u8 = undefined;
    var ciphertext: [18]u8 = undefined;
    _ = try std.fmt.hexToBytes(&secret, "2b7e151628aed2a6abf7158809cf4f3c");
    _ = try std.fmt.hexToBytes(&iv, "000102030405060708090a0b0c0d0e0f");
    _ = try std.fmt.hexToBytes(&plaintext, "6bc1bee22e409f96e93d7e117393172aae2d");
    _ = try std.fmt.hexToBytes(&ciphertext, "3b79424c9c0dd436bace9e0ed4586a4f32b9");
    var wires: [7]Wire = undefined;
    var output: [7][18]u8 = undefined;
    var jobs: [7]Wire.Encryption = undefined;
    for (&wires, &output, &jobs) |*wire, *bytes, *job| {
        wire.* = .{};
        wire.install(secret);
        wire.send_cipher.?.feedback = iv;
        wire.receive_cipher.?.feedback = iv;
        job.* = wire.encryption(bytes[0..7], bytes[7..]);
    }
    Wire.encryptBatch(&.{}, &.{});
    var begin: usize = 0;
    while (begin < jobs.len) {
        const end = @min(jobs.len, begin + Wire.encryption_batch_size);
        Wire.encryptBatch(&plaintext, jobs[begin..end]);
        begin = end;
    }
    for (&wires, &output) |*wire, *bytes| {
        try std.testing.expectEqualSlices(u8, &ciphertext, bytes);
        wire.receive(bytes);
        try std.testing.expectEqualSlices(u8, &plaintext, bytes);
    }
    wires[0].send_cipher.?.feedback = iv;
    var in_place = plaintext;
    wires[0].send(&in_place);
    try std.testing.expectEqualSlices(u8, &ciphertext, &in_place);
}

test "endpoint encryption batches preserve each protocol connection" {
    const First = struct {
        pub const protocol_number = 1;
        pub const Connection = java.Connection(struct {});
    };
    const Second = struct {
        pub const protocol_number = 2;
        pub const Connection = java.Connection(struct {});
    };
    const Endpoint = sessions.Endpoint(.{ First, Second }, void, void);
    var connections: [4]Endpoint.Connection = undefined;
    var expected: [4]Wire = undefined;
    var outputs: [4][31]u8 = undefined;
    var jobs: [4]Endpoint.Encryption = undefined;
    inline for (.{ 1, 2 }) |number| {
        const ConnectionType = if (number == 1) First.Connection else Second.Connection;
        for (&connections, &expected, &jobs, 0..) |*connection, *reference, *job, index| {
            const tag = std.fmt.comptimePrint("{d}", .{number});
            connection.* = @unionInit(Endpoint.Connection, tag, ConnectionType.init(.login));
            @field(connection, tag).wire.install(@splat(@intCast(index + number)));
            reference.* = @field(connection, tag).wire;
            job.* = .{ .connection = connection, .first = outputs[index][0..17], .second = outputs[index][17..] };
        }
        var begin: usize = 0;
        while (begin < jobs.len) {
            const end = @min(jobs.len, begin + Endpoint.encryptionBatchSize(number));
            Endpoint.encryptBatch(number, "an independent encrypted stream", jobs[begin..end]);
            begin = end;
        }
        for (connections, &expected, outputs) |connection, *reference, actual| {
            var scalar: [31]u8 = undefined;
            reference.encrypt("an independent encrypted stream", &scalar);
            try std.testing.expectEqualSlices(u8, &scalar, &actual);
            try std.testing.expectEqual(reference.send_cipher.?.feedback, @field(connection, std.fmt.comptimePrint("{d}", .{number})).wire.send_cipher.?.feedback);
        }
    }
}

test "receive batches preserve in-place tails and resumed cipher streams" {
    var random = std.Random.DefaultPrng.init(0);
    for (0..100) |_| {
        var secret: [16]u8 = undefined;
        var plain: [1024]u8 = undefined;
        random.random().bytes(&secret);
        random.random().bytes(&plain);
        var sender: Wire = .{};
        sender.install(secret);
        var encrypted: [plain.len]u8 = undefined;
        sender.encrypt(&plain, &encrypted);

        var scalar: Wire = .{};
        scalar.install(secret);
        var expected = encrypted;
        for (&expected) |*byte| scalar.receive(byte[0..1]);
        try std.testing.expectEqualSlices(u8, &plain, &expected);

        var receiver: Wire = .{};
        receiver.install(secret);
        var received = encrypted;
        var offset: usize = 0;
        while (offset < received.len) {
            const length = @min(received.len - offset, random.random().intRangeAtMost(usize, 1, 79));
            receiver.receive(received[offset..][0..length]);
            receiver.receive(received[offset..][0..0]);
            var saved: [Wire.saved_max]u8 = undefined;
            receiver = try Wire.restore(try receiver.save(&saved));
            offset += length;
        }
        try std.testing.expectEqualSlices(u8, &plain, &received);
        try std.testing.expectEqual(scalar.receive_cipher.?.feedback, receiver.receive_cipher.?.feedback);
        try std.testing.expectEqual(sender.send_cipher.?.feedback, receiver.receive_cipher.?.feedback);

        var separate: Wire = .{};
        separate.install(secret);
        var output: [plain.len]u8 = undefined;
        separate.receive_cipher.?.transform(.decrypt, &encrypted, &output);
        try std.testing.expectEqualSlices(u8, &plain, &output);
        try std.testing.expectEqual(receiver.receive_cipher.?.feedback, separate.receive_cipher.?.feedback);
    }
}

test "prepared frames preserve threshold semantics and bound their decoded fallback" {
    var workspace = try Wire.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    var raw: [8192]u8 = undefined;
    for (&raw, 0..) |*byte, index| byte.* = @truncate(index * 17 + index / 31);
    var storage: [16384]u8 = undefined;
    var output: [16384]u8 = undefined;
    var decoded: [8192]u8 = undefined;
    const encoded = try workspace.compressor.encode(&raw, storage[sessions.shared_headroom..]);
    for ([_]?usize{ null, 0, 256, raw.len, raw.len + 1 }) |threshold| {
        const frame = try workspace.prepared(&storage, encoded.len, raw.len, threshold, &output);
        const parsed = try sessions.frame(frame, output.len);
        const payload = try workspace.decode(parsed.body, threshold, &decoded);
        try std.testing.expectEqualSlices(u8, &raw, payload);
    }
    try std.testing.expectError(error.InvalidPacket, workspace.prepared(&storage, encoded.len, 0, 256, &output));
    try std.testing.expectError(error.BufferTooSmall, workspace.prepared(&storage, encoded.len, raw.len, null, output[0..64]));
}
