const std = @import("std");
const builtin = @import("builtin");
const format = @import("format.zig");

pub const Mode = enum { standard, uring };
pub const maximum_batch = 32;
const Ring = std.os.linux.IoUring;
const IoRead = struct { file: std.Io.File, offset: u64, bytes: []u8 };
const IoWrite = struct { file: std.Io.File, offset: u64, bytes: []const u8 };
pub const Io = if (builtin.os.tag == .linux) LinuxIo else StandardIo;

const LinuxIo = struct {
    io: std.Io,
    ring: ?Ring,
    pending: bool = false,
    writeback_pending: bool = false,
    sync_complete: bool = false,
    failed: bool = false,

    pub fn init(io: std.Io, mode: Mode) format.Error!LinuxIo {
        return .{ .io = io, .ring = if (mode == .uring) Ring.init(128, 0) catch |err| {
            std.log.err("event=storage_io_initialize_failed reason={s}", .{@errorName(err)});
            return error.IoFailure;
        } else null };
    }

    pub fn deinit(self: *LinuxIo) void {
        if (self.ring) |*ring| {
            // Background sync and writeback requests borrow no application buffers.
            ring.deinit();
        }
    }

    pub const Read = IoRead;

    pub fn read(self: *LinuxIo, reads: []const Read) format.Error!void {
        if (reads.len > maximum_batch) return error.InvalidArgument;
        if (self.failed) return error.IoFailure;
        if (self.ring) |*ring| {
            for (reads, 0..) |request, index| {
                _ = ring.read(index, request.file.handle, .{ .buffer = request.bytes }, request.offset) catch unreachable;
            }
            try self.submit();
            var left = reads.len;
            while (left != 0) {
                const cqe = try self.completion(true) orelse continue;
                if (self.background(cqe)) continue;
                std.debug.assert(cqe.user_data < reads.len);
                const request = reads[@intCast(cqe.user_data)];
                if (cqe.res < 0) {
                    self.failed = true;
                } else if (cqe.res != request.bytes.len) {
                    // Retain every borrowed destination until all submitted reads finish.
                    self.failed = true;
                }
                left -= 1;
            }
            if (self.failed) return error.IoFailure;
        } else for (reads) |request| {
            if ((request.file.readPositionalAll(self.io, request.bytes, request.offset) catch return error.IoFailure) != request.bytes.len) return error.Corrupt;
        }
    }

    pub fn write(self: *LinuxIo, file: std.Io.File, bytes: []const u8, start: u64) format.Error!void {
        if (self.failed) return error.IoFailure;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const count: usize = if (self.ring) |*ring| count: {
                const writing = ring.write(0, file.handle, bytes[offset..], start + offset) catch unreachable;
                const interval = 1024 * 1024;
                if (!self.writeback_pending and (start + offset) / interval != (start + bytes.len) / interval) {
                    writing.flags |= std.os.linux.IOSQE_IO_LINK;
                    const hint = ring.get_sqe() catch unreachable;
                    hint.prep_rw(.SYNC_FILE_RANGE, file.handle, 0, 0, 0);
                    hint.rw_flags = 2; // SYNC_FILE_RANGE_WRITE requests writeback without waiting or flushing metadata.
                    hint.flags |= std.os.linux.IOSQE_ASYNC;
                    hint.user_data = std.math.maxInt(u64) - 1;
                    self.writeback_pending = true;
                }
                try self.submit();
                while (true) {
                    const cqe = try self.completion(true) orelse continue;
                    if (self.background(cqe)) continue;
                    std.debug.assert(cqe.user_data == 0);
                    if (cqe.res < 0) return self.writeError(cqe.res);
                    break :count @intCast(cqe.res);
                }
            } else file.writePositional(self.io, &.{bytes[offset..]}, start + offset) catch |err| return switch (err) {
                error.NoSpaceLeft, error.DiskQuota, error.FileTooBig => error.NoSpace,
                else => error.IoFailure,
            };
            if (count == 0 or count > bytes.len - offset) return error.IoFailure;
            offset += count;
        }
    }

    pub const Write = IoWrite;

    pub fn writeBatch(self: *LinuxIo, writes: []const Write) format.Error!void {
        if (writes.len > maximum_batch) return error.InvalidArgument;
        if (self.failed) return error.IoFailure;
        if (self.ring) |*ring| {
            var positions: [maximum_batch]usize = @splat(0);
            while (true) {
                var pending: usize = 0;
                for (writes, positions[0..writes.len], 0..) |request, position, index| {
                    if (position == request.bytes.len) continue;
                    _ = ring.write(index, request.file.handle, request.bytes[position..], request.offset + position) catch unreachable;
                    pending += 1;
                }
                if (pending == 0) return;
                try self.submit();
                while (pending != 0) {
                    const cqe = try self.completion(true) orelse continue;
                    if (self.background(cqe)) continue;
                    std.debug.assert(cqe.user_data < writes.len);
                    const index: usize = @intCast(cqe.user_data);
                    const left = writes[index].bytes.len - positions[index];
                    if (cqe.res <= 0 or cqe.res > left) self.failed = true else positions[index] += @intCast(cqe.res);
                    pending -= 1;
                }
                if (self.failed) return error.IoFailure;
            }
        } else for (writes) |request| try self.write(request.file, request.bytes, request.offset);
    }

    fn writeError(_: *LinuxIo, result: i32) format.Error {
        return switch (@as(std.os.linux.E, @enumFromInt(-result))) {
            .NOSPC, .DQUOT, .FBIG => error.NoSpace,
            else => error.IoFailure,
        };
    }

    pub fn startSync(self: *LinuxIo, file: std.Io.File) format.Error!void {
        std.debug.assert(!self.pending);
        if (self.failed) return error.IoFailure;
        self.sync_complete = false;
        if (self.ring) |*ring| {
            _ = ring.fsync(std.math.maxInt(u64), file.handle, 0) catch unreachable;
            self.pending = true;
            try self.submit();
        } else {
            file.sync(self.io) catch return error.IoFailure;
            self.sync_complete = true;
        }
    }

    pub fn poll(self: *LinuxIo) format.Error!void {
        while (self.pending or self.writeback_pending) {
            if (try self.completion(false)) |entry| {
                const handled = self.background(entry);
                std.debug.assert(handled);
            } else break;
        }
        if (self.failed) return error.IoFailure;
    }

    pub fn wait(self: *LinuxIo, deadline: ?std.Io.Clock.Timestamp) format.Error!void {
        while (self.pending) {
            if (deadline) |until| {
                const remaining = until.raw.nanoseconds - std.Io.Clock.now(until.clock, self.io).nanoseconds;
                if (remaining <= 0) return error.Timeout;
                var descriptors = [_]std.posix.pollfd{.{ .fd = self.ring.?.fd, .events = std.posix.POLL.IN, .revents = 0 }};
                const timeout: std.posix.timespec = .{ .sec = @intCast(@divTrunc(remaining, std.time.ns_per_s)), .nsec = @intCast(@mod(remaining, std.time.ns_per_s)) };
                _ = std.posix.ppoll(&descriptors, &timeout, null) catch |err| switch (err) {
                    error.SignalInterrupt => continue,
                    else => return error.IoFailure,
                };
                try self.poll();
            } else try self.receive(true);
        }
        if (self.failed) return error.IoFailure;
    }

    fn receive(self: *LinuxIo, blocking: bool) format.Error!void {
        if (try self.completion(blocking)) |entry| {
            const handled = self.background(entry);
            std.debug.assert(handled);
        }
    }

    fn background(self: *LinuxIo, entry: std.os.linux.io_uring_cqe) bool {
        if (entry.user_data == std.math.maxInt(u64)) {
            std.debug.assert(self.pending);
            self.pending = false;
            self.sync_complete = entry.res >= 0;
            if (entry.res < 0) self.failed = true;
            return true;
        }
        if (entry.user_data == std.math.maxInt(u64) - 1) {
            std.debug.assert(self.writeback_pending);
            self.writeback_pending = false;
            if (entry.res < 0) switch (entry.err()) {
                .INVAL, .OPNOTSUPP, .NOSYS, .CANCELED => {},
                else => self.failed = true,
            };
            return true;
        }
        return false;
    }

    fn submit(self: *LinuxIo) format.Error!void {
        const ring = &self.ring.?;
        while (ring.sq_ready() != 0) {
            _ = ring.submit() catch |err| switch (err) {
                error.SignalInterrupt => continue,
                // Submission failure leaves kernel ownership of caller buffers uncertain.
                else => std.debug.panic("io_uring submission failed: {t}", .{err}),
            };
        }
    }

    fn completion(self: *LinuxIo, blocking: bool) format.Error!?std.os.linux.io_uring_cqe {
        var entries: [1]std.os.linux.io_uring_cqe = undefined;
        const count = self.ring.?.copy_cqes(&entries, @intFromBool(blocking)) catch |err| switch (err) {
            error.SignalInterrupt => return null,
            else => std.debug.panic("io_uring completion failed: {t}", .{err}),
        };
        return if (count == 0) null else entries[0];
    }
};

