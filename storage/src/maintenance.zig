const std = @import("std");
const builtin = @import("builtin");
const storage = @import("storage.zig");

pub const Maintenance = struct {
    store: *storage.Store,
    thread: ?std.Thread = null,
    thread_id: std.atomic.Value(std.Thread.Id) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    notified: std.atomic.Value(bool) = .init(false),
    blocked: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    wake: i32 = -1,

    /// Start and stop while foreground users are quiescent.
    pub fn start(self: *Maintenance) !void {
        if (comptime builtin.single_threaded) @compileError("storage maintenance workers require a multithreaded application");
        std.debug.assert(self.thread == null and self.wake == -1 and !self.failed.load(.acquire));
        self.stopping.store(false, .release);
        self.notified.store(false, .release);
        self.blocked.store(false, .release);
        self.thread_id.store(0, .release);
        if (self.store.io_mode != .uring) return error.NativeStorageRequired;
        const fd = std.os.linux.eventfd(0, std.os.linux.EFD.CLOEXEC);
        if (std.os.linux.errno(fd) != .SUCCESS) return error.EventFdFailed;
        self.wake = @intCast(fd);
        errdefer {
            _ = std.os.linux.close(self.wake);
            self.wake = -1;
        }
        try self.store.maintenance_io.ring.?.register_eventfd(self.wake);
        errdefer self.store.maintenance_io.ring.?.unregister_eventfd() catch unreachable;
        try self.store.filesystem.ring.?.register_eventfd(self.wake);
        errdefer self.store.filesystem.ring.?.unregister_eventfd() catch unreachable;
        const previous = self.store.resources.background.cmpxchgStrong(null, self, .acq_rel, .acquire);
        if (previous != null) return error.MaintenanceAlreadyStarted;
        errdefer self.store.resources.background.store(null, .release);
        self.thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, run, .{self});
        self.notify();
    }

    pub fn notify(self: *Maintenance) void {
        if (self.thread_id.load(.acquire) == std.Thread.getCurrentId()) return;
        if (self.notified.swap(true, .acq_rel)) return;
        const value: u64 = 1;
        while (true) {
            const result = std.os.linux.write(self.wake, std.mem.asBytes(&value).ptr, @sizeOf(u64));
            switch (std.os.linux.errno(result)) {
                .SUCCESS => {
                    std.debug.assert(result == @sizeOf(u64));
                    return;
                },
                .INTR => continue,
                else => @panic("storage maintenance notification failed"),
            }
        }
    }

    fn run(self: *Maintenance) void {
        self.thread_id.store(std.Thread.getCurrentId(), .release);
        self.execute() catch |err| {
            self.failure = err;
            self.failed.store(true, .release);
        };
    }

    fn execute(self: *Maintenance) !void {
        while (!self.stopping.load(.acquire)) {
            var value: u64 = undefined;
            while (true) {
                const result = std.os.linux.read(self.wake, std.mem.asBytes(&value).ptr, @sizeOf(u64));
                switch (std.os.linux.errno(result)) {
                    .SUCCESS => {
                        std.debug.assert(result == @sizeOf(u64) and value != 0);
                        break;
                    },
                    .INTR => continue,
                    else => return error.EventFdFailed,
                }
            }
            self.notified.store(false, .release);
            while (!self.stopping.load(.acquire)) {
                self.blocked.store(true, .release);
                const result = try self.store.pollMaintenance(.{ .index_entries = 4096, .pages = storage.batch_size });
                if (result != .pending) self.blocked.store(false, .release);
                if (result != .progressed) break;
            }
        }
    }

    pub fn check(self: *const Maintenance) !void {
        if (self.failed.load(.acquire)) return self.failure.?;
    }

    /// Stop after other users quiesce. Outstanding I/O remains owned by the store.
    pub fn stop(self: *Maintenance) void {
        const thread = self.thread orelse return;
        std.debug.assert(self.thread_id.load(.acquire) != std.Thread.getCurrentId());
        const previous = self.store.resources.background.swap(null, .acq_rel);
        std.debug.assert(previous == self);
        self.stopping.store(true, .release);
        self.notify();
        thread.join();
        self.store.maintenance_io.ring.?.unregister_eventfd() catch unreachable;
        self.store.filesystem.ring.?.unregister_eventfd() catch unreachable;
        _ = std.os.linux.close(self.wake);
        self.thread = null;
        self.wake = -1;
    }
};
