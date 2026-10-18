const std = @import("std");
const native = @import("bench.zig");
const sqlite = @import("sqlite_bench.zig");

const Pattern = enum { ordered, shuffled, churn };
const Workload = struct { bytes: []const u8, digest: [64]u8, rows: usize };

fn operation(allocator: std.mem.Allocator, writer: *std.Io.Writer, model: *[4096]?[]const u8, id: u32, version: u32, length: ?usize) !void {
    var key: [16]u8 = undefined;
    std.mem.writeInt(u128, &key, id, .big);
    try writer.writeAll(&key);
    try writer.writeInt(u32, if (length) |size| @intCast(size) else std.math.maxInt(u32), .little);
    model[id] = null;
    if (length) |size| {
        const value = try allocator.alloc(u8, size);
        var seed: [8]u8 = undefined;
        std.mem.writeInt(u32, seed[0..4], id, .little);
        std.mem.writeInt(u32, seed[4..8], version, .little);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&seed, &hash, .{});
        for (value, 0..) |*byte, at| byte.* = hash[at % hash.len];
        try writer.writeAll(value);
        model[id] = value;
    }
}

fn workload(allocator: std.mem.Allocator, pattern: Pattern) !Workload {
    var trace: std.Io.Writer.Allocating = .init(allocator);
    defer trace.deinit();
    var model: [4096]?[]const u8 = @splat(null);
    var order: [4096]u32 = undefined;
    for (&order, 0..) |*id, at| id.* = @intCast(at);
    var prng = std.Random.DefaultPrng.init(0x4c5253514c);
    const random = prng.random();
    if (pattern != .ordered) random.shuffle(u32, &order);
    try trace.writer.writeAll("LRBENCH1");
    try trace.writer.writeInt(u32, if (pattern == .churn) 18 else 1, .little);
    try trace.writer.writeInt(u32, 4096, .little);
    try trace.writer.writeByte(0);
    for (order) |id| try operation(allocator, &trace.writer, &model, id, 0, 519);
    if (pattern == .churn) {
        for (1..17) |version| {
            try trace.writer.writeInt(u32, 1024, .little);
            try trace.writer.writeByte(@intFromBool(version % 4 == 0));
            for (0..1024) |_| {
                const id = random.uintLessThan(u32, 4096);
                const lengths = [_]?usize{ null, 3, 519, 768, 1035, 8193 };
                try operation(allocator, &trace.writer, &model, id, @intCast(version), lengths[random.uintLessThan(usize, lengths.len)]);
            }
        }
        try trace.writer.writeInt(u32, 3072, .little);
        try trace.writer.writeByte(0);
        for (0..4096) |id| if (id % 4 != 0) {
            try operation(allocator, &trace.writer, &model, @intCast(id), 17, null);
        };
    }
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var rows: usize = 0;
    for (model, 0..) |value, id| if (value) |bytes| {
        var key: [16]u8 = undefined;
        std.mem.writeInt(u128, &key, id, .big);
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(bytes.len), .little);
        digest.update(&key);
        digest.update(&length);
        digest.update(bytes);
        rows += 1;
    };
    var hash: [32]u8 = undefined;
    digest.final(&hash);
    return .{ .bytes = try trace.toOwnedSlice(), .digest = std.fmt.bytesToHex(hash, .lower), .rows = rows };
}

fn clean(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    for ([_][]const u8{ "", ".wal", ".wal.next", "-wal", "-shm", "-journal" }) |suffix| {
        const name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ path, suffix });
        std.Io.Dir.cwd().deleteFile(io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

const Case = struct { workload: Pattern, engine: []const u8, trace_sha256: []const u8, result: native.Result };
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var output: []const u8 = ".zig-cache/storage-comparison";
    var library: []const u8 = "libsqlite3.so.0";
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        if (index + 1 == args.len) return error.MissingArgument;
        if (std.mem.eql(u8, args[index], "--output")) output = args[index + 1] else if (std.mem.eql(u8, args[index], "--sqlite")) library = args[index + 1] else return error.UnknownArgument;
    }
    var reference = try sqlite.Sqlite.init(library);
    defer reference.deinit();
    try std.Io.Dir.cwd().createDirPath(init.io, output);
    var cases: std.ArrayList(Case) = .empty;
    for (std.enums.values(Pattern)) |pattern| {
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        const trace = try workload(arena.allocator(), pattern);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(trace.bytes, &hash, .{});
        const trace_hex = std.fmt.bytesToHex(hash, .lower);
        const trace_hash = try allocator.dupe(u8, &trace_hex);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}.trace", .{ output, @tagName(pattern) }), .data = trace.bytes });
        for (0..5) |engine| {
            const page_size: u32 = if (engine <= 2) 4096 else 8192;
            const without_rowid = engine % 2 == 0;
            const label = if (engine == 0) "native" else try std.fmt.allocPrint(allocator, "sqlite-{d}-{s}", .{ page_size, if (without_rowid) "without-rowid" else "rowid" });
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}.{s}", .{ output, @tagName(pattern), label });
            try clean(allocator, init.io, path);
            const result = if (engine == 0) try native.run(allocator, init.io, path, trace.bytes) else try reference.run(allocator, init.io, path, trace.bytes, page_size, without_rowid);
            if (!std.mem.eql(u8, &trace.digest, result.digest) or result.rows != trace.rows) return error.RecordMismatch;
            try cases.append(allocator, .{ .workload = pattern, .engine = label, .trace_sha256 = trace_hash, .result = result });
            std.debug.print("{s:9} {s:30} files={d:9} live={d:9} payload={d:9} writes={d:10}\n", .{ @tagName(pattern), label, result.after_checkpoint.database + result.after_checkpoint.wal, (result.pages - result.free_pages) * result.page_size, result.payload, result.submitted_bytes });
        }
    }
    const file = try std.Io.Dir.cwd().createFile(init.io, try std.fs.path.join(allocator, &.{ output, "results.json" }), .{});
    defer file.close(init.io);
    var buffer: [16384]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    try std.json.Stringify.value(.{ .sqlite_version = reference.version(), .trace_seed = @as(u64, 0x4c5253514c), .configuration = .{ .native_submission = "standard", .sqlite_synchronous = "FULL", .sqlite_cache_kib = 2048, .durable_commits = true, .native_batching = "whole transaction, bounded key sorting", .vacuum = false }, .cases = cases.items }, .{ .whitespace = .indent_2 }, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}
