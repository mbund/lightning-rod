const std = @import("std");
const records = @import("records");
const terrain = @import("terrain.zig");
const chunks = @import("chunks");
const storage = @import("storage");
const metrics = @import("metrics");
const corpus = @import("corpus.zig");
const traces = @import("trace.zig");
const common = @import("common.zig");

const Options = struct {
    corpus_path: []const u8 = ".zig-cache/world-bench/corpus.bin",
    output: []const u8 = ".zig-cache/world-bench/results",
    seed: u64 = 20261017,
    steps: usize = 128,
    repeats: usize = 3,
    radius: i32 = 4,
    pattern: ?traces.Pattern = null,
    cache: ?usize = null,
    copies: usize = 1,
    filesystem_cache: enum { warm, cold } = .warm,
    wal_pages: u32 = 65536,
    checkpoint_bytes: u64 = 64 * 1024 * 1024,
    maintenance_pages: usize = 20 * storage.batch_size,
};
const Samples = struct {
    wall: []u64,
    cpu: []u64,

    fn init(allocator: std.mem.Allocator, count: usize) !Samples {
        return .{ .wall = try allocator.alloc(u64, count), .cpu = try allocator.alloc(u64, count) };
    }

    fn set(self: Samples, index: usize, duration: common.Duration) void {
        self.wall[index] = duration.wall_ns;
        self.cpu[index] = duration.cpu_ns;
    }
};
const Phase = enum { load, edit, save, maintain };
const Measurement = struct { wall: common.Distribution, cpu: common.Distribution };
const Files = struct { database: u64, wal: u64 };
const Counters = struct {
    wal_bytes: u64,
    read_bytes: u64,
    read_batches: u64,
    read_pages: u64,
    maintenance_bytes: u64,
    cache_hits: u64,
    cache_misses: u64,
    source_sections: u64,

    fn read(store: *const storage.Store, registry: *const metrics.Registry, source: *const corpus.Corpus) Counters {
        return .{ .wal_bytes = store.wal_bytes.value(), .read_bytes = store.read_bytes.value(), .read_batches = store.read_batches.value(), .read_pages = store.read_pages.value(), .maintenance_bytes = store.checkpoint_bytes.value(), .cache_hits = registry.find("chunks.cache.hits").?.value, .cache_misses = registry.find("chunks.cache.misses").?.value, .source_sections = source.generated };
    }

    fn subtract(self: Counters, before: Counters) Counters {
        return .{ .wal_bytes = self.wal_bytes - before.wal_bytes, .read_bytes = self.read_bytes - before.read_bytes, .read_batches = self.read_batches - before.read_batches, .read_pages = self.read_pages - before.read_pages, .maintenance_bytes = self.maintenance_bytes - before.maintenance_bytes, .cache_hits = self.cache_hits - before.cache_hits, .cache_misses = self.cache_misses - before.cache_misses, .source_sections = self.source_sections - before.source_sections };
    }
};
const Result = struct {
    pattern: traces.Pattern,
    repeat: usize,
    cache_sections: usize,
    players: usize,
    render_distance: i32,
    logical_seconds: usize,
    trace_sha256: []const u8,
    requests: usize,
    edits: usize,
    total: Measurement,
    initial_load: common.Duration,
    steady: Measurement,
    phases: [4]Measurement,
    final_save: common.Duration,
    maintenance: common.Duration,
    workload_io: common.IoCounts,
    maintenance_io: common.IoCounts,
    counters: Counters,
    before_maintenance: Files,
    after_maintenance: Files,
    pages: u64,
    free_pages: u64,
    verified_columns: usize,
    storage_memory_bytes: usize,
    peak_wal_pages: usize,
    peak_wal_bytes: u64,
};

fn sizes(store: *const storage.Store) !Files {
    return .{ .database = (try store.database.stat(store.io)).size, .wal = (try store.wal.stat(store.io)).size };
}

