const std = @import("std");

pub const Listener = struct {
    server: ?std.Io.net.Server,

    pub fn init(io: std.Io, address: []const u8) !Listener {
        const requested = try std.Io.net.IpAddress.parseLiteral(address);
        return .{ .server = try requested.listen(io, .{}) };
    }

    pub fn deinit(self: *Listener, io: std.Io) void {
        if (self.server) |*server| server.deinit(io);
        self.server = null;
    }

    /// The runner serializes child creation. Only this child inherits the reservation.
    pub fn spawn(self: *Listener, io: std.Io, options: std.process.SpawnOptions) !std.process.Child {
        std.debug.assert(options.progress_node.index == .none);
        const fd = self.server.?.socket.handle;
        const result = std.os.linux.fcntl(fd, std.os.linux.F.SETFD, @as(usize, 0));
        if (std.os.linux.errno(result) != .SUCCESS) return error.InvalidListener;
        defer {
            const restored = std.os.linux.fcntl(fd, std.os.linux.F.SETFD, @as(usize, std.os.linux.FD_CLOEXEC));
            std.debug.assert(std.os.linux.errno(restored) == .SUCCESS);
        }
        return std.process.spawn(io, options);
    }
};

test "simultaneous listeners reserve distinct ports and transfer through exec" {
    const io = std.testing.io;
    var first = try Listener.init(io, "127.0.0.1:0");
    defer first.deinit(io);
    var second = try Listener.init(io, "127.0.0.1:0");
    defer second.deinit(io);
    try std.testing.expect(first.server.?.socket.address.getPort() != 0);
    try std.testing.expect(first.server.?.socket.address.getPort() != second.server.?.socket.address.getPort());
    var address_bytes: [128]u8 = undefined;
    const address = try std.fmt.bufPrint(&address_bytes, "{f}", .{first.server.?.socket.address});
    try std.testing.expectError(error.AddressInUse, Listener.init(io, address));
    var path_bytes: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, "/proc/self/fd/{d}", .{first.server.?.socket.handle});
    var second_path_bytes: [64]u8 = undefined;
    const second_path = try std.fmt.bufPrint(&second_path_bytes, "/proc/self/fd/{d}", .{second.server.?.socket.handle});
    var child = try first.spawn(io, .{ .argv = &.{ "sh", "-c", "test -S \"$1\" && ! test -S \"$2\"", "listener-test", path, second_path } });
    const result = try child.wait(io);
    try std.testing.expect(result == .exited and result.exited == 0);
}
