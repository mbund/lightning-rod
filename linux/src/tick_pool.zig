const std = @import("std");
const TickScratch = @import("lightning_rod").core.TickScratch;
const Progress = @import("lightning_rod").runtime.Progress;

pub const Outcome = enum { ok, failed };
pub const Task = struct {
    context: *anyopaque,
    tick: *const fn (*anyopaque, *TickScratch) Outcome,
    minimum_scratch_bytes: usize = 0,
    begin_close: ?*const fn (*anyopaque, i128) Outcome = null,
    close_progress: ?*const fn (*anyopaque) ?Outcome = null,

    pub fn server(comptime Core: type, instance: *Core) Task {
        var task = core(Core, instance);
        task.tick = struct {
            fn tick(raw: *anyopaque, scratch: *TickScratch) Outcome {
                const value: *Core = @ptrCast(@alignCast(raw));
                const sessions = value.sessionsBoundary();
                if (!sessions.vtable.drain_input(sessions.context)) return .failed;
                defer sessions.vtable.finish_input(sessions.context);
                if (value.runtime().service() != .ok) return .failed;
                return switch (value.tickWithScratch(scratch)) {
                    .ok => .ok,
                    .failed => .failed,
                };
            }
        }.tick;
        return task;
    }

    pub fn core(comptime Core: type, instance: *Core) Task {
        return .{
            .context = instance,
            .tick = struct {
                fn tick(raw: *anyopaque, scratch: *TickScratch) Outcome {
                    const value: *Core = @ptrCast(@alignCast(raw));
                    return switch (value.tickWithScratch(scratch)) {
                        .ok => .ok,
                        .failed => .failed,
                    };
                }
            }.tick,
            .minimum_scratch_bytes = Core.minimum_tick_scratch_bytes,
            .begin_close = if (@hasDecl(Core, "beginClose")) struct {
                fn close(raw: *anyopaque, deadline_ns: i128) Outcome {
                    const value: *Core = @ptrCast(@alignCast(raw));
                    return switch (value.beginClose(deadline_ns)) {
                        .ok => .ok,
                        .failed => .failed,
                    };
                }
            }.close else null,
            .close_progress = if (@hasDecl(Core, "beginClose")) struct {
                fn progress(raw: *anyopaque) ?Outcome {
                    const value: *Core = @ptrCast(@alignCast(raw));
                    return switch (value.closeProgress()) {
                        .complete => .ok,
                        .pending => null,
                        .failed => .failed,
                    };
                }
            }.progress else null,
        };
    }
};
pub const Handle = struct { index: u32, generation: u32 };
pub const Timing = struct {
    ticks: u64 = 0,
    last_ns: u64 = 0,
    maximum_ns: u64 = 0,
    total_ns: u128 = 0,
};
const State = enum(u8) { free, idle, ready, running, complete, failed, closing, closed, close_failed };
const Slot = struct {
    state: std.atomic.Value(State) = .init(.free),
    generation: u32 = 1,
    task: Task = undefined,
    timing: Timing = .{},
};
const Worker = struct {
    pool: *Pool,
    wake: std.Io.Event = .unset,
    thread: ?std.Thread = null,
    scratch: TickScratch,
};
const Ready = struct {
    sequence: std.atomic.Value(u64),
    index: u32 = undefined,
};

