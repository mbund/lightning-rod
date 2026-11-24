const value = @import("value.zig");
pub const Value = value.Value;
const table = @import("table.zig");
pub const Table = table.Table;
pub const Resources = table.Resources;
pub const Workspaces = table.Workspaces;
pub const Get = table.Get;
pub const PackedRead = table.PackedRead;
pub const PackedBatch = table.PackedBatch;
pub const Write = table.Write;
pub const ScanEntry = table.ScanEntry;
pub const ScanKey = table.ScanKey;
pub const ScanCursor = table.ScanCursor;
pub const ScanResult = table.ScanResult;
pub const BorrowedEntry = struct { key: []const u8, value: []const u8 };
const std = @import("std");
const metrics = @import("metrics");
const storage = @import("storage");

const assert = std.debug.assert;
const IndexSet = storage.system.IndexSet;
const value_pool = @import("value_pool.zig");
pub const PooledValues = value_pool.Pool;

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
    batches: metrics.Counter = .{},
    written_bytes: metrics.Counter = .{},

    pub fn init(registry: ?*metrics.Registry, namespace: []const u8) !Instrumentation {
        const owner = registry orelse return .{};
        return .{
            .acquisition = try owner.timer(.{ .namespace = namespace, .name = "acquisition", .description = "Acquire a working set some of which was not cached" }),
            .lookup = try owner.timer(.{ .namespace = namespace, .name = "lookup", .description = "Locate cached records for a working set some of which was not cached" }),
            .eviction = try owner.timer(.{ .namespace = namespace, .name = "eviction", .description = "Select and reclaim cache slots" }),
            .storage = try owner.timer(.{ .namespace = namespace, .name = "storage", .description = "Read missing records" }),
            .eviction_write = try owner.timer(.{ .namespace = namespace, .name = "eviction_write", .description = "Write dirty eviction victims" }),
            .hits = try owner.counter(.{ .namespace = namespace, .name = "hits", .description = "Cached records found" }),
            .misses = try owner.counter(.{ .namespace = namespace, .name = "misses", .description = "Records missing from cache" }),
            .reads = try owner.counter(.{ .namespace = namespace, .name = "reads", .description = "Records read from storage" }),
            .writes = try owner.counter(.{ .namespace = namespace, .name = "writes", .description = "Records written to storage" }),
            .evictions = try owner.counter(.{ .namespace = namespace, .name = "evictions", .description = "Occupied cache slots reclaimed" }),
            .acquired = try owner.counter(.{ .namespace = namespace, .name = "acquired", .description = "Records requested" }),
            .batches = try owner.counter(.{ .namespace = namespace, .name = "batches", .description = "Working sets requested" }),
            .written_bytes = try owner.counter(.{ .namespace = namespace, .name = "written_bytes", .description = "Evicted value bytes", .unit = .bytes }),
        };
    }
};

pub const Configuration = struct {
    slots: usize,
    reserved_slots: usize = 0,
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
    decode: ?*const fn (buffer: []u8, length: usize) storage.Error!usize = null,
};

pub const Cache = CacheFor(Table);

pub fn CacheFor(comptime Backend: type) type {
    return CacheWithValues(Backend, value_pool.Fixed);
}

