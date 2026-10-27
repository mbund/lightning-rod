const std = @import("std");
const linux = std.os.linux;
const assert = std.debug.assert;

/// One batch owns its buffers until poll reports completion, including on failure.
pub const FileBatch = struct {
    pub const Mode = enum {
        /// Execute through the supplied std.Io, including deterministic in-memory models.
        standard,
        /// Submit kernel work without waiting for completion.
        uring,
    };
    pub const Error = error{ NoSpace, IoFailure, Corrupt, Timeout };
    pub const Read = struct { file: std.Io.File, offset: u64, bytes: []u8 };
    pub const Write = struct { file: std.Io.File, offset: u64, bytes: []const u8 };
    const maximum_batch = 32;
    pub const Operation = union(enum) {
        read: Read,
        write: Write,
        open: struct { directory: std.Io.Dir, path: [:0]const u8 },
        rename: struct { directory: std.Io.Dir, from: [:0]const u8, to: [:0]const u8 },
        close: std.Io.File,
        sync: std.Io.File,
        exists: struct { directory: std.Io.Dir, path: [:0]const u8, result: *bool },
    };
    io: std.Io,
    ring: ?linux.IoUring,
    operations: [maximum_batch]Operation = undefined,
    positions: [maximum_batch]usize = undefined,
    count: usize = 0,
    remaining: usize = 0,
    active: bool = false,
    failure: ?Error = null,
    opened: ?std.Io.File = null,
    stat: linux.Statx = undefined,

    pub fn init(io: std.Io, mode: Mode) !FileBatch {
        return .{ .io = io, .ring = if (mode == .uring) try linux.IoUring.init(64, 0) else null };
    }

    pub fn submit(self: *FileBatch, operations: []const Operation) Error!void {
        assert(!self.active and operations.len > 0 and operations.len <= self.operations.len);
        var stats: usize = 0;
        for (operations) |operation| {
            stats += @intFromBool(operation == .exists);
        }
        assert(stats <= 1);
        self.active = true;
        self.failure = null;
        self.opened = null;
        self.count = operations.len;
        self.remaining = operations.len;
        @memcpy(self.operations[0..self.count], operations);
        @memset(self.positions[0..self.count], 0);
        if (self.ring != null) {
            for (0..self.count) |index| self.queue(index);
            self.flush();
        } else {
            for (operations) |operation| self.execute(operation) catch |err| {
                self.failure = err;
            };
            self.remaining = 0;
        }
    }

    fn queue(self: *FileBatch, index: usize) void {
        const ring = &self.ring.?;
        const operation = self.operations[index];
        const position = self.positions[index];
        const sqe = switch (operation) {
            .read => |read| ring.read(index, read.file.handle, .{ .buffer = read.bytes[position..] }, read.offset + position) catch unreachable,
            .write => |write| ring.write(index, write.file.handle, write.bytes[position..], write.offset + position) catch unreachable,
            else => ring.get_sqe() catch unreachable,
        };
        switch (operation) {
            .read, .write => {},
            .open => |open| sqe.prep_openat(open.directory.handle, open.path, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600),
            .rename => |rename| sqe.prep_renameat(rename.directory.handle, rename.from, rename.directory.handle, rename.to, 0),
            .close => |file| sqe.prep_close(file.handle),
            .sync => |file| sqe.prep_fsync(file.handle, 0),
            .exists => |exists| sqe.prep_statx(exists.directory.handle, exists.path, 0, .{ .TYPE = true }, &self.stat),
        }
        sqe.user_data = index;
        sqe.flags |= linux.IOSQE_ASYNC;
    }

    fn flush(self: *FileBatch) void {
        const ring = &self.ring.?;
        while (ring.sq_ready() != 0) {
            _ = ring.submit() catch |err| switch (err) {
                error.SignalInterrupt => continue,
                else => std.debug.panic("maintenance submission failed: {t}", .{err}),
            };
        }
    }

    pub fn poll(self: *FileBatch) Error!bool {
        assert(self.active);
        if (self.ring) |*ring| {
            var entries: [maximum_batch]linux.io_uring_cqe = undefined;
            const count = ring.copy_cqes(&entries, 0) catch |err| switch (err) {
                error.SignalInterrupt => return false,
                else => std.debug.panic("maintenance completion failed: {t}", .{err}),
            };
            for (entries[0..count]) |entry| {
                assert(self.remaining > 0 and entry.user_data < self.count);
                const index: usize = @intCast(entry.user_data);
                const operation = self.operations[index];
                if (operation == .exists and entry.err() == .NOENT) {
                    operation.exists.result.* = false;
                    self.remaining -= 1;
                    continue;
                }
                if (entry.res < 0) {
                    self.failure = switch (entry.err()) {
                        .NOSPC, .DQUOT, .FBIG => error.NoSpace,
                        else => error.IoFailure,
                    };
                } else switch (operation) {
                    .read, .write => {
                        const length = switch (operation) {
                            .read => |read| read.bytes.len,
                            .write => |write| write.bytes.len,
                            else => unreachable,
                        };
                        const bytes: usize = @intCast(entry.res);
                        if (bytes == 0 or bytes > length - self.positions[index]) {
                            self.failure = error.IoFailure;
                        } else {
                            self.positions[index] += bytes;
                            if (self.positions[index] < length) {
                                self.queue(index);
                                continue;
                            }
                        }
                    },
                    .exists => |exists| exists.result.* = true,
                    .open => {
                        assert(self.opened == null);
                        self.opened = .{ .handle = entry.res, .flags = .{ .nonblocking = false } };
                    },
                    else => if (entry.res != 0) {
                        self.failure = error.IoFailure;
                    },
                }
                self.remaining -= 1;
            }
            if (ring.sq_ready() != 0) self.flush();
        }
        if (self.remaining != 0) return false;
        self.active = false;
        if (self.failure) |err| return err;
        return true;
    }

    fn execute(self: *FileBatch, operation: Operation) Error!void {
        switch (operation) {
            .read => |read| if ((read.file.readPositionalAll(self.io, read.bytes, read.offset) catch return error.IoFailure) != read.bytes.len) {
                return error.Corrupt;
            },
            .write => |write| write.file.writePositionalAll(self.io, write.bytes, write.offset) catch return error.IoFailure,
            .open => |open| self.opened = open.directory.createFile(self.io, open.path, .{ .read = true, .truncate = true }) catch return error.IoFailure,
            .rename => |rename| rename.directory.rename(rename.from, rename.directory, rename.to, self.io) catch return error.IoFailure,
            .close => |file| file.close(self.io),
            .sync => |file| file.sync(self.io) catch return error.IoFailure,
            .exists => |exists| {
                exists.result.* = true;
                exists.directory.access(self.io, exists.path, .{}) catch |err| switch (err) {
                    error.FileNotFound => exists.result.* = false,
                    else => return error.IoFailure,
                };
            },
        }
    }

    /// Only shutdown and reload may wait for outstanding buffer loans.
    pub fn wait(self: *FileBatch, deadline: ?std.Io.Clock.Timestamp) Error!void {
        while (self.active) {
            if (try self.poll()) break;
            if (deadline) |until| {
                const remaining = until.raw.nanoseconds - std.Io.Clock.now(until.clock, self.io).nanoseconds;
                if (remaining <= 0) return error.Timeout;
                var descriptors = [_]std.posix.pollfd{.{ .fd = self.ring.?.fd, .events = std.posix.POLL.IN, .revents = 0 }};
                const timeout: std.posix.timespec = .{ .sec = @intCast(@divTrunc(remaining, std.time.ns_per_s)), .nsec = @intCast(@mod(remaining, std.time.ns_per_s)) };
                _ = std.posix.ppoll(&descriptors, &timeout, null) catch |err| switch (err) {
                    error.SignalInterrupt => continue,
                    else => return error.IoFailure,
                };
            } else {
                _ = self.ring.?.submit_and_wait(1) catch |err| switch (err) {
                    error.SignalInterrupt => continue,
                    else => return error.IoFailure,
                };
            }
        }
    }

    pub fn drain(self: *FileBatch) Error!void {
        return self.wait(null);
    }

    pub fn deinit(self: *FileBatch) void {
        self.drain() catch {};
        assert(!self.active);
        if (self.ring) |*ring| ring.deinit();
    }
};

