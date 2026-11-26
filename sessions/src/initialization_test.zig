const std = @import("std");
const builtin = @import("builtin");
const network = @import("networking");
const worker_module = @import("worker.zig");
const service_module = @import("service.zig");
const protocol = @import("protocol.zig");
const router_module = @import("router.zig");
const shared = @import("shared.zig");
const metrics = @import("metrics");
const system = @import("system");

const Endpoint = struct {
    pub const versions = .{};
    pub const Protocols = struct { values: [1]protocol.Protocol = .{.{ .number = 1 }} };
    pub const Connection = struct { clears: *usize };
    pub const Workspaces = struct {};
    pub fn initWorkspaces(_: std.mem.Allocator) !Workspaces {
        return .{};
    }
    pub fn deinitWorkspaces(_: *Workspaces) void {}
    pub fn needsDecoded(_: ?usize) bool {
        return false;
    }
    pub fn clear(connection: *Connection) void {
        connection.clears.* += 1;
    }
};
const Hooks = struct {
    closed_count: usize = 0,
    notifications: usize = 0,
    pub fn closed(self: *Hooks, _: network.Handle) void {
        self.closed_count += 1;
    }
    pub fn notify(self: *Hooks, _: std.Io) void {
        _ = @atomicRmw(usize, &self.notifications, .Add, 1, .monotonic);
    }
    pub fn queueReceive(_: *Hooks, _: std.Io, _: network.Handle, _: []u8) network.QueueError!void {
        unreachable;
    }
    pub fn queueSend(_: *Hooks, _: std.Io, _: network.Handle, _: []const std.posix.iovec_const) network.QueueError!void {
        unreachable;
    }
    pub fn close(_: *Hooks, _: std.Io, _: network.Handle, _: network.CloseReason) void {
        unreachable;
    }
    pub fn releaseConnection(_: *Hooks, _: std.Io, _: network.Handle) void {
        unreachable;
    }
    pub fn submit(_: *Hooks, _: std.Io) !void {
        unreachable;
    }
    pub fn poll(_: *Hooks, _: std.Io, _: ?std.Io.Timeout, _: []network.Event) !usize {
        unreachable;
    }
};
const Worker = worker_module.Worker(Endpoint, Hooks, router_module.SingleSimulation);
const protocols: Endpoint.Protocols = .{};

fn transport(hooks: *Hooks) network.Transport {
    return .{ .context = hooks, .vtable = network.Transport.adapter(Hooks) };
}
fn createEndpoint(allocator: std.mem.Allocator, hooks: *Hooks) !*service_module.Service {
    return createEndpointWithInputWork(allocator, hooks, service_module.Service.default_input_work);
}

fn createEndpointWithInputWork(allocator: std.mem.Allocator, hooks: *Hooks, input_work: system.work.Limits) !*service_module.Service {
    return service_module.Service.init(allocator, std.testing.io, transport(hooks), .{
        .connections = 2,
        .credit_bytes = 512,
        .pages = 4,
        .page_bytes = 128,
        .protocols = &protocols.values,
        .max_input_bytes = 509,
        .input_work = input_work,
    });
}

test "input rounds preserve borrowed suffixes and reserve progress before sharing burst work" {
    var hooks: Hooks = .{};
    const endpoint = try createEndpointWithInputWork(std.testing.allocator, &hooks, .{ .guaranteed = .{ .operations = 1, .bytes = 1 }, .burst = .{ .operations = 1, .bytes = 512 } });
    defer endpoint.deinit();
    const first = [_][]const u8{ "a", "b", "c", "d", "e", "f" };
    const second = [_][]const u8{ "g", "h", "i", "j", "k", "l" };
    for ([_][]const []const u8{ &first, &second }, 0..) |packets, index| try std.testing.expect(endpoint.push(.{ .input = .{ .handle = .{ .index = index, .generation = 1 }, .protocol = 1, .packets = .{ .packets = packets } } }));
    var consumed: [2]usize = .{ 0, 0 };
    for (0..4) |round| {
        endpoint.beginTick();
        var counts: [2]usize = .{ 0, 0 };
        for (endpoint.input_events) |event| {
            var packets = event.input.packets;
            const index = event.input.handle.index;
            while (try packets.next()) |packet| {
                const original = if (index == 0) first[consumed[index]] else second[consumed[index]];
                try std.testing.expectEqual(original.ptr, packet.ptr);
                consumed[index] += 1;
                counts[index] += 1;
            }
        }
        try std.testing.expect(counts[0] + counts[1] <= 3);
        if (round < 2) {
            try std.testing.expectEqual(@as(usize, if (round == 0) 2 else 1), counts[0]);
            try std.testing.expectEqual(@as(usize, if (round == 0) 1 else 2), counts[1]);
        }
        endpoint.endTick(true);
        for (endpoint.releases) |*release| _ = release.swap(0, .acquire);
    }
    try std.testing.expectEqual([2]usize{ 6, 6 }, consumed);
    try std.testing.expectEqual(@as(usize, 0), endpoint.pending_input_count);
}

test "large input packets take fair burst turns and shutdown releases deferred loans" {
    var hooks: Hooks = .{};
    const endpoint = try createEndpointWithInputWork(std.testing.allocator, &hooks, .{ .guaranteed = .{ .operations = 1, .bytes = 1 }, .burst = .{ .operations = 1, .bytes = 512 } });
    defer endpoint.deinit();
    const bytes: [400]u8 = @splat(7);
    const packets = [_][]const u8{ &bytes, &bytes };
    for (0..2) |index| try std.testing.expect(endpoint.push(.{ .input = .{ .handle = .{ .index = index, .generation = 1 }, .protocol = 1, .packets = .{ .packets = &packets } } }));
    for (0..2) |round| {
        endpoint.beginTick();
        try std.testing.expectEqual(@as(usize, 1), endpoint.input_events.len);
        try std.testing.expectEqual(round, endpoint.input_events[0].input.handle.index);
        try std.testing.expectEqual(@as(usize, 1), endpoint.input_events[0].input.packets.packets.len);
        endpoint.endTick(true);
        try std.testing.expectEqual(@as(u32, 0), endpoint.releases[round].load(.acquire));
    }
    const notifications = hooks.notifications;
    endpoint.discardInputs();
    try std.testing.expectEqual(notifications + 1, hooks.notifications);
    for (endpoint.releases) |*release| try std.testing.expectEqual(@as(u32, 1), release.swap(0, .acquire));
    try std.testing.expectEqual(@as(usize, 0), endpoint.pending_input_count);
}

test "framed input retains packet boundaries and releases deferred loans on an aborted tick" {
    var hooks: Hooks = .{};
    const endpoint = try createEndpointWithInputWork(std.testing.allocator, &hooks, .{ .guaranteed = .{ .operations = 1, .bytes = 509 }, .burst = .{} });
    defer endpoint.deinit();
    const framed = [_]u8{ 2, 'a', 'b', 1, 'c', 3, 'd', 'e', 'f' };
    const handle: network.Handle = .{ .index = 0, .generation = 1 };
    try std.testing.expect(endpoint.push(.{ .input = .{ .handle = handle, .protocol = 1, .packets = .{ .framed = &framed } } }));
    endpoint.beginTick();
    var first = endpoint.input_events[0].input.packets;
    const body = (try first.next()).?;
    try std.testing.expectEqualSlices(u8, "ab", body);
    try std.testing.expectEqual(framed[1..].ptr, body.ptr);
    try std.testing.expectEqual(null, try first.next());
    endpoint.endTick(true);
    try std.testing.expectEqual(@as(u32, 0), endpoint.releases[0].load(.acquire));
    endpoint.beginTick();
    var second = endpoint.input_events[0].input.packets;
    try std.testing.expectEqualSlices(u8, "c", (try second.next()).?);
    endpoint.endTick(false);
    try std.testing.expectEqual(@as(u32, 1), endpoint.releases[0].swap(0, .acquire));
    try std.testing.expectEqual(@as(usize, 0), endpoint.pending_input_count);
    endpoint.discardInputs();
    try std.testing.expectEqual(@as(u32, 0), endpoint.releases[0].load(.acquire));
}
fn createWorker(allocator: std.mem.Allocator, hooks: *Hooks, router: *router_module.SingleSimulation, endpoints: []const *service_module.Service) !*Worker {
    return Worker.init(allocator, transport(hooks), .{
        .connections = 2,
        .max_players = 1,
        .buffer_bytes = 512,
        .max_pending_wire_bytes = 1024,
        .protocols = &protocols,
        .compression_threshold = null,
        .hooks = hooks,
        .router = router,
        .destinations = &.{0},
    }, endpoints);
}

test "typed destinations survive endpoint growth and reordering" {
    const Key = struct { uuid: u128, region: enum { primary, secondary } };
    const Router = struct {
        pub const Destination = Key;
        decision: router_module.Route(Key),
        pub fn route(self: *@This(), _: protocol.Profile) router_module.Route(Key) {
            return self.decision;
        }
    };
    const TypedWorker = worker_module.Worker(Endpoint, Hooks, Router);
    const home: Key = .{ .uuid = 0xfedcba98765432100123456789abcdef, .region = .secondary };
    const other: Key = .{ .uuid = 7, .region = .primary };
    const added: Key = .{ .uuid = 9, .region = .primary };
    var hooks: Hooks = .{};
    const first = try createEndpoint(std.testing.allocator, &hooks);
    defer first.deinit();
    const second = try createEndpoint(std.testing.allocator, &hooks);
    defer second.deinit();
    const third = try createEndpoint(std.testing.allocator, &hooks);
    defer third.deinit();
    for ([_]usize{ 2, 3 }) |count| {
        var ids = if (count == 2) [_]Key{ home, other, added } else [_]Key{ added, other, home };
        const endpoints = if (count == 2) [_]*service_module.Service{ first, second, third } else [_]*service_module.Service{ third, second, first };
        const expected: usize = if (count == 2) 0 else 2;
        var router: Router = .{ .decision = .{ .destination = home } };
        const worker = try TypedWorker.init(std.testing.allocator, transport(&hooks), .{
            .connections = 2,
            .max_players = 1,
            .buffer_bytes = 512,
            .max_pending_wire_bytes = 1024,
            .protocols = &protocols,
            .compression_threshold = null,
            .hooks = &hooks,
            .router = &router,
            .destinations = ids[0..count],
        }, endpoints[0..count]);
        defer worker.deinit();
        ids[expected] = added;
        var player: protocol.Profile = .{ .connection = .{ .index = 0, .generation = 1 }, .protocol = 1, .uuid = 123, .name = "player" };
        const selected = worker.select(player);
        try std.testing.expectEqual(expected, selected.destination);
        try std.testing.expect(worker.endpoints[selected.destination] == first);
        player.connection.generation += 1;
        router.decision = .{ .destination = .{ .uuid = home.uuid, .region = .primary } };
        try std.testing.expectEqual(router_module.Route(usize).reject, worker.select(player));
        router.decision = .pending;
        try std.testing.expectEqual(router_module.Route(usize).pending, worker.select(player));
        router.decision = .reject;
        try std.testing.expectEqual(router_module.Route(usize).reject, worker.select(player));
    }
}

