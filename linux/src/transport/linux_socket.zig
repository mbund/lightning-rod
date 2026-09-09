const std = @import("std");
const linux = std.os.linux;
const net = std.Io.net;
const posix = std.posix;

const Address = extern union {
    any: posix.sockaddr,
    ip4: posix.sockaddr.in,
    ip6: posix.sockaddr.in6,
};

pub fn listen(address: net.IpAddress, backlog: u32) !posix.socket_t {
    const fd = try socket(family(address));
    errdefer close(fd);
    const enabled = std.mem.toBytes(@as(c_int, 1));
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &enabled);
    var storage: Address = undefined;
    try bind(fd, sockaddr(address, &storage), addressLen(address));
    return switch (linux.errno(linux.listen(fd, backlog))) {
        .SUCCESS => fd,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub fn close(fd: posix.fd_t) void {
    if (fd >= 0) _ = linux.close(fd);
}

fn socket(domain: u32) !posix.socket_t {
    const result = linux.socket(domain, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
    return switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        else => |err| posix.unexpectedErrno(err),
    };
}

fn bind(fd: posix.socket_t, address: *const posix.sockaddr, len: posix.socklen_t) !void {
    for (0..64) |_| switch (linux.errno(linux.bind(fd, address, len))) {
        .SUCCESS => return,
        .INTR => continue,
        .ADDRINUSE => return error.AddressInUse,
        .ADDRNOTAVAIL => return error.AddressUnavailable,
        .ACCES, .PERM => return error.AccessDenied,
        else => |err| return posix.unexpectedErrno(err),
    };
    return error.ExcessiveSignalInterrupts;
}

fn family(address: net.IpAddress) u32 {
    return switch (address) {
        .ip4 => linux.AF.INET,
        .ip6 => linux.AF.INET6,
    };
}

fn addressLen(address: net.IpAddress) posix.socklen_t {
    return switch (address) {
        .ip4 => @sizeOf(posix.sockaddr.in),
        .ip6 => @sizeOf(posix.sockaddr.in6),
    };
}

fn sockaddr(address: net.IpAddress, storage: *Address) *const posix.sockaddr {
    switch (address) {
        .ip4 => |value| storage.ip4 = .{
            .port = std.mem.nativeToBig(u16, value.port),
            .addr = @bitCast(value.bytes),
        },
        .ip6 => |value| storage.ip6 = .{
            .port = std.mem.nativeToBig(u16, value.port),
            .flowinfo = value.flow,
            .addr = value.bytes,
            .scope_id = value.interface.index,
        },
    }
    return &storage.any;
}
