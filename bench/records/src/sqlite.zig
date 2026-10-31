const std = @import("std");
const native = @import("native.zig");
const c = @import("sqlite_c");

pub fn version() []const u8 {
    return std.mem.span(c.sqlite3_libversion());
}

fn column(statement: *c.sqlite3_stmt, index: c_int) ![]const u8 {
    const pointer = c.sqlite3_column_blob(statement, index) orelse return error.InvalidSqliteRecord;
    const length = c.sqlite3_column_bytes(statement, index);
    if (length <= 0) return error.InvalidSqliteRecord;
    return @as([*]const u8, @ptrCast(pointer))[0..@intCast(length)];
}

fn check(code: c_int) !void {
    if (code != c.SQLITE_OK) {
        std.debug.print("SQLite error {d}\n", .{code});
        return error.SqliteFailure;
    }
}

fn exec(db: *c.sqlite3, sql: [:0]const u8) !void {
    try check(c.sqlite3_exec(db, sql, null, null, null));
}

fn prepare(db: *c.sqlite3, sql: [:0]const u8) !*c.sqlite3_stmt {
    var statement: ?*c.sqlite3_stmt = null;
    try check(c.sqlite3_prepare_v2(db, sql, @intCast(sql.len), &statement, null));
    return statement orelse error.MissingSqliteStatement;
}

fn scalar(db: *c.sqlite3, sql: [:0]const u8) !u64 {
    const statement = try prepare(db, sql);
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.MissingSqliteRow;
    const value = c.sqlite3_column_int64(statement, 0);
    if (value < 0) return error.InvalidSqliteValue;
    return @intCast(value);
}

fn checkpoint(db: *c.sqlite3) !void {
    try check(c.sqlite3_wal_checkpoint_v2(db, null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null));
}

fn fileSizes(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![2]u64 {
    var sizes: [2]u64 = undefined;
    for ([_][]const u8{ "", "-wal" }, &sizes) |suffix, *size| {
        const name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ path, suffix });
        defer allocator.free(name);
        const file = try std.Io.Dir.cwd().openFile(io, name, .{});
        defer file.close(io);
        size.* = (try file.stat(io)).size;
    }
    return sizes;
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, path: []const u8, trace: []const u8, page_size: u32, without_rowid: bool) !native.Result {
    var db_optional: ?*c.sqlite3 = null;
    const opened = c.sqlite3_open(try allocator.dupeSentinel(u8, path, 0), &db_optional);
    defer if (db_optional) |db| {
        const closed = c.sqlite3_close(db);
        std.debug.assert(closed == c.SQLITE_OK);
    };
    try check(opened);
    const db = db_optional orelse return error.MissingSqliteDatabase;
    try exec(db, try std.fmt.allocPrintSentinel(allocator, "PRAGMA page_size={d}", .{page_size}, 0));
    const journal = try prepare(db, "PRAGMA journal_mode=WAL");
    defer _ = c.sqlite3_finalize(journal);
    if (c.sqlite3_step(journal) != c.SQLITE_ROW) return error.SqliteWalUnavailable;
    if (!std.mem.eql(u8, try column(journal, 0), "wal")) return error.SqliteWalUnavailable;
    if (c.sqlite3_step(journal) != c.SQLITE_DONE) return error.SqliteWalUnavailable;
    try exec(db, "PRAGMA synchronous=FULL; PRAGMA cache_size=-2048; PRAGMA wal_autocheckpoint=0;");
    try exec(db, if (without_rowid) "CREATE TABLE records(key BLOB PRIMARY KEY NOT NULL,value BLOB NOT NULL) WITHOUT ROWID" else "CREATE TABLE records(key BLOB PRIMARY KEY NOT NULL,value BLOB NOT NULL)");
    try checkpoint(db);
    const put = try prepare(db, "INSERT INTO records VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value");
    defer _ = c.sqlite3_finalize(put);
    const delete = try prepare(db, "DELETE FROM records WHERE key=?");
    defer _ = c.sqlite3_finalize(delete);
    var input: native.Input = .{ .bytes = trace };
    const header = try input.read(12);
    if (!std.mem.eql(u8, header[0..8], "LRBENCH1")) return error.InvalidTrace;
    const io_before = try native.ioCounts(io);
    for (0..std.mem.readInt(u32, header[8..12], .little)) |_| {
        const transaction = try input.read(5);
        try exec(db, "BEGIN IMMEDIATE");
        for (0..std.mem.readInt(u32, transaction[0..4], .little)) |_| {
            const key = try input.read(16);
            const bytes = try input.read(4);
            const length = std.mem.readInt(u32, bytes[0..4], .little);
            const deleted = length == std.math.maxInt(u32);
            const statement = if (deleted) delete else put;
            try check(c.sqlite3_bind_blob(statement, 1, key.ptr, @intCast(key.len), null));
            if (!deleted) {
                const value = try input.read(length);
                try check(c.sqlite3_bind_blob(statement, 2, value.ptr, @intCast(value.len), null));
            }
            if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.SqliteWriteFailed;
            try check(c.sqlite3_reset(statement));
        }
        try exec(db, "COMMIT");
        if (transaction[4] == 1) try checkpoint(db);
    }
    if (input.offset != trace.len) return error.InvalidTrace;
    const before = try fileSizes(allocator, io, path);
    try checkpoint(db);
    const after = try fileSizes(allocator, io, path);
    const io_after = try native.ioCounts(io);
    const integrity = try prepare(db, "PRAGMA integrity_check");
    defer _ = c.sqlite3_finalize(integrity);
    if (c.sqlite3_step(integrity) != c.SQLITE_ROW or !std.mem.eql(u8, try column(integrity, 0), "ok")) return error.SqliteIntegrityFailure;
    const scan = try prepare(db, "SELECT key,value FROM records ORDER BY key");
    defer _ = c.sqlite3_finalize(scan);
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var rows: usize = 0;
    var payload: usize = 0;
    while (true) {
        const status = c.sqlite3_step(scan);
        if (status == c.SQLITE_DONE) break;
        if (status != c.SQLITE_ROW) return error.SqliteReadFailed;
        const key = try column(scan, 0);
        const value = try column(scan, 1);
        if (key.len != 16) return error.InvalidSqliteRecord;
        digest.update(key);
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(value.len), .little);
        digest.update(&length);
        digest.update(value);
        rows += 1;
        payload += value.len;
    }
    var hash: [32]u8 = undefined;
    digest.final(&hash);
    const hex = std.fmt.bytesToHex(hash, .lower);
    return .{ .before_checkpoint = .{ .database = before[0], .wal = before[1] }, .after_checkpoint = .{ .database = after[0], .wal = after[1] }, .submitted_bytes = io_after[0] - io_before[0], .kernel_write_bytes = io_after[1] - io_before[1], .page_size = page_size, .pages = try scalar(db, "PRAGMA page_count"), .free_pages = try scalar(db, "PRAGMA freelist_count"), .rows = rows, .payload = payload, .digest = try allocator.dupe(u8, &hex) };
}
