const std = @import("std");
const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const encoding = @import("encoding.zig");
const patch = @import("patch.zig");
const compressed = @import("compressed.zig");
const light = @import("light.zig");
const Merger = @import("merge.zig").Merger;
const GroupCache = records.CacheFor(compressed.Backend);

const maximum_sections = 64;
const Projection = enum { encoded, decoded, classification };
const Properties = struct { table: []const u8 = &.{}, selected: u8 = 1, reads: []const Store.ClassificationRead = &.{} };
const overlay_bytes = 1 + patch.maximum;
const section_bytes = encoding.maximum_decoded_bytes;
const format_magic = "LRCHNK04";
const base_root_offset = 8;
const overlay_root_offset = 16;
const group_side_offset = 24;
const light_root_offset = 32;
const light_sequence_key = [_]u8{2};
const OverlayHeader = packed struct(u8) {
    kind: enum(u6) { removed, patch, _ },
    compressed: bool = false,
    biomes: bool = false,
};

pub const Store = struct {
    pub const Options = struct { side: u8 };
    const LoadWorkspace = struct {
        victims: [192]GroupCache.Lease,
        reads: [192]records.Get,
        fills: [192]GroupCache.Fill,
        sizes: [192]?usize,
    };
    const ReadWorkspace = struct {
        busy: bool = false,
        input: [192][]const u8 = undefined,
        batch: Batch = .{},
        leases: [192]GroupCache.Lease = undefined,
        values: [192]?[]const u8 = undefined,
        overlays: [192]records.Get = undefined,
        lengths: [192]?usize = undefined,
        locations: [maximum_sections]Location = undefined,
        states: [4096]u16 = undefined,
        biomes: [64]u16 = undefined,
        patch_bytes: [patch.maximum]u8 = undefined,
        raw: [section_bytes]u8 = undefined,
        load: LoadWorkspace = undefined,
    };
    const WriteWorkspace = struct {
        input: [192][]const u8,
        batch: Batch,
        leases: [192]GroupCache.Lease,
        overlays: [192]records.Write,
        parts: [maximum_sections][]const u8,
        locations: [maximum_sections]Location,
        replaced: [maximum_sections]bool,
        before: [4096]u16,
        after: [4096]u16,
        old_biomes: [64]u16,
        new_biomes: [64]u16,
        raw: [section_bytes]u8,
        load: LoadWorkspace,
        eviction: [192]GroupCache.Lease,
        base_writes: [192]records.Write,
        publication_keys: [maximum_sections][16]u8,
        removals: [maximum_sections]records.Write,
        revision_keys: [192][13]u8,
        revision_writes: [193]records.Write,
    };
    read_workspaces: []ReadWorkspace,
    writer: *WriteWorkspace,
    bases: GroupCache,
    side: u8,
    section_count: usize,
    header_bytes: usize,
    group_bytes: usize,
    overlays: records.Table,
    lights: records.Table,
    light_revision: u64 = 0,
    overlay_writes: []u8,
    window: usize,
    merger: *Merger,
    discovery_revision: u64 = 0,
    prepared: metrics.Counter,
    merged: metrics.Counter,
    discovery_scans: metrics.Counter,
    merge_cpu: metrics.Timer,
    scratch: []u8,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    // Table pages mutate in place. Cached bases remain independent of this lock.
    table_lock: std.Io.RwLock = .init,
    available: std.Io.Condition = .init,
    readers: usize = 0,
    writing: bool = false,
    draining: bool = false,
    mutating: []bool,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, space: storage.Space, capacity: usize, registry: *metrics.Registry, table_resources: *records.Resources, options: Options) !Store {
        var self = try allocate(allocator, io, space, capacity, registry, table_resources, options);
        try self.open();
        return self;
    }

    pub fn open(self: *Store) !void {
        const space = self.bases.backend.table.space;
        const root = try space.getRoot() orelse blk: {
            var ids: [1]storage.PageId = undefined;
            try space.allocatePages(&ids);
            var page: storage.Page = @splat(0);
            @memcpy(page[0..8], format_magic);
            page[group_side_offset] = self.side;
            try space.writePages(&.{.{ .id = ids[0], .source = &page }});
            try space.setRoot(ids[0]);
            break :blk ids[0];
        };
        var page: storage.Page = undefined;
        try space.readPages(&.{.{ .id = root, .destination = &page }});
        if (!std.mem.eql(u8, page[0..8], format_magic)) return error.UnsupportedFormat;
        if (page[group_side_offset] != self.side) return error.UnsupportedFormat;
        self.bases.backend.table.directory = root;
        self.overlays.directory = root;
        self.lights.directory = root;
        var counter: [8]u8 = undefined;
        var lengths: [1]?usize = undefined;
        try self.lights.getBatch(&.{.{ .key = &light_sequence_key, .destination = &counter }}, &lengths);
        if (lengths[0]) |length| {
            if (length != counter.len) return error.Corrupt;
            self.light_revision = std.mem.readInt(u64, &counter, .little);
        }
    }

    pub fn allocate(allocator: std.mem.Allocator, io: std.Io, space: storage.Space, capacity: usize, registry: *metrics.Registry, table_resources: *records.Resources, options: Options) !Store {
        if (capacity == 0 or (options.side != 1 and options.side != 2 and options.side != 4)) return error.InvalidArgument;
        const section_count = @as(usize, options.side) * options.side * options.side;
        const header = 8 + section_count * 2;
        const maximum = header + section_count * section_bytes;
        const scratch = try allocator.alloc(u8, maximum);
        errdefer allocator.free(scratch);
        const writer = try allocator.create(WriteWorkspace);
        errdefer allocator.destroy(writer);
        const read_workspaces = try allocator.alloc(ReadWorkspace, table_resources.readers.slots.len);
        errdefer allocator.free(read_workspaces);
        for (read_workspaces) |*workspace| workspace.busy = false;
        const mutating = try allocator.alloc(bool, capacity);
        errdefer allocator.free(mutating);
        @memset(mutating, false);
        const window: usize = @min(192, capacity * section_count);
        const overlay_writes = try allocator.alloc(u8, window * overlay_bytes);
        errdefer allocator.free(overlay_writes);
        return .{
            .prepared = try registry.counter(.{ .name = "chunks.merge.prepared", .description = "Prepared replacement chunk groups" }),
            .discovery_scans = try registry.counter(.{ .name = "chunks.merge.scans", .description = "Batches of overlay keys scanned for consolidation" }),
            .merged = try registry.counter(.{ .name = "chunks.merge.published", .description = "Atomically published replacement chunk groups" }),
            .merge_cpu = try registry.timer(.{ .name = "chunks.merge.cpu", .description = "Background chunk consolidation CPU time", .clock = .thread_cpu }),
            .merger = try Merger.init(allocator, maximum, section_count, capacity),
            .side = options.side,
            .section_count = section_count,
            .header_bytes = header,
            .group_bytes = maximum,
            .io = io,
            .scratch = scratch,
            .writer = writer,
            .read_workspaces = read_workspaces,
            .mutating = mutating,
            .window = window,
            .overlay_writes = overlay_writes,
            .overlays = .{ .space = space, .root_offset = overlay_root_offset, .resources = table_resources },
            .lights = .{ .space = space, .root_offset = light_root_offset, .resources = table_resources, .value_cache = .stream },
            .bases = try GroupCache.init(allocator, io, try compressed.Backend.init(allocator, io, .{ .space = space, .root_offset = base_root_offset, .resources = table_resources, .value_cache = .stream }, maximum, capacity), .{
                .slots = capacity,
                .key_bytes = 16,
                .value_bytes = maximum,
                .metrics = registry,
                .metrics_namespace = "chunks.bases",
            }),
        };
    }

    const Address = struct { key: [16]u8, part: usize };
    const Batch = struct {
        const absent = std.math.maxInt(u16);
        addresses: [192]Address = undefined,
        keys: [192][]const u8 = undefined,
        mapping: [192]usize = undefined,
        first: [192]u16 = undefined,
        last: [192]u16 = undefined,
        next: [192]u16 = undefined,
        count: usize = 0,
        unique: usize = 0,

        fn plan(self: *Batch, input: []const []const u8, capacity: usize, side: u8) !void {
            std.debug.assert(self.count == 0 and self.unique == 0);
            std.debug.assert(input.len > 0 and input.len <= self.addresses.len and capacity > 0);
            var buckets: [512]u16 = @splat(absent);
            for (input) |key| {
                const at = try address(key, side);
                var bucket: usize = @intCast(std.hash.Wyhash.hash(0, &at.key) & (buckets.len - 1));
                while (buckets[bucket] != absent and !std.mem.eql(u8, self.keys[buckets[bucket]], &at.key)) {
                    bucket = (bucket + 1) & (buckets.len - 1);
                }
                const group: usize = if (buckets[bucket] == absent) self.unique else buckets[bucket];
                if (group == self.unique and self.unique == capacity) break;
                self.addresses[self.count] = at;
                if (group == self.unique) {
                    self.keys[group] = &self.addresses[self.count].key;
                    self.first[group] = @intCast(self.count);
                    buckets[bucket] = @intCast(group);
                    self.unique += 1;
                } else self.next[self.last[group]] = @intCast(self.count);
                self.last[group] = @intCast(self.count);
                self.next[self.count] = absent;
                self.mapping[self.count] = group;
                self.count += 1;
            }
            std.debug.assert(self.count > 0 and self.unique <= capacity);
        }
    };
    fn address(key: []const u8, side: u8) !Address {
        if (key.len != 16) return error.InvalidArgument;
        const x = std.mem.readInt(i32, key[4..8], .big);
        const z = std.mem.readInt(i32, key[8..12], .big);
        const y = std.mem.readInt(i32, key[12..16], .big);
        const group_side: i32 = side;
        var result: Address = .{ .key = undefined, .part = @intCast((@mod(x, group_side) * group_side + @mod(z, group_side)) * group_side + @mod(y, group_side)) };
        @memcpy(result.key[0..4], key[0..4]);
        std.mem.writeInt(i32, result.key[4..8], @divFloor(x, group_side), .big);
        std.mem.writeInt(i32, result.key[8..12], @divFloor(z, group_side), .big);
        std.mem.writeInt(i32, result.key[12..16], @divFloor(y, group_side), .big);
        return result;
    }

    const Location = struct { begin: usize, end: usize };
    fn locate(self: *const Store, bytes: ?[]const u8, locations: []Location) !void {
        std.debug.assert(locations.len == self.section_count);
        const value = bytes orelse {
            @memset(locations, .{ .begin = self.header_bytes, .end = self.header_bytes });
            return;
        };
        if (value.len < self.header_bytes or value.len > self.group_bytes or std.mem.readInt(u64, value[0..8], .little) == 0) return error.Corrupt;
        var total = self.header_bytes;
        for (locations, 0..) |*location, index| {
            const length = std.mem.readInt(u16, value[8 + index * 2 ..][0..2], .little);
            if (length > section_bytes or length > value.len - total) return error.Corrupt;
            if (length != 0 and !encoding.valid(value[total..][0..length])) return error.Corrupt;
            location.* = .{ .begin = total, .end = total + length };
            total += length;
        }
        if (total != value.len) return error.Corrupt;
    }

    pub fn getBatch(self: *Store, requests: []const records.Get, lengths: []?usize) !void {
        try self.readBatch(requests, lengths, .encoded, .{}, null);
    }

    pub fn decodeBatch(self: *Store, requests: []const records.Get, lengths: []?usize) !void {
        try self.readBatch(requests, lengths, .decoded, .{}, null);
    }

    pub const PackedSection = struct { view: encoding.Packed, index: usize, generation: u64, revision: u64 };
    pub const PackedWindow = struct {
        owner: *Store,
        leases: [192]GroupCache.Lease = undefined,
        count: usize = 0,

        pub fn release(self: PackedWindow) void {
            const owner = self.owner;
            owner.mutex.lockUncancelable(owner.io);
            defer owner.mutex.unlock(owner.io);
            std.debug.assert(owner.readers > 0);
            for (self.leases[0..self.count]) |lease| lease.release();
            owner.readers -= 1;
            owner.available.broadcast(owner.io);
        }
    };

    /// A complete encoded batch transfers its base pins. Incomplete batches retain no pins.
    pub fn tryBorrowPacked(self: *Store, keys: []const []const u8, output: []PackedSection) !?PackedWindow {
        std.debug.assert(keys.len == output.len and keys.len <= 192);
        self.mutex.lockUncancelable(self.io);
        const workspace = acquire: while (true) {
            while (self.draining) self.available.waitUncancelable(self.io, &self.mutex);
            for (self.read_workspaces) |*candidate| if (!candidate.busy) {
                candidate.busy = true;
                break :acquire candidate;
            };
            self.available.waitUncancelable(self.io, &self.mutex);
        };
        self.readers += 1;
        self.mutex.unlock(self.io);
        errdefer {
            self.mutex.lockUncancelable(self.io);
            workspace.busy = false;
            self.readers -= 1;
            self.available.broadcast(self.io);
            self.mutex.unlock(self.io);
        }
        const batch = &workspace.batch;
        batch.count = 0;
        batch.unique = 0;
        try batch.plan(keys, self.bases.entries.len, self.side);
        if (batch.count != keys.len) return error.WorkingSetTooLarge;
        const held = workspace.leases[0..batch.unique];
        self.mutex.lockUncancelable(self.io);
        const loaded = self.loadTilesLocked(batch.keys[0..batch.unique], held, false, &workspace.load);
        self.mutex.unlock(self.io);
        try loaded;
        errdefer {
            self.mutex.lockUncancelable(self.io);
            for (held) |lease| lease.release();
            self.available.broadcast(self.io);
            self.mutex.unlock(self.io);
        }
        const scratch = self.bases.backend.borrowRead();
        defer scratch.end();
        const overlay_reads = workspace.overlays[0..keys.len];
        for (keys, overlay_reads, 0..) |key, *read, index| read.* = .{ .key = key, .destination = scratch.bytes()[index * overlay_bytes ..][0..overlay_bytes] };
        self.table_lock.lockSharedUncancelable(self.io);
        const read = self.overlays.getBatch(overlay_reads, workspace.lengths[0..keys.len]);
        self.table_lock.unlockShared(self.io);
        try read;
        var complete = true;
        for (held, 0..) |lease, group| {
            const bytes = lease.read();
            const locations = workspace.locations[0..self.section_count];
            try self.locate(bytes, locations);
            var member = batch.first[group];
            while (member != Batch.absent) {
                const index: usize = member;
                member = batch.next[index];
                const at = batch.addresses[index];
                const location = locations[at.part];
                if (workspace.lengths[index] != null or location.begin == location.end) {
                    complete = false;
                    continue;
                }
                output[index] = .{
                    .view = try encoding.Packed.init(bytes.?[location.begin..location.end]),
                    .index = lease.index * self.section_count + at.part,
                    .generation = lease.generation,
                    .revision = lease.revision(),
                };
            }
        }
        var window: PackedWindow = .{ .owner = self, .count = held.len };
        @memcpy(window.leases[0..held.len], held);
        self.mutex.lockUncancelable(self.io);
        workspace.busy = false;
        self.available.broadcast(self.io);
        self.mutex.unlock(self.io);
        if (!complete) {
            window.release();
            return null;
        }
        return window;
    }

    pub const ClassificationRead = struct { key: []const u8, result: *encoding.Classification, mode: encoding.ClassificationMode = .complete };

    pub fn classify(self: *Store, reads: []const ClassificationRead, properties: []const u8, selected: u8) !void {
        std.debug.assert(reads.len <= 192 and std.math.isPowerOfTwo(selected));
        var requests: [192]records.Get = undefined;
        var lengths: [192]?usize = undefined;
        for (reads, requests[0..reads.len]) |read, *request| {
            request.* = .{ .key = read.key, .destination = &.{} };
        }
        try self.readBatch(requests[0..reads.len], lengths[0..reads.len], .classification, .{ .table = properties, .selected = selected, .reads = reads }, null);
    }

    fn readBatch(self: *Store, requests: []const records.Get, lengths: []?usize, comptime projection: Projection, properties: Properties, snapshot: ?*Snapshot) !void {
        if (requests.len != lengths.len) return error.InvalidArgument;
        self.mutex.lockUncancelable(self.io);
        const workspace = acquire: while (true) {
            for (self.read_workspaces) |*candidate| if (!candidate.busy) {
                candidate.busy = true;
                break :acquire candidate;
            };
            self.available.waitUncancelable(self.io, &self.mutex);
        };
        self.mutex.unlock(self.io);
        defer {
            self.mutex.lockUncancelable(self.io);
            std.debug.assert(workspace.busy);
            workspace.busy = false;
            self.available.broadcast(self.io);
            self.mutex.unlock(self.io);
        }
        var begin: usize = 0;
        while (begin < requests.len) {
            const offered: usize = @min(self.window, requests.len - begin);
            const input = &workspace.input;
            for (requests[begin..][0..offered], input[0..offered]) |request, *key| key.* = request.key;
            const batch = &workspace.batch;
            batch.count = 0;
            batch.unique = 0;
            try batch.plan(input[0..offered], self.bases.entries.len, self.side);
            const count = batch.count;
            var window: Snapshot = if (snapshot) |value| .{ .generations = value.generations[begin..][0..count] } else undefined;
            const projected: Properties = .{ .table = properties.table, .selected = properties.selected, .reads = if (projection == .classification) properties.reads[begin..][0..count] else &.{} };
            self.readWindow(workspace, batch, requests[begin..][0..count], lengths[begin..][0..count], projection, projected, if (snapshot != null) &window else null) catch |err| switch (err) {
                error.WritebackRequired => {
                    try self.loadForEviction(batch.keys[0..batch.unique]);
                    continue;
                },
                else => return err,
            };
            if (snapshot) |value| value.overlay_bytes += window.overlay_bytes;
            begin += count;
        }
    }

    fn readWindow(self: *Store, workspace: *ReadWorkspace, batch: *const Batch, requests: []const records.Get, lengths: []?usize, comptime projection: Projection, properties: Properties, snapshot: ?*Snapshot) !void {
        std.debug.assert(workspace.busy);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.draining) self.available.waitUncancelable(self.io, &self.mutex);
        self.readers += 1;
        defer {
            std.debug.assert(self.readers > 0);
            self.readers -= 1;
            self.available.broadcast(self.io);
        }
        const leases = &workspace.leases;
        const held = leases[0..batch.unique];
        try self.loadTilesLocked(batch.keys[0..batch.unique], held, false, &workspace.load);
        defer for (held) |lease| lease.release();
        const values = &workspace.values;
        for (held, values[0..held.len]) |lease, *value| value.* = lease.read();
        self.mutex.unlock(self.io);
        defer self.mutex.lockUncancelable(self.io);
        const scratch = self.bases.backend.borrowRead();
        defer scratch.end();
        const overlay_reads = scratch.bytes();
        std.debug.assert(overlay_reads.len >= requests.len * overlay_bytes);
        const overlay_requests = &workspace.overlays;
        const overlay_lengths = &workspace.lengths;
        for (requests, overlay_requests[0..requests.len], 0..) |request, *read, index| read.* = .{
            .key = request.key,
            .destination = overlay_reads[index * overlay_bytes ..][0..overlay_bytes],
        };
        {
            self.table_lock.lockSharedUncancelable(self.io);
            defer self.table_lock.unlockShared(self.io);
            try self.overlays.getBatch(overlay_requests[0..requests.len], overlay_lengths[0..requests.len]);
        }
        for (values[0..held.len], 0..) |bytes, group| {
            const locations = workspace.locations[0..self.section_count];
            try self.locate(bytes, locations);
            var member = batch.first[group];
            while (member != Batch.absent) {
                const index: usize = member;
                std.debug.assert(index < requests.len and batch.mapping[index] == group);
                member = batch.next[index];
                const request = requests[index];
                const at = batch.addresses[index];
                const length = &lengths[index];
                const overlay_length = overlay_lengths[index];
                if (snapshot) |value| {
                    value.generations[index] = if (bytes) |base| std.mem.readInt(u64, base[0..8], .little) else 0;
                    value.overlay_bytes += overlay_length orelse 0;
                }
                const location = locations[at.part];
                const size = location.end - location.begin;
                if (projection == .classification) {
                    length.* = null;
                    const classified = properties.reads[index];
                    classified.result.* = .unavailable;
                    if (size == 0 or overlay_length != null) continue;
                    const encoded = bytes.?[location.begin..location.end];
                    classified.result.* = try encoding.classify(encoded, properties.table, properties.selected, classified.mode);
                    length.* = 1;
                    continue;
                }
                length.* = if (size == 0) null else size;
                const overlay = if (overlay_length) |n| overlay_reads[index * overlay_bytes ..][0..n] else null;
                if (overlay) |record| {
                    if (record.len == 1 and record[0] == 0) {
                        length.* = null;
                        continue;
                    }
                    if (size == 0 or record.len < 2) return error.Corrupt;
                    const header: OverlayHeader = @bitCast(record[0]);
                    if (header.kind != .patch) return error.Corrupt;
                    const states = &workspace.states;
                    const biomes = &workspace.biomes;
                    const has_biomes = try decodeStates(bytes.?[location.begin..location.end], states, biomes, &workspace.raw);
                    const payload = if (header.compressed) try scratch.decode(record[1..], &workspace.patch_bytes) else record[1..];
                    const loaded = try patch.Patch.decode(payload, std.mem.readInt(u64, bytes.?[0..8], .little), states, biomes);
                    if (loaded.biomes and !header.biomes) return error.Corrupt;
                    const raw = &workspace.raw;
                    const offset: usize = if (has_biomes or header.biomes) encoding.biome_header_bytes else 0;
                    if (offset != 0) {
                        raw[0] = 3;
                        for (biomes, 0..) |biome, i| std.mem.writeInt(u16, raw[1 + i * 2 ..][0..2], biome, .little);
                    }
                    raw[offset] = 1;
                    for (states, 0..) |state, i| std.mem.writeInt(u16, raw[offset + 1 + i * 2 ..][0..2], state, .little);
                    const result = raw[0 .. offset + encoding.dense_block_bytes];
                    if (projection == .decoded) {
                        if (request.destination.len < result.len) return error.BufferTooSmall;
                        @memcpy(request.destination[0..result.len], result);
                        length.* = result.len;
                    } else {
                        const encoded = try encoding.encode(result, request.destination);
                        if (encoded.ptr != request.destination.ptr) {
                            if (encoded.len > request.destination.len) return error.BufferTooSmall;
                            @memcpy(request.destination[0..encoded.len], encoded);
                        }
                        length.* = encoded.len;
                    }
                } else if (size != 0) {
                    const encoded = bytes.?[location.begin..location.end];
                    if (projection == .decoded) {
                        length.* = try encoding.decodeTo(encoded, request.destination);
                    } else {
                        if (size > request.destination.len) return error.BufferTooSmall;
                        @memcpy(request.destination[0..size], encoded);
                    }
                }
            }
        }
    }

    fn loadTilesLocked(self: *Store, keys: []const []const u8, held: []GroupCache.Lease, comptime writer: bool, workspace: *LoadWorkspace) !void {
        while (true) {
            if (!writer) while (true) {
                const blocked = for (keys) |key| {
                    if (self.bases.lookup.get(key)) |slot| if (self.mutating[slot]) break true;
                } else false;
                if (!blocked) break;
                self.available.waitUncancelable(self.io, &self.mutex);
            };
            const reservation = try self.bases.reserveMany(keys, held, &workspace.victims, self.bases.entries.len);
            switch (reservation) {
                .blocked => {
                    if (!(self.readers > @intFromBool(!writer) or (!writer and self.writing))) return error.CachePinned;
                    self.available.waitUncancelable(self.io, &self.mutex);
                    continue;
                },
                .ready => break,
                .writeback => |dirty| {
                    if (!writer) {
                        for (dirty) |lease| lease.release();
                        return error.WritebackRequired;
                    }
                    try self.writeTilesLocked(dirty);
                },
            }
        }
        errdefer for (held) |lease| lease.release();
        while (true) {
            if (self.bases.failed) return error.FailedTransaction;
            const reads = &workspace.reads;
            const fills = &workspace.fills;
            const sizes = &workspace.sizes;
            var loading: usize = 0;
            var waiting = false;
            for (held) |lease| {
                const entry = &self.bases.entries[lease.index];
                if (entry.loaded) continue;
                if (entry.filling) {
                    waiting = true;
                    continue;
                }
                fills[loading] = lease.reserve();
                reads[loading] = .{ .key = lease.key(), .destination = fills[loading].bytes };
                loading += 1;
            }
            if (loading == 0) {
                if (!waiting) break;
                self.available.waitUncancelable(self.io, &self.mutex);
                continue;
            }
            self.mutex.unlock(self.io);
            const result = blk: {
                self.table_lock.lockSharedUncancelable(self.io);
                defer self.table_lock.unlockShared(self.io);
                break :blk self.bases.backend.getBatch(reads[0..loading], sizes[0..loading]);
            };
            self.mutex.lockUncancelable(self.io);
            if (result) |_| {
                for (fills[0..loading], sizes[0..loading]) |fill, length| fill.load(length);
                self.bases.metrics.reads.add(loading);
            } else |err| {
                for (fills[0..loading]) |fill| fill.cancel();
                self.bases.failed = true;
                self.available.broadcast(self.io);
                return err;
            }
            self.available.broadcast(self.io);
        }
    }

    fn writeTilesLocked(self: *Store, held: []const GroupCache.Lease) !void {
        std.debug.assert(self.writing);
        const writes = &self.writer.base_writes;
        for (held, writes[0..held.len]) |lease, *write| {
            std.debug.assert(self.writing and self.bases.entries[lease.index].dirty);
            write.* = .{ .key = lease.key(), .value = lease.read() };
        }
        self.mutex.unlock(self.io);
        const result = blk: {
            self.table_lock.lockUncancelable(self.io);
            defer self.table_lock.unlock(self.io);
            break :blk self.bases.writeBack(writes[0..held.len]);
        };
        self.mutex.lockUncancelable(self.io);
        for (held) |lease| {
            if (result) |_| {
                lease.markWritten();
            } else |_| {}
            lease.release();
        }
        if (result) |_| {
            std.debug.assert(self.discovery_revision != std.math.maxInt(u64));
            self.discovery_revision += 1;
        } else |_| {}
        self.available.broadcast(self.io);
        result catch |err| {
            self.bases.failed = true;
            self.bases.backend.fail();
            return err;
        };
    }

    fn loadForEviction(self: *Store, keys: []const []const u8) !void {
        self.beginWrite();
        defer self.endWrite(false);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const held = &self.writer.eviction;
        try self.loadTilesLocked(keys, held[0..keys.len], true, &self.writer.load);
        for (held[0..keys.len]) |lease| lease.release();
        self.available.broadcast(self.io);
    }

    fn beginWrite(self: *Store) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.writing) self.available.waitUncancelable(self.io, &self.mutex);
        self.writing = true;
    }

    fn endWrite(self: *Store, changed: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.writing);
        self.writing = false;
        if (changed) {
            std.debug.assert(self.discovery_revision != std.math.maxInt(u64));
            self.discovery_revision += 1;
        }
        self.available.broadcast(self.io);
    }

    pub fn putBatch(self: *Store, writes: []const records.Write) !void {
        if (writes.len == 0) return;
        self.beginWrite();
        defer self.endWrite(true);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        errdefer self.fail();
        var begin: usize = 0;
        while (begin < writes.len) {
            const offered: usize = @min(self.window, writes.len - begin);
            const input = &self.writer.input;
            for (writes[begin..][0..offered], input[0..offered]) |write, *key| key.* = write.key;
            const batch = &self.writer.batch;
            batch.count = 0;
            batch.unique = 0;
            try batch.plan(input[0..offered], self.bases.entries.len, self.side);
            const count = batch.count;
            self.merger.invalidate(batch.keys[0..batch.unique]);
            const leases = &self.writer.leases;
            const held = leases[0..batch.unique];
            try self.loadTilesLocked(batch.keys[0..batch.unique], held, true, &self.writer.load);
            for (held) |lease| self.mutating[lease.index] = true;
            defer {
                for (held) |lease| {
                    self.mutating[lease.index] = false;
                    lease.release();
                }
                self.available.broadcast(self.io);
            }
            while (true) {
                const borrowed = for (held) |lease| {
                    if (self.bases.entries[lease.index].pins != 1) break true;
                } else false;
                if (!borrowed) break;
                self.available.waitUncancelable(self.io, &self.mutex);
            }
            const overlay_writes = &self.writer.overlays;
            var overlay_count: usize = 0;
            for (leases[0..batch.unique], 0..) |lease, group| {
                const old = lease.read();
                const parts = &self.writer.parts;
                const locations = &self.writer.locations;
                const replaced = &self.writer.replaced;
                @memset(replaced, false);
                try self.locate(old, locations[0..self.section_count]);
                for (parts[0..self.section_count], locations[0..self.section_count]) |*part, location| {
                    part.* = if (old) |bytes| bytes[location.begin..location.end] else &.{};
                }
                var member = batch.first[group];
                while (member != Batch.absent) {
                    std.debug.assert(member < count and batch.mapping[member] == group);
                    const write = writes[begin + member];
                    const target = batch.addresses[member];
                    member = batch.next[member];
                    const value = write.value orelse &.{};
                    if (value.len > section_bytes or (value.len != 0 and !encoding.valid(value))) return error.InvalidArgument;
                    const original = parts[target.part];
                    const output = self.overlay_writes[overlay_count * overlay_bytes ..][0..overlay_bytes];
                    overlay_writes[overlay_count] = .{ .key = write.key, .value = null };
                    if (original.len != 0) {
                        if (value.len == 0) {
                            output[0] = 0;
                            overlay_writes[overlay_count].value = output[0..1];
                        } else {
                            const before = &self.writer.before;
                            const after = &self.writer.after;
                            const old_biomes = &self.writer.old_biomes;
                            const new_biomes = &self.writer.new_biomes;
                            const old_has_biomes = try decodeStates(original, before, old_biomes, &self.writer.raw);
                            const new_has_biomes = try decodeStates(value, after, new_biomes, &self.writer.raw);
                            var changes: patch.Patch = .{};
                            for (before, after, 0..) |a, b, index| {
                                if (a == b) continue;
                                changes.words[index / 64] |= @as(u64, 1) << @intCast(index % 64);
                                changes.count += 1;
                            }
                            changes.biomes = new_has_biomes and (!old_has_biomes or !std.mem.eql(u16, old_biomes, new_biomes));
                            if (changes.count != 0 or changes.biomes) {
                                var header: OverlayHeader = .{ .kind = .patch, .biomes = new_has_biomes };
                                const encoded = try changes.encode(after, new_biomes, if (old) |bytes| std.mem.readInt(u64, bytes[0..8], .little) else 1, self.scratch);
                                var payload = encoded;
                                if (changes.preferCompression()) {
                                    const compressed_patch = self.bases.backend.compressor.encode(encoded, output[1..]) catch |err| switch (err) {
                                        error.BufferTooSmall => null,
                                        else => return err,
                                    };
                                    if (compressed_patch) |compressed_value| if (compressed_value.len < encoded.len) {
                                        header.compressed = true;
                                        payload = compressed_value;
                                    };
                                }
                                output[0] = @bitCast(header);
                                if (payload.ptr != output[1..].ptr) @memcpy(output[1..][0..payload.len], payload);
                                overlay_writes[overlay_count].value = output[0 .. 1 + payload.len];
                            }
                        }
                    } else {
                        parts[target.part] = value;
                        replaced[target.part] = true;
                    }
                    overlay_count += 1;
                }
                var length: usize = self.header_bytes;
                var changed = false;
                var resized = false;
                for (parts[0..self.section_count], locations[0..self.section_count]) |part, location| {
                    const previous = if (old) |bytes| bytes[location.begin..location.end] else &.{};
                    length += part.len;
                    changed = changed or !std.mem.eql(u8, previous, part);
                    resized = resized or part.len != previous.len;
                }
                if (!changed) continue;
                if (length == self.header_bytes) {
                    lease.remove();
                    continue;
                }
                if (resized) {
                    for (parts[0..self.section_count], locations[0..self.section_count], replaced[0..self.section_count]) |*part, location, replacement| {
                        if (replacement) continue;
                        const preserved = self.scratch[location.begin..location.end];
                        @memcpy(preserved, part.*);
                        part.* = preserved;
                    }
                }
                const bytes = lease.edit();
                std.mem.writeInt(u64, bytes[0..8], if (old) |previous| std.mem.readInt(u64, previous[0..8], .little) else 1, .little);
                var offset: usize = self.header_bytes;
                for (parts[0..self.section_count], replaced[0..self.section_count], 0..) |part, replacement, section| {
                    if (resized or replacement) @memcpy(bytes[offset..][0..part.len], part);
                    std.mem.writeInt(u16, bytes[8 + section * 2 ..][0..2], @intCast(part.len), .little);
                    offset += part.len;
                }
                std.debug.assert(offset == length);
                lease.commit(length);
            }
            self.mutex.unlock(self.io);
            const overlay_result = blk: {
                self.table_lock.lockUncancelable(self.io);
                defer self.table_lock.unlock(self.io);
                const mutation = self.overlays.space.mutate();
                defer mutation.end();
                self.overlays.putBatch(overlay_writes[0..overlay_count]) catch |err| break :blk err;
                if (self.light_revision == std.math.maxInt(u64)) break :blk error.Corrupt;
                self.light_revision += 1;
                var revision: [8]u8 = undefined;
                std.mem.writeInt(u64, &revision, self.light_revision, .little);
                const keys = &self.writer.revision_keys;
                const revisions = &self.writer.revision_writes;
                for (writes[begin..][0..count], keys[0..count], revisions[0..count]) |write, *key, *entry| {
                    std.debug.assert(write.key.len == 16);
                    key[0] = 0;
                    @memcpy(key[1..13], write.key[0..12]);
                    entry.* = .{ .key = key, .value = &revision };
                }
                revisions[count] = .{ .key = &light_sequence_key, .value = &revision };
                break :blk self.lights.putBatch(revisions[0 .. count + 1]);
            };
            self.mutex.lockUncancelable(self.io);
            try overlay_result;
            begin += count;
        }
    }

    pub fn lightSnapshots(self: *Store, input: []const light.Request, snapshots: []light.Snapshot) !void {
        std.debug.assert(input.len == snapshots.len and input.len <= light.batch_max);
        if (input.len == 0) return;
        var keys: [10 * light.batch_max][13]u8 = undefined;
        var values: [10 * light.batch_max][8]u8 = undefined;
        var requests: [10 * light.batch_max]records.Get = undefined;
        var lengths: [10 * light.batch_max]?usize = undefined;
        var count: usize = 0;
        for (input) |entry| {
            const neighbors = try entry.column.neighbors();
            for (neighbors) |neighbor| {
                keys[count] = neighbor.key(.revision);
                requests[count] = .{ .key = &keys[count], .destination = &values[count] };
                count += 1;
            }
            if (entry.destination) |bytes| {
                keys[count] = entry.column.key(.light);
                requests[count] = .{ .key = &keys[count], .destination = bytes };
                count += 1;
            }
        }
        {
            self.table_lock.lockSharedUncancelable(self.io);
            defer self.table_lock.unlockShared(self.io);
            try self.lights.getBatch(requests[0..count], lengths[0..count]);
        }
        var offset: usize = 0;
        for (input, snapshots) |entry, *snapshot| {
            for (&snapshot.revisions) |*revision| {
                if (lengths[offset]) |length| {
                    if (length != 8) return error.Corrupt;
                    revision.* = std.mem.readInt(u64, &values[offset], .little);
                } else revision.* = 0;
                offset += 1;
            }
            snapshot.length = if (entry.destination != null) lengths[offset] else null;
            offset += @intFromBool(entry.destination != null);
        }
        std.debug.assert(offset == count);
    }

    pub fn putLight(self: *Store, column: light.Column, frame: []const u8) !void {
        if (frame.len == 0) return error.InvalidArgument;
        const key = column.key(.light);
        self.table_lock.lockUncancelable(self.io);
        defer self.table_lock.unlock(self.io);
        try self.lights.putBatch(&.{.{ .key = &key, .value = frame }});
    }

    pub const Snapshot = struct { generations: []u64, overlay_bytes: usize = 0 };

    pub fn discoveryRevision(self: *Store) ?u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return if (self.writing) null else self.discovery_revision;
    }

    pub fn groupKey(self: *const Store, key: []const u8) ![16]u8 {
        return (try address(key, self.side)).key;
    }

    pub fn sectionKeys(self: *const Store, group: *const [16]u8, keys: [][16]u8) void {
        std.debug.assert(keys.len == self.section_count);
        const side: i32 = self.side;
        for (keys, 0..) |*key, index| {
            @memcpy(key[0..4], group[0..4]);
            std.mem.writeInt(i32, key[4..8], std.mem.readInt(i32, group[4..8], .big) * side + @as(i32, @intCast(index / self.side / self.side)), .big);
            std.mem.writeInt(i32, key[8..12], std.mem.readInt(i32, group[8..12], .big) * side + @as(i32, @intCast(index / self.side % self.side)), .big);
            std.mem.writeInt(i32, key[12..16], std.mem.readInt(i32, group[12..16], .big) * side + @as(i32, @intCast(index % self.side)), .big);
        }
    }

    pub fn readSnapshot(self: *Store, requests: []const records.Get, lengths: []?usize, snapshot: *Snapshot) !void {
        std.debug.assert(requests.len == snapshot.generations.len);
        try self.readBatch(requests, lengths, .encoded, .{}, snapshot);
    }

    pub fn prepareMerge(self: *Store) !bool {
        const timing = self.merge_cpu.start();
        defer timing.end();
        return self.merger.prepare(self);
    }

    /// Publish one group without waiting for another mutation or borrowed base.
    pub fn publishPrepared(self: *Store) !usize {
        if (!self.mutex.tryLock()) return 0;
        const index = select: {
            if (!self.writing and !self.draining) for (self.merger.slots, 0..) |*slot, index| {
                if (slot.state != .ready) continue;
                if (slot.invalidated) {
                    slot.state = .free;
                    continue;
                }
                if (self.bases.lookup.get(&slot.key)) |cached| {
                    const entry = &self.bases.entries[cached];
                    if (entry.pins != 0 or entry.filling or entry.dirty or self.mutating[cached]) continue;
                }
                break :select index;
            };
            self.mutex.unlock(self.io);
            return 0;
        };
        const selected = &self.merger.slots[index];
        if (!self.table_lock.tryLock(self.io)) {
            self.mutex.unlock(self.io);
            return 0;
        }
        const mutation = self.overlays.space.tryMutate() orelse {
            self.table_lock.unlock(self.io);
            self.mutex.unlock(self.io);
            return 0;
        };
        defer mutation.end();
        self.writing = true;
        selected.state = .publishing;
        var held: ?GroupCache.Lease = null;
        if (self.bases.lookup.get(&selected.key)) |cached| {
            held = self.bases.pin(cached);
            self.mutating[cached] = true;
        }
        self.mutex.unlock(self.io);
        defer {
            self.mutex.lockUncancelable(self.io);
            std.debug.assert(selected.state == .publishing and !selected.invalidated);
            if (held) |lease| {
                self.mutating[lease.index] = false;
                lease.release();
            }
            self.bases.invalidate(&selected.key);
            selected.state = .free;
            self.mutex.unlock(self.io);
            self.table_lock.unlock(self.io);
            self.endWrite(true);
        }
        errdefer self.fail();
        const base: records.Write = .{ .key = &selected.key, .value = if (selected.length == 0) null else self.merger.frames[index * self.merger.stride ..][0..selected.length] };
        const keys = self.writer.publication_keys[0..self.section_count];
        const removals = self.writer.removals[0..self.section_count];
        self.sectionKeys(&selected.key, keys);
        for (keys, removals) |*key, *remove| remove.* = .{ .key = key, .value = null };
        try self.bases.backend.table.putBatch(&.{base});
        try self.overlays.putBatch(removals);
        self.merged.add(1);
        return 1;
    }

    pub fn flush(self: *Store) !void {
        self.beginWrite();
        var changed = false;
        defer self.endWrite(changed);
        self.mutex.lockUncancelable(self.io);
        self.draining = true;
        while (self.readers != 0) self.available.waitUncancelable(self.io, &self.mutex);
        changed = self.bases.dirty_entries.count != 0;
        self.mutex.unlock(self.io);
        defer {
            self.mutex.lockUncancelable(self.io);
            self.draining = false;
            self.available.broadcast(self.io);
            self.mutex.unlock(self.io);
        }
        self.table_lock.lockUncancelable(self.io);
        defer self.table_lock.unlock(self.io);
        try self.bases.flush();
    }

    pub fn fail(self: *Store) void {
        self.bases.backend.fail();
    }
};

