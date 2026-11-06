const vanilla_content = @import("vanilla_content.zig");
const std = @import("std");
const streaming_options = @import("streaming_benchmark_options");
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
const minecraft_java = @import("minecraft_java");
const Players = @import("players.zig").Players;
const Lighting = @import("lighting.zig").Lighting;
const Streaming = @import("streaming.zig").Streaming;
const BlockSynchronization = @import("block_sync.zig").BlockSynchronization;
const Terrain = @import("terrain.zig").Terrain;
const wire = @import("wire_1_21_5");

const FlightPacket = enum { new_column, replacement, biomes, light, other };

pub const Scene = struct {
    empty: bool = false,

    pub fn read(self: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
        for (batch.requests) |*request| {
            request.output[0] = 3;
            for (0..64) |cell| std.mem.writeInt(u16, request.output[1 + cell * 2 ..][0..2], @intCast(game_data.registry.biomeId("minecraft:plains").?), .little);
            const blocks = request.output[chunks.encoding.biome_header_bytes..];
            if (self.empty or request.section.y != 4) {
                request.result = chunks.encoding.biome_header_bytes + chunks.uniform(0, blocks);
                continue;
            }
            blocks[0] = 1;
            for (0..4096) |local| std.mem.writeInt(u16, blocks[1 + local * 2 ..][0..2], state(request.section, local), .little);
            request.result = chunks.encoding.maximum_decoded_bytes;
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
    var output = std.Io.File.stdout().writerStreaming(io, &output_buffer);
    try output.interface.writeAll("Lighting through chunk streaming and block publication. No sockets or scheduler waits.\nplayers layout    sections passes packets deliveries relights decoded retained cpu_ms\n");
    for ([_]usize{ 1, 8, 32 }) |count| for ([_]bool{ false, true }) |spread| for ([_]u16{ 1, 24 }) |section_count| {
        try lightingLoad(.{ .players = count, .spread = spread, .sections = section_count }, &output.interface);
    };
}

test "cold lighting streams progress across separated player groups" {
    var buffer: [256]u8 = undefined;
    var output: std.Io.Writer.Discarding = .init(&buffer);
    try lightingLoad(.{ .players = 8, .spread = true, .sections = 24 }, &output.writer);
}

const LightingLoad = struct { players: usize, spread: bool, sections: u16 };

fn lightingLoad(scenario: LightingLoad, output: *std.Io.Writer) !void {
    const io = std.testing.io;
    const count = scenario.players;
    const spread = scenario.spread;
    const section_count = scenario.sections;
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
    const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 48, .demand_sections = 24, .cache_groups = 4 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = resources });
    var source: Scene = .{};
    terrain.setSource(chunks.Source.init(&source, Scene.read));
    const streaming = try Streaming.init(allocator, io, .{}, .{ .metrics = &registry, .players = &players, .chunks = terrain, .sessions = service, .packets = encoding, .worlds = dimensions, .lighting = try Lighting.init(allocator, .{}, .{ .metrics = &registry, .blocks = try vanilla_content.blocks(allocator), .chunks = terrain, .worlds = dimensions }) });
    defer service.unsubscribeOutput(streaming.changed);
    defer terrain.unsubscribeReady(streaming.changed);
    const blocks = try BlockSynchronization.init(allocator, io, .{ .metrics = &registry, .chunks = terrain, .players = &players, .streaming = streaming, .sessions = service, .packets = encoding, .worlds = dimensions }, .{});
    var background: Terrain = .{ .chunks = terrain, .streaming = streaming, .blocks = blocks, .io = io };
    background.start();
    defer background.stop();
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
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
            const groups = if (spread) @min(count, 4) else 1;
            for (0..groups) |group| try terrain.setBlock(world, .{ .x = @intCast(group * 256 + 8), .y = 72, .z = 8 }, if (passes % 2 == 0) 0 else @intCast(game_data.registry.block_glowstone_default_state));
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
    try output.print("{d:>7} {s:<9} {d:>8} {d:>6} {d:>7} {d:>10} {d:>8} {d:>7} {d:>8} {d:>6.2}\n", .{ count, if (spread) "spread" else "clustered", section_count, passes, packet_count, deliveries, work.relights, work.decoded_sections, work.retained_columns, @as(f64, @floatFromInt(elapsed)) / 1_000_000 });
    try output.flush();
}

