const std = @import("std");
const implementation = @import("core.zig");

pub fn Embedded(comptime Endpoint: type, comptime Plugins: type, comptime Router: type) type {
    return struct {
        const Self = @This();
        const Core = implementation.Core(Endpoint, Plugins, Router);
        pub const Configuration = Core.Configuration;
        pub const Options = Core.Options;
        pub const EndpointConfiguration = Core.EndpointConfiguration;

        core: *Core,
        allocator: std.mem.Allocator,
        io: std.Io,

        pub fn retainReload(comptime Backend: type) void {
            Core.retainReload(Backend);
        }

        pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration, options: Options) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{ .core = try Core.init(allocator, io, config, options), .allocator = allocator, .io = io };
            return self;
        }

        pub fn start(self: *Self) !void {
            self.core.worker.started = true;
        }

        pub fn poll(self: *Self) !void {
            _ = try self.core.worker.advance(self.io, std.Io.Clock.Timestamp.now(self.io, .awake));
            try self.core.transport.submit(self.io);
        }

        pub fn pause(self: *Self, deadline: std.Io.Clock.Timestamp) !void {
            self.core.quiesce(self.io);
            while (try self.core.worker.advance(self.io, deadline)) {
                if (std.Io.Clock.Timestamp.now(self.io, deadline.clock).raw.nanoseconds >= deadline.raw.nanoseconds) return error.Timeout;
            }
            self.core.transport.pause(self.io, true);
        }

        pub fn resumeReload(self: *Self) !void {
            try self.core.resumeReload(self.io);
        }

        pub fn stop(self: *Self) void {
            self.core.worker.stop();
            while (self.core.worker.advance(self.io, null) catch false) {}
            self.core.transport.pause(self.io, true);
        }

        pub fn deinit(self: *Self) void {
            self.core.deinit(self.io);
            self.allocator.destroy(self.core);
            self.allocator.destroy(self);
        }
    };
}