/// One coordinator owns registration/scheduling/polling. Task contexts remain
/// stable until unregistered; workers exclusively own them during a submitted tick.
pub const Pool = struct {
    pub const ScheduleError = error{ StaleCore, CoreBusy, CoreFailed, SchedulerBusy, PoolPaused };
    pub const Configuration = struct {
        maximum_cores: u32,
        workers: u16,
        stack_bytes: usize,
        scratch_bytes: usize = 64 * 1024,
    };
    pub const Memory = struct {
        allocator_bytes: usize,
        scratch_bytes: usize,
        requested_stack_bytes: usize,
    };

    /// Requested allocation payloads, excluding Core storage, allocator overhead,
    /// and platform stack rounding, guard pages, and TLS. Not an RSS estimate.
    pub fn memoryRequired(config: Configuration) error{InvalidPoolCapacity}!Memory {
        if (config.maximum_cores == 0 or config.workers == 0 or config.stack_bytes == 0 or config.scratch_bytes == 0)
            return error.InvalidPoolCapacity;
        const ready_count = std.math.ceilPowerOfTwo(usize, @max(config.maximum_cores, 2)) catch return error.InvalidPoolCapacity;
        const scratch = std.math.mul(usize, config.workers, config.scratch_bytes) catch return error.InvalidPoolCapacity;
        const stacks = std.math.mul(usize, config.workers, config.stack_bytes) catch return error.InvalidPoolCapacity;
        var bytes = scratch;
        const counts = .{ config.maximum_cores, config.workers, ready_count };
        inline for (.{ Slot, Worker, Ready }, counts) |T, count| {
            const size = std.math.mul(usize, count, @sizeOf(T)) catch return error.InvalidPoolCapacity;
            bytes = std.math.add(usize, bytes, size) catch return error.InvalidPoolCapacity;
        }
        return .{ .allocator_bytes = bytes, .scratch_bytes = scratch, .requested_stack_bytes = stacks };
    }

    allocator: std.mem.Allocator,
    io: std.Io,
    slots: []Slot,
    workers: []Worker,
    ready: []Ready,
    scratch_storage: []u8,
    read: std.atomic.Value(u64) = .init(0),
    write: u64 = 0,
    stopping: std.atomic.Value(bool) = .init(false),
    paused: bool = false,

    pub fn init(self: *Pool, allocator: std.mem.Allocator, io: std.Io, config: Configuration) !void {
        const memory = try memoryRequired(config);
        const ready_count = std.math.ceilPowerOfTwo(usize, @max(config.maximum_cores, 2)) catch return error.InvalidPoolCapacity;
        const slots = try allocator.alloc(Slot, config.maximum_cores);
        errdefer allocator.free(slots);
        const workers = try allocator.alloc(Worker, config.workers);
        errdefer allocator.free(workers);
        const ready = try allocator.alloc(Ready, ready_count);
        errdefer allocator.free(ready);
        const scratch = try allocator.alloc(u8, memory.scratch_bytes);
        errdefer allocator.free(scratch);
        for (ready, 0..) |*entry, index| entry.* = .{ .sequence = .init(index) };
        @memset(slots, .{});
        self.* = .{ .allocator = allocator, .io = io, .slots = slots, .workers = workers, .ready = ready, .scratch_storage = scratch };
        for (workers, 0..) |*worker, index| {
            const bytes = scratch[index * config.scratch_bytes ..][0..config.scratch_bytes];
            worker.* = .{ .pool = self, .scratch = .{ .bytes = bytes, .fixed = std.heap.FixedBufferAllocator.init(bytes) } };
        }
        errdefer self.join();
        for (workers) |*worker|
            worker.thread = try std.Thread.spawn(.{ .stack_size = config.stack_bytes }, runWorker, .{worker});
    }

    pub fn deinit(self: *Pool) void {
        self.join();
        for (self.slots) |*slot| {
            const state = slot.state.load(.acquire);
            std.debug.assert(state == .free or slot.task.begin_close == null or state == .closed);
        }
        self.allocator.free(self.workers);
        self.allocator.free(self.slots);
        self.allocator.free(self.ready);
        self.allocator.free(self.scratch_storage);
        self.* = undefined;
    }

    pub fn register(self: *Pool, task: Task) !Handle {
        if (self.paused) return error.PoolPaused;
        if ((task.begin_close == null) != (task.close_progress == null)) return error.InvalidTaskLifecycle;
        if (task.minimum_scratch_bytes > self.workers[0].scratch.bytes.len)
            return error.InsufficientWorkerScratch;
        var available: ?usize = null;
        for (self.slots, 0..) |*slot, index| {
            if (slot.state.load(.acquire) == .free) {
                if (available == null) available = index;
            } else if (slot.task.context == task.context) return error.AlreadyRegistered;
        }
        const index = available orelse return error.CoreCapacity;
        const slot = &self.slots[index];
        slot.task = task;
        slot.timing = .{};
        slot.state.store(.idle, .release);
        return .{ .index = @intCast(index), .generation = slot.generation };
    }

    pub fn unregister(self: *Pool, handle: Handle) !void {
        const slot = try self.lookup(handle);
        switch (slot.state.load(.acquire)) {
            .idle, .failed => if (slot.task.begin_close != null) return error.CoreNotClosed,
            .closed => {},
            else => return error.CoreBusy,
        }
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        slot.state.store(.free, .release);
    }

    pub fn retire(self: *Pool, handle: Handle, deadline_ns: i128) !void {
        const slot = try self.lookup(handle);
        switch (slot.state.load(.acquire)) {
            .idle, .failed => {},
            .closing, .closed => return,
            .close_failed => return error.CoreCloseFailed,
            else => return error.CoreBusy,
        }
        if (slot.task.begin_close) |begin| {
            slot.state.store(.closing, .release);
            if (begin(slot.task.context, deadline_ns) != .ok) {
                slot.state.store(.close_failed, .release);
                return error.CoreCloseFailed;
            }
        } else slot.state.store(.closed, .release);
    }

    pub fn schedule(self: *Pool, handle: Handle) ScheduleError!void {
        var results: [1]ScheduleError!void = undefined;
        self.scheduleBatch(&.{handle}, &results);
        return results[0];
    }

    /// Stop admission, not already accepted ticks. Poll their outcomes normally.
    pub fn pause(self: *Pool) void {
        self.paused = true;
    }

    pub fn pauseProgress(self: *const Pool) Progress {
        std.debug.assert(self.paused);
        var pending = false;
        for (self.slots) |*slot| switch (slot.state.load(.acquire)) {
            .free, .idle, .closed => {},
            .failed, .close_failed => return .failed,
            .ready, .running, .complete, .closing => pending = true,
        };
        return if (pending) .pending else .complete;
    }

    pub fn unpause(self: *Pool) !void {
        std.debug.assert(self.paused);
        switch (self.pauseProgress()) {
            .complete => self.paused = false,
            .pending => return error.CoreBusy,
            .failed => return error.CoreFailed,
        }
    }

    pub fn scheduleBatch(self: *Pool, handles: []const Handle, results: []ScheduleError!void) void {
        std.debug.assert(handles.len == results.len);
        var scheduled = false;
        for (handles, results) |handle, *result| {
            result.* = admit: {
                if (self.paused) break :admit error.PoolPaused;
                const slot = self.lookup(handle) catch |err| break :admit err;
                switch (slot.state.load(.acquire)) {
                    .idle => {},
                    .failed => break :admit error.CoreFailed,
                    else => break :admit error.CoreBusy,
                }
                const entry = &self.ready[self.write % self.ready.len];
                if (entry.sequence.load(.acquire) != self.write) break :admit error.SchedulerBusy;
                const previous = slot.state.cmpxchgStrong(.idle, .ready, .release, .monotonic);
                std.debug.assert(previous == null);
                entry.index = handle.index;
                entry.sequence.store(self.write +% 1, .release);
                self.write +%= 1;
                scheduled = true;
                break :admit;
            };
        }
        if (scheduled) for (self.workers) |*worker| worker.wake.set(self.io);
    }

    pub fn poll(self: *Pool, handle: Handle) !?Outcome {
        const slot = try self.lookup(handle);
        return switch (slot.state.load(.acquire)) {
            .complete => result: {
                slot.state.store(.idle, .release);
                break :result .ok;
            },
            .failed => .failed,
            .closing => result: {
                const outcome = slot.task.close_progress.?(slot.task.context) orelse break :result null;
                slot.state.store(if (outcome == .ok) .closed else .close_failed, .release);
                break :result outcome;
            },
            .closed => .ok,
            .close_failed => .failed,
            else => null,
        };
    }

    pub fn timing(self: *Pool, handle: Handle) !Timing {
        const slot = try self.lookup(handle);
        switch (slot.state.load(.acquire)) {
            .ready, .running => return error.CoreBusy,
            else => return slot.timing,
        }
    }

    fn lookup(self: *Pool, handle: Handle) !*Slot {
        if (handle.index >= self.slots.len) return error.StaleCore;
        const slot = &self.slots[handle.index];
        if (slot.generation != handle.generation or slot.state.load(.acquire) == .free) return error.StaleCore;
        return slot;
    }

    fn join(self: *Pool) void {
        self.stopping.store(true, .release);
        for (self.workers) |*worker| worker.wake.set(self.io);
        for (self.workers) |*worker| {
            if (worker.thread) |thread| thread.join();
            worker.thread = null;
        }
    }

    fn runWorker(worker: *Worker) void {
        const pool = worker.pool;
        while (true) {
            worker.wake.reset();
            while (true) {
                const read = pool.read.load(.monotonic);
                const entry = &pool.ready[read % pool.ready.len];
                if (entry.sequence.load(.acquire) != read +% 1) break;
                if (pool.read.cmpxchgWeak(read, read +% 1, .monotonic, .monotonic) != null) continue;
                const index = entry.index;
                entry.sequence.store(read +% pool.ready.len, .release);
                const slot = &pool.slots[index];
                const previous = slot.state.cmpxchgStrong(.ready, .running, .acquire, .monotonic);
                std.debug.assert(previous == null);
                std.debug.assert(!worker.scratch.active);
                const started = std.Io.Clock.Timestamp.now(pool.io, .awake).raw.nanoseconds;
                const outcome = slot.task.tick(slot.task.context, &worker.scratch);
                std.debug.assert(!worker.scratch.active);
                const finished = std.Io.Clock.Timestamp.now(pool.io, .awake).raw.nanoseconds;
                const elapsed: u64 = @intCast(finished - started);
                slot.timing.ticks +|= 1;
                slot.timing.last_ns = elapsed;
                slot.timing.maximum_ns = @max(slot.timing.maximum_ns, elapsed);
                slot.timing.total_ns +|= elapsed;
                slot.state.store(if (outcome == .ok) .complete else .failed, .release);
            }
            if (pool.stopping.load(.acquire)) return;
            worker.wake.waitUncancelable(pool.io);
        }
    }
};

