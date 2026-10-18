const std = @import("std");
const sessions = @import("sessions");
const JavaWire = @import("wire.zig").Wire;
const api = sessions.protocol;
const assert = std.debug.assert;

const ResumePhase = enum(u8) {
    configuration_ready = 0,
    awaiting_start_ack = 1,
    awaiting_finish_ack = 2,
};

pub fn Connection(comptime Protocol: type) type {
    return struct {
        const Self = @This();
        pub const Wire = JavaWire;
        pub const resume_format = std.hash.Wyhash.hash(0, "minecraft_java:queued-configuration:2");
        const Phase = enum { status, plugin_login, before_ack, plugin_configuration, configuration_ack, await_attach, play, reconfiguration_ack, restart_finish_ack };

        phase: Phase,
        login_started: bool = false,
        wire: Wire = .{},

        pub fn init(intent: api.Handshake.Intent) Self {
            return .{ .phase = if (intent == .status) .status else .plugin_login };
        }

        pub fn save(self: *const Self, bytes: []u8) ![]const u8 {
            const phase: ResumePhase = switch (self.phase) {
                .before_ack => .configuration_ready,
                .reconfiguration_ack => .awaiting_start_ack,
                .restart_finish_ack => .awaiting_finish_ack,
                else => return error.InvalidResume,
            };
            if (bytes.len < 1) return error.BufferTooSmall;
            bytes[0] = @intFromEnum(phase);
            const wire = try self.wire.save(bytes[1..]);
            return bytes[0 .. 1 + wire.len];
        }

        pub fn restore(bytes: []const u8) !Self {
            if (bytes.len < 1) return error.InvalidResume;
            const phase = std.enums.fromInt(ResumePhase, bytes[0]) orelse return error.InvalidResume;
            return .{
                .phase = switch (phase) {
                    .configuration_ready => .before_ack,
                    .awaiting_start_ack => .reconfiguration_ack,
                    .awaiting_finish_ack => .restart_finish_ack,
                },
                .wire = try Wire.restore(bytes[1..]),
            };
        }

        pub fn compressed(self: *const Self) bool {
            return self.wire.compressed;
        }

        pub fn isEncrypted(self: *const Self) bool {
            return self.wire.encrypted();
        }

        pub fn receive(self: *Self, bytes: []u8) void {
            self.wire.receive(bytes);
        }

        pub fn send(self: *Self, bytes: []u8) void {
            self.wire.send(bytes);
        }

        pub fn clear(self: *Self) void {
            self.wire.clear();
        }

        pub fn frame(_: *const Self, bytes: []const u8, maximum: usize) !api.Frame {
            return Wire.frame(bytes, maximum);
        }

        pub fn decode(self: *Self, bytes: []const u8, destination: []u8, workspace: *Wire.Workspace, threshold: ?usize) ![]const u8 {
            return self.wire.decode(bytes, destination, workspace, threshold);
        }

        pub fn frameControl(self: *Self, packet: []const u8, scratch: []u8, output: []u8, workspace: *Wire.Workspace, threshold: ?usize) ![]const u8 {
            return self.wire.control(packet, scratch, output, workspace, threshold);
        }

        pub fn playBorrowed(self: *const Self) bool {
            return !self.wire.compressed;
        }

        pub fn advance(self: *Self, comptime Observer: type, event: api.Event, context: api.Context(Observer)) !?[]const u8 {
            const state = context.state;
            const output = context.output;
            const profile: api.Profile = .{
                .connection = context.connection,
                .protocol = context.protocol.number,
                .uuid = state.uuid,
                .name = state.name[0..state.name_len],
            };
            switch (event) {
                .restore => {
                    if (self.wire.compressed != (context.compression_threshold != null)) return error.InvalidResume;
                    state.phase = .negotiating;
                },
                .park => {
                    if (self.phase == .before_ack or self.phase == .reconfiguration_ack or self.phase == .restart_finish_ack) return null;
                    if (self.phase != .play and self.phase != .configuration_ack and self.phase != .await_attach) return error.InvalidResume;
                    if (self.phase == .play and try context.observer.play(profile, .park, output) != null) return error.InvalidPhaseOutput;
                    const bytes = (try Protocol.play.toClient.write(output).start_configuration()).finish();
                    self.phase = if (self.phase == .configuration_ack) .restart_finish_ack else .reconfiguration_ack;
                    state.phase = .negotiating;
                    return bytes;
                },
                .disconnect => |message| return (try context.observer.play(profile, .{ .disconnect = message }, output)) orelse error.MissingDisconnectPacket,
                .attached => {
                    assert(state.phase == .attaching);
                    if (try context.observer.play(profile, .{ .attached = context.now }, output) != null) return error.InvalidPhaseOutput;
                    self.phase = .play;
                    state.phase = .play;
                },
                .admitted => |rejection| {
                    assert(state.phase == .admitting and self.phase == .plugin_login);
                    state.phase = .negotiating;
                    return try self.runLogin(Observer, context, .{ .admitted = rejection });
                },
                .poll => {
                    switch (self.phase) {
                        .plugin_login => {
                            const step: api.PhaseEvent = if (self.login_started) .poll else .begin;
                            self.login_started = true;
                            return try self.runLogin(Observer, context, step);
                        },
                        .before_ack => {
                            self.phase = .plugin_configuration;
                            return try self.configure(Observer, context, .begin);
                        },
                        .plugin_configuration => {
                            return try self.configure(Observer, context, .poll);
                        },
                        .play => return try context.observer.play(profile, .{ .poll = context.now }, output),
                        else => {},
                    }
                },
                .packet => |bytes| {
                    if (self.phase == .status)
                        return try context.observer.status(context.protocol.number, bytes, output);
                    if (self.phase == .plugin_login) {
                        if (!self.login_started) {
                            self.login_started = true;
                            if (try self.runLogin(Observer, context, .begin) != null) return error.InvalidPhaseOutput;
                        }
                        const effect = try context.observer.sessionInput(.login, profile, context.io, context.now, bytes, output);
                        switch (effect) {
                            .none => {},
                            .send => |response| return response,
                            .name => |name| {
                                if (name.len == 0 or name.len > state.name.len or state.name_len != 0) return error.InvalidName;
                                @memcpy(state.name[0..name.len], name);
                                state.name_len = name.len;
                            },
                            .encryption => |value| {
                                defer std.crypto.secureZero(u8, value);
                                if (self.wire.encrypted() or value.len != 16) return error.InvalidEncryption;
                                self.wire.install(value[0..16].*);
                            },
                        }
                        return try self.runLogin(Observer, context, .poll);
                    }
                    if (self.phase == .configuration_ack or self.phase == .restart_finish_ack) {
                        const header = try Protocol.configuration.toServer.readHeader(bytes);
                        if (header.id == Protocol.configuration.toServer.packetId(.finish_configuration)) {
                            try (try Protocol.configuration.toServer.readBody(.finish_configuration, header)).finish();
                            if (self.phase == .restart_finish_ack) {
                                self.phase = .reconfiguration_ack;
                            } else {
                                self.phase = .await_attach;
                                state.phase = .attaching;
                            }
                            return null;
                        }
                        if (self.phase == .restart_finish_ack) return null;
                        const effect = try context.observer.sessionInput(.configuration, profile, context.io, context.now, bytes, output);
                        return switch (effect) {
                            .none => null,
                            .send => |response| response,
                        };
                    }
                    if (self.phase == .play) {
                        const effect = try context.observer.sessionInput(.play, profile, context.io, context.now, bytes, output);
                        return switch (effect) {
                            .none => null,
                            .send => |response| response,
                        };
                    }
                    if (self.phase == .reconfiguration_ack) {
                        const header = try Protocol.play.toServer.readHeader(bytes);
                        if (header.id == Protocol.play.toServer.packetId(.configuration_acknowledged)) {
                            try (try Protocol.play.toServer.readBody(.configuration_acknowledged, header)).finish();
                            self.phase = .before_ack;
                            if (context.reloading) state.phase = .parked;
                        }
                        return null;
                    }
                    return error.InvalidProtocolEvent;
                },
            }
            return null;
        }

        fn runLogin(self: *Self, comptime Observer: type, context: api.Context(Observer), event: api.PhaseEvent) !?[]const u8 {
            const step = try context.observer.login(context.connection, context.state, context.protocol.number, event, context.output);
            return switch (step) {
                .send => |bytes| bytes,
                .wait => null,
                .done => blk: {
                    if (context.state.uuid == 0) return error.Unauthenticated;
                    self.phase = .before_ack;
                    break :blk null;
                },
                .admit => blk: {
                    if (context.state.uuid == 0) return error.Unauthenticated;
                    context.state.phase = .admitting;
                    break :blk null;
                },
                .enable_compression => blk: {
                    if (context.compression_threshold == null or self.wire.compressed) return error.InvalidCompression;
                    self.wire.compressed = true;
                    break :blk null;
                },
                .reject => |bytes| blk: {
                    context.state.phase = .rejected;
                    break :blk bytes;
                },
            };
        }

        fn configure(self: *Self, comptime Observer: type, context: api.Context(Observer), event: api.PhaseEvent) !?[]const u8 {
            const step = try context.observer.configuration(context.connection, context.state, context.protocol.number, event, context.output);
            return switch (step) {
                .send => |bytes| bytes,
                .done => blk: {
                    self.phase = .configuration_ack;
                    break :blk (try Protocol.configuration.toClient.write(context.output).finish_configuration()).finish();
                },
                .reject => |bytes| blk: {
                    context.state.phase = .rejected;
                    break :blk bytes;
                },
            };
        }
    };
}
