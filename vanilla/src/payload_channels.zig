const std = @import("std");
const sessions = @import("sessions");
const protocols = @import("protocols");
const minecraft_packets = @import("minecraft_packets");
const wire_1_21_5 = @import("wire_1_21_5");
const Input = @import("input.zig").Input;

pub const Session = struct {
    pub const id = "minecraft:session_payload_channels";
    pub const Configuration = struct { subscriptions: usize = 64 };
    pub const Dependencies = struct { input: *protocols.Input };
    pub const SessionConfigurationState = struct {};
    pub const SessionState = struct { configuration: SessionConfigurationState = .{} };

    const Subscription = struct {
        channel: []const u8,
        context: *anyopaque,
        call: *const fn (*anyopaque, sessions.InputScope, []const u8, []u8) anyerror!sessions.ConfigurationInputEffect,
    };

    subscriptions: []Subscription,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*Session {
        if (configuration.subscriptions == 0 or configuration.subscriptions > 4096) return error.InvalidConfiguration;

        const self = try allocator.create(Session);
        self.* = .{ .subscriptions = try allocator.alloc(Subscription, configuration.subscriptions) };
        try deps.input.configuration.on(.custom_payload, self, onPacket);
        return self;
    }

    pub fn on(self: *Session, comptime channel: []const u8, context: anytype, comptime handler: anytype) !void {
        if (comptime !validChannel(channel)) @compileError("invalid payload channel");
        if (self.count == self.subscriptions.len) return error.PayloadSubscriptionCapacity;

        self.subscriptions[self.count] = .{
            .channel = channel,
            .context = context,
            .call = struct {
                fn call(raw: *anyopaque, scope: sessions.InputScope, bytes: []const u8, output: []u8) anyerror!sessions.ConfigurationInputEffect {
                    const typed: @TypeOf(context) = @ptrCast(@alignCast(raw));
                    return handler(typed, scope, bytes, output);
                }
            }.call,
        };
        self.count += 1;
    }

    pub fn write(_: *Session, protocol: i32, output: []u8, channel: []const u8, bytes: []const u8) ![]u8 {
        if (!validChannel(channel)) return error.InvalidPayloadChannel;
        return sessions.packet_api.encodeFor(protocols.implementations, writeConfiguration, protocol, output, .{ channel, bytes });
    }

    fn onPacket(self: *Session, scope: sessions.InputScope, _: *SessionConfigurationState, packet: wire_1_21_5.configuration.toServer.packet_custom_payload.Reader, output: []u8) !sessions.ConfigurationInputEffect {
        const channel, const rest = try packet.channel();
        const bytes, const done = try rest.data();
        try done.finish();
        if (!validChannel(channel)) return error.InvalidPacket;

        var result: sessions.ConfigurationInputEffect = .none;
        for (self.subscriptions[0..self.count]) |subscription| {
            if (!std.mem.eql(u8, subscription.channel, channel)) continue;
            const effect = try subscription.call(subscription.context, scope, bytes, output);
            if (effect == .none) continue;
            if (result != .none) return error.MultiplePayloadResponses;
            result = effect;
        }
        return result;
    }
};

pub const Play = struct {
    pub const id = "minecraft:play_payload_channels";
    pub const Configuration = struct { subscriptions: usize = 64 };
    pub const Dependencies = struct { input: *Input, packets: *minecraft_packets.Packets };

    const Subscription = struct {
        channel: []const u8,
        context: *anyopaque,
        call: *const fn (*anyopaque, sessions.Handle, []const u8, std.mem.Allocator) anyerror!void,
    };

    deps: Dependencies,
    subscriptions: []Subscription,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*Play {
        if (configuration.subscriptions == 0 or configuration.subscriptions > 4096) return error.InvalidConfiguration;

        const self = try allocator.create(Play);
        self.* = .{ .deps = deps, .subscriptions = try allocator.alloc(Subscription, configuration.subscriptions) };
        try deps.input.on(.custom_payload, self, onPacket);
        return self;
    }

    pub fn on(self: *Play, comptime channel: []const u8, context: anytype, comptime handler: anytype) !void {
        if (comptime !validChannel(channel)) @compileError("invalid payload channel");
        if (self.count == self.subscriptions.len) return error.PayloadSubscriptionCapacity;

        self.subscriptions[self.count] = .{
            .channel = channel,
            .context = context,
            .call = struct {
                fn call(raw: *anyopaque, handle: sessions.Handle, bytes: []const u8, temporary: std.mem.Allocator) anyerror!void {
                    const typed: @TypeOf(context) = @ptrCast(@alignCast(raw));
                    try handler(typed, handle, bytes, temporary);
                }
            }.call,
        };
        self.count += 1;
    }

    pub fn send(self: *Play, protocol: i32, recipients: []const sessions.Handle, channel: []const u8, bytes: []const u8) !void {
        if (!validChannel(channel)) return error.InvalidPayloadChannel;
        const maximum = try std.math.add(usize, try std.math.add(usize, channel.len, bytes.len), 16);
        try self.deps.packets.sendPacket(writePlay, protocol, recipients, .{ channel, bytes }, maximum);
    }

    pub fn fanout(self: *Play, recipients: []const sessions.Service.Target, channel: []const u8, bytes: []const u8, delivered: []sessions.Service.Delivery) !void {
        if (!validChannel(channel)) return error.InvalidPayloadChannel;
        const maximum = try std.math.add(usize, try std.math.add(usize, channel.len, bytes.len), 16);
        try self.deps.packets.fanout(writePlay, recipients, .{ channel, bytes }, maximum, delivered);
    }

    fn onPacket(self: *Play, handle: sessions.Handle, packet: wire_1_21_5.play.toServer.packet_custom_payload.Reader, temporary: std.mem.Allocator) !void {
        const channel, const rest = try packet.channel();
        const bytes, const done = try rest.data();
        try done.finish();
        if (!validChannel(channel)) return error.InvalidPacket;

        for (self.subscriptions[0..self.count]) |subscription| {
            if (std.mem.eql(u8, subscription.channel, channel))
                try subscription.call(subscription.context, handle, bytes, temporary);
        }
    }
};

fn validChannel(channel: []const u8) bool {
    if (channel.len < 3 or channel.len > 32767) return false;
    const separator = std.mem.indexOfScalar(u8, channel, ':') orelse return false;
    if (separator == 0 or separator + 1 == channel.len) return false;
    for (channel, 0..) |byte, index| {
        if (std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '_' or byte == '-' or byte == '.') continue;
        if (byte == ':' and index == separator) continue;
        if (byte == '/' and index > separator) continue;
        return false;
    }
    return true;
}

fn writeConfiguration(packet: wire_1_21_5.configuration.toClient.packet_custom_payload.Writer, channel: []const u8, bytes: []const u8) ![]u8 {
    return (try (try packet.channel(channel)).data(bytes)).finish();
}

fn writePlay(packet: wire_1_21_5.play.toClient.packet_custom_payload.Writer, channel: []const u8, bytes: []const u8) ![]u8 {
    return (try (try packet.channel(channel)).data(bytes)).finish();
}
