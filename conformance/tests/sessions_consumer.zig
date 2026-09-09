const std = @import("std");
const lightning_rod = @import("lightning_rod");

test "public Sessions driver owns input pages and isolates status backpressure" {
    var table = lightning_rod.sessions.Table(2, 4){};
    table.initialize();
    const protocols = comptime lightning_rod.protocol_versions.from(.v1_21_8);
    lightning_rod.sessions.Catalog(protocols).install(&table, .{});

    var transport: MemoryTransport = .{};
    transport.initialize();
    var boundary: Boundary = .{};
    var driver = lightning_rod.sessions.Driver.init(
        table.interface(),
        transport.interface(),
        .{ .context = &transport, .vtable = &clock_vtable },
        .{ .context = &transport, .vtable = &status_vtable },
        boundary.interface(),
    );
    const runtime = driver.runtime();
    try std.testing.expectEqual(.ok, runtime.advance());
    try std.testing.expectEqual(.ok, runtime.takeInput());
    try std.testing.expectEqual(.ok, runtime.finishInput());
    transport.queueStatusRequests();
    try std.testing.expectEqual(.ok, runtime.advance());

    try std.testing.expectEqual(@as(i32, 772), table.sessions[0].?.protocol);
    try std.testing.expectEqual(@as(i32, 772), table.sessions[1].?.protocol);
    try std.testing.expectEqual(@as(usize, 4), transport.released_inputs);
    try std.testing.expectEqual(@as(usize, 1), transport.writes);
    try std.testing.expectEqual(@as(usize, 1), transport.sent);
    try std.testing.expect(transport.sent_bytes > 2);
    try std.testing.expect(std.mem.indexOf(u8, transport.output[0..transport.sent_bytes], "{}") != null);
    try std.testing.expectEqual(@as(usize, 0), transport.closed);
    try std.testing.expect(table.sessions[1].?.status_response_pending);
    try std.testing.expectEqual(@as(usize, 1), boundary.published);
    try std.testing.expectEqual(@as(usize, 1), boundary.released_inputs);
}

