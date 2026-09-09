const std = @import("std");

const linux = std.os.linux;
const io_attempt_limit = 8192;

pub const Error = error{
    CreateFailed,
    ReadFailed,
    WriteFailed,
    SeekFailed,
    TooLarge,
    SealFailed,
};

pub const HandoffFd = struct {
    fd: std.posix.fd_t,

    pub const argument_prefix = "--lightning-rod-reexec-fd=";

    pub fn create(bytes: []const u8) Error!HandoffFd {
        var handoff = try createEmpty();
        errdefer handoff.close();
        try handoff.append(bytes);
        try handoff.sealAndRewind();
        return handoff;
    }

    fn createEmpty() Error!HandoffFd {
        const fd = std.posix.memfd_create("lightning-rod-reexec", 0x0002) catch
            return error.CreateFailed;
        return .{ .fd = fd };
    }

    fn append(self: HandoffFd, bytes: []const u8) Error!void {
        try writeAll(self.fd, bytes);
    }

    fn sealAndRewind(self: HandoffFd) Error!void {
        try seal(self.fd);
        try seekStart(self.fd);
    }

    pub fn readInto(self: HandoffFd, destination: []u8) Error![]const u8 {
        try seekStart(self.fd);
        var cursor: usize = 0;
        for (0..io_attempt_limit) |_| {
            if (cursor == destination.len) {
                try rejectTrailingByte(self.fd);
                return destination;
            }
            const result = linux.read(self.fd, destination[cursor..].ptr, destination.len - cursor);
            switch (linux.errno(result)) {
                .SUCCESS => {
                    if (result == 0) return destination[0..cursor];
                    cursor += result;
                },
                .INTR => {},
                else => return error.ReadFailed,
            }
        }
        return error.ReadFailed;
    }

    pub fn close(self: HandoffFd) void {
        closeRaw(self.fd);
    }

    pub fn prepareForExec(fd: std.posix.fd_t) Error!void {
        const flags = linux.fcntl(fd, linux.F.GETFD, 0);
        if (linux.errno(flags) != .SUCCESS) return error.ReadFailed;
        const preserved = @as(usize, @intCast(flags)) & ~@as(usize, linux.FD_CLOEXEC);
        const result = linux.fcntl(fd, linux.F.SETFD, preserved);
        if (linux.errno(result) != .SUCCESS) return error.WriteFailed;
    }

    pub fn restoreCloseOnExec(fd: std.posix.fd_t) Error!void {
        const flags = linux.fcntl(fd, linux.F.GETFD, 0);
        if (linux.errno(flags) != .SUCCESS) return error.ReadFailed;
        const restored = @as(usize, @intCast(flags)) | @as(usize, linux.FD_CLOEXEC);
        const result = linux.fcntl(fd, linux.F.SETFD, restored);
        if (linux.errno(result) != .SUCCESS) return error.WriteFailed;
    }

    pub fn fromArgument(value: []const u8) Error!HandoffFd {
        if (!std.mem.startsWith(u8, value, argument_prefix)) return error.ReadFailed;
        const parsed = std.fmt.parseInt(i32, value[argument_prefix.len..], 10) catch return error.ReadFailed;
        if (parsed < 0) return error.ReadFailed;
        return .{ .fd = parsed };
    }

    pub fn argument(self: HandoffFd, output: []u8) Error![]const u8 {
        const text = std.fmt.bufPrint(output, "{s}{d}", .{ argument_prefix, self.fd }) catch
            return error.WriteFailed;
        return text;
    }

    pub fn sealed(self: HandoffFd) bool {
        const result = linux.fcntl(self.fd, linux.F.GET_SEALS, 0);
        if (linux.errno(result) != .SUCCESS) return false;
        const required = linux.F.SEAL_SEAL | linux.F.SEAL_SHRINK | linux.F.SEAL_GROW | linux.F.SEAL_WRITE;
        return (@as(usize, @intCast(result)) & required) == required;
    }
};

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) Error!void {
    var cursor: usize = 0;
    for (0..io_attempt_limit) |_| {
        if (cursor == bytes.len) return;
        const result = linux.write(fd, bytes[cursor..].ptr, bytes.len - cursor);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.WriteFailed;
                cursor += result;
                if (cursor == bytes.len) return;
            },
            .INTR => {},
            else => return error.WriteFailed,
        }
    }
    return error.WriteFailed;
}

fn seekStart(fd: std.posix.fd_t) Error!void {
    const result = linux.lseek(fd, 0, linux.SEEK.SET);
    if (linux.errno(result) != .SUCCESS) return error.SeekFailed;
}

fn rejectTrailingByte(fd: std.posix.fd_t) Error!void {
    var byte: [1]u8 = undefined;
    for (0..io_attempt_limit) |_| {
        const result = linux.read(fd, &byte, byte.len);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return;
                return error.TooLarge;
            },
            .INTR => {},
            else => return error.ReadFailed,
        }
    }
    return error.ReadFailed;
}

fn seal(fd: std.posix.fd_t) Error!void {
    const seals = linux.F.SEAL_SEAL | linux.F.SEAL_SHRINK | linux.F.SEAL_GROW | linux.F.SEAL_WRITE;
    const result = linux.fcntl(fd, linux.F.ADD_SEALS, seals);
    if (linux.errno(result) != .SUCCESS) return error.SealFailed;
}

fn closeRaw(fd: std.posix.fd_t) void {
    _ = linux.close(fd);
}

test "inherited handoff fd preserves a bounded sealed byte stream" {
    const handoff = try HandoffFd.create("restart-state");
    defer handoff.close();
    var storage: [32]u8 = undefined;
    const bytes = try handoff.readInto(&storage);
    try std.testing.expectEqualStrings("restart-state", bytes);
    try std.testing.expect(handoff.sealed());
}

test "handoff descriptor argument is bounded and validated" {
    const value = HandoffFd{ .fd = 17 };
    var storage: [64]u8 = undefined;
    const argument = try value.argument(&storage);
    try std.testing.expectEqualStrings("--lightning-rod-reexec-fd=17", argument);
    try std.testing.expectEqual(@as(std.posix.fd_t, 17), (try HandoffFd.fromArgument(argument)).fd);
    try std.testing.expectError(error.ReadFailed, HandoffFd.fromArgument("--lightning-rod-reexec-fd=-1"));
    try std.testing.expectError(error.ReadFailed, HandoffFd.fromArgument("fd"));
}

test "transport descriptors are explicitly retained across exec" {
    const handoff = try HandoffFd.create("state");
    defer handoff.close();
    const before = linux.fcntl(handoff.fd, linux.F.GETFD, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(before));
    const with_close_on_exec = linux.fcntl(handoff.fd, linux.F.SETFD, linux.FD_CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(with_close_on_exec));
    try HandoffFd.prepareForExec(handoff.fd);
    const after = linux.fcntl(handoff.fd, linux.F.GETFD, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(after));
    try std.testing.expect((@as(usize, @intCast(after)) & linux.FD_CLOEXEC) == 0);
}
