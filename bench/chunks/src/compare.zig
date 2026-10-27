const std = @import("std");
const records = @import("records");
const chunks = @import("chunks");
const storage = @import("storage");
const metrics = @import("metrics");
const nbt = @import("nbt");
const sqlite = @import("sqlite");
const corpus = @import("corpus.zig");
const anvil = @import("anvil.zig");
const common = @import("common.zig");
const terrain = @import("terrain.zig");

const Options = struct {
    corpus_path: []const u8 = ".zig-cache/world-bench/corpus.bin",
    output: []const u8 = ".zig-cache/storage-formats",
};
const Row = struct {
    format: []const u8,
    files: u64,
    payload: u64,
    file_count: usize,
    submitted_bytes: u64,
};
const Entry = struct { key: [16]u8, value: []const u8 };
const Trace = struct { bytes: []const u8, digest: [64]u8, payload: u64 };
const SqliteCase = struct { page_size: u32, without_rowid: bool, row: Row };

fn trace(allocator: std.mem.Allocator, source: *const corpus.Corpus) !Trace {
    const entries = try allocator.alloc(Entry, source.columns.len * corpus.section_count);
    defer allocator.free(entries);
    var encoded: [corpus.section_bytes]u8 = undefined;
    var payload: u64 = 0;
    for (source.columns, 0..) |column, index| for (column.sections, 0..) |section, y| {
        const bytes = try chunks.encoding.encode(section, &encoded);
        entries[index * corpus.section_count + y] = .{
            .key = chunks.encodeKey(.{ .world = 0, .x = column.x, .z = column.z, .y = @as(i32, @intCast(y)) + corpus.minimum_y }),
            .value = try allocator.dupe(u8, bytes),
        };
        payload += bytes.len;
    };
    defer for (entries) |entry| allocator.free(entry.value);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll("LRBENCH1");
    const batch = terrain.seed_columns * corpus.section_count;
    try output.writer.writeInt(u32, @intCast((entries.len + batch - 1) / batch), .little);
    for (entries, 0..) |entry, index| {
        if (index % batch == 0) {
            try output.writer.writeInt(u32, @intCast(@min(batch, entries.len - index)), .little);
            try output.writer.writeByte(1);
        }
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(entry.value.len), .little);
        try output.writer.writeAll(&entry.key);
        try output.writer.writeAll(&length);
        try output.writer.writeAll(entry.value);
    }
    std.mem.sort(Entry, entries, {}, struct {
        fn less(_: void, left: Entry, right: Entry) bool {
            return std.mem.lessThan(u8, &left.key, &right.key);
        }
    }.less);
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    for (entries) |entry| {
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(entry.value.len), .little);
        digest.update(&entry.key);
        digest.update(&length);
        digest.update(entry.value);
    }
    var hash: [32]u8 = undefined;
    digest.final(&hash);
    return .{ .bytes = try output.toOwnedSlice(), .digest = std.fmt.bytesToHex(hash, .lower), .payload = payload };
}

fn verifyNative(init: std.process.Init, source: *const corpus.Corpus, path: []const u8) !u64 {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    var registry = try metrics.Registry.init(init.gpa, init.io, .{ .capacity = 128 });
    defer registry.deinit();
    var store = try storage.Store.init(init.gpa, init.io, .{ .path = path, .metrics = &registry });
    defer store.deinit();
    const space = try store.openSpace(chunks.Chunks.id);
    const world = try chunks.Chunks.init(arena.allocator(), init.io, .{}, .{ .metrics = &registry, .storage = space, .record_workspaces = try records.Workspaces.init(arena.allocator(), init.io, .{}) });
    for (source.columns) |column| for (column.sections, 0..) |section, y| {
        const lease = try world.acquire(.{ .world = 0, .x = column.x, .z = column.z, .y = @as(i32, @intCast(y)) + corpus.minimum_y });
        defer lease.release();
        const view = lease.view();
        for (0..4096) |index| {
            const expected = std.mem.readInt(u16, section[if (section.len == 3) 1 else 1 + index * 2..][0..2], .little);
            if (view.get(@intCast(index)) != expected) return error.NativeTerrainMismatch;
        }
    };
    return (try store.database.stat(init.io)).size + (try store.wal.stat(init.io)).size;
}

