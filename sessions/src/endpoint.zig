const std = @import("std");
const protocol = @import("protocol.zig");

pub fn Endpoint(comptime implementations: anytype, comptime bootstrap: type, comptime Catalog: type) type {
    if (implementations.len == 0) @compileError("select at least one protocol implementation");
    const connection_types = block: {
        var types: [implementations.len]type = undefined;
        for (implementations, &types) |Implementation, *ConnectionType| ConnectionType.* = Implementation.Connection;
        break :block types;
    };
    return struct {
        pub const Bootstrap = bootstrap;
        pub const versions = implementations;
        pub const Protocols = Catalog;
        pub const resume_manifest = block: {
            var bytes: [implementations.len * 12]u8 = undefined;
            for (implementations, 0..) |Implementation, index| {
                std.mem.writeInt(i32, bytes[index * 12 ..][0..4], Implementation.protocol_number, .little);
                std.mem.writeInt(u64, bytes[index * 12 + 4 ..][0..8], connection_types[index].resume_format, .little);
            }
            break :block bytes;
        };
        pub const Connection = block: {
            var names: [implementations.len][:0]const u8 = undefined;
            var types: [implementations.len]type = undefined;
            var tags: [implementations.len]u16 = undefined;
            for (implementations, 0..) |Implementation, index| {
                const name = std.fmt.comptimePrint("{d}", .{Implementation.protocol_number});
                names[index] = name;
                types[index] = connection_types[index];
                tags[index] = index;
            }
            const Tag = @Enum(u16, .exhaustive, &names, &tags);
            break :block @Union(.auto, Tag, &names, &types, &@splat(.{}));
        };
        pub const Workspaces = block: {
            var types: [implementations.len]type = undefined;
            for (connection_types, &types) |ConnectionType, *workspace| workspace.* = ConnectionType.Wire.Workspace;
            break :block std.meta.Tuple(&types);
        };

        pub fn initWorkspaces() Workspaces {
            var result: Workspaces = undefined;
            inline for (implementations, 0..) |_, index| result[index] = .{};
            return result;
        }

        pub fn frame(connection: ?*const Connection, bytes: []const u8, maximum: usize) !protocol.Frame {
            const result = if (connection) |selected| switch (selected.*) {
                inline else => |*state| state.frame(bytes, maximum),
            } else bootstrap.frame(bytes, maximum);
            const parsed = try result;
            if (parsed.length < parsed.body.len or parsed.length > bytes.len) return error.Malformed;
            return parsed;
        }

        pub fn decode(connection: *Connection, workspaces: *Workspaces, bytes: []const u8, destination: []u8, threshold: ?usize) ![]const u8 {
            return switch (connection.*) {
                inline else => |*state, tag| state.decode(bytes, destination, &workspaces[@intFromEnum(tag)], threshold),
            };
        }

        pub fn control(connection: *Connection, workspaces: *Workspaces, packet: []const u8, scratch: []u8, output: []u8, threshold: ?usize) ![]const u8 {
            return switch (connection.*) {
                inline else => |*state, tag| state.frameControl(packet, scratch, output, &workspaces[@intFromEnum(tag)], threshold),
            };
        }

        pub fn sharedFrame(number: i32, workspaces: *Workspaces, storage: []u8, length: usize, threshold: ?usize, destination: []u8) ![]const u8 {
            inline for (implementations, 0..) |Implementation, index| {
                if (number == Implementation.protocol_number)
                    return connection_types[index].Wire.shared(&workspaces[index], storage, length, threshold, destination);
            }
            return error.UnsupportedProtocol;
        }

        pub fn playBorrowed(connection: *const Connection) bool {
            return switch (connection.*) {
                inline else => |*state| state.playBorrowed(),
            };
        }

        pub fn needsDecoded(compression_threshold: ?usize) bool {
            if (compression_threshold != null) return true;
            inline for (connection_types) |ConnectionType| if (ConnectionType.Wire.always_copy) return true;
            return false;
        }

        pub fn init(number: i32, intent: protocol.Handshake.Intent) !Connection {
            inline for (implementations, 0..) |Implementation, index| {
                if (number == Implementation.protocol_number)
                    return @unionInit(Connection, std.fmt.comptimePrint("{d}", .{Implementation.protocol_number}), connection_types[index].init(intent));
            }
            return error.UnsupportedProtocol;
        }

        pub fn advance(comptime Observer: type, connection: *Connection, event: protocol.Event, context: protocol.Context(Observer)) !?[]const u8 {
            return switch (connection.*) {
                inline else => |*state| state.advance(Observer, event, context),
            };
        }

        pub fn resumeFormat(connection: *const Connection) u64 {
            return switch (connection.*) {
                inline else => |*state| @TypeOf(state.*).resume_format,
            };
        }

        pub fn save(connection: *const Connection, bytes: []u8) ![]const u8 {
            return switch (connection.*) {
                inline else => |*state| state.save(bytes),
            };
        }

        pub fn compressed(connection: *const Connection) bool {
            return switch (connection.*) {
                inline else => |*state| state.compressed(),
            };
        }

        pub fn encrypted(connection: *const Connection) bool {
            return switch (connection.*) {
                inline else => |*state| state.isEncrypted(),
            };
        }

        pub fn receive(connection: *Connection, bytes: []u8) void {
            switch (connection.*) {
                inline else => |*state| state.receive(bytes),
            }
        }

        pub fn send(connection: *Connection, bytes: []u8) void {
            switch (connection.*) {
                inline else => |*state| state.send(bytes),
            }
        }

        pub fn clear(connection: *Connection) void {
            switch (connection.*) {
                inline else => |*state| state.clear(),
            }
        }

        pub fn restore(number: i32, format: u64, bytes: []const u8) !Connection {
            inline for (implementations, 0..) |Implementation, index| {
                if (number == Implementation.protocol_number) {
                    if (format != connection_types[index].resume_format) return error.IncompatibleResume;
                    return @unionInit(Connection, std.fmt.comptimePrint("{d}", .{Implementation.protocol_number}), try connection_types[index].restore(bytes));
                }
            }
            return error.UnsupportedProtocol;
        }
    };
}