test "gameplay output becomes visible as one batch after the tick" {
    var hooks: Hooks = .{};
    const endpoint = try createEndpoint(std.testing.allocator, &hooks);
    defer endpoint.deinit();
    const handle: network.Handle = .{ .index = 0, .generation = 1 };
    endpoint.credit[0].store((@as(u64, 1) << 32) | service_module.Service.active | 512, .release);
    endpoint.beginTick();
    for (0..2) |i| {
        var packet = try endpoint.reserve(8);
        defer packet.cancel();
        packet.bytes[0] = @intCast(i + 1);
        try packet.publish(1, &.{handle});
        endpoint.flush();
        var empty = endpoint.outputBatch();
        try std.testing.expect(empty.next() == null);
    }
    endpoint.endTick(true);
    try std.testing.expectEqual(@as(usize, 0), hooks.notifications);
    endpoint.flush();
    try std.testing.expectEqual(@as(usize, 1), hooks.notifications);
    var batch = endpoint.outputBatch();
    for (0..2) |i| {
        const packet = batch.next().?;
        try std.testing.expectEqual(@as(u8, @intCast(i + 1)), packet.bytes[0]);
        try std.testing.expect(endpoint.output.releaseReady(packet.page, packet.generation));
        _ = endpoint.preparing.fetchSub(1, .release);
    }
    var empty = endpoint.outputBatch();
    try std.testing.expect(empty.next() == null);
    endpoint.flush();
    try std.testing.expectEqual(@as(usize, 1), hooks.notifications);
}

test "buffer pressure publishes the accumulated batch during a tick" {
    var hooks: Hooks = .{};
    // Credit enough that the pool, not credit, is what fills.
    const endpoint = try service_module.Service.init(std.testing.allocator, std.testing.io, transport(&hooks), .{ .connections = 2, .credit_bytes = 4096, .pages = 4, .page_bytes = 128, .protocols = &protocols.values, .max_input_bytes = 509 });
    defer endpoint.deinit();
    const handles = [_]network.Handle{ .{ .index = 0, .generation = 1 }, .{ .index = 1, .generation = 1 } };
    for (endpoint.credit) |*credit| credit.store((@as(u64, 1) << 32) | service_module.Service.active | 4096, .release);
    endpoint.beginTick();
    // A packet of one byte keeps one unit of what it reserved, so the pool holds one for each.
    const capacity = endpoint.output.pool.units();
    for (0..capacity) |i| {
        var packet = try endpoint.reserve(if (i + 1 == capacity) 1 else 128);
        defer packet.cancel();
        packet.bytes[0] = @intCast(i);
        try packet.publish(1, handles[i % handles.len ..][0..1]);
        var empty = endpoint.outputBatch();
        try std.testing.expect(empty.next() == null);
    }
    try std.testing.expectError(error.Backpressured, endpoint.reserve(128));
    try std.testing.expectEqual(@as(usize, 1), hooks.notifications);
    var batch = endpoint.outputBatch();
    for (0..capacity) |i| {
        const packet = batch.next().?;
        try std.testing.expectEqual(@as(u8, @intCast(i)), packet.bytes[0]);
        try std.testing.expect(endpoint.output.releaseReady(packet.page, packet.generation));
        _ = endpoint.preparing.fetchSub(1, .release);
    }
    endpoint.endTick(true);
    endpoint.flush();
    var empty = endpoint.outputBatch();
    try std.testing.expect(empty.next() == null);
}

test "an output batch excludes packets published after its snapshot" {
    var hooks: Hooks = .{};
    const endpoint = try createEndpoint(std.testing.allocator, &hooks);
    defer endpoint.deinit();
    const handle: network.Handle = .{ .index = 0, .generation = 1 };
    endpoint.credit[0].store((@as(u64, 1) << 32) | service_module.Service.active | 512, .release);
    var batch: service_module.Service.OutputBatch = undefined;
    for (0..2) |i| {
        var packet = try endpoint.reserve(8);
        defer packet.cancel();
        packet.bytes[0] = @intCast(i + 1);
        try packet.publish(1, &.{handle});
        endpoint.flush();
        if (i == 0) batch = endpoint.outputBatch();
    }
    const first = batch.next().?;
    try std.testing.expectEqual(@as(u8, 1), first.bytes[0]);
    try std.testing.expect(batch.next() == null);
    try std.testing.expect(endpoint.output.releaseReady(first.page, first.generation));
    _ = endpoint.preparing.fetchSub(1, .release);
    var next = endpoint.outputBatch();
    const second = next.next().?;
    try std.testing.expectEqual(@as(u8, 2), second.bytes[0]);
    try std.testing.expect(next.next() == null);
    try std.testing.expect(endpoint.output.releaseReady(second.page, second.generation));
    _ = endpoint.preparing.fetchSub(1, .release);
}

test "unstarted worker rollback releases restored codec and endpoint ownership" {
    var hooks: Hooks = .{};
    var router: router_module.SingleSimulation = .{};
    const endpoint = try createEndpoint(std.testing.allocator, &hooks);
    defer endpoint.deinit();
    const endpoints = [_]*service_module.Service{endpoint};
    const worker = try createWorker(std.testing.allocator, &hooks, &router, &endpoints);
    var clears: usize = 0;
    const handle: network.Handle = .{ .index = 0, .generation = 1 };
    worker.engine.setHandle(0, handle);
    worker.engine.connections[0].lifecycle = .{ .clears = &clears };
    worker.engine.admit(0);
    worker.bindings[0] = .{ .endpoint = endpoint, .handle = handle, .native = handle };
    endpoint.routes[0] = handle;
    endpoint.occupied[0].store(true, .release);
    endpoint.releases[0].store(handle.generation, .release);
    try std.testing.expect(endpoint.push(.{ .left = handle }));
    worker.deinitUnstarted();
    try std.testing.expectEqual(@as(usize, 1), clears);
    try std.testing.expectEqual(@as(usize, 1), hooks.closed_count);
    try std.testing.expect(endpoint.owner == null);
    try std.testing.expect(endpoint.routes[0] == null);
    try std.testing.expect(!endpoint.occupied[0].load(.acquire));
    try std.testing.expectEqual(endpoint.event_write.load(.acquire), endpoint.event_read.load(.acquire));
}

fn initialize(allocator: std.mem.Allocator) !void {
    var hooks: Hooks = .{};
    var router: router_module.SingleSimulation = .{};
    const endpoint = try createEndpoint(allocator, &hooks);
    defer endpoint.deinit();
    const endpoints = [_]*service_module.Service{endpoint};
    const worker = try createWorker(allocator, &hooks, &router, &endpoints);
    worker.deinitUnstarted();
}
test "worker initialization allocation failures release owned buffers" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, initialize, .{});
}

test "background publication rejects a packet encoded across a gameplay tick" {
    var hooks: Hooks = .{};
    const endpoint = try createEndpoint(std.testing.allocator, &hooks);
    defer endpoint.deinit();
    const handle: network.Handle = .{ .index = 0, .generation = 1 };
    endpoint.credit[0].store((@as(u64, 1) << 32) | service_module.Service.active | 512, .release);
    var stale = try endpoint.reserveBackground(8, endpoint.backgroundEpoch());
    defer stale.cancel();
    stale.bytes[0] = 1;
    endpoint.beginTick();
    try std.testing.expectError(error.Backpressured, endpoint.reserveBackground(8, endpoint.backgroundEpoch()));
    endpoint.endTick(true);
    try std.testing.expectError(error.Backpressured, stale.publish(1, &.{handle}));
    try std.testing.expect(endpoint.output.takeReady() == null);
    var current = try endpoint.reserveBackground(8, endpoint.backgroundEpoch());
    defer current.cancel();
    current.bytes[0] = 2;
    try current.publish(1, &.{handle});
    const packet = endpoint.output.takeReady().?;
    try std.testing.expectEqual(@as(u8, 2), packet.bytes[0]);
    try std.testing.expect(endpoint.output.releaseReady(packet.page, packet.generation));
    endpoint.preparing.store(0, .release);
}

test "output progress wakes independent producers and detaches their events" {
    var hooks: Hooks = .{};
    const endpoint = try createEndpoint(std.testing.allocator, &hooks);
    defer endpoint.deinit();
    var a: std.Io.Event = .unset;
    var b: std.Io.Event = .unset;
    try endpoint.subscribeOutput(&a);
    defer endpoint.unsubscribeOutput(&a);
    try endpoint.subscribeOutput(&b);
    try std.testing.expectError(error.DuplicateOutputSubscription, endpoint.subscribeOutput(&a));
    endpoint.notifyOutput(std.testing.io);
    try std.testing.expect(a.isSet());
    try std.testing.expect(b.isSet());
    endpoint.unsubscribeOutput(&b);
    a.reset();
    b.reset();
    endpoint.notifyOutput(std.testing.io);
    try std.testing.expect(a.isSet());
    try std.testing.expect(!b.isSet());
}

test "a held output reservation cannot publish after shutdown begins" {
    var hooks: Hooks = .{};
    const endpoint = try createEndpoint(std.testing.allocator, &hooks);
    defer endpoint.deinit();
    const handle: network.Handle = .{ .index = 0, .generation = 1 };
    endpoint.credit[0].store((@as(u64, 1) << 32) | service_module.Service.active | 512, .release);
    var packet = try endpoint.reserveBackground(8, endpoint.backgroundEpoch());
    packet.bytes[0] = 1;
    endpoint.stopping.store(true, .release);
    try std.testing.expectError(error.Closed, packet.publish(1, &.{handle}));
    try std.testing.expectEqual(@as(usize, 0), endpoint.preparing.load(.acquire));
    try std.testing.expect(endpoint.output.takeReady() == null);
}

