const std = @import("std");
const lightning_rod = @import("lightning_rod");
const terrain = @import("vanilla_terrain");
const vanilla_lighting = @import("plugins/vanilla_lighting.zig");

const chunk_count = 64;
const trials = 6;
const tile_sizes = [_]u8{ 1, 2, 3, 4, 8 };
const seed = 0x6d62_756e_6400_0001;
const world = lightning_rod.world_identity.Handle{ .index = 0, .generation = 1 };
const Position = lightning_rod.geometry.ChunkPos;
const Pipeline = enum { interleaved, prelit, cached };

const Result = struct {
    shape_bytes: u64 = 0,
    payload_bytes: u64 = 0,
    framed_bytes: u64 = 0,
    lighting_ns: u64 = 0,
    encoding_ns: u64 = 0,
    compression_ns: u64 = 0,
    total_ns: u64 = 0,
};

pub fn main(_: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source_blocks = try createBlocks(allocator);
    var generator = try terrain.Generator.init(allocator, seed, 3);
    var positions: [chunk_count]Position = undefined;
    var shape_bytes: u64 = 0;
    for (&positions, 0..) |*position, index| {
        position.* = samplePosition(index);
        const shape = try generator.generate(position.x, position.z);
        shape_bytes += shape.storage_len;
        _ = try source_blocks.installResidentChunk(world, shape, 1, .persisted);
    }

    var legacy_order = positions;
    var spatial_orders: [tile_sizes.len][chunk_count]Position = undefined;
    sortPositions(&legacy_order, radialLess);
    for (tile_sizes, &spatial_orders) |tile_size, *order| {
        order.* = positions;
        sortSpatial(order, tile_size);
    }
    var legacy = try measure(source_blocks, &legacy_order, .interleaved);
    var spatial_interleaved: [tile_sizes.len]Result = @splat(.{});
    for (&spatial_orders, &spatial_interleaved) |*order, *result|
        result.* = try measure(source_blocks, order, .interleaved);
    var spatial = try measure(source_blocks, &spatial_orders[2], .prelit);
    var cached = try measure(source_blocks, &spatial_orders[1], .cached);
    legacy.shape_bytes = shape_bytes * trials;
    for (&spatial_interleaved) |*result| result.shape_bytes = shape_bytes * trials;
    spatial.shape_bytes = shape_bytes * trials;
    cached.shape_bytes = shape_bytes * trials;
    printResults(legacy, spatial_interleaved, spatial, cached);
}

fn measure(source: *lightning_rod.blocks.Blocks, order: *const [chunk_count]Position, pipeline: Pipeline) !Result {
    var total = Result{};
    for (0..trials) |_| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const blocks = try createBlocks(arena.allocator());
        for (order) |position| {
            const resident = source.residentChunk(world, position).?;
            _ = try blocks.installResidentChunk(world, resident.shape, 1, .persisted);
        }
        const lighting = try createLighting(arena.allocator(), blocks);
        var scratch: [lightning_rod.chunk_packet.maximum_payload_bytes]u8 = undefined;
        var framed: [lightning_rod.chunk_packet.maximum_payload_bytes + 64 * 1024]u8 = undefined;
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        switch (pipeline) {
            .interleaved => add(&total, try runLegacy(blocks, lighting, order, &scratch, &framed, &window)),
            .prelit => add(&total, try runPrelit(blocks, lighting, order, &scratch, &framed, &window)),
            .cached => {
                for (order) |position| _ = lighting.chunk(world, position);
                add(&total, try runLegacy(blocks, lighting, order, &scratch, &framed, &window));
            },
        }
    }
    return total;
}

fn add(total: *Result, value: Result) void {
    total.payload_bytes += value.payload_bytes;
    total.framed_bytes += value.framed_bytes;
    total.lighting_ns += value.lighting_ns;
    total.encoding_ns += value.encoding_ns;
    total.compression_ns += value.compression_ns;
    total.total_ns += value.total_ns;
}

fn createBlocks(allocator: std.mem.Allocator) !*lightning_rod.blocks.Blocks {
    return lightning_rod.blocks.Blocks.init(allocator, .{
        .maximum_resident_chunks = 128,
        .maximum_modified_sections = 128,
    });
}