test "streaming movement preserves planned owners while delivery catches up" {
    const render_distance = 2;
    const columns = (render_distance * 2 + 1) * (render_distance * 2 + 1);
    const movement_ticks = 256;
    const background_polls_per_tick = 8;
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = bounded.allocator();
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
    defer registry.deinit();
    var path: [256]u8 = undefined;
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = try std.fmt.bufPrint(&path, ".zig-cache/tmp/{s}/moving-stream", .{directory.sub_path}) });
    defer store.deinit();
    const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
    const world = try dimensions.create(.{ .name = "test:moving", .dimension = .{ .name = "test:dimension", .minimum_section = -4, .section_count = 24, .skylight = true } });
    var catalog = try protocols.Default.init(allocator);
    defer catalog.deinit(allocator);
    var sink: Sink = .{};
    const service = try sessions.Service.init(allocator, io, .{ .context = &sink, .vtable = network.Transport.adapter(Sink) }, .{ .connections = 2, .pages = 16, .page_bytes = 128 * 1024, .buffer_bytes = 1024 * 1024, .protocols = &catalog.values });
    defer {
        if (service.tick_active) service.endTick(false);
        var remaining = service.outputBatch();
        while (remaining.next()) |packet| {
            var recipients = packet.recipients.iterator();
            while (recipients.next()) |handle| service.refund(handle, service.framedBound(packet.bytes.len));
            service.recycle(io, &.{packet});
        }
        service.deinit();
    }
    var player_records: [2]Players.Player = undefined;
    for (&player_records, 0..) |*player, index| {
        player.* = .{ .handle = .{ .index = index, .generation = 1 }, .uuid = index + 1, .world = world, .stage = .ready, .loaded = true, .position = .{ .x = 0.5, .y = 65, .z = 0.5 }, .protocol = catalog.values[0].number };
        service.credit[index].store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
    }
    var players: Players = .{ .deps = undefined, .config = .{ .maximum = player_records.len, .render_distance = render_distance }, .spawn_world = world, .records = &player_records, .dig_handlers = &.{} };
    try players.initIndexes(allocator);
    players.rebuildIndexes();
    const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 48, .demand_sections = 24, .cache_groups = 4 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = try records.Workspaces.init(allocator, io, .{}) });
    var source: Scene = .{ .empty = true };
    terrain.setSource(chunks.Source.init(&source, Scene.read));
    const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
    const streaming = try Streaming.init(allocator, io, .{}, .{ .metrics = &registry, .players = &players, .chunks = terrain, .sessions = service, .packets = encoding, .worlds = dimensions, .lighting = try Lighting.init(allocator, .{}, .{ .metrics = &registry, .blocks = try vanilla_content.blocks(allocator), .chunks = terrain, .worlds = dimensions }) });
    defer service.unsubscribeOutput(streaming.changed);
    defer terrain.unsubscribeReady(streaming.changed);
    const blocks = try BlockSynchronization.init(allocator, io, .{ .metrics = &registry, .chunks = terrain, .players = &players, .streaming = streaming, .sessions = service, .packets = encoding, .worlds = dimensions }, .{});
    var background: Terrain = .{ .chunks = terrain, .streaming = streaming, .blocks = blocks, .io = io };
    background.start();
    defer background.stop();
    bounded.fail_index = bounded.alloc_index;
    var movements: usize = 0;
    var delivered: usize = 0;
    var initialized = false;
    var paused = false;
    try background.poll();
    try std.testing.expect(streaming.pending);
    try std.testing.expectEqual(@as(u64, 0), streaming.geometry.builds);
    var first_terrain: [player_records.len]bool = @splat(false);
    for (0..streaming.geometry.traversal.nodes.len + 1) |_| {
        while (try terrain.generation.processOne(io)) {}
        try terrain.poll();
        try background.poll();
        for (streaming.streams, &first_terrain, 0..) |stream, *received, index| {
            if (received.* or stream.delivered == 0) continue;
            try std.testing.expect(!streaming.sources[index].known);
            try std.testing.expectEqual(@as(u64, 0), streaming.geometry.visits);
            const occupied: u32 = 1 << 8;
            try std.testing.expectEqual(occupied, streaming.disclosed[index * columns]);
            try std.testing.expectEqual(occupied, ~streaming.occluded[index * columns] & ((1 << 24) - 1));
            received.* = true;
        }
        var ready = true;
        for (streaming.sources) |region| ready = ready and region.known;
        if (ready) break;
    } else return error.SourcePreparationStalled;
    for (first_terrain) |received| try std.testing.expect(received);
    for (0..1024) |_| {
        if (initialized and movements < movement_ticks) {
            const step: f64 = @floatFromInt(movements);
            player_records[0].position = .{ .x = 0.5 + step * 0.75, .y = 65 + step * 0.25, .z = 0.5 - step * 0.5 };
            player_records[1].position = .{ .x = 0.5 - step * 0.5, .y = 65, .z = 0.5 + step * 0.75 };
            movements += 1;
            players.rebuildIndexes();
        }
        if (initialized and movements < 32) {
            service.credit[1].store((@as(u64, 1) << 32) | sessions.Service.active, .release);
            paused = true;
        } else if (paused) {
            try std.testing.expectEqual(@as(usize, 0), service.outputCredit(player_records[1].handle.?));
            try std.testing.expect(streaming.streams[0].center.x != 0 or streaming.streams[0].center.z != 0);
            service.credit[1].store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
            paused = false;
        }
        service.beginTick();
        streaming.endTick(true);
        blocks.endTick(true);
        service.endTick(true);
        for (0..background_polls_per_tick) |_| {
            try background.poll();
            while (try terrain.generation.processOne(io)) {}
            try terrain.poll();
            var batch = service.outputBatch();
            while (batch.next()) |packet| {
                delivered += 1;
                var recipients = packet.recipients.iterator();
                while (recipients.next()) |handle| service.refund(handle, service.framedBound(packet.bytes.len));
                service.recycle(io, &.{packet});
            }
        }
        try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
        var complete = true;
        for (streaming.streams, player_records) |stream, player| {
            const center = Streaming.View.capture(player).center;
            complete = complete and stream.setup == .streaming and stream.cursor == columns and stream.delivered == columns and stream.center.x == center.x and stream.center.z == center.z;
        }
        if (!initialized) {
            if (!complete) continue;
            for (streaming.occluded) |mask| try std.testing.expectEqual(@as(u32, 0), mask);
            initialized = true;
            continue;
        }
        if (movements == movement_ticks and complete) break;
    } else return error.MovingStreamDidNotSettle;
    try std.testing.expectEqual(@as(usize, movement_ticks), movements);
    try std.testing.expect(delivered > columns * player_records.len);
    for (player_records) |player| try std.testing.expectEqual(service.config.buffer_bytes, service.outputCredit(player.handle.?));
}