test "recipient reservations survive backpressure and return credit on every exit" {
    for (std.meta.tags(enum { batch, direct, cancel, cancel_batch, stale, shutdown })) |mode| {
        var hooks: Hooks = .{};
        const endpoint = try createEndpoint(std.testing.allocator, &hooks);
        defer endpoint.deinit();
        const handles = [_]network.Handle{ .{ .index = 0, .generation = 1 }, .{ .index = 1, .generation = 1 } };
        const active_credit = (@as(u64, 1) << 32) | service_module.Service.active;
        endpoint.credit[0].store(active_credit, .release);
        endpoint.credit[1].store(active_credit | 512, .release);
        var packets: [2]service_module.Service.Packet = undefined;
        try std.testing.expectEqual(@as(usize, 2), try endpoint.reserveMany(8, &packets));
        for (&packets) |*packet| packet.epoch = endpoint.backgroundEpoch();
        var reservation = endpoint.reserveRecipients(&packets, &handles);
        defer reservation.release();
        try std.testing.expect(!reservation.canWrite(&packets[0], handles[0]));
        packets[0].cancel();
        try std.testing.expectEqual(@as(usize, 512) - endpoint.framedBound(8), endpoint.outputCredit(handles[1]));
        const packet = &packets[1];
        packet.limit(4);
        packet.bytes[0] = 17;
        try std.testing.expect(reservation.canWrite(packet, handles[1]));
        reservation.finish(packet, handles[1], 1);
        reservation.release();
        switch (mode) {
            .cancel => packet.cancel(),
            .cancel_batch => endpoint.cancelPackets(packets[1..]),
            .direct => try packet.publish(1, handles[1..]),
            .batch, .stale, .shutdown => {
                if (mode == .stale) packet.epoch = endpoint.backgroundEpoch() + 2;
                if (mode == .shutdown) endpoint.stopping.store(true, .release);
                var recipients = handles;
                var accepted: [1]usize = undefined;
                endpoint.publishManyReady(&.{.{ .packet = packet, .length = 1, .recipients = &recipients }}, &accepted);
                try std.testing.expectEqual(@as(usize, if (mode == .batch) 1 else 0), accepted[0]);
            },
        }
        try std.testing.expect(packet.reservation == null and packet.credit == null);
        if (mode == .batch or mode == .direct) {
            try std.testing.expectEqual(@as(usize, 512) - endpoint.framedBound(1), endpoint.outputCredit(handles[1]));
            const sent = endpoint.output.takeReady().?;
            try std.testing.expectEqualSlices(u8, &.{17}, sent.bytes);
            endpoint.recycle(std.testing.io, &.{sent});
            endpoint.refund(handles[1], endpoint.framedBound(1));
        }
        try std.testing.expectEqual(active_credit | 512, endpoint.credit[1].load(.acquire));
        try std.testing.expectEqual(@as(usize, if (mode == .shutdown) 0 else 512), endpoint.outputCredit(handles[1]));
        try std.testing.expect(endpoint.output.takeReady() == null);
        try std.testing.expectEqual(@as(usize, 0), endpoint.preparing.load(.acquire));
        try std.testing.expectEqual(endpoint.output.pool.units(), endpoint.output.pool.free_units.count());
    }
}

test "a recipient batch shares reserved credit across actual packet lengths" {
    var hooks: Hooks = .{};
    const endpoint = try createEndpoint(std.testing.allocator, &hooks);
    defer endpoint.deinit();
    const handle: network.Handle = .{ .index = 0, .generation = 1 };
    // The batch may hold everything above the floor that stays within reach of the simulation.
    const floor = endpoint.backgroundFloor();
    try std.testing.expect(floor != 0);
    const available = floor + endpoint.framedBound(8) + 2 * endpoint.framedBound(1);
    try std.testing.expect(available <= endpoint.config.credit_bytes);
    const active_credit = (@as(u64, 1) << 32) | service_module.Service.active;
    endpoint.credit[0].store(active_credit | available, .release);
    var packets: [3]service_module.Service.Packet = undefined;
    try std.testing.expectEqual(packets.len, try endpoint.reserveMany(8, &packets));
    defer endpoint.cancelPackets(&packets);
    const handles: [packets.len]network.Handle = @splat(handle);
    var reservation = endpoint.reserveRecipients(&packets, &handles);
    defer reservation.release();
    try std.testing.expectEqual(floor, endpoint.outputCredit(handle));
    // What the simulation sends this player meanwhile is refused only if it does not
    // fit the floor, which in a server holds many times the largest chat message.
    try std.testing.expectEqual(floor >= endpoint.framedBound(1), endpoint.canSend(handle, 1));
    try std.testing.expectEqual(@as(usize, 0), endpoint.packetCapacity(handle, 1));
    var publications: [packets.len]service_module.Service.Publication = undefined;
    var recipients: [packets.len][1]network.Handle = @splat(.{handle});
    for (&packets, &publications, &recipients, 0..) |*packet, *publication, *target, index| {
        try std.testing.expect(reservation.canWrite(packet, handle));
        packet.bytes[0] = @intCast(index);
        reservation.finish(packet, handle, 1);
        publication.* = .{ .packet = packet, .length = 1, .recipients = target };
    }
    reservation.release();
    var accepted: [packets.len]usize = undefined;
    endpoint.publishManyReady(&publications, &accepted);
    try std.testing.expectEqual([_]usize{ 1, 1, 1 }, accepted);
    try std.testing.expectEqual(available - packets.len * endpoint.framedBound(1), endpoint.outputCredit(handle));
    for (0..packets.len) |index| {
        const sent = endpoint.output.takeReady().?;
        try std.testing.expectEqual(index, sent.bytes[0]);
        endpoint.recycle(std.testing.io, &.{sent});
        endpoint.refund(handle, endpoint.framedBound(1));
    }
    try std.testing.expectEqual(available, endpoint.outputCredit(handle));
    try std.testing.expect(endpoint.output.takeReady() == null);
    try std.testing.expectEqual(@as(usize, 0), endpoint.preparing.load(.acquire));
    try std.testing.expectEqual(endpoint.output.pool.units(), endpoint.output.pool.free_units.count());
}

test "a packet too large for the room above the floor goes once its connection is idle" {
    var hooks: Hooks = .{};
    // Pages larger than the credit, as a server's are, so a chunk can be charged that much.
    const endpoint = try service_module.Service.init(std.testing.allocator, std.testing.io, transport(&hooks), .{
        .connections = 2,
        .credit_bytes = 512,
        .pages = 4,
        .page_bytes = 1024,
        .protocols = &protocols.values,
        .max_input_bytes = 509,
    });
    defer endpoint.deinit();
    const handle: network.Handle = .{ .index = 0, .generation = 1 };
    const credit = endpoint.config.credit_bytes;
    const room = credit - endpoint.backgroundFloor();
    // A packet charged more than the room above the floor but less than the whole credit.
    var length: usize = 1;
    while (length <= endpoint.config.page_bytes and endpoint.framedBound(length) <= room) length += 1;
    try std.testing.expect(length <= endpoint.config.page_bytes and endpoint.framedBound(length) < credit);
    const active_credit = (@as(u64, 1) << 32) | service_module.Service.active;
    endpoint.credit[0].store(active_credit | credit, .release);
    try std.testing.expectEqual(@as(usize, 1), endpoint.packetCapacity(handle, length));
    // Once anything of the connection is out, it waits, as the simulation may need the floor.
    endpoint.credit[0].store(active_credit | (credit - 1), .release);
    try std.testing.expectEqual(@as(usize, 0), endpoint.packetCapacity(handle, length));
}

test "publication batches consume rejected reservations without charging their peers" {
    for ([_]bool{ false, true }) |stale| {
        var hooks: Hooks = .{};
        const endpoint = try createEndpoint(std.testing.allocator, &hooks);
        defer endpoint.deinit();
        const handles = [_]network.Handle{ .{ .index = 0, .generation = 1 }, .{ .index = 1, .generation = 1 } };
        const active_credit = (@as(u64, 1) << 32) | service_module.Service.active;
        endpoint.credit[0].store(active_credit | 512, .release);
        endpoint.credit[1].store(active_credit | @as(u64, if (stale) 512 else 0), .release);
        var packets: [2]service_module.Service.Packet = undefined;
        try std.testing.expectEqual(@as(usize, 2), try endpoint.reserveMany(8, &packets));
        packets[0].bytes[0] = 17;
        packets[1].bytes[0] = 33;
        if (stale) packets[1].epoch = endpoint.backgroundEpoch() + 2;
        var first = [_]network.Handle{handles[0]};
        var second = [_]network.Handle{handles[1]};
        const publications = [_]service_module.Service.Publication{ .{ .packet = &packets[0], .length = 1, .recipients = &first }, .{ .packet = &packets[1], .length = 1, .recipients = &second } };
        var accepted: [2]usize = undefined;
        endpoint.publishManyReady(&publications, &accepted);
        try std.testing.expectEqualSlices(usize, &.{ 1, 0 }, &accepted);
        try std.testing.expectEqual(active_credit | @as(u64, if (stale) 512 else 0), endpoint.credit[1].load(.acquire));
        for (packets) |packet| try std.testing.expect(packet.reservation == null);
        const packet = endpoint.output.takeReady().?;
        try std.testing.expectEqualSlices(u8, &.{17}, packet.bytes);
        try std.testing.expect(endpoint.output.takeReady() == null);
        endpoint.recycle(std.testing.io, &.{packet});
        try std.testing.expectEqual(@as(usize, 0), endpoint.preparing.load(.acquire));
        try std.testing.expectEqual(endpoint.output.pool.units(), endpoint.output.pool.free_units.count());
    }
}

pub fn benchmarkFanout() !void {
    const First = struct {
        pub const protocol_number: i32 = 1;
    };
    const Second = struct {
        pub const protocol_number: i32 = 2;
    };
    const Arguments = struct { calls: *usize, pool: []u8 };
    const Encoder = struct {
        pub fn write(comptime Version: type, bytes: []u8, arguments: Arguments) ![]u8 {
            arguments.calls.* += 1;
            bytes[0] = @intCast(Version.protocol_number);
            return bytes[0..1];
        }
        pub fn writeGroup(comptime Version: type, buffers: []const []u8, lengths: []usize, arguments: Arguments) !void {
            arguments.calls.* += 1;
            try std.testing.expect(@intFromPtr(buffers[0].ptr) >= @intFromPtr(arguments.pool.ptr));
            try std.testing.expect(@intFromPtr(buffers[0].ptr) + buffers[0].len <= @intFromPtr(arguments.pool.ptr) + arguments.pool.len);
            buffers[0][0] = @intCast(Version.protocol_number);
            lengths[0] = 1;
        }
    };
    var buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(std.testing.io, &buffer);
    try output.interface.writeAll("fanout recipients | credit | protocols | encoder calls | queued recipients | transport notifications | runtime allocations\n");
    for ([_]bool{ true, false }) |available| for ([_]usize{ 2, 8, 64 }) |count| {
        var hooks: Hooks = .{};
        var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const endpoint = try service_module.Service.init(allocator.allocator(), std.testing.io, transport(&hooks), .{
            .connections = count,
            .buffer_bytes = 512,
            .pages = 4,
            .page_bytes = 128,
            .protocols = &.{ .{ .number = 1 }, .{ .number = 2 } },
        });
        defer endpoint.deinit();
        var targets: [64]service_module.Service.Target = undefined;
        var delivered: [64]service_module.Service.Delivery = undefined;
        for (endpoint.credit, targets[0..count], 0..) |*credit, *target, index| {
            credit.store((@as(u64, 1) << 32) | service_module.Service.active | @as(u64, if (available) 512 else 0), .release);
            target.* = .{ .handle = .{ .index = @intCast(index), .generation = 1 }, .protocol = @intCast(1 + index % 2) };
        }
        const before = allocator.alloc_index;
        allocator.fail_index = before;
        var calls: usize = 0;
        endpoint.beginTick();
        try endpoint.fanout(.{ First, Second }, Encoder, targets[0..count], Arguments{ .calls = &calls, .pool = endpoint.output.bytes }, &.{8}, delivered[0..count]);
        if (!available) {
            const arguments: Arguments = .{ .calls = &calls, .pool = endpoint.output.bytes };
            try std.testing.expectError(error.Backpressured, endpoint.send(.{First}, Encoder, 1, targets[0].handle, arguments, 8));
            try std.testing.expectError(error.Backpressured, endpoint.sendRetrying(.{First}, Encoder, 1, targets[0].handle, arguments, 8));
            const stale: network.Handle = .{ .index = 0, .generation = 2 };
            try std.testing.expectError(error.Closed, endpoint.send(.{First}, Encoder, 1, stale, arguments, 8));
            try std.testing.expectError(error.Closed, endpoint.sendRetrying(.{First}, Encoder, 1, stale, arguments, 8));
        }
        endpoint.endTick(true);
        endpoint.flush();
        for (delivered[0..count]) |result| try std.testing.expect(result == (if (available) service_module.Service.Delivery.queued else .backpressured));
        try std.testing.expectEqual(before, allocator.alloc_index);
        var batch = endpoint.outputBatch();
        var recipients: usize = 0;
        while (batch.next()) |packet| {
            recipients += packet.recipients.len;
            endpoint.recycle(std.testing.io, &.{packet});
        }
        try std.testing.expectEqual(if (available) count else 0, recipients);
        try std.testing.expectEqual(@as(usize, if (available) 2 else 0), calls);
        try output.interface.print("{d:17} | {d:6} | {d:9} | {d:13} | {d:17} | {d:23} | {d}\n", .{ count, @as(usize, if (available) 512 else 0), @as(usize, 2), calls, recipients, hooks.notifications, allocator.alloc_index - before });
    };
    try output.interface.flush();
}