fn decodeStates(encoded: []const u8, states: *[4096]u16, biomes: *[64]u16, buffer: *[section_bytes]u8) !bool {
    const length = try encoding.decodeTo(encoded, buffer);
    const offset = encoding.blockOffset(buffer[0..length]);
    if (offset != 0) {
        for (biomes, 0..) |*biome, index| biome.* = std.mem.readInt(u16, buffer[1 + index * 2 ..][0..2], .little);
    } else @memset(biomes, 0);
    const raw = buffer[offset..length];
    if (raw.len == 3) {
        @memset(states, std.mem.readInt(u16, raw[1..3], .little));
    } else {
        for (states, 0..) |*state, index| state.* = std.mem.readInt(u16, raw[1 + index * 2 ..][0..2], .little);
    }
    return offset != 0;
}

test "base groups preserve maximal prefixes and stable member order" {
    var keys: [192][16]u8 = undefined;
    var input: [192][]const u8 = undefined;
    var random = std.Random.DefaultPrng.init(20261027);
    for (&keys, &input) |*key, *slice| {
        std.mem.writeInt(u32, key[0..4], random.random().uintLessThan(u32, 3), .big);
        std.mem.writeInt(i32, key[4..8], random.random().intRangeAtMost(i32, -8, 8), .big);
        std.mem.writeInt(i32, key[8..12], random.random().intRangeAtMost(i32, -8, 8), .big);
        std.mem.writeInt(i32, key[12..16], random.random().intRangeAtMost(i32, -4, 1), .big);
        slice.* = key;
    }
    for ([_]usize{ 1, 7, 192 }) |capacity| {
        var begin: usize = 0;
        while (begin < input.len) {
            var batch: Store.Batch = .{};
            try batch.plan(input[begin..], capacity, 2);
            try std.testing.expect(batch.unique <= capacity);
            var visited: [192]bool = @splat(false);
            var members: usize = 0;
            for (0..batch.unique) |group| {
                var current = batch.first[group];
                var previous: ?usize = null;
                while (current != Store.Batch.absent) {
                    try std.testing.expect(current < batch.count and !visited[current]);
                    visited[current] = true;
                    members += 1;
                    if (previous) |last| try std.testing.expect(current > last);
                    const expected = try Store.address(input[begin + current], 2);
                    try std.testing.expectEqualSlices(u8, &expected.key, batch.keys[group]);
                    try std.testing.expectEqual(expected.part, batch.addresses[current].part);
                    try std.testing.expectEqual(group, batch.mapping[current]);
                    previous = current;
                    current = batch.next[current];
                }
                try std.testing.expectEqual(previous.?, batch.last[group]);
            }
            try std.testing.expectEqual(batch.count, members);
            if (begin + batch.count < input.len) {
                try std.testing.expectEqual(capacity, batch.unique);
                const next = try Store.address(input[begin + batch.count], 2);
                for (batch.keys[0..batch.unique]) |key| try std.testing.expect(!std.mem.eql(u8, key, &next.key));
            }
            begin += batch.count;
        }
    }
}
