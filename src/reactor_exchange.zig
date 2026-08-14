const std = @import("std");
const abi = @import("hot_reload_abi.zig");
const config = @import("config.zig").value;

pub const Mailbox = struct {
    events: []align(8) u8 = &.{},
    event_bytes: usize = 0,
    commands: []align(8) u8 = &.{},

    pub fn allocate(self: *Mailbox, allocator: std.mem.Allocator) !void {
        self.events = try allocator.alignedAlloc(u8, .@"8", config.tick_event_buffer_bytes);
        self.commands = try allocator.alignedAlloc(u8, .@"8", config.tick_command_buffer_bytes);
        self.event_bytes = 0;
    }

    pub fn begin(
        self: *Mailbox,
        sequence: u64,
        deadline_ns: u64,
        kernel: *const abi.KernelApi,
    ) abi.TickExchange {
        return .{
            .sequence = sequence,
            .monotonic_ns = 0,
            .deadline_ns = deadline_ns,
            .events = .{ .ptr = self.events.ptr, .len = self.event_bytes },
            .commands = .{ .ptr = self.commands.ptr, .len = self.commands.len },
            .kernel = kernel,
        };
    }

    pub fn iterator(_: *Mailbox, exchange: *const abi.TickExchange) !abi.CommandIterator {
        return abi.CommandIterator.init(exchange);
    }

    pub fn finish(self: *Mailbox, exchange: *const abi.TickExchange) void {
        if (exchange.events.ptr != self.events.ptr or exchange.events.len > self.event_bytes)
            return;
        const retained = self.event_bytes - exchange.events.len;
        if (retained != 0) {
            @memmove(
                self.events[0..retained],
                self.events[exchange.events.len..self.event_bytes],
            );
        }
        self.event_bytes = retained;
    }

    pub fn clear(self: *Mailbox) void {
        self.event_bytes = 0;
    }

    pub fn connected(self: *Mailbox, connection: abi.ConnectionHandle) bool {
        return self.writer().connected(connection);
    }

    pub fn disconnected(
        self: *Mailbox,
        connection: abi.ConnectionHandle,
        reason: abi.DisconnectReason,
    ) bool {
        return self.writer().disconnected(connection, reason);
    }

    pub fn rawInput(self: *Mailbox, connection: abi.ConnectionHandle, bytes: []const u8) bool {
        return self.writer().rawInput(connection, bytes);
    }

    pub fn attachedConnection(
        self: *Mailbox,
        connection: abi.ConnectionHandle,
        protocol_number: i32,
        player_uuid: u128,
        name: []const u8,
        phase: abi.ConnectionPhase,
        reconfiguring: bool,
    ) bool {
        return self.writer().attachedConnection(
            connection,
            protocol_number,
            player_uuid,
            name,
            phase,
            reconfiguring,
        );
    }

    pub fn reloadResult(
        self: *Mailbox,
        connection: abi.ConnectionHandle,
        succeeded: bool,
        elapsed_ms: u64,
    ) bool {
        return self.writer().reloadResult(connection, succeeded, elapsed_ms);
    }

    fn writer(self: *Mailbox) abi.EventWriter {
        return .{ .buffer = self.events, .written = &self.event_bytes };
    }
};

test "mailbox retains events appended while the tick is running" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mailbox = Mailbox{};
    try mailbox.allocate(arena.allocator());
    const first = abi.ConnectionHandle{ .index = 1, .generation = 2 };
    const second = abi.ConnectionHandle{ .index = 3, .generation = 4 };
    try std.testing.expect(mailbox.connected(first));
    var exchange = mailbox.begin(0, 0, undefined);
    try std.testing.expect(mailbox.connected(second));
    mailbox.finish(&exchange);
    exchange = mailbox.begin(1, 0, undefined);
    var events = abi.EventIterator.init(&exchange);
    try std.testing.expectEqual(second.value(), (try (try events.next()).?.connected()).connection.value());
    try std.testing.expect((try events.next()) == null);
}
