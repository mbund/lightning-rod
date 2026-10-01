const std = @import("std");
const sessions = @import("sessions");
const support = @import("support");
const wire = @import("wire.zig");

pub const Handshake = struct {
    pub const id = "minecraft:handshake";
    pub const Configuration = struct {};
    pub const Dependencies = struct { handshake: *sessions.HandshakeInput };
    pub const SessionState = struct {};

    pub fn init(allocator: std.mem.Allocator, _: Configuration, deps: Dependencies) !*Handshake {
        const self = try allocator.create(Handshake);
        try deps.handshake.on(self, onHandshake);
        return self;
    }

    fn onHandshake(_: *Handshake, bytes: []const u8) !sessions.protocol.Handshake {
        const packet_id, const a = try support.read_varint(bytes);
        if (packet_id != 0) return error.BadHandshake;
        const protocol, const b = try support.read_varint(a);
        const host_length, const host = try support.read_varint(b);
        if (host_length < 0 or host_length > 255 or host_length > host.len) return error.BadHandshake;
        const c = host[@intCast(host_length)..];
        _, const d = try support.read_u16(c);
        const intent, const rest = try support.read_varint(d);
        if (rest.len != 0) return error.BadHandshake;
        return .{ .protocol = protocol, .intent = switch (intent) {
            1 => .status,
            2 => .login,
            else => return error.BadHandshake,
        } };
    }
};

pub const Bootstrap = struct {
    pub const frame = wire.Wire.frame;

    pub fn control(packet: []const u8, scratch: []u8, output: []u8) ![]const u8 {
        var codec: wire.Wire = .{};
        var workspace: wire.Wire.Workspace = undefined;
        return codec.control(packet, scratch, output, &workspace, null);
    }
};