pub fn CacheWithValues(comptime Backend: type, comptime Values: type) type {
    return struct {
        const Self = @This();
        pub const write_batch_size = Backend.write_batch_size;
        comptime {
            assert(write_batch_size > 0 and write_batch_size <= Table.write_batch_size);
        }

        backend: Backend,
        failed: bool = false,
        entries: []Entry,
        keys: []u8,
        values: []u8,
        value_storage: Values,
        capacity: usize,
        physical_capacity: usize,
        key_bytes: usize,
        value_bytes: usize,
        replacement: usize = 0,
        pinned_entries: usize = 0,
        order: []usize,
        index: []usize,
        index_count: usize = 0,
        lookup: std.StringArrayHashMapUnmanaged(usize) = .empty,
        index_dirty: bool = false,
        dirty_entries: IndexSet,
        metrics: Instrumentation,
        scan_entries: []ScanEntry,
        scan_bytes: []u8,
        codec: ?Codec,
        encoded: []u8,
        /// Entries transient acquisitions read, oldest first: eviction takes them before the
        /// clock looks at anything else. A reference whose entry moved on is skipped.
        transients: []Transient,
        /// Scratch for the entries an index rebuild adds.
        added: []usize,
        transient_head: usize = 0,
        transient_count: usize = 0,

        const Transient = struct { slot: usize, generation: u64 };

        const Entry = struct {
            generation: u64 = 0,
            revision: u64 = 0,
            referenced: bool = false,
            /// Read by a transient acquisition and not asked for since by any other.
            transient: bool = false,
            key_len: usize = 0,
            value_len: usize = 0,
            pins: usize = 0,
            occupied: bool = false,
            present: bool = false,
            dirty: bool = false,
            indexed: bool = false,
            ordered: bool = false,
            editing: bool = false,
            filling: bool = false,
            loaded: bool = false,
        };

        pub fn init(allocator: std.mem.Allocator, io: std.Io, backend: Backend, configuration: Configuration) !Self {
            _ = io;
            if (configuration.slots == 0) return error.InvalidArgument;
            const physical = std.math.add(usize, configuration.slots, configuration.reserved_slots) catch return error.InvalidArgument;
            const slots = Values.slots(physical) catch return error.InvalidArgument;
            if (slots == 0 or slots > std.math.maxInt(u32) or configuration.key_bytes == 0 or configuration.value_bytes == 0)
                return error.InvalidArgument;

            const instrumentation = try Instrumentation.init(configuration.metrics, configuration.metrics_namespace);
            const entries = try allocator.alignedAlloc(Entry, .@"64", slots);
            errdefer allocator.free(entries);
            @memset(entries, .{});
            const keys = try allocator.alloc(u8, try std.math.mul(usize, slots, configuration.key_bytes));
            errdefer allocator.free(keys);
            const values = try allocator.alignedAlloc(u8, .@"64", try Values.bytes(physical, configuration.value_bytes));
            errdefer allocator.free(values);
            var value_storage = try Values.init(allocator, physical, configuration.value_bytes);
            errdefer value_storage.deinit(allocator);
            const order = try allocator.alignedAlloc(usize, .@"64", slots);
            errdefer allocator.free(order);
            var lookup: std.StringArrayHashMapUnmanaged(usize) = .empty;
            try lookup.ensureTotalCapacity(allocator, @intCast(slots));
            errdefer lookup.deinit(allocator);
            const index = try allocator.alignedAlloc(usize, .@"64", slots);
            errdefer allocator.free(index);
            const scan_entries = try allocator.alloc(ScanEntry, configuration.scan_batch);
            errdefer allocator.free(scan_entries);
            const stride = try std.math.add(usize, configuration.key_bytes, configuration.value_bytes);
            const scan_capacity = try std.math.add(usize, try std.math.mul(usize, configuration.scan_batch, stride), if (configuration.scan_batch == 0) 0 else configuration.key_bytes);
            const scan_bytes = try allocator.alloc(u8, scan_capacity);
            errdefer allocator.free(scan_bytes);
            var dirty_entries = try IndexSet.init(allocator, slots);
            errdefer dirty_entries.deinit(allocator);
            const encoded = try allocator.alloc(u8, if (configuration.codec == null) 0 else @max(64 * 1024, configuration.value_bytes));
            errdefer allocator.free(encoded);
            const transients = try allocator.alloc(Transient, slots);
            errdefer allocator.free(transients);
            const added = try allocator.alloc(usize, slots);

            for (scan_entries, 0..) |*entry, i|
                entry.* = .{
                    .key = scan_bytes[i * stride ..][0..configuration.key_bytes],
                    .value = scan_bytes[i * stride + configuration.key_bytes ..][0..configuration.value_bytes],
                };

            return .{
                .backend = backend,
                .dirty_entries = dirty_entries,
                .scan_entries = scan_entries,
                .scan_bytes = scan_bytes,
                .codec = configuration.codec,
                .encoded = encoded,
                .transients = transients,
                .added = added,
                .order = order,
                .index = index,
                .lookup = lookup,
                .metrics = instrumentation,
                .entries = entries,
                .keys = keys,
                .values = values,
                .value_storage = value_storage,
                .capacity = configuration.slots,
                .physical_capacity = physical,
                .key_bytes = configuration.key_bytes,
                .value_bytes = configuration.value_bytes,
            };
        }

        /// Initialization only. Outstanding pipeline pins leave the normal working set available.
        pub fn reservePinned(self: *Self, allocator: std.mem.Allocator, io: std.Io, slots: usize) !void {
            assert(self.pinned_entries == 0 and !self.failed);
            if (slots <= self.physical_capacity - self.capacity) return;
            var replacement = try Self.init(allocator, io, self.backend, .{
                .slots = self.capacity,
                .reserved_slots = slots,
                .key_bytes = self.key_bytes,
                .value_bytes = self.value_bytes,
                .scan_batch = self.scan_entries.len,
                .codec = self.codec,
            });
            errdefer replacement.freeBuffers(allocator);
            for (self.entries, 0..) |entry, index| {
                assert(entry.pins == 0 and !entry.editing and !entry.filling);
                if (!entry.occupied) continue;
                assert(replacement.value_storage.reserve(index, entry.value_len));
                @memcpy(replacement.value(index)[0..entry.value_len], self.value(index)[0..entry.value_len]);
                @memcpy(replacement.keyBytes(index)[0..entry.key_len], self.keyBytes(index)[0..entry.key_len]);
                replacement.entries[index] = entry;
                replacement.entries[index].ordered = false;
                replacement.entries[index].transient = false;
                if (entry.indexed) replacement.lookup.putAssumeCapacity(replacement.keyBytes(index)[0..entry.key_len], index);
                if (entry.dirty) replacement.dirty_entries.insert(index);
            }
            replacement.metrics = self.metrics;
            replacement.index_dirty = true;
            self.freeBuffers(allocator);
            self.* = replacement;
        }

        fn freeBuffers(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.entries);
            allocator.free(self.keys);
            allocator.free(self.values);
            self.value_storage.deinit(allocator);
            allocator.free(self.order);
            allocator.free(self.index);
            self.lookup.deinit(allocator);
            self.dirty_entries.deinit(allocator);
            allocator.free(self.scan_entries);
            allocator.free(self.scan_bytes);
            allocator.free(self.encoded);
            allocator.free(self.transients);
            allocator.free(self.added);
        }

        /// Claims unpinned transient entries as victims, oldest first, up to the victims wanted.
        /// Returns how many references were looked at, to drop once the claim stands.
        fn claimTransients(self: *Self, victims: usize, available: *usize) usize {
            var looked: usize = 0;
            while (available.* < victims and looked < self.transient_count) : (looked += 1) {
                const reference = self.transients[(self.transient_head + looked) % self.transients.len];
                const entry = &self.entries[reference.slot];
                if (entry.generation != reference.generation or !entry.transient or !entry.occupied) continue;
                // In use: it and every newer one stay for now.
                if (entry.pins != 0) break;
                self.order[available.*] = reference.slot;
                available.* += 1;
                self.addPin(reference.slot);
            }
            return looked;
        }

        fn dropTransients(self: *Self, count: usize) void {
            assert(count <= self.transient_count);
            self.transient_head = (self.transient_head + count) % self.transients.len;
            self.transient_count -= count;
        }

        fn markTransient(self: *Self, slot: usize) void {
            const entry = &self.entries[slot];
            // Only as used as a clock's first look: what is read once goes before what is read again.
            entry.referenced = false;
            entry.transient = true;
            if (self.transient_count == self.transients.len) {
                // The oldest reference makes room, and its entry is left to the clock.
                const oldest = self.transients[self.transient_head];
                if (self.entries[oldest.slot].generation == oldest.generation) self.entries[oldest.slot].transient = false;
                self.dropTransients(1);
            }
            self.transients[(self.transient_head + self.transient_count) % self.transients.len] = .{ .slot = slot, .generation = entry.generation };
            self.transient_count += 1;
        }

        fn addPin(self: *Self, index: usize) void {
            const entry = &self.entries[index];
            if (entry.pins == 0) self.pinned_entries += 1;
            entry.pins += 1;
            assert(self.pinned_entries > 0 and self.pinned_entries <= self.entries.len);
        }

        fn removePin(self: *Self, index: usize) void {
            const entry = &self.entries[index];
            assert(entry.pins > 0 and self.pinned_entries > 0);
            entry.pins -= 1;
            if (entry.pins == 0) self.pinned_entries -= 1;
        }

        pub fn pin(self: *Self, index: usize) Lease {
            const entry = &self.entries[index];
            assert(entry.occupied);
            self.addPin(index);
            return .{ .cache = self, .index = index, .generation = entry.generation };
        }

        /// A miss may synchronously read storage. Acquire known working sets in batches. Release each
        /// lease before requesting an unbounded dependency.
        pub fn acquire(self: *Self, key: []const u8) !Lease {
            var leases: [1]Lease = undefined;
            try self.acquireMany(&.{key}, &leases);
            return leases[0];
        }

        pub fn acquireMany(self: *Self, keys: []const []const u8, leases: []Lease) !void {
            const result = try self.acquireBatch(keys, leases, false, null, self.capacity, false);
            assert(result == .ready);
        }

        /// As acquireMany, but what it reads from storage is evicted before anything else. A pass
        /// over more than the cache holds then streams its excess through a few slots instead of
        /// displacing what every pass finds cached. Hits are hits as ever.
        pub fn acquireManyTransient(self: *Self, keys: []const []const u8, leases: []Lease) !void {
            const result = try self.acquireBatch(keys, leases, false, null, self.capacity, true);
            assert(result == .ready);
        }

        pub const Reservation = union(enum) { ready, writeback: []Lease, blocked: usize };

        /// A writeback result pins only dirty eviction victims. Release them after writing and retry.
        /// A blocked result reports the additional unpinned slots required and owns no leases.
        /// A ready result transfers the requested leases. Reservation performs no backend I/O.
        /// The pin limit includes existing pins and distinct requested entries.
        pub fn reserveMany(self: *Self, keys: []const []const u8, leases: []Lease, victims: []Lease, pin_limit: usize) !Reservation {
            assert(keys.len <= 192 and victims.len >= keys.len);
            assert(pin_limit <= self.entries.len);
            return self.acquireBatch(keys, leases, true, victims, pin_limit, false);
        }

        fn acquireBatch(self: *Self, keys: []const []const u8, leases: []Lease, comptime reserve_only: bool, victims_out: ?[]Lease, pin_limit: usize, comptime transient: bool) !Reservation {
            assert(keys.len == leases.len);
            if (self.failed) return error.FailedTransaction;
            if (keys.len > self.entries.len) return error.WorkingSetTooLarge;
            if (keys.len == 0) {
                if (reserve_only and self.pinned_entries > pin_limit) return .{ .blocked = self.pinned_entries - pin_limit };
                return .ready;
            }

            self.metrics.acquired.add(keys.len);
            self.metrics.batches.add(1);
            for (keys) |key| if (key.len == 0 or key.len > self.key_bytes) return error.InvalidArgument;
            // A working set found whole is not timed: reading the clock would cost more than
            // finding it.
            if (try self.acquireResident(keys, leases, reserve_only, pin_limit, transient)) |result| return result;
            const acquisition = self.metrics.acquisition.start();
            defer acquisition.end();
            // Keep miss buffers out of resident lookup frames.
            return @call(.never_inline, Self.acquireMissing, .{ self, keys, leases, reserve_only, victims_out, pin_limit, transient });
        }

        fn acquireResident(self: *Self, keys: []const []const u8, leases: []Lease, comptime reserve_only: bool, pin_limit: usize, comptime transient: bool) !?Reservation {
            var acquired: usize = 0;
            var owned = true;
            defer if (owned) for (leases[0..acquired]) |lease| lease.release();
            for (keys, leases) |key, *lease| {
                const index = self.lookup.get(key) orelse return null;
                const entry = &self.entries[index];
                if (!reserve_only and !entry.loaded) return error.CacheLoading;
                self.addPin(index);
                lease.* = .{ .cache = self, .index = index, .generation = entry.generation };
                acquired += 1;
            }
            assert(acquired == keys.len);
            if (reserve_only and self.pinned_entries > pin_limit) return .{ .blocked = self.pinned_entries - pin_limit };
            for (leases) |lease| {
                const entry = &self.entries[lease.index];
                assert(entry.pins > 0 and entry.generation == lease.generation);
                entry.referenced = true;
                if (!transient) entry.transient = false;
            }
            self.metrics.hits.add(keys.len);
            owned = false;
            return .ready;
        }

        /// What a batch of misses fills before it reads, kept apart so filling it is not paid for.
        const MissingScratch = struct {
            requests: [192]Get,
            lengths: [192]?usize,
            missing: [192]usize,
            sorted: [192]u16,
            writes: [192]Write,
            evicted: [192]Write,
        };

        fn acquireMissing(self: *Self, keys: []const []const u8, leases: []Lease, comptime reserve_only: bool, victims_out: ?[]Lease, pin_limit: usize, comptime transient: bool) !Reservation {
            // Release builds keep safety, which fills undefined memory: this scratch is written
            // before it is read, and filling its kilobytes every batch cost more than the rest.
            // Safety stays on for the work.
            @setRuntimeSafety(false);
            var scratch: MissingScratch = undefined;
            return self.acquireMissingWith(&scratch, keys, leases, reserve_only, victims_out, pin_limit, transient);
        }

        fn acquireMissingWith(self: *Self, scratch: *MissingScratch, keys: []const []const u8, leases: []Lease, comptime reserve_only: bool, victims_out: ?[]Lease, pin_limit: usize, comptime transient: bool) !Reservation {
            var acquired: usize = 0;
            errdefer for (leases[0..acquired]) |lease| lease.release();
            const protect = keys.len > 192;
            if (protect) {
                for (keys) |key| if (key.len == 0 or key.len > self.key_bytes) return error.InvalidArgument;
                for (keys, leases) |key, *lease| {
                    const slot = self.lookup.get(key);
                    if (slot) |index| self.addPin(index);
                    lease.* = .{ .cache = self, .index = slot orelse std.math.maxInt(usize), .generation = 0 };
                }
            }
            defer if (protect) {
                for (leases[acquired..]) |lease| if (lease.index != std.math.maxInt(usize)) self.removePin(lease.index);
            };
            var base: usize = 0;

            while (base < keys.len) {
                const count = @min(192, keys.len - base);
                const batch = keys[base..][0..count];
                var hits: [192]?usize = @splat(null);
                const requests = &scratch.requests;
                const lengths = &scratch.lengths;
                const missing = &scratch.missing;
                var missing_count: usize = 0;
                errdefer {
                    for (missing[0..missing_count]) |slot| {
                        self.unindex(slot);
                        self.value_storage.release(slot);
                        self.entries[slot].occupied = false;
                    }
                }
                {
                    const lookup = self.metrics.lookup.start();
                    defer lookup.end();

                    for (batch, hits[0..count]) |key, *hit| {
                        if (key.len == 0 or key.len > self.key_bytes) return error.InvalidArgument;
                        hit.* = self.lookup.get(key);
                    }
                }

                if (!reserve_only) for (hits[0..count]) |hit| {
                    if (hit) |slot| if (!self.entries[slot].loaded) return error.CacheLoading;
                };

                // Protect every hit before choosing any eviction victim.
                for (hits[0..count]) |hit| if (hit) |slot| {
                    self.addPin(slot);
                };

                if (protect) for (leases[base..][0..count]) |*lease| {
                    if (lease.index != std.math.maxInt(usize)) self.removePin(lease.index);
                    lease.index = std.math.maxInt(usize);
                };
                var hits_owned = true;
                errdefer if (hits_owned) {
                    for (hits[0..count]) |hit| if (hit) |slot| {
                        self.removePin(slot);
                    };
                };
                var available: usize = 0;
                const all_hits = for (hits[0..count]) |hit| {
                    if (hit == null) break false;
                } else true;
                if (reserve_only and all_hits and self.pinned_entries > pin_limit) {
                    const shortfall = self.pinned_entries - pin_limit;
                    for (hits[0..count]) |hit| if (hit) |slot| self.removePin(slot);
                    hits_owned = false;
                    return .{ .blocked = shortfall };
                }
                if (!all_hits) {
                    const eviction = self.metrics.eviction.start();
                    defer eviction.end();

                    const sorted = &scratch.sorted;
                    for (sorted[0..count], 0..) |*request, index| request.* = @intCast(index);
                    // By key, then by place: the order a stable sort gives, without its buffer.
                    std.sort.pdq(u16, sorted[0..count], batch, struct {
                        fn less(items: []const []const u8, a: u16, b: u16) bool {
                            return switch (std.mem.order(u8, items[a], items[b])) {
                                .lt => true,
                                .gt => false,
                                .eq => a < b,
                            };
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
                    const unpinned = pin_limit -| self.pinned_entries;
                    if (self.pinned_entries > pin_limit or victims > unpinned) {
                        if (!reserve_only) return error.CachePinned;
                        const shortfall = (self.pinned_entries -| pin_limit) + (victims -| unpinned);
                        for (hits[0..count]) |hit| if (hit) |slot| self.removePin(slot);
                        hits_owned = false;
                        return .{ .blocked = shortfall };
                    }
                    // What transient acquisitions read goes first, oldest first.
                    const transients_taken = self.claimTransients(victims, &available);
                    // The first revolution clears references. The second claims every unpinned victim.
                    var examined: usize = 0;
                    while (available < victims and examined < self.entries.len * 2) : (examined += 1) {
                        const slot = self.replacement;
                        self.replacement = (slot + 1) % self.entries.len;
                        const entry = &self.entries[slot];
                        if (entry.pins != 0) continue;
                        if (entry.occupied and entry.referenced) {
                            entry.referenced = false;
                            continue;
                        }
                        self.order[available] = slot;
                        available += 1;
                        // Pin selected victims until selection is complete.
                        self.addPin(slot);
                    }
                    for (self.order[0..available]) |slot| self.removePin(slot);
                    assert(available == victims);

                    const writes = &scratch.writes;
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
                        if (reserve_only) {
                            const victims_out_slice = victims_out.?;
                            var dirty: usize = 0;
                            for (self.order[0..victims]) |slot| {
                                const entry = &self.entries[slot];
                                if (!entry.dirty) continue;
                                assert(entry.pins == 0);
                                self.addPin(slot);
                                victims_out_slice[dirty] = .{ .cache = self, .index = slot, .generation = entry.generation };
                                dirty += 1;
                            }
                            assert(dirty == write_count);
                            self.replacement = self.order[0];
                            for (hits[0..count]) |hit| if (hit) |slot| {
                                self.removePin(slot);
                            };
                            hits_owned = false;
                            return .{ .writeback = victims_out_slice[0..dirty] };
                        }
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

                    self.dropTransients(transients_taken);
                    var victim: usize = 0;
                    var previous: ?u16 = null;

                    for (sorted[0..count]) |request| {
                        if (hits[request] != null) continue;
                        if (previous) |prior| {
                            if (std.mem.eql(u8, batch[prior], batch[request])) {
                                hits[request] = hits[prior];
                                self.addPin(hits[request].?);
                                continue;
                            }
                        }

                        if (victim == available) return error.CachePinned;

                        const slot = self.order[victim];
                        victim += 1;
                        const entry = &self.entries[slot];

                        self.unindex(slot);
                        self.metrics.evictions.add(@intFromBool(entry.occupied));
                        self.value_storage.release(slot);
                        self.metrics.misses.add(1);
                        entry.* = .{ .generation = entry.generation + 1, .key_len = batch[request].len, .occupied = true };
                        self.addPin(slot);
                        @memcpy(self.keyBytes(slot)[0..entry.key_len], batch[request]);
                        assert(!self.lookup.contains(batch[request]));
                        self.lookup.putAssumeCapacity(self.keyBytes(slot)[0..entry.key_len], slot);
                        entry.indexed = true;
                        self.index_dirty = true;
                        hits[request] = slot;
                        missing[missing_count] = slot;
                        requests[missing_count] = .{ .key = self.keyBytes(slot)[0..entry.key_len], .destination = if (reserve_only) &.{} else self.value(slot) };
                        missing_count += 1;
                        previous = request;
                    }
                }
                self.metrics.hits.add(count - missing_count);

                for (hits[0..count], leases[base..][0..count]) |hit, *lease| {
                    const slot = hit.?;
                    self.entries[slot].referenced = true;
                    if (!transient) self.entries[slot].transient = false;
                    lease.* = .{ .cache = self, .index = slot, .generation = self.entries[slot].generation };
                    acquired += 1;
                }

                hits_owned = false;
                if (!reserve_only and missing_count != 0) {
                    for (missing[0..missing_count], requests[0..missing_count]) |slot, *request| {
                        var victims: [192]Lease = undefined;
                        const lease: Lease = .{ .cache = self, .index = slot, .generation = self.entries[slot].generation };
                        while (true) {
                            switch (try self.reserveValue(lease, self.value_bytes, &victims)) {
                                .ready => break,
                                .blocked => return error.CachePinned,
                                .writeback => |dirty| {
                                    defer for (dirty) |victim| victim.release();
                                    const writes = &scratch.evicted;
                                    for (dirty, writes[0..dirty.len]) |victim, *write| write.* = .{ .key = victim.key(), .value = victim.read() };
                                    try self.writeBack(writes[0..dirty.len]);
                                    for (dirty) |victim| victim.markWritten();
                                },
                            }
                        }
                        request.destination = self.value(slot);
                    }
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
                        self.entries[slot].loaded = true;
                        self.value_storage.shrink(slot, self.entries[slot].value_len);
                    }

                    self.metrics.reads.add(missing_count);
                }
                if (transient) for (missing[0..missing_count]) |slot| self.markTransient(slot);

                base += count;
            }
            assert(!reserve_only or self.pinned_entries <= pin_limit);
            return .ready;
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
            return self.scanBatch(cursor, false, output);
        }

        /// Rows expire at the next scan or cache mutation. Decode them before acquiring other records.
        pub fn scanBorrowed(self: *Self, cursor: *ScanCursor, output: []BorrowedEntry) !ScanResult {
            return self.scanBatch(cursor, true, output);
        }

        fn scanBatch(self: *Self, cursor: *ScanCursor, comptime borrowed: bool, output: []if (borrowed) BorrowedEntry else ScanEntry) !ScanResult {
            if (self.failed) return error.FailedTransaction;
            if (output.len == 0 or output.len > self.scan_entries.len) return error.WorkingSetTooLarge;
            if (cursor.after.len < self.key_bytes) return error.BufferTooSmall;
            assert(cursor.after_len <= self.key_bytes);

            if (!borrowed) for (output) |row| {
                if (row.key.len < self.key_bytes or row.value.len < self.value_bytes) return error.BufferTooSmall;
            };

            self.rebuildIndex();
            const after = self.scan_bytes[self.scan_bytes.len - self.key_bytes ..];
            @memcpy(after[0..cursor.after_len], cursor.after[0..cursor.after_len]);
            var disk_cursor: ScanCursor = .{ .after = after, .after_len = cursor.after_len, .before = cursor.before };
            const disk = try self.backend.scan(&disk_cursor, self.scan_entries[0..output.len]);
            assert(disk.count <= output.len);
            var cached = self.lowerBound(cursor.after[0..cursor.after_len]);
            if (cached < self.index_count) {
                const slot = self.index[cached];
                if (std.mem.eql(u8, self.keyBytes(slot)[0..self.entries[slot].key_len], cursor.after[0..cursor.after_len])) cached += 1;
            }

            var stored: usize = 0;
            var count: usize = 0;

            // Cached keys at or past the bound are as good as none.
            var cached_end = self.index_count;
            if (cursor.before.len != 0) cached_end = self.lowerBound(cursor.before);
            while (count < output.len and (stored < disk.count or (!disk.more and cached < cached_end))) {
                const row = if (stored < disk.count) self.scan_entries[stored] else null;
                const slot = if (cached < cached_end) self.index[cached] else null;
                const cache_key = if (slot) |id| self.keyBytes(id)[0..self.entries[id].key_len] else null;
                const order = if (row) |r| if (cache_key) |key| std.mem.order(u8, key, r.key[0..r.key_len]) else .gt else .lt;
                const key = if (order != .gt) cache_key.? else row.?.key[0..row.?.key_len];
                var contents: ?[]const u8 = null;

                if (order != .gt) {
                    const entry = &self.entries[slot.?];
                    assert(!entry.editing);

                    if (entry.present) contents = self.value(slot.?)[0..entry.value_len];
                } else contents = row.?.value[0..try self.decode(row.?.value, row.?.value_len)];
                if (contents) |bytes| {
                    if (borrowed) {
                        output[count] = .{ .key = key, .value = bytes };
                    } else {
                        if (key.len > output[count].key.len or bytes.len > output[count].value.len) return error.BufferTooSmall;
                        @memcpy(output[count].key[0..key.len], key);
                        @memcpy(output[count].value[0..bytes.len], bytes);
                        output[count].key_len = key.len;
                        output[count].value_len = bytes.len;
                    }
                    count += 1;
                }

                @memcpy(cursor.after[0..key.len], key);
                cursor.after_len = key.len;

                if (order != .gt) cached += 1;

                if (order != .lt) stored += 1;
            }

            assert(count <= output.len);
            return .{ .count = count, .more = stored < disk.count or disk.more or cached < cached_end };
        }

        /// Existing leases remain immutable snapshots until released.
        pub fn invalidate(self: *Self, key: []const u8) void {
            const slot = self.lookup.get(key) orelse return;
            const entry = &self.entries[slot];
            assert(!entry.dirty and !entry.editing);
            self.unindex(slot);
        }

        pub fn flush(self: *Self) !void {
            if (self.failed) return error.FailedTransaction;
            errdefer {
                self.failed = true;
                self.backend.fail();
            }
            const count = self.dirty_entries.count;
            @memcpy(self.order[0..count], self.dirty_entries.values());
            std.sort.pdq(usize, self.order[0..count], self, lessKey);
            var begin: usize = 0;
            while (begin < count) {
                const length = @min(write_batch_size, count - begin);
                const slots = self.order[begin..][0..length];
                var writes: [write_batch_size]Write = undefined;
                for (slots, writes[0..length]) |slot, *write| {
                    const entry = self.entries[slot];
                    assert(entry.indexed and entry.dirty and !entry.editing);
                    assert(entry.pins == 0 or entry.filling);
                    write.* = .{
                        .key = self.keyBytes(slot)[0..entry.key_len],
                        .value = if (entry.present) self.value(slot)[0..entry.value_len] else null,
                    };
                }
                try self.putBatch(writes[0..length]);
                for (slots) |slot| {
                    self.entries[slot].dirty = false;
                    self.dirty_entries.remove(slot);
                }
                self.metrics.writes.add(length);
                begin += length;
            }
            assert(self.dirty_entries.count == 0);
            if (comptime @hasDecl(Backend, "flush")) try self.backend.flush();
        }

        fn decode(self: *Self, buffer: []u8, length: usize) !usize {
            const codec = self.codec orelse return length;
            const decode_value = codec.decode orelse return length;
            const decoded = decode_value(buffer, length) catch |err| {
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
            const codec = self.codec orelse {
                var begin: usize = 0;
                while (begin < writes.len) {
                    const count = @min(write_batch_size, writes.len - begin);
                    try self.backend.putBatch(writes[begin..][0..count]);
                    begin += count;
                }
                return;
            };
            var batch: [write_batch_size]Write = undefined;
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

        /// Pins protect these payloads. The caller serializes backend access separately.
        pub fn writeBack(self: *Self, writes: []const Write) !void {
            try self.putBatch(writes);
            self.metrics.writes.add(writes.len);
        }

        fn unindex(self: *Self, slot: usize) void {
            const entry = &self.entries[slot];
            if (!entry.indexed) return;
            const removed = self.lookup.fetchSwapRemove(self.keyBytes(slot)[0..entry.key_len]).?;
            assert(removed.value == slot);
            self.dirty_entries.remove(slot);
            entry.indexed = false;
            entry.ordered = false;
            self.index_dirty = true;
        }

        /// By key, then by slot: a total order, so unstable sorts give one result.
        fn lessKey(self: *Self, a: usize, b: usize) bool {
            return switch (std.mem.order(u8, self.keyBytes(a)[0..self.entries[a].key_len], self.keyBytes(b)[0..self.entries[b].key_len])) {
                .lt => true,
                .gt => false,
                .eq => a < b,
            };
        }

        fn rebuildIndex(self: *Self) void {
            if (!self.index_dirty) return;
            // Only what was added is sorted, then merged into the order kept: however many entries
            // a batch adds, a rebuild does not sort the whole cache again.
            const added = self.added;
            var additions: usize = 0;
            for (self.entries, 0..) |entry, slot| {
                if (!entry.indexed or entry.ordered) continue;
                added[additions] = slot;
                additions += 1;
            }
            var count: usize = 0;
            {
                std.sort.pdq(usize, added[0..additions], self, lessKey);
                var old: usize = 0;
                var fresh: usize = 0;
                while (old < self.index_count or fresh < additions) {
                    if (old < self.index_count and !self.entries[self.index[old]].ordered) {
                        old += 1;
                        continue;
                    }
                    const take_old = fresh == additions or (old < self.index_count and self.lessKey(self.index[old], added[fresh]));
                    self.order[count] = if (take_old) self.index[old] else added[fresh];
                    if (take_old) old += 1 else fresh += 1;
                    count += 1;
                }
                std.mem.swap([]usize, &self.index, &self.order);
            }
            assert(count == self.lookup.count());
            for (self.index[0..count]) |slot| {
                assert(self.entries[slot].indexed);
                self.entries[slot].ordered = true;
            }
            self.index_count = count;
            self.index_dirty = false;
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
            return self.value_storage.buffer(self.values, self.value_bytes, index);
        }

        /// Preserve previous bytes before growing a value. Other pinned buffers never move.
        pub fn reserveValue(self: *Self, lease: Lease, length: usize, victims: []Lease) !Reservation {
            const entry = &self.entries[lease.index];
            assert(entry.generation == lease.generation and entry.pins > 0);
            assert(length <= self.value_bytes and victims.len > 0);
            assert(!entry.present or length <= self.value(lease.index).len or entry.pins == 1);
            while (!self.value_storage.reserve(lease.index, length)) {
                var dirty: usize = 0;
                var reclaimed = false;
                // Two revolutions give referenced entries a second chance before reclaiming them.
                for (0..self.entries.len * 2) |_| {
                    const slot = self.replacement;
                    self.replacement = (slot + 1) % self.entries.len;
                    const candidate = &self.entries[slot];
                    if (candidate.pins != 0 or !candidate.occupied or self.value(slot).len == 0) continue;
                    if (candidate.referenced) {
                        candidate.referenced = false;
                        continue;
                    }
                    if (candidate.dirty) {
                        self.addPin(slot);
                        victims[dirty] = .{ .cache = self, .index = slot, .generation = candidate.generation };
                        dirty += 1;
                        if (dirty == victims.len) break;
                        continue;
                    }
                    self.unindex(slot);
                    self.value_storage.release(slot);
                    candidate.occupied = false;
                    candidate.loaded = false;
                    candidate.present = false;
                    candidate.value_len = 0;
                    self.metrics.evictions.add(1);
                    reclaimed = true;
                    break;
                }
                if (dirty != 0) return .{ .writeback = victims[0..dirty] };
                if (!reclaimed) return .{ .blocked = 1 };
            }
            return .ready;
        }

        /// Retains a pin. Publish or cancel only after the writer has stopped.
        pub const Fill = struct {
            lease: Lease,
            bytes: []u8,

            pub fn prepare(self: *Fill, length: usize, victims: []Lease) !Reservation {
                assert(self.lease.cache.entries[self.lease.index].filling);
                const result = try self.lease.cache.reserveValue(self.lease, length, victims);
                if (result == .ready) self.bytes = self.lease.cache.value(self.lease.index);
                return result;
            }

            pub fn load(self: Fill, length: ?usize) void {
                const entry = &self.lease.cache.entries[self.lease.index];
                assert(entry.generation == self.lease.generation and entry.pins > 0);
                assert(entry.filling and !entry.editing and !entry.present and !entry.dirty);
                assert(length == null or length.? <= self.bytes.len);
                entry.filling = false;
                entry.loaded = true;
                entry.present = length != null;
                entry.value_len = length orelse 0;
                self.lease.cache.value_storage.shrink(self.lease.index, entry.value_len);
                entry.revision += 1;
                self.lease.release();
            }

            pub fn publish(self: Fill, length: usize) void {
                const entry = &self.lease.cache.entries[self.lease.index];
                assert(entry.generation == self.lease.generation and entry.pins > 0);
                assert(entry.filling and !entry.editing and !entry.present and !entry.dirty);
                entry.filling = false;
                entry.editing = true;
                self.lease.commit(length);
                self.lease.release();
            }

            pub fn cancel(self: Fill) void {
                const entry = &self.lease.cache.entries[self.lease.index];
                assert(entry.generation == self.lease.generation and entry.pins > 0);
                assert(entry.filling and !entry.editing and !entry.present and !entry.dirty);
                entry.filling = false;
                self.lease.release();
            }
        };

        pub const Lease = struct {
            cache: *Self,
            index: usize,
            generation: u64,

            pub fn key(self: Lease) []const u8 {
                const entry = &self.cache.entries[self.index];
                assert(entry.generation == self.generation and entry.pins > 0);
                return self.cache.keyBytes(self.index)[0..entry.key_len];
            }

            pub fn retain(self: Lease) Lease {
                const entry = &self.cache.entries[self.index];
                assert(entry.pins > 0 and entry.generation == self.generation);
                self.cache.addPin(self.index);
                return self;
            }

            pub fn reserve(self: Lease) Fill {
                const entry = &self.cache.entries[self.index];
                assert(entry.generation == self.generation and entry.pins > 0);
                assert(!entry.editing and !entry.filling and !entry.present and !entry.dirty);
                entry.filling = true;
                return .{ .lease = self.retain(), .bytes = self.cache.value(self.index) };
            }

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
                assert(entry.loaded);
                return if (entry.present) self.cache.value(self.index)[0..entry.value_len] else null;
            }

            /// Release without commit poisons the cache: a partial edit cannot be checkpointed.
            pub fn edit(self: Lease) []u8 {
                const entry = &self.cache.entries[self.index];
                assert(entry.pins > 0);
                assert(entry.generation == self.generation);
                assert(!entry.editing and !entry.filling);
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
                assert(length <= self.cache.value(self.index).len);
                entry.revision += 1;
                entry.value_len = length;
                entry.present = true;
                entry.loaded = true;
                entry.dirty = true;
                self.cache.dirty_entries.insert(self.index);
                entry.editing = false;
                self.cache.value_storage.shrink(self.index, length);
                assert(entry.present and entry.dirty);
            }

            pub fn remove(self: Lease) void {
                const entry = &self.cache.entries[self.index];
                assert(entry.pins > 0 and entry.generation == self.generation);
                assert(!entry.editing);
                entry.revision += 1;
                entry.present = false;
                entry.dirty = true;
                self.cache.dirty_entries.insert(self.index);
                entry.value_len = 0;
            }

            pub fn markWritten(self: Lease) void {
                const entry = &self.cache.entries[self.index];
                assert(entry.generation == self.generation and entry.pins > 0);
                assert(entry.dirty and !entry.editing);
                assert(self.cache.dirty_entries.contains(self.index));
                entry.dirty = false;
                self.cache.dirty_entries.remove(self.index);
            }

            pub fn release(self: Lease) void {
                const entry = &self.cache.entries[self.index];
                assert(entry.pins > 0 and entry.generation == self.generation);

                if (entry.editing) {
                    self.cache.failed = true;
                    self.cache.backend.fail();
                    entry.editing = false;
                }

                assert(!entry.filling or entry.pins > 1);
                self.cache.removePin(self.index);
            }
        };
    };
}
