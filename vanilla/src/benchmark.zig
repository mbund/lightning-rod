const std = @import("std");
const builtin = @import("builtin");
const lightning_rod = @import("lightning_rod");
const terrain = @import("vanilla_terrain");
const generation = @import("vanilla_generation.zig");

const measured_chunks = 256;
const warmup_chunks = 4;
const seed = 0x6d62_756e_6400_0001;
const Stage = terrain.Generator.GenerationStage;
const Feature = terrain.vanilla_worldgen.chunk.FeatureStage;
const RequestOrder = enum { radial, nearest, rows, center_sorted, sorted, tiled };

const Profile = struct {
    stage_ns: [enumCount(Stage)]u64 = @splat(0),
    stage_calls: [enumCount(Stage)]u64 = @splat(0),
    stage_max_ns: [enumCount(Stage)]u64 = @splat(0),
    feature_ns: [enumCount(Feature)]u64 = @splat(0),
    feature_calls: [enumCount(Feature)]u64 = @splat(0),

    fn record(self: *Profile, stage: Stage, feature: ?Feature, elapsed: u64) void {
        const stage_index = @intFromEnum(stage);
        self.stage_ns[stage_index] += elapsed;
        self.stage_calls[stage_index] += 1;
        self.stage_max_ns[stage_index] = @max(self.stage_max_ns[stage_index], elapsed);
        if (feature) |value| {
            const feature_index = @intFromEnum(value);
            self.feature_ns[feature_index] += elapsed;
            self.feature_calls[feature_index] += 1;
        }
    }

    fn total(self: *const Profile) u64 {
        var result: u64 = 0;
        for (self.stage_ns) |elapsed| result += elapsed;
        return result;
    }

    fn calls(self: *const Profile) u64 {
        var result: u64 = 0;
        for (self.stage_calls) |count| result += count;
        return result;
    }
};

const Generated = struct {
    x: i32,
    z: i32,
    checksum: u64,
};

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    if (args.next()) |mode| {
        if (std.mem.eql(u8, mode, "memory")) {
            if (args.next() != null) return error.UnexpectedArgument;
            const storage = try std.heap.page_allocator.alloc(u8, 64 * 1024 * 1024);
            defer std.heap.page_allocator.free(storage);
            var fixed = std.heap.FixedBufferAllocator.init(storage);
            var generator = try terrain.Generator.init(fixed.allocator(), seed);
            defer generator.deinit();
            std.debug.print("worldgen workspace={}B\n", .{fixed.end_index});
            return;
        }
        if (std.mem.eql(u8, mode, "service")) {
            try runServiceProfile(.sorted, false);
            return;
        }
        if (std.mem.eql(u8, mode, "service-radial")) {
            try runServiceProfile(.radial, false);
            return;
        }
        if (std.mem.eql(u8, mode, "service-nearest")) {
            try runServiceProfile(.nearest, false);
            return;
        }
        if (std.mem.eql(u8, mode, "service-rows")) {
            try runServiceProfile(.rows, false);
            return;
        }
        if (std.mem.eql(u8, mode, "service-center-sorted")) {
            try runServiceProfile(.center_sorted, false);
            return;
        }
        if (std.mem.eql(u8, mode, "service-fixed-center-sorted")) {
            try runServiceProfile(.center_sorted, true);
            return;
        }
        if (std.mem.eql(u8, mode, "service-streaming")) {
            try runStreamingServiceProfile();
            return;
        }
        if (std.mem.eql(u8, mode, "service-tiled")) {
            try runServiceProfile(.tiled, false);
            return;
        }
        if (std.mem.eql(u8, mode, "service-materialized")) {
            try runMaterializedServiceProfile();
            return;
        }
        return error.UnknownMode;
    }
    _ = try runProfile();
}

