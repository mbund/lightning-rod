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
            return self;
        }

        pub fn start(self: *Self) !void {
            std.debug.assert(self.thread == null and !self.closing.load(.acquire));
            // Unoptimized builds keep a frame per protocol state, which outgrew 256 KiB for a
            // debug server on a baseline CPU.
            self.thread = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, execute, .{self});
            // Named for profilers and per thread usage. Only a label, so failing to set it is fine.
            self.thread.?.setName(self.io, "sessions") catch {};
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
    const TestWorker = struct {
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
            self.aborted = true;
        }
    };
    var worker: TestWorker = .{};
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
