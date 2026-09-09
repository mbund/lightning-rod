const std = @import("std");
const worldgen = @import("vanilla_worldgen");

const render_distance = 32;
const chunk_count = 3725;
const seed = 0x6d62_756e_6400_0001;

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const repetitions = if (args.next()) |text|
        try std.fmt.parseInt(usize, text, 10)
    else
        1;
    const selection = args.next() orelse "all";
    if (args.next() != null) return error.UnexpectedArgument;
    std.debug.assert(repetitions > 0 and repetitions <= 10);

    const states = try init.gpa.alloc(worldgen.generated_state.GeneratedState, worldgen.chunk.block_count);
    defer init.gpa.free(states);
    if (std.mem.eql(u8, selection, "density")) {
        _ = try run(.{ .surface = false, .carvers = false, .features = false, .structures = false }, "density cumulative", init.gpa, states, repetitions);
        return;
    }
    if (std.mem.eql(u8, selection, "density-detail")) {
        try profileDensity(init.gpa, states);
        return;
    }
    if (std.mem.eql(u8, selection, "surface")) {
        _ = try run(.{ .carvers = false, .features = false, .structures = false }, "surface cumulative", init.gpa, states, repetitions);
        return;
    }
    if (std.mem.eql(u8, selection, "surface-detail")) {
        try profileSurface(init.gpa, states);
        return;
    }
    if (std.mem.eql(u8, selection, "complete")) {
        _ = try run(.{}, "features cumulative", init.gpa, states, repetitions);
        return;
    }
    if (std.mem.eql(u8, selection, "biomes")) {
        profileBiomes();
        return;
    }
    if (std.mem.eql(u8, selection, "lookup")) {
        profileLookup();
        return;
    }
    if (std.mem.eql(u8, selection, "area")) {
        try profileArea(init.gpa);
        return;
    }
    if (!std.mem.eql(u8, selection, "all")) return error.UnknownSelection;
    const density = try run(.{ .surface = false, .carvers = false, .features = false, .structures = false }, "density cumulative", init.gpa, states, repetitions);
    const surface = try run(.{ .carvers = false, .features = false, .structures = false }, "surface cumulative", init.gpa, states, repetitions);
    try profileSurface(init.gpa, states);
    const carvers = try run(.{ .features = false, .structures = false }, "carvers cumulative", init.gpa, states, repetitions);
    const complete = try run(.{}, "features cumulative", init.gpa, states, repetitions);
    std.debug.print(
        "estimated marginal stages: surface={d:.3}ms carvers={d:.3}ms features+halo={d:.3}ms\n",
        .{ @max(0, surface - density), @max(0, carvers - surface), @max(0, complete - carvers) },
    );
}

fn profileLookup() void {
    const count = 256;
    var sampler = worldgen.climate.Sampler.init(seed);
    var cache: worldgen.biome.Cache = .{};
    var elapsed: u64 = 0;
    var checksum: u64 = 0;
    for (0..count) |chunk_index| {
        const chunk_x: i32 = @intCast(chunk_index % 32);
        const chunk_z: i32 = @intCast(chunk_index / 32);
        const started = now();
        const cells = cache.chunk(&sampler, chunk_x, chunk_z);
        elapsed += now() - started;
        checksum +%= cells[0] +% cells[cells.len - 1];
    }
    std.debug.print("biome volume={d:.3}ms/chunk checksum=0x{x}\n", .{
        @as(f64, @floatFromInt(elapsed)) / count / std.time.ns_per_ms,
        checksum,
    });
}

fn profileArea(allocator: std.mem.Allocator) !void {
    const side = 8;
    var area = try worldgen.pipeline.Area(.{}, side).init(allocator, seed);
    defer area.deinit();
    const states = try allocator.alloc(worldgen.generated_state.GeneratedState, side * side * worldgen.chunk.block_count);
    defer allocator.free(states);
    const started = now();
    try area.generate(0, 0, states);
    const elapsed = now() - started;
    var checksum = std.hash.Wyhash.init(0);
    checksum.update(std.mem.sliceAsBytes(states));
    std.debug.print("shared 8x8 area={d:.3}ms/chunk checksum=0x{x}\n", .{
        @as(f64, @floatFromInt(elapsed)) / (side * side) / std.time.ns_per_ms,
        checksum.final(),
    });
}

