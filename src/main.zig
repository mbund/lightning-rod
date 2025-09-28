const std = @import("std");
const net = std.net;
const posix = std.posix;

const _ = @import("varint.zig");
const VarInt = @import("varint.zig").VarInt;
const String = @import("string.zig").String;

pub fn main() !void {
    const address = try std.net.Address.parseIp("127.0.0.1", 25566);

    const tpe: u32 = posix.SOCK.STREAM;
    const protocol = posix.IPPROTO.TCP;
    const listener = try posix.socket(address.any.family, tpe, protocol);
    defer posix.close(listener);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, 1024);

    var buf: [1024]u8 = undefined;
    while (true) {
        var client_address: net.Address = undefined;
        var client_address_len: posix.socklen_t = @sizeOf(net.Address);
        const socket = posix.accept(listener, &client_address.any, &client_address_len, 0) catch |err| {
            // Rare that this happens, but in later parts we'll
            // see examples where it does.
            std.debug.print("error accept: {}\n", .{err});
            continue;
        };
        defer posix.close(socket);

        // std.debug.print("{any} connected\n", .{client_address});

        const read = posix.read(socket, &buf) catch |err| {
            std.debug.print("error reading: {}\n", .{err});
            continue;
        };

        if (read == 0) {
            continue;
        }

        std.debug.print("got {}: {any}\n", .{ read, buf[0..read] });

        // var stream = std.io.fixedBufferStream(buf[0..read]);
        var input = std.io.Reader.fixed(buf[0..read]);

        const length = try VarInt.read(&input);
        std.debug.print("length: {}\n", .{length});

        const packet_id = try VarInt.read(&input);
        std.debug.print("packet_id: {}\n", .{packet_id});

        const protocol_version = try VarInt.read(&input);
        std.debug.print("protocol_version: {}\n", .{protocol_version});

        if (packet_id == 0) {
            const s = try String.read(&input);
            std.debug.print("s: {s}\n", .{s});

            const server_port = try input.takeInt(u16, std.builtin.Endian.big);
            std.debug.print("server_port: {}\n", .{server_port});

            const intent = try VarInt.read(&input);
            std.debug.print("intent: {}\n", .{intent});

            var output_buffer: [1024]u8 = undefined;
            var output = std.io.Writer.fixed(output_buffer[5..]);
            var total = try VarInt.write(&output, 0);
            total += try String.write(&output,
                \\{"version":{"name":"1.21.8","protocol":772},"players":{"max":20,"online":1,"sample":[{"name":"cakeless","id":"0541ed27-7595-4e6a-9101-6c07f879b7b5"}]},"description":{"text":"Hello, world!"}}
            );
            try output.flush();

            var final_output = std.io.Writer.fixed(&output_buffer);
            const packet_length_length = try VarInt.write(&final_output, @intCast(total));
            std.debug.print("packet_length_length: {}\n", .{packet_length_length});
            @memmove(output_buffer[5 - packet_length_length .. 5], output_buffer[0..packet_length_length]);
            std.debug.print("sending {}: {any}\n", .{ total + 5, output_buffer[4 .. total + 5] });
            write(socket, output_buffer[5 - packet_length_length .. total + 5]) catch |err| {
                // This can easily happen, say if the client disconnects.
                std.debug.print("error writing: {}\n", .{err});
            };
        }
    }
}

fn write(socket: posix.socket_t, msg: []const u8) !void {
    var pos: usize = 0;
    while (pos < msg.len) {
        const written = try posix.write(socket, msg[pos..]);
        if (written == 0) {
            return error.Closed;
        }
        pos += written;
    }
}
