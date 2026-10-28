const std = @import("std");
const chunks = @import("chunks");
const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const worlds = @import("worlds");
const game_data = @import("game_data");
const network = @import("networking");
const sessions = @import("sessions");
const protocols = @import("protocols");
const packets = @import("minecraft_packets");
const Players = @import("players.zig").Players;
const Lighting = @import("lighting.zig").Lighting;
const Streaming = @import("streaming.zig").Streaming;
const BlockSynchronization = @import("block_sync.zig").BlockSynchronization;
const Terrain = @import("terrain.zig").Terrain;

pub const Scene = struct {
    pub fn read(_: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
        for (batch.requests) |*request| {
            if (request.section.y != 4) {
                request.result = chunks.uniform(0, request.output);
                continue;
            }
            request.output[0] = 1;
            for (0..4096) |local| std.mem.writeInt(u16, request.output[1 + local * 2 ..][0..2], state(request.section, local), .little);
            request.result = 8193;
        }
    }

    pub fn state(section: chunks.Section, local: usize) u16 {
        if (section.y != 4) return 0;
        if (local / 256 == 0) return @intCast(game_data.registry.block_stone_default_state);
        const seed = @as(i64, section.x) * 31 + @as(i64, section.z) * 17 + section.world;
        if (local == 8 * 256 + 8 * 16 + 8 and @mod(seed, 3) == 0) return @intCast(game_data.registry.block_glowstone_default_state);
        if (local / 256 == 1 and @mod(seed + @as(i64, @intCast(local)), 7) == 0) return @intCast(game_data.registry.block_glass_default_state);
        return 0;
    }
};

const Sink = struct {
    pub fn notify(_: *Sink, _: std.Io) void {}
    pub fn queueReceive(_: *Sink, _: std.Io, _: network.Handle, _: []u8) network.QueueError!void {
        unreachable;
    }
    pub fn queueSend(_: *Sink, _: std.Io, _: network.Handle, _: []const std.posix.iovec_const) network.QueueError!void {
        unreachable;
    }
    pub fn close(_: *Sink, _: std.Io, _: network.Handle, _: network.CloseReason) void {
        unreachable;
    }
    pub fn releaseConnection(_: *Sink, _: std.Io, _: network.Handle) void {
        unreachable;
    }
    pub fn submit(_: *Sink, _: std.Io) !void {
        unreachable;
    }
    pub fn poll(_: *Sink, _: std.Io, _: ?std.Io.Timeout, _: []network.Event) !usize {
        unreachable;
    }
};

