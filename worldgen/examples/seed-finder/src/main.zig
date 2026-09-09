const std = @import("std");
const options = @import("search_options");
const worldgen = @import("vanilla_worldgen");

const maximum_threads = 256;
const default_quad_diameter = 256;

const Shared = struct {
    first_seed: u64,
    seed_count: u64,
    thread_count: usize,
    search_parameter: u32,
    chunk_x: i32,
    chunk_z: i32,
    output_lock: std.atomic.Mutex = .unlocked,
};

const Worker = struct {
    shared: *Shared,
    index: usize,
};

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const first_seed = try std.fmt.parseInt(u64, args.next() orelse return usage(), 10);
    const seed_count = try std.fmt.parseInt(u64, args.next() orelse return usage(), 10);
    const thread_count = if (args.next()) |text|
        try std.fmt.parseInt(usize, text, 10)
    else
        try std.Thread.getCpuCount();
    const search_parameter = if (args.next()) |text|
        try std.fmt.parseInt(u32, text, 10)
    else if (comptime std.mem.eql(u8, options.mode, "quad-witch-hut"))
        default_quad_diameter
    else
        7;
    const chunk_x = if (args.next()) |text| try std.fmt.parseInt(i32, text, 10) else 0;
    const chunk_z = if (args.next()) |text| try std.fmt.parseInt(i32, text, 10) else 0;
    if (args.next() != null) return error.UnexpectedArgument;
    if (seed_count == 0 or thread_count == 0 or thread_count > maximum_threads)
        return error.InvalidSearchBounds;

    var shared = Shared{
        .first_seed = first_seed,
        .seed_count = seed_count,
        .thread_count = thread_count,
        .search_parameter = search_parameter,
        .chunk_x = chunk_x,
        .chunk_z = chunk_z,
    };
    var workers: [maximum_threads]Worker = undefined;
    var threads: [maximum_threads]std.Thread = undefined;
    for (threads[0..thread_count], workers[0..thread_count], 0..) |*thread, *worker, index| {
        worker.* = .{ .shared = &shared, .index = index };
        thread.* = try std.Thread.spawn(.{}, runWorker, .{worker});
    }
    for (threads[0..thread_count]) |thread| thread.join();
}

fn runWorker(worker: *Worker) void {
    if (comptime std.mem.eql(u8, options.mode, "quad-witch-hut"))
        searchQuadHuts(worker, worker.shared.search_parameter)
    else
        searchTallCactus(worker, @intCast(worker.shared.search_parameter));
}

fn searchQuadHuts(worker: *Worker, diameter: u32) void {
    var offset: u64 = worker.index;
    while (offset < worker.shared.seed_count) : (offset += worker.shared.thread_count) {
        const seed = worker.shared.first_seed +% offset;
        const quad = worldgen.structures.Quad.fromNorthWestRegion(@bitCast(seed), 0, 0);
        if (!quad.fitsDiameter(diameter)) continue;
        if (!quadSwampBiomes(seed, quad)) continue;
        lock(&worker.shared.output_lock);
        defer worker.shared.output_lock.unlock();
        std.debug.print("quad-witch-hut-biome-candidate seed={} chunks=", .{seed});
        for (quad.candidates) |candidate|
            std.debug.print("({d},{d})", .{ candidate.x, candidate.z });
        std.debug.print("\n", .{});
    }
}

fn quadSwampBiomes(seed: u64, quad: worldgen.structures.Quad) bool {
    var sampler = worldgen.climate.Sampler.init(seed);
    var lookup: worldgen.biome.Lookup = .{};
    for (quad.candidates) |candidate| {
        const x = candidate.x *% 16 +% 8;
        const z = candidate.z *% 16 +% 8;
        const sample = sampler.sample(x, z).quantized(64);
        if (!std.mem.eql(u8, lookup.biome(sample), "minecraft:swamp")) return false;
    }
    return true;
}

