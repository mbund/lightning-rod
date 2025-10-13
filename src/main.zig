const std = @import("std");
const protocol = @import("protocol");
const net = std.net;
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

test {
    _ = @import("varint.zig");
    _ = @import("protocol_test.zig");
}

const VarInt = @import("varint.zig").VarInt;
const String = @import("string.zig").String;

const log = std.log.scoped(.tcp_epoll_server);

const nbt = @import("nbt.zig");

pub fn writeNbtFile(name: []const u8, data: nbt.NbtData) !void {
    const file = try std.fs.cwd().createFile(name, .{});
    defer file.close();
    var buf = std.mem.zeroes([16384]u8);
    var file_writer = file.writer(&buf);
    try data.write(&file_writer.interface);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var list = std.ArrayList(nbt.NbtData){};
    try list.append(allocator, nbt.NbtData{ .name = @constCast("first"), .data = nbt.NbtPayload{ .long = 123456 } });
    try list.append(allocator, nbt.NbtData{ .name = @constCast("second"), .data = nbt.NbtPayload{ .float = 0.5 } });

    const data = nbt.NbtData{ .name = @constCast(""), .data = nbt.NbtPayload{ .compound = list } };
    try writeNbtFile("out", data);

    var server = try Server.init(allocator, 4096);
    defer server.deinit();

    const address = try std.net.Address.parseIp("127.0.0.1", 25565);
    try server.run(address);
}

const Server = struct {
    /// Maximum number of allowed clients
    max: usize,

    /// The number of clients we currently have connected
    connected: usize,

    loop: Epoll,

    allocator: Allocator,
    client_pool: std.heap.MemoryPool(Client),

    fn init(allocator: Allocator, max: usize) !Server {
        const loop = try Epoll.init();
        errdefer loop.deinit();

        return .{
            .max = max,
            .connected = 0,
            .loop = loop,
            .allocator = allocator,
            .client_pool = std.heap.MemoryPool(Client).init(allocator),
        };
    }

    fn deinit(self: *Server) void {
        self.loop.deinit();
        self.client_pool.deinit();
    }

    fn run(self: *Server, address: std.net.Address) !void {
        const listener = try posix.socket(address.any.family, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, posix.IPPROTO.TCP);
        defer posix.close(listener);

        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.bind(listener, &address.any, address.getOsSockLen());
        try posix.listen(listener, 128);

        try self.loop.addListener(listener);

        while (true) {
            const ready_events = self.loop.wait(-1);
            for (ready_events) |ready| {
                switch (ready.data.ptr) {
                    0 => self.accept(listener) catch |err| log.err("failed to accept: {}", .{err}),
                    else => |nptr| {
                        const events = ready.events;
                        const client: *Client = @ptrFromInt(nptr);

                        if (events & linux.EPOLL.IN == linux.EPOLL.IN) {
                            // this socket is ready to be read
                            while (true) {
                                const msg = client.readMessage() catch {
                                    self.closeClient(client);
                                    break;
                                } orelse break; // no more messages

                                if (client.state == .handshaking) {
                                    const c1 = protocol.handshaking.toServer.read(msg);
                                    // handshake
                                    switch (try c1.name()) {
                                        .set_protocol => |c2| {
                                            const protocol_version, const c3 = try c2.protocolVersion();
                                            const server_address, const c4 = try c3.serverHost();
                                            const server_port, const c5 = try c4.serverPort();
                                            const intent, const c6 = try c5.nextState();
                                            try c6.finish();

                                            log.info("handshake protocol_version={} server_address={s} server_port={} intent={}", .{ protocol_version, server_address, server_port, intent });

                                            if (intent == 1) {
                                                client.state = .status;

                                                var output = std.io.Writer.fixed(client.write_buf[2..]);
                                                _ = try VarInt.write(&output, 0);
                                                _ = try String.write(&output,
                                                    \\{"version":{"name":"1.21.8","protocol":772},"players":{"max":20,"online":1,"sample":[{"name":"cakeless","id":"0341ed27-7393-4e6a-9101-6c07f879b7b3"}]},"description":{"text":"Hello, world!"}}
                                                );

                                                // packet length is a maximum of 3 byte varint
                                                @memset(client.write_buf[1..3], 0);
                                                var final_output = std.io.Writer.fixed(client.write_buf[0..3]);
                                                _ = try VarInt.write(&final_output, @intCast(output.end));
                                                client.to_write = client.write_buf[0 .. 2 + output.end];
                                                try client.write();
                                            } else if (intent == 2) {
                                                client.state = .login;
                                            }
                                        },
                                        else => {},
                                    }
                                } else if (client.state == .status) {
                                    const c1 = protocol.status.toServer.read(msg);
                                    switch (try c1.name()) {
                                        .ping => |c2| {
                                            const timestamp, const c3 = try c2.time();
                                            try c3.finish();
                                            log.info("ping request timestamp={}", .{timestamp});

                                            var output = std.io.Writer.fixed(client.write_buf[1..]);
                                            _ = try VarInt.write(&output, 1);
                                            try output.writeInt(i64, timestamp, std.builtin.Endian.big);

                                            // std.posix.nanosleep(0, 20 * 1000 * 1000);

                                            var final_output = std.io.Writer.fixed(client.write_buf[0..1]);
                                            _ = try VarInt.write(&final_output, @intCast(output.end));
                                            client.to_write = client.write_buf[0 .. 1 + output.end];
                                            try client.write();
                                        },
                                        else => {
                                            log.info("status request", .{});
                                        },
                                    }
                                } else if (client.state == .login) {
                                    const c1 = protocol.login.toServer.read(msg);
                                    switch (try c1.name()) {
                                        .login_start => |c2| {
                                            const player_name, const c3 = try c2.username();
                                            const uuid, const c4 = try c3.playerUUID();
                                            try c4.finish();
                                            log.info("login start name={s} uuid={}", .{ player_name, uuid });
                                        },
                                        else => {},
                                    }
                                }
                            }
                        } else if (events & linux.EPOLL.OUT == linux.EPOLL.OUT) {
                            client.write() catch self.closeClient(client);
                        }
                    },
                }
            }
        }
    }

    fn accept(self: *Server, listener: posix.socket_t) !void {
        const space = self.max - self.connected;
        for (0..space) |_| {
            var address: net.Address = undefined;
            var address_len: posix.socklen_t = @sizeOf(net.Address);
            const socket = posix.accept(listener, &address.any, &address_len, posix.SOCK.NONBLOCK) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };

            log.info("ACCEPT {f}", .{address});

            const client = try self.client_pool.create();
            errdefer self.client_pool.destroy(client);
            client.* = Client.init(self.allocator, socket, address, &self.loop) catch |err| {
                posix.close(socket);
                log.err("failed to initialize client: {}", .{err});
                return;
            };
            errdefer client.deinit(self.allocator);

            try self.loop.newClient(client);
            self.connected += 1;
        } else {
            // we've run out of space, stop monitoring the listening socket
            try self.loop.removeListener(listener);
        }
    }

    fn closeClient(self: *Server, client: *Client) void {
        log.info("CLOSE {f}", .{client.address});
        posix.close(client.socket);
        client.deinit(self.allocator);
        self.client_pool.destroy(client);
    }
};

