const std = @import("std");
const commands = @import("commands");
const sessions = @import("sessions");
const protocols = @import("protocols");
const packets = @import("minecraft_packets");
const Players = @import("players.zig").Players;
const Chat = @import("chat.zig").Chat;
const Input = @import("input.zig").Input;
const dispatch = @import("commands.zig");
const Probe = struct {
    calls: usize = 0,
    allowed: bool = true,
    denied: ?u128 = null,
    executions: usize = 0,
    const Args = struct {};
    const permission: commands.Permission = .{ .name = "test.use", .description = "Test permission" };
    fn allows(self: *@This(), uuid: u128, _: *const commands.Permission) bool {
        self.calls += 1;
        return self.allowed and self.denied != uuid;
    }
    fn execute(self: *@This(), _: commands.Context, _: Args) !void {
        self.executions += 1;
    }
    fn reply(_: *@This(), _: []const u8) void {}
};
test "command visibility caches policy decisions and retries publication without rebuilding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = failing.allocator();
    var probe: Probe = .{};
    const tree = try commands.Commands.init(allocator, .{ .maximum_nodes = 256, .permission_policy = commands.Policy.init(&probe, Probe.allows) });
    const root = try tree.literal(.{ .name = "root", .permission = &Probe.permission });
    for (0..64) |i| {
        var name: [32]u8 = undefined;
        const leaf = try root.literal(.{ .name = try std.fmt.bufPrint(&name, "leaf{d}", .{i}) });
        _ = try leaf.add(&probe, commands.leaf(Probe, Probe.Args, .{ .name = "run", .description = "Test command", .handler = Probe.execute, .arguments = .{} }));
    }
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const service = try sessions.Service.init(allocator, std.testing.io, undefined, .{ .connections = 64, .pages = 128, .page_bytes = 65536, .buffer_bytes = 1024 * 1024, .protocols = &selected });
    const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
    var records: [64]Players.Player = undefined;
    for (&records, 0..) |*player, i| {
        player.* = .{ .handle = .{ .index = @intCast(i), .generation = 1 }, .uuid = i + 1, .protocol = selected[0].number, .stage = .ready };
        service.credit[i].store(@as(u64, 1) << 32 | sessions.Service.active | service.config.buffer_bytes, .release);
    }
    var players: Players = .{ .deps = undefined, .config = .{ .maximum = 64 }, .spawn_world = 0, .records = &records, .dig_handlers = &.{} };
    try players.initIndexes(allocator);
    players.rebuildIndexes();
    const chat = try Chat.init(allocator, .{ .players = &players, .sessions = service, .packets = encoding }, .{});
    const input = try Input.init(allocator, .{ .sessions = service });
    const plugin = try dispatch.CommandDispatch.init(allocator, .{ .commands = tree, .players = &players, .chat = chat, .input = input, .sessions = service, .packets = encoding }, .{});
    const Drain = struct {
        fn run(endpoint: *sessions.Service) !usize {
            var count: usize = 0;
            while (endpoint.output.takeReady()) |packet| {
                try std.testing.expect(endpoint.output.releaseReady(packet.page, packet.generation));
                _ = endpoint.preparing.fetchSub(1, .release);
                count += 1;
            }
            return count;
        }
    };
    failing.fail_index = failing.alloc_index;
    try plugin.tick();
    try std.testing.expectEqual(@as(usize, 1), try Drain.run(service));
    probe.calls = 0;
    for (0..64) |_| {
        try plugin.tick();
        try std.testing.expectEqual(@as(usize, 0), try Drain.run(service));
    }
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    probe.allowed = false;
    const context: commands.Context = .{ .sender = 1, .output = commands.Reply.init(&probe, Probe.reply) };
    try tree.execute(context, "root leaf0 run");
    try std.testing.expectEqual(@as(usize, 0), probe.executions);
    tree.permissionsChanged();
    probe.calls = 0;
    try plugin.tick();
    try std.testing.expectEqual(@as(usize, 64), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), try Drain.run(service));
    probe.allowed = true;
    tree.permissionsChanged();
    for (service.credit) |*credit| credit.store(@as(u64, 1) << 32 | sessions.Service.active, .release);
    probe.calls = 0;
    try plugin.tick();
    try std.testing.expectEqual(@as(usize, 64), probe.calls);
    try std.testing.expectEqual(@as(usize, 0), try Drain.run(service));
    probe.calls = 0;
    for (0..64) |_| try plugin.tick();
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    for (service.credit) |*credit| credit.store(@as(u64, 1) << 32 | sessions.Service.active | service.config.buffer_bytes, .release);
    try plugin.tick();
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), try Drain.run(service));
    try tree.execute(context, "root leaf0 run");
    try std.testing.expectEqual(@as(usize, 1), probe.executions);
    records[0].handle.?.generation += 1;
    service.credit[0].store(@as(u64, 2) << 32 | sessions.Service.active | service.config.buffer_bytes, .release);
    probe.calls = 0;
    try plugin.tick();
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), try Drain.run(service));
    probe.calls = 0;
    records[0].life += 1;
    try plugin.tick();
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), try Drain.run(service));
    probe.denied = records[1].uuid;
    tree.permissionsChanged();
    for (plugin.states) |*state| state.sent = false;
    try plugin.tick();
    var groups: usize = 0;
    while (service.output.takeReady()) |packet| {
        const restricted = packet.recipients.len == 1;
        try std.testing.expectEqual(if (restricted) @as(usize, 1) else 63, packet.recipients.len);
        var recipient_iterator = packet.recipients.iterator();
        while (recipient_iterator.next()) |handle| try std.testing.expectEqual(restricted, handle.index == 1);
        try std.testing.expect(service.output.releaseReady(packet.page, packet.generation));
        _ = service.preparing.fetchSub(1, .release);
        groups += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), groups);
    probe.allowed = false;
    tree.permissionsChanged();
    service.credit[0].store(@as(u64, 2) << 32 | sessions.Service.active, .release);
    try plugin.tick();
    try std.testing.expectEqual(@as(usize, 1), try Drain.run(service));
    try std.testing.expect(!plugin.states[0].sent);
    for (plugin.states[1..]) |state| try std.testing.expect(state.sent);
    service.credit[0].store(@as(u64, 2) << 32 | sessions.Service.active | service.config.buffer_bytes, .release);
    probe.calls = 0;
    try plugin.tick();
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), try Drain.run(service));
    try std.testing.expect(plugin.states[0].sent);
}

test "input rejection cleanup visits only consumed inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const service = try sessions.Service.init(allocator, std.testing.io, undefined, .{ .connections = 4096, .pages = 2, .page_bytes = 64, .buffer_bytes = 1024, .protocols = &selected });
    defer service.deinit();
    const input = try Input.init(allocator, .{ .sessions = service });
    for (input.rejected) |generation| try std.testing.expectEqual(@as(u32, 0), generation);
    input.rejected[4095] = 7;
    input.rejected[0] = 1;
    const events = [_]sessions.Event{.{ .input = .{ .handle = .{ .index = 0, .generation = 1 }, .protocol = selected[0].number, .packets = .{ .packets = &.{} } } }};
    service.input_events = &events;
    try input.tick(allocator);
    try std.testing.expectEqual(@as(u32, 0), input.rejected[0]);
    try std.testing.expectEqual(@as(u32, 7), input.rejected[4095]);
    service.input_events = &.{};
    try input.tick(allocator);
    try std.testing.expectEqual(@as(u32, 7), input.rejected[4095]);
}
