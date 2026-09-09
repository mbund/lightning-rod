const std = @import("std");
const lightning_rod = @import("lightning_rod");
const logging = lightning_rod.logging;
const runtime = lightning_rod.runtime;

pub const Stdout = struct {
    io: std.Io,
    queue: *logging.Queue,

    pub fn init(io: std.Io, queue: *logging.Queue) Stdout {
        return .{ .io = io, .queue = queue };
    }

    pub fn interface(self: *Stdout) runtime.Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    pub fn flush(self: *Stdout) void {
        while (self.queue.peek() != null) {
            const result = complete(self, self.io, 64);
            if (result.outcome == .failed or result.count == 0) return;
        }
    }

    fn complete(context: *anyopaque, _: std.Io, limit: usize) runtime.Completion {
        const self: *Stdout = @ptrCast(@alignCast(context));
        var count: usize = 0;
        while (count < limit) {
            const record = self.queue.peek() orelse break;
            std.Io.File.stdout().writeStreamingAll(self.io, record) catch return .{ .count = count, .outcome = .failed };
            if (!self.queue.tryConsume()) return .{ .count = count + 1 };
            count += 1;
        }
        return .{ .count = count };
    }

    fn submit(_: *anyopaque, _: std.Io) runtime.Outcome {
        return .ok;
    }

    fn beginShutdown(_: *anyopaque, _: std.Io) runtime.Outcome {
        return .ok;
    }

    fn shutdownProgress(context: *anyopaque) runtime.Progress {
        const self: *Stdout = @ptrCast(@alignCast(context));
        return if (self.queue.peek() == null) .complete else .pending;
    }

    fn pollInterval(context: *anyopaque) ?u64 {
        const self: *Stdout = @ptrCast(@alignCast(context));
        return if (self.queue.peek() == null) null else std.time.ns_per_ms;
    }
};

const vtable: runtime.Backend.VTable = .{
    .complete = Stdout.complete,
    .submit = Stdout.submit,
    .begin_shutdown = Stdout.beginShutdown,
    .shutdown_progress = Stdout.shutdownProgress,
    .poll_interval_ns = Stdout.pollInterval,
};

test "queued shutdown logs request progress without a gameplay tick" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var queue = try logging.Queue.init(arena.allocator(), 4, 128, 1);
    var stdout = Stdout.init(std.testing.io, &queue);
    const backend = stdout.interface();
    try std.testing.expectEqual(@as(?u64, null), backend.pollIntervalNs());
    queue.write(.info, "shutdown", "checkpoint captured", .{});
    try std.testing.expectEqual(runtime.Progress.pending, backend.shutdownProgress());
    try std.testing.expectEqual(@as(?u64, std.time.ns_per_ms), backend.pollIntervalNs());
    try std.testing.expect(queue.tryConsume());
    try std.testing.expectEqual(runtime.Progress.complete, backend.shutdownProgress());
    try std.testing.expectEqual(@as(?u64, null), backend.pollIntervalNs());
}