const ConnectionState = enum {
    handshaking,
    status,
    login,
};

const Client = struct {
    epoll: *Epoll,
    mode: Epoll.IOMode = .read,

    socket: posix.socket_t,
    address: std.net.Address,

    reader: Reader,

    // Bytes we still need to send. This is a slice of `write_buf`. When
    // empty, then we're in "read-mode" and are waiting for a message from the
    // client.
    to_write: []u8,

    // Buffer for storing our length-prefixed messaged
    write_buf: []u8,

    state: ConnectionState = .handshaking,

    fn init(allocator: Allocator, socket: posix.socket_t, address: std.net.Address, loop: *Epoll) !Client {
        const reader = try Reader.init(allocator, 4096);
        errdefer reader.deinit(allocator);

        const write_buf = try allocator.alloc(u8, 4096);
        errdefer allocator.free(write_buf);

        return .{
            .epoll = loop,
            .reader = reader,
            .socket = socket,
            .address = address,
            .to_write = &.{},
            .write_buf = write_buf,
        };
    }

    fn deinit(self: *const Client, allocator: Allocator) void {
        self.reader.deinit(allocator);
        allocator.free(self.write_buf);
    }

    fn readMessage(self: *Client) !?[]const u8 {
        return self.reader.readMessage(self.socket) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
    }

    // Returns `false` if we didn't manage to write the whole mssage
    // Returns `true` if the message is fully written
    fn write(self: *Client) !void {
        var buf = self.to_write;
        defer self.to_write = buf;
        while (buf.len > 0) {
            const n = posix.write(self.socket, buf) catch |err| switch (err) {
                error.WouldBlock => return self.setEpollMode(.write),
                else => return err,
            };

            if (n == 0) {
                return error.Closed;
            }
            buf = buf[n..];
        } else {
            return self.setEpollMode(.read);
        }
    }

    fn setEpollMode(self: *Client, mode: Epoll.IOMode) !void {
        if (mode != self.mode) {
            self.mode = mode;
            switch (self.mode) {
                .read => try self.epoll.readMode(self),
                .write => try self.epoll.writeMode(self),
            }
        }
    }
};

