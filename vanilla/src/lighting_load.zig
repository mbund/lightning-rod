const vanilla_content = @import("vanilla_content.zig");
const std = @import("std");
const streaming_options = @import("streaming_benchmark_options");
const chunks = @import("chunks");
const deflate = @import("deflate");
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
const BenchmarkNetwork = @import("streaming_network_bench.zig").Network;
const wire = @import("wire_1_21_5");

const FlightPacket = enum { new_column, replacement, biomes, light, other };

// Fragment assembly starts with a stored header block. The oracle needs only its coordinates.
fn packetPrefix(packet: sessions.RawPacket) ![]const u8 {
    if (packet.decoded_length == 0) return packet.bytes;
    const bytes = packet.bytes;
    if (bytes.len < 7 or bytes[2] != 0) return error.InvalidPreparedHeader;
    const length = std.mem.readInt(u16, bytes[3..5], .little);
    if (length < 11 or length > bytes.len - 7 or ~length != std.mem.readInt(u16, bytes[5..7], .little)) return error.InvalidPreparedHeader;
    return bytes[7..][0..length];
}

fn encryptPacket(ciphers: []minecraft_java.Wire, source: []const u8, output: []u8, recipients: sessions.Recipients, timer: metrics.Timer, digest: *std.hash.Wyhash) void {
    var selected = recipients.iterator();
    const stride = output.len / @min(ciphers.len, minecraft_java.Wire.encryption_batch_size);
    std.debug.assert(source.len <= stride);
    while (true) {
        var jobs: [minecraft_java.Wire.encryption_batch_size]minecraft_java.Wire.Encryption = undefined;
        var count: usize = 0;
        while (count < jobs.len) {
            const handle = selected.next() orelse break;
            jobs[count] = ciphers[handle.index].encryption(output[count * stride ..][0..source.len], &.{});
            count += 1;
        }
        if (count == 0) break;
        const timing = timer.start();
        minecraft_java.Wire.encryptBatch(source, jobs[0..count]);
        timing.end();
        for (jobs[0..count]) |job| digest.update(job.first);
    }
}

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

test "cold lighting streams do not block a ready player behind a paused generator" {
    for ([_]usize{ 1, 16 }) |pages| {
        const io = std.testing.io;
        var directory = std.testing.tmpDir(.{});
        defer directory.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const allocator = bounded.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{});
        defer registry.deinit();
        var path: [256]u8 = undefined;
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = try std.fmt.bufPrint(&path, ".zig-cache/tmp/{s}/independent-streams", .{directory.sub_path}) });
        defer store.deinit();
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 2 }, .{ .storage = try store.openSpace("worlds") });
        for ([_][]const u8{ "test:cold", "test:ready" }) |name| _ = try dimensions.create(.{ .name = name, .dimension = .{ .name = name, .minimum_section = 0, .section_count = 1, .skylight = false } });
        var catalog = try protocols.Default.init(allocator);
        defer catalog.deinit(allocator);
        var sink: Sink = .{};
        const service = try sessions.Service.init(allocator, io, .{ .context = &sink, .vtable = network.Transport.adapter(Sink) }, .{ .connections = 2, .pages = pages, .page_bytes = 128 * 1024, .buffer_bytes = 1024 * 1024, .protocols = &catalog.values });
        defer service.deinit();
        var player_records: [2]Players.Player = undefined;
        for (&player_records, 0..) |*player, index| {
            player.* = .{ .handle = .{ .index = index, .generation = 1 }, .uuid = index + 1, .world = @intCast(index), .stage = .ready, .loaded = true, .position = .{ .x = 0.5, .y = 8, .z = 0.5 }, .protocol = catalog.values[0].number };
            service.credit[index].store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
        }
        var players: Players = .{ .deps = undefined, .config = .{ .maximum = player_records.len, .render_distance = 1 }, .spawn_world = 0, .records = &player_records, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        players.rebuildIndexes();
        const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 48, .demand_sections = 24, .cache_groups = 4 }, .{ .metrics = &registry, .storage = try store.openSpace(chunks.Chunks.id), .record_workspaces = try records.Workspaces.init(allocator, io, .{}) });
        for (0..25) |index| {
            const position: chunks.Position = .{ .x = (@as(i32, @intCast(index % 5)) - 2) * 16, .y = 0, .z = (@as(i32, @intCast(index / 5)) - 2) * 16 };
            try terrain.setBlock(1, position, game_data.registry.block_stone_default_state);
            try terrain.setBlock(1, position, 0);
        }
        var source: Scene = .{ .empty = true };
        terrain.setSource(chunks.Source.init(&source, Scene.read));
        const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
        const streaming = try Streaming.init(allocator, io, .{ .occlusion = false, .fallback_biome = @intCast(game_data.registry.biomeId("minecraft:plains").?) }, .{ .metrics = &registry, .players = &players, .chunks = terrain, .sessions = service, .packets = encoding, .worlds = dimensions, .lighting = try Lighting.init(allocator, .{ .stored = false }, .{ .metrics = &registry, .blocks = try vanilla_content.blocks(allocator), .chunks = terrain, .worlds = dimensions }) });
        defer service.unsubscribeOutput(streaming.changed);
        defer terrain.unsubscribeReady(streaming.changed);
        terrain.attach();
        defer terrain.stop();
        terrain.generation.parallel.store(true, .release);
        bounded.fail_index = bounded.alloc_index;
        bounded.resize_fail_index = bounded.resize_index;
        service.beginTick();
        streaming.endTick(true);
        service.endTick(true);
        var deliveries: [2]usize = @splat(0);
        var chunk_id: ?i32 = null;
        inline for (protocols.implementations) |Version| if (Version.protocol_number == catalog.values[0].number) {
            chunk_id = Version.Protocol.play.toClient.packetId(.map_chunk);
        };
        for (0..2) |phase| {
            if (phase == 1) terrain.generation.parallel.store(false, .release);
            for (0..32) |_| {
                if (phase == 1) {
                    _ = try terrain.generation.processBatch(io);
                    try terrain.poll();
                }
                _ = try streaming.poll(io);
                var output = service.outputBatch();
                while (output.next()) |packet| {
                    defer service.recycle(io, &.{packet});
                    const header = try wire.play.toClient.readHeader(try packetPrefix(packet));
                    var recipients = packet.recipients.iterator();
                    while (recipients.next()) |handle| {
                        service.refund(handle, service.framedBound(packet.boundLength()));
                        if (header.id == chunk_id.?) deliveries[handle.index] += 1;
                    }
                }
            }
            try std.testing.expectEqual(if (phase == 0) @as(usize, 0) else Streaming.Horizon.count(players.config.render_distance), deliveries[0]);
            try std.testing.expectEqual(Streaming.Horizon.count(players.config.render_distance), deliveries[1]);
            try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
            try std.testing.expectEqual(service.config.buffer_bytes, service.outputCredit(player_records[1].handle.?));
            if (phase == 0) try std.testing.expect(terrain.generation.queued_count > 0);
        }
        try std.testing.expect(!bounded.has_induced_failure);
    }
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
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256, .detailed_timers = true });
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
            // Each observer gets a background turn before the next simulation mutation.
            for (0..count) |_| {
                try background.poll();
                while (try terrain.generation.processOne(io)) {}
                try terrain.poll();
                var output_batch = service.outputBatch();
                while (output_batch.next()) |packet| {
                    packet_count += 1;
                    deliveries += packet.recipients.len;
                    var recipients = packet.recipients.iterator();
                    while (recipients.next()) |handle| service.refund(handle, service.framedBound(packet.boundLength()));
                    service.recycle(io, &.{packet});
                }
                try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
            }
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
            while (recipients.next()) |handle| service.refund(handle, service.framedBound(packet.boundLength()));
            service.recycle(io, &.{packet});
        }
        settled = streaming.lightSettled();
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