const StandardIo = struct {
    pub const Read = IoRead;
    pub const Write = IoWrite;

    io: std.Io,
    pending: bool = false,
    sync_complete: bool = false,
    failed: bool = false,

    pub fn init(io: std.Io, mode: Mode) format.Error!StandardIo {
        if (mode != .standard) return error.InvalidArgument;
        return .{ .io = io };
    }
    pub fn deinit(_: *StandardIo) void {}

    pub fn read(self: *StandardIo, reads: []const Read) format.Error!void {
        if (reads.len > maximum_batch) return error.InvalidArgument;
        if (self.failed) return error.IoFailure;
        for (reads) |request| {
            if ((request.file.readPositionalAll(self.io, request.bytes, request.offset) catch return error.IoFailure) != request.bytes.len) return error.Corrupt;
        }
    }
    pub fn write(self: *StandardIo, file: std.Io.File, bytes: []const u8, offset: u64) format.Error!void {
        if (self.failed) return error.IoFailure;
        file.writePositionalAll(self.io, bytes, offset) catch |err| return switch (err) {
            error.NoSpaceLeft, error.DiskQuota, error.FileTooBig => error.NoSpace,
            else => error.IoFailure,
        };
    }
    pub fn writeBatch(self: *StandardIo, writes: []const Write) format.Error!void {
        if (writes.len > maximum_batch) return error.InvalidArgument;
        for (writes) |request| try self.write(request.file, request.bytes, request.offset);
    }
    pub fn startSync(self: *StandardIo, file: std.Io.File) format.Error!void {
        if (self.failed) return error.IoFailure;
        self.sync_complete = false;
        file.sync(self.io) catch {
            self.failed = true;
            return error.IoFailure;
        };
        self.sync_complete = true;
    }
    pub fn poll(self: *StandardIo) format.Error!void {
        if (self.failed) return error.IoFailure;
    }
    pub fn wait(self: *StandardIo, _: ?std.Io.Clock.Timestamp) format.Error!void {
        std.debug.assert(!self.pending);
        try self.poll();
    }
};
