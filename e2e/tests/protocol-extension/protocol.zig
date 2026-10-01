const std = @import("std");
const java = @import("minecraft_java");
const sessions = @import("sessions");
const game_data = @import("game_data");
const wire = @import("wire");
const registry = @import("registry");

pub const implementations = .{ Custom, Crypt };
pub const Input = sessions.Inputs(implementations);
pub const Protocols = java.RegistryCatalog(implementations);
pub const Endpoint = sessions.Endpoint(implementations, Custom.Bootstrap, Protocols);
pub const Handshake = struct {
    pub const id = "example:handshake";
    pub const Configuration = struct {};
    pub const Dependencies = struct { handshake: *sessions.HandshakeInput };
    pub const SessionState = struct {};

    pub fn init(allocator: std.mem.Allocator, _: Configuration, deps: Dependencies) !*Handshake {
        const self = try allocator.create(Handshake);
        try deps.handshake.on(self, onHandshake);
        return self;
    }

    fn onHandshake(_: *Handshake, packet: []const u8) !sessions.protocol.Handshake {
        return Custom.handshake(packet);
    }
};

pub const Custom = struct {
    pub const RegistryProvider = CustomRegistry;
    const Registries = java.Registries(struct {
        pub const protocol_number = 9001;
        pub const minecraft_name = "1.21.8";
        pub const Protocol = wire;
        pub const Registry = registry;
        pub const registry_snapshot = @embedFile("wire_snapshot");
    });
    pub const Protocol = wire;
    pub const Registry = registry;
    const Chunk = java.ChunkCodec(game_data, Protocol, Registry);
    pub const writeChunk = Chunk.write;
    pub const protocol_number = 9001;
    pub const minecraft_name: ?[]const u8 = null;
    pub const Connection = java.Connection;

    pub const Bootstrap = struct {
        pub fn frame(bytes: []const u8, maximum: usize) !sessions.protocol.Frame {
            if (bytes.len >= 2 and std.mem.eql(u8, bytes[0..2], "LR")) {
                const parsed = try Crypt.Wire.frame(bytes[2..], maximum);
                return .{ .body = parsed.body, .length = parsed.length + 2 };
            }
            return java.Wire.frame(bytes, maximum);
        }
        pub const control = java.Bootstrap.control;
    };

    fn handshake(bytes: []const u8) !sessions.protocol.Handshake {
        const header = try wire.handshaking.toServer.readHeader(bytes);
        if (header.id != wire.handshaking.toServer.packetId(.set_protocol)) return error.BadHandshake;
        const a = try wire.handshaking.toServer.readBody(.set_protocol, header);
        const version, const b = try a.protocolVersion();
        const host, const c = try b.serverHost();
        _, const d = try c.serverPort();
        const intent, const done = try d.nextState();
        try done.finish();
        if (host.len > 255) return error.BadHandshake;
        if (version != 772 and version != 9002) return error.UnsupportedProtocol;
        return .{ .protocol = if (version == 9002) 9002 else protocol_number, .intent = switch (intent) {
            1 => .status,
            2 => .login,
            else => return error.BadHandshake,
        } };
    }
};