/// What one client holds for a column, by layer and light section. Section zero is the
/// one below the world.
const ClientLight = struct {
    const sections_max = 8;
    layers: [2][sections_max][2048]u8,

    /// Applies one light update exactly as a client does. Sections the packet does not
    /// name keep what the client had.
    fn apply(self: *ClientLight, data: []const u8, count: usize) !void {
        var reader = std.Io.Reader.fixed(data);
        var masks: [4]u64 = undefined;
        for (&masks) |*mask| {
            if (try reader.takeLeb128(u32) != 1) return error.InvalidLightMask;
            mask.* = try reader.takeInt(u64, .big);
        }
        // Sky arrays come first on the wire. Layer one is sky.
        for ([_]usize{ 1, 0 }, 0..) |layer, order| {
            if (masks[order] & masks[order + 2] != 0 or (masks[order] | masks[order + 2]) >> @intCast(count) != 0) return error.InvalidLightMask;
            if (try reader.takeLeb128(u32) != @popCount(masks[order])) return error.InvalidLightCount;
            for (0..count) |section| {
                const bit = @as(u64, 1) << @intCast(section);
                if (masks[order] & bit != 0) {
                    if (try reader.takeLeb128(u32) != 2048) return error.InvalidLightArray;
                    @memcpy(&self.layers[layer][section], try reader.take(2048));
                } else if (masks[order + 2] & bit != 0) @memset(&self.layers[layer][section], 0);
            }
        }
        if (reader.seek != data.len) return error.TrailingLightData;
    }
};

test "edited light reaches every holder exactly and only where it changed" {
    const io = std.testing.io;
    const count = 2;
    const radius = 2;
    const window = 2 * radius + 1;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/edited-light", .{directory.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
    defer registry.deinit();
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    const resources = try records.Workspaces.init(allocator, io, .{});
    const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
    const dimension: worlds.Worlds.Dimension = .{ .name = "test:dimension", .minimum_section = 3, .section_count = 3, .skylight = true };
    const world = try dimensions.create(.{ .name = "test:edited", .dimension = dimension });
    const light_sections = dimension.sectionCount() + 2;
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
        player.* = .{ .handle = .{ .index = index, .generation = 1 }, .uuid = index + 1, .world = world, .stage = .ready, .loaded = true, .position = .{ .x = 8, .y = 70, .z = 8 }, .protocol = catalog.values[0].number };
        service.credit[index].store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
    }
    var players: Players = .{ .deps = undefined, .config = .{ .maximum = count, .render_distance = radius }, .spawn_world = world, .records = player_records, .dig_handlers = &.{} };
    try players.initIndexes(allocator);
    players.rebuildIndexes();
    const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 192, .demand_sections = 48, .cache_groups = 8 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = resources });
    var source: Scene = .{};
    terrain.setSource(chunks.Source.init(&source, Scene.read));
    const light_rules = try vanilla_content.blocks(allocator);
    const streaming = try Streaming.init(allocator, io, .{ .occlusion = false, .fallback_biome = @intCast(game_data.registry.biomeId("minecraft:plains").?) }, .{ .metrics = &registry, .players = &players, .chunks = terrain, .sessions = service, .packets = encoding, .worlds = dimensions, .lighting = try Lighting.init(allocator, .{ .stored = false }, .{ .metrics = &registry, .blocks = light_rules, .chunks = terrain, .worlds = dimensions }) });
    defer service.unsubscribeOutput(streaming.changed);
    defer terrain.unsubscribeReady(streaming.changed);
    const blocks = try BlockSynchronization.init(allocator, io, .{ .metrics = &registry, .chunks = terrain, .players = &players, .streaming = streaming, .sessions = service, .packets = encoding, .worlds = dimensions }, .{});
    var background: Terrain = .{ .chunks = terrain, .streaming = streaming, .blocks = blocks, .io = io };
    background.start();
    defer background.stop();
    var light_id: ?i32 = null;
    inline for (protocols.implementations) |Version| if (Version.protocol_number == catalog.values[0].number) {
        light_id = Version.Protocol.play.toClient.packetId(.update_light);
    };
    const reference = try @import("lighting.zig").Workspace.init(allocator, terrain, light_rules.light);
    const clients = try allocator.alloc(ClientLight, count * window * window);
    const truth = try allocator.create(ClientLight);
    const Harness = struct {
        fn slot(player: usize, x: i32, z: i32) usize {
            return player * window * window + @as(usize, @intCast(z + radius)) * window + @as(usize, @intCast(x + radius));
        }
    };

    // Deliver the whole horizon to both players before any edit.
    var delivered = false;
    for (0..2048) |_| {
        service.beginTick();
        streaming.endTick(true);
        blocks.endTick(true);
        service.endTick(true);
        try background.poll();
        while (try terrain.generation.processOne(io)) {}
        try terrain.poll();
        var output = service.outputBatch();
        while (output.next()) |packet| {
            var recipients = packet.recipients.iterator();
            while (recipients.next()) |handle| service.refund(handle, service.framedBound(packet.boundLength()));
            service.recycle(io, &.{packet});
        }
        delivered = true;
        for (streaming.streams) |stream| delivered = delivered and stream.setup == .streaming and stream.cursor == Streaming.Horizon.count(radius);
        if (delivered and !streaming.pending) break;
    }
    try std.testing.expect(delivered);

    const glowstone: u16 = @intCast(game_data.registry.block_glowstone_default_state);
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    const glass: u16 = @intCast(game_data.registry.block_glass_default_state);
    const Edit = struct { x: i32, y: i32, z: i32, state: u16 };
    // Each round is one tick, or two ticks the streaming thread sees together.
    const scripted = [_][]const []const Edit{
        // Two sources in neighbouring columns in one tick. Each alone would hide the other's
        // effect on the cells between them.
        &.{&.{ .{ .x = 15, .y = 70, .z = 8, .state = glowstone }, .{ .x = 17, .y = 70, .z = 8, .state = glowstone } }},
        // The same pair again, split over two ticks whose patches are sent together.
        &.{ &.{.{ .x = 15, .y = 70, .z = 8, .state = 0 }}, &.{.{ .x = 17, .y = 70, .z = 8, .state = 0 }} },
        &.{ &.{.{ .x = 0, .y = 75, .z = 15, .state = glowstone }}, &.{.{ .x = -1, .y = 75, .z = 16, .state = glowstone }} },
        // A cell written twice before its light is sent.
        &.{ &.{.{ .x = 0, .y = 75, .z = 15, .state = stone }}, &.{.{ .x = 0, .y = 75, .z = 15, .state = 0 }} },
        // Glass lights like air. A roof block dims only what is under it.
        &.{&.{ .{ .x = 5, .y = 80, .z = 5, .state = glass }, .{ .x = 20, .y = 90, .z = 20, .state = stone } }},
        &.{&.{ .{ .x = -1, .y = 75, .z = 16, .state = 0 }, .{ .x = 20, .y = 90, .z = 20, .state = 0 } }},
        // One tick with a patch where light is stored and an edit where none is. The
        // mail then carries sections for some columns and only the names of others.
        &.{&.{ .{ .x = 8, .y = 72, .z = 8, .state = glowstone }, .{ .x = 40, .y = 72, .z = 40, .state = glowstone } }},
        &.{&.{ .{ .x = 8, .y = 72, .z = 8, .state = 0 }, .{ .x = 40, .y = 72, .z = 40, .state = stone }, .{ .x = -24, .y = 72, .z = 40, .state = glowstone } }},
    };
    var random: u64 = 0x1f2e3d4c5b6a7988;
    var light_packets: usize = 0;
    var edited_columns: usize = 0;
    var generated: [2][6]Edit = undefined;
    for (0..scripted.len + 14) |round| {
        // The model starts from the truth once. Afterwards only packets may change it.
        if (round == 0) for (0..count) |player| {
            for (0..window * window) |index| {
                const x = @as(i32, @intCast(index % window)) - radius;
                const z = @as(i32, @intCast(index / window)) - radius;
                try solveColumn(reference, terrain, io, world, x, z, dimension, &clients[Harness.slot(player, x, z)]);
            }
        };
        var ticks: [2][]const Edit = undefined;
        var tick_count: usize = 0;
        if (round < scripted.len) {
            for (scripted[round]) |tick| {
                ticks[tick_count] = tick;
                tick_count += 1;
            }
        } else {
            tick_count = 1 + (round % 2);
            for (generated[0..tick_count], ticks[0..tick_count]) |*list, *tick| {
                for (list) |*edit| {
                    random ^= random << 13;
                    random ^= random >> 7;
                    random ^= random << 17;
                    // Cluster around the borders of the centre column, where light crosses.
                    edit.* = .{
                        .x = @as(i32, @intCast(random % 26)) - 5,
                        .y = 64 + @as(i32, @intCast((random >> 8) % 30)),
                        .z = @as(i32, @intCast((random >> 16) % 26)) - 5,
                        .state = switch ((random >> 24) % 5) {
                            0, 1 => glowstone,
                            2 => stone,
                            3 => glass,
                            else => 0,
                        },
                    };
                }
                tick.* = list;
            }
        }
        var touched: [2 * 6][2]i32 = undefined;
        var touched_count: usize = 0;
        for (ticks[0..tick_count]) |tick| {
            service.beginTick();
            for (tick) |edit| {
                try terrain.setBlock(world, .{ .x = edit.x, .y = edit.y, .z = edit.z }, edit.state);
                const column = [2]i32{ @divFloor(edit.x, 16), @divFloor(edit.z, 16) };
                var seen = false;
                for (touched[0..touched_count]) |other| seen = seen or std.meta.eql(other, column);
                if (!seen) {
                    touched[touched_count] = column;
                    touched_count += 1;
                }
            }
            streaming.endTick(true);
            blocks.endTick(true);
            service.endTick(true);
        }
        edited_columns += touched_count;
        var settled = false;
        for (0..512) |_| {
            try background.poll();
            while (try terrain.generation.processOne(io)) {}
            try terrain.poll();
            var output = service.outputBatch();
            while (output.next()) |packet| {
                defer service.recycle(io, &.{packet});
                const header = try wire.play.toClient.readHeader(try packetPrefix(packet));
                var body = std.Io.Reader.fixed(header.body);
                const is_light = header.id == light_id.?;
                const x: i32 = if (is_light) @bitCast(try body.takeLeb128(u32)) else 0;
                const z: i32 = if (is_light) @bitCast(try body.takeLeb128(u32)) else 0;
                light_packets += @intFromBool(is_light);
                var recipients = packet.recipients.iterator();
                while (recipients.next()) |handle| {
                    service.refund(handle, service.framedBound(packet.boundLength()));
                    if (!is_light) continue;
                    // An update may only name a column around an edit of this round.
                    var near = false;
                    for (touched[0..touched_count]) |column| near = near or (@abs(x - column[0]) <= 1 and @abs(z - column[1]) <= 1);
                    try std.testing.expect(near);
                    try clients[Harness.slot(handle.index, x, z)].apply(header.body[body.seek..], light_sections);
                }
            }
            settled = !streaming.pending and streaming.lightSettled();
            if (settled) break;
            service.beginTick();
            streaming.endTick(true);
            blocks.endTick(true);
            service.endTick(true);
        }
        try std.testing.expect(settled);
        for (0..window * window) |index| {
            const x = @as(i32, @intCast(index % window)) - radius;
            const z = @as(i32, @intCast(index / window)) - radius;
            try solveColumn(reference, terrain, io, world, x, z, dimension, truth);
            for (0..count) |player| {
                try std.testing.expect(streaming.visibleView(player, streaming.views[player], world, x, z));
                const client = &clients[Harness.slot(player, x, z)];
                for (0..2) |layer| for (0..light_sections) |section| {
                    if (std.mem.eql(u8, &truth.layers[layer][section], &client.layers[layer][section])) continue;
                    std.debug.print("stale light round={d} player={d} column={d},{d} layer={d} section={d}\n", .{ round, player, x, z, layer, section });
                    return error.StaleClientLight;
                };
            }
        }
    }
    // Updating all nine columns around each edit for both players would take far more.
    try std.testing.expect(light_packets != 0);
    try std.testing.expect(light_packets < edited_columns * 4);
    try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
}

