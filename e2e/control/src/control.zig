const lightning_rod = @import("lightning_rod");
const std = @import("std");
const sessions = @import("sessions");
const vanilla = @import("vanilla");

pub const Control = struct {
    pub const id = "e2e:control";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        payloads: *vanilla.PayloadChannels.Play,
        players: *vanilla.Players,
        reload: *vanilla.Reload,
        persistence: ?*lightning_rod.storage.Store,
        checkpoint: *lightning_rod.Checkpoint,
    };
    pub const channel = "lightning_rod:e2e";
    pub const message_bytes = 4096;
    pub const Result = enum { handled, unhandled };
    const Handler = struct {
        context: *anyopaque,
        vtable: *const VTable,
        const VTable = struct { call: *const fn (*anyopaque, sessions.Handle, []const u8) anyerror!Result };
    };
    const Name = struct { bytes: [128]u8, len: u8 };
    const Fence = struct { name: Name, handle: sessions.Handle, remaining: u2 = 2, durable: ?u64 = null };

    deps: Dependencies,
    handlers: [8]Handler = undefined,
    handler_count: usize = 0,
    marks: [256]Name = undefined,
    mark_count: usize = 0,
    fences: [64]Fence = undefined,
    fence_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Control {
        const self = try allocator.create(Control);
        self.* = .{ .deps = deps };
        try deps.payloads.on(channel, self, receive);
        return self;
    }

    pub fn on(self: *Control, context: anytype, comptime handler: anytype) void {
        std.debug.assert(self.handler_count < self.handlers.len);
        const Adapter = struct {
            const vtable: Handler.VTable = .{ .call = @This().invoke };
            fn invoke(raw: *anyopaque, handle: sessions.Handle, message: []const u8) !Result {
                const typed: @TypeOf(context) = @ptrCast(@alignCast(raw));
                return handler(typed, handle, message);
            }
        };
        self.handlers[self.handler_count] = .{
            .context = context,
            .vtable = &Adapter.vtable,
        };
        self.handler_count += 1;
    }

    fn receive(self: *Control, handle: sessions.Handle, message: []const u8, _: std.mem.Allocator) !void {
        if (message.len == 0 or message.len > message_bytes or !std.unicode.utf8ValidateSlice(message)) return error.InvalidFixtureMessage;
        if (std.mem.eql(u8, message, "reload")) {
            try self.deps.reload.stage("e2e");
        } else if (std.mem.eql(u8, message, "reload_status")) {
            const request = self.deps.reload.latest() orelse return error.ReloadUnavailable;
            const result = request.result orelse return error.ReloadNotCompleted;
            var buffer: [64]u8 = undefined;
            try self.send(handle, try std.fmt.bufPrint(&buffer, "reload {s}", .{@tagName(result)}));
        } else if (std.mem.eql(u8, message, "sync")) {
            var buffer: [133]u8 = undefined;
            for (self.marks[0..self.mark_count]) |mark|
                try self.send(handle, try std.fmt.bufPrint(&buffer, "mark {s}", .{mark.bytes[0..mark.len]}));
        } else if (std.mem.startsWith(u8, message, "mark ")) {
            const name = message[5..];
            if (name.len == 0 or name.len > 128) return error.InvalidFixtureMarker;
            for (self.marks[0..self.mark_count]) |mark|
                if (std.mem.eql(u8, name, mark.bytes[0..mark.len])) return;
            if (self.mark_count == self.marks.len) return error.FixtureMarkerCapacity;
            const mark = &self.marks[self.mark_count];
            mark.len = @intCast(name.len);
            @memcpy(mark.bytes[0..mark.len], name);
            self.mark_count += 1;
            try self.broadcast(message);
        } else if (std.mem.startsWith(u8, message, "broadcast ")) {
            if (message.len == 10) return error.InvalidFixtureMessage;
            try self.broadcast(message[10..]);
        } else if (std.mem.startsWith(u8, message, "fence ") or std.mem.startsWith(u8, message, "durable ")) {
            const durable = std.mem.startsWith(u8, message, "durable ");
            const name = message[if (durable) @as(usize, 8) else 6..];
            if (name.len == 0 or name.len > 128) return error.InvalidFixtureFence;
            if (self.fence_count == self.fences.len) return error.FixtureFenceCapacity;
            const fence = &self.fences[self.fence_count];
            fence.* = .{ .name = .{ .bytes = undefined, .len = @intCast(name.len) }, .handle = handle };
            if (durable) {
                const persistence = self.deps.persistence orelse return error.DurabilityUnavailable;
                fence.durable = try std.math.add(u64, persistence.lastTick(), 1);
                self.deps.checkpoint.request();
            }
            @memcpy(fence.name.bytes[0..fence.name.len], name);
            self.fence_count += 1;
        } else {
            var handled = false;
            for (self.handlers[0..self.handler_count]) |handler| {
                const result = try handler.vtable.call(handler.context, handle, message);
                handled = handled or result == .handled;
            }
            if (!handled) return error.UnhandledFixtureMessage;
        }
    }

    pub fn tick(self: *Control) !void {
        var pending: usize = 0;
        for (self.fences[0..self.fence_count]) |*fence| {
            const player = self.deps.players.records[fence.handle.index];
            if (!std.meta.eql(player.handle, fence.handle)) continue;
            fence.remaining -|= 1;
            // Input precedes plugin ticks. Waiting for the following tick covers every plugin,
            // regardless of where this control plugin appears in dependency order.
            if (fence.remaining == 0 and player.stage == .ready and (fence.durable == null or self.deps.persistence.?.durableTick() >= fence.durable.?)) {
                var buffer: [134]u8 = undefined;
                try self.send(fence.handle, try std.fmt.bufPrint(&buffer, "fence {s}", .{fence.name.bytes[0..fence.name.len]}));
            } else {
                self.fences[pending] = fence.*;
                pending += 1;
            }
        }
        self.fence_count = pending;
    }

    pub fn broadcast(self: *Control, message: []const u8) !void {
        for (self.deps.players.records) |player| {
            const handle = player.handle orelse continue;
            if (player.stage != .ready) continue;
            try self.send(handle, message);
        }
    }

    pub fn send(self: *Control, handle: sessions.Handle, message: []const u8) !void {
        std.debug.assert(message.len > 0 and message.len <= message_bytes);
        std.debug.assert(std.unicode.utf8ValidateSlice(message));
        const player = self.deps.players.records[handle.index];
        std.debug.assert(std.meta.eql(player.handle, handle));
        try self.deps.payloads.send(player.protocol, &.{handle}, channel, message);
    }
};

