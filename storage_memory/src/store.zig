const std = @import("std");
const storage = @import("storage");

const assert = std.debug.assert;

/// Bounded volatile storage. Only modified values occupy an alternate slot. Commit switches
/// metadata, and abort leaves committed values untouched.
pub const Store = struct {
    pub const Options = struct {
        max_records: usize,
        max_namespace_bytes: usize,
        max_key_bytes: usize,
        max_value_bytes: usize,
    };

    const Record = struct {
        namespace: []u8,
        namespace_len: usize = 0,
        key: []u8,
        key_len: usize = 0,
        values: [2][]u8,
        lengths: [2]?usize = .{ null, null },
        committed: u1 = 0,
        dirty: bool = false,

        fn selected(self: *const Record) u1 {
            return self.committed ^ @intFromBool(self.dirty);
        }
    };

    allocator: std.mem.Allocator,
    records: []Record,
    bytes: []u8,
    options: Options,
    tick: u64 = 0,
    pending_tick: u64 = 0,
    failed: bool = false,
    lease: u64 = 0,
    active: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: Options) storage.Error!Store {
        if (options.max_records == 0 or options.max_namespace_bytes == 0 or
            options.max_key_bytes == 0 or options.max_value_bytes == 0) return error.InvalidArgument;

        const value_bytes = std.math.mul(usize, options.max_value_bytes, 2) catch return error.InvalidArgument;
        const key_bytes = std.math.add(usize, options.max_namespace_bytes, options.max_key_bytes) catch return error.InvalidArgument;
        const stride = std.math.add(usize, key_bytes, value_bytes) catch return error.InvalidArgument;
        const capacity = std.math.mul(usize, options.max_records, stride) catch return error.InvalidArgument;
        const records = allocator.alloc(Record, options.max_records) catch return error.NoSpace;
        errdefer allocator.free(records);
        const bytes = allocator.alloc(u8, capacity) catch return error.NoSpace;

        for (records, 0..) |*record, index| {
            const row = bytes[index * stride ..][0..stride];
            record.* = .{
                .namespace = row[0..options.max_namespace_bytes],
                .key = row[options.max_namespace_bytes..key_bytes],
                .values = .{ row[key_bytes..][0..options.max_value_bytes], row[key_bytes + options.max_value_bytes ..] },
            };
        }

        return .{ .allocator = allocator, .records = records, .bytes = bytes, .options = options };
    }

    pub fn deinit(self: *Store) void {
        assert(!self.active);
        self.allocator.free(self.bytes);
        self.allocator.free(self.records);
        self.* = undefined;
    }

    pub fn interface(self: *Store) storage.Storage {
        return .{ .context = self, .vtable = &.{ .begin = begin, .last_tick = lastTick, .durable_tick = lastTick, .flush = flush } };
    }

    fn flush(_: *anyopaque, _: std.Io) storage.Error!void {}

    fn lastTick(context: *const anyopaque) u64 {
        const self: *const Store = @ptrCast(@alignCast(context));
        return self.tick;
    }

    fn begin(context: *anyopaque, _: std.Io, tick: u64) storage.Error!storage.Transaction {
        const self: *Store = @ptrCast(@alignCast(context));
        if (self.active) return error.Busy;
        if (tick <= self.tick or self.lease == std.math.maxInt(u64)) return error.InvalidArgument;
        self.pending_tick = tick;
        self.failed = false;
        self.lease += 1;
        self.active = true;
        return .{ .context = self, .lease = self.lease, .vtable = &.{ .namespace = namespace, .submit = submit, .abort = abort } };
    }

    fn namespace(context: *anyopaque, lease: u64, bytes: []const u8) storage.Error!storage.Namespace {
        const self: *Store = @ptrCast(@alignCast(context));
        if (!self.active or self.lease != lease) return error.Closed;
        if (bytes.len > self.options.max_namespace_bytes) return error.BufferTooSmall;
        return .{
            .context = self,
            .bytes = bytes,
            .vtable = &.{ .fail = fail, .get = get, .get_batch = getBatch, .put_batch = putBatch, .scan = scan },
        };
    }

    fn fail(context: *anyopaque) void {
        const self: *Store = @ptrCast(@alignCast(context));
        assert(self.active);
        self.failed = true;
    }

    fn get(context: *anyopaque, ns: []const u8, key: []const u8, destination: []u8) storage.Error!?usize {
        const self: *Store = @ptrCast(@alignCast(context));
        if (!self.active) return error.Closed;

        const record = self.find(ns, key) orelse return null;
        const selected = record.selected();
        const length = record.lengths[selected] orelse return null;
        if (length > destination.len) return error.BufferTooSmall;
        @memcpy(destination[0..length], record.values[selected][0..length]);
        return length;
    }

    fn getBatch(context: *anyopaque, ns: []const u8, requests: []const storage.Get, lengths: []?usize) storage.Error!void {
        if (requests.len != lengths.len) return error.InvalidArgument;

        for (requests, lengths) |request, *length| length.* = try get(context, ns, request.key, request.destination);
    }

    fn putBatch(context: *anyopaque, ns: []const u8, writes: []const storage.Write) storage.Error!void {
        const self: *Store = @ptrCast(@alignCast(context));
        if (!self.active) return error.Closed;
        if (ns.len > self.options.max_namespace_bytes) return error.BufferTooSmall;

        var additions: usize = 0;

        for (writes, 0..) |write, index| {
            if (write.key.len == 0) return error.InvalidArgument;
            if (write.key.len > self.options.max_key_bytes) return error.BufferTooSmall;
            if (write.value) |value| {
                if (value.len > self.options.max_value_bytes) return error.BufferTooSmall;

                if (self.find(ns, write.key) == null) {
                    var seen = false;

                    for (writes[0..index]) |prior| {
                        seen = seen or (prior.value != null and std.mem.eql(u8, prior.key, write.key));
                    }

                    additions += @intFromBool(!seen);
                }
            }
        }

        var free: usize = 0;

        for (self.records) |record| free += @intFromBool(record.key_len == 0);
        if (additions > free) return error.NoSpace;

        for (writes) |write| {
            var found = self.find(ns, write.key);
            if (found == null) {
                if (write.value == null) continue;

                for (self.records) |*candidate| {
                    if (candidate.key_len != 0) continue;
                    assert(candidate.lengths[candidate.committed] == null and !candidate.dirty);
                    @memcpy(candidate.namespace[0..ns.len], ns);
                    @memcpy(candidate.key[0..write.key.len], write.key);
                    candidate.namespace_len = ns.len;
                    candidate.key_len = write.key.len;
                    found = candidate;
                    break;
                }
            }

            const record = found.?;
            const target = record.committed ^ 1;
            record.lengths[target] = null;

            if (write.value) |value| {
                @memcpy(record.values[target][0..value.len], value);
                record.lengths[target] = value.len;
            }

            record.dirty = true;
        }
    }

    fn scan(context: *anyopaque, ns: []const u8, cursor: *storage.ScanCursor, entries: []storage.ScanEntry) storage.Error!storage.ScanResult {
        const self: *Store = @ptrCast(@alignCast(context));
        if (!self.active) return error.Closed;
        if (cursor.after_len > cursor.after.len) return error.InvalidArgument;

        var count: usize = 0;

        while (true) {
            var best: ?*Record = null;

            for (self.records) |*record| {
                if (record.key_len == 0 or record.lengths[record.selected()] == null or
                    !std.mem.eql(u8, record.namespace[0..record.namespace_len], ns) or
                    std.mem.order(u8, record.key[0..record.key_len], cursor.after[0..cursor.after_len]) != .gt) continue;

                if (best == null or std.mem.order(u8, record.key[0..record.key_len], best.?.key[0..best.?.key_len]) == .lt) best = record;
            }

            const record = best orelse return .{ .count = count, .more = false };
            if (count == entries.len) return .{ .count = count, .more = true };

            const selected = record.selected();
            const length = record.lengths[selected].?;
            const entry = &entries[count];
            if (record.key_len > entry.key.len or record.key_len > cursor.after.len or length > entry.value.len) return error.BufferTooSmall;
            @memcpy(entry.key[0..record.key_len], record.key[0..record.key_len]);
            @memcpy(entry.value[0..length], record.values[selected][0..length]);
            @memcpy(cursor.after[0..record.key_len], record.key[0..record.key_len]);
            entry.key_len = record.key_len;
            entry.value_len = length;
            cursor.after_len = record.key_len;
            count += 1;
        }
    }

    fn submit(context: *anyopaque, lease: u64) storage.Error!void {
        const self: *Store = @ptrCast(@alignCast(context));
        if (!self.active or self.lease != lease) return error.Closed;
        if (self.failed) return error.FailedTransaction;

        for (self.records) |*record| {
            record.committed = record.selected();
            record.dirty = false;

            if (record.lengths[record.committed] == null) record.key_len = 0;
        }

        self.tick = self.pending_tick;
        self.active = false;
    }

    fn abort(context: *anyopaque, lease: u64) void {
        const self: *Store = @ptrCast(@alignCast(context));
        if (!self.active or self.lease != lease) return;

        for (self.records) |*record| {
            record.dirty = false;

            if (record.lengths[record.committed] == null) record.key_len = 0;
        }

        self.active = false;
    }

    fn find(self: *Store, ns: []const u8, key: []const u8) ?*Record {
        for (self.records) |*record| {
            if (record.key_len != 0 and std.mem.eql(u8, record.namespace[0..record.namespace_len], ns) and
                std.mem.eql(u8, record.key[0..record.key_len], key)) return record;
        }

        return null;
    }
};
