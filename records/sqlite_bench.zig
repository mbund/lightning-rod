const std = @import("std");
const native = @import("bench.zig");

const Database = opaque {};
const Statement = opaque {};
const row = 100;
const done = 101;

const Api = struct {
    sqlite3_open: *const fn ([*:0]const u8, *?*Database) callconv(.c) c_int,
    sqlite3_close: *const fn (*Database) callconv(.c) c_int,
    sqlite3_exec: *const fn (*Database, [*:0]const u8, ?*const fn () callconv(.c) c_int, ?*anyopaque, ?*?[*:0]u8) callconv(.c) c_int,
    sqlite3_prepare_v2: *const fn (*Database, [*:0]const u8, c_int, *?*Statement, ?*?[*:0]const u8) callconv(.c) c_int,
    sqlite3_finalize: *const fn (*Statement) callconv(.c) c_int,
    sqlite3_step: *const fn (*Statement) callconv(.c) c_int,
    sqlite3_reset: *const fn (*Statement) callconv(.c) c_int,
    sqlite3_bind_blob: *const fn (*Statement, c_int, ?*const anyopaque, c_int, ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) c_int,
    sqlite3_column_int64: *const fn (*Statement, c_int) callconv(.c) i64,
    sqlite3_column_blob: *const fn (*Statement, c_int) callconv(.c) ?[*]const u8,
    sqlite3_column_text: *const fn (*Statement, c_int) callconv(.c) ?[*:0]const u8,
    sqlite3_column_bytes: *const fn (*Statement, c_int) callconv(.c) c_int,
    sqlite3_wal_checkpoint_v2: *const fn (*Database, ?[*:0]const u8, c_int, ?*c_int, ?*c_int) callconv(.c) c_int,
    sqlite3_libversion: *const fn () callconv(.c) [*:0]const u8,
};