fn copyDatabase(allocator: std.mem.Allocator, io: std.Io, from: []const u8, to: []const u8, cold: bool) !void {
    try common.removeDatabase(allocator, io, to);
    for ([_][]const u8{ "", ".wal" }) |suffix| {
        const input = try std.fmt.allocPrint(allocator, "{s}{s}", .{ from, suffix });
        defer allocator.free(input);
        const output = try std.fmt.allocPrint(allocator, "{s}{s}", .{ to, suffix });
        defer allocator.free(output);
        const source = try std.Io.Dir.cwd().openFile(io, input, .{});
        defer source.close(io);
        const file = try std.Io.Dir.cwd().createFile(io, output, .{});
        defer file.close(io);
        const buffer = try allocator.alloc(u8, 1024 * 1024);
        defer allocator.free(buffer);
        var offset: u64 = 0;
        while (true) {
            const n = try source.readPositionalAll(io, buffer, offset);
            if (n == 0) break;
            try file.writePositionalAll(io, buffer[0..n], offset);
            offset += n;
        }
        try file.sync(io);
        if (cold and std.os.linux.errno(std.os.linux.fadvise(file.handle, 0, 0, std.os.linux.POSIX_FADV.DONTNEED)) != .SUCCESS) return error.CacheAdviceFailed;
    }
}

fn verify(init: std.process.Init, source: *const corpus.Corpus, trace: *const traces.Trace, path: []const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    var registry = try metrics.Registry.init(init.gpa, init.io, .{ .capacity = 128 });
    defer registry.deinit();
    var store = try storage.Store.init(init.gpa, init.io, .{ .path = path });
    defer store.deinit();
    defer store.transaction().fail();
    const space = try store.openSpace(chunks.Chunks.id);
    const world = try chunks.Chunks.init(arena.allocator(), init.io, .{}, .{ .metrics = &registry, .storage = space, .record_workspaces = try records.Workspaces.init(arena.allocator(), init.io, .{}) });
    const changed = try arena.allocator().alloc(bool, source.columns.len * corpus.section_count);
    @memset(changed, false);
    var iterator = trace.final_edits.keyIterator();
    while (iterator.next()) |key| changed[@intCast(key.* / 4096)] = true;
    var verified: usize = 0;
    for (source.columns, 0..) |column, id| {
        var sections: [corpus.section_count]chunks.Section = undefined;
        var leases: [corpus.section_count]chunks.Lease = undefined;
        for (&sections, 0..) |*section, y| section.* = .{ .world = 0, .x = column.x, .z = column.z, .y = @as(i32, @intCast(y)) + corpus.minimum_y };
        try world.acquireMany(&sections, &leases);
        defer for (leases) |lease| lease.release();
        for (leases, 0..) |lease, y| {
            const bytes = lease.record.read();
            if (!trace.touched[id]) {
                if (bytes != null) return error.UnexpectedPersistedSection;
                continue;
            }
            if (bytes == null) return error.MissingPersistedSection;
            const expected = column.sections[y];
            var dense: [corpus.section_bytes]u8 = undefined;
            if (changed[id * corpus.section_count + y]) {
                dense[0] = 1;
                for (0..4096) |index| {
                    const key = (@as(u64, id) * corpus.section_count + y) * 4096 + index;
                    const original = std.mem.readInt(u16, expected[if (expected[0] == 0) 1 else 1 + index * 2..][0..2], .little);
                    const state = trace.final_edits.get(key) orelse original;
                    std.mem.writeInt(u16, dense[1 + index * 2 ..][0..2], state, .little);
                }
            } else if (expected[0] == 1) {
                @memcpy(&dense, expected);
            }
            const view = lease.view();
            if (!changed[id * corpus.section_count + y] and expected[0] == 0) {
                if (view != .uniform or view.uniform != std.mem.readInt(u16, expected[1..3], .little)) return error.UniformMismatch;
            } else if (view == .dense) {
                if (!std.mem.eql(u8, view.dense, dense[1..])) return error.BlockMismatch;
            } else {
                for (0..4096) |index| if (view.uniform != std.mem.readInt(u16, dense[1 + index * 2 ..][0..2], .little)) return error.BlockMismatch;
            }
        }
        if (trace.touched[id]) verified += 1;
    }
    const before = store.wal_bytes.value();
    try world.checkpoint(space);
    if (before != store.wal_bytes.value()) return error.CleanCheckpointRewroteData;
    return verified;
}