test "connected Core task owns drain service tick and cleanup including failures" {
    const lr = @import("lightning_rod");
    const Exchange = lr.core_exchange.SessionExchange(.{ .to_core_pages = 2, .to_sessions_pages = 1, .to_core_page_bytes = 64, .to_sessions_page_bytes = 64, .to_core_messages = 4, .to_sessions_messages = 1 });
    const Core = struct {
        const Stage = enum { idle, drained, serviced };
        pub const minimum_tick_scratch_bytes = 64;
        consumer: lr.core_exchange.InputConsumer(Exchange),
        inbox: lr.core_exchange.Inbox,
        stage: Stage = .idle,
        fail: enum { none, drain, service, tick } = .none,
        ticks: usize = 0,
        finished: usize = 0,
        sum: i32 = 0,

        pub fn sessionsBoundary(self: *@This()) lr.sessions.CoreBoundary {
            const vtable = comptime blk: {
                var result: lr.sessions.CoreBoundary.VTable = undefined;
                result.drain_input = drain;
                result.finish_input = finish;
                break :blk result;
            };
            return .{ .context = self, .vtable = &vtable };
        }
        pub fn runtime(self: *@This()) lr.runtime.Core {
            const vtable = comptime blk: {
                var result: lr.runtime.Core.VTable = undefined;
                result.service = service;
                break :blk result;
            };
            return .{ .context = self, .vtable = &vtable };
        }
        fn drain(raw: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(self.stage == .idle);
            if (self.fail == .drain) return false;
            if (!self.consumer.inputDrain().drain(&self.inbox)) return false;
            self.stage = .drained;
            return true;
        }
        fn service(raw: *anyopaque) lr.runtime.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(self.stage == .drained);
            if (self.fail == .service) return .failed;
            self.stage = .serviced;
            return .ok;
        }
        pub fn tickWithScratch(self: *@This(), scratch: *TickScratch) Outcome {
            std.debug.assert(self.stage == .serviced);
            const temporary = scratch.begin();
            defer scratch.finish();
            const values = temporary.alloc(i32, self.inbox.packet_count) catch return .failed;
            for (self.inbox.input().packet_views, values) |packet, *value| value.* = packet.id;
            for (values) |value| self.sum += value;
            self.ticks += 1;
            return if (self.fail == .tick) .failed else .ok;
        }
        fn finish(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(self.stage != .idle);
            self.inbox.clear();
            self.stage = .idle;
            self.finished += 1;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pool: Pool = undefined;
    try pool.init(std.testing.allocator, std.testing.io, .{ .maximum_cores = 1, .workers = 1, .stack_bytes = 256 * 1024, .scratch_bytes = 64 });
    defer pool.deinit();
    var exchange = Exchange{};
    exchange.initialize();
    var producer = lr.core_exchange.InputProducer(Exchange).init(&exchange);
    var core = Core{ .consumer = .init(&exchange), .inbox = try lr.core_exchange.Inbox.init(arena.allocator(), 4, 64) };
    for ([_]@TypeOf(core.fail){ .none, .drain, .service, .tick }) |failure| {
        core.fail = failure;
        const handle = try pool.register(Task.server(Core, &core));
        const finished = core.finished;
        const ticks = core.ticks;
        const packets = [_]lr.core_exchange.PacketView{.{ .connection = .{ .index = 900, .generation = 4 }, .protocol = 772, .id = 17, .bytes = "payload" }};
        if (failure == .none) try std.testing.expect(producer.ingress().stage(.{ .attachments = &.{}, .detachments = &.{}, .packet_views = &packets, .packet_claimed = &.{} }));
        try pool.schedule(handle);
        try std.testing.expectEqual(if (failure == .none) Outcome.ok else Outcome.failed, try waitForTest(&pool, handle));
        try std.testing.expectEqual(finished + @intFromBool(failure != .drain), core.finished);
        try std.testing.expectEqual(ticks + @intFromBool(failure == .none or failure == .tick), core.ticks);
        try std.testing.expectEqual(Core.Stage.idle, core.stage);
        try std.testing.expectEqual(@as(i32, 17), core.sum);
        if (failure != .none) try std.testing.expectError(error.CoreFailed, pool.schedule(handle));
        try pool.unregister(handle);
    }
}

test "a blocked Core cannot be reentered and does not form a barrier for another Core" {
    const Context = struct {
        entered: std.Io.Event = .unset,
        release: std.Io.Event = .unset,
        active: std.atomic.Value(bool) = .init(false),
        ticks: usize = 0,
        blocking: bool = false,
        fail: bool = false,
        scratch_address: usize = 0,

        fn tick(raw: *anyopaque, scratch: *TickScratch) Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const temporary = scratch.begin();
            defer scratch.finish();
            const bytes = temporary.alloc(u8, 64) catch return .failed;
            self.scratch_address = @intFromPtr(bytes.ptr);
            @memset(bytes, if (self.blocking) 0x51 else 0x72);
            std.debug.assert(!self.active.swap(true, .acq_rel));
            defer self.active.store(false, .release);
            self.ticks += 1;
            self.entered.set(std.testing.io);
            if (self.blocking) self.release.waitUncancelable(std.testing.io);
            for (bytes) |value| std.debug.assert(value == if (self.blocking) @as(u8, 0x51) else @as(u8, 0x72));
            return if (self.fail) .failed else .ok;
        }
    };
    var pool: Pool = undefined;
    try pool.init(std.testing.allocator, std.testing.io, .{ .maximum_cores = 2, .workers = 2, .stack_bytes = 256 * 1024 });
    defer pool.deinit();
    var slow = Context{ .blocking = true };
    defer slow.release.set(std.testing.io);
    var fast = Context{};
    const slow_handle = try pool.register(.{ .context = &slow, .tick = Context.tick });
    const fast_handle = try pool.register(.{ .context = &fast, .tick = Context.tick });
    try std.testing.expectError(error.AlreadyRegistered, pool.register(.{ .context = &slow, .tick = Context.tick }));
    var excess = Context{};
    try std.testing.expectError(error.CoreCapacity, pool.register(.{ .context = &excess, .tick = Context.tick }));
    try pool.schedule(slow_handle);
    slow.entered.waitUncancelable(std.testing.io);
    try std.testing.expectError(error.CoreBusy, pool.schedule(slow_handle));
    try std.testing.expectError(error.CoreBusy, pool.unregister(slow_handle));
    for (0..16) |index| {
        try pool.schedule(fast_handle);
        try std.testing.expectEqual(Outcome.ok, try waitForTest(&pool, fast_handle));
        try std.testing.expectEqual(index + 1, fast.ticks);
        try std.testing.expect(slow.active.load(.acquire));
        try std.testing.expect(slow.scratch_address != fast.scratch_address);
    }
    fast.fail = true;
    var results: [3]Pool.ScheduleError!void = undefined;
    pool.scheduleBatch(&.{ slow_handle, .{ .index = std.math.maxInt(u32), .generation = 1 }, fast_handle }, &results);
    try std.testing.expectError(error.CoreBusy, results[0]);
    try std.testing.expectError(error.StaleCore, results[1]);
    try results[2];
    try std.testing.expectEqual(Outcome.failed, try waitForTest(&pool, fast_handle));
    try std.testing.expectError(error.CoreFailed, pool.schedule(fast_handle));
    try pool.unregister(fast_handle);
    const replacement = try pool.register(.{ .context = &excess, .tick = Context.tick });
    try std.testing.expectEqual(fast_handle.index, replacement.index);
    try std.testing.expect(fast_handle.generation != replacement.generation);
    try std.testing.expectError(error.StaleCore, pool.schedule(fast_handle));
    try pool.schedule(replacement);
    try std.testing.expectEqual(Outcome.ok, try waitForTest(&pool, replacement));
    slow.release.set(std.testing.io);
    try std.testing.expectEqual(Outcome.ok, try waitForTest(&pool, slow_handle));
    try std.testing.expectEqual(@as(usize, 1), slow.ticks);
}