fn solveColumn(workspace: *@import("lighting.zig").Workspace, terrain: *chunks.Chunks, io: std.Io, world: u32, x: i32, z: i32, dimension: worlds.Worlds.Dimension, output: *ClientLight) !void {
    var solved = false;
    for (0..256) |_| {
        solved = try workspace.prepare(terrain, world, x, z, dimension, 0);
        if (solved) break;
        while (try terrain.generation.processOne(io)) {}
        try terrain.poll();
    }
    if (!solved) return error.LightingDidNotSettle;
    for (0..2) |layer| for (0..dimension.sectionCount() + 2) |section| {
        workspace.engine.packSection(if (layer == 0) .block else .sky, .{ 1, section, 1 }, &output.layers[layer][section]);
    };
}

test "streaming movement preserves planned owners while delivery catches up" {
    const render_distance = 4;
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
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256, .detailed_timers = true });
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
            while (recipients.next()) |handle| service.refund(handle, service.framedBound(packet.boundLength()));
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
    // Delivered counts are compared with the horizon, which holds only when columns unload at
    // the delivery radius. The client storage band has its own streaming test.
    const streaming = try Streaming.init(allocator, io, .{ .retain_client_storage = false }, .{ .metrics = &registry, .players = &players, .chunks = terrain, .sessions = service, .packets = encoding, .worlds = dimensions, .lighting = try Lighting.init(allocator, .{}, .{ .metrics = &registry, .blocks = try vanilla_content.blocks(allocator), .chunks = terrain, .worlds = dimensions }) });
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
    for (0..streaming.geometry.views.len * streaming.geometry.views[0].masks.len * 8 + 1) |_| {
        while (try terrain.generation.processOne(io)) {}
        try terrain.poll();
        try background.poll();
        for (streaming.streams, &first_terrain, 0..) |stream, *received, index| {
            if (received.* or stream.delivered == 0) continue;
            const occupied: u32 = 1 << 8;
            try std.testing.expectEqual(occupied, streaming.disclosed[index * streaming.grid.columns + streaming.grid.at(stream.center)] & occupied);
            try std.testing.expectEqual(occupied, ~streaming.occluded[index * streaming.grid.columns + streaming.grid.at(stream.center)] & occupied);
            if (!streaming.sources[index].known) {
                try std.testing.expectEqual(occupied, streaming.disclosed[index * streaming.grid.columns + streaming.grid.at(stream.center)]);
                try std.testing.expectEqual(occupied, ~streaming.occluded[index * streaming.grid.columns + streaming.grid.at(stream.center)] & ((1 << 24) - 1));
            }
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
                while (recipients.next()) |handle| service.refund(handle, service.framedBound(packet.boundLength()));
                service.recycle(io, &.{packet});
            }
        }
        try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
        var complete = true;
        for (streaming.streams, player_records) |stream, player| {
            const center = Streaming.View.capture(player).center;
            complete = complete and stream.setup == .streaming and stream.cursor == columns and stream.delivered == Streaming.Horizon.count(render_distance) and stream.center.x == center.x and stream.center.z == center.z;
        }
        if (!initialized) {
            if (!complete) continue;
            const side = render_distance * 2 + 1;
            for (streaming.streams, 0..) |stream, recipient| for (0..columns) |index| {
                const at: Streaming.Position = .{ .x = stream.center.x + @as(i32, @intCast(index % side)) - render_distance, .z = stream.center.z + @as(i32, @intCast(index / side)) - render_distance };
                // The per-player grid covers the client storage band, which is wider than the horizon.
                const slot = recipient * streaming.grid.columns + streaming.grid.at(at);
                const expected: u32 = if (Streaming.Horizon.contains(render_distance, stream.center, at)) 0 else std.math.maxInt(u32);
                try std.testing.expectEqual(expected, streaming.occluded[slot]);
            };
            initialized = true;
            continue;
        }
        if (movements == movement_ticks and complete) break;
    } else return error.MovingStreamDidNotSettle;
    try std.testing.expectEqual(@as(usize, movement_ticks), movements);
    try std.testing.expect(delivered > columns * player_records.len);
    for (player_records) |player| try std.testing.expectEqual(service.config.buffer_bytes, service.outputCredit(player.handle.?));
}