fn profileBiomes() void {
    var sampler = worldgen.climate.Sampler.init(seed);
    var cache: worldgen.biome.Cache = .{};
    var climate_ns: u64 = 0;
    var lookup_ns: u64 = 0;
    var horizontal: [16]worldgen.climate.Sample = undefined;
    var lookup: worldgen.biome.Lookup = .{};
    for (0..chunk_count) |chunk_index| {
        const chunk_x: i32 = @intCast(chunk_index % 61);
        const chunk_z: i32 = @intCast(chunk_index / 61);
        var started = now();
        for (0..4) |x| {
            for (0..4) |z| {
                horizontal[x * 4 + z] = sampler.sample((chunk_x * 4 + @as(i32, @intCast(x))) << 2, (chunk_z * 4 + @as(i32, @intCast(z))) << 2);
            }
        }
        climate_ns += now() - started;
        started = now();
        for (0..96) |y| {
            for (0..16) |column| {
                _ = lookup.biomeIndex(horizontal[column].quantized((@as(i32, @intCast(y)) - 16) << 2));
            }
        }
        lookup_ns += now() - started;
    }
    var elapsed: u64 = 0;
    var checksum: u64 = 0;
    var produced: usize = 0;
    var z: i32 = -render_distance - 1;
    while (z <= render_distance + 1) : (z += 1) {
        var x: i32 = -render_distance - 1;
        while (x <= render_distance + 1) : (x += 1) {
            if (!inView(x, z)) continue;
            const started = now();
            var neighbor_z = z - 1;
            while (neighbor_z <= z + 1) : (neighbor_z += 1) {
                var neighbor_x = x - 1;
                while (neighbor_x <= x + 1) : (neighbor_x += 1) {
                    const cells = cache.chunk(&sampler, neighbor_x, neighbor_z);
                    checksum +%= cells[0] +% cells[cells.len - 1];
                }
            }
            elapsed += now() - started;
            produced += 1;
        }
    }
    std.debug.assert(produced == chunk_count);
    std.debug.print("biome climate={d:.3}ms lookup={d:.3}ms retained window={d:.3}ms/chunk checksum=0x{x}\n", .{
        perChunk(climate_ns), perChunk(lookup_ns), perChunk(elapsed), checksum,
    });
}

fn profileSurface(
    allocator: std.mem.Allocator,
    states: []worldgen.generated_state.GeneratedState,
) !void {
    var generator = try worldgen.chunk.Generator.initForRegion(allocator, seed);
    defer generator.deinit();
    const materials = try allocator.alloc(worldgen.aquifer.Material, worldgen.chunk.block_count);
    defer allocator.free(materials);
    var top_heights: [worldgen.chunk.width * worldgen.chunk.width]i32 = undefined;
    var biome_halo: worldgen.chunk.BiomeHalo = undefined;
    var base_ns: u64 = 0;
    var preliminary_ns: u64 = 0;
    var initialize_ns: u64 = 0;
    var biome_ns: u64 = 0;
    var columns_ns: u64 = 0;
    var ores_ns: u64 = 0;
    var produced: usize = 0;
    var checksum = std.hash.Wyhash.init(0);
    var z: i32 = -render_distance - 1;
    while (z <= render_distance + 1) : (z += 1) {
        var x: i32 = -render_distance - 1;
        while (x <= render_distance + 1) : (x += 1) {
            if (!inView(x, z)) continue;
            var started = now();
            try generator.fillBaseMaterials(x, z, materials);
            base_ns += now() - started;
            started = now();
            const preliminary = worldgen.density.preliminarySurfaceCorners(generator.router, x, z);
            preliminary_ns += now() - started;
            started = now();
            try worldgen.chunk.Generator.initializeSurface(materials, states, &top_heights);
            initialize_ns += now() - started;
            started = now();
            generator.prepareSurfaceBiomeHalo(x, z, &biome_halo);
            biome_ns += now() - started;
            started = now();
            try generator.applySurfaceColumns(x, z, states, &top_heights, &biome_halo, &preliminary, 0, worldgen.chunk.width);
            columns_ns += now() - started;
            started = now();
            try generator.finishSurface(x, z, states);
            ores_ns += now() - started;
            checksum.update(std.mem.sliceAsBytes(states));
            produced += 1;
        }
    }
    std.debug.assert(produced == chunk_count);
    std.debug.print(
        "surface breakdown: base={d:.3}ms preliminary={d:.3}ms initialize={d:.3}ms biome={d:.3}ms columns={d:.3}ms ores={d:.3}ms checksum=0x{x}\n",
        .{
            perChunk(base_ns),
            perChunk(preliminary_ns),
            perChunk(initialize_ns),
            perChunk(biome_ns),
            perChunk(columns_ns),
            perChunk(ores_ns),
            checksum.final(),
        },
    );
}

