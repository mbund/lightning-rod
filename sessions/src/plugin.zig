const std = @import("std");
const sessions = @import("sessions.zig");

pub const Routing = struct { endpoints: []const *sessions.Service };

pub const World = struct {
    pub const id = "lightning_rod:session_endpoint";
    pub const Configuration = struct { endpoint: ?*sessions.Service = null };
    pub const Provides = .{*sessions.Service};
    endpoint: *sessions.Service,
    pub fn init(allocator: std.mem.Allocator, config: Configuration) !*World {
        const endpoint = config.endpoint orelse return error.InvalidSessionEndpoint;
        const self = try allocator.create(World);
        self.* = .{ .endpoint = endpoint };
        return self;
    }
    pub fn provide(self: *World, comptime Contract: type) Contract {
        if (Contract != *sessions.Service) @compileError("unsupported session endpoint service");
        return self.endpoint;
    }
    pub fn beginTick(self: *World) void {
        self.endpoint.beginTick();
    }
    pub fn endTick(self: *World, completed: bool) void {
        self.endpoint.endTick(completed);
    }
    pub fn publish(self: *World) void {
        self.endpoint.flush();
    }
};
