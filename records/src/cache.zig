const std = @import("std");
const metrics = @import("metrics");
const storage = @import("storage");

const assert = std.debug.assert;

const Trace = metrics.Metrics(enum { acquisition, lookup, eviction, storage });

pub const Configuration = struct {
    slots: usize,
    key_bytes: usize = 32,
    value_bytes: usize,
    metrics: metrics.Options = .{},
    scan_batch: usize = 0,
};

pub const Statistics = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    reads: u64 = 0,
    writes: u64 = 0,
    evictions: u64 = 0,
};

pub const Cache = struct {
    namespace: storage.Namespace,
    failed: bool = false,
    entries: []Entry,
    keys: []u8,
    values: []u8,
    key_bytes: usize,
    value_bytes: usize,
    clock: u64 = 0,
    statistics: Statistics = .{},
    order: []usize,
    index: []usize,
    index_count: usize = 0,
    metrics: Trace,
    scan_entries: []storage.ScanEntry,
    scan_bytes: []u8,

    const Entry = struct {
        generation: u64 = 0,
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

    pub fn init(allocator: std.mem.Allocator, io: std.Io, namespace: storage.Namespace, configuration: Configuration) !Cache {
        if (configuration.slots == 0 or configuration.key_bytes == 0 or configuration.value_bytes == 0)
            return error.InvalidArgument;

        const entries = try allocator.alignedAlloc(Entry, .@"64", configuration.slots);
        errdefer allocator.free(entries);
        const keys = try allocator.alloc(u8, try std.math.mul(usize, configuration.slots, configuration.key_bytes));
        errdefer allocator.free(keys);
        const values = try allocator.alloc(u8, try std.math.mul(usize, configuration.slots, configuration.value_bytes));
        errdefer allocator.free(values);
        const order = try allocator.alignedAlloc(usize, .@"64", configuration.slots);
        errdefer allocator.free(order);
        const index = try allocator.alignedAlloc(usize, .@"64", configuration.slots);
        errdefer allocator.free(index);
        const scan_entries = try allocator.alloc(storage.ScanEntry, configuration.scan_batch);
        errdefer allocator.free(scan_entries);
        const stride = try std.math.add(usize, configuration.key_bytes, configuration.value_bytes);
        const scan_bytes = try allocator.alloc(u8, try std.math.add(usize, try std.math.mul(usize, configuration.scan_batch, stride), if (configuration.scan_batch == 0) 0 else configuration.key_bytes));

        for (scan_entries, 0..) |*entry, i|
            entry.* = .{
                .key = scan_bytes[i * stride ..][0..configuration.key_bytes],
                .value = scan_bytes[i * stride + configuration.key_bytes ..][0..configuration.value_bytes],
            };

        @memset(entries, .{});
        return .{
            .namespace = namespace,
            .scan_entries = scan_entries,
            .scan_bytes = scan_bytes,
            .order = order,
            .index = index,
            .metrics = Trace.init(io, configuration.metrics),
            .entries = entries,
            .keys = keys,
            .values = values,
            .key_bytes = configuration.key_bytes,
            .value_bytes = configuration.value_bytes,
        };
    }

    /// A miss may synchronously read storage. Acquire known working sets in batches. Release each
    /// lease before requesting an unbounded dependency.
    pub fn acquire(self: *Cache, key: []const u8) !Lease {
        var leases: [1]Lease = undefined;
        try self.acquireMany(&.{key}, &leases);
        return leases[0];
    }

    pub fn acquireMany(self: *Cache, keys: []const []const u8, leases: []Lease) !void {
        assert(keys.len == leases.len);
        if (self.failed) return error.FailedTransaction;
        if (keys.len > self.entries.len) return error.WorkingSetTooLarge;

        var acquisition = self.metrics.begin(.acquisition);
        defer acquisition.end();
        acquisition.add(.records, keys.len);
        var acquired: usize = 0;
        errdefer for (leases[0..acquired]) |lease| lease.release();
        var base: usize = 0;

        while (base < keys.len) {
            const count = @min(192, keys.len - base);
            const batch = keys[base..][0..count];
            var sorted: [192]u16 = undefined;
            var hits: [192]?usize = @splat(null);
            var requests: [192]storage.Get = undefined;
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
                const lookup = acquisition.begin(.lookup);
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
                var at: usize = 0;

                for (sorted[0..count]) |request| {
                    while (at < self.index_count) {
                        const slot = self.index[at];
                        const order = std.mem.order(u8, self.keyBytes(slot)[0..self.entries[slot].key_len], batch[request]);
                        if (order == .lt) {
                            at += 1;
                            continue;
                        }

                        if (order == .eq) hits[request] = slot;
                        break;
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
            {
                const eviction = acquisition.begin(.eviction);
                defer eviction.end();

                for (self.entries, 0..) |entry, slot| {
                    if (entry.pins != 0) continue;
                    self.order[available] = slot;
                    available += 1;
                }

                std.mem.sort(usize, self.order[0..available], self, struct {
                    fn less(cache: *Cache, a: usize, b: usize) bool {
                        const x = cache.entries[a];
                        const y = cache.entries[b];
                        return if (x.occupied != y.occupied) !x.occupied else if (x.touched != y.touched) x.touched < y.touched else a < b;
                    }
                }.less);
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

                    if (entry.dirty) {
                        try self.namespace.put(self.keyBytes(slot)[0..entry.key_len], if (entry.present) self.value(slot)[0..entry.value_len] else null);
                        self.statistics.writes += 1;
                    }

                    self.statistics.evictions += @intFromBool(entry.occupied);
                    self.statistics.misses += 1;
                    entry.* = .{ .generation = entry.generation + 1, .key_len = batch[request].len, .occupied = true, .pins = 1 };
                    @memcpy(self.keyBytes(slot)[0..entry.key_len], batch[request]);
                    hits[request] = slot;
                    missing[missing_count] = slot;
                    requests[missing_count] = .{ .key = self.keyBytes(slot)[0..entry.key_len], .destination = self.value(slot) };
                    missing_count += 1;
                    previous = request;
                }
            }
            self.statistics.hits += count - missing_count;
            acquisition.add(.misses, missing_count);
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
                const reading = acquisition.begin(.storage);
                defer reading.end();
                self.namespace.getBatch(requests[0..missing_count], lengths[0..missing_count]) catch |err| {
                    if (err == error.Corrupt or err == error.IoFailure) {
                        self.failed = true;
                        self.namespace.fail();
                    }

                    return err;
                };

                for (missing[0..missing_count], lengths[0..missing_count]) |slot, length| {
                    self.entries[slot].present = length != null;
                    self.entries[slot].value_len = length orelse 0;
                }

                self.statistics.reads += missing_count;
            }

            base += count;
        }
    }

    pub const Iterator = struct {
        cache: *Cache,
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

    pub fn iterate(self: *Cache, keys: []const []const u8, leases: []Lease) Iterator {
        assert(leases.len > 0);
        return .{ .cache = self, .keys = keys, .leases = leases };
    }

    /// Merge stored records and dirty cache entries in order. No writeback occurs.
    pub fn scan(self: *Cache, cursor: *storage.ScanCursor, output: []storage.ScanEntry) !storage.ScanResult {
        if (self.failed) return error.FailedTransaction;
        if (output.len == 0 or output.len > self.scan_entries.len) return error.WorkingSetTooLarge;
        if (cursor.after.len < self.key_bytes) return error.BufferTooSmall;
        assert(cursor.after_len <= self.key_bytes);

        for (output) |row| {
            if (row.key.len < self.key_bytes or row.value.len < self.value_bytes) return error.BufferTooSmall;
        }

        const after = self.scan_bytes[self.scan_bytes.len - self.key_bytes ..];
        @memcpy(after[0..cursor.after_len], cursor.after[0..cursor.after_len]);
        var disk_cursor: storage.ScanCursor = .{ .after = after, .after_len = cursor.after_len };
        const disk = try self.namespace.scan(&disk_cursor, self.scan_entries[0..output.len]);
        assert(disk.count <= output.len);
        var cached: usize = 0;

        while (cached < self.index_count) : (cached += 1) {
            const slot = self.index[cached];
            if (std.mem.order(u8, self.keyBytes(slot)[0..self.entries[slot].key_len], cursor.after[0..cursor.after_len]) == .gt) break;
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

    pub fn flush(self: *Cache) !void {
        if (self.failed) return error.FailedTransaction;
        errdefer {
            self.failed = true;
            self.namespace.fail();
        }
        var writes: [32]storage.Write = undefined;
        var dirty: [32]usize = undefined;
        var count: usize = 0;

        for (self.entries, 0..) |entry, index| {
            assert(entry.pins == 0);

            if (entry.dirty) {
                writes[count] = .{
                    .key = self.keyBytes(index)[0..entry.key_len],
                    .value = if (entry.present) self.value(index)[0..entry.value_len] else null,
                };
                dirty[count] = index;
                count += 1;
            }

            if (count == writes.len or index + 1 == self.entries.len) {
                if (count != 0) try self.namespace.putBatch(writes[0..count]);

                for (dirty[0..count]) |written| self.entries[written].dirty = false;
                self.statistics.writes += count;
                count = 0;
            }
        }
    }

    fn keyBytes(self: *Cache, index: usize) []u8 {
        return self.keys[index * self.key_bytes ..][0..self.key_bytes];
    }

    fn value(self: *Cache, index: usize) []u8 {
        return self.values[index * self.value_bytes ..][0..self.value_bytes];
    }

    pub const Lease = struct {
        cache: *Cache,
        index: usize,
        generation: u64,

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
            entry.present = false;
            entry.dirty = true;
            entry.value_len = 0;
        }

        pub fn release(self: Lease) void {
            const entry = &self.cache.entries[self.index];
            assert(entry.pins > 0 and entry.generation == self.generation);

            if (entry.editing) {
                self.cache.failed = true;
                self.cache.namespace.fail();
                entry.editing = false;
            }

            entry.pins -= 1;
        }
    };
};