test "imported world fixture" {
    const io = std.testing.io;
    const path = streaming_options.world orelse return error.MissingStreamingWorld;
    const count = streaming_options.players;
    if (count == 0) return error.InvalidPlayerCount;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var registry = try metrics.Registry.init(allocator, io, .{ .enabled = false });
    defer registry.deinit();
    var store = try storage.Store.init(allocator, io, .{ .path = path });
    defer store.deinit();
    const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 16 }, .{ .storage = try store.openSpace(worlds.Worlds.id) });
    const definition = dimensions.find("minecraft:overworld") orelse return error.MissingOverworld;
    const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 1, .demand_sections = 1, .cache_groups = 32 }, .{
        .metrics = &registry,
        .storage = try store.openSpace(chunks.Chunks.id),
        .record_workspaces = try records.Workspaces.init(allocator, io, .{}),
    });
    var origin: [2]i32 = .{ 0, 0 };
    if (streaming_options.position) |text| {
        var parts = std.mem.splitScalar(u8, text, ',');
        origin[0] = @intFromFloat(@floor((try std.fmt.parseFloat(f64, parts.next() orelse return error.InvalidPosition)) / 16));
        _ = parts.next() orelse return error.InvalidPosition;
        origin[1] = @intFromFloat(@floor((try std.fmt.parseFloat(f64, parts.next() orelse return error.InvalidPosition)) / 16));
        if (parts.next() != null) return error.InvalidPosition;
    }
    const width: usize = @min(count, 8);
    const rows = try std.math.divCeil(usize, count, width);
    const radius: i32 = @intCast(streaming_options.radius + 1 + @as(usize, if (streaming_options.movement) 2 else 0));
    const centers = try allocator.alloc([2]i32, count);
    const fingerprints = try allocator.alloc([32]u8, count);
    const section_count = definition.dimension.sectionCount();
    if (section_count == 0 or section_count > 192) return error.UnsupportedWorldHeight;
    const buffer = try allocator.alloc(u8, section_count * chunks.encoding.maximum_decoded_bytes);
    const keys = try allocator.alloc([16]u8, section_count);
    const requests = try allocator.alloc(records.Get, section_count);
    const lengths = try allocator.alloc(?usize, section_count);
    for (centers, fingerprints, 0..) |*center, *fingerprint, index| {
        const dx = @as(i64, @intCast(index % width)) - @as(i64, @intCast(width / 2));
        const dz = @as(i64, @intCast(index / width)) - @as(i64, @intCast(rows / 2));
        center.* = .{
            origin[0] + @as(i32, @intCast(dx * @as(i64, @intCast(streaming_options.spacing)))),
            origin[1] + @as(i32, @intCast(dz * @as(i64, @intCast(streaming_options.spacing)))),
        };
        var hash = std.crypto.hash.Blake3.init(.{});
        var z = center[1] - radius;
        while (z <= center[1] + radius) : (z += 1) {
            var x = center[0] - radius;
            while (x <= center[0] + radius) : (x += 1) {
                for (keys, requests, 0..) |*key, *request, y| {
                    key.* = chunks.encodeKey(.{ .world = definition.id, .x = x, .z = z, .y = definition.dimension.minimumSection() + @as(i32, @intCast(y)) });
                    request.* = .{ .key = key, .destination = buffer[y * chunks.encoding.maximum_decoded_bytes ..][0..chunks.encoding.maximum_decoded_bytes] };
                }
                try terrain.cache.backend.store.decodeBatch(requests, lengths);
                for (requests, lengths) |request, length| {
                    const size = length orelse {
                        std.debug.print("Missing benchmark terrain at {d},{d},{d}\n", .{ x, std.mem.readInt(i32, request.key[12..16], .big), z });
                        return error.IncompleteStreamingWorld;
                    };
                    var prefix: [4]u8 = undefined;
                    std.mem.writeInt(u32, &prefix, @intCast(size), .little);
                    hash.update(&prefix);
                    hash.update(request.destination[0..size]);
                }
            }
        }
        hash.final(fingerprint);
        const hex = std.fmt.bytesToHex(fingerprint.*, .lower);
        std.debug.print("observer={d} column={d},{d} terrain_blake3={s}\n", .{ index, center[0], center[1], hex });
        for (centers[0..index], fingerprints[0..index]) |previous, previous_hash| {
            const separated = @max(@abs(@as(i64, center[0]) - previous[0]), @abs(@as(i64, center[1]) - previous[1])) > 2 * radius;
            if (separated and std.mem.eql(u8, fingerprint, &previous_hash)) {
                std.debug.print("Separated observer horizons have identical terrain\n", .{});
                return error.DuplicateStreamingTerrain;
            }
        }
    }
}

test "imported world streaming" {
    if (streaming_options.corpus != null and (streaming_options.occlusion == null or streaming_options.lighting_comparison)) return error.CorpusRequiresSingleStreamingMode;
    if (streaming_options.lighting_comparison) {
        const concealment = streaming_options.occlusion orelse true;
        const before = try streamWorld(concealment, false, false);
        const after = try streamWorld(concealment, false, true);
        try std.testing.expectEqual(before, after);
    } else if (streaming_options.movement) {
        for ([_]bool{ false, true }) |concealment| {
            if (streaming_options.occlusion) |selected| if (selected != concealment) continue;
            var speeds = std.mem.splitScalar(u8, streaming_options.flight_speeds, ',');
            while (speeds.next()) |text| {
                const speed = try std.fmt.parseFloat(f64, text);
                if (!std.math.isFinite(speed) or speed <= 0) return error.InvalidFlightSpeed;
                _ = try streamPlayers(concealment, false, true, streaming_options.players, streaming_options.spacing, speed);
            }
        }
    } else if (streaming_options.position != null or streaming_options.spacing != 0) {
        for ([_]bool{ false, true }) |concealment| {
            if (streaming_options.occlusion) |enabled| if (enabled != concealment) continue;
            _ = try streamWorld(concealment, false, true);
        }
    } else {
        for ([_]bool{ false, true }) |cave| {
            for ([_]bool{ false, true }) |concealment| {
                _ = try streamWorld(concealment, cave, true);
            }
        }
    }
}

fn streamWorld(concealment: bool, cave: bool, retain_lighting: bool) !u64 {
    return streamPlayers(concealment, cave, retain_lighting, streaming_options.players, streaming_options.spacing, 80);
}

test "imported world player scaling" {
    if (streaming_options.movement or streaming_options.lighting_comparison) return error.InvalidScalingOptions;
    for ([_]usize{ 1, 8, 32 }) |count| for ([_]usize{ 0, 4 }) |spacing| {
        if (count == 1 and spacing != 0) continue;
        for ([_]bool{ false, true }) |concealment| _ = try streamPlayers(concealment, false, true, count, spacing, 80);
    };
}

