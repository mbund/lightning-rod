const std = @import("std");
const chunks = @import("chunks");
const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const deflate = @import("deflate");
const fragments = deflate.fragments;


const Corpus = struct {
    allocator: std.mem.Allocator,
    decoder: deflate.fragments.Decoder,
    inputs: std.ArrayList([]const u8) = .empty,
    raw_bytes: usize = 0,
    cached_bytes: usize = 0,

    fn append(self: *Corpus, fragment: deflate.fragments.Fragment) !void {
        const bytes = try self.allocator.alloc(u8, fragment.decoded);
        _ = try self.decoder.decode(fragment, bytes);
        try self.inputs.append(self.allocator, bytes);
        self.cached_bytes += fragment.bytes.len;
        self.raw_bytes += bytes.len;
    }
};

/// Fits the shared table to the fragments a world's caches hold, which this build wrote, and
/// writes it as the table source. Each pass parses every fragment under the table so far.
pub fn main(init: std.process.Init) !void {
    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    const path = arguments.next() orelse return error.MissingWorld;
    const destination = arguments.next() orelse return error.MissingDestination;
    const limit = if (arguments.next()) |text| try std.fmt.parseInt(usize, text, 10) else 512;
    // Only this world's columns, as each dimension is a world.
    const only: ?u32 = if (arguments.next()) |text| try std.fmt.parseInt(u32, text, 10) else null;
    if (arguments.next() != null or limit == 0) return error.InvalidArguments;
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
    var seen: [8]usize = @splat(0);
    while (true) {
        var batch: [32]chunks.Light.Column = undefined;
        const result = try terrain.savedLightColumns(&cursor, &batch);
        for (batch[0..result.count]) |column| if (only == null or column.world == only.?) try columns.append(allocator, column);
        for (batch[0..result.count]) |column| seen[@min(column.world, seen.len - 1)] += 1;
        if (!result.more) break;
    }
    for (seen, 0..) |count, world| if (count != 0) std.debug.print("world {d}: {d} columns\n", .{ world, count });
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
        if (view.heightmap) |heightmap| try corpus.append(heightmap.packet);
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
    var baker = try fragments.Baker.init(allocator);
    defer baker.deinit();
    // Each fragment with a table of its own, as libdeflate coded them before the shared table.
    var own_tables: usize = 0;
    {
        var encoder = try deflate.Encoder.init(allocator, 6);
        defer encoder.deinit();
        const scratch = try allocator.alloc(u8, deflate.fragments.bound(fragments.Baker.maximum_input) + 64);
        for (corpus.inputs.items) |input| own_tables += (try encoder.encode(input, scratch)).len - 6;
    }
    var fitted = fragments.shared;
    var bits: [5]usize = undefined;
    var counts: fragments.Counts = .{};
    for (&bits) |*total| {
        counts = .{};
        total.* = 0;
        for (corpus.inputs.items) |input| total.* += baker.measure(input, &fitted, &counts);
        // Every symbol keeps a code, so any bytes between fragments can still be written.
        for (&counts.literal) |*value| value.* += 1;
        for (&counts.distance) |*value| value.* += 1;
        fragments.huffmanLengths(&counts.literal, &fitted.literal, fragments.maximum_literal_bits);
        fragments.huffmanLengths(&counts.distance, &fitted.distance, 15);
        if (!fitted.valid()) return error.InvalidTable;
    }
    const fitted_header = fragments.headerBits(&fitted);
    const fitted_codes = codeBits(&counts, &fitted);
    const chosen = smallerHeader(&counts, fitted);
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    try output.interface.print("fitted header {d} B, after swaps {d} B, codes {d:.2}% longer\n", .{ fitted_header / 8, fragments.headerBits(&chosen) / 8, 100 * (@as(f64, @floatFromInt(codeBits(&counts, &chosen))) / @as(f64, @floatFromInt(fitted_codes)) - 1) });
    fitted = chosen;
    try output.interface.print("fragments {d}, decoded {d:.2} MiB, cached {d:.4} MiB\n", .{ corpus.inputs.items.len, mebibytes(corpus.raw_bytes), mebibytes(corpus.cached_bytes) });
    try output.interface.print("own table per fragment, libdeflate 6: {d:.4} MiB\n", .{mebibytes(own_tables)});
    for (bits, 0..) |total, pass| try output.interface.print("pass {d}: {d:.4} MiB of codes\n", .{ pass, mebibytes(total / 8) });
    try output.interface.flush();
    var file = try std.Io.Dir.cwd().createFile(io, destination, .{});
    defer file.close(io);
    var file_buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &file_buffer);
    try writer.interface.writeAll("//! Code lengths every fragment and every stitched stream share. Generated by `zig build\n//! fragment-table -- <world>` in bench/chunks from the fragments a world's caches hold.\n\n");
    for ([_][]const u8{ "literal", "distance" }, [_][]const u8{ &fitted.literal, &fitted.distance }) |name, lengths| {
        try writer.interface.print("pub const {s} = [{d}]u8{{ ", .{ name, lengths.len });
        for (lengths, 0..) |length, index| try writer.interface.print("{s}{d}", .{ if (index == 0) "" else ", ", length });
        try writer.interface.writeAll(" };\n");
    }
    try writer.interface.flush();
}

/// Fragment bits a real terrain chunk packet carries, measured with the bench. The header is
/// paid once per packet, so this weighs its bits against the codes.
const packet_code_bits = 12000;

/// Code bits of the counted symbols, without extra bits, which no table changes.
fn codeBits(counts: *const fragments.Counts, table: *const fragments.Table) u64 {
    var total: u64 = 0;
    for (counts.literal, table.literal) |count, length| total += count * length;
    for (counts.distance, table.distance) |count, length| total += count * length;
    return total;
}

/// Swaps lengths between symbols, which keeps the code complete, where a run of equal lengths
/// shortens the header by more than the codes grow for one packet.
fn smallerHeader(counts: *const fragments.Counts, start: fragments.Table) fragments.Table {
    var table = start;
    const base: f64 = @floatFromInt(codeBits(counts, &start));
    const cost = struct {
        fn of(values: *const fragments.Counts, candidate: *const fragments.Table, reference: f64) f64 {
            return @as(f64, @floatFromInt(fragments.headerBits(candidate))) + packet_code_bits * @as(f64, @floatFromInt(codeBits(values, candidate))) / reference;
        }
    }.of;
    var best = cost(counts, &table, base);
    var random = std.Random.DefaultPrng.init(0x5eed);
    for (0..400_000) |_| {
        const literal = random.random().uintLessThan(u8, 8) != 0;
        const lengths: []u8 = if (literal) &table.literal else &table.distance;
        const at = random.random().uintLessThan(usize, lengths.len);
        const neighbor = if (at == 0) 1 else if (at + 1 == lengths.len) at - 1 else if (random.random().boolean()) at - 1 else at + 1;
        const wanted = lengths[neighbor];
        if (lengths[at] == wanted) continue;
        // Another symbol holding the wanted length gives it up for this one's.
        var other = random.random().uintLessThan(usize, lengths.len);
        var tries: usize = 0;
        while ((lengths[other] != wanted or other == neighbor) and tries < lengths.len) : (tries += 1) other = (other + 1) % lengths.len;
        if (lengths[other] != wanted or other == neighbor) continue;
        std.mem.swap(u8, &lengths[at], &lengths[other]);
        const candidate = cost(counts, &table, base);
        if (candidate < best) best = candidate else std.mem.swap(u8, &lengths[at], &lengths[other]);
    }
    std.debug.assert(table.valid());
    return table;
}

fn mebibytes(bytes: usize) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024 * 1024);
}