fn waitForTest(pool: *Pool, handle: Handle) !Outcome {
    for (0..1000) |_| {
        if (try pool.poll(handle)) |result| return result;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.TestTimeout;
}

test "checkpoint pause drains accepted work and requires observing failed ticks" {
    const Context = struct {
        entered: std.Io.Event = .unset,
        release: std.Io.Event = .unset,
        fail: bool = false,
        ticks: usize = 0,
        fn tick(raw: *anyopaque, _: *TickScratch) Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.entered.set(std.testing.io);
            self.release.waitUncancelable(std.testing.io);
            self.ticks += 1;
            return if (self.fail) .failed else .ok;
        }
    };
    var pool: Pool = undefined;
    try pool.init(std.testing.allocator, std.testing.io, .{ .maximum_cores = 2, .workers = 1, .stack_bytes = 256 * 1024 });
    defer pool.deinit();
    var context = Context{};
    defer context.release.set(std.testing.io);
    const task = Task{ .context = &context, .tick = Context.tick };
    const handle = try pool.register(task);
    try pool.schedule(handle);
    context.entered.waitUncancelable(std.testing.io);
    pool.pause();
    try std.testing.expectEqual(Progress.pending, pool.pauseProgress());
    try std.testing.expectError(error.CoreBusy, pool.unpause());
    try std.testing.expectError(error.PoolPaused, pool.register(task));
    var results: [2]Pool.ScheduleError!void = undefined;
    pool.scheduleBatch(&.{ handle, handle }, &results);
    for (results) |result| try std.testing.expectError(error.PoolPaused, result);
    context.release.set(std.testing.io);
    try std.testing.expectEqual(Outcome.ok, try waitForTest(&pool, handle));
    try std.testing.expectEqual(Progress.complete, pool.pauseProgress());
    try std.testing.expectEqual(@as(usize, 1), context.ticks);
    try pool.unpause();
    context.fail = true;
    try pool.schedule(handle);
    pool.pause();
    try std.testing.expectEqual(Outcome.failed, try waitForTest(&pool, handle));
    try std.testing.expectEqual(Progress.failed, pool.pauseProgress());
    try std.testing.expectError(error.CoreFailed, pool.unpause());
    try std.testing.expectEqual(@as(usize, 2), context.ticks);
}

