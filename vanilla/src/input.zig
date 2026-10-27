const std = @import("std");
const sessions = @import("sessions");
const protocols = @import("protocols");

pub const Input = struct {
    pub const id = "minecraft:input";
    pub const Configuration = struct {};
    pub const Dependencies = struct { sessions: *sessions.Service };

    const Handler = *const fn (*anyopaque, sessions.Handle, []const u8, std.mem.Allocator) anyerror!void;
    const Entry = struct {
        context: *anyopaque,
        vtable: *const VTable,
        const VTable = struct { call: Handler };
    };
    const Slot = struct { valid: bool = false, entry: ?Entry = null };
    const Lifecycle = struct {
        context: *anyopaque,
        vtable: *const VTable,
        const VTable = struct { call: *const fn (*anyopaque, []const sessions.Event) anyerror!void };
    };

    deps: Dependencies,
    tables: [protocols.implementations.len][]Slot,
    rejected: []u32,
    lifecycle: ?Lifecycle = null,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Input {
        const self = try allocator.create(Input);
        self.* = .{
            .deps = deps,
            .tables = undefined,
            .rejected = try allocator.alloc(u32, deps.sessions.config.connections),
        };

        @memset(self.rejected, 0);
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
        const Adapter = struct {
            const vtable: Entry.VTable = .{ .call = @This().invoke };
            fn invoke(raw: *anyopaque, handle: sessions.Handle, body: []const u8, temporary: std.mem.Allocator) anyerror!void {
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
        };
        slot.entry = .{
            .context = context,
            .vtable = &Adapter.vtable,
        };
    }

    pub fn onLifecycle(self: *Input, context: anytype, comptime handler: anytype) !void {
        if (self.lifecycle != null) return error.DuplicateLifecycleOwner;
        const Adapter = struct {
            const vtable: Lifecycle.VTable = .{ .call = @This().invoke };
            fn invoke(raw: *anyopaque, events: []const sessions.Event) anyerror!void {
                const typed: @TypeOf(context) = @ptrCast(@alignCast(raw));
                return handler(typed, events);
            }
        };
        self.lifecycle = .{ .context = context, .vtable = &Adapter.vtable };
    }

    pub fn tick(self: *Input, temporary: std.mem.Allocator) !void {
        const events = self.deps.sessions.input_events;
        defer for (events) |event| {
            if (event == .input) self.rejected[event.input.handle.index] = 0;
        };
        var cursor: usize = 0;
        while (cursor < events.len) {
            const event = events[cursor];
            cursor += 1;
            switch (event) {
                .joined, .left, .ready => {
                    const begin = cursor - 1;
                    while (cursor < events.len and events[cursor] != .input) cursor += 1;
                    if (self.lifecycle) |handler|
                        try handler.vtable.call(handler.context, events[begin..cursor]);
                },
                .input => |input| {
                    if (self.rejected[input.handle.index] == input.handle.generation) continue;
                    var incoming = input.packets;
                    packets: while (incoming.next() catch unreachable) |packet| {
                        var matched = false;

                        inline for (protocols.implementations, 0..) |Version, index| {
                            if (input.protocol == Version.protocol_number) {
                                matched = true;
                                const Packet = Version.Protocol.play.toServer;
                                const header = Packet.readHeader(packet) catch {
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
                                if (slot.entry) |entry| entry.vtable.call(entry.context, input.handle, header.body, temporary) catch |err| {
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