test "fanout batches protocols while preserving independent target admission" {
    const First = struct {
        pub const protocol_number: i32 = 1;
    };
    const Second = struct {
        pub const protocol_number: i32 = 2;
    };
    const Arguments = struct { value: u8, calls: *[2]usize, pool: []u8 };
    const Encoder = struct {
        pub fn writeGroup(comptime Version: type, buffers: []const []u8, lengths: []usize, arguments: Arguments) !void {
            arguments.calls[Version.protocol_number - 1] += 1;
            try std.testing.expect(@intFromPtr(buffers[0].ptr) >= @intFromPtr(arguments.pool.ptr));
            try std.testing.expect(@intFromPtr(buffers[0].ptr) + buffers[0].len <= @intFromPtr(arguments.pool.ptr) + arguments.pool.len);
            buffers[0][0] = @intCast(Version.protocol_number);
            buffers[0][1] = arguments.value;
            lengths[0] = 2;
        }
    };
    var hooks: Hooks = .{};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const endpoint = try service_module.Service.init(failing.allocator(), std.testing.io, transport(&hooks), .{
        .connections = 3,
        .credit_bytes = 512,
        .pages = 4,
        .page_bytes = 128,
        .protocols = &.{ .{ .number = 1 }, .{ .number = 2 } },
    });
    defer endpoint.deinit();
    for (endpoint.credit, 0..) |*credit, index| credit.store((@as(u64, 1) << 32) | service_module.Service.active | @as(u64, if (index == 2) 0 else 512), .release);
    const targets = [_]service_module.Service.Target{
        .{ .handle = .{ .index = 1, .generation = 1 }, .protocol = 2 },
        .{ .handle = .{ .index = 0, .generation = 1 }, .protocol = 1 },
        .{ .handle = .{ .index = 2, .generation = 1 }, .protocol = 1 },
    };
    var delivered: [3]service_module.Service.Delivery = undefined;
    var calls: [2]usize = @splat(0);
    const allocated = failing.alloc_index;
    failing.fail_index = allocated;
    try endpoint.fanout(.{ First, Second }, Encoder, &targets, Arguments{ .value = 77, .calls = &calls, .pool = endpoint.output.bytes }, &.{8}, &delivered);
    try std.testing.expectEqual(allocated, failing.alloc_index);
    try std.testing.expectEqualSlices(usize, &.{ 1, 1 }, &calls);
    try std.testing.expectEqualSlices(service_module.Service.Delivery, &.{ .queued, .queued, .backpressured }, &delivered);
    const first = endpoint.output.takeReady().?;
    const second = endpoint.output.takeReady().?;
    try std.testing.expectEqualSlices(u8, &.{ 1, 77 }, first.bytes);
    try std.testing.expectEqualSlices(u8, &.{ 2, 77 }, second.bytes);
    try std.testing.expect(first.recipients.eqlSlice(&.{targets[1].handle}));
    try std.testing.expect(second.recipients.eqlSlice(&.{targets[0].handle}));
    endpoint.recycle(std.testing.io, &.{ first, second });
}

test "ordered packet groups reserve all credit before publishing any member" {
    const io = std.testing.io;
    var hooks: Hooks = .{};
    var catalog: Endpoint.Protocols = .{};
    const endpoint = try service_module.Service.init(std.testing.allocator, io, transport(&hooks), .{
        .connections = 2,
        .credit_bytes = 4096,
        .pages = 8,
        .page_bytes = 128,
        .protocols = &catalog.values,
    });
    defer endpoint.deinit();
    const handles = [_]network.Handle{ .{ .index = 0, .generation = 1 }, .{ .index = 1, .generation = 1 } };
    const Version = struct {
        pub const protocol_number: i32 = 1;
    };
    const Encoder = struct {
        pub fn writeGroup(comptime _: type, buffers: []const []u8, lengths: []usize, _: void) !void {
            for (buffers, lengths, 0..) |buffer, *length, index| {
                @memset(buffer, @intCast(index + 1));
                length.* = 10 + index;
            }
        }
    };
    var charge: usize = 0;
    for (0..3) |index| charge += endpoint.framedBound(10 + index);
    const active = service_module.Service.active;
    endpoint.credit[0].store((@as(u64, 1) << 32) | active | (charge - 1), .release);
    endpoint.credit[1].store((@as(u64, 1) << 32) | active | charge, .release);
    const targets = [_]service_module.Service.Target{ .{ .handle = handles[0], .protocol = 1 }, .{ .handle = handles[1], .protocol = 1 } };
    var delivered: [2]service_module.Service.Delivery = @splat(.backpressured);
    try endpoint.fanout(.{Version}, Encoder, &targets, {}, &.{ 32, 32, 32 }, &delivered);
    try std.testing.expectEqualSlices(service_module.Service.Delivery, &.{ .backpressured, .queued }, &delivered);
    try std.testing.expectEqual(charge - 1, endpoint.outputCredit(handles[0]));
    try std.testing.expectEqual(@as(usize, 0), endpoint.outputCredit(handles[1]));
    endpoint.flush();
    var batch = endpoint.outputBatch();
    var received: [3]shared.RawPacket = undefined;
    for (&received, 0..) |*packet, index| {
        packet.* = batch.next() orelse return error.MissingGroupPacket;
        try std.testing.expectEqual(10 + index, packet.bytes.len);
        try std.testing.expectEqual(@as(u8, 3), packet.group.count);
        try std.testing.expectEqual(@as(?i32, 1), packet.group.protocol);
        try std.testing.expectEqual(charge, packet.group.bytes);
        try std.testing.expectEqual(@as(u8, @intCast(index)), packet.group.index);
        try std.testing.expect(std.mem.allEqual(u8, packet.bytes, @intCast(index + 1)));
        try std.testing.expect(packet.recipients.eqlSlice(handles[1..2]));
    }
    try std.testing.expect(batch.next() == null);
    endpoint.recycle(io, &received);
    endpoint.refund(handles[1], charge);
    try std.testing.expectEqual(@as(usize, 0), endpoint.preparing.load(.acquire));
}

test "concurrent group producers keep recipient storage and admitted results private" {
    if (comptime builtin.single_threaded) return error.SkipZigTest;
    const Service = service_module.Service;
    const io = std.testing.io;
    var hooks: Hooks = .{};
    const endpoint = try Service.init(std.testing.allocator, io, transport(&hooks), .{
        .connections = 2,
        .credit_bytes = 4096,
        .pages = 16,
        .page_bytes = 128,
        .protocols = &.{.{ .number = 1 }},
    });
    defer endpoint.deinit();
    for (endpoint.credit) |*credit| credit.store(@as(u64, 1) << 32 | Service.active | 4096, .release);
    const Version = struct {
        pub const protocol_number: i32 = 1;
    };
    const Value = struct { peer: u8, sequence: u32 };
    const Encoder = struct {
        pub fn writeGroup(comptime _: type, buffers: []const []u8, lengths: []usize, value: Value) !void {
            for (buffers, lengths, 0..) |buffer, *length, index| {
                buffer[0] = value.peer;
                std.mem.writeInt(u32, buffer[1..5], value.sequence, .little);
                buffer[5] = @intCast(index);
                length.* = 6;
            }
        }
    };
    const Producer = struct {
        endpoint: *Service,
        peer: u8,
        stopping: *std.atomic.Value(bool),
        queued: usize = 0,
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            while (self.queued < 200 and !self.stopping.load(.acquire)) {
                var result: [1]Service.Delivery = undefined;
                self.endpoint.fanout(.{Version}, Encoder, &.{.{ .handle = .{ .index = self.peer, .generation = 1 }, .protocol = 1 }}, Value{ .peer = self.peer, .sequence = @intCast(self.queued) }, &.{ 8, 8 }, &result) catch |err| {
                    self.failure = err;
                    return;
                };
                self.queued += @intFromBool(result[0] == .queued);
                if (result[0] != .queued) std.Thread.yield() catch {};
            }
        }
    };
    var stopping: std.atomic.Value(bool) = .init(false);
    var producers = [_]Producer{ .{ .endpoint = endpoint, .peer = 0, .stopping = &stopping }, .{ .endpoint = endpoint, .peer = 1, .stopping = &stopping } };
    var threads: [2]std.Thread = undefined;
    var started: usize = 0;
    defer {
        stopping.store(true, .release);
        for (threads[0..started]) |thread| thread.join();
        while (endpoint.output.takeReady()) |packet| endpoint.recycle(io, &.{packet});
    }
    for (&producers, &threads) |*producer, *thread| {
        thread.* = try std.Thread.spawn(.{}, Producer.run, .{producer});
        started += 1;
    }
    var next: [2]u8 = @splat(0);
    var sequence: [2]u32 = @splat(0);
    var completed: [2]usize = @splat(0);
    var identities: [2]shared.Group = undefined;
    while (!producers[0].done.load(.acquire) or !producers[1].done.load(.acquire) or endpoint.preparing.load(.acquire) != 0) {
        const packet = endpoint.output.takeReady() orelse {
            std.Thread.yield() catch {};
            continue;
        };
        const handle = packet.recipients.first().?;
        try std.testing.expectEqual(@as(usize, 1), packet.recipients.len);
        try std.testing.expectEqual(handle.index, packet.bytes[0]);
        try std.testing.expectEqual(next[handle.index], packet.group.index);
        try std.testing.expectEqual(next[handle.index], packet.bytes[5]);
        if (packet.group.index == 0) {
            identities[handle.index] = packet.group;
            sequence[handle.index] = std.mem.readInt(u32, packet.bytes[1..5], .little);
        } else {
            try std.testing.expectEqual(identities[handle.index].first, packet.group.first);
            try std.testing.expectEqual(identities[handle.index].generation, packet.group.generation);
            try std.testing.expectEqual(sequence[handle.index], std.mem.readInt(u32, packet.bytes[1..5], .little));
            completed[handle.index] += 1;
        }
        next[handle.index] = (next[handle.index] + 1) % 2;
        const charge = endpoint.framedBound(packet.bytes.len);
        endpoint.recycle(io, &.{packet});
        endpoint.refund(handle, charge);
    }
    for (&producers, completed, next) |*producer, count, expected| {
        if (producer.failure) |err| return err;
        try std.testing.expectEqual(@as(usize, 200), count);
        try std.testing.expectEqual(producer.queued, count);
        try std.testing.expectEqual(@as(u8, 0), expected);
    }
}

