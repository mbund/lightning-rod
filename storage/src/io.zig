const std = @import("std");
const builtin = @import("builtin");
const system = @import("system");
const format = @import("format.zig");

pub const Mode = system.FileBatch.Mode;
pub const maximum_batch = 32;
const Ring = std.os.linux.IoUring;
const IoRead = system.FileBatch.Read;
const IoWrite = system.FileBatch.Write;
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
            var vectors: [maximum_batch]std.posix.iovec = undefined;
            var lengths: [maximum_batch]usize = undefined;
            var left: usize = 0;
            var index: usize = 0;
            while (index < reads.len) {
                const first = index;
                const request = reads[first];
                var length: usize = 0;
                while (index < reads.len) : (index += 1) {
                    const next = reads[index];
                    if (next.file.handle != request.file.handle or next.offset != request.offset + length) break;
                    vectors[index] = .{ .base = next.bytes.ptr, .len = next.bytes.len };
                    length += next.bytes.len;
                }
                lengths[first] = length;
                const buffer: Ring.ReadBuffer = if (index == first + 1) .{ .buffer = request.bytes } else .{ .iovecs = vectors[first..index] };
                _ = ring.read(first, request.file.handle, buffer, request.offset) catch unreachable;
                left += 1;
            }
            try self.submit(1);
            var completions: [maximum_batch + 2]std.os.linux.io_uring_cqe = undefined;
            while (left != 0) {
                const count = try self.reap(&completions, @intCast(left));
                std.debug.assert(count <= completions.len);
                for (completions[0..count]) |cqe| {
                    if (self.background(cqe)) continue;
                    std.debug.assert(left > 0 and cqe.user_data < reads.len);
                    const expected = lengths[@intCast(cqe.user_data)];
                    // Retain every destination until the whole batch has completed, including errors.
                    if (cqe.res < 0 or cqe.res != expected) self.failed = true;
                    left -= 1;
                }
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
                try self.submit(1);
                while (true) {
                    const cqe = try self.completion(1) orelse continue;
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
            var vectors: [maximum_batch]std.posix.iovec_const = undefined;
            var lengths: [maximum_batch]usize = undefined;
            var completions: [maximum_batch + 2]std.os.linux.io_uring_cqe = undefined;
            while (true) {
                var pending: usize = 0;
                var index: usize = 0;
                while (index < writes.len) {
                    const request = writes[index];
                    const position = positions[index];
                    if (position == request.bytes.len) {
                        index += 1;
                        continue;
                    }
                    const first = index;
                    var length: usize = 0;
                    while (index < writes.len) : (index += 1) {
                        const next = writes[index];
                        if (next.file.handle != request.file.handle or next.offset + positions[index] != request.offset + position + length) break;
                        const bytes = next.bytes[positions[index]..];
                        vectors[index] = .{ .base = bytes.ptr, .len = bytes.len };
                        length += bytes.len;
                    }
                    lengths[first] = length;
                    if (index == first + 1) {
                        _ = ring.write(first, request.file.handle, request.bytes[position..], request.offset + position) catch unreachable;
                    } else {
                        _ = ring.writev(first, request.file.handle, vectors[first..index], request.offset + position) catch unreachable;
                    }
                    pending += 1;
                }
                if (pending == 0) return;
                try self.submit(1);
                while (pending != 0) {
                    const count = try self.reap(&completions, @intCast(pending));
                    std.debug.assert(count <= completions.len);
                    for (completions[0..count]) |cqe| {
                        if (self.background(cqe)) continue;
                        std.debug.assert(pending > 0 and cqe.user_data < writes.len);
                        var at: usize = @intCast(cqe.user_data);
                        if (cqe.res <= 0 or cqe.res > lengths[at]) {
                            self.failed = true;
                        } else {
                            var completed: usize = @intCast(cqe.res);
                            while (completed != 0) : (at += 1) {
                                const size = @min(completed, writes[at].bytes.len - positions[at]);
                                positions[at] += size;
                                completed -= size;
                            }
                        }
                        pending -= 1;
                    }
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
            const sync = ring.fsync(std.math.maxInt(u64), file.handle, 0) catch unreachable;
            sync.flags |= std.os.linux.IOSQE_ASYNC;
            self.pending = true;
            try self.submit(0);
        } else {
            file.sync(self.io) catch return error.IoFailure;
            self.sync_complete = true;
        }
    }

    pub fn poll(self: *LinuxIo) format.Error!void {
        while (self.pending or self.writeback_pending) {
            if (try self.completion(0)) |entry| {
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
        if (try self.completion(@intFromBool(blocking))) |entry| {
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

    fn submit(self: *LinuxIo, wait_for: u32) format.Error!void {
        const ring = &self.ring.?;
        while (ring.sq_ready() != 0) {
            _ = ring.submit_and_wait(wait_for) catch |err| switch (err) {
                error.SignalInterrupt => continue,
                // Submission failure leaves kernel ownership of caller buffers uncertain.
                else => std.debug.panic("io_uring submission failed: {t}", .{err}),
            };
        }
    }

    fn completion(self: *LinuxIo, minimum: u32) format.Error!?std.os.linux.io_uring_cqe {
        var entries: [1]std.os.linux.io_uring_cqe = undefined;
        return if (try self.reap(&entries, minimum) == 0) null else entries[0];
    }

    fn reap(self: *LinuxIo, entries: []std.os.linux.io_uring_cqe, minimum: u32) format.Error!usize {
        std.debug.assert(entries.len > 0);
        const count = self.ring.?.copy_cqes(entries, minimum) catch |err| switch (err) {
            error.SignalInterrupt => return 0,
            else => std.debug.panic("io_uring completion failed: {t}", .{err}),
        };
        std.debug.assert(count <= entries.len);
        return count;
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
