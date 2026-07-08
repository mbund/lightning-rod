const std = @import("std");
const protocol = @import("protocol");
const protocol_support = @import("protocol_support");
const net = std.Io.net;
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

test {
    _ = @import("protocol_test.zig");
}

const log = std.log.scoped(.tcp_epoll_server);

const max_packet_prefix_len = 5;
const status_response_json =
    \\{"version":{"name":"1.21.8","protocol":772},"players":{"max":20,"online":0},"description":{"text":"lightning-rod"}}
;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try Server.init(allocator, 4096);
    defer server.deinit();

    const address = try net.IpAddress.parse("127.0.0.1", 25565);
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
            .client_pool = .empty,
        };
    }

    fn deinit(self: *Server) void {
        self.loop.deinit();
        self.client_pool.deinit(self.allocator);
    }

    fn run(self: *Server, address: net.IpAddress) !void {
        const listener = try linuxSocket(posixAddressFamily(&address), linux.SOCK.STREAM | linux.SOCK.NONBLOCK, linux.IPPROTO.TCP);
        defer linuxClose(listener);

        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        var storage: PosixAddress = undefined;
        const address_len = addressToPosix(&address, &storage);
        try linuxBind(listener, &storage.any, address_len);
        try linuxListen(listener, 128);

        try self.loop.addListener(listener);

        while (true) {
            const ready_events = try self.loop.wait(-1);
            for (ready_events) |ready| {
                switch (ready.data.ptr) {
                    0 => self.accept(listener) catch |err| log.err("failed to accept: {}", .{err}),
                    else => |nptr| {
                        const events = ready.events;
                        const client: *Client = @ptrFromInt(nptr);

                        if (events & linux.EPOLL.IN == linux.EPOLL.IN) {
                            while (true) {
                                const msg = client.readMessage() catch {
                                    self.closeClient(client);
                                    break;
                                } orelse break; // no more messages

                                client.handlePacket(msg) catch |err| {
                                    log.err("protocol error from {f}: {}", .{ client.address, err });
                                    self.closeClient(client);
                                    break;
                                };
                                if (client.to_write.len != 0) {
                                    client.write() catch {
                                        self.closeClient(client);
                                        break;
                                    };
                                    if (client.to_write.len != 0) break;
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
            var posix_address: PosixAddress = undefined;
            var address_len: posix.socklen_t = @sizeOf(PosixAddress);
            const socket = linuxAccept(listener, &posix_address.any, &address_len, linux.SOCK.NONBLOCK) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            const address = addressFromPosix(&posix_address);

            log.info("ACCEPT {f}", .{address});

            const client = try self.client_pool.create(self.allocator);
            errdefer self.client_pool.destroy(client);
            client.* = Client.init(self.allocator, socket, address, &self.loop) catch |err| {
                linuxClose(socket);
                log.err("failed to initialize client: {}", .{err});
                return;
            };
            errdefer client.deinit(self.allocator);

            try self.loop.newClient(client);
            self.connected += 1;
        }
    }

    fn closeClient(self: *Server, client: *Client) void {
        log.info("CLOSE {f}", .{client.address});
        linuxClose(client.socket);
        client.deinit(self.allocator);
        self.client_pool.destroy(client);
        std.debug.assert(self.connected > 0);
        self.connected -= 1;
    }
};

const ConnectionState = enum {
    handshaking,
    status,
};

const Client = struct {
    epoll: *Epoll,
    mode: Epoll.IOMode = .read,

    socket: posix.socket_t,
    address: net.IpAddress,

    reader: Reader,

    // Bytes still pending from write_buf. Empty means the client is in read mode.
    to_write: []u8,

    // Scratch space for encoded length-prefixed packets.
    write_buf: []u8,

    state: ConnectionState = .handshaking,

    fn init(allocator: Allocator, socket: posix.socket_t, address: net.IpAddress, loop: *Epoll) !Client {
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

    fn handlePacket(self: *Client, msg: []const u8) !void {
        switch (self.state) {
            .handshaking => try self.handleHandshake(msg),
            .status => try self.handleStatus(msg),
        }
    }

    fn handleHandshake(self: *Client, msg: []const u8) !void {
        const packet = protocol.handshaking.toServer.read(msg);
        switch (try packet.name()) {
            .set_protocol => |body| {
                const protocol_version, const c2 = try body.protocolVersion();
                const server_address, const c3 = try c2.serverHost();
                const server_port, const c4 = try c3.serverPort();
                const intent, const done = try c4.nextState();
                try done.finish();

                log.info("handshake protocol={} host={s} port={} intent={}", .{ protocol_version, server_address, server_port, intent });
                if (intent != 1) return error.UnsupportedIntent;
                self.state = .status;
            },
            else => return error.UnexpectedPacket,
        }
    }

    fn handleStatus(self: *Client, msg: []const u8) !void {
        const packet = protocol.status.toServer.read(msg);
        switch (try packet.name()) {
            .ping_start => |body| {
                try body.finish();
                try self.queueStatusResponse();
            },
            .ping => |body| {
                const timestamp, const done = try body.time();
                try done.finish();
                try self.queuePong(timestamp);
            },
            else => return error.UnexpectedPacket,
        }
    }

    fn queueStatusResponse(self: *Client) !void {
        const body_buffer = self.write_buf[max_packet_prefix_len..];
        const c1 = protocol.status.toClient.write(body_buffer);
        const c2 = try c1.server_info();
        const done = try c2.response(status_response_json);
        try self.queueFramed(done.finish());
    }

    fn queuePong(self: *Client, timestamp: i64) !void {
        const body_buffer = self.write_buf[max_packet_prefix_len..];
        const c1 = protocol.status.toClient.write(body_buffer);
        const c2 = try c1.ping();
        const done = try c2.time(timestamp);
        try self.queueFramed(done.finish());
    }

    fn queueFramed(self: *Client, body: []u8) !void {
        std.debug.assert(body.ptr == self.write_buf[max_packet_prefix_len..].ptr);
        if (body.len > @as(usize, @intCast(std.math.maxInt(i32)))) return error.PacketTooLarge;

        var prefix: [max_packet_prefix_len]u8 = undefined;
        const prefix_rest = try protocol_support.write_varint(&prefix, @intCast(body.len));
        const prefix_len = prefix.len - prefix_rest.len;
        const packet_start = max_packet_prefix_len - prefix_len;
        @memcpy(self.write_buf[packet_start..max_packet_prefix_len], prefix[0..prefix_len]);
        self.to_write = self.write_buf[packet_start .. max_packet_prefix_len + body.len];
    }

    fn write(self: *Client) !void {
        var buf = self.to_write;
        defer self.to_write = buf;
        while (buf.len > 0) {
            const n = linuxWrite(self.socket, buf) catch |err| switch (err) {
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
        if (unprocessed.len == 0) {
            self.ensureSpace(1) catch unreachable;
            return null;
        }

        const len, const payload = protocol_support.read_varint(unprocessed) catch |err| switch (err) {
            error.EndOfStream => {
                if (unprocessed.len >= max_packet_prefix_len) return error.MalformedPacketLength;
                self.ensureSpace(unprocessed.len + 1) catch unreachable;
                return null;
            },
            else => return err,
        };
        if (len < 0) {
            return error.MalformedPacketLength;
        }
        const message_len: usize = @intCast(len);
        const prefix_len = unprocessed.len - payload.len;
        const total_len = prefix_len + message_len;

        if (unprocessed.len < total_len) {
            try self.ensureSpace(total_len);
            return null;
        }

        self.start += total_len;
        return unprocessed[prefix_len..total_len];
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

const PosixAddress = extern union {
    any: posix.sockaddr,
    in: posix.sockaddr.in,
    in6: posix.sockaddr.in6,
};

fn posixAddressFamily(address: *const net.IpAddress) u32 {
    return switch (address.*) {
        .ip4 => linux.AF.INET,
        .ip6 => linux.AF.INET6,
    };
}

fn addressToPosix(address: *const net.IpAddress, storage: *PosixAddress) posix.socklen_t {
    return switch (address.*) {
        .ip4 => |ip4| {
            storage.in = .{
                .port = std.mem.nativeToBig(u16, ip4.port),
                .addr = @bitCast(ip4.bytes),
            };
            return @sizeOf(posix.sockaddr.in);
        },
        .ip6 => |ip6| {
            storage.in6 = .{
                .port = std.mem.nativeToBig(u16, ip6.port),
                .flowinfo = ip6.flow,
                .addr = ip6.bytes,
                .scope_id = ip6.interface.index,
            };
            return @sizeOf(posix.sockaddr.in6);
        },
    };
}

fn addressFromPosix(address: *const PosixAddress) net.IpAddress {
    return switch (address.any.family) {
        linux.AF.INET => .{ .ip4 = .{
            .port = std.mem.bigToNative(u16, address.in.port),
            .bytes = @bitCast(address.in.addr),
        } },
        linux.AF.INET6 => .{ .ip6 = .{
            .port = std.mem.bigToNative(u16, address.in6.port),
            .bytes = address.in6.addr,
            .flow = address.in6.flowinfo,
            .interface = .{ .index = address.in6.scope_id },
        } },
        else => .{ .ip4 = .loopback(0) },
    };
}

fn linuxSocket(domain: u32, socket_type: u32, protocol_id: u32) !posix.socket_t {
    const rc = linux.socket(domain, socket_type, protocol_id);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |err| posix.unexpectedErrno(err),
    };
}

fn linuxBind(fd: posix.socket_t, address: *const posix.sockaddr, address_len: posix.socklen_t) !void {
    const rc = linux.bind(fd, address, address_len);
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => |err| posix.unexpectedErrno(err),
    };
}

fn linuxListen(fd: posix.socket_t, backlog: u32) !void {
    const rc = linux.listen(fd, backlog);
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => |err| posix.unexpectedErrno(err),
    };
}

fn linuxAccept(fd: posix.socket_t, address: *posix.sockaddr, address_len: *posix.socklen_t, flags: u32) !posix.socket_t {
    const rc = linux.accept4(fd, address, address_len, flags);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .AGAIN => error.WouldBlock,
        else => |err| posix.unexpectedErrno(err),
    };
}

fn linuxWrite(fd: posix.socket_t, buffer: []const u8) !usize {
    const rc = linux.write(fd, buffer.ptr, buffer.len);
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .AGAIN => error.WouldBlock,
        else => |err| posix.unexpectedErrno(err),
    };
}

fn linuxClose(fd: posix.fd_t) void {
    switch (linux.errno(linux.close(fd))) {
        .SUCCESS => {},
        else => {},
    }
}

const Epoll = struct {
    efd: posix.fd_t,
    ready_list: [128]linux.epoll_event = undefined,

    pub const IOMode = enum {
        read,
        write,
    };

    fn init() !Epoll {
        const efd = try linuxEpollCreate1(0);
        return .{ .efd = efd };
    }

    fn deinit(self: Epoll) void {
        linuxClose(self.efd);
    }

    fn wait(self: *Epoll, timeout: i32) ![]linux.epoll_event {
        const count = try linuxEpollWait(self.efd, &self.ready_list, timeout);
        return self.ready_list[0..count];
    }

    fn addListener(self: Epoll, listener: posix.socket_t) !void {
        var event = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .ptr = 0 },
        };
        try linuxEpollCtl(self.efd, linux.EPOLL.CTL_ADD, listener, &event);
    }

    fn newClient(self: Epoll, client: *Client) !void {
        var event = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .ptr = @intFromPtr(client) },
        };
        try linuxEpollCtl(self.efd, linux.EPOLL.CTL_ADD, client.socket, &event);
    }

    fn readMode(self: Epoll, client: *Client) !void {
        log.info("Setting read mode", .{});
        var event = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .ptr = @intFromPtr(client) },
        };
        try linuxEpollCtl(self.efd, linux.EPOLL.CTL_MOD, client.socket, &event);
    }

    fn writeMode(self: Epoll, client: *Client) !void {
        log.info("Setting write mode", .{});
        var event = linux.epoll_event{
            .events = linux.EPOLL.OUT,
            .data = .{ .ptr = @intFromPtr(client) },
        };
        try linuxEpollCtl(self.efd, linux.EPOLL.CTL_MOD, client.socket, &event);
    }

    fn linuxEpollCreate1(flags: usize) !posix.fd_t {
        const rc = linux.epoll_create1(flags);
        return switch (linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            else => |err| posix.unexpectedErrno(err),
        };
    }

    fn linuxEpollWait(efd: posix.fd_t, events: []linux.epoll_event, timeout: i32) !usize {
        const rc = linux.epoll_wait(efd, events.ptr, @intCast(events.len), timeout);
        return switch (linux.errno(rc)) {
            .SUCCESS => rc,
            else => |err| posix.unexpectedErrno(err),
        };
    }

    fn linuxEpollCtl(efd: posix.fd_t, op: u32, fd: posix.fd_t, event: ?*linux.epoll_event) !void {
        const rc = linux.epoll_ctl(efd, op, fd, event);
        return switch (linux.errno(rc)) {
            .SUCCESS => {},
            else => |err| posix.unexpectedErrno(err),
        };
    }
};
