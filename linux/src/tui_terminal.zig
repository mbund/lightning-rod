const std = @import("std");
const lightning_rod = @import("lightning_rod");
const tui = @import("lightning_rod_tui");
const logging = lightning_rod.logging;
const metrics = lightning_rod.metrics;
const runtime = lightning_rod.runtime;

pub fn Terminal(comptime render_bytes: usize) type {
    if (render_bytes < 1024) @compileError("terminal render buffer must be at least 1024 bytes");
    return struct {
        const Self = @This();

        io: std.Io,
        dashboard: *const tui.Plugin,
        runtime_metrics: *metrics.Runtime,
        persistence_store: *const lightning_rod.persistence.Store,
        persistence_capacity: usize,
        dimensions: tui.Dimensions,
        rendered_revision: u64 = 0,
        rendered_scrollback_revision: u64 = 0,
        scrollback_len: usize = 0,
        scrollback_evictions: u64 = 0,
        scrollback_revision: u64 = 0,
        log_queue: ?*logging.Queue = null,
        entered: bool = false,
        stopping: bool = false,
        faulted: bool = false,
        buffer: [render_bytes]u8 = undefined,
        scrollback: [render_bytes / 4]u8 = undefined,

        pub fn init(
            io: std.Io,
            dashboard: *const tui.Plugin,
            runtime_metrics: *metrics.Runtime,
            persistence_store: *const lightning_rod.persistence.Store,
            persistence_capacity: usize,
            dimensions: tui.Dimensions,
        ) Self {
            var self: Self = .{
                .io = io,
                .dashboard = dashboard,
                .runtime_metrics = runtime_metrics,
                .persistence_store = persistence_store,
                .persistence_capacity = persistence_capacity,
                .dimensions = dimensions,
            };
            self.sampleDimensions();
            self.sampleRuntime();
            return self;
        }

        pub fn backend(self: *Self) runtime.Backend {
            return .{ .context = self, .vtable = &backend_vtable };
        }

        pub fn loggingBackend(self: *Self, queue: *logging.Queue) runtime.Backend {
            self.log_queue = queue;
            return .{ .context = self, .vtable = &logging_vtable };
        }

        pub fn enter(self: *Self) !void {
            if (self.entered) return;
            if (self.stopping or self.faulted) return error.InvalidState;
            try std.Io.File.stdout().writeStreamingAll(self.io, "\x1b[?1049h\x1b[?25l");
            self.entered = true;
            self.rendered_revision = std.math.maxInt(u64);
            self.rendered_scrollback_revision = std.math.maxInt(u64);
        }

        pub fn draw(self: *Self) !bool {
            if (!self.entered or self.stopping) return false;
            if (!self.dashboard.ready()) return false;
            self.sampleDimensions();
            self.sampleRuntime();
            const snapshot = self.dashboard.snapshot();
            if (snapshot.revision == self.rendered_revision and
                self.scrollback_revision == self.rendered_scrollback_revision) return false;
            var writer = std.Io.Writer.fixed(&self.buffer);
            try tui.render(snapshot, self.dimensions, &writer);
            try self.renderScrollback(&writer);
            try std.Io.File.stdout().writeStreamingAll(self.io, writer.buffered());
            self.rendered_revision = snapshot.revision;
            self.rendered_scrollback_revision = self.scrollback_revision;
            return true;
        }

        fn sampleDimensions(self: *Self) void {
            var size: std.posix.winsize = undefined;
            const file = std.Io.File.stdout();
            const fd: usize = @bitCast(@as(isize, file.handle));
            const result = std.os.linux.syscall3(.ioctl, fd, std.os.linux.T.IOCGWINSZ, @intFromPtr(&size));
            if (std.os.linux.errno(result) != .SUCCESS or size.row == 0 or size.col == 0) return;
            self.dimensions = .{ .rows = size.row, .columns = size.col };
        }

        fn sampleResidentSet(self: *Self) void {
            const file = std.Io.Dir.openFileAbsolute(self.io, "/proc/self/status", .{ .mode = .read_only }) catch return;
            defer file.close(self.io);
            var storage: [4096]u8 = undefined;
            const length = file.readPositionalAll(self.io, &storage, 0) catch return;
            const marker = "VmRSS:";
            const start = (std.mem.indexOf(u8, storage[0..length], marker) orelse return) + marker.len;
            const end = start + (std.mem.indexOfScalar(u8, storage[start..length], '\n') orelse return);
            var fields = std.mem.tokenizeAny(u8, storage[start..end], " \t");
            const kibibytes = std.fmt.parseInt(usize, fields.next() orelse return, 10) catch return;
            self.runtime_metrics.setResidentSet(std.math.mul(usize, kibibytes, 1024) catch return);
        }

        fn sampleRuntime(self: *Self) void {
            self.sampleResidentSet();
            self.runtime_metrics.setPersistenceKeys(
                self.persistence_store.liveRecords(),
                self.persistence_capacity,
            );
        }

        pub fn leave(self: *Self) !void {
            if (!self.entered) return;
            try std.Io.File.stdout().writeStreamingAll(self.io, "\x1b[?25h\x1b[?1049l");
            self.entered = false;
        }

        fn appendScrollback(self: *Self, record: []const u8) void {
            appendScrollbackBytes(&self.scrollback, &self.scrollback_len, &self.scrollback_evictions, record);
            self.scrollback_revision +%= 1;
        }

        fn renderScrollback(self: *const Self, writer: *std.Io.Writer) !void {
            if (self.scrollback_len == 0) return;
            try writer.writeAll("\n\x1b[1mLogs\x1b[0m\n");
            if (self.scrollback_evictions != 0)
                try writer.print("[older log bytes evicted: {d}]\n", .{self.scrollback_evictions});
            try writer.writeAll(lastLines(self.scrollback[0..self.scrollback_len], 2));
        }

        fn from(raw: *anyopaque) *Self {
            return @ptrCast(@alignCast(raw));
        }

        fn complete(raw: *anyopaque, _: std.Io, limit: usize) runtime.Completion {
            const self = from(raw);
            if (self.faulted) return .{ .count = 0, .outcome = .failed };
            if (limit == 0 or self.stopping) return .{ .count = 0 };
            const drew = self.draw() catch {
                self.faulted = true;
                return .{ .count = 0, .outcome = .failed };
            };
            return .{ .count = @intFromBool(drew) };
        }

        fn submit(_: *anyopaque, _: std.Io) runtime.Outcome {
            return .ok;
        }

        fn completeLogs(raw: *anyopaque, _: std.Io, limit: usize) runtime.Completion {
            const self = from(raw);
            if (self.faulted) return .{ .count = 0, .outcome = .failed };
            const queue = self.log_queue orelse return .{ .count = 0, .outcome = .failed };
            var count: usize = 0;
            while (count < limit) {
                const record = queue.peek() orelse break;
                self.appendScrollback(record);
                if (!queue.tryConsume()) return .{ .count = count + 1 };
                count += 1;
            }
            return .{ .count = count };
        }

        fn beginShutdown(raw: *anyopaque, _: std.Io) runtime.Outcome {
            const self = from(raw);
            self.stopping = true;
            self.leave() catch {
                self.faulted = true;
                return .failed;
            };
            return .ok;
        }

        fn shutdownProgress(raw: *anyopaque) runtime.Progress {
            const self = from(raw);
            if (self.faulted) return .failed;
            return if (self.stopping and !self.entered) .complete else .pending;
        }

        const backend_vtable: runtime.Backend.VTable = .{
            .complete = complete,
            .submit = submit,
            .begin_shutdown = beginShutdown,
            .shutdown_progress = shutdownProgress,
        };
        const logging_vtable: runtime.Backend.VTable = .{
            .complete = completeLogs,
            .submit = submit,
            .begin_shutdown = beginShutdownLogs,
            .shutdown_progress = shutdownProgressLogs,
        };

        fn beginShutdownLogs(_: *anyopaque, _: std.Io) runtime.Outcome {
            return .ok;
        }

        fn shutdownProgressLogs(raw: *anyopaque) runtime.Progress {
            const self = from(raw);
            if (self.faulted) return .failed;
            const queue = self.log_queue orelse return .failed;
            return if (queue.peek() == null) .complete else .pending;
        }
    };
}

fn lastLines(bytes: []const u8, maximum_lines: usize) []const u8 {
    if (maximum_lines == 0) return bytes[bytes.len..];
    var start = bytes.len;
    var lines: usize = 0;
    while (start != 0) {
        start -= 1;
        if (bytes[start] != '\n' or start + 1 == bytes.len) continue;
        lines += 1;
        if (lines == maximum_lines) return bytes[start + 1 ..];
    }
    return bytes;
}

fn appendScrollbackBytes(storage: []u8, length: *usize, evictions: *u64, record: []const u8) void {
    if (record.len >= storage.len) {
        @memcpy(storage, record[record.len - storage.len ..]);
        length.* = storage.len;
        evictions.* +%= 1;
        return;
    }
    const available = storage.len - length.*;
    if (record.len > available) {
        const evict = record.len - available;
        std.mem.copyForwards(u8, storage[0 .. length.* - evict], storage[evict..length.*]);
        length.* -= evict;
        evictions.* +%= 1;
    }
    @memcpy(storage[length.*..][0..record.len], record);
    length.* += record.len;
}
