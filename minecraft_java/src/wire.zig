const std = @import("std");
const sessions = @import("sessions");
const Cipher = @import("cipher.zig").Cipher;
const compression = @import("compression.zig");

pub const Wire = struct {
    pub const Workspace = compression.Workspace;
    pub const always_copy = false;
    pub const frame_bound: sessions.protocol.Protocol.FrameBound = .{};

    compressed: bool = false,
    receive_cipher: ?Cipher = null,
    send_cipher: ?Cipher = null,

    pub fn encrypted(self: *const Wire) bool {
        return self.receive_cipher != null;
    }

    pub fn install(self: *Wire, secret: [16]u8) void {
        std.debug.assert(self.receive_cipher == null and self.send_cipher == null);
        self.receive_cipher = Cipher.init(secret);
        self.send_cipher = Cipher.init(secret);
    }

    pub fn receive(self: *Wire, bytes: []u8) void {
        if (self.receive_cipher) |*cipher| cipher.transform(.decrypt, bytes, bytes);
    }

    pub fn send(self: *Wire, bytes: []u8) void {
        if (self.send_cipher) |*cipher| cipher.transform(.encrypt, bytes, bytes);
    }

    pub fn save(self: *const Wire, bytes: []u8) ![]const u8 {
        if (bytes.len < 50) return error.BufferTooSmall;
        bytes[0] = @intFromBool(self.compressed);
        bytes[1] = @intFromBool(self.encrypted());
        if (self.receive_cipher) |cipher| {
            @memcpy(bytes[2..18], &cipher.secret);
            @memcpy(bytes[18..34], &cipher.feedback);
            @memcpy(bytes[34..50], &self.send_cipher.?.feedback);
        } else @memset(bytes[2..50], 0);
        return bytes[0..50];
    }

    pub fn restore(bytes: []const u8) !Wire {
        if (bytes.len != 50 or bytes[0] > 1 or bytes[1] > 1) return error.InvalidResume;
        var wire: Wire = .{ .compressed = bytes[0] == 1 };
        if (bytes[1] == 1) {
            wire.install(bytes[2..18].*);
            wire.receive_cipher.?.feedback = bytes[18..34].*;
            wire.send_cipher.?.feedback = bytes[34..50].*;
        } else if (!std.mem.allEqual(u8, bytes[2..50], 0)) return error.InvalidResume;
        return wire;
    }

    pub fn clear(self: *Wire) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }

    pub fn frame(bytes: []const u8, maximum: usize) !sessions.protocol.Frame {
        const parsed = try sessions.frame(bytes, maximum);
        return .{ .body = parsed.body, .length = parsed.length };
    }

    pub fn decode(self: *Wire, input: []const u8, destination: []u8, workspace: *Workspace, threshold: ?usize) ![]const u8 {
        return if (self.compressed) try workspace.decode(input, threshold, destination) else input;
    }

    pub fn control(self: *Wire, packet: []const u8, scratch: []u8, output: []u8, workspace: *Workspace, threshold: ?usize) ![]const u8 {
        _ = scratch;
        const result = if (self.compressed and packet.len >= threshold.?)
            try workspace.compress(packet, output)
        else blk: {
            const zero: usize = @intFromBool(self.compressed);
            if (packet.len + zero > output.len - 3) return error.BufferTooSmall;
            output[3] = 0;
            @memcpy(output[3 + zero ..][0..packet.len], packet);
            break :blk frameOutput(output, packet.len + zero);
        };
        self.send(@constCast(result));
        return result;
    }

    pub fn shared(workspace: *Workspace, storage: []u8, length: usize, threshold: ?usize, destination: []u8) ![]const u8 {
        return workspace.encode(storage, length, threshold, destination);
    }
};

fn frameOutput(storage: []u8, length: usize) []const u8 {
    std.debug.assert(length > 0 and length <= compression.maximum and length <= storage.len - 3);
    const prefix: usize = if (length < 128) 1 else if (length < 16384) 2 else 3;
    for (storage[3 - prefix .. 3], 0..) |*byte, i|
        byte.* = @as(u8, @intCast((length >> @intCast(i * 7)) & 127)) | (@as(u8, @intFromBool(i + 1 < prefix)) << 7);
    return storage[3 - prefix .. 3 + length];
}
