const std = @import("std");
const protocol = @import("protocol.zig");

/// Decoding input on the sessions thread: one frame's packet before Play, and a run of Play
/// frames decrypted as they arrived.
pub fn Decoding(comptime Endpoint: type) type {
    return struct {
        pub const Result = struct { bytes: []const u8 = &.{}, consumed: usize = 0, input: ?protocol.Packets = null, needs_output: bool = false };
        pub const Decode = struct { connection: *Endpoint.Connection, bytes: []const u8, output: []u8, threshold: ?usize };
        pub const DecodeBatch = struct {
            connection: *Endpoint.Connection,
            bytes: []const u8,
            output: []u8,
            packets: [][]const u8,
            threshold: ?usize,
            maximum: usize,
        };

        pub fn decode(workspaces: *Endpoint.Workspaces, request: Decode) !Result {
            const bytes = Endpoint.decode(request.connection, workspaces, request.bytes, request.output, request.threshold) catch |err| {
                if (err == error.BufferTooSmall) return .{ .needs_output = true };
                return err;
            };
            return .{ .bytes = bytes };
        }

        /// As many whole frames as the packets and output hold, decoded. Output too small for
        /// the first asks for a larger one.
        pub fn decodeBatch(workspaces: *Endpoint.Workspaces, request: DecodeBatch) !Result {
            var consumed: usize = 0;
            var written: usize = 0;
            var count: usize = 0;
            while (consumed < request.bytes.len and count < request.packets.len) {
                const frame = Endpoint.frame(request.connection, request.bytes[consumed..], request.maximum) catch |err| {
                    if (err == error.Incomplete) break;
                    return err;
                };
                if (frame.body.len == 0) return error.InvalidPacket;
                const destination = request.output[written..];
                const payload = Endpoint.decode(request.connection, workspaces, frame.body, destination, request.threshold) catch |err| {
                    if (err == error.BufferTooSmall) {
                        if (count != 0) break;
                        return .{ .needs_output = true };
                    }
                    return err;
                };
                if (payload.len == 0 or payload.len > request.maximum) return error.InvalidPacket;
                if (payload.ptr == destination.ptr) {
                    std.debug.assert(payload.len <= destination.len);
                    written += payload.len;
                }
                request.packets[count] = payload;
                count += 1;
                consumed += frame.length;
            }
            return .{ .consumed = consumed, .input = .{ .packets = request.packets[0..count] } };
        }
    };
}