fn runStreamingServiceProfile() !void {
    var overworld = generation.Overworld.configured(.{});
    try overworld.initialize(std.heap.page_allocator);
    defer overworld.deinitialize();
    const order = try lightning_rod.chunk_stream.Order.create(std.heap.page_allocator, 32);
    defer std.heap.page_allocator.free(order.indices);
    var tracker: lightning_rod.chunk_stream.Tracker = .{};
    try tracker.allocate(std.heap.page_allocator, &order);
    defer std.heap.page_allocator.free(tracker.dirty_bits);
    defer std.heap.page_allocator.free(tracker.sent_bits);
    defer std.heap.page_allocator.free(tracker.translated_bits);
    tracker.reset(.{ .x = 0, .z = 0 });
    const positions = try std.heap.page_allocator.alloc(lightning_rod.geometry.ChunkPos, order.indices.len);
    defer std.heap.page_allocator.free(positions);
    var demands = tracker.missingIterator();
    for (positions) |*position| position.* = demands.next() orelse unreachable;
    const generated = try std.heap.page_allocator.alloc(Generated, positions.len);
    defer std.heap.page_allocator.free(generated);
    var generated_count: usize = 0;
    const started = now();
    for (positions) |position| {
        if (tracker.ready(position)) continue;
        const shape = try overworld.generate(seed, position);
        generated[generated_count] = .{ .x = shape.chunk_x, .z = shape.chunk_z, .checksum = 0 };
        generated_count += 1;
        tracker.mark(.{ .x = shape.chunk_x, .z = shape.chunk_z });
        std.mem.doNotOptimizeAway(&shape.heights);
    }
    const elapsed = now() - started;
    std.debug.print("worldgen service mode={s} order=production requests={} emitted={} throughput={d:.2} requested chunks/s mean={d:.3} ms/request\n", .{
        @tagName(builtin.mode),
        positions.len,
        generated_count,
        @as(f64, @floatFromInt(positions.len)) * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed)),
        @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(positions.len)) / std.time.ns_per_ms,
    });
}

fn runServiceProfile(request_order: RequestOrder, fixed: bool) !void {
    const fixed_storage: []u8 = if (fixed) try std.heap.page_allocator.alloc(u8, generation.Overworld.transient_workspace_bytes) else @constCast(&.{});
    defer if (fixed) std.heap.page_allocator.free(fixed_storage);
    var fixed_allocator = std.heap.FixedBufferAllocator.init(fixed_storage);
    var overworld = generation.Overworld.configured(.{});
    try overworld.initialize(if (fixed) fixed_allocator.allocator() else std.heap.page_allocator);
    defer overworld.deinitialize();
    const order = try lightning_rod.chunk_stream.Order.create(std.heap.page_allocator, 32);
    defer std.heap.page_allocator.free(order.indices);
    var tracker: lightning_rod.chunk_stream.Tracker = .{};
    try tracker.allocate(std.heap.page_allocator, &order);
    defer std.heap.page_allocator.free(tracker.dirty_bits);
    defer std.heap.page_allocator.free(tracker.sent_bits);
    var positions: [measured_chunks]lightning_rod.geometry.ChunkPos = undefined;
    switch (request_order) {
        .tiled => fillTiledPositions(&positions, &tracker),
        .rows => fillRowPositions(&positions, &tracker),
        .radial, .nearest, .center_sorted, .sorted => {
            var iterator = tracker.missingIterator();
            for (&positions) |*position| position.* = iterator.next() orelse unreachable;
            if (request_order == .sorted or request_order == .center_sorted)
                std.mem.sort(lightning_rod.geometry.ChunkPos, &positions, {}, chunkPositionLess);
            if (request_order == .center_sorted) {
                var center: usize = 0;
                while (positions[center].x != 0 or positions[center].z != 0) center += 1;
                std.mem.rotate(lightning_rod.geometry.ChunkPos, positions[0 .. center + 1], center);
            }
            if (request_order == .nearest) orderNearest(&positions);
        },
    }
    var generated: [2048]Generated = undefined;
    var generated_count: usize = 0;
    const started = now();
    var maximum: u64 = 0;
    for (positions) |position| {
        var present = false;
        for (generated[0..generated_count]) |entry| {
            if (entry.x == position.x and entry.z == position.z) {
                present = true;
                break;
            }
        }
        if (present) continue;
        const chunk_started = now();
        const shape = try overworld.generate(seed, position);
        generated[generated_count] = .{ .x = shape.chunk_x, .z = shape.chunk_z, .checksum = 0 };
        generated_count += 1;
        std.mem.doNotOptimizeAway(&shape.heights);
        maximum = @max(maximum, now() - chunk_started);
    }
    const elapsed = now() - started;
    std.debug.print("worldgen service mode={s} allocator={s} order={s} requests={} produced={} throughput={d:.2} chunks/s mean={d:.3} ms/chunk max={d:.3} ms\n", .{
        @tagName(builtin.mode),
        if (fixed) "fixed" else "page",
        @tagName(request_order),
        measured_chunks,
        generated_count,
        @as(f64, @floatFromInt(generated_count)) * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed)),
        @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(generated_count)) / std.time.ns_per_ms,
        @as(f64, @floatFromInt(maximum)) / std.time.ns_per_ms,
    });
}

