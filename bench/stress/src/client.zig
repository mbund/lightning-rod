const std = @import("std");
const protocols = @import("protocols");
const java = @import("minecraft_java");

const Version = protocols.version("26.2");
const Protocol = Version.Protocol;
const maximum = 2 * 1024 * 1024;

pub const Client = struct {
    io: std.Io,
    address: std.Io.net.IpAddress,
    index: usize,
    played: bool = false,
    bytes: usize = 0,
    packets: usize = 0,
    chunks: usize = 0,
    chunk_bytes: usize = 0,
    unloads: usize = 0,
    failure: ?anyerror = null,

    pub fn run(self: *Client) void {
        self.connect() catch |err| {
            self.failure = err;
        };
    }

    fn connect(self: *Client) !void {
        const allocator = std.heap.page_allocator;
        const input = try allocator.alloc(u8, maximum);
        defer allocator.free(input);
        const decoded = try allocator.alloc(u8, maximum);
        defer allocator.free(decoded);
        const storage = try allocator.alloc(u8, 65536);
        defer allocator.free(storage);
        var workspace = try java.Wire.Workspace.init(allocator);
        defer workspace.deinit();
        var codec: java.Wire = .{};
        const stream = try self.address.connect(self.io, .{ .mode = .stream });
        defer stream.close(self.io);
        var reader = stream.reader(self.io, storage);
        var writer_buffer: [1024]u8 = undefined;
        var writer = stream.writer(self.io, &writer_buffer);
        var packet: [512]u8 = undefined;
        var raw: std.Io.Writer = .fixed(&packet);
        try varint(&raw, 0);
        try varint(&raw, Version.protocol_number);
        try varint(&raw, 9);
        try raw.writeAll("localhost");
        try raw.writeInt(u16, self.address.getPort(), .big);
        try varint(&raw, 2);
        try send(&writer.interface, raw.buffered(), false);
        var name_buffer: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "stress_{d}", .{self.index});
        const hello = try Protocol.login.toServer.write(&packet).login_start();
        try send(&writer.interface, (try (try hello.username(name)).playerUUID(0)).finish(), false);
        var phase: enum { login, configuration, play } = .login;
        while (true) {
            const length = readVarint(&reader.interface) catch |err| {
                if (err == error.EndOfStream and self.played) return;
                return err;
            };
            if (length == 0 or length > input.len) return error.InvalidFrameLength;
            try reader.interface.readSliceAll(input[0..length]);
            self.bytes += length;
            self.packets += 1;
            const body = try codec.decode(input[0..length], decoded, &workspace, 256);
            switch (phase) {
                .login => {
                    const header = try Protocol.login.toClient.readHeader(body);
                    if (header.id == Protocol.login.toClient.packetId(.compress)) {
                        codec.compressed = true;
                    } else if (header.id == Protocol.login.toClient.packetId(.success)) {
                        try send(&writer.interface, (try Protocol.login.toServer.write(&packet).login_acknowledged()).finish(), codec.compressed);
                        phase = .configuration;
                    } else if (header.id == Protocol.login.toClient.packetId(.disconnect)) return error.LoginRejected;
                },
                .configuration => {
                    const header = try Protocol.configuration.toClient.readHeader(body);
                    if (header.id == Protocol.configuration.toClient.packetId(.finish_configuration)) {
                        try send(&writer.interface, (try Protocol.configuration.toServer.write(&packet).finish_configuration()).finish(), codec.compressed);
                        phase = .play;
                        self.played = true;
                    } else if (header.id == Protocol.configuration.toClient.packetId(.disconnect)) return error.ConfigurationRejected;
                },
                .play => {
                    const header = try Protocol.play.toClient.readHeader(body);
                    if (header.id == Protocol.play.toClient.packetId(.position)) {
                        const position = try Protocol.play.toClient.readBody(.position, header);
                        const id, _ = try position.teleportId();
                        try send(&writer.interface, (try (try Protocol.play.toServer.write(&packet).teleport_confirm()).teleportId(id)).finish(), codec.compressed);
                        try send(&writer.interface, (try Protocol.play.toServer.write(&packet).player_loaded()).finish(), codec.compressed);
                    } else if (header.id == Protocol.play.toClient.packetId(.keep_alive)) {
                        const keepalive = try Protocol.play.toClient.readBody(.keep_alive, header);
                        const id, _ = try keepalive.keepAliveId();
                        try send(&writer.interface, (try (try Protocol.play.toServer.write(&packet).keep_alive()).keepAliveId(id)).finish(), codec.compressed);
                    } else if (header.id == Protocol.play.toClient.packetId(.map_chunk)) {
                        self.chunks += 1;
                        self.chunk_bytes += length;
                    } else if (header.id == Protocol.play.toClient.packetId(.unload_chunk)) {
                        self.unloads += 1;
                    } else if (header.id == Protocol.play.toClient.packetId(.kick_disconnect)) return;
                },
            }
        }
    }
};

fn send(writer: *std.Io.Writer, packet: []const u8, compressed: bool) !void {
    try varint(writer, @intCast(packet.len + @intFromBool(compressed)));
    if (compressed) try writer.writeByte(0);
    try writer.writeAll(packet);
    try writer.flush();
}

fn readVarint(reader: *std.Io.Reader) !u32 {
    var result: u32 = 0;
    for (0..5) |index| {
        const byte = try reader.takeByte();
        if (index == 4 and byte > 15) return error.InvalidVarint;
        result |= @as(u32, byte & 127) << @intCast(index * 7);
        if (byte & 128 == 0) return result;
    }
    return error.InvalidVarint;
}

fn varint(writer: *std.Io.Writer, value: u32) !void {
    var rest = value;
    while (rest >= 128) {
        try writer.writeByte(@as(u8, @truncate(rest)) | 128);
        rest >>= 7;
    }
    try writer.writeByte(@intCast(rest));
}
