const std = @import("std");
const sessions = @import("sessions");
const protocols = @import("protocols");

pub const Input = struct {
    pub const id = "minecraft:input";
    pub const Configuration = struct {};
    pub const Dependencies = struct { sessions: *sessions.Service };

    const Handler = *const fn (*anyopaque, sessions.Handle, []const u8, std.mem.Allocator) anyerror!void;
    const Entry = struct { context: *anyopaque, call: Handler };
    const Slot = struct { valid: bool = false, entry: ?Entry = null };
    const Lifecycle = *const fn (*anyopaque, sessions.Event) anyerror!void;

    deps: Dependencies,
    tables: [protocols.implementations.len][]Slot,
    rejected: []u32,
    lifecycle_context: ?*anyopaque = null,
    lifecycle_handler: ?Lifecycle = null,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Input {
        const self = try allocator.create(Input);
        self.* = .{
            .deps = deps,
            .tables = undefined,
            .rejected = try allocator.alloc(u32, deps.sessions.config.connections),
        };

        inline for (protocols.implementations, 0..) |Version, index| {
            const Packet = Version.Protocol.play.toServer;
            var maximum: usize = 0;
            inline for (@typeInfo(Packet.PacketName).@"enum".fields) |field|
                maximum = @max(maximum, @as(usize, @intCast(Packet.packetId(@field(Packet.PacketName, field.name)))));
            self.tables[index] = try allocator.alloc(Slot, maximum + 1);
            @memset(self.tables[index], .{});
            inline for (@typeInfo(Packet.PacketName).@"enum".fields) |field| {
                const number: usize = @intCast(Packet.packetId(@field(Packet.PacketName, field.name)));
                self.tables[index][number].valid = true;
            }
        }
        return self;
    }

    pub fn on(self: *Input, comptime packet: anytype, context: anytype, comptime handler: anytype) !void {
        inline for (protocols.implementations, 0..) |Version, index|
            try self.register(Version, index, packet, context, handler);
    }

    pub fn onVersion(self: *Input, comptime Version: type, comptime packet: anytype, context: anytype, comptime handler: anytype) !void {
        const index = comptime selected: {
            for (protocols.implementations, 0..) |Selected, candidate|
                if (Selected == Version) break :selected candidate;
            @compileError("protocol version is not selected");
        };
        return self.register(Version, index, packet, context, handler);
    }

    fn register(self: *Input, comptime Version: type, comptime index: usize, comptime packet: anytype, context: anytype, comptime handler: anytype) !void {
        const name = @tagName(packet);
        const Packet = Version.Protocol.play.toServer;
        if (!@hasField(Packet.PacketName, name))
            @compileError("packet " ++ name ++ " is absent from " ++ Version.minecraft_name);
        const number: usize = @intCast(Packet.packetId(@field(Packet.PacketName, name)));
        const slot = &self.tables[index][number];
        std.debug.assert(slot.valid);
        if (slot.entry != null) return error.DuplicatePacketOwner;
        slot.entry = .{
            .context = context,
            .call = struct {
                fn call(raw: *anyopaque, handle: sessions.Handle, body: []const u8, temporary: std.mem.Allocator) anyerror!void {
                    const typed: @TypeOf(context) = @ptrCast(@alignCast(raw));
                    const handlers = comptime sessions.packet_api.candidates(handler);
                    const callback = handlers[comptime sessions.packet_api.select(Version, handler)];
                    const Reader = sessions.packet_api.Cursor(callback);
                    comptime sessions.packet_api.validateReader(Reader, "play", name);
                    const reader: Reader = .{ ._cursor = .{ .buffer = body, .rest = body, .protocol_number = Version.protocol_number } };
                    comptime if (@typeInfo(@TypeOf(callback)).@"fn".params.len != 3 and @typeInfo(@TypeOf(callback)).@"fn".params.len != 4)
                        @compileError("packet handler takes context, handle, Reader, and optionally temporary allocator");
                    if (comptime @typeInfo(@TypeOf(callback)).@"fn".params.len == 3)
                        try @call(.auto, callback, .{ typed, handle, reader })
                    else
                        try @call(.auto, callback, .{ typed, handle, reader, temporary });
                }
            }.call,
        };
    }

    pub fn onLifecycle(self: *Input, context: anytype, comptime handler: anytype) !void {
        if (self.lifecycle_handler != null) return error.DuplicateLifecycleOwner;
        self.lifecycle_context = context;
        self.lifecycle_handler = struct {
            fn call(raw: *anyopaque, event: sessions.Event) anyerror!void {
                const typed: @TypeOf(context) = @ptrCast(@alignCast(raw));
                try @call(.auto, handler, .{ typed, event });
            }
        }.call;
    }

    pub fn tick(self: *Input, temporary: std.mem.Allocator) !void {
        @memset(self.rejected, 0);
        for (self.deps.sessions.input_events) |event| {
            switch (event) {
                .joined, .left => {
                    if (self.lifecycle_handler) |handler|
                        try handler(self.lifecycle_context.?, event);
                },
                .input => |input| {
                    if (self.rejected[input.handle.index] == input.handle.generation) continue;
                    var bytes = input.bytes;
                    packets: while (bytes.len != 0) {
                        const frame = sessions.frame(bytes, self.deps.sessions.config.buffer_bytes) catch unreachable;
                        bytes = bytes[frame.length..];
                        var matched = false;

                        inline for (protocols.implementations, 0..) |Version, index| {
                            if (input.protocol == Version.protocol_number) {
                                matched = true;
                                const Packet = Version.Protocol.play.toServer;
                                const header = Packet.readHeader(frame.body) catch {
                                    self.reject(input.handle, "Header");
                                    break :packets;
                                };
                                if (header.id < 0 or @as(usize, @intCast(header.id)) >= self.tables[index].len) {
                                    self.reject(input.handle, "PacketId");
                                    break :packets;
                                }
                                const slot = self.tables[index][@intCast(header.id)];
                                if (!slot.valid) {
                                    self.reject(input.handle, "UnknownPacket");
                                    break :packets;
                                }
                                if (slot.entry) |entry| entry.call(entry.context, input.handle, header.body, temporary) catch |err| {
                                    if (err != error.InvalidPacket) return err;
                                    self.reject(input.handle, "InvalidPacket");
                                    break :packets;
                                };
                            }
                        }
                        if (!matched) return error.UnsupportedProtocol;
                    }
                },
            }
        }
    }

    fn reject(self: *Input, handle: sessions.Handle, reason: []const u8) void {
        std.log.warn("event=client_input_rejected connection={d}:{d} reason={s}", .{ handle.index, handle.generation, reason });
        self.rejected[handle.index] = handle.generation;
        self.deps.sessions.disconnect(handle);
    }
};
