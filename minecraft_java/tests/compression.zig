const std = @import("std");
const Wire = @import("java").Wire;
const headroom = @import("sessions").shared_headroom;

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