test "groups that cannot fit the configured memory or credit fail without publication" {
    const Service = service_module.Service;
    const Version = struct {
        pub const protocol_number: i32 = 1;
    };
    const Encoder = struct {
        pub fn writeGroup(comptime _: type, buffers: []const []u8, lengths: []usize, size: usize) !void {
            for (buffers, lengths) |buffer, *length| {
                @memset(buffer[0..size], 7);
                length.* = size;
            }
        }
    };
    for ([_]usize{ 1, 4 }) |pages| {
        var hooks: Hooks = .{};
        const endpoint = try Service.init(std.testing.allocator, std.testing.io, transport(&hooks), .{
            .connections = 1,
            .credit_bytes = 512,
            .pages = pages,
            .page_bytes = 256,
            .protocols = &.{.{ .number = 1 }},
        });
        defer endpoint.deinit();
        endpoint.credit[0].store(@as(u64, 1) << 32 | Service.active | 512, .release);
        var delivered: [1]Service.Delivery = undefined;
        // Two packets the size of a page: more than one page of memory holds, and more than
        // four pages of credit allows.
        const size: usize = 256;
        try std.testing.expectError(error.GroupTooLarge, endpoint.fanout(.{Version}, Encoder, &.{.{ .handle = .{ .index = 0, .generation = 1 }, .protocol = 1 }}, size, &.{ size, size }, &delivered));
        try std.testing.expect(endpoint.output.takeReady() == null);
        try std.testing.expectEqual(@as(usize, 0), endpoint.preparing.load(.acquire));
        try std.testing.expectEqual(@as(usize, 512), endpoint.outputCredit(.{ .index = 0, .generation = 1 }));
        try std.testing.expectEqual(endpoint.output.pool.units(), endpoint.output.pool.free_units.count());
    }
}

test "ending a tick releases the input batch with one notification" {
    var hooks: Hooks = .{};
    const endpoint = try createEndpoint(std.testing.allocator, &hooks);
    defer endpoint.deinit();
    defer for (endpoint.releases) |*release| release.store(0, .release);
    for (0..2) |index| try std.testing.expect(endpoint.push(.{ .input = .{
        .handle = .{ .index = @intCast(index), .generation = 1 },
        .protocol = 1,
        .packets = .{ .packets = &.{"packet"} },
    } }));
    endpoint.beginTick();
    try std.testing.expectEqual(@as(usize, 2), endpoint.input_events.len);
    const before = hooks.notifications;
    endpoint.endTick(true);
    try std.testing.expectEqual(before + 1, hooks.notifications);
    try std.testing.expectEqual(@as(u64, 0), endpoint.backgroundEpoch() & 1);
    for (endpoint.releases[0..2]) |*release| try std.testing.expectEqual(@as(u32, 1), release.load(.acquire));
    try std.testing.expectEqual(@as(usize, 3), endpoint.activity[0].load(.acquire));
}

test "endpoint readiness coalesces publication across bitmap words and rolls back transfers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const count = @bitSizeOf(usize) + 1;
    var hooks: Hooks = .{};
    var router: router_module.SingleSimulation = .{};
    var endpoints: [count]*service_module.Service = undefined;
    var destinations: [count]u32 = undefined;
    for (&endpoints, &destinations, 0..) |*endpoint, *destination, index| {
        endpoint.* = try createEndpoint(allocator, &hooks);
        destination.* = @intCast(index);
    }
    const worker = try Worker.init(allocator, transport(&hooks), .{
        .connections = 2,
        .max_players = 1,
        .buffer_bytes = 512,
        .max_pending_wire_bytes = 1024,
        .protocols = &protocols,
        .compression_threshold = null,
        .hooks = &hooks,
        .router = &router,
        .destinations = &destinations,
    }, &endpoints);
    defer {
        worker.abort(std.testing.io);
        worker.deinit();
        for (endpoints) |endpoint| endpoint.deinit();
    }
    const source = endpoints[count - 1];
    const handle: network.Handle = .{ .index = 1, .generation = 1 };
    source.credit[handle.index].store((@as(u64, 1) << 32) | service_module.Service.active | 512, .release);
    source.beginTick();
    try source.transfer(handle, endpoints[0]);
    const other: network.Handle = .{ .index = 0, .generation = 1 };
    source.credit[other.index].store((@as(u64, 1) << 32) | service_module.Service.active | 512, .release);
    try source.transfer(other, endpoints[0]);
    try std.testing.expectEqual(other.index, source.staged_move.?);
    try std.testing.expectEqual(handle.index, source.moves[other.index].next_staged.?);
    source.endTick(false);
    try std.testing.expectEqual(null, source.staged_move);
    try std.testing.expectEqual(null, source.moves[other.index].next_staged);
    try std.testing.expectEqual(.idle, source.moves[other.index].state.load(.acquire));
    try std.testing.expect(!endpoints[0].occupied[1].load(.acquire));
    try std.testing.expectEqual(.idle, source.moves[handle.index].state.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), worker.transfers_ready[1].load(.acquire));
    try std.testing.expect(!endpoints[0].occupied[0].load(.acquire));

    source.beginTick();
    try source.transfer(handle, endpoints[0]);
    try std.testing.expectEqual(@as(usize, 0), worker.transfers_ready[1].load(.acquire));
    source.endTick(true);
    try std.testing.expectEqual(.committed, source.moves[handle.index].state.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), worker.transfers_ready[0].load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), worker.transfers_ready[1].load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), source.committed_moves[0].load(.acquire));

    source.release(handle);
    try std.testing.expectEqual(@as(usize, 0), worker.inputs_ready[0].load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), worker.inputs_ready[1].load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), source.activity[0].load(.acquire));

    const output = endpoints[0];
    output.credit[0].store((@as(u64, 1) << 32) | service_module.Service.active | 512, .release);
    for (0..2) |index| {
        var packet = try output.reserve(1);
        packet.bytes[0] = @intCast(index);
        try packet.publish(1, &.{.{ .index = 0, .generation = 1 }});
    }
    try std.testing.expectEqual(@as(usize, 0), worker.output_ready[0].load(.acquire));
    output.flush();
    try std.testing.expectEqual(@as(usize, 1), worker.output_ready[0].swap(0, .acq_rel));
    var batch = output.outputBatch();
    var later = try output.reserve(1);
    later.bytes[0] = 2;
    try later.publish(1, &.{.{ .index = 0, .generation = 1 }});
    output.flush();
    for (0..2) |index| {
        const packet = batch.next().?;
        try std.testing.expectEqual(@as(u8, @intCast(index)), packet.bytes[0]);
        output.recycle(std.testing.io, &.{packet});
    }
    try std.testing.expect(batch.next() == null);
    try std.testing.expectEqual(@as(usize, 1), worker.output_ready[0].load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), worker.output_ready[1].load(.acquire));
}

test "pending descriptors follow pool identity across shared endpoints and abort reuse" {
    var hooks: Hooks = .{};
    var router: router_module.SingleSimulation = .{};
    var pool = try shared.Pool.init(std.testing.allocator, .{ .pages = 4, .page_bytes = 128, .recipients_per_page = 2 });
    defer pool.deinit();
    var endpoints: [3]*service_module.Service = undefined;
    for (&endpoints, 0..) |*endpoint, index| endpoint.* = try service_module.Service.init(std.testing.allocator, std.testing.io, transport(&hooks), .{
        .connections = 2,
        .credit_bytes = 512,
        .pages = 4,
        .page_bytes = 128,
        .protocols = &protocols.values,
        .output_pool = if (index == 1) null else &pool,
    });
    defer for (endpoints) |endpoint| endpoint.deinit();
    const worker = try Worker.init(std.testing.allocator, transport(&hooks), .{
        .connections = 2,
        .max_players = 1,
        .buffer_bytes = 512,
        .max_pending_wire_bytes = 1024,
        .protocols = &protocols,
        .compression_threshold = null,
        .hooks = &hooks,
        .router = &router,
        .destinations = &.{ 0, 1, 2 },
    }, &endpoints);
    defer worker.deinit();
    // A packet for each slot of each distinct pool.
    try std.testing.expectEqual(pool.slots.len + endpoints[1].output.slots.len, worker.packets.len);
    for (0..2) |_| {
        try std.testing.expectEqual(@as(usize, 0), worker.sources[0].packet_base);
        try std.testing.expectEqual(pool.slots.len, worker.sources[1].packet_base);
        try std.testing.expectEqual(@as(usize, 0), worker.sources[2].packet_base);
        worker.abort(std.testing.io);
    }
}