fn observerOffset(count: usize, index: usize, spacing: usize) [2]f64 {
    std.debug.assert(count > 0 and index < count);
    const width = @min(count, 8);
    const rows = std.math.divCeil(usize, count, width) catch unreachable;
    const distance: f64 = @floatFromInt(spacing * 16);
    return .{
        (@as(f64, @floatFromInt(index % width)) - @as(f64, @floatFromInt(width - 1)) / 2) * distance,
        (@as(f64, @floatFromInt(index / width)) - @as(f64, @floatFromInt(rows - 1)) / 2) * distance,
    };
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
    var origin: [2]f64 = .{ 8.5, 8.5 };
    if (streaming_options.position) |text| {
        var parts = std.mem.splitScalar(u8, text, ',');
        origin[0] = try std.fmt.parseFloat(f64, parts.next() orelse return error.InvalidPosition);
        _ = parts.next() orelse return error.InvalidPosition;
        origin[1] = try std.fmt.parseFloat(f64, parts.next() orelse return error.InvalidPosition);
        if (parts.next() != null) return error.InvalidPosition;
    }
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
        const offset = observerOffset(count, index, streaming_options.spacing);
        center.* = .{
            @intFromFloat(@floor((origin[0] + offset[0]) / 16)),
            @intFromFloat(@floor((origin[1] + offset[1]) / 16)),
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
    if (streaming_options.codec_workers) |counts| {
        var reference: [2]?u64 = @splat(null);
        var selected = std.mem.splitScalar(u8, counts, ',');
        while (selected.next()) |value| {
            const workers = try std.fmt.parseInt(usize, value, 10);
            for ([_]bool{ false, true }) |concealment| {
                if (streaming_options.occlusion) |enabled| if (concealment != enabled) continue;
                const result = try streamPlayers(.{ .occlusion = concealment, .players = streaming_options.players, .spacing = streaming_options.spacing, .codec_workers = workers });
                const hash = result.packet_hash;
                const previous = &reference[@intFromBool(concealment)];
                if (streaming_options.validate_output) {
                    if (previous.*) |expected| try std.testing.expectEqual(expected, hash) else previous.* = hash;
                }
            }
        }
        return;
    }
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
                _ = try streamPlayers(.{ .occlusion = concealment, .players = streaming_options.players, .spacing = streaming_options.spacing, .speed = speed, .flight = true });
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
    return (try streamPlayers(.{ .occlusion = concealment, .cave = cave, .retain_lighting = retain_lighting, .players = streaming_options.players, .spacing = streaming_options.spacing })).packet_hash;
}

test "imported world player scaling" {
    if (streaming_options.movement or streaming_options.lighting_comparison) return error.InvalidScalingOptions;
    for ([_]usize{ 1, 8, 32 }) |count| for ([_]usize{ 0, 4 }) |spacing| {
        if (count == 1 and spacing != 0) continue;
        for ([_]bool{ false, true }) |concealment| _ = try streamPlayers(.{ .occlusion = concealment, .players = count, .spacing = spacing });
    };
}

const StreamingResult = struct { packet_hash: u64, cpu_ns: u64, wire_bytes: u64 };

const StreamingCase = struct {
    occlusion: bool,
    cave: bool = false,
    retain_lighting: bool = true,
    players: usize,
    spacing: usize,
    speed: f64 = 80,
    flight: bool = false,
    roaming: bool = false,
    cache_groups: usize = 32,
    visibility_columns: ?usize = null,
    protocol: ?i32 = null,
    encryption: bool = streaming_options.encryption,
    codec_workers: ?usize = null,
    fragment_level: ?u4 = null,
};

test "imported world horizon scaling" {
    if (streaming_options.corpus != null and (streaming_options.occlusion == null or std.mem.indexOfScalar(u8, streaming_options.horizon_players, ',') != null)) return error.CorpusRequiresSingleStreamingMode;
    const protocol = protocols.implementations[protocols.implementations.len - 1].protocol_number;
    var counts = std.mem.splitScalar(u8, streaming_options.horizon_players, ',');
    while (counts.next()) |text| {
        const count = try std.fmt.parseInt(usize, text, 10);
        for ([_]bool{ true, false }) |occlusion| {
            if (streaming_options.occlusion) |selected| if (selected != occlusion) continue;
            _ = try streamPlayers(.{ .occlusion = occlusion, .players = count, .spacing = streaming_options.spacing, .flight = true, .roaming = !streaming_options.flight_straight, .cache_groups = 32, .protocol = protocol, .encryption = true });
        }
    }
}

fn streamPlayers(workload: StreamingCase) !StreamingResult {
    if (workload.codec_workers != null and (workload.flight or streaming_options.corpus != null)) return error.UnsupportedBenchmarkCombination;
    const concealment = workload.occlusion;
    const cave = workload.cave;
    const retain_lighting = workload.retain_lighting;
    const count = workload.players;
    const spacing = workload.spacing;
    const flight_speed = workload.speed;
    const io = std.testing.io;
    const path = streaming_options.world orelse return error.MissingStreamingWorld;
    if (count == 0) return error.InvalidPlayerCount;
    const radius = streaming_options.radius;
    const prefetch = streaming_options.prefetch;
    const delivery_radius = radius + @as(usize, prefetch);
    const window = (2 * delivery_radius + 1) * (2 * delivery_radius + 1);
    const target = Streaming.Horizon.count(@intCast(delivery_radius));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = bounded.allocator();
    var compression: ?minecraft_java.Wire.Workspace = if (workload.codec_workers == null) try minecraft_java.Wire.Workspace.init(allocator) else null;
    defer if (compression) |*workspace| workspace.deinit();
    const compressed = try allocator.alloc(u8, if (workload.codec_workers == null) (1 << 21) + sessions.shared_headroom else 0);
    const decoded = try allocator.alloc(u8, compressed.len);
    const encrypted = try allocator.alloc(u8, if (workload.encryption and workload.codec_workers == null) compressed.len * @min(count, minecraft_java.Wire.encryption_batch_size) else 0);
    const ciphers = try allocator.alloc(minecraft_java.Wire, if (workload.encryption and workload.codec_workers == null) count else 0);
    for (ciphers, 0..) |*cipher, index| {
        cipher.* = .{};
        var secret: [16]u8 = @splat(0x37);
        std.mem.writeInt(u64, secret[0..8], @intCast(index), .little);
        cipher.install(secret);
    }
    var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 256, .detailed_timers = streaming_options.detailed_timers });
    defer registry.deinit();
    var storage_metrics = try metrics.Registry.init(allocator, io, .{ .capacity = 64, .parent = &registry, .detailed_timers = true });
    defer storage_metrics.deinit();
    const compression_cpu = try registry.timer(.{ .name = "benchmark.compression.cpu", .description = "Protocol compression on the benchmark thread", .clock = .thread_cpu });
    const encryption_cpu = try registry.timer(.{ .name = "benchmark.encryption.cpu", .description = "Production cipher for each recipient", .clock = .thread_cpu });
    const terrain_cpu = try registry.timer(.{ .name = "benchmark.terrain.cpu", .description = "Complete terrain poll including storage and streaming", .clock = .thread_cpu, .detailed = true });
    const output_cpu = try registry.timer(.{ .name = "benchmark.output.cpu", .description = "Drain output including compression hashing and recycling", .clock = .thread_cpu, .detailed = true });
    const hash_cpu = try registry.timer(.{ .name = "benchmark.hash.cpu", .description = "Hash uncompressed packets for correctness", .clock = .thread_cpu, .detailed = true });
    var store = try storage.Store.init(allocator, io, .{ .path = path, .metrics = &storage_metrics });
    defer store.deinit();
    const resources = try records.Workspaces.init(allocator, io, .{ .metrics = &registry });
    const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 16 }, .{ .storage = try store.openSpace(worlds.Worlds.id) });
    const world = (dimensions.find("minecraft:overworld") orelse return error.MissingOverworld).id;
    var catalog = try protocols.Default.init(allocator);
    defer catalog.deinit(allocator);
    var sink: Sink = .{};
    const service = try sessions.Service.init(allocator, io, .{ .context = &sink, .vtable = network.Transport.adapter(Sink) }, .{ .connections = count, .protocols = &catalog.values });
    defer {
        if (service.tick_active) service.endTick(false);
        var pending = service.outputBatch();
        while (pending.next()) |packet| service.recycle(io, &.{packet});
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
        player.* = .{ .handle = .{ .index = index, .generation = 1 }, .uuid = index + 1, .world = world, .stage = .ready, .loaded = true, .position = .{ .x = 8.5, .y = 65, .z = 8.5 }, .protocol = workload.protocol orelse catalog.values[index % catalog.values.len].number };
        service.credit[index].store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
    }
    const benchmark_network: ?*BenchmarkNetwork = if (workload.codec_workers) |workers| try BenchmarkNetwork.init(allocator, io, service, &catalog, &registry, workers, workload.encryption, radius, streaming_options.validate_output) else null;
    defer if (benchmark_network) |owner| owner.stop() catch |err| std.debug.panic("Benchmark network failed: {s}", .{@errorName(err)});
    var players: Players = .{ .deps = undefined, .config = .{ .maximum = count, .render_distance = radius }, .spawn_world = world, .records = player_records, .dig_handlers = &.{} };
    try players.initIndexes(allocator);
    players.rebuildIndexes();
    const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 192, .demand_sections = 24, .cache_groups = workload.cache_groups }, .{ .metrics = &registry, .storage = try store.openSpace(chunks.Chunks.id), .record_workspaces = resources });
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
        const offset = observerOffset(count, index, spacing);
        player.position.x += offset[0];
        player.position.z += offset[1];
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
    if (workload.flight) for (player_records) |*player| {
        player.position.y = @max(150, player.position.y);
    };
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
    const streaming = try Streaming.init(allocator, io, .{ .occlusion = concealment, .prefetch = prefetch, .occlusion_columns = workload.visibility_columns }, .{ .metrics = &registry, .players = &players, .chunks = terrain, .sessions = service, .packets = encoding, .worlds = dimensions, .lighting = try Lighting.init(allocator, .{ .stored = streaming_options.stored_lighting }, .{ .metrics = &registry, .blocks = try vanilla_content.blocks(allocator), .chunks = terrain, .worlds = dimensions }) });
    defer service.unsubscribeOutput(streaming.changed);
    defer terrain.unsubscribeReady(streaming.changed);
    if (workload.fragment_level) |level| for ([_]*deflate.fragments.Baker{ &streaming.deps.lighting.stored_workspace.fragment_baker, &streaming.deps.lighting.terrain_baker.compressor, &streaming.encoding.uniform_light.baker, &streaming.delivery.baker }) |baker| {
        const owner = baker.allocator;
        baker.deinit();
        baker.* = try .initLevel(owner, level);
    };
    const blocks = try BlockSynchronization.init(allocator, io, .{ .metrics = &registry, .chunks = terrain, .players = &players, .streaming = streaming, .sessions = service, .packets = encoding, .worlds = dimensions }, .{});

    var background: Terrain = .{ .chunks = terrain, .streaming = streaming, .blocks = blocks, .io = io };
    const metric_count = registry.count + storage_metrics.count;
    const flight_metrics = try allocator.alloc(metrics.Snapshot, if (workload.flight) metric_count else 0);
    const after_metrics = try allocator.alloc(metrics.Snapshot, if (workload.flight) metric_count else 0);
    const flight_columns = try allocator.alloc(Streaming.Position, if (workload.flight) count * window else 0);
    const flight_starts = try allocator.alloc(@FieldType(Players.Player, "position"), if (workload.flight) count else 0);
    const flight_directions = try allocator.alloc([2]f64, if (workload.flight) count else 0);
    var random = std.Random.DefaultPrng.init(0x4e81bac);
    for (flight_starts, flight_directions, player_records[0..flight_starts.len]) |*start, *direction, player| {
        start.* = player.position;
        const angle = random.random().float(f64) * std.math.pi * 2;
        direction.* = .{ @cos(angle) * flight_speed / 20, @sin(angle) * flight_speed / 20 };
    }
    background.start();
    defer background.stop();
    if (benchmark_network) |owner| try owner.start(terrain.ready());
    registry.seal();
    storage_metrics.seal();
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    const reserved_bytes = bounded.allocated_bytes - bounded.freed_bytes;
    service.beginTick();
    streaming.endTick(true);
    service.endTick(true);
    const started = std.Io.Clock.now(.awake, io).nanoseconds;
    const cpu = std.Io.Clock.now(.cpu_thread, io).nanoseconds;
    const process_cpu = std.Io.Clock.now(.cpu_process, io).nanoseconds;
    if (benchmark_network) |owner| owner.begin();
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
        if (benchmark_network != null) {
            terrain.ready().reset();
        }
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
        if (benchmark_network) |owner| {
            try owner.pollInline();
        } else {
            var batch = service.outputBatch();
            while (batch.next()) |packet| {
                defer service.recycle(io, &.{packet});
                bytes += if (packet.decoded_length == 0) packet.bytes.len else packet.decoded_length;
                const raw = raw: {
                    const timing = hash_cpu.start();
                    defer timing.end();
                    break :raw if (packet.decoded_length == 0) packet.bytes else try compression.?.decompressor.decode(packet.bytes, decoded[0..packet.decoded_length]);
                };
                const frame = frame: {
                    const timing = compression_cpu.start();
                    defer timing.end();
                    break :frame if (packet.decoded_length == 0) try compression.?.encode(service.output.framingStorage(packet), packet.bytes.len, 256, compressed) else try compression.?.prepared(service.output.framingStorage(packet), packet.bytes.len, packet.decoded_length, 256, compressed);
                };
                wire_bytes += frame.len;
                if (corpus_writer) |*writer| {
                    try writer.interface.writeInt(u32, @intCast(raw.len), .little);
                    try writer.interface.writeInt(u32, @intCast(frame.len), .little);
                    try writer.interface.writeInt(u64, packet.recipients.len, .little);
                    var targets = packet.recipients.iterator();
                    while (targets.next()) |handle| try writer.interface.writeInt(u64, handle.index, .little);
                    try writer.interface.writeAll(raw);
                    try writer.interface.writeAll(frame);
                }
                {
                    const timing = hash_cpu.start();
                    defer timing.end();
                    digest.update(raw);
                }
                var recipients = packet.recipients.iterator();
                if (workload.encryption) encryptPacket(ciphers, frame, encrypted, packet.recipients, encryption_cpu, &encrypted_digest);
                while (recipients.next()) |handle| {
                    deliveries += 1;
                    recipient_bytes += frame.len;
                    progress[handle.index].wire_bytes += frame.len;
                    service.refund(handle, service.framedBound(packet.boundLength()));
                }
            }
        }
        complete = true;
        var minimum_delivered = target;
        var maximum_delivered: usize = 0;
        var milestone_cpu: ?i96 = null;
        for (streaming.streams, progress) |stream, *player_progress| {
            complete = complete and stream.cursor == window and stream.delivered == target;
            minimum_delivered = @min(minimum_delivered, stream.delivered);
            maximum_delivered = @max(maximum_delivered, stream.delivered);
            for (milestones, &player_progress.milestones) |threshold, *reached| {
                if (reached.* != 0 or stream.delivered < threshold) continue;
                if (milestone_cpu == null) milestone_cpu = std.Io.Clock.now(.cpu_thread, io).nanoseconds - cpu;
                reached.* = milestone_cpu.?;
            }
        }
        maximum_lead = @max(maximum_lead, maximum_delivered - minimum_delivered);
        if (!complete) if (benchmark_network) |owner| {
            if (!terrain.ready().isSet()) try owner.wait();
        };
    }
    if (benchmark_network) |owner| {
        try owner.drain();
        for (owner.hashes, owner.bytes, progress) |*hash, sent, *player_progress| {
            var value: [8]u8 = undefined;
            std.mem.writeInt(u64, &value, hash.final(), .little);
            encrypted_digest.update(&value);
            recipient_bytes += sent;
            player_progress.wire_bytes = sent;
        }
        bytes = owner.worker.instruments.encoded_bytes.value();
        wire_bytes = recipient_bytes;
        deliveries = owner.worker.instruments.encoded_packets.value();
    }
    const elapsed_cpu = std.Io.Clock.now(.cpu_thread, io).nanoseconds - cpu;
    const elapsed_wall = std.Io.Clock.now(.awake, io).nanoseconds - started;
    const elapsed_process_cpu = std.Io.Clock.now(.cpu_process, io).nanoseconds - process_cpu;
    const network_hash = if (benchmark_network != null) encrypted_digest.final() else 0;
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
    if (workload.codec_workers) |workers| try output.interface.print("Production pipeline: codec_workers={d} validated={} detailed_timers={} wall_ms={d:.2} process_CPU_ms={d:.2} terrain_thread_CPU_ms={d:.2} validation_CPU_ms={d:.2} server_CPU_ms={d:.2} terrain_hash={x} biome_hash={x}\n", .{ workers, streaming_options.validate_output, streaming_options.detailed_timers, @as(f64, @floatFromInt(elapsed_wall)) / std.time.ns_per_ms, @as(f64, @floatFromInt(elapsed_process_cpu)) / std.time.ns_per_ms, @as(f64, @floatFromInt(elapsed_cpu)) / std.time.ns_per_ms, @as(f64, @floatFromInt(benchmark_network.?.validation_cpu_ns)) / std.time.ns_per_ms, @as(f64, @floatFromInt(elapsed_process_cpu - benchmark_network.?.validation_cpu_ns)) / std.time.ns_per_ms, benchmark_network.?.terrainHash(), benchmark_network.?.biomeHash() });
    if (streaming_options.corpus) |output_path| try output.interface.print("Packet corpus: {s}. Capture I/O is included in pipeline timings.\n", .{output_path});
    try output.interface.writeAll("Native world streaming with protocol compression, excluding sockets and client rendering\nocclusion chunks   CPU_ms   wall_ms  packet_MiB wire_MiB  pipeline_MiB  decoded  batches  relights  visits  sweep_batches columns sweeps occluded section_builds change_lookups packet_hash\n");
    try output.interface.print("players={d} spacing_chunks={d} encryption={} {s}={d} recipient_wire_MiB={d:.2} reserved_MiB={d:.2} runtime_allocations=0 encrypted_hash={x}\n", .{ count, spacing, workload.encryption, if (benchmark_network != null) "framing_operations" else "deliveries", deliveries, @as(f64, @floatFromInt(recipient_bytes)) / (1024 * 1024), @as(f64, @floatFromInt(reserved_bytes)) / (1024 * 1024), if (benchmark_network != null) network_hash else encrypted_digest.final() });
    try output.interface.print("Observer horizons: radius_chunks={d} columns_per_player={d} minimum_separation_chunks={d} overlapping_pairs={d} overlapping_light_halos={d}\n", .{ delivery_radius, target, minimum_separation, overlapping_horizons, overlapping_light_halos });
    try output.interface.print("Benchmark codec output buffers included above: compression_MiB={d:.2} encryption_MiB={d:.2}\n", .{ @as(f64, @floatFromInt(compressed.len)) / (1024 * 1024), @as(f64, @floatFromInt(encrypted.len)) / (1024 * 1024) });
    try output.interface.print("Streaming fairness: maximum_column_lead={d}\nplayer first_column_CPU_ms halfway_CPU_ms complete_CPU_ms wire_MiB\n", .{maximum_lead});
    for (progress, 0..) |player_progress, index| {
        try output.interface.print("{d} {d:.2} {d:.2} {d:.2} {d:.2}\n", .{ index, @as(f64, @floatFromInt(player_progress.milestones[0])) / std.time.ns_per_ms, @as(f64, @floatFromInt(player_progress.milestones[1])) / std.time.ns_per_ms, @as(f64, @floatFromInt(player_progress.milestones[2])) / std.time.ns_per_ms, @as(f64, @floatFromInt(player_progress.wire_bytes)) / (1024 * 1024) });
    }
    try output.interface.print("Idle simulation snapshot exchange: {d} ns/tick over {d} ticks, excluding other gameplay\n", .{ snapshot_ns, snapshot_samples });
    try output.interface.print("Stored lighting: enabled={} hits={d} misses={d} decodes={d}\n", .{ streaming_options.stored_lighting, streaming.deps.lighting.stored_hits.value(), streaming.deps.lighting.stored_misses.value(), streaming.deps.lighting.stored_decodes.value() });
    try output.interface.print("Terrain section reads: {d}\n", .{terrain.cache.metrics.reads.value()});
    const groups = &terrain.cache.backend.store.bases;
    try output.interface.print("Terrain group cache: capacity={d} pipeline_capacity={d} hits={d} misses={d} reads={d} layouts={d} decoded_MiB={d:.2} resident_slots={d} used_KiB={d:.2} peak_KiB={d:.2}\n", .{ groups.capacity, groups.physical_capacity - groups.capacity, groups.metrics.hits.value(), groups.metrics.misses.value(), groups.metrics.reads.value(), terrain.cache.backend.store.layout_builds, @as(f64, @floatFromInt(groups.backend.decoded_bytes.value())) / (1024 * 1024), groups.entries.len, @as(f64, @floatFromInt(groups.value_storage.used_bytes)) / 1024, @as(f64, @floatFromInt(groups.value_storage.peak_bytes)) / 1024 });
    try output.interface.print("Stored visibility: restored_sections={d} decoded_MiB={d:.2}\n", .{ streaming.geometry.restored, @as(f64, @floatFromInt(terrain.cache.backend.store.classification_decoded_bytes.value())) / (1024 * 1024) });
    try output.interface.print("Visibility operations: column_acquisitions={d} section_resolutions={d}\n", .{ streaming.geometry.acquisitions, streaming.geometry.section_resolutions });
    try output.interface.print("Storage reads: batches={d} pages={d} bytes={d}\n", .{ store.read_batches.value(), store.read_pages.value(), store.read_bytes.value() });
    try output.interface.print("{s} observer x={d:.1} y={d:.1} z={d:.1}\n", .{ if (cave) "cave" else "surface", player_records[0].position.x, player_records[0].position.y, player_records[0].position.z });
    const work = streaming.deps.lighting.background.work;
    try output.interface.print("Lighting reuse: {} full_solves={d} scrolls={d} material_rows={d} retained_rows={d} propagated_rows={d} candidate_rows={d} source_rows={d} darkened_rows={d}\n", .{ retain_lighting, work.relights, work.scrolls, work.loaded_rows, work.retained_rows, work.propagated_rows, work.candidate_rows, work.source_rows, work.darkened_rows });
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
        streaming.geometry.traversal_batches,
        streaming.geometry.lookup.count(),
        streaming.geometry.completed,
        streaming.concealed_sections.value(),
        streaming.geometry.builds,
        streaming.geometry.change_lookups,
        if (benchmark_network != null) network_hash else digest.final(),
    });
    try output.interface.writeAll("Stage timings include nested stages. Do not sum parent and child totals.\nStage                                      clock       count     total_ms      max_ms\n");
    for ([_]*metrics.Registry{ &registry, &storage_metrics }) |owner| for (0..owner.count) |index| {
        const value = owner.at(index);
        if (value.kind != .timer or value.count == 0) continue;
        try output.interface.print("{s:<42} {s:<10} {d:>7} {d:>12.2} {d:>11.2}\n", .{ value.name, @tagName(value.clock), value.count, @as(f64, @floatFromInt(value.total)) / std.time.ns_per_ms, @as(f64, @floatFromInt(value.maximum)) / std.time.ns_per_ms });
    };
    try output.interface.flush();
    if (workload.flight and streaming_options.flight_ticks != 0) {
        const flight_ticks = streaming_options.flight_ticks;
        const extent: i32 = @intCast(radius);
        const tick_budget = 50 * std.time.ns_per_ms;
        var complete_player_ticks: usize = 0;
        var required_columns: usize = 0;
        var accounting_cpu: i96 = 0;
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
        for (player_records, 0..) |player, recipient| {
            const initial = Streaming.View.capture(player).center;
            for (0..window) |index| {
                const x = initial.x - @as(i32, @intCast(delivery_radius)) + @as(i32, @intCast(index % side));
                const z = initial.z - @as(i32, @intCast(delivery_radius)) + @as(i32, @intCast(index / side));
                const slot: usize = @intCast(@mod(z, @as(i32, @intCast(side))) * @as(i32, @intCast(side)) + @mod(x, @as(i32, @intCast(side))));
                const at: Streaming.Position = .{ .x = x, .z = z };
                flight_columns[recipient * window + slot] = if (Streaming.Horizon.contains(@intCast(delivery_radius), initial, at)) at else .{ .x = std.math.minInt(i32), .z = std.math.minInt(i32) };
            }
        }
        const visits_before = streaming.geometry.visits;
        const builds_before = streaming.geometry.builds;
        const layouts_before = terrain.cache.backend.store.layout_builds;
        _ = try registry.snapshotTree(flight_metrics);
        const flight_cpu = std.Io.Clock.now(.cpu_thread, io).nanoseconds;
        for (0..flight_ticks) |tick| {
            const tick_started = std.Io.Clock.now(.cpu_thread, io).nanoseconds;
            for (player_records, flight_starts, flight_directions) |*player, start, *direction| {
                const before = Streaming.View.capture(player.*).center;
                if (workload.roaming) {
                    if (@abs(player.position.x + direction[0] - start.x) > 64) direction[0] = -direction[0];
                    if (@abs(player.position.z + direction[1] - start.z) > 64) direction[1] = -direction[1];
                    player.position.x += direction[0];
                    player.position.z += direction[1];
                } else player.position.x = start.x + @as(f64, @floatFromInt(tick + 1)) * flight_speed / 20;
                player.position.y = @max(150, start.y);
                const after = Streaming.View.capture(player.*).center;
                required_columns += Streaming.Horizon.differenceCount(@intCast(radius), before, after);
            }
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
                    defer service.recycle(io, &.{packet});
                    flight_packets += 1;
                    const frame = frame: {
                        const timing = compression_cpu.start();
                        defer timing.end();
                        break :frame if (packet.decoded_length == 0) try compression.?.encode(service.output.framingStorage(packet), packet.bytes.len, 256, compressed) else try compression.?.prepared(service.output.framingStorage(packet), packet.bytes.len, packet.decoded_length, 256, compressed);
                    };
                    const header = try wire.play.toClient.readHeader(try packetPrefix(packet));
                    const protocol = player_records[packet.recipients.first().?.index].protocol;
                    var kind: FlightPacket = .other;
                    var chunk_at: ?Streaming.Position = null;
                    var unload_at: ?Streaming.Position = null;
                    inline for (protocols.implementations) |Version| {
                        if (protocol == Version.protocol_number) {
                            if (header.id == Version.Protocol.play.toClient.packetId(.map_chunk)) {
                                chunk_at = .{ .x = std.mem.readInt(i32, header.body[0..4], .big), .z = std.mem.readInt(i32, header.body[4..8], .big) };
                            } else if (header.id == Version.Protocol.play.toClient.packetId(.unload_chunk)) {
                                unload_at = .{ .z = std.mem.readInt(i32, header.body[0..4], .big), .x = std.mem.readInt(i32, header.body[4..8], .big) };
                            } else if (header.id == Version.Protocol.play.toClient.packetId(.update_light)) kind = .light else if (header.id == Version.Protocol.play.toClient.packetId(.chunk_biomes)) kind = .biomes;
                        }
                    }
                    flight_bytes += frame.len * packet.recipients.len;
                    var recipients = packet.recipients.iterator();
                    if (workload.encryption) encryptPacket(ciphers, frame, encrypted, packet.recipients, encryption_cpu, &flight_encrypted_digest);
                    while (recipients.next()) |handle| {
                        if (unload_at) |at| {
                            const slot = handle.index * window + @as(usize, @intCast(@mod(at.z, @as(i32, @intCast(side))) * @as(i32, @intCast(side)) + @mod(at.x, @as(i32, @intCast(side)))));
                            if (std.meta.eql(flight_columns[slot], at)) flight_columns[slot] = .{ .x = std.math.minInt(i32), .z = std.math.minInt(i32) };
                        }
                        if (chunk_at) |at| {
                            const slot = handle.index * window + @as(usize, @intCast(@mod(at.z, @as(i32, @intCast(side))) * @as(i32, @intCast(side)) + @mod(at.x, @as(i32, @intCast(side)))));
                            kind = if (std.meta.eql(flight_columns[slot], at)) .replacement else .new_column;
                            flight_columns[slot] = at;
                        }
                        traffic_counts[@backingInt(kind)] += 1;
                        traffic_bytes[@backingInt(kind)] += frame.len;
                        service.refund(handle, service.framedBound(packet.boundLength()));
                    }
                }
                if (!streaming.pending and streaming.lightSettled()) break;
            }
            streaming.tick();
            const elapsed = std.Io.Clock.now(.cpu_thread, io).nanoseconds - tick_started;
            maximum_tick = @max(maximum_tick, elapsed);
            over_budget_ticks += @intFromBool(elapsed > tick_budget);
            overdue = @max(0, overdue + elapsed - tick_budget);
            maximum_overdue = @max(maximum_overdue, overdue);
            const accounting_start = std.Io.Clock.now(.cpu_thread, io).nanoseconds;
            var missing: usize = 0;
            for (player_records, 0..) |player, recipient| {
                const view = Streaming.View.capture(player);
                const center = view.center;
                var player_missing: usize = 0;
                for (0..(2 * radius + 1) * (2 * radius + 1)) |column| {
                    const x = center.x - extent + @as(i32, @intCast(column % (2 * radius + 1)));
                    const z = center.z - extent + @as(i32, @intCast(column / (2 * radius + 1)));
                    if (!Streaming.Horizon.contains(@intCast(radius), center, .{ .x = x, .z = z })) continue;
                    player_missing += @intFromBool(!streaming.visibleView(recipient, view, world, x, z));
                }
                complete_player_ticks += @intFromBool(player_missing == 0);
                missing += player_missing;
            }
            accounting_cpu += std.Io.Clock.now(.cpu_thread, io).nanoseconds - accounting_start;
            maximum_missing = @max(maximum_missing, missing);
            missing_sum += missing;
            complete_ticks += @intFromBool(missing == 0);
            settled_ticks += @intFromBool(missing == 0 and !streaming.pending and streaming.lightSettled());
        }
        const flight_elapsed = std.Io.Clock.now(.cpu_thread, io).nanoseconds - flight_cpu - accounting_cpu;
        try output.interface.print("Flight path: {s}\n", .{if (workload.roaming) "turning within independent observer areas" else "straight through fresh terrain"});
        try output.interface.print("Flight: players={d} speed={d:.0}_blocks/s occlusion={} encrypted={} cache_groups={d} settle={} ticks={d} complete_ticks={d} settled_ticks={d} over_budget_ticks={d} skipped_work_ticks={d} max_missing_columns={d} mean_missing_columns={d:.2} CPU_ms={d:.2} max_poll_ms={d:.2} max_tick_ms={d:.2} max_overdue_ms={d:.2} wire_MiB={d:.2} packets={d} encrypted_hash={x}\n", .{ count, flight_speed, concealment, workload.encryption, workload.cache_groups, streaming_options.flight_settle, flight_ticks, complete_ticks, settled_ticks, over_budget_ticks, skipped_work_ticks, maximum_missing, @as(f64, @floatFromInt(missing_sum)) / flight_ticks, @as(f64, @floatFromInt(flight_elapsed)) / std.time.ns_per_ms, @as(f64, @floatFromInt(maximum_poll)) / std.time.ns_per_ms, @as(f64, @floatFromInt(maximum_tick)) / std.time.ns_per_ms, @as(f64, @floatFromInt(maximum_overdue)) / std.time.ns_per_ms, @as(f64, @floatFromInt(flight_bytes)) / (1024 * 1024), flight_packets, flight_encrypted_digest.final() });
        try output.interface.print("Flight coverage: complete_player_ticks={d}/{d} required_new_columns={d} accounting_CPU_ms={d:.2}\n", .{ complete_player_ticks, count * flight_ticks, required_columns, @as(f64, @floatFromInt(accounting_cpu)) / std.time.ns_per_ms });
        try output.interface.print("Flight geometry: visits={d} section_builds={d} group_layouts={d}\n", .{ streaming.geometry.visits - visits_before, streaming.geometry.builds - builds_before, terrain.cache.backend.store.layout_builds - layouts_before });
        inline for (std.meta.tags(FlightPacket)) |kind| try output.interface.print("Flight traffic: kind={s} packets={d} wire_MiB={d:.2}\n", .{ @tagName(kind), traffic_counts[@backingInt(kind)], @as(f64, @floatFromInt(traffic_bytes[@backingInt(kind)])) / (1024 * 1024) });
        var compression_ns: u64 = 0;
        var encryption_ns: u64 = 0;
        var io_ns: u64 = 0;
        const final_metrics = try registry.snapshotTree(after_metrics);
        std.debug.assert(metric_count == final_metrics.len);
        for (flight_metrics, final_metrics) |before, after| {
            if (std.mem.eql(u8, after.name, "benchmark.compression.cpu")) compression_ns = after.total - before.total;
            if (std.mem.eql(u8, after.name, "benchmark.encryption.cpu")) encryption_ns = after.total - before.total;
            if (std.mem.eql(u8, after.name, "storage.read.cpu")) io_ns = after.total - before.total;
            if (after.kind == .counter) {
                if (after.value != before.value) try output.interface.print("Flight counter: {s} {d}\n", .{ after.name, after.value - before.value });
            } else if (after.kind == .timer and after.clock == .thread_cpu and after.count != before.count) {
                try output.interface.print("Flight stage: {s:<42} count={d} CPU_ms={d:.2}\n", .{ after.name, after.count - before.count, @as(f64, @floatFromInt(after.total - before.total)) / std.time.ns_per_ms });
            }
        }
        {
            const overhead = flight_elapsed - compression_ns - encryption_ns - io_ns;
            try output.interface.print("Flight CPU accounting: total_ms={d:.2} file_io_ms={d:.2} compression_ms={d:.2} encryption_ms={d:.2} overhead_ms={d:.2}\n", .{ @as(f64, @floatFromInt(flight_elapsed)) / std.time.ns_per_ms, @as(f64, @floatFromInt(io_ns)) / std.time.ns_per_ms, @as(f64, @floatFromInt(compression_ns)) / std.time.ns_per_ms, @as(f64, @floatFromInt(encryption_ns)) / std.time.ns_per_ms, @as(f64, @floatFromInt(overhead)) / std.time.ns_per_ms });
        }
        try output.interface.flush();
        if (streaming_options.flight_settle) {
            try std.testing.expectEqual(@as(usize, flight_ticks), complete_ticks);
            try std.testing.expectEqual(@as(usize, flight_ticks), settled_ticks);
        }
    }
    return .{ .packet_hash = if (benchmark_network) |owner| owner.terrainHash() else digest.final(), .cpu_ns = @intCast(elapsed_cpu), .wire_bytes = recipient_bytes };
}

