const lightning_rod = @import("lightning_rod");
const std = @import("std");
const sessions = @import("sessions");
const vanilla = @import("vanilla");
const protocols = @import("protocols");

pub const Control = struct {
    pub const id = "e2e:control";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        payloads: *vanilla.PayloadChannels.Play,
        players: *vanilla.Players,
        reload: *vanilla.Reload,
        persistence: *lightning_rod.storage.Store,
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
    const Cursor = struct { generation: u32 = 0, next: usize = 0 };

    deps: Dependencies,
    handlers: [8]Handler = undefined,
    handler_count: usize = 0,
    marks: [256]Name = undefined,
    mark_count: usize = 0,
    cursors: []Cursor,
    targets: []sessions.Service.Target,
    delivered: []sessions.Service.Delivery,
    fences: [64]Fence = undefined,
    fence_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Control {
        const self = try allocator.create(Control);
        self.* = .{
            .deps = deps,
            .cursors = try allocator.alloc(Cursor, deps.players.records.len),
            .targets = try allocator.alloc(sessions.Service.Target, deps.players.records.len),
            .delivered = try allocator.alloc(sessions.Service.Delivery, deps.players.records.len),
        };
        @memset(self.cursors, .{});
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
            self.cursors[handle.index] = .{ .generation = handle.generation };
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
                fence.durable = try std.math.add(u64, self.deps.persistence.lastTick(), 1);
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
        for (self.deps.players.records, 0..) |player, index| {
            const handle = player.handle orelse continue;
            if (self.cursors[index].generation != handle.generation)
                self.cursors[index] = .{ .generation = handle.generation };
        }
        for (self.marks[0..self.mark_count], 0..) |mark, index| {
            var count: usize = 0;
            for (self.deps.players.records) |player| {
                const handle = player.handle orelse continue;
                if (player.stage != .ready or self.cursors[handle.index].next != index) continue;
                self.targets[count] = .{ .handle = handle, .protocol = player.protocol };
                count += 1;
            }
            if (count == 0) continue;
            var buffer: [133]u8 = undefined;
            try self.fanout(self.targets[0..count], try std.fmt.bufPrint(&buffer, "mark {s}", .{mark.bytes[0..mark.len]}));
            for (self.targets[0..count], self.delivered[0..count]) |target, delivered| {
                if (delivered == .queued) self.cursors[target.handle.index].next += 1;
            }
        }
        var pending: usize = 0;
        for (self.fences[0..self.fence_count]) |*fence| {
            const player = self.deps.players.records[fence.handle.index];
            if (!std.meta.eql(player.handle, fence.handle)) continue;
            fence.remaining -|= 1;
            // Input precedes plugin ticks. Waiting for the following tick covers every plugin,
            // regardless of where this control plugin appears in dependency order.
            if (fence.remaining == 0 and player.stage == .ready and (fence.durable == null or self.deps.persistence.durableTick() >= fence.durable.?)) {
                var buffer: [134]u8 = undefined;
                const target: sessions.Service.Target = .{ .handle = fence.handle, .protocol = player.protocol };
                try self.fanout(&.{target}, try std.fmt.bufPrint(&buffer, "fence {s}", .{fence.name.bytes[0..fence.name.len]}));
                if (self.delivered[0] != .backpressured) continue;
            }
            self.fences[pending] = fence.*;
            pending += 1;
        }
        self.fence_count = pending;
    }

    pub fn broadcast(self: *Control, message: []const u8) !void {
        var count: usize = 0;
        for (self.deps.players.records) |player| {
            const handle = player.handle orelse continue;
            if (player.stage != .ready) continue;
            self.targets[count] = .{ .handle = handle, .protocol = player.protocol };
            count += 1;
        }
        if (count == 0) return;
        try self.fanout(self.targets[0..count], message);
        for (self.delivered[0..count]) |delivered|
            if (delivered == .backpressured) return error.Backpressured;
    }

    pub fn send(self: *Control, handle: sessions.Handle, message: []const u8) !void {
        const player = self.deps.players.records[handle.index];
        std.debug.assert(std.meta.eql(player.handle, handle));
        try self.fanout(&.{.{ .handle = handle, .protocol = player.protocol }}, message);
        if (self.delivered[0] == .backpressured) return error.Backpressured;
    }

    fn fanout(self: *Control, targets: []const sessions.Service.Target, message: []const u8) !void {
        std.debug.assert(message.len > 0 and message.len <= message_bytes);
        std.debug.assert(std.unicode.utf8ValidateSlice(message));
        try self.deps.payloads.fanout(targets, channel, message, self.delivered[0..targets.len]);
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
    var control: Control = .{ .deps = undefined, .cursors = &.{}, .targets = &.{}, .delivered = &.{} };
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

test "markers catch up after readiness backpressure and connection reuse" {
    const protocol: i32 = protocols.implementations[0].protocol_number;
    const service = try sessions.Service.init(std.testing.allocator, std.testing.io, undefined, .{
        .connections = 2,
        .pages = 64,
        .page_bytes = 512,
        .buffer_bytes = 8192,
        .protocols = &.{.{ .number = protocol }},
    });
    defer {
        while (service.output.takeReady()) |packet| {
            _ = service.preparing.fetchSub(1, .release);
            std.debug.assert(service.output.releaseReady(packet.page, packet.generation));
        }
        service.deinit();
    }
    const alice: sessions.Handle = .{ .index = 0, .generation = 1 };
    const bob: sessions.Handle = .{ .index = 1, .generation = 1 };
    for ([_]sessions.Handle{ alice, bob }) |handle|
        service.credit[handle.index].store((@as(u64, handle.generation) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);

    var records: [2]vanilla.Players.Player = .{
        .{ .handle = alice, .protocol = protocol, .stage = .ready },
        .{ .handle = bob, .protocol = protocol, .stage = .awaiting_teleport },
    };
    var players: vanilla.Players = .{ .deps = undefined, .config = .{}, .spawn_world = 0, .records = &records, .dig_handlers = &.{} };
    var packets: vanilla.Packets = .{ .deps = .{ .sessions = service } };
    var payloads: vanilla.PayloadChannels.Play = .{ .deps = .{ .input = undefined, .packets = &packets }, .subscriptions = &.{} };
    var cursors: [2]Control.Cursor = @splat(.{});
    var targets: [2]sessions.Service.Target = undefined;
    var delivered: [2]sessions.Service.Delivery = undefined;
    var control: Control = .{ .deps = .{ .players = &players, .payloads = &payloads, .reload = undefined, .persistence = undefined, .checkpoint = undefined }, .cursors = &cursors, .targets = &targets, .delivered = &delivered };

    try control.receive(bob, "sync", std.testing.allocator);
    try control.receive(alice, "mark alice.ready", std.testing.allocator);
    try control.tick();
    try std.testing.expectEqual(@as(usize, 1), control.cursors[0].next);
    try std.testing.expectEqual(@as(usize, 0), control.cursors[1].next);
    records[1].stage = .ready;
    try control.tick();
    try std.testing.expectEqual(@as(usize, 1), control.cursors[1].next);
    const replay = service.output.takeReady().?;
    try std.testing.expect(std.mem.indexOf(u8, replay.bytes, "mark alice.ready") != null);
    try std.testing.expect(replay.recipients.eqlSlice(&.{alice}));
    _ = service.preparing.fetchSub(1, .release);
    try std.testing.expect(service.output.releaseReady(replay.page, replay.generation));
    const catchup = service.output.takeReady().?;
    try std.testing.expect(std.mem.indexOf(u8, catchup.bytes, "mark alice.ready") != null);
    try std.testing.expect(catchup.recipients.eqlSlice(&.{bob}));
    _ = service.preparing.fetchSub(1, .release);
    try std.testing.expect(service.output.releaseReady(catchup.page, catchup.generation));

    service.credit[1].store((@as(u64, bob.generation) << 32) | sessions.Service.active, .release);
    try control.receive(alice, "mark alice.observed", std.testing.allocator);
    try control.tick();
    try std.testing.expectEqual(@as(usize, 2), control.cursors[0].next);
    try std.testing.expectEqual(@as(usize, 1), control.cursors[1].next);
    service.credit[1].store((@as(u64, bob.generation) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
    try control.tick();
    try std.testing.expectEqual(@as(usize, 2), control.cursors[1].next);

    const reconnected: sessions.Handle = .{ .index = 1, .generation = 2 };
    records[1].handle = reconnected;
    service.credit[1].store((@as(u64, reconnected.generation) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
    try control.tick();
    try std.testing.expectEqual(reconnected.generation, control.cursors[1].generation);
    try std.testing.expectEqual(@as(usize, 2), control.cursors[1].next);

    service.credit[1].store(0, .release);
    try control.broadcast("completed");
    try std.testing.expectEqual(sessions.Service.Delivery.queued, control.delivered[0]);
    try std.testing.expectEqual(sessions.Service.Delivery.closed, control.delivered[1]);
    try control.send(reconnected, "closed");
}
