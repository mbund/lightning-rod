const std = @import("std");
const metrics = @import("metrics");

const assert = std.debug.assert;

/// I/O and presentation work on the Simulation owner, not additional gameplay ticks.
pub const Work = struct {
    pub const Result = enum { idle, progressed, blocked };

    pub const Task = struct {
        context: *anyopaque,
        maximum_items: usize,
        vtable: *const VTable,

        item_ns: u64 = std.time.ns_per_ms,
        batch_ns: u64 = std.time.ns_per_ms,
        duration: metrics.Timer = .{},

        pub const VTable = struct {
            /// Never process more than the supplied item limit. Blocked requires an external wakeup.
            run: *const fn (*anyopaque, std.Io, usize) anyerror!Result,
        };

        // Callbacks cannot be interrupted. Reserve for both item cost and fixed batch overhead.
        fn limit(self: Task, remaining_ns: u64) usize {
            if (remaining_ns / 2 < self.batch_ns) return 0;
            return @intCast(@min(self.maximum_items, remaining_ns / self.item_ns / 2));
        }
    };

    tasks: []Task,
    count: usize = 0,
    next: usize = 0,
    sealed: bool = false,
    registration_timer: metrics.Timer = .{},

    pub fn register(self: *Work, owner: anytype, maximum_items: usize, comptime handler: anytype) !void {
        const Adapter = struct {
            const vtable: Task.VTable = .{ .run = @This().invoke };

            fn invoke(raw: *anyopaque, io: std.Io, limit: usize) anyerror!Result {
                const typed: @TypeOf(owner) = @ptrCast(@alignCast(raw));
                return handler(typed, io, limit);
            }
        };
        const task: Task = .{ .context = owner, .maximum_items = maximum_items, .vtable = &Adapter.vtable };
        assert(!self.sealed);
        assert(task.maximum_items > 0);
        assert(task.item_ns > 0);
        assert(task.batch_ns > 0);
        if (self.count == self.tasks.len) return error.WorkCapacity;
        self.tasks[self.count] = task;
        self.tasks[self.count].duration = self.registration_timer;
        self.count += 1;
        assert(self.count <= self.tasks.len);
    }

    // Decay once per tick so a transient stall cannot starve a task.
    pub fn beginTick(self: *Work) void {
        for (self.tasks[0..self.count]) |*task| {
            task.item_ns = @max(100 * std.time.ns_per_us, task.item_ns - task.item_ns / 8);
            task.batch_ns = @max(100 * std.time.ns_per_us, task.batch_ns - task.batch_ns / 8);
        }
    }

    pub fn progress(self: *Work, io: std.Io, deadline: i96) !Result {
        assert(self.sealed);
        assert(self.count <= self.tasks.len);
        var result: Result = .idle;

        for (0..self.count) |_| {
            const task = &self.tasks[self.next];
            self.next = (self.next + 1) % self.count;

            const started = std.Io.Clock.now(.awake, io).nanoseconds;
            if (started >= deadline) return result;
            const limit = task.limit(@intCast(deadline - started));
            if (limit == 0) continue;

            const scope = task.duration.start();
            const progressed = task.vtable.run(task.context, io, limit);
            const elapsed: u64 = @intCast(std.Io.Clock.now(.awake, io).nanoseconds - started);
            task.item_ns = @max(task.item_ns, std.math.divCeil(u64, elapsed, limit) catch unreachable);
            task.batch_ns = @max(task.batch_ns, elapsed);
            scope.end();
            switch (try progressed) {
                .progressed => return .progressed,
                .blocked => result = .blocked,
                .idle => {},
            }
        }

        return result;
    }
};

test "work records successful and failed callbacks" {
    const io = std.testing.io;
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 1 });
    defer registry.deinit();
    const duration = try registry.timer(.{ .name = "work", .description = "Callback duration" });
    var tasks: [1]Work.Task = undefined;
    var work: Work = .{ .tasks = &tasks, .registration_timer = duration };
    const State = struct {
        calls: u32 = 0,
        fn run(self: *@This(), _: std.Io, limit: usize) !Work.Result {
            std.debug.assert(limit == 1);
            self.calls += 1;
            if (self.calls == 2) return error.TaskFailed;
            return .progressed;
        }
    };
    var state: State = .{};
    try work.register(&state, 1, State.run);
    work.sealed = true;
    try std.testing.expectEqual(Work.Result.progressed, try work.progress(io, std.Io.Clock.now(.awake, io).nanoseconds + std.time.ns_per_s));
    try std.testing.expectError(error.TaskFailed, work.progress(io, std.Io.Clock.now(.awake, io).nanoseconds + std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 2), duration.read().?.count);
}

test "work admission scales batches and recovers from slow samples" {
    var tasks: [1]Work.Task = .{.{ .context = undefined, .maximum_items = 4, .vtable = undefined }};
    const task = &tasks[0];
    try std.testing.expectEqual(@as(usize, 0), task.limit(2 * std.time.ns_per_ms - 1));
    try std.testing.expectEqual(@as(usize, 1), task.limit(2 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(usize, 3), task.limit(6 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(usize, 4), task.limit(20 * std.time.ns_per_ms));
    task.batch_ns = 8 * std.time.ns_per_ms;
    try std.testing.expectEqual(@as(usize, 0), task.limit(16 * std.time.ns_per_ms - 1));
    try std.testing.expectEqual(@as(usize, 4), task.limit(16 * std.time.ns_per_ms));
    var work: Work = .{ .tasks = &tasks, .count = 1, .sealed = true };
    task.item_ns = std.time.ns_per_s;
    task.batch_ns = std.time.ns_per_s;
    for (0..100) |_| work.beginTick();
    try std.testing.expect(task.item_ns <= std.time.ns_per_ms);
    try std.testing.expect(task.batch_ns <= std.time.ns_per_ms);
    try std.testing.expectEqual(Work.Result.idle, try work.progress(std.testing.io, 0));
}
