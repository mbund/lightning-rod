const std = @import("std");
const vanilla = @import("lib.zig");
const sessions = @import("sessions");
const protocols = @import("protocols");

test "environment updates admit healthy clients independently and retry blocked clients" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const selected = [_]sessions.Protocol{.{
        .number = protocols.implementations[0].protocol_number,
        .registries = &.{.{ .name = "minecraft:world_clock", .entries = &.{ "minecraft:overworld", "minecraft:the_end" } }},
    }};
    const service = try sessions.Service.init(allocator, std.testing.io, undefined, .{ .connections = 2, .pages = 128, .page_bytes = 4096, .buffer_bytes = 32768, .protocols = &selected });
    const packets = try vanilla.Packets.init(allocator, .{ .sessions = service });
    const worlds = try vanilla.Worlds.allocate(allocator, .{ .maximum = 1 });
    const world = try worlds.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16, .skylight = true } });
    var records: [2]vanilla.Players.Player = undefined;
    for (&records, 0..) |*player, i| {
        player.* = .{ .handle = .{ .index = @intCast(i), .generation = 1 }, .uuid = i + 1, .world = world, .protocol = selected[0].number, .name = @splat(0), .name_len = 1, .stage = .ready };
        service.credit[i].store(@as(u64, 1) << 32 | sessions.Service.active | service.config.buffer_bytes, .release);
    }
    var players: vanilla.Players = .{ .deps = .{ .sessions = service, .packets = packets, .input = undefined, .storage = undefined, .worlds = worlds, .vanilla_worlds = undefined, .record_workspaces = undefined }, .config = .{ .maximum = 2 }, .spawn_world = world, .records = &records, .dig_handlers = &.{} };
    try players.initIndexes(allocator);
    players.rebuildIndexes();
    const time = try vanilla.Time.allocate(allocator, .{});
    const weather = try vanilla.Weather.allocate(allocator, .{ .weather_cycle = false });
    const environment = try vanilla.Environment.init(allocator, .{ .players = &players, .time = time, .weather = weather });
    const Drain = struct {
        fn run(endpoint: *sessions.Service, expected: []const sessions.Handle) !usize {
            var count: usize = 0;
            while (endpoint.output.takeReady()) |packet| {
                try std.testing.expect(packet.recipients.eqlSlice(expected));
                std.debug.assert(endpoint.output.releaseReady(packet.page, packet.generation));
                _ = endpoint.preparing.fetchSub(1, .release);
                count += 1;
            }
            return count;
        }
    };
    try environment.tick();
    const healthy = try Drain.run(service, &.{ records[0].handle.?, records[1].handle.? });
    try std.testing.expectEqual(@as(usize, 6), healthy);
    const blocked_environment = try vanilla.Environment.init(allocator, .{ .players = &players, .time = time, .weather = weather });
    service.credit[1].store(@as(u64, 1) << 32 | sessions.Service.active, .release);
    var blocked: usize = 0;
    for (0..64) |_| {
        try blocked_environment.tick();
        blocked += try Drain.run(service, &.{records[0].handle.?});
    }
    try std.testing.expectEqual(@as(usize, 9), blocked);
    service.credit[1].store(@as(u64, 1) << 32 | sessions.Service.active | service.config.buffer_bytes, .release);
    try blocked_environment.tick();
    const recovered = try Drain.run(service, &.{records[1].handle.?});
    try std.testing.expectEqual(@as(usize, 6), recovered);
}
