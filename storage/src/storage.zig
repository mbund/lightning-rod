const std = @import("std");

/// A single-threaded, tick-scoped, namespaced byte store. The caller owns all read/write buffers.
/// Their loans end on return. Namespace names outlive their bindings.
pub const Storage = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        begin: *const fn (*anyopaque, std.Io, u64) Error!Transaction,
        last_tick: *const fn (*const anyopaque) u64,
        durable_tick: *const fn (*const anyopaque) u64,
        flush: *const fn (*anyopaque, std.Io) Error!void,
    };

    pub fn begin(self: Storage, io: std.Io, tick: u64) Error!Transaction {
        return self.vtable.begin(self.context, io, tick);
    }

    /// Latest complete tick accepted by the backend, including pending durability.
    pub fn lastTick(self: Storage) u64 {
        return self.vtable.last_tick(self.context);
    }

    /// Highest acknowledged durable tick, which may lag the last submitted tick.
    pub fn durableTick(self: Storage) u64 {
        return self.vtable.durable_tick(self.context);
    }

    pub fn flush(self: Storage, io: std.Io) Error!void {
        return self.vtable.flush(self.context, io);
    }
};

pub const Error = error{
    Closed,
    Busy,
    InvalidArgument,
    BufferTooSmall,
    Corrupt,
    UnsupportedFormat,
    IoFailure,
    NoSpace,
    FailedTransaction,
};

pub const Transaction = struct {
    context: *anyopaque,
    lease: u64,
    vtable: *const VTable,

    pub const VTable = struct {
        namespace: *const fn (*anyopaque, u64, []const u8) Error!Namespace,
        submit: *const fn (*anyopaque, u64) Error!void,
        abort: *const fn (*anyopaque, u64) void,
    };

    pub fn namespace(self: Transaction, bytes: []const u8) Error!Namespace {
        return self.vtable.namespace(self.context, self.lease, bytes);
    }

    /// Seal one complete tick. The backend owns its immutable writes until durable completion.
    /// Bounded backend capacity may make this call wait.
    pub fn submit(self: Transaction) Error!void {
        return self.vtable.submit(self.context, self.lease);
    }

    pub fn abort(self: Transaction) void {
        self.vtable.abort(self.context, self.lease);
    }
};

pub const Namespace = struct {
    /// A namespace binds one Store for its full lifetime and resolves that
    /// store's current active transaction on every operation. `bytes` is
    /// borrowed for the binding lifetime, so inject a stable literal or an
    /// owner-retained buffer rather than temporary tick storage.
    context: *anyopaque,
    bytes: []const u8,
    vtable: *const VTable,

    pub const VTable = struct {
        fail: *const fn (*anyopaque) void,
        get: *const fn (*anyopaque, []const u8, []const u8, []u8) Error!?usize,
        put_batch: *const fn (*anyopaque, []const u8, []const Write) Error!void,
        get_batch: *const fn (*anyopaque, []const u8, []const Get, []?usize) Error!void,
        scan: *const fn (*anyopaque, []const u8, *ScanCursor, []ScanEntry) Error!ScanResult,
    };

    pub fn get(self: Namespace, key: []const u8, destination: []u8) Error!?usize {
        return self.vtable.get(self.context, self.bytes, key, destination);
    }

    /// Irreversible in-memory failure: no namespace may submit this tick afterward.
    pub fn fail(self: Namespace) void {
        self.vtable.fail(self.context);
    }

    /// Destinations must not overlap. Independent reads may run concurrently. All loans end before
    /// this call returns, including on failure.
    pub fn getBatch(self: Namespace, records: []const Get, lengths: []?usize) Error!void {
        if (records.len != lengths.len) return error.InvalidArgument;
        return self.vtable.get_batch(self.context, self.bytes, records, lengths);
    }

    pub fn put(self: Namespace, key: []const u8, value: ?[]const u8) Error!void {
        return self.putBatch(&.{.{ .key = key, .value = value }});
    }

    pub fn putBatch(self: Namespace, records: []const Write) Error!void {
        return self.vtable.put_batch(self.context, self.bytes, records);
    }

    pub fn scan(self: Namespace, cursor: *ScanCursor, entries: []ScanEntry) Error!ScanResult {
        return self.vtable.scan(self.context, self.bytes, cursor, entries);
    }
};

pub const Get = struct {
    key: []const u8,
    destination: []u8,
};

pub const Write = struct {
    key: []const u8,
    value: ?[]const u8,
};

pub const ScanCursor = struct {
    /// `after[0..after_len]` is exclusive. Its storage is owned by the caller.
    after: []u8,
    after_len: usize = 0,
};

pub const ScanEntry = struct {
    key: []u8,
    value: []u8,
    key_len: usize = 0,
    value_len: usize = 0,
};

pub const ScanResult = struct {
    count: usize,
    more: bool,
};
