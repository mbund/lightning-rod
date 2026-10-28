const std = @import("std");
const lighting = @import("lighting");

const Case = struct {
    name: []const u8,
    dimensions: lighting.Dimensions,
    skylight: bool,
    states: []const u16,
    expected: [2][]const u8,
    steps: []const Step,
    vanilla: Timing,

    fn blocks(self: Case) lighting.Blocks {
        return if (std.mem.allEqual(u16, self.states, self.states[0])) .{ .uniform = self.states[0] } else .{ .dense = self.states };
    }
};
const Timing = struct { median: u64, p95: u64 };
const Step = struct { name: []const u8, edits: []const lighting.Edit, expected: [2][]const u8, vanilla: Timing };

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2 and args.len != 6) return error.ExpectedCorpus;
    if (args.len == 6 and !std.mem.eql(u8, args[2], "--profile")) return error.ExpectedProfile;
    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .limited(256 * 1024 * 1024));
    var reader = std.Io.Reader.fixed(data);
    if (!std.mem.eql(u8, try reader.take(8), "LRLIGHT4")) return error.InvalidCorpus;
    const state_count = try reader.takeInt(u32, .big);
    const face_count = try reader.takeInt(u32, .big);
    if (state_count == 0 or state_count > 65536 or face_count == 0 or face_count > 4096) return error.InvalidRegistry;
    const properties = try allocator.alloc(lighting.Properties, state_count);
    for (properties) |*entry| {
        entry.opacity = try reader.takeByte();
        entry.emission = try reader.takeByte();
        for (&entry.faces) |*face| face.* = try reader.takeInt(u16, .big);
    }
    const registry: lighting.Registry = .{ .states = properties, .faces = face_count, .occlusion = try reader.take(@as(usize, face_count) * face_count) };
    const count = try reader.takeInt(u32, .big);
    if (count == 0 or count > 256) return error.InvalidCorpus;
    const cases = try allocator.alloc(Case, count);
    for (cases) |*case| {
        const name_length = try reader.takeInt(u32, .big);
        case.name = try reader.take(name_length);
        case.dimensions = .{ .x = try reader.takeInt(u32, .big), .y = try reader.takeInt(u32, .big), .z = try reader.takeInt(u32, .big) };
        case.skylight = (try reader.takeByte()) != 0;
        if (case.dimensions.x != 48 or case.dimensions.z != 48 or case.dimensions.y < 32 or case.dimensions.y > 416) return error.InvalidDimensions;
        const states = try allocator.alloc(u16, case.dimensions.volume());
        for (states) |*state| state.* = try reader.takeInt(u16, .big);
        case.states = states;
        for (&case.expected) |*expected| expected.* = try reader.take(case.dimensions.y * 256);
        const step_count = try reader.takeInt(u32, .big);
        if (step_count > 256) return error.InvalidEdits;
        const steps = try allocator.alloc(Step, step_count);
        for (steps) |*step| {
            step.name = try reader.take(try reader.takeInt(u32, .big));
            const edit_count = try reader.takeInt(u32, .big);
            if (edit_count == 0 or edit_count > lighting.batch_max) return error.InvalidEdits;
            const edits = try allocator.alloc(lighting.Edit, edit_count);
            for (edits) |*edit| edit.* = .{ .index = try reader.takeInt(u32, .big), .state = try reader.takeInt(u16, .big) };
            step.edits = edits;
            for (&step.expected) |*expected| expected.* = try reader.take(case.dimensions.y * 256);
        }
        case.steps = steps;
        case.vanilla = .{ .median = try reader.takeInt(u64, .big), .p95 = try reader.takeInt(u64, .big) };
        for (steps) |*step| step.vanilla = .{ .median = try reader.takeInt(u64, .big), .p95 = try reader.takeInt(u64, .big) };
    }
    if (reader.end != reader.seek) return error.TrailingCorpusData;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout.interface;
    if (args.len == 6) {
        const iterations = try std.fmt.parseInt(usize, args[5], 10);
        if (iterations == 0 or iterations > 1_000_000) return error.InvalidIterations;
        for (cases) |case| {
            if (!std.mem.eql(u8, case.name, args[3])) continue;
            var engine = try lighting.Engine.init(allocator, case.dimensions, registry);
            defer engine.deinit();
            try runProfile(init.io, &engine, case, args[4], iterations, out);
            try out.flush();
            return;
        }
        return error.UnknownCase;
    }
    var clock_samples: [32]u64 = undefined;
    for (&clock_samples) |*sample| {
        const start = cpu(init.io);
        sample.* = cpu(init.io) - start;
    }
    std.mem.sort(u64, &clock_samples, {}, std.sort.asc(u64));
    try out.writeAll("Whole 3x3 chunk region, thread CPU time, median of 32 repetitions. Initialization is excluded.\n");
    try out.print("Timestamp-pair baseline: {d} ns. Timings below include this overhead. Export measures the center chunk only.\n", .{clock_samples[clock_samples.len / 2]});
    try out.writeAll("Vanilla: 32 warmup runs, 32 measured runs per case. Prepared input metadata, vanilla sky sources, and section storage are excluded. Zig relight includes sky source discovery.\n");
    try out.writeAll("Incremental Zig samples reuse a settled workspace. Inverse edits and checks run outside the timer.\n");
    try out.writeAll("Case                    Decode us   Relight us    Export us   Vanilla propagation us (median/p95)    Sky rows    Rows popped   Changed cells   Shape checks\n");
    try out.flush();
    for (cases) |case| {
        var engine = try lighting.Engine.init(allocator, case.dimensions, registry);
        defer engine.deinit();
        var decode_samples: [32]u64 = undefined;
        var samples: [32]u64 = undefined;
        var export_samples: [32]u64 = undefined;
        const input = case.blocks();
        const exported = try allocator.alloc([2048]u8, 2 * case.dimensions.y / 16);
        defer allocator.free(exported);
        for (&samples, &decode_samples, &export_samples) |*sample, *decode_sample, *export_sample| {
            const decode_start = cpu(init.io);
            try engine.load(input);
            decode_sample.* = cpu(init.io) - decode_start;
            const start = cpu(init.io);
            engine.relight(case.skylight);
            sample.* = cpu(init.io) - start;
            try verify(&engine, case.name, case.expected);
            const export_start = cpu(init.io);
            for ([_]lighting.Layer{ .block, .sky }, 0..) |layer, l| {
                for (0..case.dimensions.y / 16) |s| engine.packSection(layer, .{ 1, s, 1 }, &exported[l * (case.dimensions.y / 16) + s]);
            }
            export_sample.* = cpu(init.io) - export_start;
            for (case.expected, 0..) |expected, l| for (expected, 0..) |value, index| {
                const section = l * (case.dimensions.y / 16) + index / 4096;
                const at = index % 4096;
                const actual = (exported[section][at / 2] >> @as(u3, @intCast(at % 2 * 4))) & 15;
                if (actual != value) return error.IncorrectNibbleExport;
            };
        }
        std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
        std.mem.sort(u64, &decode_samples, {}, std.sort.asc(u64));
        std.mem.sort(u64, &export_samples, {}, std.sort.asc(u64));
        try out.print("{s: <23} {d: >9.2} {d: >12.2} {d: >12.2} {d: >16.2}/{d: <12.2} {d: >10} {d: >14} {d: >15} {d: >14}\n", .{
            case.name,
            @as(f64, @floatFromInt(decode_samples[decode_samples.len / 2])) / 1000,
            @as(f64, @floatFromInt(samples[samples.len / 2])) / 1000,
            @as(f64, @floatFromInt(export_samples[export_samples.len / 2])) / 1000,
            @as(f64, @floatFromInt(case.vanilla.median)) / 1000,
            @as(f64, @floatFromInt(case.vanilla.p95)) / 1000,
            engine.work.source_rows,
            engine.work.propagated_rows,
            engine.work.changed_cells,
            engine.work.shape_checks,
        });
        try out.flush();
        for (case.steps, 0..) |step, s| {
            var undo: [lighting.batch_max]lighting.Edit = undefined;
            for (step.edits, undo[0..step.edits.len]) |edit, *restore| restore.* = .{ .index = edit.index, .state = engine.blockState(edit.index) };
            for (&samples, 0..) |*sample, repeat| {
                const start = cpu(init.io);
                try engine.update(step.edits);
                sample.* = cpu(init.io) - start;
                try verify(&engine, step.name, step.expected);
                if (repeat + 1 < samples.len) {
                    try engine.update(undo[0..step.edits.len]);
                    try verify(&engine, step.name, if (s == 0) case.expected else case.steps[s - 1].expected);
                }
            }
            std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
            try out.print("  {s: <25} Zig {d: >9.2}/{d: <9.2} us  Vanilla {d: >9.2}/{d: <9.2} us (median/p95)  rise {d: >6}  fall {d: >6}  restore {d: >6}  changed {d: >7}  removed {d: >7}  sky rows {d: >5}  cancelled {d: >5}\n", .{
                step.name,
                @as(f64, @floatFromInt(samples[samples.len / 2])) / 1000,
                @as(f64, @floatFromInt(samples[samples.len * 95 / 100])) / 1000,
                @as(f64, @floatFromInt(step.vanilla.median)) / 1000,
                @as(f64, @floatFromInt(step.vanilla.p95)) / 1000,
                engine.work.propagated_rows,
                engine.work.darkened_rows,
                engine.work.restored_rows,
                engine.work.changed_cells,
                engine.work.removed_cells,
                engine.work.source_rows,
                engine.work.cancelled_rows,
            });
            try out.flush();
        }
    }
}