fn searchTallCactus(worker: *Worker, minimum_height: u8) void {
    var pipeline = worldgen.pipeline.Area(.{}, 1).init(std.heap.page_allocator, 0) catch return;
    defer pipeline.deinit();
    const states = std.heap.page_allocator.alloc(
        worldgen.generated_state.GeneratedState,
        worldgen.chunk.block_count,
    ) catch return;
    defer std.heap.page_allocator.free(states);
    var offset: u64 = worker.index;
    while (offset < worker.shared.seed_count) : (offset += worker.shared.thread_count) {
        const seed = worker.shared.first_seed +% offset;
        if (potentialCactusHeight(
            seed,
            worker.shared.chunk_x,
            worker.shared.chunk_z,
        ) < minimum_height) continue;
        pipeline.reseed(seed) catch return;
        pipeline.generate(worker.shared.chunk_x, worker.shared.chunk_z, states) catch return;
        if (tallestCactus(states) < minimum_height) continue;
        lock(&worker.shared.output_lock);
        defer worker.shared.output_lock.unlock();
        std.debug.print("tall-cactus seed={} height={} chunk=({d},{d})\n", .{
            seed,
            tallestCactus(states),
            worker.shared.chunk_x,
            worker.shared.chunk_z,
        });
    }
}

fn potentialCactusHeight(seed: u64, center_x: i32, center_z: i32) u8 {
    var heights: [64 * 64]u8 = @splat(0);
    var flowers: [64 * 64]bool = @splat(false);
    var maximum: u8 = 0;
    var chunk_z = center_z - 1;
    while (chunk_z <= center_z + 1) : (chunk_z += 1) {
        var chunk_x = center_x - 1;
        while (chunk_x <= center_x + 1) : (chunk_x += 1) {
            maximum = @max(maximum, potentialCactusPatch(
                seed,
                chunk_x,
                chunk_z,
                center_x,
                center_z,
                &heights,
                &flowers,
            ));
        }
    }
    return maximum;
}

fn potentialCactusPatch(
    seed: u64,
    chunk_x: i32,
    chunk_z: i32,
    center_x: i32,
    center_z: i32,
    heights: *[64 * 64]u8,
    flowers: *[64 * 64]bool,
) u8 {
    const population_seed = worldgen.random.ChunkRandom.populationSeed(
        seed,
        chunk_x * 16,
        chunk_z * 16,
    );
    var source = worldgen.random.ChunkRandom.init(
        worldgen.random.decoratorSeed(population_seed, 83, 9),
    );
    if (source.nextF32() >= 1.0 / 6.0) return 0;
    const origin_x = chunk_x * 16 + source.nextBoundedI32(16);
    const origin_z = chunk_z * 16 + source.nextBoundedI32(16);
    var maximum: u8 = 0;
    for (0..10) |_| {
        const x = origin_x + source.nextBoundedI32(8) - source.nextBoundedI32(8);
        const y = source.nextBoundedI32(4) - source.nextBoundedI32(4);
        const z = origin_z + source.nextBoundedI32(8) - source.nextBoundedI32(8);
        const local_x = x - center_x * 16;
        const local_z = z - center_z * 16;
        const index: usize = @intCast((local_z + 24) * 64 + local_x + 24);
        if (flowers[index] or y != heights[index]) continue;
        const sampled_maximum = source.nextBoundedI32(3) + 1;
        const height: u8 = @intCast(source.nextBoundedI32(sampled_maximum) + 1);
        flowers[index] = source.nextBoundedI32(4) == 3;
        heights[index] += height;
        maximum = @max(maximum, heights[index]);
    }
    return maximum;
}

fn tallestCactus(states: []const worldgen.generated_state.GeneratedState) u8 {
    const generated = worldgen.chunk.View.init(states);
    var maximum: u8 = 0;
    for (0..16) |z| for (0..16) |x| {
        var run: u8 = 0;
        var y: i32 = worldgen.chunk.minimum_y;
        while (y < worldgen.chunk.minimum_y + worldgen.chunk.height) : (y += 1) {
            const state = generated.at(.{ .x = @intCast(x), .y = @intCast(y), .z = @intCast(z) });
            if (state.block() == .cactus) {
                run += 1;
                maximum = @max(maximum, run);
            } else {
                run = 0;
            }
        }
    };
    return maximum;
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        "usage: vanilla_seed_finder <first-seed> <count> [threads] [minimum-height|maximum-diameter] [chunk-x chunk-z] (compiled search: {s})\n",
        .{options.mode},
    );
    return error.InvalidArguments;
}

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}
