const std = @import("std");
const builtin = @import("builtin");
const chunks = @import("chunks");
const metrics = @import("metrics");

pub const Generation = struct {
    const Worker = struct {
        pool: *Generation,
        ready: std.Io.Event = .unset,
        thread: ?std.Thread = null,
        subscribed: bool = false,

        fn run(self: *Worker) void {
            const pool = self.pool;
            while (!pool.queue.stopping.load(.acquire)) {
                self.ready.waitUncancelable(pool.io);
                self.ready.reset();
                if (pool.queue.stopping.load(.acquire)) return;
                while (!pool.queue.stopping.load(.acquire)) {
                    const count = pool.queue.processBatch(pool.io) catch |err| {
                        pool.queue.fail(err);
                        return;
                    };
                    if (count == 0) break;
                }
            }
        }
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    queue: *chunks.Generation,
    workers: []Worker,
    started: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, queue: *chunks.Generation, workers: usize) !*Generation {
        if (workers > 64) return error.InvalidGenerationWorkers;
        if (builtin.single_threaded and workers != 0) return error.ThreadsUnavailable;
        const self = try allocator.create(Generation);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .io = io, .queue = queue, .workers = try allocator.alloc(Worker, workers) };
        for (self.workers) |*worker| worker.* = .{ .pool = self };
        return self;
    }

    pub fn start(self: *Generation) !void {
        std.debug.assert(!self.started);
        self.queue.start(self.workers.len != 0);
        self.started = true;
        errdefer self.stop();
        for (self.workers) |*worker| {
            try self.queue.subscribe(&worker.ready);
            worker.subscribed = true;
        }
        for (self.workers) |*worker| {
            if (comptime builtin.single_threaded) {
                unreachable;
            } else {
                worker.thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, Worker.run, .{worker});
            }
        }
    }

    pub fn stop(self: *Generation) void {
        if (!self.started) return;
        self.queue.stop();
        for (self.workers) |*worker| {
            if (worker.thread) |thread| {
                thread.join();
                worker.thread = null;
            }
            if (worker.subscribed) self.queue.unsubscribe(&worker.ready);
            worker.subscribed = false;
        }
        self.queue.finish();
        self.started = false;
    }

    pub fn deinit(self: *Generation) void {
        std.debug.assert(!self.started);
        self.allocator.free(self.workers);
        self.allocator.destroy(self);
    }
};

test "generation workers execute concurrently and retain completed results across restart" {
    const Source = struct {
        entered: std.atomic.Value(usize) = .init(0),
        concurrent: std.Io.Event = .unset,
        release: std.Io.Event = .unset,

        fn read(self: *@This(), io: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests, 0..) |*request, index| {
                request.result = self.readOne(io, request.section, request.output);
                batch.complete(batch.requests[index..][0..1]);
            }
        }

        fn readOne(self: *@This(), io: std.Io, section: chunks.Section, output: []u8) !usize {
            if (self.entered.fetchAdd(1, .acq_rel) == 1) self.concurrent.set(io);
            self.release.waitUncancelable(io);
            return chunks.uniform(@intCast(section.x), output);
        }
    };
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
    defer registry.deinit();
    var ready: std.Io.Event = .unset;
    const queue = try chunks.Generation.init(arena.allocator(), io, 4, &ready, &registry);
    var source: Source = .{};
    queue.setSource(chunks.Source.init(&source, Source.read));
    const pool = try Generation.init(std.testing.allocator, io, queue, 2);
    defer pool.deinit();
    try pool.start();
    defer pool.stop();
    defer source.release.set(io);
    const sections = [_]chunks.Section{
        .{ .world = 0, .x = 1, .y = 0, .z = 0 },
        .{ .world = 0, .x = 2, .y = 0, .z = 0 },
    };
    var buffers: [2][8193]u8 = undefined;
    const requests = [_]chunks.Generation.Request{
        .{ .section = sections[0], .destination = &buffers[0], .token = 0 },
        .{ .section = sections[1], .destination = &buffers[1], .token = 1 },
    };
    try std.testing.expectEqual(sections.len, queue.submit(&requests, .{}));
    try source.concurrent.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
    source.release.set(io);
    while (queue.ready_count.load(.acquire) != sections.len) {
        queue.completed.reset();
        if (queue.ready_count.load(.acquire) != sections.len) try queue.completed.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
    }
    pool.stop();
    try pool.start();
    for (sections) |section| {
        const result = queue.take(section).?;
        try std.testing.expectEqual(@as(u16, @intCast(section.x)), std.mem.readInt(u16, (try result.result)[1..3], .little));
        queue.release(result);
    }
    try std.testing.expectEqual(queue.slots.len, queue.free_count);
}

test "canceling a running generation retains its destination until the worker returns" {
    const Source = struct {
        entered: std.Io.Event = .unset,
        release: std.Io.Event = .unset,
        fn read(self: *@This(), io: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests, 0..) |*request, index| {
                request.result = self.readOne(io, request.section, request.output);
                batch.complete(batch.requests[index..][0..1]);
            }
        }

        fn readOne(self: *@This(), io: std.Io, _: chunks.Section, output: []u8) !usize {
            self.entered.set(io);
            self.release.waitUncancelable(io);
            return chunks.uniform(7, output);
        }
    };
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
    defer registry.deinit();
    var ready: std.Io.Event = .unset;
    const queue = try chunks.Generation.init(arena.allocator(), io, 1, &ready, &registry);
    var source: Source = .{};
    queue.setSource(chunks.Source.init(&source, Source.read));
    const pool = try Generation.init(std.testing.allocator, io, queue, 1);
    defer pool.deinit();
    try pool.start();
    defer pool.stop();
    defer source.release.set(io);
    var destination: [8193]u8 = undefined;
    const request: chunks.Generation.Request = .{ .section = .{ .world = 0, .x = 0, .y = 0, .z = 0 }, .destination = &destination, .token = 42 };
    try std.testing.expectEqual(@as(usize, 1), queue.submit(&.{request}, .{}));
    try source.entered.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
    queue.update(0, null);
    try std.testing.expect(queue.next() == null);
    try std.testing.expectEqual(@as(usize, 0), queue.free_count);
    source.release.set(io);
    while (queue.ready_count.load(.acquire) == 0) {
        queue.completed.reset();
        if (queue.ready_count.load(.acquire) == 0) try queue.completed.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
    }
    const completion = queue.next().?;
    try std.testing.expectEqual(@as(usize, 42), completion.token);
    try std.testing.expectError(error.Obsolete, completion.result);
    queue.release(completion);
    try std.testing.expectEqual(@as(usize, 1), queue.free_count);
}
