const value = @import("value.zig");
pub const Value = value.Value;
const table = @import("table.zig");
pub const Table = table.Table;
pub const Get = table.Get;
pub const Write = table.Write;
pub const ScanEntry = table.ScanEntry;
pub const ScanCursor = table.ScanCursor;
pub const ScanResult = table.ScanResult;
const std = @import("std");
const metrics = @import("metrics");
const storage = @import("storage");

const assert = std.debug.assert;

pub const Instrumentation = struct {
    acquisition: metrics.Timer = .{},
    lookup: metrics.Timer = .{},
    eviction: metrics.Timer = .{},
    storage: metrics.Timer = .{},
    eviction_write: metrics.Timer = .{},
    hits: metrics.Counter = .{},
    misses: metrics.Counter = .{},
    reads: metrics.Counter = .{},
    writes: metrics.Counter = .{},
    evictions: metrics.Counter = .{},
    acquired: metrics.Counter = .{},
    written_bytes: metrics.Counter = .{},

    pub fn init(registry: ?*metrics.Registry, namespace: []const u8) !Instrumentation {
        const owner = registry orelse return .{};
        return .{
            .acquisition = try owner.timer(.{ .namespace = namespace, .name = "acquisition", .description = "Acquire a cache working set" }),
            .lookup = try owner.timer(.{ .namespace = namespace, .name = "lookup", .description = "Locate cached records" }),
            .eviction = try owner.timer(.{ .namespace = namespace, .name = "eviction", .description = "Select and reclaim cache slots" }),
            .storage = try owner.timer(.{ .namespace = namespace, .name = "storage", .description = "Read missing records" }),
            .eviction_write = try owner.timer(.{ .namespace = namespace, .name = "eviction_write", .description = "Write dirty eviction victims" }),
            .hits = try owner.counter(.{ .namespace = namespace, .name = "hits", .description = "Cached records found" }),
            .misses = try owner.counter(.{ .namespace = namespace, .name = "misses", .description = "Records missing from cache" }),
            .reads = try owner.counter(.{ .namespace = namespace, .name = "reads", .description = "Records read from storage" }),
            .writes = try owner.counter(.{ .namespace = namespace, .name = "writes", .description = "Records written to storage" }),
            .evictions = try owner.counter(.{ .namespace = namespace, .name = "evictions", .description = "Occupied cache slots reclaimed" }),
            .acquired = try owner.counter(.{ .namespace = namespace, .name = "acquired", .description = "Records requested" }),
            .written_bytes = try owner.counter(.{ .namespace = namespace, .name = "written_bytes", .description = "Evicted value bytes", .unit = .bytes }),
        };
    }
};

pub const Configuration = struct {
    slots: usize,
    key_bytes: usize = 32,
    value_bytes: usize,
    metrics: ?*metrics.Registry = null,
    metrics_namespace: []const u8 = "cache",
    scan_batch: usize = 0,
    codec: ?Codec = null,
};

pub const Codec = struct {
    /// Borrow input or return a prefix of output. Encoding must fit within value_bytes.
    encode: *const fn (input: []const u8, output: []u8) storage.Error![]const u8,
    decode: *const fn (buffer: []u8, length: usize) storage.Error!usize,
};

pub const Cache = CacheFor(Table);