fn runProfile(io: std.Io, engine: *lighting.Engine, case: Case, name: []const u8, iterations: usize, out: *std.Io.Writer) !void {
    try engine.load(case.blocks());
    engine.relight(case.skylight);
    try verify(engine, case.name, case.expected);
    for (case.steps, 0..) |step, s| {
        if (!std.mem.eql(u8, step.name, name)) {
            try engine.update(step.edits);
            try verify(engine, step.name, step.expected);
            continue;
        }
        var undo: [lighting.batch_max]lighting.Edit = undefined;
        for (step.edits, undo[0..step.edits.len]) |edit, *restore| restore.* = .{ .index = edit.index, .state = engine.blockState(edit.index) };
        const previous = if (s == 0) case.expected else case.steps[s - 1].expected;
        try engine.update(step.edits);
        try verify(engine, step.name, step.expected);
        try engine.update(undo[0..step.edits.len]);
        try verify(engine, step.name, previous);
        for (0..128) |_| {
            try engine.update(step.edits);
            try engine.update(undo[0..step.edits.len]);
        }
        const start = cpu(io);
        for (0..iterations) |_| {
            try engine.update(step.edits);
            try engine.update(undo[0..step.edits.len]);
        }
        const elapsed = cpu(io) - start;
        try verify(engine, step.name, previous);
        try engine.update(step.edits);
        try verify(engine, step.name, step.expected);
        try out.print("{s}/{s}: {d} edit/undo pairs, {d:.2} us CPU per pair. Setup and correctness checks excluded from timing.\n", .{
            case.name,
            step.name,
            iterations,
            @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations)) / 1000,
        });
        return;
    }
    return error.UnknownStep;
}

fn verify(engine: *const lighting.Engine, name: []const u8, wanted: [2][]const u8) !void {
    const dimensions = engine.dimensions;
    for ([_]lighting.Layer{ .block, .sky }, wanted) |layer, expected| {
        var at: usize = 0;
        for (0..dimensions.y) |y| for (16..32) |z| for (16..32) |x| {
            const actual = engine.get(layer, (y * dimensions.z + z) * dimensions.x + x);
            if (actual != expected[at]) {
                std.debug.print("{s}: {s} ({d},{d},{d}) expected {d}, got {d}\n", .{ name, @tagName(layer), x, @as(i32, @intCast(y)) - 16, z, expected[at], actual });
                return error.VanillaMismatch;
            }
            at += 1;
        };
    }
}

fn cpu(io: std.Io) u64 {
    return @intCast(std.Io.Clock.now(.cpu_thread, io).nanoseconds);
}
