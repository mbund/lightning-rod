const std = @import("std");
const implementation = @import("core.zig");

pub fn Threaded(comptime Endpoint: type, comptime Plugins: type, comptime Router: type) type {
    return Driver(implementation.Core(Endpoint, Plugins, Router));
}

fn Driver(comptime Core: type) type {
    return struct {
        const Self = @This();
        pub const Configuration = Core.Configuration;
        pub const Options = Core.Options;
        pub const EndpointConfiguration = Core.EndpointConfiguration;

        core: *Core,
        allocator: std.mem.Allocator,
        io: std.Io,
        thread: ?std.Thread = null,
        closing: std.atomic.Value(bool) = .init(false),
        parked: std.Io.Event = .unset,
        resume_requested: std.Io.Event = .unset,
        failure: ?anyerror = null,

        pub fn retainReload(comptime Backend: type) void {
            Core.retainReload(Backend);
        }

        pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration, options: Options) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{ .core = try Core.init(allocator, io, config, options), .allocator = allocator, .io = io };
            errdefer {
                self.core.deinit(io);
                allocator.destroy(self.core);
            }
            const before = options.memory.assigned_bytes;
            try self.core.worker.initCodec(io, options.metrics);
            self.core.owned_bytes += options.memory.assigned_bytes - before;
            self.core.owned_buffers.set(self.core.owned_bytes);
            return self;
        }

        pub fn start(self: *Self) !void {
            std.debug.assert(self.thread == null and !self.closing.load(.acquire));
            try self.core.worker.engine.codec.?.start();
            errdefer self.core.worker.engine.codec.?.stop();
            self.thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, execute, .{self});
        }

        fn execute(self: *Self) void {
            while (true) {
                self.core.run(self.io) catch |err| {
                    self.failure = err;
                    self.parked.set(self.io);
                    return;
                };
                self.parked.set(self.io);
                if (self.closing.load(.acquire) and self.core.worker.drained()) return;
                self.resume_requested.waitUncancelable(self.io);
                self.resume_requested.reset();
                if (self.closing.load(.acquire) and self.core.worker.drained()) return;
                self.parked.reset();
            }
        }

        pub fn check(self: *Self) !void {
            if (self.parked.isSet()) if (self.failure) |err| return err;
        }

        pub fn pause(self: *Self, deadline: std.Io.Clock.Timestamp) !void {
            self.core.quiesce(self.io);
            try self.parked.waitTimeout(self.io, .{ .deadline = deadline });
            try self.check();
        }

        pub fn resumeReload(self: *Self) !void {
            try self.check();
            try self.core.resumeReload(self.io);
            self.parked.reset();
            self.resume_requested.set(self.io);
        }

        pub fn stop(self: *Self) void {
            if (self.thread) |thread| {
                self.closing.store(true, .release);
                self.core.worker.stop();
                self.core.transport.notify(self.io);
                self.resume_requested.set(self.io);
                thread.join();
                self.thread = null;
                self.core.worker.engine.codec.?.stop();
                if (self.failure != null) self.core.abort(self.io);
            }
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(self.thread == null);
            self.core.deinit(self.io);
            self.allocator.destroy(self.core);
            self.allocator.destroy(self);
        }
    };
}

test "terminal network failure is joined without retrying normal drain" {
    const TestCodec = struct {
        started: bool = false,
        fn start(self: *@This()) !void {
            self.started = true;
        }
        fn stop(self: *@This()) void {
            self.started = false;
        }
    };
    const TestWorker = struct {
        engine: struct { codec: ?*TestCodec },
        is_drained: bool = false,
        fn drained(self: *const @This()) bool {
            return self.is_drained;
        }
        fn stop(_: *@This()) void {}
    };
    const TestCore = struct {
        pub const Configuration = void;
        pub const Options = void;
        pub const EndpointConfiguration = void;
        worker: *TestWorker,
        transport: struct {
            fn notify(_: *@This(), _: std.Io) void {}
        } = .{},
        runs: usize = 0,
        aborted: bool = false,
        fn run(self: *@This(), _: std.Io) !void {
            self.runs += 1;
            // Bound the regression case so retrying fails this test without hanging it.
            if (self.runs > 1) self.worker.is_drained = true;
            return error.InjectedFailure;
        }
        fn abort(self: *@This(), _: std.Io) void {
            std.debug.assert(!self.worker.engine.codec.?.started);
            self.aborted = true;
        }
    };
    var codec: TestCodec = .{};
    var worker: TestWorker = .{ .engine = .{ .codec = &codec } };
    var core: TestCore = .{ .worker = &worker };
    var driver: Driver(TestCore) = .{ .core = &core, .allocator = std.testing.allocator, .io = std.testing.io };
    try driver.start();
    defer driver.stop();
    try driver.parked.waitTimeout(std.testing.io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(2) } });
    try std.testing.expectError(error.InjectedFailure, driver.check());
    driver.stop();
    try std.testing.expectEqual(@as(usize, 1), core.runs);
    try std.testing.expect(core.aborted);
    try std.testing.expect(!worker.drained());
    try std.testing.expect(driver.thread == null);
}
