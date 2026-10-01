const std = @import("std");
const sessions = @import("sessions");

const flate = std.compress.flate;
const assert = std.debug.assert;

pub const headroom = sessions.shared_headroom;
pub const maximum = (1 << 21) - 1;
pub const Error = error{ InvalidPacket, BufferTooSmall };

pub const Workspace = struct {
    compressor: flate.Compress = undefined,
    window: [flate.max_window_len]u8 = undefined,

    /// Payload starts at headroom. Uncompressed framing borrows it in place. Compressed framing
    /// borrows destination. Neither survives reuse of its owner.
    pub fn encode(self: *Workspace, storage: []u8, length: usize, threshold: ?usize, destination: []u8) Error![]const u8 {
        if (length == 0 or length > maximum) return error.InvalidPacket;
        if (storage.len < headroom or length > storage.len - headroom) return error.BufferTooSmall;
        if (threshold) |limit| {
            if (length >= limit) return self.compress(storage[headroom..][0..length], destination);
        }

        const end = headroom + length;
        var start: usize = headroom;
        if (threshold != null) {
            start -= 1;
            storage[start] = 0;
        }
        const body_length = end - start;
        if (body_length > maximum) return error.InvalidPacket;
        const prefix = width(body_length);
        start -= prefix;
        write(storage[start..][0..prefix], body_length);
        assert(end <= storage.len);
        return storage[start..end];
    }

    pub fn compress(self: *Workspace, packet: []const u8, destination: []u8) Error![]const u8 {
        if (packet.len == 0 or packet.len > maximum) return error.InvalidPacket;
        if (destination.len < headroom + 9) return error.BufferTooSmall;

        var writer: std.Io.Writer = .fixed(destination[headroom..]);
        self.compressor = flate.Compress.init(&writer, &self.window, .zlib, .level_1) catch return error.BufferTooSmall;
        self.compressor.writer.writeAll(packet) catch return error.BufferTooSmall;
        self.compressor.finish() catch return error.BufferTooSmall;

        const end = headroom + writer.buffered().len;
        var start = headroom - width(packet.len);
        write(destination[start..headroom], packet.len);
        const body_length = end - start;
        if (body_length > maximum) return error.InvalidPacket;
        const prefix = width(body_length);
        start -= prefix;
        write(destination[start..][0..prefix], body_length);
        assert(end <= destination.len);
        return destination[start..end];
    }

    /// Input excludes the outer frame length. Plain payloads borrow input. Inflated payloads borrow
    /// destination. Both expire when their owner reuses it.
    pub fn decode(self: *Workspace, input: []const u8, threshold: ?usize, destination: []u8) Error![]const u8 {
        if (input.len == 0 or input.len > maximum) return error.InvalidPacket;

        const limit = threshold orelse return input;
        var length: usize = 0;
        var prefix: usize = 0;

        while (true) {
            if (prefix == 3 or prefix == input.len) return error.InvalidPacket;

            const byte = input[prefix];
            length |= @as(usize, byte & 127) << @intCast(7 * prefix);
            prefix += 1;
            if (byte & 128 == 0) break;
        }

        const body = input[prefix..];
        if (length == 0) {
            if (body.len == 0 or body.len >= limit) return error.InvalidPacket;
            return body;
        }

        if (length < limit or length > maximum) return error.InvalidPacket;
        if (length > destination.len) return error.BufferTooSmall;

        var source: std.Io.Reader = .fixed(body);
        var decompressor = flate.Decompress.init(&source, .zlib, &self.window);
        decompressor.reader.readSliceAll(destination[0..length]) catch return error.InvalidPacket;

        if (decompressor.reader.takeByte()) |_| {
            return error.InvalidPacket;
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return error.InvalidPacket,
        }

        if (source.seek != body.len or decompressor.container_metadata.zlib.adler != std.hash.Adler32.hash(destination[0..length]))
            return error.InvalidPacket;
        return destination[0..length];
    }
};

fn width(value: usize) usize {
    assert(value > 0 and value <= maximum);
    return 1 + @as(usize, @intFromBool(value >= 128)) + @as(usize, @intFromBool(value >= 16384));
}

fn write(bytes: []u8, value: usize) void {
    assert(bytes.len == width(value));

    for (bytes, 0..) |*byte, i| byte.* = @as(u8, @intCast((value >> @intCast(i * 7)) & 127)) | (@as(u8, @intFromBool(i + 1 < bytes.len)) << 7);
}