pub const Sqlite = struct {
    library: std.DynLib,
    api: Api,

    pub fn init(path: []const u8) !Sqlite {
        var library = try std.DynLib.open(path);
        errdefer library.close();
        var api: Api = undefined;
        inline for (std.meta.fields(Api)) |field| @field(api, field.name) = library.lookup(field.type, field.name) orelse return error.MissingSqliteSymbol;
        return .{ .library = library, .api = api };
    }

    pub fn deinit(self: *Sqlite) void {
        self.library.close();
    }

    pub fn version(self: *const Sqlite) []const u8 {
        return std.mem.span(self.api.sqlite3_libversion());
    }

    fn check(code: c_int) !void {
        if (code != 0) {
            std.debug.print("SQLite error {d}\n", .{code});
            return error.SqliteFailure;
        }
    }

    fn exec(self: *const Sqlite, db: *Database, sql: [:0]const u8) !void {
        try check(self.api.sqlite3_exec(db, sql, null, null, null));
    }

    fn prepare(self: *const Sqlite, db: *Database, sql: [:0]const u8) !*Statement {
        var statement: ?*Statement = null;
        try check(self.api.sqlite3_prepare_v2(db, sql, @intCast(sql.len), &statement, null));
        return statement orelse error.MissingSqliteStatement;
    }

    fn scalar(self: *const Sqlite, db: *Database, sql: [:0]const u8) !u64 {
        const statement = try self.prepare(db, sql);
        defer _ = self.api.sqlite3_finalize(statement);
        if (self.api.sqlite3_step(statement) != row) return error.MissingSqliteRow;
        const value = self.api.sqlite3_column_int64(statement, 0);
        if (value < 0) return error.InvalidSqliteValue;
        return @intCast(value);
    }

    fn checkpoint(self: *const Sqlite, db: *Database) !void {
        try check(self.api.sqlite3_wal_checkpoint_v2(db, null, 3, null, null));
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

    pub fn run(self: *const Sqlite, allocator: std.mem.Allocator, io: std.Io, path: []const u8, trace: []const u8, page_size: u32, without_rowid: bool) !native.Result {
        var db_optional: ?*Database = null;
        try check(self.api.sqlite3_open(try allocator.dupeZ(u8, path), &db_optional));
        const db = db_optional orelse return error.MissingSqliteDatabase;
        defer _ = self.api.sqlite3_close(db);
        try self.exec(db, try std.fmt.allocPrintSentinel(allocator, "PRAGMA page_size={d}", .{page_size}, 0));
        const journal = try self.prepare(db, "PRAGMA journal_mode=WAL");
        defer _ = self.api.sqlite3_finalize(journal);
        if (self.api.sqlite3_step(journal) != row) return error.SqliteWalUnavailable;
        if (!std.mem.eql(u8, std.mem.span(self.api.sqlite3_column_text(journal, 0).?), "wal")) return error.SqliteWalUnavailable;
        if (self.api.sqlite3_step(journal) != done) return error.SqliteWalUnavailable;
        try self.exec(db, "PRAGMA synchronous=FULL; PRAGMA cache_size=-2048; PRAGMA wal_autocheckpoint=0;");
        try self.exec(db, if (without_rowid) "CREATE TABLE records(key BLOB PRIMARY KEY NOT NULL,value BLOB NOT NULL) WITHOUT ROWID" else "CREATE TABLE records(key BLOB PRIMARY KEY NOT NULL,value BLOB NOT NULL)");
        try self.checkpoint(db);
        const put = try self.prepare(db, "INSERT INTO records VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value");
        defer _ = self.api.sqlite3_finalize(put);
        const delete = try self.prepare(db, "DELETE FROM records WHERE key=?");
        defer _ = self.api.sqlite3_finalize(delete);
        var input: native.Input = .{ .bytes = trace };
        const header = try input.read(12);
        if (!std.mem.eql(u8, header[0..8], "LRBENCH1")) return error.InvalidTrace;
        const io_before = try native.ioCounts(io);
        for (0..std.mem.readInt(u32, header[8..12], .little)) |_| {
            const transaction = try input.read(5);
            try self.exec(db, "BEGIN IMMEDIATE");
            for (0..std.mem.readInt(u32, transaction[0..4], .little)) |_| {
                const key = try input.read(16);
                const bytes = try input.read(4);
                const length = std.mem.readInt(u32, bytes[0..4], .little);
                const deleted = length == std.math.maxInt(u32);
                const statement = if (deleted) delete else put;
                try check(self.api.sqlite3_bind_blob(statement, 1, key.ptr, @intCast(key.len), null));
                if (!deleted) {
                    const value = try input.read(length);
                    try check(self.api.sqlite3_bind_blob(statement, 2, value.ptr, @intCast(value.len), null));
                }
                if (self.api.sqlite3_step(statement) != done) return error.SqliteWriteFailed;
                try check(self.api.sqlite3_reset(statement));
            }
            try self.exec(db, "COMMIT");
            if (transaction[4] == 1) try self.checkpoint(db);
        }
        if (input.offset != trace.len) return error.InvalidTrace;
        const before = try fileSizes(allocator, io, path);
        try self.checkpoint(db);
        const after = try fileSizes(allocator, io, path);
        const io_after = try native.ioCounts(io);
        const integrity = try self.prepare(db, "PRAGMA integrity_check");
        defer _ = self.api.sqlite3_finalize(integrity);
        if (self.api.sqlite3_step(integrity) != row or !std.mem.eql(u8, std.mem.span(self.api.sqlite3_column_text(integrity, 0).?), "ok")) return error.SqliteIntegrityFailure;
        const scan = try self.prepare(db, "SELECT key,value FROM records ORDER BY key");
        defer _ = self.api.sqlite3_finalize(scan);
        var digest = std.crypto.hash.sha2.Sha256.init(.{});
        var rows: usize = 0;
        var payload: usize = 0;
        while (true) {
            const status = self.api.sqlite3_step(scan);
            if (status == done) break;
            if (status != row) return error.SqliteReadFailed;
            const key_length: usize = @intCast(self.api.sqlite3_column_bytes(scan, 0));
            const value_length: usize = @intCast(self.api.sqlite3_column_bytes(scan, 1));
            if (key_length != 16 or value_length == 0) return error.InvalidSqliteRecord;
            digest.update(self.api.sqlite3_column_blob(scan, 0).?[0..key_length]);
            var length: [4]u8 = undefined;
            std.mem.writeInt(u32, &length, @intCast(value_length), .little);
            digest.update(&length);
            digest.update(self.api.sqlite3_column_blob(scan, 1).?[0..value_length]);
            rows += 1;
            payload += value_length;
        }
        var hash: [32]u8 = undefined;
        digest.final(&hash);
        const hex = std.fmt.bytesToHex(hash, .lower);
        return .{ .before_checkpoint = .{ .database = before[0], .wal = before[1] }, .after_checkpoint = .{ .database = after[0], .wal = after[1] }, .submitted_bytes = io_after[0] - io_before[0], .kernel_write_bytes = io_after[1] - io_before[1], .page_size = page_size, .pages = try self.scalar(db, "PRAGMA page_count"), .free_pages = try self.scalar(db, "PRAGMA freelist_count"), .rows = rows, .payload = payload, .digest = try allocator.dupe(u8, &hex) };
    }
};