test "lighting load scenarios" {
    const io = std.testing.io;
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    try output.interface.writeAll("Lighting through chunk streaming and block publication. No sockets or scheduler waits.\nplayers layout    sections passes packets deliveries relights decoded retained cpu_ms\n");
    for ([_]usize{ 1, 8, 32 }) |count| for ([_]bool{ false, true }) |spread| for ([_]u16{ 1, 24 }) |section_count| {
        var directory = std.testing.tmpDir(.{});
        defer directory.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/lighting-load", .{directory.sub_path});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const allocator = bounded.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
        defer registry.deinit();
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        const resources = try records.Workspaces.init(allocator, io, .{});
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
        const world = try dimensions.create(.{ .name = "test:lighting", .dimension = .{ .name = "test:dimension", .minimum_section = if (section_count == 1) 4 else -4, .section_count = section_count, .skylight = true } });
        var catalog = try protocols.Default.init(allocator);
        defer catalog.deinit(allocator);
        var sink: Sink = .{};
        const service = try sessions.Service.init(allocator, io, .{ .context = &sink, .vtable = network.Transport.adapter(Sink) }, .{ .connections = count, .pages = 32, .page_bytes = 128 * 1024, .buffer_bytes = 1024 * 1024, .protocols = &catalog.values });
        defer {
            if (service.tick_active) service.endTick(false);
            service.deinit();
        }
        const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
        const player_records = try allocator.alloc(Players.Player, count);
        for (player_records, 0..) |*player, index| {
            const group = if (spread) index % 4 else 0;
            player.* = .{ .handle = .{ .index = index, .generation = 1 }, .uuid = index + 1, .world = world, .stage = .ready, .loaded = true, .position = .{ .x = @as(f64, @floatFromInt(group * 256)), .y = 65, .z = 0 }, .protocol = catalog.values[index % catalog.values.len].number };
            service.credit[index].store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
        }
        var players: Players = .{ .deps = undefined, .config = .{ .maximum = count, .render_distance = 2 }, .spawn_world = world, .records = player_records, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        players.rebuildIndexes();
        const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 48, .demand_sections = 24, .cache_tiles = 4 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = resources });
        var source: Scene = .{};
        terrain.setSource(chunks.Source.init(&source, Scene.read));
        const streaming = try Streaming.init(allocator, io, .{}, .{ .metrics = &registry, .players = &players, .chunks = terrain, .sessions = service, .packets = encoding, .worlds = dimensions, .lighting = try Lighting.init(allocator, .{}, .{ .chunks = terrain, .worlds = dimensions }) });
        defer service.unsubscribeOutput(streaming.changed);
        defer terrain.unsubscribeReady(streaming.changed);
        const blocks = try BlockSynchronization.init(allocator, io, .{ .metrics = &registry, .chunks = terrain, .players = &players, .streaming = streaming, .sessions = service, .packets = encoding, .worlds = dimensions }, .{});
        var background: Terrain = .{ .chunks = terrain, .streaming = streaming, .blocks = blocks, .io = io };
        background.start();
        defer background.stop();
        bounded.fail_index = bounded.alloc_index;
        const started = std.Io.Clock.now(.cpu_thread, io).nanoseconds;
        var passes: usize = 0;
        var packet_count: usize = 0;
        var deliveries: usize = 0;
        for (0..2) |phase| {
            if (phase != 0) {
                for (player_records) |*player| player.position.x += 16;
                players.rebuildIndexes();
            }
            var complete = false;
            for (0..1024) |_| {
                passes += 1;
                service.beginTick();
                try terrain.setBlock(world, .{ .x = 8, .y = 72, .z = 8 }, if (passes % 2 == 0) 0 else @intCast(game_data.registry.block_glowstone_default_state));
                streaming.endTick(true);
                blocks.endTick(true);
                service.endTick(true);
                try background.poll();
                while (try terrain.generation.processOne(io)) {}
                try terrain.poll();
                var output_batch = service.outputBatch();
                while (output_batch.next()) |packet| {
                    packet_count += 1;
                    deliveries += packet.recipients.len;
                    var recipients = packet.recipients.iterator();
                    while (recipients.next()) |handle| service.refund(handle, service.framedBound(packet.bytes.len));
                    service.recycle(io, &.{packet});
                }
                try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
                complete = true;
                for (streaming.streams, player_records) |stream, player| {
                    const center = Streaming.View.capture(player).center;
                    complete = complete and stream.setup == .streaming and stream.cursor == 25 and stream.center.x == center.x and stream.center.z == center.z;
                }
                if (complete) break;
            }
            if (!complete) {
                std.debug.print("stream stalled players={d} spread={} sections={d} phase={d} cursor={d} queued={d} copied={d} decoded={d}\n", .{ count, spread, section_count, phase, streaming.streams[0].cursor, terrain.generation.queued_count, std.mem.count(bool, &streaming.deps.lighting.background.copied, &.{true}), streaming.deps.lighting.background.work.decoded_sections });
                return error.LightingStreamStalled;
            }
        }
        // Stop edits and drain the remaining light notifications to check eventual delivery.
        var settled = false;
        for (0..512) |_| {
            service.beginTick();
            streaming.endTick(true);
            blocks.endTick(true);
            service.endTick(true);
            try background.poll();
            while (try terrain.generation.processOne(io)) {}
            try terrain.poll();
            var output_batch = service.outputBatch();
            while (output_batch.next()) |packet| {
                packet_count += 1;
                deliveries += packet.recipients.len;
                var recipients = packet.recipients.iterator();
                while (recipients.next()) |handle| service.refund(handle, service.framedBound(packet.bytes.len));
                service.recycle(io, &.{packet});
            }
            settled = streaming.light_pending.words.count == 0;
            if (settled) break;
        }
        try std.testing.expect(settled);
        for (player_records) |player| try std.testing.expectEqual(service.config.buffer_bytes, service.outputCredit(player.handle.?));
        try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
        const elapsed = std.Io.Clock.now(.cpu_thread, io).nanoseconds - started;
        const work = streaming.deps.lighting.background.work;
        try output.interface.print("{d:>7} {s:<9} {d:>8} {d:>6} {d:>7} {d:>10} {d:>8} {d:>7} {d:>8} {d:>6.2}\n", .{ count, if (spread) "spread" else "clustered", section_count, passes, packet_count, deliveries, work.relights, work.decoded_sections, work.retained_columns, @as(f64, @floatFromInt(elapsed)) / 1_000_000 });
        try output.interface.flush();
    };
}
