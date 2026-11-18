const std = @import("std");
const chunks = @import("chunks");
const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");

const Part = enum {
    record_header,
    frame_header,
    biomes,
    terrain_lengths,
    section_headers,
    section_heights,
    section_palettes,
    section_entities,
    section_words,
    heightmap,
    light_tags,
    light_fragments,
    variant_directory,
    compiled_tables,
    compiled_headers,
    compiled_words,
    compiled_biomes,
    compiled_entities,
};

/// Splits a world's derived cache into the parts its records hold, to see where its bytes go.
pub fn main(init: std.process.Init) !void {
    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    const path = arguments.next() orelse return error.MissingWorld;
    // Writes each stored classification frame to its own file there, to try other codecs on.
    const dump = arguments.next();
    if (arguments.next() != null) return error.InvalidArguments;
    var dumped: usize = 0;
    const allocator = init.arena.allocator();
    const io = init.io;
    var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 128 });
    defer registry.deinit();
    var store = try storage.Store.init(allocator, io, .{ .path = path, .metrics = &registry });
    defer store.deinit();
    const resources = try records.Workspaces.init(allocator, io, .{ .metrics = &registry });
    const terrain = try chunks.Chunks.init(allocator, io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 1, .cache_groups = 1 }, .{ .metrics = &registry, .storage = try store.openSpace(chunks.Chunks.id), .record_workspaces = resources });
    // Roots the derived tables.
    {
        var after: [64]u8 = undefined;
        var cursor: records.ScanCursor = .{ .after = &after };
        var batch: [1]chunks.Light.Column = undefined;
        _ = try terrain.savedLightColumns(&cursor, &batch);
    }
    const derived = terrain.cache.backend.store;
    var parts: [std.enums.values(Part).len]u64 = @splat(0);
    var kinds: [8]struct { count: u64 = 0, key: u64 = 0, value: u64 = 0 } = @splat(.{});
    var workspace = try chunks.Light.Workspace.init(allocator);
    defer workspace.deinit();
    var sections: u64 = 0;
    var overflow_pages: u64 = 0;
    var overflow_waste: u64 = 0;
    var local_bytes: u64 = 0;
    var headers: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    var palettes_only: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var same_records: u64 = 0;
    var same_record_bytes: u64 = 0;
    var same_headers: u64 = 0;
    var headers_seen: u64 = 0;
    var uniform_sections: u64 = 0;
    var variants: u64 = 0;
    var columns: u64 = 0;
    var buffer = try allocator.alloc(u8, 4 << 20);
    {
        var after: [64]u8 = undefined;
        var cursor: records.ScanCursor = .{ .after = &after };
        var key_storage: [64][64]u8 = undefined;
        while (true) {
            var keys: [64]records.ScanKey = undefined;
            for (&keys, &key_storage) |*key, *bytes| key.* = .{ .key = bytes };
            const result = try derived.lights.scanKeys(&cursor, &keys);
            for (keys[0..result.count]) |scanned| {
                const key = scanned.key[0..scanned.key_len];
                const length = (try derived.lights.get(key, buffer)) orelse return error.MissingRecord;
                if (length > buffer.len) {
                    buffer = try allocator.alloc(u8, length);
                    _ = try derived.lights.get(key, buffer);
                }
                const kind = &kinds[@min(key[0], 7)];
                kind.count += 1;
                kind.key += key.len;
                kind.value += length;
                if (length > 1277) {
                    const remainder = length % 4064;
                    if (remainder > 2626) {
                        overflow_pages += length / 4064 + 1;
                        overflow_waste += 4064 - remainder;
                    } else {
                        overflow_pages += length / 4064;
                        local_bytes += remainder + 8 + key.len + (length / 4064) * 8;
                    }
                } else local_bytes += length + 8 + key.len;
                if (key[0] != @intFromEnum(chunks.Light.Column.Kind.light)) continue;
                columns += 1;
                const bytes = buffer[0..length];
                const column = try chunks.Delivery.Column.read(bytes);
                parts[@intFromEnum(Part.record_header)] += chunks.Delivery.Column.header_size;
                parts[@intFromEnum(Part.variant_directory)] += column.slots * chunks.Delivery.Column.entry_size;
                const view = try workspace.decode(column.frame);
                const frame = column.frame;
                const metadata: usize = if (view.metadata) |value| 32 + value.bytes.len else 0;
                parts[@intFromEnum(Part.frame_header)] += chunks.Light.header_bytes + metadata;
                var terrain_start: ?usize = null;
                for (view.terrain[0..view.header.count]) |maybe| {
                    sections += 1;
                    const encoded = maybe orelse {
                        uniform_sections += 1;
                        continue;
                    };
                    const offset = @intFromPtr(encoded.bytes.ptr) - @intFromPtr(frame.ptr);
                    if (terrain_start == null) terrain_start = offset - 2;
                    parts[@intFromEnum(Part.terrain_lengths)] += 2;
                    const section = encoded.view();
                    {
                        var hash = std.hash.Wyhash.init(0);
                        hash.update(std.mem.asBytes(&section.count));
                        hash.update(&.{section.bits});
                        hash.update(section.palette);
                        const entry = try headers.getOrPut(allocator, hash.final());
                        if (!entry.found_existing) entry.value_ptr.* = 0;
                        entry.value_ptr.* += 1;
                        palettes_only.put(allocator, std.hash.Wyhash.hash(1, section.palette), {}) catch {};
                    }
                    parts[@intFromEnum(Part.section_headers)] += chunks.Prepared.header_bytes;
                    parts[@intFromEnum(Part.section_heights)] += section.heights.bytes.len;
                    parts[@intFromEnum(Part.section_palettes)] += section.palette.len;
                    parts[@intFromEnum(Part.section_entities)] += section.entities.len;
                    parts[@intFromEnum(Part.section_words)] += section.words.bytes.len;
                }
                if (view.heightmap) |heightmap| parts[@intFromEnum(Part.heightmap)] += 10 + heightmap.packet.bytes.len;
                for (0..2) |layer| for (0..view.header.count + 2) |index| {
                    parts[@intFromEnum(Part.light_tags)] += 1;
                    switch (view.layer(layer, index)) {
                        .encoded => |value| {
                            parts[@intFromEnum(Part.light_tags)] += 12;
                            parts[@intFromEnum(Part.light_fragments)] += value.fragment.bytes.len;
                        },
                        else => {},
                    }
                };
                // Biomes are what the frame holds between its header and its terrain.
                const terrain_offset = terrain_start orelse frame.len;
                parts[@intFromEnum(Part.biomes)] += terrain_offset -| (chunks.Light.header_bytes + metadata);
                var earlier: [8]chunks.Delivery.View = undefined;
                var earlier_count: usize = 0;
                for (0..column.slots) |slot| {
                    const entry = bytes[chunks.Delivery.Column.header_size + frame.len + slot * chunks.Delivery.Column.entry_size ..][0..chunks.Delivery.Column.entry_size];
                    const offset = std.mem.readInt(u32, entry[32..36], .little);
                    const size = std.mem.readInt(u32, entry[36..40], .little);
                    if (size == 0) continue;
                    variants += 1;
                    const compiled = try chunks.Delivery.View.read(bytes[offset..][0..size], .fromHeader(&view.header));
                    var fragment_bytes: u64 = 0;
                    var seen: [32]usize = undefined;
                    var unique: usize = 0;
                    for (0..compiled.count) |index| {
                        const slot_index = compiled.bytes[chunks.Delivery.header_bytes + index];
                        if (std.mem.indexOfScalar(usize, seen[0..unique], slot_index) != null) continue;
                        seen[unique] = slot_index;
                        unique += 1;
                        const parts_ = compiled.section(index);
                        parts[@intFromEnum(Part.compiled_headers)] += parts_.header.bytes.len;
                        fragment_bytes += parts_.header.bytes.len;
                        if (parts_.words) |words| {
                            parts[@intFromEnum(Part.compiled_words)] += words.bytes.len;
                            fragment_bytes += words.bytes.len;
                        }
                        if (parts_.biome) |biome| {
                            parts[@intFromEnum(Part.compiled_biomes)] += biome.bytes.len;
                            fragment_bytes += biome.bytes.len;
                        }
                        parts[@intFromEnum(Part.compiled_entities)] += parts_.entities.len;
                        fragment_bytes += parts_.entities.len;
                    }
                    parts[@intFromEnum(Part.compiled_tables)] += size - fragment_bytes;
                    for (earlier[0..earlier_count]) |other| {
                        if (std.mem.eql(u8, other.bytes, compiled.bytes)) {
                            same_records += 1;
                            same_record_bytes += size;
                            break;
                        }
                    }
                    for (0..compiled.count) |index| {
                        const mine = compiled.section(index);
                        for (earlier[0..earlier_count]) |other| {
                            const theirs = other.section(index);
                            if (std.mem.eql(u8, mine.header.bytes, theirs.header.bytes)) {
                                same_headers += 1;
                                break;
                            }
                        }
                        headers_seen += 1;
                    }
                    earlier[earlier_count] = compiled;
                    earlier_count += 1;
                }
            }
            if (!result.more) break;
        }
    }
    var classification_count: u64 = 0;
    var classification_key: u64 = 0;
    var classification_value: u64 = 0;
    {
        var after: [64]u8 = undefined;
        var cursor: records.ScanCursor = .{ .after = &after };
        var key_storage: [16][64]u8 = undefined;
        var value_storage: [16][8]u8 = undefined;
        while (true) {
            var entries: [16]records.ScanEntry = undefined;
            for (&entries, &key_storage, &value_storage) |*entry, *key, *value| entry.* = .{ .key = key, .value = value };
            const result = try derived.classifications.scan(&cursor, &entries);
            for (entries[0..result.count]) |entry| {
                if (entry.value_len != 8) continue;
                const directory: storage.PageId = @fromBackingInt(std.mem.readInt(u64, entry.value[0..8], .little));
                const table = records.Table.rooted(derived.classifications.space, directory, 0, derived.classifications.resources);
                var inner_after: [64]u8 = undefined;
                var inner: records.ScanCursor = .{ .after = &inner_after };
                var inner_keys: [64][64]u8 = undefined;
                while (true) {
                    var keys: [64]records.ScanKey = undefined;
                    for (&keys, &inner_keys) |*key, *bytes| key.* = .{ .key = bytes };
                    const batch = try table.scanKeys(&inner, &keys);
                    var lengths: [64]?usize = undefined;
                    var slices: [64][]const u8 = undefined;
                    for (keys[0..batch.count], slices[0..batch.count]) |key, *slice| slice.* = key.key[0..key.key_len];
                    try table.lengthsBatch(slices[0..batch.count], lengths[0..batch.count]);
                    for (slices[0..batch.count], lengths[0..batch.count]) |key, value| {
                        classification_count += 1;
                        classification_key += key.len;
                        classification_value += value orelse 0;
                        local_bytes += (value orelse 0) + 8 + key.len;
                        if (dump) |folder| {
                            var record: [4096]u8 = undefined;
                            const n = (try table.get(key, &record)) orelse continue;
                            if (record[0] != 1) continue;
                            var name: [256]u8 = undefined;
                            const file_path = try std.fmt.bufPrint(&name, "{s}/{d}.zst", .{ folder, dumped });
                            dumped += 1;
                            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = record[1..n] });
                        }
                    }
                    if (!batch.more) break;
                }
            }
            if (!result.more) break;
        }
    }
    const world_tables = [_]struct { name: []const u8, table: records.Table }{ .{ .name = "bases", .table = derived.bases.backend.table }, .{ .name = "overlays", .table = derived.overlays }, .{ .name = "revisions", .table = derived.revisions } };
    var world_sizes: [world_tables.len][3]u64 = @splat(@splat(0));
    for (world_tables, &world_sizes) |entry, *size| size.* = try tableSize(entry.table);
    if (dump) |folder| try dumpTable(io, derived.bases.backend.table, folder, buffer);
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    const out = &output.interface;
    try out.print("columns {d}, sections {d} ({d} uniform), compiled variants {d}\n", .{ columns, sections, uniform_sections, variants });
    for (kinds, 0..) |kind, index| if (kind.count != 0) try out.print("kind {d}: {d} records, keys {d:.2} MB, values {d:.2} MB\n", .{ index, kind.count, megabytes(kind.key), megabytes(kind.value) });
    try out.print("classifications: {d} records, keys {d:.2} MB, values {d:.2} MB\n", .{ classification_count, megabytes(classification_key), megabytes(classification_value) });
    try out.print("variant records equal to an earlier variant: {d} ({d:.2} MB); section headers equal: {d} of {d}\n", .{ same_records, megabytes(same_record_bytes), same_headers, headers_seen });
    for (world_tables, world_sizes) |entry, size| try out.print("world {s}: {d} records, keys {d:.2} MB, values {d:.2} MB\n", .{ entry.name, size[0], megabytes(size[1]), megabytes(size[2]) });
    try out.print("mixed section headers: {d} distinct (palettes alone {d})\n", .{ headers.count(), palettes_only.count() });
    try out.print("light table overflow pages {d} ({d:.2} MB, {d:.2} MB of it unused tails); leaf-resident bytes incl. classifications {d:.2} MB\n", .{ overflow_pages, megabytes(overflow_pages * 4096), megabytes(overflow_waste), megabytes(local_bytes) });
    var total: u64 = 0;
    for (parts) |value| total += value;
    for (parts, 0..) |value, index| try out.print("  {s:<20} {d:>8.2} MB {d:>6.0} B/column\n", .{ @tagName(@as(Part, @enumFromInt(index))), megabytes(value), @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(@max(columns, 1))) });
    try out.print("  {s:<20} {d:>8.2} MB\n", .{ "total", megabytes(total) });
    try out.flush();
}

