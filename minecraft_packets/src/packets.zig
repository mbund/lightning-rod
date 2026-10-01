const std = @import("std");
const sessions = @import("sessions");
const protocols = @import("protocols");
const registry = @import("registry.zig");

const Registry = registry.Registry;

fn Writer(comptime callbacks: anytype) type {
    return struct {
        pub fn write(comptime Version: type, bytes: []u8, arguments: anytype) ![]u8 {
            const candidates = comptime sessions.packet_api.candidates(callbacks);
            const index = comptime sessions.packet_api.select(Version, callbacks);
            const handler = candidates[index];
            const parameters = @typeInfo(@TypeOf(handler)).@"fn".params;
            if (comptime parameters.len > 1 and parameters[1].type == Registry) {
                const selected: Registry = .{
                    .entities = Version.Registry.canonical_entity_to_wire,
                    .items = Version.Registry.canonical_item_to_wire,
                    .blocks = Version.Registry.canonical_block_to_wire,
                    .block_states = Version.Registry.canonical_block_state_to_wire,
                    .sounds = Version.Registry.canonical_sound_to_wire,
                    .effects = Version.Registry.canonical_effect_to_wire,
                    .attributes = Version.Registry.canonical_attribute_to_wire,
                };
                return sessions.packet_api.encode(Version, callbacks, bytes, .{selected} ++ arguments);
            }
            return sessions.packet_api.encode(Version, callbacks, bytes, arguments);
        }
    };
}

pub const Packets = struct {
    pub const id = "minecraft:packets";
    pub const Configuration = struct {};
    pub const Dependencies = struct { sessions: *sessions.Service };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Packets {
        comptime {
            for (protocols.implementations, 0..) |Implementation, index| {
                for (0..index) |previous|
                    if (protocols.implementations[previous].protocol_number == Implementation.protocol_number) @compileError("duplicate protocol implementation");
            }
        }
        for (deps.sessions.config.protocols) |selected| {
            var supported = false;
            inline for (protocols.implementations) |Implementation| supported = supported or selected.number == Implementation.protocol_number;
            if (!supported) return error.UnsupportedProtocol;
        }
        const self = try allocator.create(Packets);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn writePacket(self: *Packets, comptime encode_packet: anytype, protocol: i32, bytes: []u8, arguments: anytype) ![]u8 {
        _ = try self.definition(protocol);
        inline for (protocols.implementations) |Version| {
            if (protocol == Version.protocol_number) {
                const result = try Writer(encode_packet).write(Version, bytes, arguments);
                std.debug.assert(result.ptr == bytes.ptr);
                std.debug.assert(result.len <= bytes.len);
                return result;
            }
        }
        return error.UnsupportedProtocol;
    }

    pub fn sendPacket(self: *Packets, comptime encode_packet: anytype, protocol: i32, recipients: []const sessions.Handle, arguments: anytype, maximum_bytes: usize) !void {
        try self.deps.sessions.send(protocols.implementations, Writer(encode_packet), protocol, recipients, arguments, maximum_bytes);
    }

    pub fn sendPacketRetrying(self: *Packets, comptime encode_packet: anytype, protocol: i32, recipients: []const sessions.Handle, arguments: anytype, maximum_bytes: usize) !void {
        try self.deps.sessions.sendRetrying(protocols.implementations, Writer(encode_packet), protocol, recipients, arguments, maximum_bytes);
    }

    pub fn fanout(self: *Packets, comptime encode_packet: anytype, recipients: []const sessions.Service.Target, arguments: anytype, maximum_bytes: usize, delivered: []sessions.Service.Delivery) !void {
        try self.deps.sessions.fanout(protocols.implementations, Writer(encode_packet), recipients, arguments, maximum_bytes, delivered);
    }

    pub fn definition(self: *const Packets, number: i32) !*const sessions.Protocol {
        for (self.deps.sessions.config.protocols) |*selected| if (selected.number == number) return selected;
        return error.UnsupportedProtocol;
    }
};