const Reader = struct {
    buf: []u8,
    pos: usize = 0,
    start: usize = 0,

    fn init(allocator: Allocator, size: usize) !Reader {
        const buf = try allocator.alloc(u8, size);
        return .{
            .pos = 0,
            .start = 0,
            .buf = buf,
        };
    }

    fn deinit(self: *const Reader, allocator: Allocator) void {
        allocator.free(self.buf);
    }

    fn readMessage(self: *Reader, socket: posix.socket_t) ![]u8 {
        var buf = self.buf;

        while (true) {
            if (try self.bufferedMessage()) |msg| {
                return msg;
            }
            const pos = self.pos;
            const n = try posix.read(socket, buf[pos..]);
            if (n == 0) {
                return error.Closed;
            }
            self.pos = pos + n;
        }
    }

    fn bufferedMessage(self: *Reader) !?[]u8 {
        const buf = self.buf;
        const pos = self.pos;
        const start = self.start;

        std.debug.assert(pos >= start);
        const unprocessed = buf[start..pos];
        // The length field cannot be longer than 3 bytes. We assume (wrongly) that a message has
        // at least 3 bytes including its message length varint
        if (unprocessed.len < 3) {
            self.ensureSpace(3 - unprocessed.len) catch unreachable;
            return null;
        }

        var input = std.io.Reader.fixed(unprocessed);
        const len = try VarInt.read(&input);
        if (len < 0) {
            @panic("negative message length");
        }
        const message_len: usize = @intCast(len);
        const total_len = message_len + input.seek;

        if (unprocessed.len < total_len) {
            try self.ensureSpace(total_len);
            return null;
        }

        self.start += total_len;
        return unprocessed[input.seek..total_len];
    }

    fn ensureSpace(self: *Reader, space: usize) error{BufferTooSmall}!void {
        const buf = self.buf;
        if (buf.len < space) {
            return error.BufferTooSmall;
        }

        const start = self.start;
        const spare = buf.len - start;
        if (spare >= space) {
            return;
        }

        const unprocessed = buf[start..self.pos];
        @memmove(buf[0..unprocessed.len], unprocessed);
        self.start = 0;
        self.pos = unprocessed.len;
    }
};

const Epoll = struct {
    efd: posix.fd_t,
    ready_list: [128]linux.epoll_event = undefined,

    pub const IOMode = enum {
        read,
        write,
    };

    fn init() !Epoll {
        const efd = try posix.epoll_create1(0);
        return .{ .efd = efd };
    }

    fn deinit(self: Epoll) void {
        posix.close(self.efd);
    }

    fn wait(self: *Epoll, timeout: i32) []linux.epoll_event {
        const count = posix.epoll_wait(self.efd, &self.ready_list, timeout);
        return self.ready_list[0..count];
    }

    fn addListener(self: Epoll, listener: posix.socket_t) !void {
        var event = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .ptr = 0 },
        };
        try posix.epoll_ctl(self.efd, linux.EPOLL.CTL_ADD, listener, &event);
    }

    fn removeListener(self: Epoll, listener: posix.socket_t) !void {
        try posix.epoll_ctl(self.efd, linux.EPOLL.CTL_DEL, listener, null);
    }

    fn newClient(self: Epoll, client: *Client) !void {
        var event = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .ptr = @intFromPtr(client) },
        };
        try posix.epoll_ctl(self.efd, linux.EPOLL.CTL_ADD, client.socket, &event);
    }

    fn readMode(self: Epoll, client: *Client) !void {
        log.info("Setting read mode", .{});
        var event = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .ptr = @intFromPtr(client) },
        };
        try posix.epoll_ctl(self.efd, linux.EPOLL.CTL_MOD, client.socket, &event);
    }

    fn writeMode(self: Epoll, client: *Client) !void {
        log.info("Setting write mode", .{});
        var event = linux.epoll_event{
            .events = linux.EPOLL.OUT,
            .data = .{ .ptr = @intFromPtr(client) },
        };
        try posix.epoll_ctl(self.efd, linux.EPOLL.CTL_MOD, client.socket, &event);
    }
};