test "one worker drains a full batch in submission order across queue wraparound" {
    const Count = 63;
    const Context = struct {
        const Shared = struct {
            entered: std.Io.Event = .unset,
            release: std.Io.Event = .unset,
            order: [Count]usize = undefined,
            count: usize = 0,
        };
        shared: *Shared,
        index: usize,

        fn tick(raw: *anyopaque, _: *TickScratch) Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.index == Count - 1) {
                self.shared.entered.set(std.testing.io);
                self.shared.release.waitUncancelable(std.testing.io);
            }
            self.shared.order[self.shared.count] = self.index;
            self.shared.count += 1;
            return .ok;
        }
    };
    var pool: Pool = undefined;
    try pool.init(std.testing.allocator, std.testing.io, .{ .maximum_cores = Count, .workers = 1, .stack_bytes = 256 * 1024 });
    defer pool.deinit();
    var shared = Context.Shared{};
    defer shared.release.set(std.testing.io);
    var contexts: [Count]Context = undefined;
    var handles: [Count]Handle = undefined;
    for (&contexts, &handles, 0..) |*context, *handle, index| {
        context.* = .{ .shared = &shared, .index = index };
        handle.* = try pool.register(.{ .context = context, .tick = Context.tick });
    }
    for (0..8) |round| {
        shared.count = 0;
        shared.entered.reset();
        shared.release.reset();
        try pool.schedule(handles[Count - 1]);
        shared.entered.waitUncancelable(std.testing.io);
        if (round == 0) {
            const cursor = std.math.maxInt(u64) - 31;
            pool.read.store(cursor, .monotonic);
            pool.write = cursor;
            for (0..pool.ready.len) |offset| {
                const position = cursor +% offset;
                pool.ready[position % pool.ready.len].sequence.store(position, .monotonic);
            }
        }
        var batch: [Count - 1]Handle = undefined;
        var results: [Count - 1]Pool.ScheduleError!void = undefined;
        for (&batch, 0..) |*handle, index| handle.* = handles[Count - 2 - index];
        pool.scheduleBatch(&batch, &results);
        for (results) |result| try result;
        shared.release.set(std.testing.io);
        for (handles) |handle| try std.testing.expectEqual(Outcome.ok, try waitForTest(&pool, handle));
        try std.testing.expectEqual(Count, shared.count);
        for (shared.order, 0..) |index, position| try std.testing.expectEqual(Count - 1 - position, index);
    }
}

test "multiple workers execute accepted ticks exactly once and shutdown drains the queue" {
    const Count = 17;
    const Rounds = 128;
    const Context = struct {
        pub const minimum_tick_scratch_bytes = 64 * 1024;
        ticks: usize = 0,
        pub fn tickWithScratch(self: *@This(), scratch: *TickScratch) Outcome {
            const temporary = scratch.begin();
            defer scratch.finish();
            _ = temporary.alloc(u8, scratch.bytes.len) catch return .failed;
            self.ticks += 1;
            return .ok;
        }
    };
    var pool: Pool = undefined;
    try pool.init(std.testing.allocator, std.testing.io, .{ .maximum_cores = Count, .workers = 4, .stack_bytes = 256 * 1024 });
    var live = true;
    defer if (live) pool.deinit();
    var contexts: [Count]Context = @splat(.{});
    var handles: [Count]Handle = undefined;
    var oversized = Task.core(Context, &contexts[0]);
    oversized.minimum_scratch_bytes += 1;
    try std.testing.expectError(error.InsufficientWorkerScratch, pool.register(oversized));
    for (&contexts, &handles) |*context, *handle|
        handle.* = try pool.register(Task.core(Context, context));
    for (0..Rounds) |round| {
        for (handles) |handle| {
            for (0..1000) |_| {
                pool.schedule(handle) catch |err| switch (err) {
                    error.SchedulerBusy => {
                        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
                        continue;
                    },
                    else => return err,
                };
                break;
            } else return error.TestTimeout;
        }
        if (round == Rounds - 1) break;
        for (handles) |handle| try std.testing.expectEqual(Outcome.ok, try waitForTest(&pool, handle));
        for (contexts) |context| try std.testing.expectEqual(round + 1, context.ticks);
        for (handles) |handle| {
            const observed = try pool.timing(handle);
            try std.testing.expectEqual(round + 1, observed.ticks);
            try std.testing.expect(observed.maximum_ns >= observed.last_ns);
            try std.testing.expect(observed.total_ns >= observed.maximum_ns);
        }
    }
    pool.deinit();
    live = false;
    for (contexts) |context| try std.testing.expectEqual(Rounds, context.ticks);
}