fn verifyAnvil(init: std.process.Init, source: *const corpus.Corpus, directory: []const u8) !Row {
    const allocator = init.arena.allocator();
    const manifest_bytes = try common.readFile(allocator, init.io, try std.fs.path.join(allocator, &.{ directory, "corpus.json" }), 1024 * 1024);
    const manifest = try std.json.parseFromSlice(struct { data_version: i32, registry_sha256: []const u8, anvil_submitted_bytes: u64 }, allocator, manifest_bytes, .{ .ignore_unknown_fields = true });
    defer manifest.deinit();
    const registry = try anvil.Registry.load(allocator, init.io, try std.fs.path.join(allocator, &.{ directory, "registry.json" }));
    if (!std.mem.eql(u8, &registry.hash, manifest.value.registry_sha256)) return error.RegistryMismatch;
    var reader = try anvil.Reader.init(allocator, init.io, try std.fs.path.join(allocator, &.{ directory, "anvil" }), manifest.value.data_version);
    var decoded: [corpus.section_bytes]u8 = undefined;
    for (source.columns) |column| {
        const document = try reader.load(column.x, column.z);
        var sections: [corpus.section_count]?nbt.Node = @splat(null);
        var iterator = (document.childNamed("sections") orelse return error.MissingSections).childIterator(document.nodes);
        while (iterator.next()) |section| {
            const y = try (section.childNamed(document.nodes, "Y") orelse return error.MissingSectionY).byte();
            if (y < corpus.minimum_y or y >= corpus.minimum_y + corpus.section_count) return error.InvalidSectionY;
            const index: usize = @intCast(y - corpus.minimum_y);
            if (sections[index] != null) return error.DuplicateSection;
            sections[index] = section;
        }
        for (column.sections, sections) |expected, section| {
            const actual = try anvil.section(init.gpa, &registry, document, section, &decoded);
            if (!std.mem.eql(u8, expected, actual)) return error.AnvilTerrainMismatch;
        }
    }
    var region = try std.Io.Dir.cwd().openDir(init.io, reader.region, .{ .iterate = true });
    defer region.close(init.io);
    var iterator = region.iterate();
    var result: Row = .{ .format = "Anvil (NBT + zlib)", .files = 0, .payload = 0, .file_count = 0, .submitted_bytes = manifest.value.anvil_submitted_bytes };
    var columns: usize = 0;
    while (try iterator.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".mca")) return error.UnexpectedRegionFile;
        const file = try region.openFile(init.io, entry.name, .{});
        defer file.close(init.io);
        result.files += (try file.stat(init.io)).size;
        result.file_count += 1;
        var locations: [4096]u8 = undefined;
        if (try file.readPositionalAll(init.io, &locations, 0) != locations.len) return error.TruncatedRegion;
        for (0..1024) |index| {
            const location = std.mem.readInt(u32, locations[index * 4 ..][0..4], .big);
            if (location == 0) continue;
            var length: [4]u8 = undefined;
            if (try file.readPositionalAll(init.io, &length, @as(u64, location >> 8) * 4096) != length.len) return error.TruncatedRegion;
            const size = std.mem.readInt(u32, &length, .big);
            if (size < 1) return error.InvalidRegionLength;
            result.payload += size - 1;
            columns += 1;
        }
    }
    if (columns != source.columns.len) return error.AnvilColumnCountMismatch;
    return result;
}

pub fn main(init: std.process.Init) !void {
    try run(init);
}