test "custom messages must be claimed and handler errors must propagate" {
    const Probe = struct {
        calls: usize = 0,
        result: Control.Result = .unhandled,
        fail: bool = false,

        fn message(self: *@This(), _: sessions.Handle, _: []const u8) !Control.Result {
            self.calls += 1;
            if (self.fail) return error.InvalidProbeState;
            return self.result;
        }
    };
    var control: Control = .{ .deps = undefined };
    const handle: sessions.Handle = .{ .index = 0, .generation = 1 };
    try std.testing.expectError(error.UnhandledFixtureMessage, control.receive(handle, "unknown", std.testing.allocator));
    var first: Probe = .{};
    control.on(&first, Probe.message);
    try std.testing.expectError(error.UnhandledFixtureMessage, control.receive(handle, "unknown", std.testing.allocator));
    var second: Probe = .{ .result = .handled };
    control.on(&second, Probe.message);
    try control.receive(handle, "claimed", std.testing.allocator);
    try std.testing.expectEqual(2, first.calls);
    try std.testing.expectEqual(1, second.calls);
    first.result = .handled;
    second.result = .unhandled;
    try control.receive(handle, "claimed", std.testing.allocator);
    second.fail = true;
    try std.testing.expectError(error.InvalidProbeState, control.receive(handle, "claimed", std.testing.allocator));
}
