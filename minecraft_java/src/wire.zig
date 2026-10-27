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

    pub fn encrypt(self: *Wire, source: []const u8, destination: []u8) void {
        self.send_cipher.?.transform(.encrypt, source, destination);
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

    pub fn control(self: *Wire, packet: sessions.protocol.Packet, output: []u8, workspace: *Workspace, threshold: ?usize) !sessions.protocol.Fragments {
        const source = switch (packet) {
            .buffered => |value| value.storage[compression.headroom..][0..value.length],
            .borrowed => |bytes| bytes,
        };
        if (source.len == 0 or source.len > compression.maximum) return error.InvalidPacket;
        if (threshold != null and source.len >= threshold.?) {
            const result = try workspace.compress(source, output);
            self.send(result);
            return .{ .first = result };
        }
        if (packet == .buffered) {
            const value = packet.buffered;
            const result = try workspace.encode(value.storage, value.length, threshold, output);
            self.send(result);
            return .{ .first = result };
        }
        const zero: usize = @intFromBool(threshold != null);
        const body_length = source.len + zero;
        if (body_length > compression.maximum or output.len < compression.headroom) return error.BufferTooSmall;
        const width: usize = if (body_length < 128) 1 else if (body_length < 16384) 2 else 3;
        for (output[0..width], 0..) |*byte, index| {
            byte.* = @as(u8, @intCast((body_length >> @intCast(index * 7)) & 127)) | (@as(u8, @intFromBool(index + 1 < width)) << 7);
        }
        if (threshold != null) output[width] = 0;
        const prefix = width + zero;
        if (self.encrypted()) {
            if (source.len > output.len - prefix) return error.BufferTooSmall;
            self.send(output[0..prefix]);
            self.encrypt(source, output[prefix..][0..source.len]);
            return .{ .first = output[0 .. prefix + source.len] };
        }
        return .{ .first = output[0..prefix], .second = source };
    }

    pub fn shared(workspace: *Workspace, storage: []u8, length: usize, threshold: ?usize, destination: []u8) ![]const u8 {
        return workspace.encode(storage, length, threshold, destination);
    }
};