fn createLighting(allocator: std.mem.Allocator, blocks: *lightning_rod.blocks.Blocks) !*vanilla_lighting.Lighting {
    const State = struct {
        var clock: lightning_rod.clock.Clock = .{};
        var players: lightning_rod.players.Players = undefined;
        var sessions: lightning_rod.sessions.Sessions = undefined;
    };
    return vanilla_lighting.Lighting.init(allocator, .{
        .clock = &State.clock,
        .blocks = blocks,
        .players = &State.players,
        .sessions = &State.sessions,
        .paging = null,
    }, .{});
}

fn runLegacy(blocks: *lightning_rod.blocks.Blocks, lighting: *vanilla_lighting.Lighting, positions: *const [chunk_count]Position, payload: []u8, framed: []u8, window: *[std.compress.flate.max_window_len]u8) !Result {
    var result = Result{};
    var player_view: lightning_rod.view.PlayerView = .{};
    const started = now();
    for (positions) |position| {
        const resident = blocks.residentChunk(world, position).?;
        var stage = now();
        const light = lighting.chunk(world, position);
        result.lighting_ns += now() - stage;
        stage = now();
        const encoded = try lightning_rod.chunk_packet.writeChunkPayload(payload, blocks, world, &player_view, position, &resident.shape, light, 772);
        result.encoding_ns += now() - stage;
        result.payload_bytes += encoded.len;
        stage = now();
        const framed_len = compressPacket(encoded, framed, window) orelse return error.CompressionCapacity;
        result.compression_ns += now() - stage;
        result.framed_bytes += framed_len;
    }
    result.total_ns = now() - started;
    return result;
}

fn runPrelit(blocks: *lightning_rod.blocks.Blocks, lighting: *vanilla_lighting.Lighting, positions: *const [chunk_count]Position, scratch: []u8, framed: []u8, window: *[std.compress.flate.max_window_len]u8) !Result {
    var result = Result{};
    var player_view: lightning_rod.view.PlayerView = .{};
    const started = now();
    var stage = now();
    for (positions) |position| _ = lighting.chunk(world, position);
    for (positions) |position| {
        const resident = blocks.residentChunk(world, position).?;
        const light = lighting.chunk(world, position);
        result.lighting_ns += now() - stage;
        stage = now();
        const payload = try lightning_rod.chunk_packet.writeChunkPayload(scratch, blocks, world, &player_view, position, &resident.shape, light, 772);
        result.encoding_ns += now() - stage;
        result.payload_bytes += payload.len;
        stage = now();
        const framed_len = compressPacket(payload, framed, window) orelse return error.CompressionCapacity;
        result.framed_bytes += framed_len;
        result.compression_ns += now() - stage;
        stage = now();
    }
    result.total_ns = now() - started;
    return result;
}

fn samplePosition(index: usize) Position {
    return .{ .x = @as(i32, @intCast(index & 7)) - 4, .z = @as(i32, @intCast(index >> 3)) - 4 };
}

fn sortPositions(positions: *[chunk_count]Position, less: *const fn (Position, Position) bool) void {
    for (0..positions.len) |left| {
        var least = left;
        for (left + 1..positions.len) |right|
            if (less(positions[right], positions[least])) {
                least = right;
            };
        if (least != left) std.mem.swap(Position, &positions[left], &positions[least]);
    }
}

fn radialLess(left: Position, right: Position) bool {
    const left_distance = left.x * left.x + left.z * left.z;
    const right_distance = right.x * right.x + right.z * right.z;
    if (left_distance != right_distance) return left_distance < right_distance;
    if (left.z != right.z) return left.z < right.z;
    return left.x < right.x;
}

fn sortSpatial(positions: *[chunk_count]Position, tile_size: u8) void {
    for (0..positions.len) |left| {
        var least = left;
        for (left + 1..positions.len) |right| {
            if (spatialLess(positions[right], positions[least], tile_size))
                least = right;
        }
        if (least != left) std.mem.swap(Position, &positions[left], &positions[least]);
    }
}

fn spatialLess(left: Position, right: Position, tile_size: u8) bool {
    const size: i32 = tile_size;
    const offset = @divFloor(size, 2);
    const left_tile = Position{ .x = @divFloor(left.x + offset, size), .z = @divFloor(left.z + offset, size) };
    const right_tile = Position{ .x = @divFloor(right.x + offset, size), .z = @divFloor(right.z + offset, size) };
    const left_distance = left_tile.x * left_tile.x + left_tile.z * left_tile.z;
    const right_distance = right_tile.x * right_tile.x + right_tile.z * right_tile.z;
    if (left_distance != right_distance) return left_distance < right_distance;
    if (left_tile.z != right_tile.z) return left_tile.z < right_tile.z;
    if (left_tile.x != right_tile.x) return left_tile.x < right_tile.x;
    return radialLess(left, right);
}