fn runCase(init: std.process.Init, source: *corpus.Corpus, trace: *const traces.Trace, options: Options, pattern: traces.Pattern, cache: usize, repeat: usize, base: []const u8) !Result {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const stem = try std.fmt.allocPrint(allocator, "{s}/{s}-{d}-{d}", .{ options.output, @tagName(pattern), cache, repeat });
    const path = try std.fmt.allocPrint(allocator, "{s}.world", .{stem});
    if (pattern == .exploration) try common.removeDatabase(allocator, init.io, path) else try copyDatabase(allocator, init.io, base, path, options.filesystem_cache == .cold);
    const total = try Samples.init(allocator, options.steps);
    var phases: [4]Samples = undefined;
    for (&phases) |*samples| samples.* = try Samples.init(allocator, options.steps);
    var result: Result = undefined;
    {
        var registry = try metrics.Registry.init(init.gpa, init.io, .{ .capacity = 128 });
        defer registry.deinit();
        var store = try storage.Store.init(init.gpa, init.io, .{ .path = path, .metrics = &registry, .maximum_wal_pages = options.wal_pages, .checkpoint_bytes = options.checkpoint_bytes });
        defer store.deinit();
        const space = try store.openSpace(chunks.Chunks.id);
        const world = try chunks.Chunks.init(allocator, init.io, .{ .demand_sections = 0, .cache_sections = cache }, .{ .metrics = &registry, .storage = space, .record_workspaces = try records.Workspaces.init(arena.allocator(), init.io, .{}) });
        if (pattern == .exploration) world.setSource(chunks.Source.init(source, corpus.Corpus.read));
        const wall_timer = try registry.timer(.{ .namespace = "bench", .name = "step", .description = "One logical second of the access trace" });
        const cpu_timer = try registry.timer(.{ .namespace = "bench", .name = "step_cpu", .description = "Simulation thread CPU per trace step", .clock = .thread_cpu });
        const counters_before = Counters.read(&store, &registry, source);
        const io_before = try common.IoCounts.read(init.io);
        var tick = store.lastTick();
        var peak_wal_pages: usize = store.locations.count();
        var peak_wal_bytes: u64 = store.end;
        for (trace.steps, 0..) |step, index| {
            errdefer std.debug.print("Failed step={d} WAL pages={d}/{d} bytes={d} maintenance={t} copied={d}/{d} committed={d} durable={d} dirty={d}\n", .{ index, store.locations.count(), store.limits.maximum_wal_pages, store.end, store.phase, store.checkpoint_at, store.checkpoint_count, store.saved.sequence, store.durable_sequence, store.dirty_count });
            const start = common.Stamp.now(init.io);
            var phase_start = start;
            try terrain.acquireColumns(world, source, step.columns);
            var now = common.Stamp.now(init.io);
            phases[@intFromEnum(Phase.load)].set(index, now.since(phase_start));
            phase_start = now;
            var edits: [6]chunks.BlockEdit = undefined;
            var sections: [6]chunks.SectionEdits = undefined;
            for (step.edits, 0..) |edit, i| {
                const column = source.columns[edit.column];
                edits[i] = .{ .index = edit.index, .state = edit.state };
                sections[i] = .{ .section = .{ .world = 0, .x = column.x, .z = column.z, .y = @as(i32, edit.section) + corpus.minimum_y }, .edits = edits[i..][0..1] };
            }
            try world.setSections(sections[0..step.edits.len]);
            now = common.Stamp.now(init.io);
            phases[@intFromEnum(Phase.edit)].set(index, now.since(phase_start));
            phase_start = now;
            if (step.save) {
                try world.checkpoint(space);
                tick += 1;
                try store.submitSync(try store.commit(tick));
            }
            peak_wal_pages = @max(peak_wal_pages, store.locations.count());
            peak_wal_bytes = @max(peak_wal_bytes, store.end);
            now = common.Stamp.now(init.io);
            phases[@intFromEnum(Phase.save)].set(index, now.since(phase_start));
            phase_start = now;
            var remaining = options.maintenance_pages;
            while (remaining != 0) {
                const pages = @min(remaining, storage.batch_size);
                _ = try store.pollMaintenance(.{ .index_entries = pages, .pages = pages });
                remaining -= pages;
            }
            now = common.Stamp.now(init.io);
            phases[@intFromEnum(Phase.maintain)].set(index, now.since(phase_start));
            const duration = now.since(start);
            total.set(index, duration);
            wall_timer.observe(duration.wall_ns);
            cpu_timer.observe(duration.cpu_ns);
        }
        const finish = common.Stamp.now(init.io);
        try world.checkpoint(space);
        tick += 1;
        try store.waitDurable(try store.commit(tick));
        peak_wal_pages = @max(peak_wal_pages, store.locations.count());
        peak_wal_bytes = @max(peak_wal_bytes, store.end);
        const saved = common.Stamp.now(init.io);
        const workload_io = (try common.IoCounts.read(init.io)).subtract(io_before);
        const before = try sizes(&store);
        const counters = Counters.read(&store, &registry, source).subtract(counters_before);
        const maintenance_io_before = try common.IoCounts.read(init.io);
        const maintenance_start = common.Stamp.now(init.io);
        try common.drain(&store);
        const maintenance = common.Stamp.now(init.io).since(maintenance_start);
        const maintenance_io = (try common.IoCounts.read(init.io)).subtract(maintenance_io_before);
        const free_pages = store.metadata.free_pages;
        const snapshot = try std.Io.Dir.cwd().createFile(init.io, try std.fmt.allocPrint(allocator, "{s}.metrics.jsonl", .{stem}), .{});
        defer snapshot.close(init.io);
        var buffer: [16384]u8 = undefined;
        var writer = snapshot.writer(init.io, &buffer);
        try metrics.Exporter.writeSnapshot(&registry, &writer.interface);
        try writer.interface.flush();
        result = .{ .pattern = pattern, .repeat = repeat, .cache_sections = cache, .players = trace.players, .render_distance = trace.radius, .logical_seconds = options.steps, .trace_sha256 = try init.arena.allocator().dupe(u8, &trace.hash), .requests = trace.requests, .edits = trace.edits, .total = undefined, .initial_load = undefined, .steady = undefined, .phases = undefined, .final_save = saved.since(finish), .maintenance = maintenance, .workload_io = workload_io, .maintenance_io = maintenance_io, .counters = counters, .before_maintenance = before, .after_maintenance = try sizes(&store), .pages = store.metadata.pages, .free_pages = free_pages, .verified_columns = 0, .storage_memory_bytes = store.memoryBytes(), .peak_wal_pages = peak_wal_pages, .peak_wal_bytes = peak_wal_bytes };
    }
    result.verified_columns = try verify(init, source, trace, path);
    const samples_file = try std.Io.Dir.cwd().createFile(init.io, try std.fmt.allocPrint(allocator, "{s}.steps.jsonl", .{stem}), .{});
    defer samples_file.close(init.io);
    var buffer: [16384]u8 = undefined;
    var writer = samples_file.writer(init.io, &buffer);
    for (0..options.steps) |index| {
        var wall: [4]u64 = undefined;
        var cpu: [4]u64 = undefined;
        for (phases, 0..) |samples, i| {
            wall[i] = samples.wall[index];
            cpu[i] = samples.cpu[index];
        }
        try std.json.Stringify.value(.{ .step = index, .requests = trace.steps[index].columns.len, .edits = trace.steps[index].edits.len, .save = trace.steps[index].save, .wall_ns = total.wall[index], .cpu_ns = total.cpu[index], .phase_wall_ns = wall, .phase_cpu_ns = cpu }, .{}, &writer.interface);
        try writer.interface.writeByte('\n');
    }
    try writer.interface.flush();
    result.initial_load = .{ .wall_ns = total.wall[0], .cpu_ns = total.cpu[0] };
    result.steady = .{ .wall = common.Distribution.summarize(total.wall[1..]), .cpu = common.Distribution.summarize(total.cpu[1..]) };
    result.total = .{ .wall = common.Distribution.summarize(total.wall), .cpu = common.Distribution.summarize(total.cpu) };
    for (phases, &result.phases) |samples, *measurement| measurement.* = .{ .wall = common.Distribution.summarize(samples.wall), .cpu = common.Distribution.summarize(samples.cpu) };
    std.debug.print("{s:12} cache={d:4} run={d} requests={d:5} cpu={d:.2}ms wall={d:.2}ms p99={d:.3}ms max={d:.3}ms writes={d} verified={d}\n", .{ @tagName(pattern), cache, repeat, trace.requests, @as(f64, @floatFromInt(result.total.cpu.total_ns)) / 1e6, @as(f64, @floatFromInt(result.total.wall.total_ns)) / 1e6, @as(f64, @floatFromInt(result.total.wall.p99_ns)) / 1e6, @as(f64, @floatFromInt(result.total.wall.maximum_ns)) / 1e6, result.counters.wal_bytes, result.verified_columns });
    return result;
}

