const std = @import("std");
const sessions = @import("sessions");
const protocols = @import("protocols");
const registry = @import("registry.zig");

const Registry = registry.Registry;

fn Writer(comptime callbacks: anytype) type {
    return struct {
        pub fn writeGroup(comptime Version: type, buffers: []const []u8, lengths: []usize, arguments: anytype) !void {
            std.debug.assert(buffers.len == 1 and lengths.len == 1);
            lengths[0] = (try write(Version, buffers[0], arguments)).len;
        }

        pub fn write(comptime Version: type, bytes: []u8, arguments: anytype) ![]u8 {
            const candidates = comptime sessions.packet_api.candidates(callbacks);
            const index = comptime sessions.packet_api.select(Version, callbacks);
            const handler = candidates[index];
            const parameters = @typeInfo(@TypeOf(handler)).@"fn".param_types;
            if (comptime parameters.len > 1 and parameters[1] == Registry) {
                const selected: Registry = .{
                    .entities = Version.Registry.canonical_entity_to_wire,
                    .items = Version.Registry.canonical_item_to_wire,
                    .blocks = Version.Registry.canonical_block_to_wire,
                    .block_states = Version.Registry.canonical_block_state_to_wire,
                    .block_state_bits = Version.Registry.block_state_bits,
                    .sounds = Version.Registry.canonical_sound_to_wire,
                    .effects = Version.Registry.canonical_effect_to_wire,
                    .attributes = Version.Registry.canonical_attribute_to_wire,
                };
                const encoded = try sessions.packet_api.encode(Version, callbacks, bytes, .{selected} ++ arguments);
                std.debug.assert(encoded.ptr == bytes.ptr and encoded.len <= bytes.len);
                return encoded;
            }
            const encoded = try sessions.packet_api.encode(Version, callbacks, bytes, arguments);
            std.debug.assert(encoded.ptr == bytes.ptr and encoded.len <= bytes.len);
            return encoded;
        }
    };
}

fn GroupWriter(comptime callbacks: anytype) type {
    return struct {
        pub fn writeGroup(comptime Version: type, buffers: []const []u8, lengths: []usize, arguments: anytype) !void {
            const bundled = callbacks.len > 1;
            const offset: usize = @intFromBool(bundled);
            std.debug.assert(buffers.len == callbacks.len + offset * 2 and buffers.len == lengths.len);
            if (bundled) {
                lengths[0] = (try (try Version.Protocol.play.toClient.write(buffers[0]).bundle_delimiter()).value()).finish().len;
                lengths[lengths.len - 1] = (try (try Version.Protocol.play.toClient.write(buffers[buffers.len - 1]).bundle_delimiter()).value()).finish().len;
            }
            inline for (callbacks, 0..) |callback, index| {
                lengths[index + offset] = (Writer(callback).write(Version, buffers[index + offset], arguments[index]) catch |err| switch (@as(anyerror, err)) {
                    error.UnsupportedItem, error.UnsupportedComponent => return error.UnsupportedEncoding,
                    else => return err,
                }).len;
            }
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

    pub fn sendPacket(self: *Packets, comptime encode_packet: anytype, protocol: i32, recipient: sessions.Handle, arguments: anytype, maximum_bytes: usize) !void {
        try self.deps.sessions.send(protocols.implementations, Writer(encode_packet), protocol, recipient, arguments, maximum_bytes);
    }

    pub fn sendPacketRetrying(self: *Packets, comptime encode_packet: anytype, protocol: i32, recipient: sessions.Handle, arguments: anytype, maximum_bytes: usize) !void {
        try self.deps.sessions.sendRetrying(protocols.implementations, Writer(encode_packet), protocol, recipient, arguments, maximum_bytes);
    }

    /// Delivery is independent per recipient. Encoding is skipped for blocked protocol groups.
    pub fn fanout(self: *Packets, comptime encode_packet: anytype, recipients: []const sessions.Service.Target, arguments: anytype, maximum_bytes: usize, delivered: []sessions.Service.Delivery) !void {
        try self.deps.sessions.fanout(protocols.implementations, Writer(encode_packet), recipients, arguments, &.{maximum_bytes}, delivered);
    }

    pub fn broadcast(self: *Packets, batch: *sessions.Service.Broadcast, comptime encode_packet: anytype, excluded: ?sessions.Handle, required: ?sessions.Service.Broadcast.Receipt, arguments: anytype, maximum_bytes: usize) !sessions.Service.Broadcast.Receipt {
        std.debug.assert(batch.owner == self.deps.sessions);
        return batch.write(protocols.implementations, Writer(encode_packet), excluded, required, arguments, maximum_bytes);
    }

    pub fn broadcastGroup(self: *Packets, batch: *sessions.Service.Broadcast, comptime callbacks: anytype, excluded: ?sessions.Handle, required: ?sessions.Service.Broadcast.Receipt, arguments: anytype, maximum_bytes: []const usize) !sessions.Service.Broadcast.Receipt {
        std.debug.assert(batch.owner == self.deps.sessions);
        const offset: usize = @intFromBool(callbacks.len > 1);
        const count = callbacks.len + offset * 2;
        comptime std.debug.assert(callbacks.len > 0 and count <= sessions.Service.batch_max);
        std.debug.assert(maximum_bytes.len == callbacks.len);
        var capacities: [count]usize = undefined;
        if (offset != 0) {
            capacities[0] = 5;
            capacities[count - 1] = 5;
        }
        @memcpy(capacities[offset..][0..callbacks.len], maximum_bytes);
        return batch.writeGroup(protocols.implementations, GroupWriter(callbacks), excluded, required, arguments, &capacities);
    }

    /// Each recipient admits every member or none. Multiple members are bundled without interleaving.
    /// Callbacks encode once per protocol directly into reserved output storage before publication.
    pub fn fanoutGroup(self: *Packets, comptime callbacks: anytype, recipients: []const sessions.Service.Target, arguments: anytype, maximum_bytes: []const usize, delivered: []sessions.Service.Delivery) !void {
        const offset: usize = @intFromBool(callbacks.len > 1);
        const count = callbacks.len + offset * 2;
        comptime {
            std.debug.assert(callbacks.len > 0 and count <= sessions.Service.batch_max);
            std.debug.assert(@typeInfo(@TypeOf(arguments)).@"struct".field_names.len == callbacks.len);
        }
        std.debug.assert(maximum_bytes.len == callbacks.len);
        var capacities: [count]usize = undefined;
        if (offset != 0) {
            capacities[0] = 5;
            capacities[count - 1] = 5;
        }
        @memcpy(capacities[offset..][0..callbacks.len], maximum_bytes);
        try self.deps.sessions.fanout(protocols.implementations, GroupWriter(callbacks), recipients, arguments, &capacities, delivered);
    }

    pub fn definition(self: *const Packets, number: i32) !*const sessions.Protocol {
        for (self.deps.sessions.config.protocols) |*selected| if (selected.number == number) return selected;
        return error.UnsupportedProtocol;
    }
};
