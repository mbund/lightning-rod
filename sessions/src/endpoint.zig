const std = @import("std");
const protocol = @import("protocol.zig");

pub fn Endpoint(comptime implementations: anytype, comptime bootstrap: type, comptime Catalog: type) type {
    if (implementations.len == 0) @compileError("select at least one protocol implementation");
    const connection_types = block: {
        var types: [implementations.len]type = undefined;
        for (implementations, &types) |Implementation, *ConnectionType| ConnectionType.* = Implementation.Connection;
        break :block types;
    };
    const workspace_layout = block: {
        var types: [implementations.len]type = undefined;
        var indices: [implementations.len]usize = undefined;
        var count: usize = 0;
        for (connection_types, 0..) |ConnectionType, version_index| {
            const index = for (types[0..count], 0..) |Workspace, index| {
                if (Workspace == ConnectionType.Wire.Workspace) break index;
            } else count;
            if (index == count) {
                types[count] = ConnectionType.Wire.Workspace;
                count += 1;
            }
            indices[version_index] = index;
        }
        break :block .{ .types = types[0..count].*, .indices = indices };
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
        /// One workspace per type. Operations run sequentially on the owning session thread.
        pub const Workspaces = @Tuple(&workspace_layout.types);

        pub fn initWorkspaces(allocator: std.mem.Allocator) !Workspaces {
            var result: Workspaces = undefined;
            var initialized: usize = 0;
            errdefer inline for (workspace_layout.types, 0..) |Workspace, index| {
                if (@hasDecl(Workspace, "deinit")) {
                    if (index < initialized) result[index].deinit();
                }
            };
            inline for (workspace_layout.types, 0..) |Workspace, index| {
                result[index] = if (@hasDecl(Workspace, "init")) try Workspace.init(allocator) else .{};
                initialized += 1;
            }
            return result;
        }

        pub fn deinitWorkspaces(workspaces: *Workspaces) void {
            inline for (workspace_layout.types, 0..) |Workspace, index| {
                if (@hasDecl(Workspace, "deinit")) workspaces[index].deinit();
            }
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
                inline else => |*state, tag| state.decode(bytes, destination, &workspaces[workspace_layout.indices[@backingInt(tag)]], threshold),
            };
        }

        /// Framing settings belong to the packet, before subsequent protocol polling changes them.
        pub fn control(connection: *Connection, workspaces: *Workspaces, packet: protocol.Packet, output: []u8, threshold: ?usize) !protocol.Fragments {
            return switch (connection.*) {
                inline else => |*state, tag| state.frameControl(packet, output, &workspaces[workspace_layout.indices[@backingInt(tag)]], threshold),
            };
        }

        pub fn sharedFrame(number: i32, workspaces: *Workspaces, storage: []u8, length: usize, threshold: ?usize, destination: []u8) ![]const u8 {
            inline for (implementations, 0..) |Implementation, index| {
                if (number == Implementation.protocol_number)
                    return connection_types[index].Wire.shared(&workspaces[workspace_layout.indices[index]], storage, length, threshold, destination);
            }
            return error.UnsupportedProtocol;
        }

        pub fn preparedFrame(number: i32, workspaces: *Workspaces, storage: []u8, length: usize, decoded_length: usize, threshold: ?usize, destination: []u8) ![]const u8 {
            inline for (implementations, 0..) |Implementation, index| {
                if (number == Implementation.protocol_number) {
                    const Wire = connection_types[index].Wire;
                    if (comptime @hasDecl(Wire, "prepared")) return Wire.prepared(&workspaces[workspace_layout.indices[index]], storage, length, decoded_length, threshold, destination);
                    return error.UnsupportedEncoding;
                }
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

        pub fn encrypt(connection: *Connection, source: []const u8, destination: []u8) void {
            switch (connection.*) {
                inline else => |*state| state.encrypt(source, destination),
            }
        }

        pub const Encryption = protocol.Encryption(Connection);
        pub const maximum_encryption_batch_size = size: {
            var maximum: usize = 1;
            for (connection_types) |ConnectionType| {
                std.debug.assert(ConnectionType.Wire.encryption_batch_size > 0);
                maximum = @max(maximum, ConnectionType.Wire.encryption_batch_size);
            }
            break :size maximum;
        };

        pub fn encryptionBatchSize(number: i32) usize {
            inline for (implementations, 0..) |Implementation, index| {
                if (number == Implementation.protocol_number) return connection_types[index].Wire.encryption_batch_size;
            }
            unreachable;
        }

        pub fn encryptBatch(number: i32, source: []const u8, targets: []const Encryption) void {
            std.debug.assert(targets.len <= maximum_encryption_batch_size);
            if (targets.len == 0) return;
            inline for (implementations, 0..) |Implementation, index| {
                if (number == Implementation.protocol_number) {
                    const ConnectionType = connection_types[index];
                    var jobs: [ConnectionType.Wire.encryption_batch_size]ConnectionType.Wire.Encryption = undefined;
                    std.debug.assert(targets.len <= jobs.len);
                    for (targets, jobs[0..targets.len]) |target, *job| {
                        const state = &@field(target.connection.*, std.fmt.comptimePrint("{d}", .{Implementation.protocol_number}));
                        job.* = state.encryption(target.first, target.second);
                    }
                    ConnectionType.Wire.encryptBatch(source, jobs[0..targets.len]);
                    return;
                }
            }
            unreachable;
        }

        /// One connection's new output, encrypted in place as its send stream continues.
        pub const Stream = struct { connection: *Connection, bytes: []u8 };

        /// Encrypts each stream as `send` would alone, side by side where a protocol's cipher can,
        /// as one stream leaves the AES units waiting on each byte before.
        pub fn encryptStreams(streams: []const Stream) void {
            inline for (implementations, 0..) |Implementation, index| {
                const ConnectionType = connection_types[index];
                const tag = comptime std.fmt.comptimePrint("{d}", .{Implementation.protocol_number});
                const active = @field(std.meta.Tag(Connection), tag);
                if (comptime @hasDecl(ConnectionType.Wire, "encryptStreams")) {
                    var batch: [64]ConnectionType.Wire.Stream = undefined;
                    var count: usize = 0;
                    for (streams) |stream| {
                        if (stream.bytes.len == 0 or std.meta.activeTag(stream.connection.*) != active) continue;
                        batch[count] = @field(stream.connection.*, tag).sendStream(stream.bytes) orelse continue;
                        count += 1;
                        if (count == batch.len) {
                            ConnectionType.Wire.encryptStreams(&batch);
                            count = 0;
                        }
                    }
                    ConnectionType.Wire.encryptStreams(batch[0..count]);
                } else for (streams) |stream| {
                    if (stream.bytes.len != 0 and std.meta.activeTag(stream.connection.*) == active) @field(stream.connection.*, tag).send(stream.bytes);
                }
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
