const std = @import("std");
const protocol = @import("protocol.zig");
const network = @import("networking");
const packet_api = @import("packet_api.zig");

pub const Phase = enum { login, configuration, play };

pub const HandshakeInput = struct {
    const Self = @This();
    const Handler = *const fn (*anyopaque, []const u8) anyerror!protocol.Handshake;

    context: ?*anyopaque = null,
    call: ?Handler = null,
    sealed: bool = false,

    pub fn on(self: *Self, context: anytype, comptime handler: anytype) !void {
        if (self.sealed) return error.InputRegistrationClosed;
        if (self.call != null) return error.DuplicateHandshakeOwner;
        self.context = context;
        self.call = struct {
            fn call(raw: *anyopaque, packet: []const u8) anyerror!protocol.Handshake {
                const typed: @TypeOf(context) = @ptrCast(@alignCast(raw));
                return handler(typed, packet);
            }
        }.call;
    }

    pub fn dispatch(self: *const Self, packet: []const u8) !protocol.Handshake {
        const call = self.call orelse return error.MissingHandshakeHandler;
        return call(self.context.?, packet);
    }
};

pub const LoginEffect = union(enum) {
    none,
    send: []const u8,
    name: []const u8,
    encryption: []u8,
};

pub const ConfigurationEffect = union(enum) {
    none,
    send: []const u8,
};

pub const PlayEffect = union(enum) {
    none,
    send: []const u8,
    reconfigure,
};

pub fn Effect(comptime phase: Phase) type {
    return switch (phase) {
        .login => LoginEffect,
        .configuration => ConfigurationEffect,
        .play => PlayEffect,
    };
}

pub const Scope = struct {
    profile: protocol.Profile,
    io: std.Io,
    now: i96,
};

pub const Phases = struct {
    const Self = @This();
    const LoginCall = *const fn (*anyopaque, protocol.PhaseScope, *anyopaque, protocol.PhaseEvent, []u8) anyerror!protocol.LoginStep;
    const ConfigurationCall = *const fn (*anyopaque, protocol.PhaseScope, *anyopaque, protocol.PhaseEvent, []u8) anyerror!protocol.ConfigurationStep;
    const PlayCall = *const fn (*anyopaque, protocol.Profile, *anyopaque, protocol.PlayEvent, []u8) anyerror!?[]const u8;
    const ClosedCall = *const fn (*anyopaque, network.Handle, *anyopaque) void;
    const Login = struct { context: *anyopaque, call: LoginCall };
    const Configuration = struct { context: *anyopaque, call: ConfigurationCall };
    const Play = struct { context: *anyopaque, call: PlayCall };
    const Closed = struct { context: *anyopaque, call: ClosedCall };

    pub const Entry = struct {
        login: ?Login = null,
        configuration: ?Configuration = null,
        play: ?Play = null,
        closed: ?Closed = null,
    };

    entries: []Entry,
    owner: usize = 0,
    sealed: bool = false,

    pub fn init(allocator: std.mem.Allocator, count: usize) !Self {
        const entries = try allocator.alloc(Entry, count);
        @memset(entries, .{});
        return .{ .entries = entries };
    }

    pub fn onLogin(self: *Self, context: anytype, comptime handler: anytype) !void {
        if (self.sealed) return error.InputRegistrationClosed;
        const entry = &self.entries[self.owner].login;
        if (entry.* != null) return error.DuplicatePhaseOwner;
        const Plugin = @typeInfo(@TypeOf(context)).pointer.child;
        entry.* = .{ .context = context, .call = struct {
            fn call(raw: *anyopaque, scope: protocol.PhaseScope, state: *anyopaque, event: protocol.PhaseEvent, output: []u8) anyerror!protocol.LoginStep {
                const typed: @TypeOf(context) = @ptrCast(@alignCast(raw));
                const typed_state: *Plugin.SessionState = @ptrCast(@alignCast(state));
                return handler(typed, scope, &typed_state.login, event, output);
            }
        }.call };
    }

    pub fn onConfiguration(self: *Self, context: anytype, comptime handler: anytype) !void {
        if (self.sealed) return error.InputRegistrationClosed;
        const entry = &self.entries[self.owner].configuration;
        if (entry.* != null) return error.DuplicatePhaseOwner;
        const Plugin = @typeInfo(@TypeOf(context)).pointer.child;
        entry.* = .{ .context = context, .call = struct {
            fn call(raw: *anyopaque, scope: protocol.PhaseScope, state: *anyopaque, event: protocol.PhaseEvent, output: []u8) anyerror!protocol.ConfigurationStep {
                const typed: @TypeOf(context) = @ptrCast(@alignCast(raw));
                const typed_state: *Plugin.SessionState = @ptrCast(@alignCast(state));
                return handler(typed, scope, &typed_state.configuration, event, output);
            }
        }.call };
    }

    pub fn onPlay(self: *Self, context: anytype, comptime handler: anytype) !void {
        if (self.sealed) return error.InputRegistrationClosed;
        const entry = &self.entries[self.owner].play;
        if (entry.* != null) return error.DuplicatePhaseOwner;
        const Plugin = @typeInfo(@TypeOf(context)).pointer.child;
        entry.* = .{ .context = context, .call = struct {
            fn call(raw: *anyopaque, profile: protocol.Profile, state: *anyopaque, event: protocol.PlayEvent, output: []u8) anyerror!?[]const u8 {
                const typed: @TypeOf(context) = @ptrCast(@alignCast(raw));
                const typed_state: *Plugin.SessionState = @ptrCast(@alignCast(state));
                return handler(typed, profile, &typed_state.play, event, output);
            }
        }.call };
    }

    pub fn onClosed(self: *Self, context: anytype, comptime handler: anytype) !void {
        if (self.sealed) return error.InputRegistrationClosed;
        const entry = &self.entries[self.owner].closed;
        if (entry.* != null) return error.DuplicatePhaseOwner;
        const Plugin = @typeInfo(@TypeOf(context)).pointer.child;
        entry.* = .{ .context = context, .call = struct {
            fn call(raw: *anyopaque, handle: network.Handle, state: *anyopaque) void {
                const typed: @TypeOf(context) = @ptrCast(@alignCast(raw));
                const typed_state: *Plugin.SessionState = @ptrCast(@alignCast(state));
                handler(typed, handle, typed_state);
            }
        }.call };
    }
};