const CodecResult = struct { sections: usize, decoded_bytes: u64, encoded_bytes: u64, representations: [3]usize, encoded_size_bounds: [6]usize, encoded_size_counts: [6]usize, encode: Measurement, decode: Measurement };
fn benchmarkCodec(init: std.process.Init, source: *const corpus.Corpus, base: []const u8) !CodecResult {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    var registry = try metrics.Registry.init(init.gpa, init.io, .{ .capacity = 128 });
    defer registry.deinit();
    var store = try storage.Store.init(init.gpa, init.io, .{ .path = base });
    defer store.deinit();
    defer store.transaction().fail();
    const world = try chunks.Chunks.init(allocator, init.io, .{}, .{ .metrics = &registry, .storage = try store.openSpace(chunks.Chunks.id), .record_workspaces = try records.Workspaces.init(allocator, init.io, .{}) });
    const codec = world.cache.codec.?;
    const encoded = try allocator.alloc([corpus.section_bytes]u8, corpus.section_count);
    const decoded = try allocator.alloc([corpus.section_bytes]u8, corpus.section_count);
    const encoding_samples = try Samples.init(allocator, source.columns.len);
    const decoding_samples = try Samples.init(allocator, source.columns.len);
    var input_bytes: u64 = 0;
    var output_bytes: u64 = 0;
    var representations: [3]usize = @splat(0);
    const bounds = [6]usize{ 512, 1024, 1277, 2048, 4064, 8193 };
    var counts: [6]usize = @splat(0);
    for (source.columns, 0..) |column, i| {
        var slices: [corpus.section_count][]const u8 = undefined;
        var lengths: [corpus.section_count]usize = undefined;
        const start = common.Stamp.now(init.io);
        for (column.sections, encoded, &slices) |section, *destination, *slice| slice.* = try codec.encode(section, destination);
        encoding_samples.set(i, common.Stamp.now(init.io).since(start));
        for (column.sections, slices, decoded, &lengths) |section, bytes, *destination, *length| {
            @memcpy(destination[0..bytes.len], bytes);
            length.* = bytes.len;
            input_bytes += section.len;
            output_bytes += bytes.len;
            representations[bytes[0]] += 1;
            for (bounds, &counts) |bound, *count| if (bytes.len <= bound) {
                count.* += 1;
                break;
            };
        }
        const decode_start = common.Stamp.now(init.io);
        for (decoded, &lengths) |*destination, *length| length.* = try codec.decode(destination, length.*);
        decoding_samples.set(i, common.Stamp.now(init.io).since(decode_start));
        for (column.sections, decoded, lengths) |section, *bytes, length| if (!std.mem.eql(u8, section, bytes[0..length])) return error.CodecMismatch;
    }
    return .{ .sections = source.columns.len * corpus.section_count, .decoded_bytes = input_bytes, .encoded_bytes = output_bytes, .representations = representations, .encoded_size_bounds = bounds, .encoded_size_counts = counts, .encode = .{ .wall = common.Distribution.summarize(encoding_samples.wall), .cpu = common.Distribution.summarize(encoding_samples.cpu) }, .decode = .{ .wall = common.Distribution.summarize(decoding_samples.wall), .cpu = common.Distribution.summarize(decoding_samples.cpu) } };
}

