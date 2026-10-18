const std = @import("std");
const records = @import("records");
const storage = @import("storage");
const metrics = @import("metrics");

const value_capacity = 8193;
const batch_size = 192;

pub const Input = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn read(self: *Input, length: usize) ![]const u8 {
        if (length > self.bytes.len - self.offset) return error.TruncatedTrace;
        const result = self.bytes[self.offset..][0..length];
        self.offset += length;
        return result;
    }
};

pub fn checkpoint(store: *storage.Store) !void {
    for (0..10000) |_| {
        _ = try store.maintain(storage.batch_size);
        if (store.end == 64 and store.phase == .idle) return;
    }
    return error.CheckpointDidNotFinish;
}

fn sizes(store: *storage.Store) ![2]u64 {
    return .{ (try store.database.stat(store.io)).size, (try store.wal.stat(store.io)).size };
}

pub fn ioCounts(io: std.Io) ![2]u64 {
    const file = try std.Io.Dir.cwd().openFile(io, "/proc/self/io", .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    const length = try file.readPositionalAll(io, &buffer, 0);
    var result: [2]u64 = @splat(0);
    var found: usize = 0;
    var lines = std.mem.splitScalar(u8, buffer[0..length], '\n');
    while (lines.next()) |line| {
        for ([_][]const u8{ "wchar: ", "write_bytes: " }, 0..) |prefix, index| {
            if (!std.mem.startsWith(u8, line, prefix)) continue;
            result[index] = try std.fmt.parseInt(u64, line[prefix.len..], 10);
            found += 1;
        }
    }
    if (found != result.len) return error.MissingIoCounts;
    return result;
}

pub const Result = struct {
    before_checkpoint: struct { database: u64, wal: u64 },
    after_checkpoint: struct { database: u64, wal: u64 },
    submitted_bytes: u64,
    kernel_write_bytes: u64,
    submitted_wal_bytes: u64 = 0,
    maintenance_bytes: u64 = 0,
    page_size: u64,
    pages: u64,
    free_pages: u64,
    rows: usize,
    payload: usize,
    digest: []const u8,
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, path: []const u8, trace: []const u8) !Result {
    var input: Input = .{ .bytes = trace };
    const header = try input.read(12);
    if (!std.mem.eql(u8, header[0..8], "LRBENCH1")) return error.InvalidTrace;
    const transactions = std.mem.readInt(u32, header[8..12], .little);
    var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 64 });
    defer registry.deinit();
    var store = try storage.Store.init(allocator, io, .{ .path = path, .submission = .standard, .checkpoint_bytes = 64, .metrics = &registry });
    defer store.deinit();
    const table = records.Table.init(try store.openSpace("records"));
    const values = try allocator.alloc([value_capacity]u8, batch_size);
    defer allocator.free(values);
    var keys: [batch_size][16]u8 = undefined;
    const writes = try allocator.alloc(records.Write, 65536);
    defer allocator.free(writes);
    const io_before = try ioCounts(io);
    for (0..transactions) |tick| {
        const transaction = try input.read(5);
        const count = std.mem.readInt(u32, transaction[0..4], .little);
        if (transaction[4] > 1 or count > writes.len) return error.InvalidTrace;
        for (writes[0..count]) |*write| {
            const key = try input.read(16);
            const bytes = try input.read(4);
            const length = std.mem.readInt(u32, bytes[0..4], .little);
            write.* = .{ .key = key, .value = null };
            if (length != std.math.maxInt(u32)) {
                if (length > value_capacity) return error.InvalidTrace;
                write.value = try input.read(length);
            }
        }
        try table.putBatch(writes[0..count]);
        try store.waitDurable(try store.commit(tick + 1));
        if (transaction[4] == 1) try checkpoint(&store);
    }
    if (input.offset != trace.len) return error.InvalidTrace;
    const before = try sizes(&store);
    try checkpoint(&store);
    const after = try sizes(&store);
    const io_after = try ioCounts(io);
    var free = store.metadata.free;
    var free_pages: u64 = 0;
    while (free != 0) {
        if (free >= store.metadata.pages or free_pages == store.metadata.pages) return error.Corrupt;
        var next: [8]u8 = undefined;
        if (try store.database.readPositionalAll(io, &next, free * 4096 + 32) != next.len) return error.Corrupt;
        free = std.mem.readInt(u64, &next, .little);
        free_pages += 1;
    }
    var cursor_key: [64]u8 = undefined;
    var cursor: records.ScanCursor = .{ .after = &cursor_key };
    var entries: [batch_size]records.ScanEntry = undefined;
    for (&entries, &keys, values) |*entry, *key, *value| entry.* = .{ .key = key, .value = value };
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var rows: usize = 0;
    var payload: usize = 0;
    while (true) {
        const result = try table.scan(&cursor, &entries);
        for (entries[0..result.count]) |entry| {
            digest.update(entry.key[0..entry.key_len]);
            var length: [4]u8 = undefined;
            std.mem.writeInt(u32, &length, @intCast(entry.value_len), .little);
            digest.update(&length);
            digest.update(entry.value[0..entry.value_len]);
            rows += 1;
            payload += entry.value_len;
        }
        if (!result.more) break;
    }
    var hash: [32]u8 = undefined;
    digest.final(&hash);
    const hex = std.fmt.bytesToHex(hash, .lower);
    return .{ .before_checkpoint = .{ .database = before[0], .wal = before[1] }, .after_checkpoint = .{ .database = after[0], .wal = after[1] }, .submitted_bytes = io_after[0] - io_before[0], .kernel_write_bytes = io_after[1] - io_before[1], .submitted_wal_bytes = store.wal_bytes.value(), .maintenance_bytes = store.checkpoint_bytes.value(), .page_size = 4096, .pages = store.metadata.pages, .free_pages = free_pages, .rows = rows, .payload = payload, .digest = try allocator.dupe(u8, &hex) };
}