fn profileDensity(
    allocator: std.mem.Allocator,
    states: []worldgen.generated_state.GeneratedState,
) !void {
    var generator = try worldgen.chunk.Generator.initForRegion(allocator, seed);
    defer generator.deinit();
    var top_heights: [worldgen.chunk.width * worldgen.chunk.width]i32 = undefined;
    var prepare_ns: u64 = 0;
    var fill_ns: u64 = 0;
    var produced: usize = 0;
    var checksum = std.hash.Wyhash.init(0);
    var z: i32 = -render_distance - 1;
    while (z <= render_distance + 1) : (z += 1) {
        var x: i32 = -render_distance - 1;
        while (x <= render_distance + 1) : (x += 1) {
            if (!inView(x, z)) continue;
            var started = now();
            generator.prepareBaseMaterials(x, z);
            prepare_ns += now() - started;
            @memset(&top_heights, worldgen.chunk.minimum_y);
            started = now();
            while (!generator.advanceBaseStates(states, &top_heights)) {}
            fill_ns += now() - started;
            checksum.update(std.mem.sliceAsBytes(states));
            produced += 1;
        }
    }
    std.debug.assert(produced == chunk_count);
    std.debug.print("density breakdown: prepare={d:.3}ms fill={d:.3}ms checksum=0x{x}\n", .{
        perChunk(prepare_ns), perChunk(fill_ns), checksum.final(),
    });
}

fn perChunk(elapsed: u64) f64 {
    return @as(f64, @floatFromInt(elapsed)) / chunk_count / std.time.ns_per_ms;
}

fn run(
    comptime stages: worldgen.pipeline.Stages,
    comptime name: []const u8,
    allocator: std.mem.Allocator,
    states: []worldgen.generated_state.GeneratedState,
    repetitions: usize,
) !f64 {
    var pipeline = try worldgen.pipeline.Pipeline(stages).init(allocator, seed);
    defer pipeline.deinit();
    var best: u64 = std.math.maxInt(u64);
    var checksum: u64 = 0;
    for (0..repetitions) |repetition| {
        var hash = std.hash.Wyhash.init(repetition);
        var produced: usize = 0;
        var elapsed: u64 = 0;
        var z: i32 = -render_distance - 1;
        while (z <= render_distance + 1) : (z += 1) {
            var x: i32 = -render_distance - 1;
            while (x <= render_distance + 1) : (x += 1) {
                if (!inView(x, z)) continue;
                const started = now();
                try pipeline.generate(x, z, states);
                elapsed += now() - started;
                hash.update(std.mem.sliceAsBytes(states));
                produced += 1;
            }
        }
        std.debug.assert(produced == chunk_count);
        best = @min(best, elapsed);
        checksum +%= hash.final();
    }
    const per_chunk = @as(f64, @floatFromInt(best)) /
        chunk_count / std.time.ns_per_ms;
    const throughput = @as(f64, chunk_count) * std.time.ns_per_s /
        @as(f64, @floatFromInt(best));
    std.debug.print(
        "{s} render_distance={} chunks={} best={d:.3}s {d:.3}ms/chunk throughput={d:.2}chunks/s checksum=0x{x}\n",
        .{ name, render_distance, chunk_count, @as(f64, @floatFromInt(best)) / std.time.ns_per_s, per_chunk, throughput, checksum },
    );
    return per_chunk;
}

fn inView(x: i32, z: i32) bool {
    const dx: u64 = @intCast(@abs(x) -| 2);
    const dz: u64 = @intCast(@abs(z) -| 2);
    return dx * dx + dz * dz < render_distance * render_distance;
}

fn now() u64 {
    var value: std.os.linux.timespec = undefined;
    const result = std.os.linux.clock_gettime(.MONOTONIC, &value);
    if (std.os.linux.errno(result) != .SUCCESS) @panic("clock_gettime failed");
    return @as(u64, @intCast(value.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(value.nsec));
}
