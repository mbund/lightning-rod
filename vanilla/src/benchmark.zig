const std = @import("std");
const builtin = @import("builtin");
const lightning_rod = @import("lightning_rod");
const terrain = @import("vanilla_terrain");

const measured_chunks = 256;
const warmup_chunks = 4;
const seed = 0x6d62_756e_6400_0001;
const Stage = terrain.Generator.GenerationStage;
const Feature = terrain.vanilla_worldgen.chunk.FeatureStage;

const Profile = struct {
    stage_ns: [enumCount(Stage)]u64 = @splat(0),
    stage_calls: [enumCount(Stage)]u64 = @splat(0),
    feature_ns: [enumCount(Feature)]u64 = @splat(0),
    feature_calls: [enumCount(Feature)]u64 = @splat(0),

    fn record(self: *Profile, stage: Stage, feature: ?Feature, elapsed: u64) void {
        const stage_index = @intFromEnum(stage);
        self.stage_ns[stage_index] += elapsed;
        self.stage_calls[stage_index] += 1;
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
    if (args.next()) |side_text| {
        if (args.next() != null) return error.UnexpectedArgument;
        _ = try runProfile(try std.fmt.parseInt(usize, side_text, 10));
        return;
    }
    _ = try runProfile(1);
    _ = try runProfile(3);
}

fn runProfile(batch_side: usize) ![measured_chunks]u64 {
    var generator = try terrain.Generator.init(
        std.heap.page_allocator,
        seed,
        batch_side,
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
        batch_side,
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
    batch_side: usize,
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
        "\nworldgen mode={s} batch_side={} requests={} produced={} throughput={d:.2} chunks/s mean={d:.3} ms/chunk advances/chunk={d:.2} base_builds/chunk={d:.2} feature_origins/chunk={d:.2} maximum_cached_base={}B\n",
        .{ @tagName(builtin.mode), batch_side, measured_chunks, generated_count, chunks_per_second, milliseconds_per_chunk, @as(f64, @floatFromInt(profile.calls())) / @as(f64, @floatFromInt(generated_count)), @as(f64, @floatFromInt(base_builds)) / @as(f64, @floatFromInt(generated_count)), @as(f64, @floatFromInt(feature_passes)) / @as(f64, @floatFromInt(generated_count)), maximum_cached_base_bytes },
    );
    inline for (@typeInfo(Stage).@"enum".fields) |field| {
        const index = field.value;
        printLine(field.name, profile.stage_ns[index], profile.stage_calls[index], total, generated_count);
    }
}

fn printLine(name: []const u8, elapsed: u64, calls: u64, total: u64, generated_count: usize) void {
    const milliseconds_per_chunk = @as(f64, @floatFromInt(elapsed)) /
        @as(f64, @floatFromInt(generated_count)) / std.time.ns_per_ms;
    const calls_per_chunk = @as(f64, @floatFromInt(calls)) /
        @as(f64, @floatFromInt(generated_count));
    const percent = 100.0 * @as(f64, @floatFromInt(elapsed)) /
        @as(f64, @floatFromInt(total));
    std.debug.print(
        "    {s: <24} {d:8.3} ms/chunk {d:6.1}% {d:7.2} calls/chunk\n",
        .{ name, milliseconds_per_chunk, percent, calls_per_chunk },
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