const MemoryTransport = struct {
    events: [4]lightning_rod.transport.TransportEvent = undefined,
    event_count: usize = 0,
    delivered: bool = false,
    handshake: [17]u8 = .{ 0x10, 0x00, 0x84, 0x06, 0x09, 'l', 'o', 'c', 'a', 'l', 'h', 'o', 's', 't', 0x63, 0xdd, 0x01 },
    status_request: [2]u8 = .{ 0x01, 0x00 },
    output: [1024]u8 = undefined,
    released_inputs: usize = 0,
    writes: usize = 0,
    sent: usize = 0,
    sent_bytes: usize = 0,
    closed: usize = 0,
    closed_connection: lightning_rod.connection.Handle = .{ .index = 0, .generation = 0 },

    fn initialize(self: *MemoryTransport) void {
        const first: lightning_rod.connection.Handle = .{ .index = 0, .generation = 1 };
        const second: lightning_rod.connection.Handle = .{ .index = 1, .generation = 1 };
        self.events = .{
            .{ .accepted = first },
            .{ .received = .{ .connection = first, .page = .{ .id = @enumFromInt(0), .bytes = self.handshake[0..] } } },
            .{ .accepted = second },
            .{ .received = .{ .connection = second, .page = .{ .id = @enumFromInt(1), .bytes = self.handshake[0..] } } },
        };
        self.event_count = self.events.len;
    }

    fn interface(self: *MemoryTransport) lightning_rod.transport.Transport {
        return .{ .context = self, .vtable = &vtable };
    }

    fn queueStatusRequests(self: *MemoryTransport) void {
        self.events = .{
            .{ .received = .{ .connection = .{ .index = 0, .generation = 1 }, .page = .{ .id = @enumFromInt(2), .bytes = self.status_request[0..] } } },
            .{ .received = .{ .connection = .{ .index = 1, .generation = 1 }, .page = .{ .id = @enumFromInt(3), .bytes = self.status_request[0..] } } },
            undefined,
            undefined,
        };
        self.event_count = 2;
        self.delivered = false;
    }

    fn from(raw: *anyopaque) *MemoryTransport {
        return @ptrCast(@alignCast(raw));
    }

    fn complete(raw: *anyopaque, destination: []lightning_rod.transport.TransportEvent) usize {
        const self = from(raw);
        if (self.delivered) return 0;
        self.delivered = true;
        @memcpy(destination[0..self.event_count], self.events[0..self.event_count]);
        return self.event_count;
    }

    fn inputPage(_: *anyopaque, _: lightning_rod.connection.Page) ?lightning_rod.transport.InputPage {
        return null;
    }
    fn outputCredit(_: *anyopaque, connection: lightning_rod.connection.Handle) usize {
        return if (connection.index == 0) 1024 else 0;
    }
    fn outputMetrics(_: *anyopaque, connection: lightning_rod.connection.Handle) ?lightning_rod.transport.OutputMetrics {
        return .{ .queued_bytes = 0, .capacity_bytes = if (connection.index == 0) 1024 else 0 };
    }
    fn releaseInput(raw: *anyopaque, _: lightning_rod.connection.Page) void {
        from(raw).released_inputs += 1;
    }
    fn write(raw: *anyopaque, connection: lightning_rod.connection.Handle, bytes: []const u8) bool {
        const self = from(raw);
        if (connection.index != 0 or bytes.len > self.output.len) return false;
        @memcpy(self.output[0..bytes.len], bytes);
        self.writes += 1;
        self.sent += 1;
        self.sent_bytes = bytes.len;
        return true;
    }
    fn close(raw: *anyopaque, connection: lightning_rod.connection.Handle, _: lightning_rod.connection.DisconnectReason) void {
        const self = from(raw);
        self.closed += 1;
        self.closed_connection = connection;
    }
    fn submit(_: *anyopaque) void {}

    const vtable: lightning_rod.transport.Transport.VTable = .{
        .complete = complete,
        .input_page = inputPage,
        .output_credit = outputCredit,
        .output_metrics = outputMetrics,
        .write = write,
        .release_input = releaseInput,
        .close = close,
        .submit = submit,
    };
};

const Boundary = struct {
    published: usize = 0,
    released_inputs: usize = 0,

    fn interface(self: *Boundary) lightning_rod.sessions.CoreBoundary {
        return .{ .context = self, .vtable = &vtable };
    }
    fn from(raw: *anyopaque) *Boundary {
        return @ptrCast(@alignCast(raw));
    }
    fn publish(raw: *anyopaque, _: lightning_rod.transport.CoreInput) bool {
        from(raw).published += 1;
        return true;
    }
    fn releaseInput(raw: *anyopaque) void {
        from(raw).released_inputs += 1;
    }
    fn playerSession(_: *anyopaque, slot: u16) ?lightning_rod.Session {
        return .{ .slot = slot, .generation = 1 };
    }
    fn connectionForPlayer(_: *anyopaque, player: lightning_rod.Session) ?lightning_rod.connection.Handle {
        return .{ .index = player.slot, .generation = 1 };
    }
    fn packetViews(_: *const anyopaque) []const lightning_rod.core_exchange.PacketView {
        return &.{};
    }
    fn claimPacket(_: *anyopaque, _: lightning_rod.core_exchange.PacketView) lightning_rod.sessions.Claim {
        return .unavailable;
    }
    const vtable: lightning_rod.sessions.CoreBoundary.VTable = .{
        .publish_input = publish,
        .release_input = releaseInput,
        .player_session = playerSession,
        .connection_for_player = connectionForPlayer,
        .packet_views = packetViews,
        .claim_packet = claimPacket,
    };
};

fn now(_: *const anyopaque) u64 {
    return 0;
}
const clock_vtable: lightning_rod.sessions.Clock.VTable = .{ .now_ns = now };
fn snapshot(_: *const anyopaque) lightning_rod.session_api.StatusSnapshot {
    return .{ .revision = 1, .json = "{}" };
}
const status_vtable: lightning_rod.sessions.Status.VTable = .{ .snapshot = snapshot };
