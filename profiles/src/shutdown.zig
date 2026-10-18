const std = @import("std");
const sessions = @import("sessions");

pub const Shutdown = struct {
    io: std.Io,
    event: std.Io.Event = .unset,
    // Publish a stable slice before workers start and withdraw it before endpoints are freed.
    endpoints: std.atomic.Value(?*const []const *sessions.Service) = .init(null),

    pub fn requested(self: *const Shutdown) bool {
        return self.event.isSet();
    }

    pub fn request(self: *Shutdown) void {
        self.event.set(self.io);
        if (self.endpoints.load(.acquire)) |endpoints| {
            for (endpoints.*) |endpoint| endpoint.output_progress.set(self.io);
            if (endpoints.len != 0) endpoints.*[0].transport.notify(self.io);
        }
    }

    pub fn wait(self: *Shutdown, deadline: i96) std.Io.Cancelable!void {
        self.event.waitTimeout(self.io, .{ .deadline = .{ .clock = .awake, .raw = .{ .nanoseconds = deadline } } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        };
    }
};