test "connected two-world Cores fit one MiB and stay isolated on shared tick workers" {
    const lr = @import("lightning_rod");
    const Simulation = struct {
        pub const id = "test:island_simulation";
        pub const Configuration = struct { island: u64 };
        pub const Dependencies = struct { worlds: *lr.worlds.Worlds };
        pub const tick_scratch_bytes = 4096;
        deps: Dependencies,
        config: Configuration,
        ticks: u64 = 0,

        pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{ .deps = deps, .config = config };
            return self;
        }

        pub fn tick(self: *@This(), temporary: std.mem.Allocator) void {
            const values = temporary.alloc(u64, 512) catch unreachable;
            @memset(values, self.config.island);
            for (self.deps.worlds.active()) |handle| {
                const world = self.deps.worlds.get(handle).?;
                world.seed += self.config.island;
                world.tickets += 1;
            }
            for (values) |value| std.debug.assert(value == self.config.island);
            self.ticks += 1;
        }

        pub fn checkpoint(self: *@This(), writer: *@import("lightning_rod").plugin_lifecycle.Checkpoint.NamespaceWriter) !void {
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &bytes, self.config.island, .little);
            try writer.put("island", &bytes);
        }
    };
    const descriptions = [_]lr.worlds.Description{
        .{ .key = .{ .value = 1 }, .name = "overworld", .dimension = .{ .index = 0 }, .generator = @enumFromInt(0), .seed = 0, .spawn_x = 0, .spawn_y = 64, .spawn_z = 0 },
        .{ .key = .{ .value = 2 }, .name = "nether", .dimension = .{ .index = 1 }, .generator = @enumFromInt(0), .seed = 0, .spawn_x = 0, .spawn_y = 64, .spawn_z = 0 },
    };
    var selected = lr.plugin.compose(.{
        lr.plugin.configured(lr.worlds.Worlds, lr.worlds.Worlds.Configuration{ .initial = &descriptions, .maximum_worlds = 2 }),
        lr.plugin.configured(lr.player_lifecycle.Events, .{}),
        lr.plugin.configured(lr.players.Players, .{ .initial_world = descriptions[0].key, .maximum_connections = 2, .maximum_players = 2 }),
        lr.plugin.configured(lr.players.Containers, .{}),
        lr.plugin.configured(lr.random.Random, .{}),
        lr.plugin.configured(lr.blocks.Blocks, .{ .maximum_transient_chunks = 4, .maximum_modified_sections = 4, .maximum_block_mutations = 32 }),
        lr.plugin.configured(lr.inputs.Inputs, .{ .maximum_block_requests = 16, .maximum_inventory_clicks = 16, .maximum_creative_slot_changes = 16 }),
        lr.plugin.configured(lr.entities.LivingEntities, .{ .maximum_entities = 16, .maximum_search_nodes = 32, .maximum_path_nodes = 16 }),
        lr.plugin.configured(lr.entities.ItemEntities, .{ .maximum_entities = 32, .spatial_bucket_count = 16 }),
        lr.plugin.configured(lr.Packets, .{ .maximum_input_packets = 16, .input_byte_capacity = 1024, .maximum_player_messages = 8 }),
        lr.plugin.configured(Simulation, Simulation.Configuration{ .island = 1 }),
    });
    const Core = lr.core.Server(@TypeOf(selected));
    const Exchange = lr.core_exchange.SessionExchange(.{ .to_core_pages = 2, .to_sessions_pages = 1, .to_core_page_bytes = 512, .to_sessions_page_bytes = 512, .to_core_messages = 16, .to_sessions_messages = 16 });
    try std.testing.expectEqual(@as(usize, 4096), Core.minimum_tick_scratch_bytes);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const store = try lr.persistence.Store.initForTest(allocator, .{
        .maximum_keys = 8,
        .maximum_checkpoint_records = 8,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 64,
        .maximum_key_bytes = 16,
        .maximum_value_bytes = 32,
        .maximum_checkpoint_bytes = 2048,
    }, 4096);
    var pool: Pool = undefined;
    try pool.init(std.testing.allocator, std.testing.io, .{ .maximum_cores = 8, .workers = 2, .stack_bytes = 256 * 1024, .scratch_bytes = 4096 });
    defer pool.deinit();
    const pool_memory = try Pool.memoryRequired(.{ .maximum_cores = 8, .workers = 2, .stack_bytes = 256 * 1024, .scratch_bytes = 4096 });
    try std.testing.expectEqual(pool_memory.allocator_bytes, std.mem.sliceAsBytes(pool.slots).len +
        std.mem.sliceAsBytes(pool.workers).len + std.mem.sliceAsBytes(pool.ready).len + pool.scratch_storage.len);
    try std.testing.expectEqual(@as(usize, 8192), pool_memory.scratch_bytes);
    try std.testing.expectEqual(@as(usize, 512 * 1024), pool_memory.requested_stack_bytes);
    try std.testing.expectError(error.InvalidPoolCapacity, Pool.memoryRequired(.{ .maximum_cores = 8, .workers = 2, .stack_bytes = std.math.maxInt(usize) }));
    var cores: [8]*Core = undefined;
    var saved_players: [8]lr.test_support.state.SavedPlayers = @splat(.{});
    var handles: [8]Handle = undefined;
    var scopes: [8]*lr.persistence.Scope = undefined;
    var wires: [8]*Exchange = undefined;
    var producers: [8]lr.core_exchange.InputProducer(Exchange) = undefined;
    const Router = lr.core_exchange.InputRouter(8);
    var router = Router.init(null);
    var quiescent = router.quiescent();
    const persistence_access = lr.persistence.Access.init(.{ .interface = store.interface(), .maximum_checkpoint_records = 1 });
    for (&cores, &handles, &scopes, 1..) |*core, *handle, *scope, island| {
        selected[selected.len - 1].configuration.island = island;
        const memory = try allocator.alloc(u8, 1024 * 1024);
        var fixed = std.heap.FixedBufferAllocator.init(memory);
        const settings = try fixed.allocator().create(lr.sessions.Sessions);
        settings.* = lr.sessions.Sessions.init(772);
        const wire = try fixed.allocator().create(Exchange);
        wires[island - 1] = wire;
        wire.initialize();
        const input = try fixed.allocator().create(lr.core_exchange.InputConsumer(Exchange));
        input.* = .init(wire);
        var identity: [8]u8 = undefined;
        std.mem.writeInt(u64, &identity, island, .little);
        scope.* = try lr.persistence.Scope.init(fixed.allocator(), &persistence_access, &identity, &.{Simulation.id}, 64, 1);
        const boundary_bytes = fixed.end_index;
        core.* = try Core.create(fixed.allocator(), std.testing.io, scope.*.interface(), .{ .memory_bytes = memory.len - boundary_bytes, .tick_bytes = 0, .profiling = false }, null);
        try core.*.initialize(selected, .{ .sessions = settings, .meta = .{} });
        try core.*.get(lr.players.Players).bindSavedPlayerStorage(saved_players[island - 1].interface());
        core.*.bindInputDrain(input.inputDrain());
        try std.testing.expectEqual(memory.len, fixed.end_index);
        try std.testing.expectEqual(@as(usize, 1024 * 1024), core.*.memory().capacity_bytes + boundary_bytes);
        try std.testing.expectEqual(@as(usize, 0), core.*.memory().tick_capacity_bytes);
        producers[island - 1] = .init(wire);
        var name: [16]u8 = @splat(0);
        const text = try std.fmt.bufPrint(&name, "island{d}", .{island});
        const attachment = lr.core_exchange.AttachPlayer{ .connection = .{ .index = @intCast(island * 10_000), .generation = 1 }, .protocol = 772, .uuid = island, .name = name, .name_len = @intCast(text.len), .reconfiguring = false };
        try Router.bind(&quiescent, attachment.connection, producers[island - 1].ingress());
        try std.testing.expectEqual(Router.Admission.accepted, router.publish(.{ .attachments = &.{attachment}, .detachments = &.{}, .packet_views = &.{}, .packet_claimed = &.{} }));
        handle.* = try pool.register(Task.server(Core, core.*));
    }
    for (0..32) |_| {
        for (handles) |handle| try pool.schedule(handle);
        for (handles) |handle| try std.testing.expectEqual(Outcome.ok, try waitForTest(&pool, handle));
    }
    pool.pause();
    try std.testing.expectEqual(Progress.complete, pool.pauseProgress());
    try std.testing.expectError(error.PoolPaused, pool.schedule(handles[0]));
    for (cores) |core| {
        try std.testing.expectEqual(lr.runtime.Outcome.ok, core.stageCheckpoint());
        try std.testing.expect(!store.checkpoint_requested);
        try std.testing.expectEqual(@as(usize, 0), store.test_storage_len);
    }
    try std.testing.expectEqual(lr.persistence.Status.pending, store.requestCheckpoint());
    store.submit();
    _ = store.complete(1);
    try std.testing.expectEqual(@as(u64, 1), store.generation);
    try pool.unpause();
    for (cores, handles, scopes, 1..) |core, handle, scope, island| {
        try std.testing.expectEqual(@as(u64, 32), core.get(Simulation).ticks);
        const worlds = core.get(lr.worlds.Worlds);
        try std.testing.expectEqual(@as(usize, 2), worlds.active().len);
        for (worlds.active()) |world| {
            try std.testing.expectEqual(@as(u64, island * 32), worlds.get(world).?.seed);
            try std.testing.expectEqual(@as(u32, 32), worlds.get(world).?.tickets);
        }
        try std.testing.expectEqual(lr.runtime.Progress.complete, core.runtime().checkpointProgress());
        const players = core.get(lr.players.Players);
        try std.testing.expectEqual(@as(usize, 1), players.active_count);
        try std.testing.expectEqual(@as(u128, island), players.records[players.active_slots[0]].uuid);
        var encoded: [8]u8 = undefined;
        const request = scope.interface().namespace(Simulation.id).read("island", &encoded);
        _ = store.complete(1);
        try std.testing.expectEqual(lr.persistence.Status.ready, scope.interface().pollRead(request).status);
        try std.testing.expectEqual(@as(u64, island), std.mem.readInt(u64, &encoded, .little));
        var failed_stage: ?lr.runtime.Outcome = null;
        var failed_capture: ?lr.runtime.CheckpointCapture = null;
        if (island == 7 or island == 8) {
            const wire = wires[island - 1];
            if (island == 7) {
                var producer = lr.core_exchange.InputProducer(Exchange).init(wire);
                var arrivals: [2]lr.core_exchange.AttachPlayer = undefined;
                for (&arrivals, 0..) |*arrival, index| arrival.* = .{ .connection = .{ .index = @intCast(100_000 + index), .generation = 1 }, .uuid = 100 + index, .protocol = 772, .name = @splat('x'), .name_len = 1, .reconfiguring = false };
                try std.testing.expect(producer.ingress().stage(.{ .attachments = &arrivals, .detachments = &.{}, .packet_views = &.{}, .packet_claimed = &.{} }));
            } else {
                const page = wire.to_core.acquireFor(1).?;
                wire.to_core.producerBytes(page)[0] = 0;
                try std.testing.expect(wire.to_core.submit(.{ .connection = .{ .index = 80_000, .generation = 1 }, .kind = .input, .page = page, .len = 1 }));
            }
            try pool.schedule(handle);
            try std.testing.expectEqual(Outcome.failed, try waitForTest(&pool, handle));
            try std.testing.expectEqual(@as(u64, 32), core.get(Simulation).ticks);
            failed_stage = core.stageCheckpoint();
            failed_capture = core.runtime().captureCheckpoint();
        }
        try std.testing.expectError(error.CoreNotClosed, pool.unregister(handle));
        try pool.retire(handle, 0);
        try std.testing.expectEqual(Outcome.ok, try waitForTest(&pool, handle));
        try pool.unregister(handle);
        if (failed_stage) |result| try std.testing.expectEqual(lr.runtime.Outcome.failed, result);
        if (failed_capture) |result| try std.testing.expectEqual(lr.runtime.CheckpointCapture.failed, result);
    }
    try std.testing.expectEqual(@as(usize, 8), store.liveRecords());
    for (scopes, 1..) |scope, island| {
        var encoded: [8]u8 = undefined;
        const request = scope.interface().namespace(Simulation.id).read("island", &encoded);
        _ = store.complete(1);
        try std.testing.expectEqual(lr.persistence.Status.ready, scope.interface().pollRead(request).status);
        try std.testing.expectEqual(@as(u64, island), std.mem.readInt(u64, &encoded, .little));
    }
    const recovered = try lr.persistence.Store.initForTest(allocator, store.configuration, 4096);
    const committed = store.test_storage[0..store.test_storage_len];
    try std.testing.expectEqual(@as(usize, 0), try recovered.recover(committed[0 .. committed.len - 1]));
    try std.testing.expectEqual(@as(usize, 0), recovered.liveRecords());
    try std.testing.expectEqual(committed.len, try recovered.recover(committed));
    try std.testing.expectEqual(@as(usize, 8), recovered.liveRecords());
    @memcpy(recovered.test_storage[0..committed.len], committed);
    recovered.test_storage_len = committed.len;
    const recovered_access = lr.persistence.Access.init(.{ .interface = recovered.interface(), .maximum_checkpoint_records = 1 });
    for (1..9) |island| {
        var identity: [8]u8 = undefined;
        std.mem.writeInt(u64, &identity, island, .little);
        const scope = try lr.persistence.Scope.init(std.testing.allocator, &recovered_access, &identity, &.{Simulation.id}, 64, 1);
        defer scope.deinit(std.testing.allocator);
        var encoded: [8]u8 = undefined;
        const request = scope.interface().namespace(Simulation.id).read("island", &encoded);
        _ = recovered.complete(1);
        try std.testing.expectEqual(lr.persistence.Status.ready, scope.interface().pollRead(request).status);
        try std.testing.expectEqual(@as(u64, island), std.mem.readInt(u64, &encoded, .little));
    }
}