fn streamPlayers(concealment: bool, cave: bool, retain_lighting: bool, count: usize, spacing: usize, flight_speed: f64) !u64 {
    const io = std.testing.io;
    const path = streaming_options.world orelse return error.MissingStreamingWorld;
    if (count == 0 or (streaming_options.movement and count != 1)) return error.InvalidPlayerCount;
    const radius = streaming_options.radius;
    const prefetch: u2 = if (streaming_options.movement) 2 else 0;
    const delivery_radius = radius + @as(usize, prefetch);
    const target = (2 * delivery_radius + 1) * (2 * delivery_radius + 1);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = bounded.allocator();
    var compression = try minecraft_java.Wire.Workspace.init(allocator);
    defer compression.deinit();
    const compressed = try allocator.alloc(u8, (1 << 21) + sessions.shared_headroom);
    const encrypted = try allocator.alloc(u8, if (streaming_options.encryption) compressed.len else 0);
    const ciphers = try allocator.alloc(minecraft_java.Wire, if (streaming_options.encryption) count else 0);
    for (ciphers, 0..) |*cipher, index| {
        cipher.* = .{};
        var secret: [16]u8 = @splat(0x37);
        std.mem.writeInt(u64, secret[0..8], @intCast(index), .little);
        cipher.install(secret);
    }
    var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 256 });
    defer registry.deinit();
    const compression_cpu = try registry.timer(.{ .name = "benchmark.compression.cpu", .description = "Protocol compression on the benchmark thread", .clock = .thread_cpu });
    const encryption_cpu = try registry.timer(.{ .name = "benchmark.encryption.cpu", .description = "Production cipher for each recipient", .clock = .thread_cpu });
    const terrain_cpu = try registry.timer(.{ .name = "benchmark.terrain.cpu", .description = "Complete terrain poll including storage and streaming", .clock = .thread_cpu });
    const output_cpu = try registry.timer(.{ .name = "benchmark.output.cpu", .description = "Drain output including compression hashing and recycling", .clock = .thread_cpu });
    const hash_cpu = try registry.timer(.{ .name = "benchmark.hash.cpu", .description = "Hash uncompressed packets for correctness", .clock = .thread_cpu });
    var store = try storage.Store.init(allocator, io, .{ .path = path, .metrics = &registry });
    defer store.deinit();
    const resources = try records.Workspaces.init(allocator, io, .{});
    const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 16 }, .{ .storage = try store.openSpace(worlds.Worlds.id) });
    const world = (dimensions.find("minecraft:overworld") orelse return error.MissingOverworld).id;
    var catalog = try protocols.Default.init(allocator);
    defer catalog.deinit(allocator);
    var sink: Sink = .{};
    const service = try sessions.Service.init(allocator, io, .{ .context = &sink, .vtable = network.Transport.adapter(Sink) }, .{ .connections = count, .protocols = &catalog.values });
    defer {
        if (service.tick_active) service.endTick(false);
        service.deinit();
    }
    const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
    const player_records = try allocator.alloc(Players.Player, count);
    const Progress = struct { milestones: [3]i96 = @splat(0), wire_bytes: usize = 0 };
    const progress = try allocator.alloc(Progress, count);
    @memset(progress, .{});
    const milestones = [_]usize{ 1, (target + 1) / 2, target };
    const corpus_buffer = try allocator.alloc(u8, if (streaming_options.corpus != null) 1024 * 1024 else 0);
    const corpus_file: ?std.Io.File = if (streaming_options.corpus) |output_path| try std.Io.Dir.cwd().createFile(io, output_path, .{}) else null;
    defer if (corpus_file) |file| file.close(io);
    var corpus_writer: ?std.Io.File.Writer = if (corpus_file) |file| file.writerStreaming(io, corpus_buffer) else null;
    if (corpus_writer) |*writer| {
        try writer.interface.writeAll("LRSTRM01");
        try writer.interface.writeInt(u64, count, .little);
    }
    for (player_records, 0..) |*player, index| {
        player.* = .{ .handle = .{ .index = index, .generation = 1 }, .uuid = index + 1, .world = world, .stage = .ready, .loaded = true, .position = .{ .x = 8.5, .y = 65, .z = 8.5 }, .protocol = catalog.values[index % catalog.values.len].number };
        service.credit[index].store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
    }
    var players: Players = .{ .deps = undefined, .config = .{ .maximum = count, .render_distance = radius }, .spawn_world = world, .records = player_records, .dig_handlers = &.{} };
    try players.initIndexes(allocator);
    players.rebuildIndexes();
    const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 192, .demand_sections = 24, .cache_groups = 32 }, .{ .metrics = &registry, .storage = try store.openSpace(chunks.Chunks.id), .record_workspaces = resources });
    const Disk = struct {
        fn read(_: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests) |*request| request.result = error.MissingStoredSection;
        }
    };
    var disk: Disk = .{};
    terrain.setSource(chunks.Source.init(&disk, Disk.read));
    const dimension = dimensions.get(world).?.dimension;
    var surface_found = false;
    var section_y = dimension.minimumSection() + @as(i32, @intCast(dimension.sectionCount()));
    if (streaming_options.position) |text| {
        var parts = std.mem.splitScalar(u8, text, ',');
        player_records[0].position = .{
            .x = try std.fmt.parseFloat(f64, parts.next() orelse return error.InvalidPosition),
            .y = try std.fmt.parseFloat(f64, parts.next() orelse return error.InvalidPosition),
            .z = try std.fmt.parseFloat(f64, parts.next() orelse return error.InvalidPosition),
        };
        if (parts.next() != null) return error.InvalidPosition;
        surface_found = true;
    }
    while (section_y > dimension.minimumSection() and !surface_found) {
        section_y -= 1;
        const lease = try terrain.acquire(.{ .world = world, .x = 0, .y = section_y, .z = 0 });
        defer lease.release();
        var local_y: usize = 16;
        while (local_y != 0) {
            local_y -= 1;
            if (game_data.physics.get(lease.get(@intCast(local_y * 256 + 8 * 16 + 8))).air) continue;
            player_records[0].position.y = @floatFromInt(section_y * 16 + @as(i32, @intCast(local_y)) + 1);
            surface_found = true;
            break;
        }
    }
    if (!surface_found) return error.MissingSurface;
    if (cave) {
        const surface = player_records[0].position.y;
        var found = false;
        section_y = dimension.minimumSection();
        search: while (section_y * 16 < surface - 16) : (section_y += 1) {
            const lease = try terrain.acquire(.{ .world = world, .x = 0, .y = section_y, .z = 0 });
            defer lease.release();
            for (1..14) |y| for (0..16) |z| for (0..16) |x| {
                const index = y * 256 + z * 16 + x;
                if (!game_data.physics.get(lease.get(@intCast(index))).air or
                    !game_data.physics.get(lease.get(@intCast(index + 256))).air or
                    !game_data.physics.rendering(lease.get(@intCast(index - 256))).occluder) continue;
                player_records[0].position = .{ .x = @as(f64, @floatFromInt(x)) + 0.5, .y = @floatFromInt(section_y * 16 + @as(i32, @intCast(y))), .z = @as(f64, @floatFromInt(z)) + 0.5 };
                found = true;
                break :search;
            };
        }
        if (!found) return error.MissingCave;
    }
    const origin = player_records[0].position;
    for (player_records, 0..) |*player, index| {
        player.position = origin;
        if (spacing == 0) continue;
        const width: usize = @min(count, 8);
        const rows = std.math.divCeil(usize, count, width) catch unreachable;
        player.position.x += @as(f64, @floatFromInt(@as(i64, @intCast(index % width)) - @as(i64, @intCast(width / 2)))) * @as(f64, @floatFromInt(spacing * 16));
        player.position.z += @as(f64, @floatFromInt(@as(i64, @intCast(index / width)) - @as(i64, @intCast(rows / 2)))) * @as(f64, @floatFromInt(spacing * 16));
        const x: i32 = @intFromFloat(@floor(player.position.x));
        const z: i32 = @intFromFloat(@floor(player.position.z));
        var y = dimension.minimumSection() + @as(i32, @intCast(dimension.sectionCount()));
        var found = false;
        while (y > dimension.minimumSection() and !found) {
            y -= 1;
            const lease = try terrain.acquire(.{ .world = world, .x = @divFloor(x, 16), .y = y, .z = @divFloor(z, 16) });
            defer lease.release();
            var local_y: usize = 16;
            while (local_y != 0) {
                local_y -= 1;
                const local: u12 = @intCast(local_y * 256 + @as(usize, @intCast(@mod(z, 16))) * 16 + @as(usize, @intCast(@mod(x, 16))));
                if (game_data.physics.get(lease.get(local)).air) continue;
                player.position.y = @floatFromInt(y * 16 + @as(i32, @intCast(local_y)) + 1);
                found = true;
                break;
            }
        }
        if (!found) return error.MissingSurface;
    }
    players.rebuildIndexes();
    var overlapping_horizons: usize = 0;
    var overlapping_light_halos: usize = 0;
    var minimum_separation: u64 = if (count > 1) std.math.maxInt(u64) else 0;
    for (player_records, 0..) |player, index| {
        const center = Streaming.View.capture(player).center;
        for (player_records[0..index]) |other| {
            const previous = Streaming.View.capture(other).center;
            const dx = @abs(@as(i64, center.x) - previous.x);
            const dz = @abs(@as(i64, center.z) - previous.z);
            minimum_separation = @min(minimum_separation, @max(dx, dz));
            overlapping_horizons += @intFromBool(dx <= 2 * delivery_radius and dz <= 2 * delivery_radius);
            overlapping_light_halos += @intFromBool(dx <= 2 * (delivery_radius + 1) and dz <= 2 * (delivery_radius + 1));
        }
    }
    const streaming = try Streaming.init(allocator, io, .{ .occlusion = concealment, .prefetch = prefetch }, .{ .metrics = &registry, .players = &players, .chunks = terrain, .sessions = service, .packets = encoding, .worlds = dimensions, .lighting = try Lighting.init(allocator, .{ .stored = streaming_options.stored_lighting }, .{ .metrics = &registry, .blocks = try vanilla_content.blocks(allocator), .chunks = terrain, .worlds = dimensions }) });
    defer service.unsubscribeOutput(streaming.changed);
    defer terrain.unsubscribeReady(streaming.changed);
    const blocks = try BlockSynchronization.init(allocator, io, .{ .metrics = &registry, .chunks = terrain, .players = &players, .streaming = streaming, .sessions = service, .packets = encoding, .worlds = dimensions }, .{});

    var background: Terrain = .{ .chunks = terrain, .streaming = streaming, .blocks = blocks, .io = io };
    const flight_metrics = try allocator.alloc(metrics.Snapshot, if (streaming_options.movement) registry.count else 0);
    const flight_columns = try allocator.alloc(Streaming.Position, if (streaming_options.movement) target else 0);
    background.start();
    defer background.stop();
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    const reserved_bytes = bounded.allocated_bytes - bounded.freed_bytes;
    service.beginTick();
    streaming.endTick(true);
    service.endTick(true);
    const started = std.Io.Clock.now(.awake, io).nanoseconds;
    const cpu = std.Io.Clock.now(.cpu_thread, io).nanoseconds;
    var passes: usize = 0;
    var bytes: usize = 0;
    var wire_bytes: usize = 0;
    var recipient_bytes: usize = 0;
    var deliveries: usize = 0;
    var encrypted_digest = std.hash.Wyhash.init(0);
    var digest = std.hash.Wyhash.init(0);
    var complete = false;
    var maximum_lead: usize = 0;
    while (!complete) {
        passes += 1;
        if (passes > 100000 * count) return error.StreamingStalled;
        if (!retain_lighting) streaming.deps.lighting.background.solved = null;
        {
            const timing = terrain_cpu.start();
            defer timing.end();
            try background.poll();
        }
        const output_timing = output_cpu.start();
        defer output_timing.end();
        var batch = service.outputBatch();
        while (batch.next()) |packet| {
            bytes += packet.bytes.len;
            const frame = frame: {
                const timing = compression_cpu.start();
                defer timing.end();
                break :frame try compression.encode(service.output.framingStorage(packet), packet.bytes.len, 256, compressed);
            };
            wire_bytes += frame.len;
            if (corpus_writer) |*writer| {
                try writer.interface.writeInt(u32, @intCast(packet.bytes.len), .little);
                try writer.interface.writeInt(u32, @intCast(frame.len), .little);
                try writer.interface.writeInt(u64, packet.recipients.len, .little);
                var targets = packet.recipients.iterator();
                while (targets.next()) |handle| try writer.interface.writeInt(u64, handle.index, .little);
                try writer.interface.writeAll(packet.bytes);
                try writer.interface.writeAll(frame);
            }
            {
                const timing = hash_cpu.start();
                defer timing.end();
                digest.update(packet.bytes);
            }
            var recipients = packet.recipients.iterator();
            while (recipients.next()) |handle| {
                deliveries += 1;
                recipient_bytes += frame.len;
                progress[handle.index].wire_bytes += frame.len;
                if (streaming_options.encryption) {
                    const timing = encryption_cpu.start();
                    ciphers[handle.index].encrypt(frame, encrypted[0..frame.len]);
                    timing.end();
                    encrypted_digest.update(encrypted[0..frame.len]);
                }
                service.refund(handle, service.framedBound(packet.bytes.len));
            }
            service.recycle(io, &.{packet});
        }
        complete = true;
        var minimum_delivered = target;
        var maximum_delivered: usize = 0;
        var milestone_cpu: ?i96 = null;
        for (streaming.streams, progress) |stream, *player_progress| {
            complete = complete and stream.cursor == target and stream.delivered == target;
            minimum_delivered = @min(minimum_delivered, stream.delivered);
            maximum_delivered = @max(maximum_delivered, stream.delivered);
            for (milestones, &player_progress.milestones) |threshold, *reached| {
                if (reached.* != 0 or stream.delivered < threshold) continue;
                if (milestone_cpu == null) milestone_cpu = std.Io.Clock.now(.cpu_thread, io).nanoseconds - cpu;
                reached.* = milestone_cpu.?;
            }
        }
        maximum_lead = @max(maximum_lead, maximum_delivered - minimum_delivered);
    }
    const elapsed_cpu = std.Io.Clock.now(.cpu_thread, io).nanoseconds - cpu;
    const elapsed_wall = std.Io.Clock.now(.awake, io).nanoseconds - started;
    if (corpus_writer) |*writer| {
        try writer.interface.writeInt(u32, 0, .little);
        try writer.interface.writeInt(u64, digest.final(), .little);
        try writer.interface.writeInt(u64, encrypted_digest.final(), .little);
        try writer.interface.flush();
    }
    for (streaming.streams, player_records) |stream, player| {
        try std.testing.expectEqual(target, stream.delivered);
        try std.testing.expectEqual(service.config.buffer_bytes, service.outputCredit(player.handle.?));
    }
    const snapshot_samples = 1024;
    const snapshot_start = std.Io.Clock.now(.cpu_thread, io).nanoseconds;
    for (0..snapshot_samples) |_| {
        service.beginTick();
        streaming.tick();
        streaming.endTick(true);
        service.endTick(true);
    }
    const snapshot_ns = @divTrunc(std.Io.Clock.now(.cpu_thread, io).nanoseconds - snapshot_start, snapshot_samples);
    try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
    try std.testing.expect(!bounded.has_induced_failure);
    try std.testing.expectEqual(reserved_bytes, bounded.allocated_bytes - bounded.freed_bytes);
    if (concealment) if (streaming_options.hidden) |text| {
        streaming.tick();
        const visibility = streaming.snapshotVisibility();
        var points = std.mem.splitScalar(u8, text, ';');
        while (points.next()) |point| {
            var parts = std.mem.splitScalar(u8, point, ',');
            const x = try std.fmt.parseInt(i32, parts.next() orelse return error.InvalidPosition, 10);
            const y = try std.fmt.parseInt(i32, parts.next() orelse return error.InvalidPosition, 10);
            const z = try std.fmt.parseInt(i32, parts.next() orelse return error.InvalidPosition, 10);
            if (parts.next() != null) return error.InvalidPosition;
            if (visibility.blockVisible(0, &player_records[0], world, .{ x, y, z })) {
                std.debug.print("disclosed target x={d} y={d} z={d}\n", .{ x, y, z });
                return error.IncorrectDisclosure;
            }
        }
    };
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(io, &output_buffer);
    if (streaming_options.corpus) |output_path| try output.interface.print("Packet corpus: {s}. Capture I/O is included in pipeline timings.\n", .{output_path});
    try output.interface.writeAll("Native world streaming with protocol compression, excluding sockets and client rendering\nocclusion chunks   CPU_ms   wall_ms  packet_MiB wire_MiB  pipeline_MiB  decoded  batches  relights  visits  cache_hits  columns queries occluded section_builds change_lookups packet_hash\n");
    try output.interface.print("players={d} spacing_chunks={d} encryption={} deliveries={d} recipient_wire_MiB={d:.2} reserved_MiB={d:.2} runtime_allocations=0 encrypted_hash={x}\n", .{ count, spacing, streaming_options.encryption, deliveries, @as(f64, @floatFromInt(recipient_bytes)) / (1024 * 1024), @as(f64, @floatFromInt(reserved_bytes)) / (1024 * 1024), encrypted_digest.final() });
    try output.interface.print("Observer horizons: radius_chunks={d} columns_per_player={d} minimum_separation_chunks={d} overlapping_pairs={d} overlapping_light_halos={d}\n", .{ delivery_radius, target, minimum_separation, overlapping_horizons, overlapping_light_halos });
    try output.interface.print("Streaming fairness: maximum_column_lead={d}\nplayer first_column_CPU_ms halfway_CPU_ms complete_CPU_ms wire_MiB\n", .{maximum_lead});
    for (progress, 0..) |player_progress, index| {
        try output.interface.print("{d} {d:.2} {d:.2} {d:.2} {d:.2}\n", .{ index, @as(f64, @floatFromInt(player_progress.milestones[0])) / std.time.ns_per_ms, @as(f64, @floatFromInt(player_progress.milestones[1])) / std.time.ns_per_ms, @as(f64, @floatFromInt(player_progress.milestones[2])) / std.time.ns_per_ms, @as(f64, @floatFromInt(player_progress.wire_bytes)) / (1024 * 1024) });
    }
    try output.interface.print("Idle simulation snapshot exchange: {d} ns/tick over {d} ticks, excluding other gameplay\n", .{ snapshot_ns, snapshot_samples });
    try output.interface.print("Stored lighting: enabled={} hits={d} misses={d}\n", .{ streaming_options.stored_lighting, streaming.deps.lighting.stored_hits.value(), streaming.deps.lighting.stored_misses.value() });
    try output.interface.print("Terrain section reads: {d}\n", .{terrain.cache.metrics.reads.value()});
    const groups = &terrain.cache.backend.store.bases;
    try output.interface.print("Terrain group cache: capacity={d} hits={d} misses={d} reads={d}\n", .{ groups.entries.len, groups.metrics.hits.value(), groups.metrics.misses.value(), groups.metrics.reads.value() });
    try output.interface.print("Storage reads: batches={d} pages={d} bytes={d}\n", .{ store.read_batches.value(), store.read_pages.value(), store.read_bytes.value() });
    try output.interface.print("{s} observer x={d:.1} y={d:.1} z={d:.1}\n", .{ if (cave) "cave" else "surface", player_records[0].position.x, player_records[0].position.y, player_records[0].position.z });
    const work = streaming.deps.lighting.background.work;
    try output.interface.print("Lighting reuse: {} full_solves={d} scrolls={d} material_rows={d} retained_rows={d} propagated_rows={d} candidate_rows={d} source_rows={d} reset_rows={d}\n", .{ retain_lighting, work.relights, work.scrolls, work.loaded_rows, work.retained_rows, work.propagated_rows, work.candidate_rows, work.source_rows, work.reset_rows });
    try output.interface.print("{s} {d}  {d:.2}  {d:.2}  {d:.2}  {d:.2}  {d:.2}  {d}  {d}  {d}  {d} {d} {d} {d} {d} {d} {d} {x}\n", .{
        if (concealment) "on " else "off",
        streaming.streams[0].delivered,
        @as(f64, @floatFromInt(elapsed_cpu)) / std.time.ns_per_ms,
        @as(f64, @floatFromInt(elapsed_wall)) / std.time.ns_per_ms,
        @as(f64, @floatFromInt(bytes)) / (1024 * 1024),
        @as(f64, @floatFromInt(wire_bytes)) / (1024 * 1024),
        @as(f64, @floatFromInt(bounded.allocated_bytes - bounded.freed_bytes)) / (1024 * 1024),
        work.decoded_sections,
        work.acquisition_batches,
        work.relights,
        streaming.geometry.visits,
        streaming.geometry.cache_hits,
        streaming.geometry.lookup.count(),
        streaming.geometry.query_lookup.count(),
        streaming.concealed_sections.value(),
        streaming.geometry.builds,
        streaming.geometry.change_lookups,
        digest.final(),
    });
    try output.interface.writeAll("Stage timings include nested stages. Do not sum parent and child totals.\nStage                                      clock       count     total_ms      max_ms\n");
    for (0..registry.count) |index| {
        const value = registry.at(index);
        if (value.kind != .timer or value.count == 0) continue;
        try output.interface.print("{s:<42} {s:<10} {d:>7} {d:>12.2} {d:>11.2}\n", .{ value.name, @tagName(value.clock), value.count, @as(f64, @floatFromInt(value.total)) / std.time.ns_per_ms, @as(f64, @floatFromInt(value.maximum)) / std.time.ns_per_ms });
    }
    try output.interface.flush();
    if (streaming_options.movement) {
        const flight_ticks = 600;
        const extent: i32 = @intCast(radius);
        const tick_budget = 50 * std.time.ns_per_ms;
        const flight_start = player_records[0].position;
        var maximum_missing: usize = 0;
        var missing_sum: usize = 0;
        var complete_ticks: usize = 0;
        var settled_ticks: usize = 0;
        var flight_bytes: usize = 0;
        var flight_packets: usize = 0;
        var flight_encrypted_digest = std.hash.Wyhash.init(0);
        var maximum_poll: i96 = 0;
        var maximum_tick: i96 = 0;
        var overdue: i96 = 0;
        var maximum_overdue: i96 = 0;
        var over_budget_ticks: usize = 0;
        var skipped_work_ticks: usize = 0;
        var traffic_counts: [std.meta.tags(FlightPacket).len]usize = @splat(0);
        var traffic_bytes: [std.meta.tags(FlightPacket).len]usize = @splat(0);
        const side = 2 * delivery_radius + 1;
        const initial = Streaming.View.capture(player_records[0]).center;
        for (flight_columns, 0..) |_, index| {
            const x = initial.x - @as(i32, @intCast(delivery_radius)) + @as(i32, @intCast(index % side));
            const z = initial.z - @as(i32, @intCast(delivery_radius)) + @as(i32, @intCast(index / side));
            const slot: usize = @intCast(@mod(z, @as(i32, @intCast(side))) * @as(i32, @intCast(side)) + @mod(x, @as(i32, @intCast(side))));
            flight_columns[slot] = .{ .x = x, .z = z };
        }
        const visits_before = streaming.geometry.visits;
        const builds_before = streaming.geometry.builds;
        _ = registry.snapshot(flight_metrics);
        const flight_cpu = std.Io.Clock.now(.cpu_thread, io).nanoseconds;
        for (0..flight_ticks) |tick| {
            const tick_started = std.Io.Clock.now(.cpu_thread, io).nanoseconds;
            player_records[0].position.x = flight_start.x + @as(f64, @floatFromInt(tick + 1)) * flight_speed / 20;
            player_records[0].position.y = @max(150, flight_start.y);
            players.rebuildIndexes();
            service.beginTick();
            streaming.endTick(true);
            service.endTick(true);
            skipped_work_ticks += @intFromBool(!streaming_options.flight_settle and overdue >= tick_budget);
            // Late work consumes the next interval instead of receiving a fresh budget.
            var polls: usize = 0;
            while (streaming_options.flight_settle or std.Io.Clock.now(.cpu_thread, io).nanoseconds - tick_started + overdue < tick_budget) {
                polls += 1;
                if (polls > 100000) return error.StreamingStalled;
                const poll_started = std.Io.Clock.now(.cpu_thread, io).nanoseconds;
                if (!retain_lighting) streaming.deps.lighting.background.solved = null;
                {
                    const timing = terrain_cpu.start();
                    defer timing.end();
                    try background.poll();
                }
                maximum_poll = @max(maximum_poll, std.Io.Clock.now(.cpu_thread, io).nanoseconds - poll_started);
                const output_timing = output_cpu.start();
                defer output_timing.end();
                var batch = service.outputBatch();
                while (batch.next()) |packet| {
                    flight_packets += 1;
                    const frame = frame: {
                        const timing = compression_cpu.start();
                        defer timing.end();
                        break :frame try compression.encode(service.output.framingStorage(packet), packet.bytes.len, 256, compressed);
                    };
                    const header = try wire.play.toClient.readHeader(packet.bytes);
                    const protocol = player_records[packet.recipients.first().?.index].protocol;
                    var kind: FlightPacket = .other;
                    inline for (protocols.implementations) |Version| {
                        if (protocol == Version.protocol_number) {
                            if (header.id == Version.Protocol.play.toClient.packetId(.map_chunk)) {
                                const at: Streaming.Position = .{ .x = std.mem.readInt(i32, header.body[0..4], .big), .z = std.mem.readInt(i32, header.body[4..8], .big) };
                                const slot: usize = @intCast(@mod(at.z, @as(i32, @intCast(side))) * @as(i32, @intCast(side)) + @mod(at.x, @as(i32, @intCast(side))));
                                kind = if (std.meta.eql(flight_columns[slot], at)) .replacement else .new_column;
                                flight_columns[slot] = at;
                            } else if (header.id == Version.Protocol.play.toClient.packetId(.update_light)) kind = .light else if (header.id == Version.Protocol.play.toClient.packetId(.chunk_biomes)) kind = .biomes;
                        }
                    }
                    traffic_counts[@backingInt(kind)] += 1;
                    traffic_bytes[@backingInt(kind)] += frame.len * packet.recipients.len;
                    flight_bytes += frame.len * packet.recipients.len;
                    var recipients = packet.recipients.iterator();
                    while (recipients.next()) |handle| {
                        if (streaming_options.encryption) {
                            const timing = encryption_cpu.start();
                            ciphers[handle.index].encrypt(frame, encrypted[0..frame.len]);
                            timing.end();
                            flight_encrypted_digest.update(encrypted[0..frame.len]);
                        }
                        service.refund(handle, service.framedBound(packet.bytes.len));
                    }
                    service.recycle(io, &.{packet});
                }
                if (!streaming.pending and streaming.light_pending.words.count == 0) break;
            }
            streaming.tick();
            const elapsed = std.Io.Clock.now(.cpu_thread, io).nanoseconds - tick_started;
            maximum_tick = @max(maximum_tick, elapsed);
            over_budget_ticks += @intFromBool(elapsed > tick_budget);
            overdue = @max(0, overdue + elapsed - tick_budget);
            maximum_overdue = @max(maximum_overdue, overdue);
            const view = Streaming.View.capture(player_records[0]);
            const center = view.center;
            var missing: usize = 0;
            for (0..(2 * radius + 1) * (2 * radius + 1)) |column| {
                const x = center.x - extent + @as(i32, @intCast(column % (2 * radius + 1)));
                const z = center.z - extent + @as(i32, @intCast(column / (2 * radius + 1)));
                missing += @intFromBool(!streaming.visibleView(0, view, world, x, z));
            }
            maximum_missing = @max(maximum_missing, missing);
            missing_sum += missing;
            complete_ticks += @intFromBool(missing == 0);
            settled_ticks += @intFromBool(missing == 0 and !streaming.pending and streaming.light_pending.words.count == 0);
        }
        try output.interface.print("Flight: speed={d:.0}_blocks/s occlusion={} settle={} ticks={d} complete_ticks={d} settled_ticks={d} over_budget_ticks={d} skipped_work_ticks={d} max_missing_columns={d} mean_missing_columns={d:.2} CPU_ms={d:.2} max_poll_ms={d:.2} max_tick_ms={d:.2} max_overdue_ms={d:.2} wire_MiB={d:.2} packets={d} encrypted_hash={x}\n", .{ flight_speed, concealment, streaming_options.flight_settle, flight_ticks, complete_ticks, settled_ticks, over_budget_ticks, skipped_work_ticks, maximum_missing, @as(f64, @floatFromInt(missing_sum)) / flight_ticks, @as(f64, @floatFromInt(std.Io.Clock.now(.cpu_thread, io).nanoseconds - flight_cpu)) / std.time.ns_per_ms, @as(f64, @floatFromInt(maximum_poll)) / std.time.ns_per_ms, @as(f64, @floatFromInt(maximum_tick)) / std.time.ns_per_ms, @as(f64, @floatFromInt(maximum_overdue)) / std.time.ns_per_ms, @as(f64, @floatFromInt(flight_bytes)) / (1024 * 1024), flight_packets, flight_encrypted_digest.final() });
        try output.interface.print("Flight geometry: visits={d} section_builds={d}\n", .{ streaming.geometry.visits - visits_before, streaming.geometry.builds - builds_before });
        inline for (std.meta.tags(FlightPacket)) |kind| try output.interface.print("Flight traffic: kind={s} packets={d} wire_MiB={d:.2}\n", .{ @tagName(kind), traffic_counts[@backingInt(kind)], @as(f64, @floatFromInt(traffic_bytes[@backingInt(kind)])) / (1024 * 1024) });
        for (flight_metrics, 0..) |before, index| {
            const after = registry.at(index);
            if (after.kind == .counter) {
                if (after.value != before.value) try output.interface.print("Flight counter: {s} {d}\n", .{ after.name, after.value - before.value });
            } else if (after.kind == .timer and after.clock == .thread_cpu and after.count != before.count) {
                try output.interface.print("Flight stage: {s:<42} count={d} CPU_ms={d:.2}\n", .{ after.name, after.count - before.count, @as(f64, @floatFromInt(after.total - before.total)) / std.time.ns_per_ms });
            }
        }
        try output.interface.flush();
        if (streaming_options.flight_settle) {
            try std.testing.expectEqual(@as(usize, flight_ticks), complete_ticks);
            try std.testing.expectEqual(@as(usize, flight_ticks), settled_ticks);
        }
    }
    return digest.final();
}