test "imported world DEFLATE levels" {
    const io = std.testing.io;
    const path = streaming_options.world orelse return error.MissingStreamingWorld;
    if (!streaming_options.stored_lighting or streaming_options.codec_workers != null or streaming_options.corpus != null) return error.InvalidCompressionOptions;
    const samples = streaming_options.compression_samples;
    if (samples == 0 or samples > 15) return error.InvalidSampleCount;
    const levels = [_]u4{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const allocator = std.testing.allocator;
    const cold = try allocator.alloc(u64, levels.len * samples);
    defer allocator.free(cold);
    const warm = try allocator.alloc(u64, cold.len);
    defer allocator.free(warm);
    const cache_path = try std.mem.concat(allocator, u8, &.{ path, ".cache" });
    defer allocator.free(cache_path);
    var wire_bytes: [levels.len]u64 = @splat(0);
    var cache_bytes: [levels.len]u64 = @splat(0);
    var expected: ?u64 = null;
    for (0..samples) |sample| for (0..levels.len) |rank| {
        const level = (rank + sample * 3) % levels.len;
        std.Io.Dir.cwd().deleteFile(io, cache_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        const workload: StreamingCase = .{ .occlusion = streaming_options.occlusion orelse true, .players = streaming_options.players, .spacing = streaming_options.spacing, .encryption = true, .fragment_level = levels[level] };
        const built = try streamPlayers(workload);
        const reused = try streamPlayers(workload);
        try std.testing.expectEqual(built.packet_hash, reused.packet_hash);
        try std.testing.expectEqual(built.wire_bytes, reused.wire_bytes);
        if (expected) |hash| try std.testing.expectEqual(hash, built.packet_hash) else expected = built.packet_hash;
        cold[level * samples + sample] = built.cpu_ns;
        warm[level * samples + sample] = reused.cpu_ns;
        if (sample != 0) try std.testing.expectEqual(wire_bytes[level], built.wire_bytes);
        wire_bytes[level] = built.wire_bytes;
        const file = try std.Io.Dir.cwd().openFile(io, cache_path, .{});
        defer file.close(io);
        cache_bytes[level] = (try file.stat(io)).size;
        std.debug.print("DEFLATE level={d} sample={d}/{d} cold_CPU_ms={d:.2} warm_CPU_ms={d:.2} wire_bytes={d}\n", .{ level + 1, sample + 1, samples, @as(f64, @floatFromInt(built.cpu_ns)) / std.time.ns_per_ms, @as(f64, @floatFromInt(reused.cpu_ns)) / std.time.ns_per_ms, built.wire_bytes });
    };
    std.debug.print("\nReal terrain streaming. Median thread CPU, including lighting, cache work and encryption.\nlevel cold_CPU_ms warm_CPU_ms wire_MiB saved_percent cache_MiB\n", .{});
    for (levels, 0..) |_, level| {
        const build_samples = cold[level * samples ..][0..samples];
        const reuse_samples = warm[level * samples ..][0..samples];
        std.mem.sort(u64, build_samples, {}, std.sort.asc(u64));
        std.mem.sort(u64, reuse_samples, {}, std.sort.asc(u64));
        const saved = 100 * (1 - @as(f64, @floatFromInt(wire_bytes[level])) / @as(f64, @floatFromInt(wire_bytes[0])));
        std.debug.print("{d} {d:.2} {d:.2} {d:.4} {d:.2} {d:.2}\n", .{ level + 1, @as(f64, @floatFromInt(build_samples[samples / 2])) / std.time.ns_per_ms, @as(f64, @floatFromInt(reuse_samples[samples / 2])) / std.time.ns_per_ms, @as(f64, @floatFromInt(wire_bytes[level])) / (1024 * 1024), saved, @as(f64, @floatFromInt(cache_bytes[level])) / (1024 * 1024) });
    }
}