pub fn main(init: std.process.Init) !void {
    try run(init);
}

fn run(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var options: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 == args.len) return error.MissingArgument;
        const flag = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, flag, "--copies")) {
            options.copies = try std.fmt.parseInt(usize, value, 10);
            continue;
        }
        if (std.mem.eql(u8, flag, "--filesystem-cache")) {
            options.filesystem_cache = std.meta.stringToEnum(@TypeOf(options.filesystem_cache), value) orelse return error.InvalidCacheMode;
            continue;
        }
        if (std.mem.eql(u8, flag, "--wal-pages")) {
            options.wal_pages = try std.fmt.parseInt(u32, value, 10);
            continue;
        }
        if (std.mem.eql(u8, flag, "--checkpoint-bytes")) {
            options.checkpoint_bytes = try std.fmt.parseInt(u64, value, 10);
            continue;
        }
        if (std.mem.eql(u8, flag, "--maintenance-pages")) {
            options.maintenance_pages = try std.fmt.parseInt(usize, value, 10);
            continue;
        }
        if (std.mem.eql(u8, flag, "--corpus")) options.corpus_path = value else if (std.mem.eql(u8, flag, "--output")) options.output = value else if (std.mem.eql(u8, flag, "--steps")) options.steps = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, flag, "--repeats")) options.repeats = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, flag, "--seed")) options.seed = try std.fmt.parseInt(u64, value, 10) else if (std.mem.eql(u8, flag, "--radius")) options.radius = try std.fmt.parseInt(i32, value, 10) else if (std.mem.eql(u8, flag, "--cache")) options.cache = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, flag, "--pattern")) options.pattern = std.meta.stringToEnum(traces.Pattern, value) orelse return error.InvalidPattern else return error.UnknownOption;
    }
    if (options.steps < 2 or options.steps > 65536 or options.repeats == 0 or options.repeats > 100 or options.radius < 1 or options.radius > 12) return error.InvalidConfiguration;
    if (options.wal_pages < storage.batch_size or options.wal_pages > 1 << 24 or options.checkpoint_bytes < 64 or options.maintenance_pages > 65536) return error.InvalidConfiguration;
    if (options.cache) |cache| if (cache < 192 or cache > 65536) return error.InvalidCacheCapacity;
    try std.Io.Dir.cwd().createDirPath(init.io, options.output);
    var source = try corpus.Corpus.load(allocator, init.io, options.corpus_path);
    defer source.deinit(allocator, init.io);
    const source_columns = source.columns.len;
    try source.replicate(allocator, options.copies);
    const base = try std.fs.path.join(allocator, &.{ options.output, "base.world" });
    _ = try terrain.seedDatabase(init, &source, base);
    const codec = try benchmarkCodec(init, &source, base);
    std.debug.print("Codec: {d} sections, {d} decoded -> {d} encoded bytes, CPU encode {d:.2}ms decode {d:.2}ms\n", .{ codec.sections, codec.decoded_bytes, codec.encoded_bytes, @as(f64, @floatFromInt(codec.encode.cpu.total_ns)) / 1e6, @as(f64, @floatFromInt(codec.decode.cpu.total_ns)) / 1e6 });
    var results: std.ArrayList(Result) = .empty;
    for (std.enums.values(traces.Pattern)) |pattern| {
        if (options.pattern) |selected| if (selected != pattern) continue;
        var trace_arena = std.heap.ArenaAllocator.init(init.gpa);
        defer trace_arena.deinit();
        const trace = try traces.generate(trace_arena.allocator(), &source, pattern, options.seed, options.steps, options.radius);
        const caches = [_]usize{ 192, 3072 };
        for (if (options.cache) |*cache| @as([]const usize, cache[0..1]) else &caches) |cache| {
            for (0..options.repeats) |repeat| try results.append(allocator, try runCase(init, &source, &trace, options, pattern, cache, repeat, base));
        }
    }
    const report = try std.Io.Dir.cwd().createFile(init.io, try std.fs.path.join(allocator, &.{ options.output, "results.json" }), .{});
    defer report.close(init.io);
    var buffer: [32768]u8 = undefined;
    var writer = report.writer(init.io, &buffer);
    try std.json.Stringify.value(.{ .corpus_sha256 = &source.hash, .source_columns = source_columns, .copies = source.copies, .columns = source.columns.len, .trace_seed = options.seed, .submission = "system.io_uring", .filesystem_cache = if (options.filesystem_cache == .cold) "file-local DONTNEED requested after sync" else "warm, not dropped", .wal_pages = options.wal_pages, .checkpoint_bytes = options.checkpoint_bytes, .maintenance_pages_per_second = options.maintenance_pages, .application_cache = "cold at each run", .step_seconds = 1, .walking_blocks_per_second = 4.317, .autosave_seconds = 32, .phase_order = .{ "load", "edit", "save", "maintain" }, .codec = codec, .results = results.items }, .{ .whitespace = .indent_2 }, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}
