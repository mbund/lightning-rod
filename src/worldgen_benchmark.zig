const std = @import("std");
const builtin = @import("builtin");
const lightning_rod = @import("lightning_rod");

const measured_chunks = 64;
const warmup_chunks = 4;
const base_requests_per_chunk = 25;
const seed = 0x6d62_756e_6400_0001;
const Stage = lightning_rod.terrain.Generator.GenerationStage;
const Feature = lightning_rod.terrain.vanilla_worldgen.chunk.FeatureStage;

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
};

pub fn main(_: std.process.Init) !void {
    const compact = try runProfile(3);
    const cached = try runProfile(128);
    for (compact, cached, 0..) |left, right, index| {
        if (left != right) {
            std.debug.print("worldgen output mismatch at measured chunk {}\n", .{index});
            return error.CacheChangedWorldgenOutput;
        }
    }
}

fn runProfile(cache_capacity: usize) ![measured_chunks]u64 {
    var generator = try lightning_rod.terrain.Generator.init(
        std.heap.page_allocator,
        seed,
        cache_capacity,
    );
    defer generator.deinit();
    var tracker: lightning_rod.chunk_stream.Tracker = .{};
    try tracker.allocate(std.heap.page_allocator);
    defer std.heap.page_allocator.free(tracker.dirty_bits);
    defer std.heap.page_allocator.free(tracker.sent_bits);
    var positions = tracker.missingIterator();
    for (0..warmup_chunks) |_| {
        const position = positions.next() orelse unreachable;
        const shape = try generator.generate(position.x, position.z);
        std.mem.doNotOptimizeAway(&shape.heights);
    }
    var profile: Profile = .{};
    var checksums: [measured_chunks]u64 = undefined;
    for (&checksums) |*checksum| {
        const position = positions.next() orelse unreachable;
        checksum.* = try profileChunk(&generator, position.x, position.z, &profile);
    }
    printProfile(cache_capacity, &profile);
    return checksums;
}

fn profileChunk(
    generator: *lightning_rod.terrain.Generator,
    chunk_x: i32,
    chunk_z: i32,
    profile: *Profile,
) !u64 {
    generator.cancel();
    while (true) {
        const stage = generator.generationStage();
        const feature = generator.featureStage();
        const started = now();
        const shape = try generator.advance(chunk_x, chunk_z);
        profile.record(stage, feature, now() - started);
        if (shape) |result| {
            std.mem.doNotOptimizeAway(&result.heights);
            return chunkChecksum(result);
        }
    }
}

fn chunkChecksum(shape: lightning_rod.terrain.ChunkShape) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(shape.storage[0..shape.storage_len]);
    hash.update(std.mem.sliceAsBytes(&shape.heights));
    hash.update(&shape.biomes);
    return hash.final();
}

fn printProfile(cache_capacity: usize, profile: *const Profile) void {
    const total = profile.total();
    const chunks_per_second = @as(f64, measured_chunks) * std.time.ns_per_s /
        @as(f64, @floatFromInt(total));
    const milliseconds_per_chunk = @as(f64, @floatFromInt(total)) /
        measured_chunks / std.time.ns_per_ms;
    const base_builds = profile.stage_calls[@intFromEnum(Stage.surface)];
    const base_requests = measured_chunks * base_requests_per_chunk;
    std.debug.print(
        "\nworldgen mode={s} cache={} chunks={} throughput={d:.2} chunks/s mean={d:.3} ms/chunk base_builds/chunk={d:.2} cache_hit={d:.1}%\n",
        .{ @tagName(builtin.mode), cache_capacity, measured_chunks, chunks_per_second, milliseconds_per_chunk, @as(f64, @floatFromInt(base_builds)) / measured_chunks, 100.0 * @as(f64, @floatFromInt(base_requests - base_builds)) / base_requests },
    );
    inline for (@typeInfo(Stage).@"enum".fields) |field| {
        const index = field.value;
        printLine(field.name, profile.stage_ns[index], profile.stage_calls[index], total);
    }
    std.debug.print("  feature passes:\n", .{});
    inline for (@typeInfo(Feature).@"enum".fields) |field| {
        const index = field.value;
        printLine(field.name, profile.feature_ns[index], profile.feature_calls[index], total);
    }
}

fn printLine(name: []const u8, elapsed: u64, calls: u64, total: u64) void {
    const milliseconds_per_chunk = @as(f64, @floatFromInt(elapsed)) /
        measured_chunks / std.time.ns_per_ms;
    const calls_per_chunk = @as(f64, @floatFromInt(calls)) / measured_chunks;
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