fn dumpTable(io: std.Io, table: records.Table, folder: []const u8, buffer: []u8) !void {
    var after: [64]u8 = undefined;
    var cursor: records.ScanCursor = .{ .after = &after };
    var key_storage: [64][64]u8 = undefined;
    var index: usize = 0;
    while (true) {
        var keys: [64]records.ScanKey = undefined;
        for (&keys, &key_storage) |*key, *bytes| key.* = .{ .key = bytes };
        const batch = try table.scanKeys(&cursor, &keys);
        for (keys[0..batch.count]) |key| {
            const n = (try table.get(key.key[0..key.key_len], buffer)) orelse continue;
            var name: [256]u8 = undefined;
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name, "{s}/base{d}.zst", .{ folder, index }), .data = buffer[0..n] });
            index += 1;
        }
        if (!batch.more) break;
    }
}

fn tableSize(table: records.Table) ![3]u64 {
    var result: [3]u64 = @splat(0);
    var after: [64]u8 = undefined;
    var cursor: records.ScanCursor = .{ .after = &after };
    var key_storage: [64][64]u8 = undefined;
    while (true) {
        var keys: [64]records.ScanKey = undefined;
        for (&keys, &key_storage) |*key, *bytes| key.* = .{ .key = bytes };
        const batch = try table.scanKeys(&cursor, &keys);
        var lengths: [64]?usize = undefined;
        var slices: [64][]const u8 = undefined;
        for (keys[0..batch.count], slices[0..batch.count]) |key, *slice| slice.* = key.key[0..key.key_len];
        try table.lengthsBatch(slices[0..batch.count], lengths[0..batch.count]);
        for (slices[0..batch.count], lengths[0..batch.count]) |key, value| {
            result[0] += 1;
            result[1] += key.len;
            result[2] += value orelse 0;
        }
        if (!batch.more) break;
    }
    return result;
}

fn megabytes(value: u64) f64 {
    return @as(f64, @floatFromInt(value)) / 1e6;
}