test "a failed batch retains other destinations until every request completes" {
    const io = std.testing.io;
    var batch = try FileBatch.init(io, .uring);
    defer batch.deinit();
    const raw = linux.eventfd(0, linux.EFD.CLOEXEC);
    try std.testing.expectEqual(.SUCCESS, linux.errno(raw));
    const file: std.Io.File = .{ .handle = @intCast(raw), .flags = .{ .nonblocking = false } };
    defer file.close(io);
    var first: [8]u8 = undefined;
    var second: [8]u8 = undefined;
    try batch.submit(&.{
        .{ .read = .{ .file = .{ .handle = -1, .flags = .{ .nonblocking = false } }, .offset = 0, .bytes = &first } },
        .{ .read = .{ .file = file, .offset = 0, .bytes = &second } },
    });
    const value: u64 = 1;
    var released = false;
    defer if (!released) {
        _ = linux.write(file.handle, std.mem.asBytes(&value).ptr, @sizeOf(u64));
        batch.drain() catch {};
    };
    try std.testing.expect(!try batch.poll());
    try std.testing.expect(batch.active);
    try std.testing.expectEqual(@as(usize, 8), linux.write(file.handle, std.mem.asBytes(&value).ptr, @sizeOf(u64)));
    released = true;
    try std.testing.expectError(error.IoFailure, batch.drain());
    try std.testing.expect(!batch.active);
    try std.testing.expectEqual(value, std.mem.bytesToValue(u64, &second));
}
