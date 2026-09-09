const std = @import("std");
const worldgen = @import("vanilla_worldgen");

const chunk_count = 64;
const seed = 0x6d62_756e_6400_0001;

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const repetitions = if (args.next()) |text|
        try std.fmt.parseInt(usize, text, 10)
    else
        3;
    if (args.next() != null) return error.UnexpectedArgument;
    std.debug.assert(repetitions > 0 and repetitions <= 1_000);

    const states = try init.gpa.alloc(worldgen.generated_state.GeneratedState, chunk_count * worldgen.chunk.block_count);
    defer init.gpa.free(states);
    const density = try run(.{ .surface = false, .carvers = false, .features = false, .structures = false }, "density cumulative", init.gpa, states, repetitions);
    const surface = try run(.{ .carvers = false, .features = false, .structures = false }, "surface cumulative", init.gpa, states, repetitions);
    const carvers = try run(.{ .features = false, .structures = false }, "carvers cumulative", init.gpa, states, repetitions);
    const complete = try run(.{}, "features cumulative", init.gpa, states, repetitions);
    std.debug.print(
        "estimated marginal stages: surface={d:.3}ms carvers={d:.3}ms features+halo={d:.3}ms\n",
        .{ @max(0, surface - density), @max(0, carvers - surface), @max(0, complete - carvers) },
    );
}

fn run(
    comptime stages: worldgen.pipeline.Stages,
    comptime name: []const u8,
    allocator: std.mem.Allocator,
    states: []worldgen.generated_state.GeneratedState,
    repetitions: usize,
) !f64 {
    var area = try worldgen.pipeline.Area(stages, 8).init(allocator, seed);
    defer area.deinit();
    try area.generate(0, 0, states);
    var best: u64 = std.math.maxInt(u64);
    var checksum: u64 = 0;
    for (0..repetitions) |repetition| {
        const started = now();
        try area.generate(0, 0, states);
        checksum +%= hash(states) +% repetition;
        best = @min(best, now() - started);
    }
    const per_chunk = @as(f64, @floatFromInt(best)) /
        @as(f64, chunk_count) / std.time.ns_per_ms;
    const throughput = @as(f64, chunk_count) * std.time.ns_per_s /
        @as(f64, @floatFromInt(best));
    std.debug.print(
        "{s} area=8x8 best={d:.3}ms/chunk throughput={d:.1}chunks/s checksum=0x{x}\n",
        .{ name, per_chunk, throughput, checksum },
    );
    return per_chunk;
}

fn hash(states: []const worldgen.generated_state.GeneratedState) u64 {
    var value = std.hash.Wyhash.init(0);
    value.update(std.mem.sliceAsBytes(states));
    return value.final();
}

fn now() u64 {
    var value: std.os.linux.timespec = undefined;
    const result = std.os.linux.clock_gettime(.MONOTONIC, &value);
    if (std.os.linux.errno(result) != .SUCCESS) @panic("clock_gettime failed");
    return @as(u64, @intCast(value.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(value.nsec));
}