pub fn Input(comptime Version: type, comptime phase: Phase) type {
    const Server = switch (phase) {
        .login => Version.Protocol.login.toServer,
        .configuration => Version.Protocol.configuration.toServer,
        .play => Version.Protocol.play.toServer,
    };
    const maximum = comptime block: {
        @setEvalBranchQuota(100_000);
        var value: usize = 0;
        for (@typeInfo(Server.PacketName).@"enum".fields) |field| {
            const packet = @field(Server.PacketName, field.name);
            value = @max(value, @as(usize, @intCast(Server.packetId(packet))));
        }
        break :block value;
    };

    return struct {
        const Self = @This();
        pub const Entry = struct {
            owner: usize,
            context: *anyopaque,
            call: *const fn (*anyopaque, Scope, *anyopaque, Server.Header, []u8) anyerror!Effect(phase),
        };

        owners: [maximum + 1]?Entry = @splat(null),
        owner: usize = 0,
        sealed: bool = false,

        pub fn on(self: *Self, comptime packet: Server.PacketName, context: anytype, comptime handler: anytype) !void {
            if (self.sealed) return error.InputRegistrationClosed;
            const id: usize = @intCast(Server.packetId(packet));
            if (self.owners[id] != null) return error.DuplicatePacketOwner;
            const Plugin = @typeInfo(@TypeOf(context)).pointer.child;
            const State = @FieldType(Plugin.SessionState, @tagName(phase));
            self.owners[id] = .{
                .owner = self.owner,
                .context = context,
                .call = struct {
                    fn call(raw: *anyopaque, scope: Scope, state: *anyopaque, header: Server.Header, output: []u8) anyerror!Effect(phase) {
                        const typed: @TypeOf(context) = @ptrCast(@alignCast(raw));
                        const plugin_state: *Plugin.SessionState = @ptrCast(@alignCast(state));
                        const typed_state: *State = &@field(plugin_state.*, @tagName(phase));
                        const handlers = comptime packet_api.candidates(handler);
                        const callback = handlers[comptime packet_api.select(Version, handler)];
                        const Reader = packet_api.Cursor(callback);
                        comptime packet_api.validateReader(Reader, @tagName(phase), @tagName(packet));
                        const reader: Reader = .{ ._cursor = .{ .buffer = header.body, .rest = header.body, .protocol_number = Version.protocol_number, .layout_protocol = Version.Protocol.protocol_number } };
                        return @call(.auto, callback, .{ typed, scope, typed_state, reader, output });
                    }
                }.call,
            };
        }

        pub fn entry(self: *const Self, packet: []const u8) !?struct { Entry, Server.Header } {
            const header = try Server.readHeader(packet);
            if (header.id < 0 or @as(usize, @intCast(header.id)) >= self.owners.len)
                return null;
            const owner = self.owners[@intCast(header.id)] orelse return null;
            return .{ owner, header };
        }
    };
}

