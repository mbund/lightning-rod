const std = @import("std");
const lightning_rod = @import("lightning_rod");
const plugins = @import("plugins.zig");
const sessions = @import("sessions.zig");

const Endpoint = struct {
    pub const versions = .{};
};

/// The one plugin every runtime needs, with a session state large enough that the states of many
/// connections would not fit the plugins' fixed memory.
const Handshake = struct {
    pub const id = "test:handshake";
    pub const Configuration = struct {};
    pub const Dependencies = struct { handshake: *sessions.HandshakeInput };
    pub const SessionState = struct { bytes: [256]u8 = undefined };

    pub fn init(allocator: std.mem.Allocator, _: Configuration, deps: Dependencies) !*Handshake {
        const self = try allocator.create(Handshake);
        try deps.handshake.on(self, onHandshake);
        return self;
    }

    fn onHandshake(_: *Handshake, _: []const u8) !sessions.protocol.Handshake {
        return error.BadHandshake;
    }
};

test "the state of every connection is kept apart from the plugins' fixed memory" {
    const selections = lightning_rod.plugin.compose(.{lightning_rod.plugin.configured(Handshake, Handshake.Configuration{})});
    const Runtime = plugins.Runtime(Endpoint, @TypeOf(selections));
    // A megabyte of session state for 4096 connections, beside 64 KiB for the plugins.
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io, selections, .{}, 64 * 1024, 4096);
    defer runtime.deinit(std.testing.io);
    try std.testing.expectEqual(@as(usize, 4096), runtime.connections.len);
    try std.testing.expect(runtime.memoryBytes() > 4096 * 256);
}