pub fn CacheFor(comptime Backend: type) type {
    return struct {
        const Self = @This();
        backend: Backend,
        failed: bool = false,
        entries: []Entry,
        keys: []u8,
        values: []u8,
        key_bytes: usize,
        value_bytes: usize,
        clock: u64 = 0,
        order: []usize,
        index: []usize,
        index_count: usize = 0,
        metrics: Instrumentation,
        scan_entries: []ScanEntry,
        scan_bytes: []u8,
        codec: ?Codec,
        encoded: []u8,

        const Entry = struct {
            generation: u64 = 0,
            revision: u64 = 0,
            touched: u64 = 0,
            key_len: usize = 0,
            value_len: usize = 0,
            pins: usize = 0,
            occupied: bool = false,
            present: bool = false,
            dirty: bool = false,
            indexed: bool = false,
            editing: bool = false,
        };

        pub fn init(allocator: std.mem.Allocator, io: std.Io, backend: Backend, configuration: Configuration) !Self {
            _ = io;
            if (configuration.slots == 0 or configuration.key_bytes == 0 or configuration.value_bytes == 0)
                return error.InvalidArgument;

            const instrumentation = try Instrumentation.init(configuration.metrics, configuration.metrics_namespace);
            const entries = try allocator.alignedAlloc(Entry, .@"64", configuration.slots);
            errdefer allocator.free(entries);
            @memset(entries, .{});
            const keys = try allocator.alloc(u8, try std.math.mul(usize, configuration.slots, configuration.key_bytes));
            errdefer allocator.free(keys);
            const values = try allocator.alloc(u8, try std.math.mul(usize, configuration.slots, configuration.value_bytes));
            errdefer allocator.free(values);
            const order = try allocator.alignedAlloc(usize, .@"64", configuration.slots);
            errdefer allocator.free(order);
            const index = try allocator.alignedAlloc(usize, .@"64", configuration.slots);
            errdefer allocator.free(index);
            const scan_entries = try allocator.alloc(ScanEntry, configuration.scan_batch);
            errdefer allocator.free(scan_entries);
            const stride = try std.math.add(usize, configuration.key_bytes, configuration.value_bytes);
            const scan_capacity = try std.math.add(usize, try std.math.mul(usize, configuration.scan_batch, stride), if (configuration.scan_batch == 0) 0 else configuration.key_bytes);
            const scan_bytes = try allocator.alloc(u8, scan_capacity);
            errdefer allocator.free(scan_bytes);
            const encoded = try allocator.alloc(u8, if (configuration.codec == null) 0 else @max(64 * 1024, configuration.value_bytes));

            for (scan_entries, 0..) |*entry, i|
                entry.* = .{
                    .key = scan_bytes[i * stride ..][0..configuration.key_bytes],
                    .value = scan_bytes[i * stride + configuration.key_bytes ..][0..configuration.value_bytes],
                };

            return .{
                .backend = backend,
                .scan_entries = scan_entries,
                .scan_bytes = scan_bytes,
                .codec = configuration.codec,
                .encoded = encoded,
                .order = order,
                .index = index,
                .metrics = instrumentation,
                .entries = entries,
                .keys = keys,
                .values = values,
                .key_bytes = configuration.key_bytes,
                .value_bytes = configuration.value_bytes,
            };
        }

        /// A miss may synchronously read storage. Acquire known working sets in batches. Release each
        /// lease before requesting an unbounded dependency.
        pub fn acquire(self: *Self, key: []const u8) !Lease {
            var leases: [1]Lease = undefined;
            try self.acquireMany(&.{key}, &leases);
            return leases[0];
        }

        pub fn acquireMany(self: *Self, keys: []const []const u8, leases: []Lease) !void {
            assert(keys.len == leases.len);
            if (self.failed) return error.FailedTransaction;
            if (keys.len > self.entries.len) return error.WorkingSetTooLarge;

            const acquisition = self.metrics.acquisition.start();
            defer acquisition.end();
            self.metrics.acquired.add(keys.len);
            var acquired: usize = 0;
            errdefer for (leases[0..acquired]) |lease| lease.release();
            var base: usize = 0;

            while (base < keys.len) {
                const count = @min(192, keys.len - base);
                const batch = keys[base..][0..count];
                var sorted: [192]u16 = undefined;
                var hits: [192]?usize = @splat(null);
                var requests: [192]Get = undefined;
                var lengths: [192]?usize = undefined;
                var missing: [192]usize = undefined;
                var missing_count: usize = 0;
                errdefer {
                    for (missing[0..missing_count]) |slot| {
                        self.entries[slot].occupied = false;
                        self.entries[slot].indexed = false;
                    }

                    var kept: usize = 0;

                    for (self.index[0..self.index_count]) |slot| {
                        if (!self.entries[slot].indexed) continue;
                        self.index[kept] = slot;
                        kept += 1;
                    }

                    self.index_count = kept;
                }
                {
                    const lookup = self.metrics.lookup.start();
                    defer lookup.end();

                    for (batch, sorted[0..count], 0..) |key, *slot, i| {
                        if (key.len == 0 or key.len > self.key_bytes) return error.InvalidArgument;
                        slot.* = @intCast(i);
                    }

                    std.mem.sort(u16, sorted[0..count], batch, struct {
                        fn less(items: []const []const u8, a: u16, b: u16) bool {
                            return std.mem.order(u8, items[a], items[b]) == .lt;
                        }
                    }.less);
                    for (sorted[0..count]) |request| {
                        const at = self.lowerBound(batch[request]);
                        if (at < self.index_count) {
                            const slot = self.index[at];
                            if (std.mem.eql(u8, self.keyBytes(slot)[0..self.entries[slot].key_len], batch[request])) hits[request] = slot;
                        }
                    }
                }

                // Protect every hit before choosing any eviction victim.
                for (hits[0..count]) |hit| if (hit) |slot| {
                    self.entries[slot].pins += 1;
                };

                var hits_owned = true;
                errdefer if (hits_owned) {
                    for (hits[0..count]) |hit| if (hit) |slot| {
                        self.entries[slot].pins -= 1;
                    };
                };
                var available: usize = 0;
                const all_hits = for (hits[0..count]) |hit| {
                    if (hit == null) break false;
                } else true;
                if (!all_hits) {
                    const eviction = self.metrics.eviction.start();
                    defer eviction.end();

                    for (self.entries, 0..) |entry, slot| {
                        if (entry.pins != 0) continue;
                        self.order[available] = slot;
                        available += 1;
                    }

                    std.mem.sort(usize, self.order[0..available], self, struct {
                        fn less(cache: *Self, a: usize, b: usize) bool {
                            const x = cache.entries[a];
                            const y = cache.entries[b];
                            return if (x.occupied != y.occupied) !x.occupied else if (x.touched != y.touched) x.touched < y.touched else a < b;
                        }
                    }.less);
                    var victims: usize = 0;
                    var prior_key: ?[]const u8 = null;
                    for (sorted[0..count]) |request| {
                        if (hits[request] != null) continue;
                        if (prior_key) |key| if (std.mem.eql(u8, key, batch[request])) continue;
                        victims += 1;
                        prior_key = batch[request];
                    }
                    if (victims > available) return error.CachePinned;

                    var writes: [192]Write = undefined;
                    var write_count: usize = 0;
                    for (self.order[0..victims]) |slot| {
                        const entry = &self.entries[slot];
                        if (!entry.dirty) continue;
                        writes[write_count] = .{
                            .key = self.keyBytes(slot)[0..entry.key_len],
                            .value = if (entry.present) self.value(slot)[0..entry.value_len] else null,
                        };
                        write_count += 1;
                    }
                    if (write_count != 0) {
                        const writeback = self.metrics.eviction_write.start();
                        defer writeback.end();

                        for (writes[0..write_count]) |write| self.metrics.written_bytes.add(if (write.value) |contents| contents.len else 0);
                        self.putBatch(writes[0..write_count]) catch |err| {
                            self.failed = true;
                            self.backend.fail();
                            return err;
                        };
                        self.metrics.writes.add(write_count);
                    }

                    var victim: usize = 0;
                    var previous: ?u16 = null;

                    for (sorted[0..count]) |request| {
                        if (hits[request] != null) continue;
                        if (previous) |prior| {
                            if (std.mem.eql(u8, batch[prior], batch[request])) {
                                hits[request] = hits[prior];
                                self.entries[hits[request].?].pins += 1;
                                continue;
                            }
                        }

                        if (victim == available) return error.CachePinned;

                        const slot = self.order[victim];
                        victim += 1;
                        const entry = &self.entries[slot];

                        self.metrics.evictions.add(@intFromBool(entry.occupied));
                        self.metrics.misses.add(1);
                        entry.* = .{ .generation = entry.generation + 1, .key_len = batch[request].len, .occupied = true, .pins = 1 };
                        @memcpy(self.keyBytes(slot)[0..entry.key_len], batch[request]);
                        hits[request] = slot;
                        missing[missing_count] = slot;
                        requests[missing_count] = .{ .key = self.keyBytes(slot)[0..entry.key_len], .destination = self.value(slot) };
                        missing_count += 1;
                        previous = request;
                    }
                }
                self.metrics.hits.add(count - missing_count);

                if (missing_count != 0) {
                    var old: usize = 0;
                    var added: usize = 0;
                    var merged: usize = 0;

                    while (old < self.index_count or added < missing_count) {
                        if (old < self.index_count and !self.entries[self.index[old]].indexed) {
                            old += 1;
                            continue;
                        }

                        const take_old = added == missing_count or (old < self.index_count and std.mem.order(u8, self.keyBytes(self.index[old])[0..self.entries[self.index[old]].key_len], requests[added].key) == .lt);
                        self.order[merged] = if (take_old) self.index[old] else missing[added];

                        if (take_old) old += 1 else added += 1;
                        merged += 1;
                    }

                    assert(merged <= self.entries.len);
                    std.mem.swap([]usize, &self.index, &self.order);
                    self.index_count = merged;

                    for (missing[0..missing_count]) |slot| self.entries[slot].indexed = true;
                }

                for (hits[0..count], leases[base..][0..count]) |hit, *lease| {
                    const slot = hit.?;
                    self.clock += 1;
                    self.entries[slot].touched = self.clock;
                    lease.* = .{ .cache = self, .index = slot, .generation = self.entries[slot].generation };
                    acquired += 1;
                }

                hits_owned = false;
                if (missing_count != 0) {
                    const reading = self.metrics.storage.start();
                    defer reading.end();
                    self.backend.getBatch(requests[0..missing_count], lengths[0..missing_count]) catch |err| {
                        self.failed = true;
                        if (err != error.FailedTransaction) self.backend.fail();
                        return err;
                    };

                    for (missing[0..missing_count], lengths[0..missing_count]) |slot, length| {
                        self.entries[slot].present = length != null;
                        self.entries[slot].value_len = if (length) |size| try self.decode(self.value(slot), size) else 0;
                    }

                    self.metrics.reads.add(missing_count);
                }

                base += count;
            }
        }

        pub const Iterator = struct {
            cache: *Self,
            keys: []const []const u8,
            leases: []Lease,
            live: usize = 0,
            next_key: usize = 0,

            /// The previous batch expires here. Early exit must call deinit.
            pub fn next(self: *Iterator) !?[]Lease {
                self.deinit();
                if (self.next_key == self.keys.len) return null;

                const count = @min(self.leases.len, self.cache.entries.len, self.keys.len - self.next_key);
                assert(count > 0);
                try self.cache.acquireMany(self.keys[self.next_key..][0..count], self.leases[0..count]);
                self.live = count;
                self.next_key += count;
                assert(self.next_key <= self.keys.len);
                return self.leases[0..count];
            }

            pub fn deinit(self: *Iterator) void {
                for (self.leases[0..self.live]) |lease| lease.release();
                self.live = 0;
            }
        };

        pub fn iterate(self: *Self, keys: []const []const u8, leases: []Lease) Iterator {
            assert(leases.len > 0);
            return .{ .cache = self, .keys = keys, .leases = leases };
        }

        /// Merge stored records and dirty cache entries in order. No writeback occurs.
        pub fn scan(self: *Self, cursor: *ScanCursor, output: []ScanEntry) !ScanResult {
            if (self.failed) return error.FailedTransaction;
            if (output.len == 0 or output.len > self.scan_entries.len) return error.WorkingSetTooLarge;
            if (cursor.after.len < self.key_bytes) return error.BufferTooSmall;
            assert(cursor.after_len <= self.key_bytes);

            for (output) |row| {
                if (row.key.len < self.key_bytes or row.value.len < self.value_bytes) return error.BufferTooSmall;
            }

            const after = self.scan_bytes[self.scan_bytes.len - self.key_bytes ..];
            @memcpy(after[0..cursor.after_len], cursor.after[0..cursor.after_len]);
            var disk_cursor: ScanCursor = .{ .after = after, .after_len = cursor.after_len };
            const disk = try self.backend.scan(&disk_cursor, self.scan_entries[0..output.len]);
            assert(disk.count <= output.len);
            for (self.scan_entries[0..disk.count]) |*row| row.value_len = try self.decode(row.value, row.value_len);
            var cached = self.lowerBound(cursor.after[0..cursor.after_len]);
            if (cached < self.index_count) {
                const slot = self.index[cached];
                if (std.mem.eql(u8, self.keyBytes(slot)[0..self.entries[slot].key_len], cursor.after[0..cursor.after_len])) cached += 1;
            }

            var stored: usize = 0;
            var count: usize = 0;

            while (count < output.len and (stored < disk.count or (!disk.more and cached < self.index_count))) {
                const row = if (stored < disk.count) self.scan_entries[stored] else null;
                const slot = if (cached < self.index_count) self.index[cached] else null;
                const cache_key = if (slot) |id| self.keyBytes(id)[0..self.entries[id].key_len] else null;
                const order = if (row) |r| if (cache_key) |key| std.mem.order(u8, key, r.key[0..r.key_len]) else .gt else .lt;
                const key = if (order != .gt) cache_key.? else row.?.key[0..row.?.key_len];
                var contents: ?[]const u8 = null;

                if (order != .gt) {
                    const entry = &self.entries[slot.?];
                    assert(!entry.editing);

                    if (entry.present) contents = self.value(slot.?)[0..entry.value_len];
                } else contents = row.?.value[0..row.?.value_len];
                if (contents) |bytes| {
                    if (key.len > output[count].key.len or bytes.len > output[count].value.len) return error.BufferTooSmall;
                    @memcpy(output[count].key[0..key.len], key);
                    @memcpy(output[count].value[0..bytes.len], bytes);
                    output[count].key_len = key.len;
                    output[count].value_len = bytes.len;
                    count += 1;
                }

                @memcpy(cursor.after[0..key.len], key);
                cursor.after_len = key.len;

                if (order != .gt) cached += 1;

                if (order != .lt) stored += 1;
            }

            assert(count <= output.len);
            return .{ .count = count, .more = stored < disk.count or disk.more or cached < self.index_count };
        }

        pub fn flush(self: *Self) !void {
            if (self.failed) return error.FailedTransaction;
            errdefer {
                self.failed = true;
                self.backend.fail();
            }
            var writes: [32]Write = undefined;
            var dirty: [32]usize = undefined;
            var count: usize = 0;

            for (self.index[0..self.index_count], 0..) |index, at| {
                const entry = self.entries[index];
                assert(entry.pins == 0);

                if (entry.dirty) {
                    writes[count] = .{
                        .key = self.keyBytes(index)[0..entry.key_len],
                        .value = if (entry.present) self.value(index)[0..entry.value_len] else null,
                    };
                    dirty[count] = index;
                    count += 1;
                }

                if (count == writes.len or at + 1 == self.index_count) {
                    if (count != 0) try self.putBatch(writes[0..count]);

                    for (dirty[0..count]) |written| self.entries[written].dirty = false;
                    self.metrics.writes.add(count);
                    count = 0;
                }
            }
            if (comptime @hasDecl(Backend, "flush")) try self.backend.flush();
        }

        fn decode(self: *Self, buffer: []u8, length: usize) !usize {
            const codec = self.codec orelse return length;
            const decoded = codec.decode(buffer, length) catch |err| {
                self.failed = true;
                self.backend.fail();
                return err;
            };
            if (decoded > buffer.len) {
                self.failed = true;
                self.backend.fail();
                return error.Corrupt;
            }
            return decoded;
        }

        fn putBatch(self: *Self, writes: []const Write) !void {
            const codec = self.codec orelse return self.backend.putBatch(writes);
            var batch: [192]Write = undefined;
            var count: usize = 0;
            var used: usize = 0;
            for (writes) |write| {
                if (count == batch.len or self.encoded.len - used < self.value_bytes) {
                    assert(count > 0);
                    try self.backend.putBatch(batch[0..count]);
                    count = 0;
                    used = 0;
                }
                batch[count] = write;
                if (write.value) |contents| {
                    const encoded = try codec.encode(contents, self.encoded[used..]);
                    assert(encoded.ptr == contents.ptr or encoded.ptr == self.encoded[used..].ptr);
                    if (encoded.len > self.value_bytes) return error.BufferTooSmall;
                    batch[count].value = encoded;
                    if (encoded.ptr == self.encoded[used..].ptr) used += encoded.len;
                }
                count += 1;
            }
            if (count != 0) try self.backend.putBatch(batch[0..count]);
        }

        fn lowerBound(self: *Self, key: []const u8) usize {
            var low: usize = 0;
            var high = self.index_count;
            while (low < high) {
                const middle = low + (high - low) / 2;
                const slot = self.index[middle];
                if (std.mem.order(u8, self.keyBytes(slot)[0..self.entries[slot].key_len], key) == .lt) low = middle + 1 else high = middle;
            }
            return low;
        }

        fn keyBytes(self: *Self, index: usize) []u8 {
            return self.keys[index * self.key_bytes ..][0..self.key_bytes];
        }

        fn value(self: *Self, index: usize) []u8 {
            return self.values[index * self.value_bytes ..][0..self.value_bytes];
        }

        pub const Lease = struct {
            cache: *Self,
            index: usize,
            generation: u64,

            pub fn revision(self: Lease) u64 {
                const entry = &self.cache.entries[self.index];
                assert(entry.pins > 0 and entry.generation == self.generation);
                assert(!entry.editing);
                return entry.revision;
            }

            pub fn read(self: Lease) ?[]const u8 {
                const entry = &self.cache.entries[self.index];
                assert(entry.pins > 0 and entry.generation == self.generation);
                assert(!entry.editing);
                return if (entry.present) self.cache.value(self.index)[0..entry.value_len] else null;
            }

            /// Release without commit poisons the cache: a partial edit cannot be checkpointed.
            pub fn edit(self: Lease) []u8 {
                const entry = &self.cache.entries[self.index];
                assert(entry.pins > 0);
                assert(entry.generation == self.generation);
                assert(!entry.editing);
                assert(!self.cache.failed);
                entry.editing = true;
                return self.cache.value(self.index);
            }

            pub fn commit(self: Lease, length: usize) void {
                const entry = &self.cache.entries[self.index];
                assert(entry.generation == self.generation);
                assert(entry.pins > 0);
                assert(entry.editing);
                assert(length <= self.cache.value_bytes);
                entry.revision += 1;
                entry.value_len = length;
                entry.present = true;
                entry.dirty = true;
                entry.editing = false;
                assert(entry.present and entry.dirty);
            }

            pub fn remove(self: Lease) void {
                const entry = &self.cache.entries[self.index];
                assert(entry.pins > 0 and entry.generation == self.generation);
                assert(!entry.editing);
                entry.revision += 1;
                entry.present = false;
                entry.dirty = true;
                entry.value_len = 0;
            }

            pub fn release(self: Lease) void {
                const entry = &self.cache.entries[self.index];
                assert(entry.pins > 0 and entry.generation == self.generation);

                if (entry.editing) {
                    self.cache.failed = true;
                    self.cache.backend.fail();
                    entry.editing = false;
                }

                entry.pins -= 1;
            }
        };
    };
}
