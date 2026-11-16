const std = @import("std");
const chunks = @import("chunks");
const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const deflate = @import("deflate");

const Corpus = struct {
    allocator: std.mem.Allocator,
    decoder: deflate.fragments.Decoder,
    inputs: std.ArrayList([]const u8) = .empty,
    raw_bytes: usize = 0,

    fn append(self: *Corpus, fragment: deflate.fragments.Fragment) !void {
        const bytes = try self.allocator.alloc(u8, fragment.decoded);
        _ = try self.decoder.decode(fragment, bytes);
        try self.inputs.append(self.allocator, bytes);
        self.raw_bytes += bytes.len;
    }
};

pub fn main(init: std.process.Init) !void {
    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    const path = arguments.next() orelse return error.MissingWorld;
    const samples = if (arguments.next()) |text| try std.fmt.parseInt(usize, text, 10) else 5;
    const limit = if (arguments.next()) |text| try std.fmt.parseInt(usize, text, 10) else 256;
    if (arguments.next() != null or samples == 0 or samples > 31 or limit == 0) return error.InvalidArguments;
    const allocator = init.arena.allocator();
    const io = init.io;
    var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 128 });
    defer registry.deinit();
    var store = try storage.Store.init(allocator, io, .{ .path = path, .metrics = &registry });
    defer store.deinit();
    const resources = try records.Workspaces.init(allocator, io, .{ .metrics = &registry });
    const terrain = try chunks.Chunks.init(allocator, io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 1, .cache_groups = 1 }, .{ .metrics = &registry, .storage = try store.openSpace(chunks.Chunks.id), .record_workspaces = resources });
    var after: [64]u8 = undefined;
    var cursor: records.ScanCursor = .{ .after = &after };
    var columns: std.ArrayList(chunks.Light.Column) = .empty;
    while (true) {
        var batch: [32]chunks.Light.Column = undefined;
        const result = try terrain.savedLightColumns(&cursor, &batch);
        try columns.appendSlice(allocator, batch[0..result.count]);
        if (!result.more) break;
    }
    if (columns.items.len == 0) return error.EmptyDeliveryCache;
    var corpus: Corpus = .{ .allocator = allocator, .decoder = try .init(allocator, 32768) };
    defer corpus.decoder.deinit();
    var workspace = try chunks.Light.Workspace.init(allocator);
    defer workspace.deinit();
    const count = @min(limit, columns.items.len);
    for (0..count) |index| {
        const key = chunks.Delivery.key(columns.items[index * columns.items.len / count]);
        const table = terrain.cache.backend.store.lights;
        var lengths: [1]?usize = undefined;
        try table.lengthsBatch(&.{&key}, &lengths);
        const bytes = try allocator.alloc(u8, lengths[0] orelse return error.MissingColumn);
        defer allocator.free(bytes);
        const length = (try table.get(&key, bytes)) orelse return error.MissingColumn;
        const column = try chunks.Delivery.Column.read(bytes[0..length]);
        const view = try workspace.decode(column.frame);
        for (view.terrain[0..view.header.count]) |section| if (section) |encoded| try corpus.append(encoded.view().words);
        if (view.heightmap) |heightmap| try corpus.append(heightmap.words);
        for (0..2) |layer| for (0..view.header.count + 2) |section| switch (view.layer(layer, section)) {
            .encoded => |encoded| try corpus.append(encoded.fragment),
            .uniform => {},
            .dense => return error.UnexpectedDenseLayer,
        };
        for (0..column.slots) |slot| {
            const entry = bytes[chunks.Delivery.Column.header_size + column.frame.len + slot * chunks.Delivery.Column.entry_size ..][0..chunks.Delivery.Column.entry_size];
            const offset = std.mem.readInt(u32, entry[32..36], .little);
            const size = std.mem.readInt(u32, entry[36..40], .little);
            if (size == 0) continue;
            const prepared = try chunks.Delivery.View.read(bytes[offset..][0..size], .fromHeader(&view.header));
            for (0..prepared.count) |section| {
                const parts = prepared.section(section);
                try corpus.append(parts.header);
                if (parts.words) |words| try corpus.append(words);
                if (parts.biome) |biome| try corpus.append(biome);
            }
        }
    }
    // Each level runs through libdeflate, then through the std path used for multi-block inputs.
    const levels = [_]u4{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const variants = 2 * levels.len;
    var bakers: [levels.len]deflate.fragments.Baker = undefined;
    for (&bakers, levels) |*baker, level| baker.* = try .initLevel(allocator, level);
    defer for (&bakers) |*baker| baker.deinit();
    const encoded = try allocator.alloc(u8, 65536);
    const decoded = try allocator.alloc(u8, 32768);
    const durations = try allocator.alloc(u64, samples * variants);
    var sizes: [variants]usize = @splat(0);
    for (0..samples) |sample| for (0..variants) |rank| {
        const variant = (rank + sample * 4) % variants;
        const baker = &bakers[variant % levels.len];
        const standard = variant >= levels.len;
        var size: usize = 0;
        const start = std.Io.Clock.now(.cpu_thread, io).nanoseconds;
        for (corpus.inputs.items) |input| size += (try if (standard) baker.encodeStd(input, encoded) else baker.encode(input, encoded)).bytes.len;
        const end = std.Io.Clock.now(.cpu_thread, io).nanoseconds;
        durations[variant * samples + sample] = @intCast(end - start);
        if (sample == 0) {
            for (corpus.inputs.items) |input| {
                const fragment = try if (standard) baker.encodeStd(input, encoded) else baker.encode(input, encoded);
                if (!std.mem.eql(u8, input, try corpus.decoder.decode(fragment, decoded))) return error.RoundtripMismatch;
            }
        } else if (sizes[variant] != size) return error.NondeterministicCompression;
        sizes[variant] = size;
    };
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(io, &buffer);
    try output.interface.writeAll("encoder level encoded_MiB saved_percent encode_CPU_ms CPU_ratio\n");
    for (0..variants) |variant| std.mem.sort(u64, durations[variant * samples ..][0..samples], {}, std.sort.asc(u64));
    for (0..variants) |variant| {
        const median = durations[variant * samples + samples / 2];
        try output.interface.print("{s} {d} {d:.4} {d:.2} {d:.2} {d:.2}\n", .{ if (variant >= levels.len) "std" else "libdeflate", levels[variant % levels.len], @as(f64, @floatFromInt(sizes[variant])) / (1024 * 1024), 100 * (1 - @as(f64, @floatFromInt(sizes[variant])) / @as(f64, @floatFromInt(sizes[0]))), @as(f64, @floatFromInt(median)) / std.time.ns_per_ms, @as(f64, @floatFromInt(median)) / @as(f64, @floatFromInt(durations[samples / 2])) });
    }
    try output.interface.flush();
}