fn compressPacket(body: []const u8, output: []u8, window: *[std.compress.flate.max_window_len]u8) ?usize {
    const reserve = 10;
    var writer: std.Io.Writer = .fixed(output[reserve..]);
    var compressor = std.compress.flate.Compress.init(&writer, window, .zlib, .level_1) catch return null;
    compressor.writer.writeAll(body) catch return null;
    compressor.finish() catch return null;
    const compressed_len = writer.buffered().len;
    const data_prefix = varIntLen(@intCast(body.len));
    const outer_len = data_prefix + compressed_len;
    const outer_prefix = varIntLen(@intCast(outer_len));
    const total = outer_prefix + outer_len;
    if (total > output.len) return null;
    @memmove(output[outer_prefix + data_prefix ..][0..compressed_len], output[reserve..][0..compressed_len]);
    const rest = lightning_rod.protocol_support.write_varint(output, @intCast(outer_len)) catch return null;
    _ = lightning_rod.protocol_support.write_varint(rest, @intCast(body.len)) catch return null;
    return total;
}

fn varIntLen(value: i32) usize {
    var remaining: u32 = @bitCast(value);
    var length: usize = 1;
    while (remaining >= 0x80) : (length += 1) remaining >>= 7;
    return length;
}

fn printResults(legacy: Result, interleaved: [tile_sizes.len]Result, spatial: Result, cached: Result) void {
    std.debug.print(
        "streaming benchmark chunks={} trials={} protocol=772\n" ++
            "  resident shape                  {d:.1} KiB/chunk\n" ++
            "  packet payload                  {d:.1} KiB/chunk\n" ++
            "  compressed frame                {d:.1} KiB/chunk\n" ++
            "  legacy radial/interleaved       {d:.3} ms/chunk\n" ++
            "    lighting {d:.3}  encode {d:.3}  zlib {d:.3}\n" ++
            "  spatial tile sweep (interleaved)\n" ++
            "  spatial 3x3/prelit              {d:.3} ms/chunk\n" ++
            "    lighting {d:.3}  encode {d:.3}  zlib {d:.3}\n" ++
            "  prelit speedup                  {d:.2}x\n",
        .{
            chunk_count,
            trials,
            kibPerChunk(spatial.shape_bytes),
            kibPerChunk(spatial.payload_bytes),
            kibPerChunk(spatial.framed_bytes),
            msPerChunk(legacy.total_ns),
            msPerChunk(legacy.lighting_ns),
            msPerChunk(legacy.encoding_ns),
            msPerChunk(legacy.compression_ns),
            msPerChunk(spatial.total_ns),
            msPerChunk(spatial.lighting_ns),
            msPerChunk(spatial.encoding_ns),
            msPerChunk(spatial.compression_ns),
            @as(f64, @floatFromInt(interleaved[2].total_ns)) / @as(f64, @floatFromInt(spatial.total_ns)),
        },
    );
    std.debug.print(
        "  materialized light/interleaved    {d:.3} ms/chunk\n" ++
            "    lighting {d:.3}  encode {d:.3}  zlib {d:.3}\n",
        .{
            msPerChunk(cached.total_ns),
            msPerChunk(cached.lighting_ns),
            msPerChunk(cached.encoding_ns),
            msPerChunk(cached.compression_ns),
        },
    );
    for (tile_sizes, interleaved) |tile_size, result| std.debug.print(
        "    {}x{}  {d:.3} ms/chunk  lighting {d:.3}  encode {d:.3}  zlib {d:.3}  speedup {d:.2}x\n",
        .{
            tile_size,
            tile_size,
            msPerChunk(result.total_ns),
            msPerChunk(result.lighting_ns),
            msPerChunk(result.encoding_ns),
            msPerChunk(result.compression_ns),
            @as(f64, @floatFromInt(legacy.total_ns)) / @as(f64, @floatFromInt(result.total_ns)),
        },
    );
}

fn kibPerChunk(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (chunk_count * trials) / 1024;
}

fn msPerChunk(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / (chunk_count * trials) / std.time.ns_per_ms;
}

fn now() u64 {
    var value: std.os.linux.timespec = undefined;
    const result = std.os.linux.clock_gettime(.MONOTONIC, &value);
    if (std.os.linux.errno(result) != .SUCCESS) @panic("clock_gettime failed");
    return @as(u64, @intCast(value.sec)) * std.time.ns_per_s + @as(u64, @intCast(value.nsec));
}
