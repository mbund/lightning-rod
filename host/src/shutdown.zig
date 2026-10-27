const std = @import("std");

pub const Shutdown = struct {
    io: std.Io,
    event: std.Io.Event = .unset,
    pub fn requested(self: *const Shutdown) bool {
        return self.event.isSet();
    }
    pub fn request(self: *Shutdown) void {
        self.event.set(self.io);
    }
    pub fn wait(self: *Shutdown, deadline: i96) std.Io.Cancelable!void {
        self.event.waitTimeout(self.io, .{ .deadline = .{ .clock = .awake, .raw = .{ .nanoseconds = deadline } } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        };
    }
};