pub const Crypt = struct {
    pub const RegistryProvider = CryptRegistry;
    pub const protocol_number = 9002;
    pub const minecraft_name: ?[]const u8 = null;
    pub const Protocol = Custom.Protocol;
    pub const Registry = Custom.Registry;
    pub const writeChunk = Custom.writeChunk;

    pub const Wire = struct {
        pub const Workspace = java.Wire.Workspace;
        pub const always_copy = true;
        pub const frame_bound: sessions.protocol.Protocol.FrameBound = .{ .expansion_per_mille = 0, .overhead = 2 };

        pub fn frame(bytes: []const u8, maximum: usize) !sessions.protocol.Frame {
            if (bytes.len < 2) return error.Incomplete;
            const length = std.mem.readInt(u16, bytes[0..2], .big);
            if (length == 0 or length > maximum) return error.Malformed;
            if (bytes.len < 2 + length) return error.Incomplete;
            return .{ .body = bytes[2 .. 2 + length], .length = 2 + length };
        }

        pub fn shared(_: *Workspace, storage: []u8, length: usize, _: ?usize, destination: []u8) ![]const u8 {
            if (length > std.math.maxInt(u16) or destination.len < length + 2) return error.BufferTooSmall;
            std.mem.writeInt(u16, destination[0..2], @intCast(length), .big);
            @memcpy(destination[2..][0..length], storage[sessions.shared_headroom..][0..length]);
            return destination[0 .. length + 2];
        }
    };

    pub const Connection = struct {
        pub const Wire = Crypt.Wire;
        pub const resume_format = std.hash.Wyhash.hash(0, "example:fixed-frame-xor:1");

        base: Custom.Connection,

        pub fn init(intent: sessions.protocol.Handshake.Intent) Connection {
            return .{ .base = Custom.Connection.init(intent) };
        }

        pub fn save(self: *const Connection, bytes: []u8) ![]const u8 {
            return self.base.save(bytes);
        }

        pub fn restore(bytes: []const u8) !Connection {
            return .{ .base = try Custom.Connection.restore(bytes) };
        }

        pub fn advance(self: *Connection, comptime Observer: type, event: sessions.protocol.Event, context: sessions.protocol.Context(Observer)) !?[]const u8 {
            return self.base.advance(Observer, event, context);
        }

        pub fn compressed(_: *const Connection) bool {
            return false;
        }

        pub fn isEncrypted(_: *const Connection) bool {
            return true;
        }

        pub fn receive(_: *Connection, bytes: []u8) void {
            for (bytes) |*byte| byte.* ^= 0x5a;
        }

        pub fn send(self: *Connection, bytes: []u8) void {
            self.receive(bytes);
        }

        pub fn clear(self: *Connection) void {
            self.base.clear();
        }

        pub fn frame(_: *const Connection, bytes: []const u8, maximum: usize) !sessions.protocol.Frame {
            return Crypt.Wire.frame(bytes, maximum);
        }

        pub fn decode(_: *Connection, bytes: []const u8, _: []u8, _: *Crypt.Wire.Workspace, _: ?usize) ![]const u8 {
            return bytes;
        }

        pub fn frameControl(self: *Connection, packet: []const u8, _: []u8, output: []u8, _: *Crypt.Wire.Workspace, _: ?usize) ![]const u8 {
            if (packet.len > std.math.maxInt(u16) or output.len < packet.len + 2) return error.BufferTooSmall;
            std.mem.writeInt(u16, output[0..2], @intCast(packet.len), .big);
            @memcpy(output[2..][0..packet.len], packet);
            self.send(output[0 .. packet.len + 2]);
            return output[0 .. packet.len + 2];
        }

        pub fn playBorrowed(_: *const Connection) bool {
            return false;
        }
    };
};

const CustomRegistry = struct {
    pub const PreparedRegistries = Custom.Registries.PreparedRegistries;

    pub fn init(allocator: std.mem.Allocator) !PreparedRegistries {
        const snapshot = try Custom.Registries.snapshot(allocator);
        defer snapshot.deinit(allocator);
        for (snapshot.registries) |table| {
            if (table.synchronized) std.mem.reverse(Custom.Registries.Builder.RegistryEntry, @constCast(table.entries));
            if (!std.mem.eql(u8, table.id, "minecraft:dimension_type")) continue;
            const entries = @constCast(table.entries);
            for (entries) |*entry| {
                if (std.mem.eql(u8, entry.id, "minecraft:overworld")) entry.id = "example:bright";
            }
        }
        return Custom.Registries.Builder.build(allocator, Custom.protocol_number, snapshot);
    }
};

const CryptRegistry = struct {
    pub const PreparedRegistries = CustomRegistry.PreparedRegistries;

    pub fn init(allocator: std.mem.Allocator) !PreparedRegistries {
        var prepared = try CustomRegistry.init(allocator);
        prepared.protocol_number = Crypt.protocol_number;
        return prepared;
    }
};