fn run(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var options: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        if (index + 1 == args.len) return error.MissingArgument;
        if (std.mem.eql(u8, args[index], "--corpus")) options.corpus_path = args[index + 1] else if (std.mem.eql(u8, args[index], "--output")) options.output = args[index + 1] else return error.UnknownOption;
    }
    try std.Io.Dir.cwd().createDirPath(init.io, options.output);
    var source = try corpus.Corpus.load(allocator, init.io, options.corpus_path);
    defer source.deinit(allocator, init.io);
    const directory = std.fs.path.dirname(options.corpus_path) orelse ".";
    const vanilla = try verifyAnvil(init, &source, directory);
    const writes = try trace(allocator, &source);
    var sqlite_cases: [4]SqliteCase = undefined;
    var smallest: usize = 0;
    for (&sqlite_cases, 0..) |*case, layout| {
        const page_size: u32 = if (layout < 2) 4096 else 8192;
        const without_rowid = layout % 2 == 1;
        const sqlite_path = try std.fmt.allocPrint(allocator, "{s}/sqlite-{d}-{s}.db", .{ options.output, page_size, if (without_rowid) "without-rowid" else "rowid" });
        for ([_][]const u8{ "", "-wal", "-shm", "-journal" }) |suffix| {
            std.Io.Dir.cwd().deleteFile(init.io, try std.fmt.allocPrint(allocator, "{s}{s}", .{ sqlite_path, suffix })) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
        const result = try sqlite.run(allocator, init.io, sqlite_path, writes.bytes, page_size, without_rowid);
        if (result.rows != source.columns.len * corpus.section_count or !std.mem.eql(u8, result.digest, &writes.digest)) return error.SqliteTerrainMismatch;
        case.* = .{
            .page_size = page_size,
            .without_rowid = without_rowid,
            .row = .{ .format = "SQLite (packed sections)", .files = result.after_checkpoint.database + result.after_checkpoint.wal, .payload = result.payload, .file_count = 1, .submitted_bytes = result.submitted_bytes },
        };
        if (case.row.files < sqlite_cases[smallest].row.files) smallest = layout;
    }
    const sql = sqlite_cases[smallest];
    const native_path = try std.fs.path.join(allocator, &.{ options.output, "native.world" });
    const native_writes = try terrain.seedDatabase(init, &source, native_path);
    const native_bytes = try verifyNative(init, &source, native_path);
    const rows = [_]Row{
        vanilla,
        sql.row,
        .{ .format = "Native (packed tiles)", .files = native_bytes, .payload = writes.payload, .file_count = 2, .submitted_bytes = native_writes.wal_bytes + native_writes.maintenance_bytes },
    };
    var raw: u64 = 0;
    for (source.columns) |column| for (column.sections) |section| {
        raw += section.len;
    };
    const result_path = try std.fs.path.join(allocator, &.{ options.output, "results.json" });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = result_path, .data = try std.json.Stringify.valueAlloc(allocator, .{
        .corpus_sha256 = source.hash,
        .columns = source.columns.len,
        .sections = source.columns.len * corpus.section_count,
        .decoded_bytes = raw,
        .columns_per_commit = terrain.seed_columns,
        .scope = "Overworld block states only. No entities, inventories, biomes, lighting, or heightmaps.",
        .sqlite = .{ .version = sqlite.version(), .selected_page_size = sql.page_size, .selected_without_rowid = sql.without_rowid, .synchronous = "FULL", .journal = "WAL", .cases = sqlite_cases },
        .native = "Production chunk codec, 2x2 section tiles, durable WAL and completed maintenance",
        .anvil = "NBT palettes, zlib level 6, 4 KiB sectors. No atomic multi-chunk commit.",
        .rows = rows,
    }, .{ .whitespace = .indent_2 }) });
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &output.interface;
    try writer.print("\nTerrain storage comparison: {d} chunks, {d} sections, {d:.3} MiB decoded\n\n", .{ source.columns.len, source.columns.len * corpus.section_count, @as(f64, @floatFromInt(raw)) / 1048576 });
    try writer.print("{s: <28} {s: >10} {s: >12} {s: >12} {s: >12}\n", .{ "Format", "File MiB", "Payload MiB", "Overhead %", "Write MiB" });
    try writer.writeAll("--------------------------------------------------------------------------------\n");
    for (rows) |row| try writer.print("{s: <28} {d: >10.3} {d: >12.3} {d: >12.2} {d: >12.3}\n", .{
        row.format,
        @as(f64, @floatFromInt(row.files)) / 1048576,
        @as(f64, @floatFromInt(row.payload)) / 1048576,
        @as(f64, @floatFromInt(row.files - row.payload)) * 100 / @as(f64, @floatFromInt(row.payload)),
        @as(f64, @floatFromInt(row.submitted_bytes)) / 1048576,
    });
    try writer.writeAll("\nBlock states only. All terrain was read back and verified. Lower file size is better.\nFiles include indexes, free space, and retained WAL headers after maintenance.\nOverhead is (file - encoded payload) / encoded payload. Native tile headers count.\nWrites count submitted bytes including WAL, checkpoints, and region header updates.\nAnvil has no atomic multi-chunk commit. SQLite and native use durable WAL commits.\n");
    try writer.print("SQLite shows the smallest of four layouts: {d}-byte pages, {s}.\n", .{ sql.page_size, if (sql.without_rowid) "WITHOUT ROWID" else "rowid" });
    try writer.print("Detailed results: {s}\n", .{result_path});
    try writer.flush();
}