fn fillRowPositions(positions: *[measured_chunks]lightning_rod.geometry.ChunkPos, tracker: *const lightning_rod.chunk_stream.Tracker) void {
    var count: usize = 0;
    var row: i32 = 0;
    while (count < positions.len) : (row += 1) {
        const z = if (row == 0) @as(i32, 0) else if (row & 1 == 1) -@divTrunc(row + 1, 2) else @divTrunc(row, 2);
        var x = -tracker.grid_radius;
        while (x <= tracker.grid_radius and count < positions.len) : (x += 1) {
            const position = lightning_rod.geometry.ChunkPos{ .x = x, .z = z };
            if (!tracker.wants(position)) continue;
            positions[count] = position;
            count += 1;
        }
    }
}

fn orderNearest(positions: []lightning_rod.geometry.ChunkPos) void {
    for (positions[1..], 1..) |_, index| {
        var selected = index;
        var distance = chunkDistance(positions[index - 1], positions[index]);
        for (positions[index + 1 ..], index + 1..) |candidate, candidate_index| {
            const candidate_distance = chunkDistance(positions[index - 1], candidate);
            if (candidate_distance >= distance) continue;
            selected = candidate_index;
            distance = candidate_distance;
        }
        std.mem.swap(lightning_rod.geometry.ChunkPos, &positions[index], &positions[selected]);
    }
}

fn chunkDistance(left: lightning_rod.geometry.ChunkPos, right: lightning_rod.geometry.ChunkPos) u32 {
    return @intCast(@abs(left.x - right.x) + @abs(left.z - right.z));
}

fn fillTiledPositions(positions: *[measured_chunks]lightning_rod.geometry.ChunkPos, tracker: *const lightning_rod.chunk_stream.Tracker) void {
    var count: usize = 0;
    var layer: i32 = 0;
    while (count < positions.len) : (layer += 1) {
        var tile_z = -layer;
        while (tile_z <= layer and count < positions.len) : (tile_z += 1) {
            var tile_x = -layer;
            while (tile_x <= layer and count < positions.len) : (tile_x += 1) {
                if (@max(@abs(tile_x), @abs(tile_z)) != layer) continue;
                for (0..3) |local_z| {
                    for (0..3) |local_x| {
                        const position = lightning_rod.geometry.ChunkPos{
                            .x = tile_x * 3 + @as(i32, @intCast(local_x)),
                            .z = tile_z * 3 + @as(i32, @intCast(local_z)),
                        };
                        if (!tracker.wants(position)) continue;
                        positions[count] = position;
                        count += 1;
                        if (count == positions.len) return;
                    }
                }
            }
        }
    }
}