test "broadcast batches preserve exclusions dependencies credits and audience ownership" {
    const connections = 257;
    const Version = struct {
        pub const protocol_number = 1;
    };
    const Encoder = struct {
        pub fn writeGroup(comptime _: type, buffers: []const []u8, lengths: []usize, arguments: anytype) !void {
            lengths[0] = arguments[0];
            @memset(buffers[0][0..lengths[0]], 1);
        }
    };
    for (0..4) |mode| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .capacity = 16 });
        defer registry.deinit();
        var hooks: Hooks = .{};
        const endpoint = try service_module.Service.init(allocator, std.testing.io, transport(&hooks), .{ .metrics = &registry, .connections = connections, .pages = connections * 4, .page_bytes = 64, .credit_bytes = 128 * 1024, .protocols = &protocols.values });
        defer endpoint.deinit();
        var batch = try service_module.Service.Broadcast.init(allocator, endpoint, connections * 2);
        defer batch.deinit();
        var targets: [connections]service_module.Service.Target = undefined;
        var remaining: [connections]usize = @splat(endpoint.config.credit_bytes);
        if (mode == 1) remaining[0] = 0;
        if (mode == 2) remaining[0] = 300;
        if (mode == 3) for (&remaining, 0..) |*value, index| {
            value.* = (index * 173) % 32000;
        };
        for (&targets, remaining, 0..) |*target, credit, index| {
            target.* = .{ .handle = .{ .index = @intCast(index), .generation = 1 }, .protocol = 1 };
            endpoint.credit[index].store(@as(u64, 1) << 32 | service_module.Service.active | credit, .release);
        }
        try batch.begin(&targets);
        var receipts: [connections * 2]service_module.Service.Broadcast.Receipt = undefined;
        const expected = try allocator.alloc([connections]bool, receipts.len);
        @memset(expected, @splat(false));
        for (targets, 0..) |target, subject| {
            for (0..2) |phase| {
                const at = 2 * subject + phase;
                receipts[at] = try batch.write(.{Version}, Encoder, target.handle, if (phase == 0) null else receipts[at - 1], .{phase + 1}, 16);
                const charge = endpoint.framedBound(phase + 1);
                for (&remaining, 0..) |*credit, recipient| {
                    if (recipient == subject or (phase == 1 and !expected[at - 1][recipient]) or credit.* < charge) continue;
                    credit.* -= charge;
                    expected[at][recipient] = true;
                }
            }
        }
        batch.commit();
        try std.testing.expect(endpoint.instruments.broadcast_reservations.value() <= targets.len);
        if (mode == 0 or mode == 1) try std.testing.expectEqual(@as(u64, 0), endpoint.instruments.broadcast_exceptions.value());
        if (mode == 2) try std.testing.expectEqual(@as(u64, 1), endpoint.instruments.broadcast_exceptions.value());
        for (receipts, expected) |receipt, mask| {
            const accepted = batch.accepted(receipt);
            for (mask, 0..) |included, index| try std.testing.expectEqual(included, accepted.contains(index));
        }
        for (endpoint.credit, remaining) |*credit, wanted| try std.testing.expectEqual(wanted, credit.load(.acquire) & (service_module.Service.active - 1));
        batch.cancel();
        var packets: usize = 0;
        for (expected) |mask| {
            if (std.mem.indexOfScalar(bool, &mask, true) == null) continue;
            const packet = endpoint.output.takeReady() orelse return error.MissingBroadcast;
            var actual: [connections]bool = @splat(false);
            var recipient_iterator = packet.recipients.iterator();
            while (recipient_iterator.next()) |handle| {
                try std.testing.expect(!actual[handle.index]);
                actual[handle.index] = true;
            }
            try std.testing.expectEqualSlices(bool, &mask, &actual);
            endpoint.recycle(std.testing.io, &.{packet});
            packets += 1;
        }
        try std.testing.expect(endpoint.output.takeReady() == null);
        try std.testing.expect(packets > 0);
    }
}

test "a send short of credit waits for a client that reads, and backpressures only one that stopped" {
    var hooks: Hooks = .{};
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .capacity = 16 });
    defer registry.deinit();
    const endpoint = try service_module.Service.init(std.testing.allocator, std.testing.io, transport(&hooks), .{ .metrics = &registry, .connections = 2, .credit_bytes = 512, .pages = 4, .page_bytes = 128, .protocols = &protocols.values, .max_input_bytes = 509 });
    defer endpoint.deinit();
    const handle: network.Handle = .{ .index = 0, .generation = 1 };
    const Service = service_module.Service;
    endpoint.credit[0].store(@as(u64, 1) << 32 | Service.active, .release);
    endpoint.concurrent.store(true, .release);
    defer endpoint.concurrent.store(false, .release);
    // As the worker does for a client that reads: credit back soon after the send asks.
    const Reader = struct {
        fn run(service: *Service) void {
            std.Io.sleep(std.testing.io, .fromNanoseconds(100 * std.time.ns_per_us), .awake) catch {};
            service.refund(.{ .index = 0, .generation = 1 }, 200);
        }
    };
    const reader = try std.Thread.spawn(.{}, Reader.run, .{endpoint});
    endpoint.publication.lockUncancelable(std.testing.io);
    const came = endpoint.awaitCreditLocked(handle, 200);
    endpoint.publication.unlock(std.testing.io);
    reader.join();
    try std.testing.expect(came);
    try std.testing.expectEqual(@as(u64, 1), endpoint.instruments.credit_waits.value());
    try std.testing.expect(endpoint.mayWait(handle));
    // Nothing more comes back: the client stopped reading, so the send gives up, once a tick.
    endpoint.credit[0].store(@as(u64, 1) << 32 | Service.active, .release);
    endpoint.publication.lockUncancelable(std.testing.io);
    try std.testing.expect(!endpoint.awaitCreditLocked(handle, 200));
    endpoint.publication.unlock(std.testing.io);
    try std.testing.expectEqual(@as(u64, 1), endpoint.instruments.slow_clients.value());
    try std.testing.expect(!endpoint.mayWait(handle));
    endpoint.publication.lockUncancelable(std.testing.io);
    try std.testing.expect(!endpoint.awaitCreditLocked(handle, 200));
    endpoint.publication.unlock(std.testing.io);
    try std.testing.expectEqual(@as(u64, 1), endpoint.instruments.slow_clients.value());
    // It lags this tick and the next, as game state learns of it, then no longer: a tick moves
    // the epoch on twice. A new tick lets it wait again.
    try std.testing.expect(endpoint.lagging(handle));
    endpoint.epoch.store(endpoint.epoch.load(.acquire) + 2, .release);
    try std.testing.expect(endpoint.lagging(handle) and endpoint.mayWait(handle));
    endpoint.epoch.store(endpoint.epoch.load(.acquire) + 2, .release);
    try std.testing.expect(!endpoint.lagging(handle));
    try std.testing.expect(!endpoint.lagging(.{ .index = 1, .generation = 1 }));
    // Without a worker of its own, nothing would give credit back, so nothing waits.
    endpoint.concurrent.store(false, .release);
    try std.testing.expect(!endpoint.mayWait(.{ .index = 1, .generation = 1 }));
    endpoint.credit[0].store(0, .release);
}

