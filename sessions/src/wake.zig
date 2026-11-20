const std = @import("std");
const network = @import("networking");
const Readiness = @import("readiness.zig").Readiness;

/// Wakes a connection from any thread, for session plugins whose work finishes elsewhere, such
/// as a login waiting on an authentication server. The connection's next turn asks its plugins
/// again. Set once the engine exists; until then nothing can be waiting.
pub const Wake = struct {
    readiness: ?*Readiness = null,
    transport: ?network.Transport = null,
    io: std.Io = undefined,

    pub fn connection(self: *const Wake, handle: network.Handle) void {
        const readiness = self.readiness orelse return;
        readiness.signal(handle.index).notify();
        // The sessions thread may be waiting on the network with nothing else to do.
        if (self.transport) |transport| transport.notify(self.io);
    }
};
