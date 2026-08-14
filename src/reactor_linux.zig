const std = @import("std");

const linux = std.os.linux;
const net = std.Io.net;
const posix = std.posix;

pub const CpuPlacement = struct {
    simulation: usize,
    io_workers: posix.cpu_set_t,
};

pub fn entropy(buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const result = linux.getrandom(buffer[offset..].ptr, buffer.len - offset, 0);
        switch (linux.errno(result)) {
            .SUCCESS => offset += result,
            .INTR => continue,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub fn firstDeadline(ticks_per_second: u64) !linux.timespec {
    var now: linux.timespec = undefined;
    switch (linux.errno(linux.clock_gettime(.MONOTONIC, &now))) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }
    advanceDeadline(&now, ticks_per_second);
    return now;
}

pub fn advanceDeadline(deadline: *linux.timespec, ticks_per_second: u64) void {
    const tick_ns = std.time.ns_per_s / ticks_per_second;
    deadline.nsec += @intCast(tick_ns % std.time.ns_per_s);
    deadline.sec += @intCast(tick_ns / std.time.ns_per_s);
    if (deadline.nsec < std.time.ns_per_s) return;
    deadline.nsec -= std.time.ns_per_s;
    deadline.sec += 1;
}

pub fn nanoseconds(value: linux.timespec) u64 {
    return @as(u64, @intCast(value.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(value.nsec));
}

pub fn monotonicNanoseconds() !u64 {
    var now: linux.timespec = undefined;
    switch (linux.errno(linux.clock_gettime(.MONOTONIC, &now))) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }
    return nanoseconds(now);
}

pub fn monotonicMilliseconds() !u64 {
    return (try monotonicNanoseconds()) / std.time.ns_per_ms;
}

pub fn pinOneCpu(requested: ?usize) !CpuPlacement {
    const allowed = try posix.sched_getaffinity(0);
    const word_bits = @bitSizeOf(usize);
    const maximum_cpu = allowed.len * word_bits;
    const selected = if (requested) |cpu| selected: {
        if (cpu >= maximum_cpu) return error.InvalidCpu;
        if (allowed[cpu / word_bits] & (@as(usize, 1) << @intCast(cpu % word_bits)) == 0)
            return error.CpuNotAllowed;
        break :selected cpu;
    } else selected: {
        for (allowed, 0..) |word, word_index| {
            if (word != 0) break :selected word_index * word_bits + @ctz(word);
        }
        return error.NoAllowedCpu;
    };
    var target = [_]usize{0} ** allowed.len;
    target[selected / word_bits] = @as(usize, 1) << @intCast(selected % word_bits);
    try linux.sched_setaffinity(0, &target);
    var io_workers = allowed;
    io_workers[selected / word_bits] &= ~(@as(usize, 1) << @intCast(selected % word_bits));
    if (linux.CPU_COUNT(io_workers) == 0) io_workers = target;
    return .{ .simulation = selected, .io_workers = io_workers };
}

pub fn registerWorkerAffinity(
    ring: *linux.IoUring,
    io_workers: *const posix.cpu_set_t,
) !void {
    const result = linux.io_uring_register(
        ring.fd,
        .REGISTER_IOWQ_AFF,
        io_workers,
        @sizeOf(posix.cpu_set_t),
    );
    switch (linux.errno(result)) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn registerFileRange(ring: *linux.IoUring, offset: usize, length: usize) !void {
    const range = linux.io_uring_file_index_range{
        .off = @intCast(offset),
        .len = @intCast(length),
        .resv = 0,
    };
    const result = linux.io_uring_register(ring.fd, .REGISTER_FILE_ALLOC_RANGE, &range, 0);
    switch (linux.errno(result)) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }
}

const PosixAddress = extern union {
    any: posix.sockaddr,
    in: posix.sockaddr.in,
    in6: posix.sockaddr.in6,
};

pub fn listen(address: net.IpAddress, backlog: u32) !posix.socket_t {
    const fd = try socket(addressFamily(address), linux.SOCK.STREAM | linux.SOCK.NONBLOCK |
        linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
    errdefer close(fd);
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    var storage: PosixAddress = undefined;
    try bind(fd, storageAddress(address, &storage), addressLength(address));
    const result = linux.listen(fd, backlog);
    return switch (linux.errno(result)) {
        .SUCCESS => fd,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub fn close(fd: posix.fd_t) void {
    _ = linux.close(fd);
}

fn addressFamily(address: net.IpAddress) u32 {
    return switch (address) {
        .ip4 => linux.AF.INET,
        .ip6 => linux.AF.INET6,
    };
}

fn addressLength(address: net.IpAddress) posix.socklen_t {
    return switch (address) {
        .ip4 => @sizeOf(posix.sockaddr.in),
        .ip6 => @sizeOf(posix.sockaddr.in6),
    };
}

fn storageAddress(address: net.IpAddress, storage: *PosixAddress) *const posix.sockaddr {
    switch (address) {
        .ip4 => |ip4| storage.in = .{
            .port = std.mem.nativeToBig(u16, ip4.port),
            .addr = @bitCast(ip4.bytes),
        },
        .ip6 => |ip6| storage.in6 = .{
            .port = std.mem.nativeToBig(u16, ip6.port),
            .flowinfo = ip6.flow,
            .addr = ip6.bytes,
            .scope_id = ip6.interface.index,
        },
    }
    return &storage.any;
}

fn socket(domain: u32, socket_type: u32, protocol: u32) !posix.socket_t {
    const result = linux.socket(domain, socket_type, protocol);
    return switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        else => |err| posix.unexpectedErrno(err),
    };
}

fn bind(fd: posix.socket_t, address: *const posix.sockaddr, length: posix.socklen_t) !void {
    for (0..1024) |_| switch (linux.errno(linux.bind(fd, address, length))) {
        .SUCCESS => return,
        .INTR => continue,
        .ADDRINUSE => return error.AddressInUse,
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        .ADDRNOTAVAIL => return error.AddressUnavailable,
        .NOMEM => return error.SystemResources,
        .ACCES, .PERM => return error.AccessDenied,
        else => |err| return posix.unexpectedErrno(err),
    };
    return error.ExcessiveSignalInterrupts;
}