pub fn StatusInput(comptime Version: type) type {
    const Server = Version.Protocol.status.toServer;
    const maximum = comptime block: {
        var value: usize = 0;
        for (@typeInfo(Server.PacketName).@"enum".fields) |field| {
            const packet = @field(Server.PacketName, field.name);
            value = @max(value, @as(usize, @intCast(Server.packetId(packet))));
        }
        break :block value;
    };

    return struct {
        const Self = @This();
        const Handler = *const fn (*anyopaque, protocol.StatusRequest, Server.Header, []u8) anyerror!?[]const u8;
        const Entry = struct { context: *anyopaque, call: Handler };

        owners: [maximum + 1]?Entry = @splat(null),
        sealed: bool = false,

        pub fn on(self: *Self, comptime packet: Server.PacketName, context: anytype, comptime handler: anytype) !void {
            if (self.sealed) return error.InputRegistrationClosed;
            const id: usize = @intCast(Server.packetId(packet));
            if (self.owners[id] != null) return error.DuplicatePacketOwner;
            self.owners[id] = .{
                .context = context,
                .call = struct {
                    fn call(raw: *anyopaque, request: protocol.StatusRequest, header: Server.Header, output: []u8) anyerror!?[]const u8 {
                        const typed: @TypeOf(context) = @ptrCast(@alignCast(raw));
                        const handlers = comptime packet_api.candidates(handler);
                        const callback = handlers[comptime packet_api.select(Version, handler)];
                        const Reader = packet_api.Cursor(callback);
                        comptime packet_api.validateReader(Reader, "status", @tagName(packet));
                        const reader: Reader = .{ ._cursor = .{ .buffer = header.body, .rest = header.body, .protocol_number = Version.protocol_number, .layout_protocol = Version.Protocol.protocol_number } };
                        const bytes = try @call(.auto, callback, .{ typed, request, reader, output });
                        return bytes;
                    }
                }.call,
            };
        }

        pub fn dispatch(self: *Self, request: protocol.StatusRequest, packet: []const u8, output: []u8) !?[]const u8 {
            const header = try Server.readHeader(packet);
            if (header.id < 0 or @as(usize, @intCast(header.id)) >= self.owners.len)
                return error.UnexpectedStatusPacket;
            const entry = self.owners[@intCast(header.id)] orelse return error.UnexpectedStatusPacket;
            if (try entry.call(entry.context, request, header, output)) |bytes| {
                if (bytes.len == 0 or bytes.len > output.len or bytes.ptr != output.ptr)
                    return error.InvalidPhaseOutput;
                return bytes;
            }
            return null;
        }
    };
}

pub fn Inputs(comptime versions: anytype) type {
    return struct {
        const Self = @This();

        handshake: HandshakeInput = .{},
        status: Set(versions, .status),
        login: Set(versions, .login),
        configuration: Set(versions, .configuration),
        play: Set(versions, .play),

        pub fn init(self: *Self) void {
            self.handshake = .{};
            inline for (versions, 0..) |_, index| {
                self.status.tables[index] = .{};
                self.login.tables[index] = .{};
                self.configuration.tables[index] = .{};
                self.play.tables[index] = .{};
            }
        }

        pub fn seal(self: *Self) void {
            std.debug.assert(!self.handshake.sealed);
            self.handshake.sealed = true;
            inline for (versions, 0..) |_, index| {
                std.debug.assert(!self.status.tables[index].sealed);
                std.debug.assert(!self.login.tables[index].sealed);
                std.debug.assert(!self.configuration.tables[index].sealed);
                std.debug.assert(!self.play.tables[index].sealed);
                self.status.tables[index].sealed = true;
                self.login.tables[index].sealed = true;
                self.configuration.tables[index].sealed = true;
                self.play.tables[index].sealed = true;
            }
        }
    };
}

fn Set(comptime versions: anytype, comptime phase: enum { status, login, configuration, play }) type {
    const types = comptime block: {
        var values: [versions.len]type = undefined;
        for (versions, &values) |Version, *value| {
            value.* = if (phase == .status) StatusInput(Version) else Input(Version, @field(Phase, @tagName(phase)));
        }
        break :block values;
    };

    return struct {
        const Self = @This();
        tables: std.meta.Tuple(&types),

        pub fn on(self: *Self, comptime packet: anytype, context: anytype, comptime handler: anytype) !void {
            inline for (versions) |Version|
                try self.onVersion(Version, packet, context, handler);
        }

        pub fn onVersion(self: *Self, comptime Version: type, comptime packet: anytype, context: anytype, comptime handler: anytype) !void {
            const index = comptime selected: {
                for (versions, 0..) |Selected, candidate|
                    if (Selected == Version) break :selected candidate;
                @compileError("protocol version is not selected");
            };
            const Server = @field(Version.Protocol, @tagName(phase)).toServer;
            try self.tables[index].on(@field(Server.PacketName, @tagName(packet)), context, handler);
        }
    };
}