fn runMaterializedServiceProfile() !void {
    const count = 120;
    var overworld = generation.Overworld.configured(.{});
    try overworld.initialize(std.heap.page_allocator);
    defer overworld.deinitialize();
    const blocks = try lightning_rod.blocks.Blocks.init(std.heap.page_allocator, .{
        .maximum_transient_chunks = 128,
        .maximum_modified_sections = 64,
    });
    const order = try lightning_rod.chunk_stream.Order.create(std.heap.page_allocator, 32);
    defer std.heap.page_allocator.free(order.indices);
    var tracker: lightning_rod.chunk_stream.Tracker = .{};
    try tracker.allocate(std.heap.page_allocator, &order);
    defer std.heap.page_allocator.free(tracker.dirty_bits);
    defer std.heap.page_allocator.free(tracker.sent_bits);
    var all_positions: [measured_chunks]lightning_rod.geometry.ChunkPos = undefined;
    fillTiledPositions(&all_positions, &tracker);
    var generated: [2048]Generated = undefined;
    var generated_count: usize = 0;
    const started = now();
    for (all_positions[0..count]) |position| {
        if (blocks.materializedChunk(.{ .index = 0, .generation = 1 }, position) != null) continue;
        const shape = try overworld.generate(seed, position);
        _ = try blocks.installMaterialization(.{ .index = 0, .generation = 1 }, shape, 1, .persisted);
        generated[generated_count] = .{ .x = shape.chunk_x, .z = shape.chunk_z, .checksum = 0 };
        generated_count += 1;
    }
    const elapsed = now() - started;
    std.debug.print("worldgen service mode={s} order=tiled-materialized requests={} produced={} throughput={d:.2} chunks/s requested={d:.2} chunks/s mean={d:.3} ms/output\n", .{
        @tagName(builtin.mode),                                                                          count,                                                                  generated_count,
        @as(f64, @floatFromInt(generated_count)) * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed)), @as(f64, count) * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed)), @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(generated_count)) / std.time.ns_per_ms,
    });
}

fn runProfile() ![measured_chunks]u64 {
    var generator = try terrain.Generator.init(
        std.heap.page_allocator,
        seed,
    );
    defer generator.deinit();
    const order = try lightning_rod.chunk_stream.Order.create(std.heap.page_allocator, 32);
    defer std.heap.page_allocator.free(order.indices);
    var tracker: lightning_rod.chunk_stream.Tracker = .{};
    try tracker.allocate(std.heap.page_allocator, &order);
    defer std.heap.page_allocator.free(tracker.dirty_bits);
    defer std.heap.page_allocator.free(tracker.sent_bits);
    var generated: [2048]Generated = undefined;
    var generated_count: usize = 0;
    var warmup_profile: Profile = .{};
    for (0..warmup_chunks) |index| {
        _ = try profileChunk(
            &generator,
            10_000 + @as(i32, @intCast(index)),
            10_000,
            &warmup_profile,
            &generated,
            &generated_count,
        );
    }
    generated_count = 0;
    var position_iterator = tracker.missingIterator();
    var positions: [measured_chunks]lightning_rod.geometry.ChunkPos = undefined;
    for (&positions) |*position|
        position.* = position_iterator.next() orelse unreachable;
    std.mem.sort(
        lightning_rod.geometry.ChunkPos,
        &positions,
        {},
        chunkPositionLess,
    );
    var profile: Profile = .{};
    var checksums: [measured_chunks]u64 = undefined;
    for (&checksums, positions) |*checksum, position| {
        checksum.* = try profileChunk(
            &generator,
            position.x,
            position.z,
            &profile,
            &generated,
            &generated_count,
        );
    }
    printProfile(
        generated_count,
        generator.maximumCachedBaseBytes(),
        &profile,
    );
    return checksums;
}

fn chunkPositionLess(
    _: void,
    left: lightning_rod.geometry.ChunkPos,
    right: lightning_rod.geometry.ChunkPos,
) bool {
    if (left.z != right.z) return left.z < right.z;
    return left.x < right.x;
}