test "retiring Core stays owned until close completes without blocking another Core" {
    const Core = struct {
        pub const minimum_tick_scratch_bytes = 0;
        ticks: u32 = 0,
        closing: bool = false,
        ready: bool = false,
        deadline: i128 = 0,

        pub fn tickWithScratch(self: *@This(), _: *TickScratch) Outcome {
            std.debug.assert(!self.closing);
            self.ticks += 1;
            return .ok;
        }
        pub fn beginClose(self: *@This(), deadline: i128) @import("lightning_rod").runtime.Outcome {
            std.debug.assert(!self.closing);
            self.closing = true;
            self.deadline = deadline;
            return .ok;
        }
        pub fn closeProgress(self: *@This()) @import("lightning_rod").runtime.Progress {
            return if (self.ready) .complete else .pending;
        }
    };
    var pool: Pool = undefined;
    try pool.init(std.testing.allocator, std.testing.io, .{ .maximum_cores = 2, .workers = 1, .stack_bytes = 256 * 1024 });
    defer pool.deinit();
    var first = Core{};
    var second = Core{};
    const a = try pool.register(Task.core(Core, &first));
    const b = try pool.register(Task.core(Core, &second));
    try pool.retire(a, 1234);
    try pool.retire(a, 5678);
    try std.testing.expectEqual(@as(i128, 1234), first.deadline);
    try std.testing.expectEqual(@as(?Outcome, null), try pool.poll(a));
    try std.testing.expectError(error.CoreBusy, pool.unregister(a));
    try std.testing.expectError(error.CoreBusy, pool.schedule(a));
    var replacement = Core{};
    try std.testing.expectError(error.CoreCapacity, pool.register(Task.core(Core, &replacement)));
    try pool.schedule(b);
    try std.testing.expectEqual(Outcome.ok, try waitForTest(&pool, b));
    try std.testing.expectEqual(@as(u32, 1), second.ticks);
    try std.testing.expectEqual(@as(u32, 0), first.ticks);
    first.ready = true;
    try std.testing.expectEqual(Outcome.ok, (try pool.poll(a)).?);
    try pool.unregister(a);
    const next = try pool.register(Task.core(Core, &replacement));
    try std.testing.expectEqual(a.index, next.index);
    try std.testing.expect(next.generation != a.generation);
    try std.testing.expectError(error.StaleCore, pool.retire(a, 0));
    replacement.ready = true;
    second.ready = true;
    try pool.retire(next, 0);
    try pool.retire(b, 0);
    try std.testing.expectEqual(Outcome.ok, (try pool.poll(next)).?);
    try std.testing.expectEqual(Outcome.ok, (try pool.poll(b)).?);
    try pool.unregister(next);
    try pool.unregister(b);
}