test "small packets for one audience pack into one buffer charged what they take on the wire" {
    const Version = struct {
        pub const protocol_number = 1;
    };
    const Encoder = struct {
        pub fn writeGroup(comptime _: type, buffers: []const []u8, lengths: []usize, arguments: anytype) !void {
            for (buffers, lengths, 0..) |buffer, *length, index| {
                length.* = arguments[0] + index;
                @memset(buffer[0..length.*], @intCast(arguments[1]));
            }
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var hooks: Hooks = .{};
    // Frames that add four bytes at most without compressing, as Minecraft's.
    const plain = [1]protocol.Protocol{.{ .number = 1, .frame_bound = .{ .plain_overhead = 4 } }};
    const endpoint = try service_module.Service.init(allocator, std.testing.io, transport(&hooks), .{ .connections = 2, .pages = 8, .page_bytes = 4096, .credit_bytes = 64 * 1024, .protocols = &plain, .compression_threshold = 256 });
    defer endpoint.deinit();
    var batch = try service_module.Service.Broadcast.init(allocator, endpoint, 64);
    defer batch.deinit();
    var targets: [2]service_module.Service.Target = undefined;
    for (&targets, 0..) |*target, index| {
        target.* = .{ .handle = .{ .index = @intCast(index), .generation = 1 }, .protocol = 1 };
        endpoint.credit[index].store(@as(u64, 1) << 32 | service_module.Service.active | endpoint.config.credit_bytes, .release);
    }
    try batch.begin(&targets);
    var receipts: [20]service_module.Service.Broadcast.Receipt = undefined;
    var bound: usize = 0;
    for (&receipts, 0..) |*receipt, index| {
        // Movement alone, then a spawn and its data, which go together.
        if (index % 2 == 0) {
            receipt.* = try batch.write(.{Version}, Encoder, null, null, .{ 10, index }, 32);
            bound += 10 + 4;
        } else {
            receipt.* = try batch.writeGroup(.{Version}, Encoder, null, null, .{ 20, index }, &.{ 64, 64 });
            bound += 20 + 4 + 21 + 4;
        }
    }
    batch.commit();
    for (receipts) |receipt| {
        const accepted = batch.accepted(receipt);
        try std.testing.expect(accepted.contains(0) and accepted.contains(1));
    }
    // One packet of every piece, charged their frames together, far less than a bound each.
    const packet = endpoint.output.takeReady() orelse return error.MissingBroadcast;
    try std.testing.expectEqual(@as(u16, 30), packet.group.pieces);
    try std.testing.expectEqual(bound, packet.group.bytes);
    try std.testing.expect(endpoint.output.takeReady() == null);
    for (endpoint.credit[0..2]) |*credit| try std.testing.expectEqual(endpoint.config.credit_bytes - bound, credit.load(.acquire) & (service_module.Service.active - 1));
    endpoint.recycle(std.testing.io, &.{packet});
    batch.cancel();
}

test "broadcast groups retain independent protocol admission across audience reuse" {
    const One = struct {
        pub const protocol_number = 1;
    };
    const Two = struct {
        pub const protocol_number = 2;
    };
    const Encoder = struct {
        pub fn writeGroup(comptime Version: type, buffers: []const []u8, lengths: []usize, _: void) !void {
            for (buffers, lengths) |buffer, *length| {
                buffer[0] = Version.protocol_number;
                length.* = 1;
            }
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var hooks: Hooks = .{};
    const selected = [_]protocol.Protocol{ .{ .number = 1 }, .{ .number = 2 } };
    const endpoint = try service_module.Service.init(allocator, std.testing.io, transport(&hooks), .{ .connections = 4, .pages = 16, .page_bytes = 64, .credit_bytes = 4096, .protocols = &selected });
    defer endpoint.deinit();
    var batch = try service_module.Service.Broadcast.init(allocator, endpoint, 16);
    defer batch.deinit();
    var targets: [4]service_module.Service.Target = undefined;
    for (&targets, 0..) |*target, index| {
        target.* = .{ .handle = .{ .index = @intCast(index), .generation = 1 }, .protocol = 1 + @as(i32, @intCast(index % 2)) };
        const credit = if (index == 2) 2 * endpoint.framedBound(1) - 1 else endpoint.config.credit_bytes;
        endpoint.credit[index].store(@as(u64, 1) << 32 | service_module.Service.active | credit, .release);
    }
    try batch.begin(&targets);
    const group = try batch.writeGroup(.{ One, Two }, Encoder, targets[0].handle, null, {}, &.{ 8, 8 });
    batch.commit();
    // One recipient short of room, and one excluded: what each packet reached must be asked.
    try std.testing.expect(!batch.wentWhole());
    try std.testing.expectEqual(@as(usize, 10), batch.accepted(group).words[0]);
    const dependent = try batch.write(.{ One, Two }, Encoder, targets[1].handle, group, {}, 8);
    batch.finish();
    try std.testing.expectEqual(@as(usize, 8), batch.accepted(dependent).words[0]);
    targets[1].handle.generation = 2;
    endpoint.credit[1].store(@as(u64, 2) << 32 | service_module.Service.active | endpoint.config.credit_bytes, .release);
    try batch.begin(targets[1..2]);
    const next = try batch.write(.{ One, Two }, Encoder, null, null, {}, 8);
    batch.finish();
    // Its one recipient had room: the packet went whole, as `accepted` agrees.
    try std.testing.expect(batch.wentWhole());
    try std.testing.expectEqual(@as(usize, 2), batch.accepted(next).words[0]);
    // Its one recipient has no room at all: nothing is written for its protocol, and the batch
    // did not go whole, as `accepted` agrees.
    endpoint.credit[1].store(@as(u64, 2) << 32 | service_module.Service.active, .release);
    try batch.begin(targets[1..2]);
    const starved = try batch.write(.{ One, Two }, Encoder, null, null, {}, 8);
    batch.finish();
    try std.testing.expect(!batch.wentWhole());
    try std.testing.expectEqual(@as(usize, 0), batch.accepted(starved).words[0]);
    endpoint.credit[1].store(@as(u64, 2) << 32 | service_module.Service.active | endpoint.config.credit_bytes, .release);
    var packets: usize = 0;
    while (endpoint.output.takeReady()) |packet| {
        if (packets < 2) {
            try std.testing.expectEqual(@as(u8, 2), packet.group.count);
            try std.testing.expectEqual(@as(u8, @intCast(packets)), packet.group.index);
            try std.testing.expect(packet.recipients.eqlSlice(&.{ .{ .index = 1, .generation = 1 }, .{ .index = 3, .generation = 1 } }));
        } else if (packets == 2) {
            try std.testing.expect(packet.recipients.eqlSlice(&.{.{ .index = 3, .generation = 1 }}));
        } else {
            try std.testing.expectEqual(@as(usize, 3), packets);
            try std.testing.expect(packet.recipients.eqlSlice(&.{.{ .index = 1, .generation = 2 }}));
        }
        endpoint.recycle(std.testing.io, &.{packet});
        packets += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), packets);
}

test "broadcast rejects stale epochs generations transfers and unsupported encodings" {
    const Version = struct {
        pub const protocol_number = 1;
    };
    const Encoder = struct {
        pub fn writeGroup(comptime _: type, buffers: []const []u8, lengths: []usize, arguments: anytype) !void {
            if (arguments[0]) return error.UnsupportedEncoding;
            buffers[0][0] = 1;
            lengths[0] = 1;
        }
    };
    for (0..4) |mode| {
        var hooks: Hooks = .{};
        const endpoint = try service_module.Service.init(std.testing.allocator, std.testing.io, transport(&hooks), .{ .connections = 2, .pages = 2, .page_bytes = 64, .credit_bytes = 1024, .protocols = &protocols.values });
        defer endpoint.deinit();
        var batch = try service_module.Service.Broadcast.init(std.testing.allocator, endpoint, 2);
        defer batch.deinit();
        const targets = [_]service_module.Service.Target{
            .{ .handle = .{ .index = 0, .generation = 1 }, .protocol = 1 },
            .{ .handle = .{ .index = 1, .generation = 1 }, .protocol = 1 },
        };
        for (endpoint.credit) |*credit| credit.store(@as(u64, 1) << 32 | service_module.Service.active | 1024, .release);
        try batch.begin(&targets);
        const receipt = try batch.write(.{Version}, Encoder, null, null, .{mode == 3}, 8);
        switch (mode) {
            0 => endpoint.beginTick(),
            1 => endpoint.credit[0].store(@as(u64, 2) << 32 | service_module.Service.active | 1024, .release),
            2 => endpoint.moves[0].state.store(.committed, .release),
            else => {},
        }
        batch.finish();
        const accepted: usize = if (mode == 1 or mode == 2) 2 else 0;
        try std.testing.expectEqual(accepted, batch.accepted(receipt).words[0]);
        try std.testing.expectEqual(@as(usize, if (mode == 3) 3 else 0), batch.unsupported(receipt).words[0]);
        if (mode == 0) endpoint.endTick(false);
        if (mode == 2) endpoint.moves[0].state.store(.idle, .release);
        try std.testing.expectEqual(@as(u64, 1024), endpoint.credit[0].load(.acquire) & (service_module.Service.active - 1));
        if (accepted != 0) {
            const packet = endpoint.output.takeReady() orelse return error.MissingBroadcast;
            try std.testing.expect(packet.recipients.eqlSlice(&.{targets[1].handle}));
            endpoint.recycle(std.testing.io, &.{packet});
        }
        try std.testing.expect(endpoint.output.takeReady() == null);
    }
}

test "broadcast pressure commits complete packets without waiting or publishing partial groups" {
    const Version = struct {
        pub const protocol_number = 1;
    };
    const Encoder = struct {
        pub fn writeGroup(comptime _: type, buffers: []const []u8, lengths: []usize, _: void) !void {
            for (buffers, lengths) |bytes, *length| {
                bytes[0] = 1;
                length.* = 1;
            }
        }
    };
    var hooks: Hooks = .{};
    const endpoint = try service_module.Service.init(std.testing.allocator, std.testing.io, transport(&hooks), .{ .connections = 1, .pages = 1, .page_bytes = 64, .credit_bytes = 1024, .protocols = &protocols.values });
    defer endpoint.deinit();
    var batch = try service_module.Service.Broadcast.init(std.testing.allocator, endpoint, 4);
    defer batch.deinit();
    const targets = [_]service_module.Service.Target{.{ .handle = .{ .index = 0, .generation = 1 }, .protocol = 1 }};
    endpoint.credit[0].store(@as(u64, 1) << 32 | service_module.Service.active | 1024, .release);
    try batch.begin(&targets);
    const first = try batch.write(.{Version}, Encoder, null, null, {}, 8);
    const blocked = try batch.write(.{Version}, Encoder, null, first, {}, 8);
    batch.finish();
    try std.testing.expectEqual(@as(usize, 1), batch.accepted(first).words[0]);
    try std.testing.expectEqual(@as(usize, 0), batch.accepted(blocked).words[0]);
    const packet = endpoint.output.takeReady() orelse return error.MissingBroadcast;
    endpoint.recycle(std.testing.io, &.{packet});
    try batch.begin(&targets);
    const group = try batch.writeGroup(.{Version}, Encoder, null, null, {}, &.{ 8, 8 });
    batch.finish();
    try std.testing.expectEqual(@as(usize, 0), batch.accepted(group).words[0]);
    try std.testing.expect(endpoint.output.takeReady() == null);
    try std.testing.expectEqual(@as(u64, 1024 - endpoint.framedBound(1)), endpoint.credit[0].load(.acquire) & (service_module.Service.active - 1));
}

test "broadcast admission and delivery retain connection indexes beyond sixteen bits" {
    const Version = struct {
        pub const protocol_number = 1;
    };
    const Encoder = struct {
        pub fn writeGroup(comptime _: type, buffers: []const []u8, lengths: []usize, _: void) !void {
            buffers[0][0] = 42;
            lengths[0] = 1;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var hooks: Hooks = .{};
    const endpoint = try service_module.Service.init(allocator, std.testing.io, transport(&hooks), .{ .connections = 65_537, .pages = 2, .page_bytes = 64, .credit_bytes = 1024, .protocols = &protocols.values });
    defer endpoint.deinit();
    var batch = try service_module.Service.Broadcast.init(allocator, endpoint, 1);
    defer batch.deinit();
    const handle: network.Handle = .{ .index = 65_536, .generation = 1 };
    endpoint.credit[handle.index].store(@as(u64, 1) << 32 | service_module.Service.active | 1024, .release);
    try batch.begin(&.{.{ .handle = handle, .protocol = 1 }});
    const receipt = try batch.write(.{Version}, Encoder, null, null, {}, 8);
    batch.finish();
    const accepted = batch.accepted(receipt);
    try std.testing.expect(accepted.contains(handle.index));
    try std.testing.expectEqual(@as(usize, 1), accepted.count());
    try std.testing.expect(!batch.unsupported(receipt).any());
    const packet = endpoint.output.takeReady() orelse return error.MissingBroadcast;
    try std.testing.expect(packet.recipients.eqlSlice(&.{handle}));
    endpoint.recycle(std.testing.io, &.{packet});
}

test "broadcast mask history exhaustion refunds credits and preserves earlier receipts" {
    const Version = struct {
        pub const protocol_number = 1;
    };
    const Encoder = struct {
        pub fn writeGroup(comptime _: type, buffers: []const []u8, lengths: []usize, _: void) !void {
            buffers[0][0] = 1;
            lengths[0] = 1;
        }
    };
    var hooks: Hooks = .{};
    const endpoint = try service_module.Service.init(std.testing.allocator, std.testing.io, transport(&hooks), .{ .connections = 3, .pages = 2, .page_bytes = 64, .credit_bytes = 1024, .protocols = &protocols.values });
    defer endpoint.deinit();
    var batch = try service_module.Service.Broadcast.init(std.testing.allocator, endpoint, 4);
    defer batch.deinit();
    defer if (batch.active) batch.cancel();
    const targets = [_]service_module.Service.Target{
        .{ .handle = .{ .index = 0, .generation = 1 }, .protocol = 1 },
        .{ .handle = .{ .index = 1, .generation = 1 }, .protocol = 1 },
        .{ .handle = .{ .index = 2, .generation = 1 }, .protocol = 1 },
    };
    for (endpoint.credit) |*credit| credit.store((@as(u64, 1) << 32) | service_module.Service.active | 1024, .release);
    try batch.begin(&targets);
    var receipts: [3]service_module.Service.Broadcast.Receipt = undefined;
    for (&receipts, 0..) |*receipt, selected| {
        for (endpoint.credit, 0..) |*credit, index| credit.store((@as(u64, 1) << 32) | service_module.Service.active | @as(u64, if (index == selected) 1024 else 0), .release);
        receipt.* = try batch.write(.{Version}, Encoder, null, null, {}, 8);
        batch.commit();
        if (selected < 2) {
            try std.testing.expectEqual(@as(usize, 1), batch.accepted(receipt.*).count());
            try std.testing.expect(batch.accepted(receipt.*).contains(selected));
        } else {
            try std.testing.expect(!batch.accepted(receipt.*).any());
            try std.testing.expectEqual(@as(usize, 1024), endpoint.outputCredit(targets[selected].handle));
        }
        while (endpoint.output.takeReady()) |packet| endpoint.recycle(std.testing.io, &.{packet});
    }
    try std.testing.expect(batch.accepted(receipts[0]).contains(0));
    try std.testing.expect(batch.accepted(receipts[1]).contains(1));
    batch.finish();
    try batch.begin(&targets);
    const retried = try batch.write(.{Version}, Encoder, null, null, {}, 8);
    batch.finish();
    try std.testing.expect(batch.accepted(retried).contains(2));
    while (endpoint.output.takeReady()) |packet| endpoint.recycle(std.testing.io, &.{packet});
}

test "compact broadcasts retain sparse handles generations and receipt coordinates" {
    const One = struct {
        pub const protocol_number = 1;
    };
    const Two = struct {
        pub const protocol_number = 2;
    };
    const Encoder = struct {
        pub fn writeGroup(comptime Version: type, buffers: []const []u8, lengths: []usize, _: void) !void {
            for (buffers, lengths) |bytes, *length| {
                bytes[0] = Version.protocol_number;
                length.* = 1;
            }
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = failing.allocator();
    var hooks: Hooks = .{};
    const selected = [_]protocol.Protocol{ .{ .number = 1 }, .{ .number = 2 } };
    const endpoint = try service_module.Service.init(allocator, std.testing.io, transport(&hooks), .{ .connections = 65_537, .pages = 10, .page_bytes = 64, .credit_bytes = 4096, .protocols = &selected });
    defer endpoint.deinit();
    var batch = try service_module.Service.Broadcast.init(allocator, endpoint, 8);
    defer batch.deinit();
    var targets: [65]service_module.Service.Target = undefined;
    for (&targets, 0..) |*target, index| {
        target.* = .{ .handle = .{ .index = if (index == 0) 65_536 else index, .generation = 1 }, .protocol = 1 + @as(i32, @intCast(index % 2)) };
        endpoint.credit[target.handle.index].store((@as(u64, 1) << 32) | service_module.Service.active | 4096, .release);
    }
    failing.fail_index = failing.alloc_index;
    try batch.begin(&targets);
    try std.testing.expectEqual(@as(usize, 2), batch.words);
    const audience = batch.audience.?;
    try std.testing.expect(batch.audience_handles.ptr == audience.pool.audience_handles[audience.index * audience.pool.recipients_per_page ..].ptr);
    try std.testing.expectEqual(targets.len, audience.pool.audiences[audience.index].length);
    const first = try batch.write(.{ One, Two }, Encoder, targets[0].handle, null, {}, 8);
    const other = try batch.write(.{ One, Two }, Encoder, targets[1].handle, null, {}, 8);
    batch.finish();
    try std.testing.expectEqual(@as(usize, 64), batch.accepted(other).count());
    try std.testing.expect(batch.accepted(other).contains(65_536));
    try std.testing.expect(!batch.accepted(other).contains(1));
    const accepted = batch.accepted(first);
    try std.testing.expectEqual(@as(usize, 64), accepted.count());
    try std.testing.expect(!accepted.contains(65_536));
    try std.testing.expect(accepted.contains(1) and accepted.contains(64));
    const next_targets = [_]service_module.Service.Target{
        .{ .handle = .{ .index = 65_536, .generation = 2 }, .protocol = 2 },
        .{ .handle = .{ .index = 3, .generation = 1 }, .protocol = 2 },
        .{ .handle = .{ .index = 0, .generation = 2 }, .protocol = 1 },
    };
    for (next_targets) |target| endpoint.credit[target.handle.index].store((@as(u64, target.handle.generation) << 32) | service_module.Service.active | 4096, .release);
    try batch.begin(&next_targets);
    try std.testing.expectEqual(@as(usize, 1), batch.words);
    const group = try batch.writeGroup(.{ One, Two }, Encoder, next_targets[0].handle, null, {}, &.{ 8, 8 });
    batch.commit();
    try std.testing.expectEqual(@as(usize, 2), batch.accepted(group).count());
    try std.testing.expect(batch.accepted(group).contains(0) and batch.accepted(group).contains(3));
    const dependent = try batch.write(.{ One, Two }, Encoder, next_targets[1].handle, group, {}, 8);
    batch.finish();
    try std.testing.expectEqual(@as(usize, 1), batch.accepted(dependent).count());
    try std.testing.expect(batch.accepted(dependent).contains(0));
    endpoint.flush();
    var queued = endpoint.outputBatch();
    var count: usize = 0;
    while (queued.next()) |packet| {
        if (count < 4) {
            try std.testing.expectEqual(targets.len, packet.recipients.handles.len);
            try std.testing.expectEqual(@as(u32, 1), packet.recipients.handles[0].generation);
        } else {
            try std.testing.expectEqual(next_targets.len, packet.recipients.handles.len);
            try std.testing.expectEqual(@as(u32, 2), packet.recipients.handles[0].generation);
        }
        try std.testing.expectEqual((packet.recipients.handles.len + 63) / 64, packet.recipients.mask.len);
        endpoint.recycle(std.testing.io, &.{packet});
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 9), count);
    try std.testing.expectEqual(next_targets[0].handle, batch.handleAt(65_536));
    const Unsupported = struct {
        pub fn writeGroup(comptime _: type, _: []const []u8, _: []usize, _: void) !void {
            return error.UnsupportedEncoding;
        }
    };
    try batch.begin(&next_targets);
    const rejected = try batch.write(.{Two}, Unsupported, null, null, {}, 8);
    batch.finish();
    const unavailable = batch.unsupported(rejected);
    try std.testing.expectEqual(@as(usize, 2), unavailable.count());
    try std.testing.expect(unavailable.contains(65_536) and unavailable.contains(3));
    try std.testing.expectEqual(next_targets[0].handle, batch.handleAt(65_536));
    try std.testing.expectEqual(next_targets[1].handle, batch.handleAt(3));
    try batch.begin(next_targets[0..1]);
    const excluded = try batch.write(.{Two}, Unsupported, next_targets[0].handle, null, {}, 8);
    const included = try batch.write(.{Two}, Unsupported, null, null, {}, 8);
    batch.finish();
    try std.testing.expect(!batch.unsupported(excluded).any());
    try std.testing.expectEqual(@as(usize, 1), batch.unsupported(included).count());
    try std.testing.expect(batch.unsupported(included).contains(65_536));
    try std.testing.expect(!batch.unsupported(excluded).any());
}

test "failed and empty broadcast capture release audience reservations" {
    var hooks: Hooks = .{};
    const endpoint = try createEndpoint(std.testing.allocator, &hooks);
    defer endpoint.deinit();
    var batch = try service_module.Service.Broadcast.init(std.testing.allocator, endpoint, 1);
    defer batch.deinit();
    const targets = [_]service_module.Service.Target{
        .{ .handle = .{ .index = 1, .generation = 1 }, .protocol = 1 },
        .{ .handle = .{ .index = 0, .generation = 1 }, .protocol = -1 },
    };
    try std.testing.expectError(error.UnsupportedProtocol, batch.begin(&targets));
    try std.testing.expectEqual(endpoint.output.pool.audiences.len, endpoint.output.pool.free_audiences.count());
    try batch.begin(targets[0..1]);
    batch.cancel();
    try batch.begin(&.{});
    batch.finish();
    try std.testing.expectEqual(endpoint.output.pool.audiences.len, endpoint.output.pool.free_audiences.count());
}

test "prepared publications charge decoded capacity through cancellation batching and groups" {
    var hooks: Hooks = .{};
    const endpoint = try createEndpoint(std.testing.allocator, &hooks);
    defer endpoint.deinit();
    const handle: network.Handle = .{ .index = 0, .generation = 1 };
    for (0..3) |mode| {
        endpoint.credit[0].store(@as(u64, 1) << 32 | service_module.Service.active | 512, .release);
        var packet = try endpoint.reserve(128);
        @memset(packet.bytes[0..8], 37);
        packet.prepare(100);
        if (mode == 0) {
            var credits = endpoint.reserveRecipients(&.{packet}, &.{handle});
            credits.finish(&packet, handle, 8);
            credits.release();
            packet.cancel();
            try std.testing.expectEqual(@as(usize, 512), endpoint.outputCredit(handle));
            continue;
        }
        if (mode == 1) {
            var recipients = [_]network.Handle{handle};
            var accepted: [1]usize = undefined;
            endpoint.publishManyReady(&.{.{ .packet = &packet, .length = 8, .recipients = &recipients }}, &accepted);
            try std.testing.expectEqual(@as(usize, 1), accepted[0]);
        } else {
            var result = [_]service_module.Service.Delivery{.backpressured};
            endpoint.publishGroups(&.{.{ .packets = &.{.{ .packet = &packet, .length = 8 }}, .protocol = 1, .targets = &.{.{ .handle = handle, .protocol = 1 }}, .delivered = &result }});
            try std.testing.expectEqual(service_module.Service.Delivery.queued, result[0]);
        }
        endpoint.flush();
        var batch = endpoint.outputBatch();
        const published = batch.next().?;
        try std.testing.expectEqual(@as(usize, 8), published.bytes.len);
        try std.testing.expectEqual(@as(usize, 100), published.decoded_length);
        try std.testing.expectEqual(@as(usize, 512 - endpoint.framedBound(100)), endpoint.outputCredit(handle));
        endpoint.refund(handle, endpoint.framedBound(published.boundLength()));
        endpoint.recycle(std.testing.io, &.{published});
        try std.testing.expect(batch.next() == null);
        try std.testing.expectEqual(@as(usize, 512), endpoint.outputCredit(handle));
    }
}

test "input lent before a tick grows until the tick takes it" {
    var hooks: Hooks = .{};
    const endpoint = try createEndpoint(std.testing.allocator, &hooks);
    defer endpoint.deinit();
    const packets = [_][]const u8{ "move", "end", "use", "late" };
    try std.testing.expect(endpoint.push(.{ .input = .{ .handle = .{ .index = 0, .generation = 1 }, .protocol = 1, .packets = .{ .packets = packets[0..2] } } }));
    // An action arriving before the tick joins the batch already waiting.
    try std.testing.expect(endpoint.extendInput(0, 3));
    endpoint.beginTick();
    // Once the tick holds the batch, it grows no more: what comes next waits for it.
    try std.testing.expect(!endpoint.extendInput(0, 4));
    var seen: usize = 0;
    for (endpoint.input_events) |event| {
        var incoming = event.input.packets;
        while (try incoming.next()) |packet| {
            try std.testing.expectEqual(packets[seen].ptr, packet.ptr);
            seen += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
    endpoint.endTick(true);
    try std.testing.expectEqual(@as(u32, 1), endpoint.releases[0].swap(0, .acquire));
    try std.testing.expect(!endpoint.extendInput(0, 4));
}

test "a prepared packet is charged the frame it goes out as" {
    var endpoint: service_module.Service = undefined;
    endpoint.config = .{ .protocols = &.{}, .compression_threshold = 256 };
    // Compressed at its size, a prepared packet goes out as stored.
    try std.testing.expectEqual(@as(usize, 300), endpoint.chargedLength(300, 4000));
    // Below the threshold, or with compression off, it goes out decoded.
    try std.testing.expectEqual(@as(usize, 200), endpoint.chargedLength(100, 200));
    endpoint.config.compression_threshold = null;
    try std.testing.expectEqual(@as(usize, 4000), endpoint.chargedLength(300, 4000));
    // A packet that is not prepared goes out as its bytes, compressed or not.
    try std.testing.expectEqual(@as(usize, 300), endpoint.chargedLength(300, 0));
}