fn profileChunk(
    generator: *terrain.Generator,
    chunk_x: i32,
    chunk_z: i32,
    profile: *Profile,
    generated: *[2048]Generated,
    generated_count: *usize,
) !u64 {
    for (generated[0..generated_count.*]) |entry|
        if (entry.x == chunk_x and entry.z == chunk_z) return entry.checksum;
    while (true) {
        const stage = generator.generationStage();
        const started = now();
        const shape = try generator.advance(chunk_x, chunk_z);
        profile.record(stage, null, now() - started);
        if (shape) |result| {
            std.mem.doNotOptimizeAway(&result.heights);
            const checksum = chunkChecksum(result);
            std.debug.assert(generated_count.* < generated.len);
            generated[generated_count.*] = .{
                .x = result.chunk_x,
                .z = result.chunk_z,
                .checksum = checksum,
            };
            generated_count.* += 1;
            if (result.chunk_x == chunk_x and result.chunk_z == chunk_z)
                return checksum;
        }
    }
}

fn chunkChecksum(shape: terrain.ChunkShape) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(shape.storage[0..shape.storage_len]);
    hash.update(std.mem.sliceAsBytes(&shape.heights));
    hash.update(&shape.biomes);
    return hash.final();
}

fn printProfile(
    generated_count: usize,
    maximum_cached_base_bytes: usize,
    profile: *const Profile,
) void {
    const total = profile.total();
    const chunks_per_second = @as(f64, @floatFromInt(generated_count)) * std.time.ns_per_s /
        @as(f64, @floatFromInt(total));
    const milliseconds_per_chunk = @as(f64, @floatFromInt(total)) /
        @as(f64, @floatFromInt(generated_count)) / std.time.ns_per_ms;
    const base_builds = profile.stage_calls[@intFromEnum(Stage.surface)];
    const feature_passes = profile.stage_calls[@intFromEnum(Stage.features)];
    std.debug.print(
        "\nworldgen mode={s} requests={} produced={} throughput={d:.2} chunks/s mean={d:.3} ms/chunk advances/chunk={d:.2} base_builds/chunk={d:.2} feature_origins/chunk={d:.2} maximum_cached_base={}B\n",
        .{ @tagName(builtin.mode), measured_chunks, generated_count, chunks_per_second, milliseconds_per_chunk, @as(f64, @floatFromInt(profile.calls())) / @as(f64, @floatFromInt(generated_count)), @as(f64, @floatFromInt(base_builds)) / @as(f64, @floatFromInt(generated_count)), @as(f64, @floatFromInt(feature_passes)) / @as(f64, @floatFromInt(generated_count)), maximum_cached_base_bytes },
    );
    inline for (@typeInfo(Stage).@"enum".fields) |field| {
        const index = field.value;
        printLine(field.name, profile.stage_ns[index], profile.stage_calls[index], profile.stage_max_ns[index], total, generated_count);
    }
}

fn printLine(name: []const u8, elapsed: u64, calls: u64, maximum: u64, total: u64, generated_count: usize) void {
    const milliseconds_per_chunk = @as(f64, @floatFromInt(elapsed)) /
        @as(f64, @floatFromInt(generated_count)) / std.time.ns_per_ms;
    const calls_per_chunk = @as(f64, @floatFromInt(calls)) /
        @as(f64, @floatFromInt(generated_count));
    const percent = 100.0 * @as(f64, @floatFromInt(elapsed)) /
        @as(f64, @floatFromInt(total));
    std.debug.print(
        "    {s: <24} {d:8.3} ms/chunk {d:6.1}% {d:7.2} calls/chunk max={d:.3}ms\n",
        .{ name, milliseconds_per_chunk, percent, calls_per_chunk, @as(f64, @floatFromInt(maximum)) / std.time.ns_per_ms },
    );
}

fn now() u64 {
    var value: std.os.linux.timespec = undefined;
    const result = std.os.linux.clock_gettime(.MONOTONIC, &value);
    if (std.os.linux.errno(result) != .SUCCESS) @panic("clock_gettime failed");
    return @as(u64, @intCast(value.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(value.nsec));
}

fn enumCount(comptime T: type) usize {
    return @typeInfo(T).@"enum".fields.len;
}
