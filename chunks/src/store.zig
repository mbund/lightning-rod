const std = @import("std");
const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const zstandard = @import("zstandard");
const encoding = @import("encoding.zig");
const patch = @import("patch.zig");
const compressed = @import("compressed.zig");
const light = @import("light.zig");
const delivery = @import("delivery.zig");
const classification = @import("classification.zig");
const Merger = @import("merge.zig").Merger;
const GroupCache = records.CacheWithValues(compressed.Backend, records.PooledValues);

const maximum_sections = 64;
const Projection = enum { encoded, decoded, classification };
const Properties = struct { table: []const u8 = &.{}, selected: u8 = 1, reads: []const Store.ClassificationRead = &.{} };
const overlay_bytes = 1 + patch.maximum;
const section_bytes = encoding.maximum_decoded_bytes;
const format_magic = "LRCHNK05";
const derived_magic = "LRDER002";
/// No cache generation reaches this value, so a store holding it has no roots yet.
const derived_detached = std.math.maxInt(u32);
/// Page zero holds file metadata and never a table directory.
const derived_unrooted: storage.PageId = @fromBackingInt(0);
const base_root_offset = 8;
const overlay_root_offset = 16;
const group_side_offset = 24;
const revision_root_offset = 32;
const classification_root_offset = 40;
const revision_batch_max = records.Table.write_batch_size;
const OverlayHeader = packed struct(u8) {
    kind: enum(u6) { removed, patch, _ },
    compressed: bool = false,
    biomes: bool = false,
};

pub const Store = struct {
    pub const Options = struct { side: u8, batch_groups: usize = 8, write_bytes: ?usize = null, prepared_groups: usize = 2 };
    const LoadWorkspace = struct {
        victims: [192]GroupCache.Lease,
        keys: [192][]const u8,
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
        states: [4096]u16 = undefined,
        biomes: [64]u16 = undefined,
        patch_bytes: [patch.maximum]u8 = undefined,
        raw: [section_bytes]u8 = undefined,
        classification_keys: [192][classification.key_bytes]u8 = undefined,
        classifications: []u8,
        classification_raw: []u8,
        load: LoadWorkspace = undefined,
    };
    const ReadLease = struct {
        owner: *Store,
        workspace: *ReadWorkspace,

        fn end(self: ReadLease) void {
            self.owner.mutex.lockUncancelable(self.owner.io);
            defer self.owner.mutex.unlock(self.owner.io);
            std.debug.assert(self.workspace.busy);
            self.workspace.busy = false;
            self.owner.available.broadcast(self.owner.io);
        }
    };
    const WriteWorkspace = struct {
        input: [192][]const u8,
        batch: Batch,
        leases: [192]GroupCache.Lease,
        /// Groups of the batch being written that someone else held when room for the
        /// write was reserved. They are patched and never written in place.
        borrowed: [192]bool,
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
        revision_keys: [revision_batch_max][13]u8,
        revision_writes: [revision_batch_max]records.Write,
        light_record: []u8,
        classification_keys: [][classification.key_bytes]u8,
        classification_headers: [][classification.Header.maximum_size]u8,
        classification_decoded: []classification.Header,
        classification_reads: []records.Get,
        classification_lengths: []?usize,
        classifications: []u8,
        classification_writes: []records.Write,
        classification_source: []u8,
        classification_results: []encoding.Classification,
    };
    read_workspaces: []ReadWorkspace,
    writer: *WriteWorkspace,
    bases: GroupCache,
    layouts: []Layout,
    layout_builds: u64 = 0,
    side: u8,
    section_count: usize,
    header_bytes: usize,
    group_bytes: usize,
    overlays: records.Table,
    lights: records.Table,
    revisions: records.Table,
    derived: *storage.DiskCache,
    derived_mutex: std.Io.Mutex = .init,
    /// The cache generation that holds this store's roots. Changes only while derived_tables
    /// is held exclusively.
    derived_generation: u32 = derived_detached,
    derived_identity: [16]u8,
    /// The cache had no place for this store when it opened: its names were all taken, or
    /// it had been dropped. The store never reads or writes it.
    derived_unplaced: bool = false,
    derived_resets: metrics.Counter,
    derived_disables: metrics.Counter,
    derived_tables: std.Io.RwLock = .init,
    classifications: records.Table,
    classification_indices: ?*classification.Index = null,
    classification_bytes: usize = 0,
    window: usize,
    merger: *Merger,
    discovery_revision: u64 = 0,
    prepared: metrics.Counter,
    merged: metrics.Counter,
    discovery_scans: metrics.Counter,
    merge_cpu: metrics.Timer,
    classification_reading: metrics.Timer,
    classification_decoding: metrics.Timer,
    light_reading: metrics.Timer,
    classification_decoded_bytes: metrics.Counter,
    classification_header_reads: metrics.Counter,
    scratch: []u8,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    // Table pages mutate in place. Cached bases remain independent of this lock.
    table_lock: std.Io.RwLock = .init,
    available: std.Io.Condition = .init,
    readers: usize = 0,
    writing: bool = false,
    mutating: []bool,
    pipeline_capacity: usize = 0,
    pipeline_pins: usize = 0,
    group_windows: ?*GroupWindow = null,

    fn acquireRead(self: *Store) ReadLease {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            for (self.read_workspaces) |*workspace| if (!workspace.busy) {
                workspace.busy = true;
                return .{ .owner = self, .workspace = workspace };
            };
            self.available.waitUncancelable(self.io, &self.mutex);
        }
    }

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
        self.revisions.directory = root;
    }

    pub fn allocate(allocator: std.mem.Allocator, io: std.Io, space: storage.Space, capacity: usize, registry: *metrics.Registry, table_resources: *records.Resources, options: Options) !Store {
        if (capacity == 0 or options.batch_groups == 0 or options.batch_groups > 192 or options.prepared_groups == 0 or options.prepared_groups > 192 or (options.side != 1 and options.side != 2 and options.side != 4)) return error.InvalidArgument;
        const batch_groups = @min(capacity, options.batch_groups);
        const section_count = @as(usize, options.side) * options.side * options.side;
        const header = 8 + section_count * 2;
        const maximum = header + section_count * section_bytes;
        const derived = try space.store.openCache(".cache", .{});
        var name_buffer: [63]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "chunks_{d}_{d}", .{ @backingInt(space.id), if (space.root) |reference| @backingInt(reference.page) else @as(u64, 0) });
        // A disposable cache never stops a store from opening. Without a place in it the
        // store derives everything again, as it does after the cache is dropped.
        const cache_space: ?storage.Space = derived.openSpace(name) catch |err| placed: {
            // A damaged cache is emptied by its next writer. Nobody may have written since.
            if (err == error.FailedTransaction and derived.state.load(.acquire) == .damaged) {
                if (derived.reset() catch false) {
                    if (derived.openSpace(name)) |space_again| break :placed space_again else |_| {}
                }
            }
            if (err != error.NoSpace and err != error.FailedTransaction) return err;
            std.log.warn("event=chunk_cache_unplaced reason={t} store={s}", .{ err, name });
            break :placed null;
        };
        if (cache_space) |placed| std.debug.assert(placed.store != space.store);
        // The terrain thread reads frames and the simulation thread reads light for edits.
        // Each has a reader of its own, so that neither waits for the disk read of the other.
        const derived_resources = try records.Resources.init(allocator, io, .{ .readers = 2, .writers = 1 });
        const source_identity = (try space.revision()).identity;
        const layouts = try allocator.alloc(Layout, try records.PooledValues.slots(capacity));
        errdefer allocator.free(layouts);
        @memset(layouts, .{});
        if (options.write_bytes) |bytes| if (bytes < zstandard.bound(maximum)) return error.InvalidArgument;
        const scratch = try allocator.alloc(u8, maximum);
        errdefer allocator.free(scratch);
        const writer = try allocator.create(WriteWorkspace);
        errdefer allocator.destroy(writer);
        writer.classifications = &.{};
        writer.classification_keys = &.{};
        writer.classification_headers = &.{};
        writer.classification_decoded = &.{};
        writer.classification_reads = &.{};
        writer.classification_lengths = &.{};
        writer.classification_writes = &.{};
        writer.classification_source = &.{};
        writer.classification_results = &.{};
        writer.light_record = try allocator.alloc(u8, light.maximum_bytes + delivery.Column.header_size);
        errdefer allocator.free(writer.light_record);
        const read_workspaces = try allocator.alloc(ReadWorkspace, table_resources.readers.slots.len);
        errdefer allocator.free(read_workspaces);
        for (read_workspaces) |*workspace| {
            workspace.busy = false;
            workspace.classifications = &.{};
            workspace.classification_raw = &.{};
        }
        const mutating = try allocator.alloc(bool, layouts.len);
        errdefer allocator.free(mutating);
        @memset(mutating, false);
        const window: usize = @min(192, capacity * section_count, try std.math.mul(usize, zstandard.bound(maximum), batch_groups) / overlay_bytes);
        std.debug.assert(window > 0);
        var store: Store = .{
            .prepared = try registry.counter(.{ .name = "chunks.merge.prepared", .description = "Prepared replacement chunk groups" }),
            .discovery_scans = try registry.counter(.{ .name = "chunks.merge.scans", .description = "Batches of overlay keys scanned for consolidation" }),
            .merged = try registry.counter(.{ .name = "chunks.merge.published", .description = "Atomically published replacement chunk groups" }),
            .merge_cpu = try registry.timer(.{ .name = "chunks.merge.cpu", .description = "Background chunk consolidation CPU time", .clock = .thread_cpu, .detailed = true }),
            .classification_reading = try registry.timer(.{ .name = "chunks.classifications.read.cpu", .description = "Read baked classification headers and section records", .clock = .thread_cpu, .detailed = true }),
            .classification_decoding = try registry.timer(.{ .name = "chunks.classifications.decode.cpu", .description = "Decode prepared section classification records", .clock = .thread_cpu, .detailed = true }),
            .light_reading = try registry.timer(.{ .name = "chunks.light.read.cpu", .description = "Read stored lighting or bake dependency revisions", .clock = .thread_cpu, .detailed = true }),
            .classification_decoded_bytes = try registry.counter(.{ .name = "chunks.classifications.decoded_bytes", .description = "Decompressed prepared classification bytes", .unit = .bytes }),
            .classification_header_reads = try registry.counter(.{ .name = "chunks.classifications.header_reads", .description = "Classification column summaries read from the record index" }),
            .merger = try Merger.init(allocator, maximum, section_count, @min(batch_groups, options.prepared_groups)),
            .side = options.side,
            .section_count = section_count,
            .layouts = layouts,
            .header_bytes = header,
            .group_bytes = maximum,
            .io = io,
            .scratch = scratch,
            .writer = writer,
            .read_workspaces = read_workspaces,
            .mutating = mutating,
            .window = window,
            .overlays = .{ .space = space, .root_offset = overlay_root_offset, .resources = table_resources },
            .revisions = .{ .space = space, .root_offset = revision_root_offset, .resources = table_resources },
            .derived = derived,
            .derived_identity = source_identity,
            .derived_resets = try registry.counter(.{ .name = "chunks.disk_cache.resets", .description = "Times the derived chunk cache was emptied after damage and kept in use" }),
            .derived_disables = try registry.counter(.{ .name = "chunks.disk_cache.disabled", .description = "Times the derived chunk cache was switched off for the rest of the process" }),
            .derived_unplaced = cache_space == null,
            // Tables of an unplaced store are never rooted, so the space they name is never used.
            .lights = .{ .space = cache_space orelse space, .directory = derived_unrooted, .root_offset = 32, .resources = derived_resources, .value_cache = .stream },
            .classifications = .{ .space = cache_space orelse space, .directory = derived_unrooted, .root_offset = classification_root_offset, .resources = derived_resources },
            .bases = try GroupCache.init(allocator, io, try compressed.Backend.init(allocator, io, .{ .space = space, .root_offset = base_root_offset, .resources = table_resources, .value_cache = .stream }, .{ .maximum = maximum, .batch_groups = batch_groups, .read_bytes = window * overlay_bytes, .write_bytes = options.write_bytes, .patch_bytes = window * overlay_bytes, .metrics = registry }), .{
                .slots = capacity,
                .key_bytes = 16,
                .value_bytes = @max(maximum, zstandard.bound(maximum)),
                .metrics = registry,
                .metrics_namespace = "chunks.bases",
            }),
        };
        store.rootDerived();
        return store;
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

        fn plan(self: *Batch, input: []const []const u8, capacity: usize, side: u8, comptime group_keys: usize) !void {
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
                if (self.count + 1 + (self.unique + @intFromBool(group == self.unique)) * group_keys > self.keys.len) break;
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
    const Layout = struct {
        generation: u64 = 0,
        revision: u64 = 0,
        locations: [maximum_sections]Location = undefined,
    };
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

    fn prepareLayouts(self: *Store, leases: []const GroupCache.Lease) !void {
        for (leases) |lease| {
            const layout = &self.layouts[lease.index];
            const revision = lease.revision();
            if (layout.generation == lease.generation and layout.revision == revision) continue;
            const bytes = lease.read();
            try self.locate(bytes, layout.locations[0..self.section_count]);
            layout.generation = lease.generation;
            layout.revision = revision;
            self.layout_builds += 1;
        }
    }

    pub fn getBatch(self: *Store, requests: []const records.Get, lengths: []?usize) !void {
        try self.readBatch(requests, lengths, .encoded, .{}, null);
    }

    pub fn decodeBatch(self: *Store, requests: []const records.Get, lengths: []?usize) !void {
        try self.readBatch(requests, lengths, .decoded, .{}, null);
    }

    /// Retains matching groups on first read until reset. Admission does not load terrain.
    pub const GroupWindow = struct {
        /// Section coordinates. Horizontal bounds are the containing storage group.
        pub const Region = struct { world: u32, x: i32, z: i32, minimum: i32, count: usize };
        owner: *Store,
        leases: []GroupCache.Lease,
        count: usize = 0,
        bounds: ?Region = null,
        next: ?*GroupWindow = null,

        pub fn begin(self: *GroupWindow, region: Region) void {
            const owner = self.owner;
            owner.mutex.lockUncancelable(owner.io);
            defer owner.mutex.unlock(owner.io);
            self.resetLocked();
            owner.available.broadcast(owner.io);
            std.debug.assert(region.count > 0);
            const last = std.math.cast(i32, @as(i64, region.minimum) + @as(i64, @intCast(region.count)) - 1) orelse unreachable;
            const minimum = @divFloor(region.minimum, owner.side);
            const count: usize = @intCast(@as(i64, @divFloor(last, owner.side)) - minimum + 1);
            std.debug.assert(count <= self.leases.len);
            self.bounds = .{ .world = region.world, .x = @divFloor(region.x, owner.side), .z = @divFloor(region.z, owner.side), .minimum = minimum, .count = count };
        }

        pub fn reset(self: *GroupWindow) void {
            const owner = self.owner;
            owner.mutex.lockUncancelable(owner.io);
            defer owner.mutex.unlock(owner.io);
            self.resetLocked();
            owner.available.broadcast(owner.io);
        }

        fn resetLocked(self: *GroupWindow) void {
            const owner = self.owner;
            std.debug.assert(owner.pipeline_pins >= self.count);
            for (self.leases[0..self.count]) |lease| lease.release();
            owner.pipeline_pins -= self.count;
            if (self.count != 0) {
                std.debug.assert(owner.readers > 0);
                owner.readers -= 1;
            }
            self.count = 0;
            self.bounds = null;
        }

        fn retain(self: *GroupWindow, lease: GroupCache.Lease) void {
            const bounds = self.bounds orelse return;
            if (lease.read() == null) return;
            const key = lease.key();
            const y = std.mem.readInt(i32, key[12..16], .big);
            if (std.mem.readInt(u32, key[0..4], .big) != bounds.world or
                std.mem.readInt(i32, key[4..8], .big) != bounds.x or
                std.mem.readInt(i32, key[8..12], .big) != bounds.z or
                y < bounds.minimum or @as(i64, y) - bounds.minimum >= bounds.count) return;
            for (self.leases[0..self.count]) |held| if (held.index == lease.index) {
                std.debug.assert(held.generation == lease.generation);
                return;
            };
            std.debug.assert(self.count < self.leases.len);
            if (self.count == 0) self.owner.readers += 1;
            self.leases[self.count] = lease.retain();
            self.count += 1;
            self.owner.pipeline_pins += 1;
            std.debug.assert(self.owner.pipeline_pins <= self.owner.pipeline_capacity);
        }
    };

    /// Initialization only. Capacity is measured in decoded storage groups.
    pub fn createGroupWindow(self: *Store, allocator: std.mem.Allocator, capacity: usize) !*GroupWindow {
        std.debug.assert(capacity > 0);
        const leases = try allocator.alloc(GroupCache.Lease, capacity);
        errdefer allocator.free(leases);
        const window = try allocator.create(GroupWindow);
        errdefer allocator.destroy(window);
        try self.reservePipeline(allocator, capacity);
        window.* = .{ .owner = self, .leases = leases, .next = self.group_windows };
        self.group_windows = window;
        return window;
    }

    fn reservePipeline(self: *Store, allocator: std.mem.Allocator, groups: usize) !void {
        std.debug.assert(self.readers == 0 and !self.writing and self.pipeline_pins == 0);
        const capacity = try std.math.add(usize, self.pipeline_capacity, groups);
        const physical = try std.math.add(usize, self.bases.capacity, capacity);
        const layouts = try allocator.alloc(Layout, try records.PooledValues.slots(physical));
        errdefer allocator.free(layouts);
        @memset(layouts, .{});
        const mutating = try allocator.alloc(bool, layouts.len);
        errdefer allocator.free(mutating);
        @memset(mutating, false);
        try self.bases.reservePinned(allocator, self.io, capacity);
        allocator.free(self.layouts);
        allocator.free(self.mutating);
        self.layouts = layouts;
        self.mutating = mutating;
        self.pipeline_capacity = capacity;
        std.debug.assert(self.bases.physical_capacity == physical);
    }

    pub const ClassificationRead = struct { key: []const u8, result: *encoding.Classification, prepared: ?*classification.Prepared = null, projection: classification.Projection = .full };

    /// Register immutable projections during initialization. Missing records are built on demand.
    pub fn registerClassification(self: *Store, allocator: std.mem.Allocator, properties: []const u8, selected: u8, codec: ?classification.Codec) !*const classification.Index {
        if (properties.len == 0 or !std.math.isPowerOfTwo(selected)) return error.InvalidArgument;
        if (codec) |extra| if (extra.identity.len == 0 or extra.maximum == 0 or extra.prefix_bytes > classification.maximum_prefix or extra.prefix_bytes > extra.maximum) return error.InvalidArgument;
        if (codec) |extra| if (extra.column) |column| if (column.identity.len == 0 or column.maximum == 0 or column.maximum > light.maximum_metadata) return error.InvalidArgument;
        const identity = classification.Index.fingerprint(properties, selected, codec);
        var cursor = self.classification_indices;
        while (cursor) |index| : (cursor = index.next) {
            if (std.mem.eql(u8, &index.identity, &identity)) return index;
        }
        if (self.classification_indices == null) {
            const groups = self.window;
            self.writer.classification_source = try allocator.alloc(u8, self.window * section_bytes);
            self.writer.classification_results = try allocator.alloc(encoding.Classification, self.window);
            self.writer.classification_keys = try allocator.alloc([classification.key_bytes]u8, groups + self.window);
            self.writer.classification_headers = try allocator.alloc([classification.Header.maximum_size]u8, groups);
            self.writer.classification_decoded = try allocator.alloc(classification.Header, groups);
            self.writer.classification_reads = try allocator.alloc(records.Get, groups);
            self.writer.classification_lengths = try allocator.alloc(?usize, groups);
            self.writer.classification_writes = try allocator.alloc(records.Write, groups + self.window);
        }
        const raw_bytes = try std.math.add(usize, 8 + classification.bytes, if (codec) |extra| extra.maximum else @as(usize, 0));
        const compressor = try allocator.create(zstandard.Compressor);
        compressor.* = try .init(allocator, 6, raw_bytes);
        const encoder = try compressor.borrow(6, raw_bytes);
        std.debug.assert(encoder.owner != &self.bases.backend.compressor);
        const stride = @max(classification.Header.size(if (codec) |extra| extra.prefix_bytes else 0), try std.math.add(usize, 1, zstandard.bound(raw_bytes)));
        if (stride > self.classification_bytes) {
            const capacity = try std.math.mul(usize, 192, stride);
            self.writer.classifications = try allocator.realloc(self.writer.classifications, try std.math.mul(usize, self.window, stride));
            for (self.read_workspaces) |*workspace| {
                workspace.classifications = try allocator.realloc(workspace.classifications, capacity);
            }
            self.classification_bytes = stride;
        }
        for (self.read_workspaces) |*workspace| {
            if (workspace.classification_raw.len < raw_bytes) workspace.classification_raw = try allocator.realloc(workspace.classification_raw, raw_bytes);
        }
        const scratch = try allocator.alloc(u8, raw_bytes);
        errdefer allocator.free(scratch);
        const index = try allocator.create(classification.Index);
        index.* = .{ .identity = identity, .properties = properties, .selected = selected, .codec = codec, .table = records.Table.init(self.classifications.space, self.classifications.resources), .encoder = encoder, .scratch = scratch };
        self.attachClassification(index);
        index.next = self.classification_indices;
        self.classification_indices = index;
        return index;
    }

    /// Roots a new index in the cache. A file too damaged to open is left for the next
    /// writer to empty, which roots every registered index again, so a disposable file
    /// never stops the server from starting.
    fn attachClassification(self: *Store, index: *classification.Index) void {
        self.derived_tables.lockUncancelable(self.io);
        defer self.derived_tables.unlock(self.io);
        const use = self.beginDerivedWrite() orelse return;
        defer use.end();
        self.openClassification(index) catch |err| return self.failDerived(use, err);
        // The pages it allocated are part of the file only once the header says so. A
        // server that stopped before any other cache write would otherwise leave a file
        // longer than its header, which the next start takes for damage and deletes.
        self.commitDerived(use);
    }

    fn openClassification(self: *Store, index: *classification.Index) !void {
        const space = self.classifications.space;
        var encoded_directory: [8]u8 = undefined;
        var length: [1]?usize = undefined;
        try self.classifications.getBatch(&.{.{ .key = &index.identity, .destination = &encoded_directory }}, &length);
        const directory: storage.PageId = if (length[0]) |n| existing: {
            if (n != 8) return error.Corrupt;
            const id = std.mem.readInt(u64, &encoded_directory, .little);
            if (id == 0) return error.Corrupt;
            break :existing @fromBackingInt(id);
        } else create: {
            var ids: [1]storage.PageId = undefined;
            try space.allocatePages(&ids);
            const page: storage.Page = @splat(0);
            try space.writePages(&.{.{ .id = ids[0], .source = &page }});
            std.mem.writeInt(u64, &encoded_directory, @backingInt(ids[0]), .little);
            try self.classifications.putBatch(&.{.{ .key = &index.identity, .value = &encoded_directory }});
            break :create ids[0];
        };
        index.table = records.Table.rooted(space, directory, 0, self.classifications.resources);
    }

    pub fn summarize(self: *Store, columns: []const classification.Column, output: []classification.ColumnSummary, properties: []const u8, selected: u8) !void {
        self.derived_mutex.lockUncancelable(self.io);
        defer self.derived_mutex.unlock(self.io);
        const generation = self.derived.generation.load(.acquire);
        self.summarizeCached(columns, output, properties, selected) catch |err| {
            self.failDerivedSince(err, generation);
            @memset(output, .{});
        };
        const index = self.findClassification(properties, selected) orelse return;
        var keys: [192][16]u8 = undefined;
        var reads: [192]ClassificationRead = undefined;
        var locations: [192]struct { column: usize, section: u5 } = undefined;
        const results = self.writer.classification_results;
        var count: usize = 0;
        for (columns, output, 0..) |column, summary, column_index| {
            for (0..column.count) |section| {
                if ((summary.known | summary.missing) & (@as(u32, 1) << @intCast(section)) != 0) continue;
                keys[count] = chunksKey(column, @intCast(section));
                reads[count] = .{ .key = &keys[count], .result = &results[count], .projection = .prefix };
                locations[count] = .{ .column = column_index, .section = @intCast(section) };
                count += 1;
                if (count == self.window) {
                    try self.buildClassifications(reads[0..count], index);
                    for (results[0..count], locations[0..count]) |result, location| applySummary(&output[location.column], location.section, result, index);
                    count = 0;
                }
            }
        }
        if (count != 0) {
            try self.buildClassifications(reads[0..count], index);
            for (results[0..count], locations[0..count]) |result, location| applySummary(&output[location.column], location.section, result, index);
        }
    }

    fn applySummary(summary: *classification.ColumnSummary, section: u5, result: encoding.Classification, index: *const classification.Index) void {
        if (result == .unavailable) return;
        const value = result.summary;
        const bit = @as(u32, 1) << section;
        summary.known |= bit;
        summary.common[section] = value.common;
        summary.prefix_bytes = if (index.codec) |codec| codec.prefix_bytes else 0;
        if (value.prefix_len != 0) {
            summary.prefixed |= bit;
            @memcpy(summary.prefixes[section][0..value.prefix_len], value.prefix[0..value.prefix_len]);
        }
    }

    fn chunksKey(column: classification.Column, offset: i32) [16]u8 {
        var key: [16]u8 = undefined;
        std.mem.writeInt(u32, key[0..4], column.world, .big);
        std.mem.writeInt(i32, key[4..8], column.x, .big);
        std.mem.writeInt(i32, key[8..12], column.z, .big);
        std.mem.writeInt(i32, key[12..16], column.minimum + offset, .big);
        return key;
    }

    fn findClassification(self: *const Store, properties: []const u8, selected: u8) ?*const classification.Index {
        var cursor = self.classification_indices;
        while (cursor) |index| : (cursor = index.next) {
            if (index.properties.ptr == properties.ptr and index.properties.len == properties.len and index.selected == selected) return index;
        }
        return null;
    }

    fn summarizeCached(self: *Store, columns: []const classification.Column, output: []classification.ColumnSummary, properties: []const u8, selected: u8) !void {
        std.debug.assert(columns.len == output.len and columns.len <= classification.column_batch_max);
        @memset(output, .{});
        if (columns.len == 0) return;
        const index = find: {
            var cursor = self.classification_indices;
            while (cursor) |entry| : (cursor = entry.next) {
                if (entry.properties.ptr == properties.ptr and entry.properties.len == properties.len and entry.selected == selected) break :find entry;
            }
            return;
        };
        const read_lease = self.acquireRead();
        defer read_lease.end();
        const workspace = read_lease.workspace;
        const prefix: usize = if (index.codec) |codec| codec.prefix_bytes else 0;
        var mapping: [classification.column_batch_max][32]u8 = undefined;
        var batch: classification.Header.Batch = .{};
        for (columns, 0..) |column, column_index| {
            std.debug.assert(column.count > 0 and column.count <= 32);
            var offset: usize = 0;
            while (offset < column.count) {
                const y = try std.math.add(i32, column.minimum, @intCast(offset));
                var section_key: [16]u8 = undefined;
                std.mem.writeInt(u32, section_key[0..4], column.world, .big);
                std.mem.writeInt(i32, section_key[4..8], column.x, .big);
                std.mem.writeInt(i32, section_key[8..12], column.z, .big);
                std.mem.writeInt(i32, section_key[12..16], y, .big);
                try batch.append(&section_key);
                const end = @min(column.count, offset + classification.Header.sections - classification.Header.part(&section_key));
                @memset(mapping[column_index][offset..end], batch.mapping[batch.count - 1]);
                offset = end;
            }
        }
        var headers: [192]classification.Header.View = undefined;
        {
            const timing = self.classification_reading.start();
            defer timing.end();
            self.derived_tables.lockSharedUncancelable(self.io);
            defer self.derived_tables.unlockShared(self.io);
            const use = self.derived.use();
            defer use.end();
            if (!self.derivedCurrent(use)) return;
            for (batch.keys[0..batch.unique], 0..) |key, slot| {
                workspace.classification_keys[slot] = key;
                workspace.overlays[slot] = .{ .key = &workspace.classification_keys[slot], .destination = workspace.classifications[slot * self.classification_bytes ..][0..classification.Header.size(prefix)] };
            }
            try self.stampClassificationKeys(workspace.classification_keys[0..batch.unique]);
            try index.table.getBatch(workspace.overlays[0..batch.unique], workspace.lengths[0..batch.unique]);
            self.classification_header_reads.add(batch.unique);
            for (workspace.lengths[0..batch.unique], headers[0..batch.unique], 0..) |length, *header, slot| {
                header.* = if (length) |n| try classification.Header.read(workspace.classifications[slot * self.classification_bytes ..][0..n], prefix) else .{};
            }
        }
        for (columns, output, 0..) |column, *summary, column_index| {
            summary.prefix_bytes = @intCast(prefix);
            for (0..column.count) |offset| {
                const header = &headers[mapping[column_index][offset]];
                const part: usize = @intCast(@mod(@as(i64, column.minimum) + @as(i64, @intCast(offset)), classification.Header.sections));
                const stored = @as(u32, 1) << @intCast(part);
                const bit = @as(u32, 1) << @intCast(offset);
                if (header.missing & stored != 0) summary.missing |= bit;
                if (header.known & stored == 0) continue;
                summary.known |= bit;
                summary.common[offset] = header.commonAt(@intCast(part));
                if (prefix != 0 and header.stored & stored != 0) {
                    summary.prefixed |= bit;
                    @memcpy(summary.prefixes[offset][0..prefix], header.prefixAt(@intCast(part), prefix));
                }
            }
        }
    }

    pub fn classify(self: *Store, reads: []const ClassificationRead, properties: []const u8, selected: u8) !void {
        self.derived_mutex.lockUncancelable(self.io);
        defer self.derived_mutex.unlock(self.io);
        std.debug.assert(reads.len <= 192 and std.math.isPowerOfTwo(selected));
        for (reads) |read| {
            std.debug.assert(read.projection == .full or read.prepared == null);
            if (read.prepared) |prepared| prepared.length = 0;
        }
        var cursor = self.classification_indices;
        while (cursor) |index| : (cursor = index.next) {
            if (index.properties.ptr == properties.ptr and index.properties.len == properties.len and index.selected == selected) {
                const generation = self.derived.generation.load(.acquire);
                self.classifyIndexed(reads, index) catch |err| {
                    self.failDerivedSince(err, generation);
                    var begin: usize = 0;
                    while (begin < reads.len) {
                        const end = @min(reads.len, begin + self.window);
                        try self.buildClassifications(reads[begin..end], index);
                        begin = end;
                    }
                };
                return;
            }
        }
        return self.classifyUnindexed(reads, properties, selected);
    }

    fn classifyIndexed(self: *Store, reads: []const ClassificationRead, index: *const classification.Index) !void {
        const read_lease = self.acquireRead();
        const workspace = read_lease.workspace;
        var missing: [192]ClassificationRead = undefined;
        var count: usize = 0;
        {
            defer read_lease.end();
            var decoder: ?compressed.Backend.ReadLease = null;
            defer if (decoder) |held| held.end();
            var begin: usize = 0;
            while (begin < reads.len) {
                const offered = @min(reads.len - begin, workspace.overlays.len / 2);
                var planned: classification.Header.Batch = .{};
                const batch = &planned;
                for (reads[begin..][0..offered]) |read| try batch.append(read.key);
                const prefix: usize = if (index.codec) |extra| extra.prefix_bytes else 0;
                var total = batch.unique;
                var outputs: [192]usize = undefined;
                for (batch.keys[0..batch.unique], 0..) |key, group| {
                    workspace.classification_keys[group] = key;
                    workspace.overlays[group] = .{ .key = &workspace.classification_keys[group], .destination = workspace.classifications[group * self.classification_bytes ..][0..classification.Header.size(prefix)] };
                }
                for (reads[begin..][0..batch.count], 0..) |read, position| {
                    if (read.projection != .full) continue;
                    const out = total;
                    outputs[position] = out;
                    total += 1;
                    workspace.classification_keys[out] = index.key(read.key);
                    workspace.overlays[out] = .{ .key = &workspace.classification_keys[out], .destination = workspace.classifications[out * self.classification_bytes ..][0..self.classification_bytes] };
                }
                std.debug.assert(total <= batch.unique + batch.count);
                {
                    const reading = self.classification_reading.start();
                    defer reading.end();
                    self.derived_tables.lockSharedUncancelable(self.io);
                    defer self.derived_tables.unlockShared(self.io);
                    const use = self.derived.use();
                    defer use.end();
                    // An absent cache knows no section, so every one is built below.
                    if (self.derivedCurrent(use)) {
                        try self.stampClassificationKeys(workspace.classification_keys[0..total]);
                        try index.table.getBatch(workspace.overlays[0..total], workspace.lengths[0..total]);
                    } else @memset(workspace.lengths[0..total], null);
                }
                const decoding = self.classification_decoding.start();
                defer decoding.end();
                for (reads[begin..][0..batch.count], 0..) |read, position| {
                    const group = batch.mapping[position];
                    const header: classification.Header.View = if (workspace.lengths[group]) |n|
                        try classification.Header.read(workspace.classifications[group * self.classification_bytes ..][0..n], prefix)
                    else
                        .{};
                    const part = batch.parts[position];
                    const bit = @as(u32, 1) << @intCast(part);
                    if (header.known & bit == 0) {
                        read.result.* = .unavailable;
                        if (header.missing & bit == 0) {
                            missing[count] = read;
                            count += 1;
                        }
                        continue;
                    }
                    if (read.projection != .full) {
                        read.result.* = .{ .summary = .{ .common = header.commonAt(part), .property = index.selected } };
                        if (read.projection == .prefix and header.stored & bit != 0) {
                            @memcpy(read.result.summary.prefix[0..prefix], header.prefixAt(@intCast(part), prefix));
                            read.result.summary.prefix_len = @intCast(prefix);
                        }
                        continue;
                    }
                    if (header.stored & bit == 0) {
                        read.result.* = .{ .known = .{ .common = header.commonAt(part), .property = index.selected, .selected = @splat(if (header.commonAt(part) & index.selected != 0) std.math.maxInt(u64) else 0) } };
                        continue;
                    }
                    const out = outputs[position];
                    const n = workspace.lengths[out] orelse return error.Corrupt;
                    if (n < 3) return error.Corrupt;
                    const record = workspace.classifications[out * self.classification_bytes ..][0..n];
                    if (record[0] > 1) return error.Corrupt;
                    var raw: []const u8 = record[1..];
                    if (record[0] == 1) {
                        if (decoder == null) decoder = self.bases.backend.borrowRead();
                        raw = try decoder.?.decode(raw, workspace.classification_raw);
                        self.classification_decoded_bytes.add(raw.len);
                    }
                    read.result.* = try index.decode(&workspace.classification_keys[out], raw, read.prepared);
                    if (read.result.known.common != header.commonAt(part)) return error.Corrupt;
                }
                begin += batch.count;
            }
        }
        var begin: usize = 0;
        while (begin < count) {
            const end = @min(count, begin + self.window);
            try self.buildClassifications(missing[begin..end], index);
            begin = end;
        }
    }

    fn classifyUnindexed(self: *Store, reads: []const ClassificationRead, properties: []const u8, selected: u8) !void {
        var requests: [192]records.Get = undefined;
        var lengths: [192]?usize = undefined;
        for (reads, requests[0..reads.len]) |read, *request| {
            request.* = .{ .key = read.key, .destination = &.{} };
        }
        try self.readBatch(requests[0..reads.len], lengths[0..reads.len], .classification, .{ .table = properties, .selected = selected, .reads = reads }, null);
    }

    fn readBatch(self: *Store, requests: []const records.Get, lengths: []?usize, comptime projection: Projection, properties: Properties, snapshot: ?*Snapshot) !void {
        if (requests.len != lengths.len) return error.InvalidArgument;
        const read_lease = self.acquireRead();
        defer read_lease.end();
        const workspace = read_lease.workspace;
        var begin: usize = 0;
        while (begin < requests.len) {
            const offered: usize = @min(self.window, requests.len - begin);
            const input = &workspace.input;
            for (requests[begin..][0..offered], input[0..offered]) |request, *key| key.* = request.key;
            const batch = &workspace.batch;
            batch.count = 0;
            batch.unique = 0;
            try batch.plan(input[0..offered], self.bases.capacity, self.side, 0);
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
            const lease = held[group];
            const layout = &self.layouts[lease.index];
            std.debug.assert(layout.generation == lease.generation and layout.revision == lease.revision());
            const locations = layout.locations[0..self.section_count];
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
                    classified.result.* = .{ .known = try encoding.classify(encoded, properties.table, properties.selected) };
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
                    if (record.len < 2) return error.Corrupt;
                    const header: OverlayHeader = @bitCast(record[0]);
                    if (header.kind != .patch) return error.Corrupt;
                    const states = &workspace.states;
                    const biomes = &workspace.biomes;
                    const has_biomes = if (size != 0) try decodeStates(bytes.?[location.begin..location.end], states, biomes, &workspace.raw) else empty: {
                        @memset(states, 0);
                        @memset(biomes, 0);
                        break :empty false;
                    };
                    const payload = if (header.compressed) try scratch.decode(record[1..], &workspace.patch_bytes) else record[1..];
                    const loaded = try patch.Patch.decode(payload, if (bytes) |base| std.mem.readInt(u64, base[0..8], .little) else 1, states, biomes);
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
            const reservation = try self.bases.reserveMany(keys, held, &workspace.victims, self.bases.physical_capacity);
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
            const keys_loading = &workspace.keys;
            const fills = &workspace.fills;
            const sizes = &workspace.sizes;
            var loading: usize = 0;
            var waiting = false;
            for (held) |lease| {
                if (loading == self.bases.backend.capacity) break;
                const entry = &self.bases.entries[lease.index];
                if (entry.loaded) continue;
                if (entry.filling) {
                    waiting = true;
                    continue;
                }
                fills[loading] = lease.reserve();
                keys_loading[loading] = lease.key();
                loading += 1;
            }
            if (loading == 0) {
                if (!waiting) break;
                self.available.waitUncancelable(self.io, &self.mutex);
                continue;
            }
            self.mutex.unlock(self.io);
            const source = self.bases.backend.borrowRead();
            defer source.end();
            const result = blk: {
                self.table_lock.lockSharedUncancelable(self.io);
                defer self.table_lock.unlockShared(self.io);
                break :blk source.readFrames(keys_loading[0..loading], sizes[0..loading]);
            };
            self.mutex.lockUncancelable(self.io);
            var published = false;
            defer if (!published) {
                for (fills[0..loading]) |fill| fill.cancel();
                self.available.broadcast(self.io);
            };
            result catch |err| {
                self.bases.failed = true;
                return err;
            };
            for (fills[0..loading], sizes[0..loading], 0..) |*fill, size, index| {
                const length = size orelse continue;
                const required = try zstandard.decodedBound(source.frame(index, length), self.group_bytes);
                while (true) {
                    switch (try fill.prepare(required, &workspace.victims)) {
                        .ready => break,
                        .writeback => |dirty| {
                            if (!writer) {
                                for (dirty) |lease| lease.release();
                                return error.WritebackRequired;
                            }
                            try self.writeTilesLocked(dirty);
                        },
                        .blocked => {
                            if (!(self.readers > @intFromBool(!writer) or (!writer and self.writing))) return error.CachePinned;
                            self.available.waitUncancelable(self.io, &self.mutex);
                        },
                    }
                }
            }
            self.mutex.unlock(self.io);
            const decoded = decode: {
                const timing = self.bases.backend.decoding.start();
                defer timing.end();
                var decoded_bytes: usize = 0;
                for (fills[0..loading], sizes[0..loading], 0..) |fill, *size, index| {
                    const length = size.* orelse continue;
                    const bytes = source.decode(source.frame(index, length), fill.bytes) catch |err| break :decode err;
                    size.* = bytes.len;
                    decoded_bytes += bytes.len;
                }
                self.bases.backend.decoded_bytes.add(decoded_bytes);
                break :decode @as(anyerror!void, {});
            };
            self.mutex.lockUncancelable(self.io);
            decoded catch |err| {
                self.bases.failed = true;
                return err;
            };
            var completed: usize = 0;
            for (fills[0..loading], sizes[0..loading], 0..) |fill, length, index| {
                if (source.completed(index)) {
                    fill.load(length);
                    completed += 1;
                } else fill.cancel();
            }
            std.debug.assert(completed > 0 and completed <= loading);
            published = true;
            self.bases.metrics.reads.add(completed);
            self.available.broadcast(self.io);
        }
        self.prepareLayouts(held) catch |err| {
            self.bases.failed = true;
            return err;
        };
        var cursor = self.group_windows;
        while (cursor) |window| : (cursor = window.next) {
            for (held) |lease| window.retain(lease);
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
            try batch.plan(input[0..offered], self.bases.capacity, self.side, 0);
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
            try self.reserveBaseWrites(writes[begin..][0..count], batch, held);
            const staging = self.bases.backend.beginStaging(.patches);
            defer staging.end();
            std.debug.assert(staging.bytes.len >= count * overlay_bytes);
            const overlay_writes = &self.writer.overlays;
            var overlay_count: usize = 0;
            for (leases[0..batch.unique], 0..) |lease, group| {
                const old = lease.read();
                const base_generation = if (old) |bytes| std.mem.readInt(u64, bytes[0..8], .little) else 1;
                const parts = &self.writer.parts;
                const locations = &self.writer.locations;
                const replaced = &self.writer.replaced;
                @memset(replaced, false);
                const layout = &self.layouts[lease.index];
                std.debug.assert(layout.generation == lease.generation and layout.revision == lease.revision());
                @memcpy(locations[0..self.section_count], layout.locations[0..self.section_count]);
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
                    const output = staging.bytes[overlay_count * overlay_bytes ..][0..overlay_bytes];
                    overlay_writes[overlay_count] = .{ .key = write.key, .value = null };
                    // A borrowed group stays immutable. Missing sections can be patched from zero.
                    // Whether it is borrowed was settled when room was reserved. The other
                    // holder may have let go since, and a group that was not given room then
                    // must not grow now.
                    if (original.len != 0 or self.writer.borrowed[group]) {
                        if (value.len == 0) {
                            output[0] = 0;
                            overlay_writes[overlay_count].value = output[0..1];
                        } else {
                            const before = &self.writer.before;
                            const after = &self.writer.after;
                            const old_biomes = &self.writer.old_biomes;
                            const new_biomes = &self.writer.new_biomes;
                            const old_has_biomes = if (original.len != 0) try decodeStates(original, before, old_biomes, &self.writer.raw) else empty: {
                                @memset(before, 0);
                                @memset(old_biomes, 0);
                                break :empty false;
                            };
                            const new_has_biomes = try decodeStates(value, after, new_biomes, &self.writer.raw);
                            var changes: patch.Patch = .{};
                            for (before, after, 0..) |a, b, index| {
                                if (a == b) continue;
                                changes.words[index / 64] |= @as(u64, 1) << @intCast(index % 64);
                                changes.count += 1;
                            }
                            changes.biomes = new_has_biomes and (!old_has_biomes or !std.mem.eql(u16, old_biomes, new_biomes));
                            if (changes.count != 0 or changes.biomes or original.len == 0) {
                                var header: OverlayHeader = .{ .kind = .patch, .biomes = new_has_biomes };
                                const encoded = try changes.encode(after, new_biomes, base_generation, self.scratch);
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
                std.debug.assert(self.bases.entries[lease.index].pins == 1);
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
                std.debug.assert(length <= self.bases.value_storage.buffer(self.bases.values, self.bases.value_bytes, lease.index).len);
                const bytes = lease.edit();
                std.mem.writeInt(u64, bytes[0..8], base_generation, .little);
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
                self.updateRevisions(writes[begin..][0..count]) catch |err| break :blk err;
                break :blk {};
            };
            self.mutex.lockUncancelable(self.io);
            try overlay_result;
            begin += count;
        }
    }

    fn reserveBaseWrites(self: *Store, writes: []const records.Write, batch: *const Batch, held: []const GroupCache.Lease) !void {
        std.debug.assert(self.writing);
        // Every group is judged before any wait. A wait lets other holders release, and
        // a group passed over here would then look free to write in place.
        for (held, self.writer.borrowed[0..held.len]) |lease, *borrowed| borrowed.* = self.bases.entries[lease.index].pins != 1;
        for (held, 0..) |lease, group| {
            if (self.writer.borrowed[group]) continue;
            const old = lease.read();
            const locations = self.layouts[lease.index].locations[0..self.section_count];
            var length = if (old) |bytes| bytes.len else self.header_bytes;
            var added: u64 = 0;
            var member = batch.first[group];
            while (member != Batch.absent) {
                const position = member;
                member = batch.next[position];
                const value = writes[position].value orelse continue;
                if (value.len == 0) continue;
                if (value.len > section_bytes or !encoding.valid(value)) return error.InvalidArgument;
                const part = batch.addresses[position].part;
                const bit = @as(u64, 1) << @intCast(part);
                if (added & bit != 0 or locations[part].begin != locations[part].end) continue;
                length += value.len;
                added |= bit;
            }
            if (added == 0) continue;
            if (length <= self.bases.value_storage.buffer(self.bases.values, self.bases.value_bytes, lease.index).len) continue;
            if (old) |bytes| @memcpy(self.scratch[0..bytes.len], bytes);
            while (true) {
                switch (try self.bases.reserveValue(lease, length, &self.writer.eviction)) {
                    .ready => break,
                    .writeback => |dirty| try self.writeTilesLocked(dirty),
                    .blocked => {
                        if (self.readers == 0) return error.CachePinned;
                        self.available.waitUncancelable(self.io, &self.mutex);
                    },
                }
            }
            if (old) |bytes| @memcpy(self.bases.value_storage.buffer(self.bases.values, self.bases.value_bytes, lease.index)[0..bytes.len], self.scratch[0..bytes.len]);
        }
    }

    fn buildClassifications(self: *Store, reads: []const ClassificationRead, index: *const classification.Index) !void {
        std.debug.assert(reads.len > 0 and reads.len <= self.window);
        var requests: [192]records.Get = undefined;
        var lengths: [192]?usize = undefined;
        var keys: [192][classification.key_bytes]u8 = undefined;
        for (reads, requests[0..reads.len], keys[0..reads.len], 0..) |read, *request, *key, position| {
            key.* = index.key(read.key);
            request.* = .{ .key = read.key, .destination = self.writer.classification_source[position * section_bytes ..][0..section_bytes] };
            read.result.* = .unavailable;
        }
        try self.stampClassificationKeys(keys[0..reads.len]);
        try self.getBatch(requests[0..reads.len], lengths[0..reads.len]);
        self.derived_tables.lockUncancelable(self.io);
        defer self.derived_tables.unlock(self.io);
        var current: [192][classification.key_bytes]u8 = undefined;
        @memcpy(current[0..reads.len], keys[0..reads.len]);
        try self.stampClassificationKeys(current[0..reads.len]);
        var planned: classification.Header.Batch = .{};
        for (reads) |read| try planned.append(read.key);
        const prefix: usize = if (index.codec) |extra| extra.prefix_bytes else 0;
        const groups = planned.unique;
        for (planned.keys[0..groups], 0..) |key, group| {
            self.writer.classification_keys[group] = key;
            self.writer.classification_reads[group] = .{ .key = &self.writer.classification_keys[group], .destination = &self.writer.classification_headers[group] };
        }
        // A header takes the revision its records were just stamped with. Reading it
        // again could find a newer one, and the header would then vouch at that
        // revision for records written under the older.
        for (current[0..reads.len], 0..) |*stamped, position| {
            @memcpy(self.writer.classification_keys[planned.mapping[position]][17..], stamped[17..]);
        }
        const derived = self.beginDerivedWrite();
        defer if (derived) |use| use.end();
        @memset(self.writer.classification_lengths[0..groups], null);
        if (derived) |use| index.table.getBatch(self.writer.classification_reads[0..groups], self.writer.classification_lengths[0..groups]) catch |err| {
            self.failDerived(use, err);
            @memset(self.writer.classification_lengths[0..groups], null);
        };
        const headers = self.writer.classification_decoded;
        for (headers[0..groups], 0..) |*header, group| {
            header.* = if (self.writer.classification_lengths[group]) |n| classification.Header.decode(self.writer.classification_headers[group][0..n], prefix) catch |err| invalid: {
                self.failDerived(derived.?, err);
                break :invalid .{};
            } else .{};
        }
        var total = groups;
        for (reads, lengths[0..reads.len], keys[0..reads.len], current[0..reads.len], 0..) |read, length, before, after, position| {
            if (!std.mem.eql(u8, &before, &after)) continue;
            const part = planned.parts[position];
            const header = &headers[planned.mapping[position]];
            const bit = @as(u32, 1) << part;
            const n = length orelse {
                header.known &= ~bit;
                header.stored &= ~bit;
                header.missing |= bit;
                continue;
            };
            const projected = try index.encode(&before, requests[position].destination[0..n], self.writer.classifications[position * self.classification_bytes ..][0..self.classification_bytes]);
            read.result.* = try index.decode(&before, projected.raw, read.prepared);
            if (read.projection != .full) read.result.* = .{ .summary = .{ .common = projected.common, .property = index.selected, .prefix_len = if (read.projection == .prefix) @intCast(projected.prefix.len) else 0 } };
            if (read.projection == .prefix) @memcpy(read.result.summary.prefix[0..projected.prefix.len], projected.prefix);
            header.missing &= ~bit;
            header.known |= bit;
            header.stored &= ~bit;
            header.common[part] = projected.common;
            @memset(&header.prefixes[part], 0);
            @memcpy(header.prefixes[part][0..projected.prefix.len], projected.prefix);
            if (projected.stored) {
                header.stored |= bit;
                self.writer.classification_keys[total] = before;
                self.writer.classification_writes[total] = .{ .key = &self.writer.classification_keys[total], .value = projected.bytes };
                total += 1;
            }
        }
        for (headers[0..groups], 0..) |header, group| {
            const encoded = header.encode(&self.writer.classification_headers[group], prefix);
            self.writer.classification_writes[group] = .{ .key = &self.writer.classification_keys[group], .value = if (header.known | header.missing != 0) encoded else null };
        }
        if (derived) |use| if (use.ready()) {
            // A column classified for the first time at this revision has left records
            // behind under its older ones.
            for (0..groups) |group| {
                if (self.writer.classification_lengths[group] != null) continue;
                const key = &self.writer.classification_keys[group];
                if (group != 0 and std.mem.eql(u8, key[1..13], self.writer.classification_keys[group - 1][1..13])) continue;
                self.dropSupersededClassifications(index, use, key);
            }
            index.table.putBatch(self.writer.classification_writes[0..total]) catch |err| self.failDerived(use, err);
            self.commitDerived(use);
        };
    }

    /// Deletes what an index holds for other revisions of a column. `current` is any
    /// classification key of the column, stamped with its revision now. Readers stamp
    /// their keys with the current revision, so a record of another one is never read
    /// again and would only stay in the file until the file is full.
    fn dropSupersededClassifications(self: *Store, index: *const classification.Index, use: storage.DiskCache.Use, current: *const [classification.key_bytes]u8) void {
        var storage_keys: [32][64]u8 = undefined;
        var entries: [32]records.ScanKey = undefined;
        var writes: [32]records.Write = undefined;
        // Section records first, then the headers that list them.
        const section: [16]u8 = @splat(0);
        const kinds = [2]u8{ index.key(&section)[0], (classification.Header.key(&section) catch unreachable)[0] };
        for (kinds) |kind| {
            var after: [64]u8 = undefined;
            after[0] = kind;
            @memcpy(after[1..13], current[1..13]);
            var cursor: records.ScanCursor = .{ .after = &after, .after_len = 13 };
            while (true) {
                for (&storage_keys, &entries) |*key, *entry| entry.* = .{ .key = key };
                const result = index.table.scanKeys(&cursor, &entries) catch |err| return self.failDerived(use, err);
                var count: usize = 0;
                var more = result.more;
                for (entries[0..result.count]) |entry| {
                    if (entry.key_len != classification.key_bytes or entry.key[0] != kind or !std.mem.eql(u8, entry.key[1..13], current[1..13])) {
                        more = false;
                        break;
                    }
                    if (std.mem.eql(u8, entry.key[17..classification.key_bytes], current[17..])) continue;
                    writes[count] = .{ .key = entry.key[0..entry.key_len], .value = null };
                    count += 1;
                }
                if (count != 0) index.table.putBatch(writes[0..count]) catch |err| return self.failDerived(use, err);
                if (!more) break;
            }
        }
    }

    fn stampClassificationKeys(self: *Store, keys: [][classification.key_bytes]u8) !void {
        self.table_lock.lockSharedUncancelable(self.io);
        defer self.table_lock.unlockShared(self.io);
        std.debug.assert(keys.len <= records.Table.read_batch_size);
        var source: [192][13]u8 = undefined;
        var values: [192][8]u8 = undefined;
        var reads: [192]records.Get = undefined;
        var lengths: [192]?usize = undefined;
        for (keys, source[0..keys.len], reads[0..keys.len], values[0..keys.len]) |key, *column, *read, *value| {
            column[0] = 0;
            @memcpy(column[1..], key[1..13]);
            read.* = .{ .key = column, .destination = value };
        }
        try self.revisions.getBatch(reads[0..keys.len], lengths[0..keys.len]);
        for (keys, values[0..keys.len], lengths[0..keys.len]) |*key, value, length| {
            if (length) |n| {
                if (n != 8) return error.Corrupt;
                @memcpy(key[17..], &value);
            } else @memset(key[17..], 0);
        }
    }

    /// Whether this store's tables are rooted in the file `use` holds and may be touched.
    fn derivedCurrent(self: *const Store, use: storage.DiskCache.Use) bool {
        return use.ready() and use.generation == self.derived_generation;
    }

    /// Call with derived_tables held exclusively and no use open. Empties a damaged cache,
    /// roots this store's tables in the file being served, and returns a use to write under.
    /// Null means the cache was discarded.
    fn beginDerivedWrite(self: *Store) ?storage.DiskCache.Use {
        if (self.derived_unplaced) return null;
        // Each pass either returns or follows a reset, and resets are limited.
        while (true) {
            const use = self.derived.use();
            switch (self.derived.state.load(.acquire)) {
                .discarded => {
                    use.end();
                    return null;
                },
                .damaged => {
                    use.end();
                    const emptied = self.derived.reset() catch |err| {
                        self.reportDisabled(err);
                        return null;
                    };
                    if (!emptied) continue;
                    self.derived_resets.add(1);
                    std.log.warn("event=chunk_cache_reset resets={d} limit={d}", .{ self.derived.generation.load(.acquire), storage.DiskCache.resets_max });
                },
                .ready => {
                    if (use.generation == self.derived_generation) return use;
                    // Another store emptied the file, or this one has not opened it yet.
                    if (self.attachDerived(use)) |_| return use else |err| self.failDerived(use, err);
                    use.end();
                },
            }
        }
    }

    /// Roots this store's tables in the file `use` holds.
    fn attachDerived(self: *Store, use: storage.DiskCache.Use) !void {
        const space = self.lights.space;
        const root = root: {
            const id = try space.getRoot() orelse break :root try createDerivedRoot(space, self.derived_identity);
            var page: storage.Page = undefined;
            try space.readPages(&.{.{ .id = id, .destination = &page }});
            // Pages derived from another world or layout would stay in the file unreachable.
            if (!std.mem.eql(u8, page[0..8], derived_magic) or !std.mem.eql(u8, page[8..24], &self.derived_identity)) return error.Outdated;
            break :root id;
        };
        self.lights.directory = root;
        self.classifications.directory = root;
        var index = self.classification_indices;
        while (index) |value| : (index = value.next) try self.openClassification(value);
        try self.derived.publish();
        self.derived_generation = use.generation;
    }

    fn createDerivedRoot(space: storage.Space, identity: [16]u8) !storage.PageId {
        var ids: [1]storage.PageId = undefined;
        try space.allocatePages(&ids);
        var page: storage.Page = @splat(0);
        @memcpy(page[0..8], derived_magic);
        @memcpy(page[8..24], &identity);
        try space.writePages(&.{.{ .id = ids[0], .source = &page }});
        try space.setRoot(ids[0]);
        return ids[0];
    }

    /// Finds or creates this store's roots in the cache file being served.
    fn rootDerived(self: *Store) void {
        self.derived_tables.lockUncancelable(self.io);
        defer self.derived_tables.unlock(self.io);
        if (self.beginDerivedWrite()) |use| use.end();
    }

    /// Call inside the use the failure happened in. Every user treats a damaged file as
    /// empty until the next writer empties it.
    fn failDerived(self: *Store, use: storage.DiskCache.Use, err: anyerror) void {
        // A full device or page limit would only fill up again.
        if (err == error.NoSpace) return self.disableDerived(err);
        if (use.damage()) std.log.warn("event=chunk_cache_damaged reason={t}", .{err});
    }

    /// Reports a failure noticed after its use ended. A file emptied since `generation`
    /// was read is not the one that failed.
    fn failDerivedSince(self: *Store, err: anyerror, generation: u32) void {
        const use = self.derived.use();
        defer use.end();
        if (use.generation == generation) self.failDerived(use, err);
    }

    fn disableDerived(self: *Store, err: anyerror) void {
        const first = self.derived.discard() catch |failure| first: {
            std.log.warn("event=chunk_cache_discard_failed reason={t}", .{failure});
            break :first true;
        };
        if (first) self.reportDisabled(err);
    }

    fn reportDisabled(self: *Store, err: anyerror) void {
        self.derived_disables.add(1);
        std.log.warn("event=chunk_cache_disabled reason={t}", .{err});
    }

    fn commitDerived(self: *Store, use: storage.DiskCache.Use) void {
        if (!use.ready()) return;
        self.derived.publish() catch |err| self.failDerived(use, err);
    }

    fn updateRevisions(self: *Store, writes: []const records.Write) !void {
        const keys = &self.writer.revision_keys;
        const output = &self.writer.revision_writes;
        var buckets: [std.math.ceilPowerOfTwoAssert(usize, records.Table.write_batch_size * 2)]u16 = @splat(std.math.maxInt(u16));
        var mapping: [192]usize = undefined;
        var count: usize = 0;
        for (writes, mapping[0..writes.len]) |write, *slot| {
            var key: [13]u8 = undefined;
            key[0] = 0;
            @memcpy(key[1..], write.key[0..12]);
            _ = insertRevisionKey(keys, &count, &buckets, &key);
            var bucket: usize = @intCast(std.hash.Wyhash.hash(0, &key) & (buckets.len - 1));
            while (!std.mem.eql(u8, &keys[buckets[bucket]], &key)) bucket = (bucket + 1) & (buckets.len - 1);
            slot.* = buckets[bucket];
        }
        var values: [192][8]u8 = undefined;
        var reads: [192]records.Get = undefined;
        var lengths: [192]?usize = undefined;
        for (keys[0..count], values[0..count], reads[0..count]) |*key, *value, *read| read.* = .{ .key = key, .destination = value };
        try self.revisions.getBatch(reads[0..count], lengths[0..count]);
        for (values[0..count], lengths[0..count]) |*value, length| {
            if (length) |n| {
                if (n != 8) return error.Corrupt;
            } else @memset(value, 0);
        }
        for (writes, mapping[0..writes.len]) |write, slot| {
            var hash = std.crypto.hash.Blake3.init(.{});
            hash.update(&values[slot]);
            hash.update(write.key);
            var size: [8]u8 = undefined;
            std.mem.writeInt(u64, &size, if (write.value) |value| value.len else std.math.maxInt(u64), .little);
            hash.update(&size);
            if (write.value) |value| hash.update(value);
            hash.final(&values[slot]);
        }
        for (keys[0..count], values[0..count], output[0..count]) |*key, *value, *entry| entry.* = .{ .key = key, .value = value };
        try self.revisions.putBatch(output[0..count]);
    }

    fn insertRevisionKey(keys: *[revision_batch_max][13]u8, count: *usize, buckets: []u16, key: *const [13]u8) bool {
        std.debug.assert(std.math.isPowerOfTwo(buckets.len));
        var bucket: usize = @intCast(std.hash.Wyhash.hash(0, key) & (buckets.len - 1));
        while (buckets[bucket] != std.math.maxInt(u16)) : (bucket = (bucket + 1) & (buckets.len - 1)) {
            if (std.mem.eql(u8, &keys[buckets[bucket]], key)) return false;
        }
        std.debug.assert(count.* < keys.len);
        keys[count.*] = key.*;
        buckets[bucket] = @intCast(count.*);
        count.* += 1;
        return true;
    }

    pub fn lightDependencies(self: *Store, input: []const light.Request, snapshots: []light.Dependencies) !void {
        std.debug.assert(input.len == snapshots.len and input.len <= light.dependency_batch_max);
        self.table_lock.lockSharedUncancelable(self.io);
        defer self.table_lock.unlockShared(self.io);
        try self.readLightDependencies(input, snapshots);
    }

    fn readLightDependencies(self: *Store, input: []const light.Request, snapshots: []light.Dependencies) !void {
        std.debug.assert(input.len == snapshots.len and input.len <= light.dependency_batch_max);
        var keys: [192][13]u8 = undefined;
        var values: [192][8]u8 = undefined;
        var reads: [192]records.Get = undefined;
        var lengths: [192]?usize = undefined;
        var count: usize = 0;
        for (input) |entry| for (try entry.column.neighbors()) |neighbor| {
            keys[count] = neighbor.key(.revision);
            reads[count] = .{ .key = &keys[count], .destination = &values[count] };
            count += 1;
        };
        try self.revisions.getBatch(reads[0..count], lengths[0..count]);
        for (snapshots, 0..) |*snapshot, column| for (&snapshot.revisions, 0..) |*revision, neighbor| {
            const offset = column * 9 + neighbor;
            revision.* = 0;
            if (lengths[offset]) |length| {
                if (length != 8) return error.Corrupt;
                revision.* = std.mem.readInt(u64, &values[offset], .little);
            }
        };
    }

    pub fn lightFrames(self: *Store, input: []const light.Request, output: *light.FrameBatch) !void {
        return self.deliveryFrames(input, output, null);
    }

    pub fn deliveryFrames(self: *Store, input: []const light.Request, output: *light.FrameBatch, additional: ?*delivery.ReadBatch) !void {
        std.debug.assert(input.len <= light.frame_batch_max and input.len == output.frames.len and input.len == output.complete.len and input.len == output.clean.len);
        output.used = 0;
        const extra: usize = if (additional) |batch| batch.keys.len else 0;
        std.debug.assert(@max(input.len, extra) <= records.Table.read_batch_size);
        if (@max(input.len, extra) == 0) {
            if (additional) |batch| batch.submitted = true;
            return;
        }
        const read_lease = self.acquireRead();
        defer read_lease.end();
        const workspace = read_lease.workspace;
        for (input, workspace.input[0..input.len], workspace.classification_keys[0..input.len]) |request, *key, *bytes| {
            @memcpy(bytes[0..13], &request.column.key(.light));
            key.* = bytes[0..13];
        }
        var read_batch: records.PackedRead = .{ .bytes = output.bytes, .values = output.frames, .complete = output.complete, .prefix_bytes = light.maximum_bytes + delivery.Column.header_size };
        const destination = if (additional) |batch| batch.output else &read_batch;
        if (additional) |batch| {
            std.debug.assert(!batch.submitted);
            for (batch.keys, workspace.input[0..extra]) |*key, *request| request.* = key;
        }
        const timing = self.light_reading.start();
        defer timing.end();
        self.derived_tables.lockSharedUncancelable(self.io);
        defer self.derived_tables.unlockShared(self.io);
        const use = self.derived.use();
        defer use.end();
        if (!self.derivedCurrent(use)) {
            @memset(destination.values, null);
            @memset(destination.complete, true);
        } else self.lights.getPacked(workspace.input[0..if (additional != null) extra else input.len], destination) catch |err| {
            if (err == error.BufferTooSmall) return err;
            self.failDerived(use, err);
            @memset(destination.values, null);
            @memset(destination.complete, true);
        };
        for (input, output.frames, output.complete, 0..) |request, *frame, *complete, index| {
            const slot = if (additional) |batch| found: {
                const key = request.column.key(.light);
                for (batch.keys, 0..) |candidate, slot| if (std.mem.eql(u8, &key, &candidate)) break :found slot;
                unreachable;
            } else index;
            complete.* = destination.complete[slot];
            const bytes = destination.values[slot];
            frame.* = if (bytes) |value| common: {
                const common_frame = delivery.Column.common(value) catch |err| {
                    if (err != error.Outdated) self.failDerived(use, err);
                    break :common null;
                };
                const column: light.Column = .{ .world = std.mem.readInt(u32, value[16..20], .little), .x = std.mem.readInt(i32, value[20..24], .little), .z = std.mem.readInt(i32, value[24..28], .little) };
                if (!std.meta.eql(column, request.column)) {
                    self.failDerived(use, error.Corrupt);
                    break :common null;
                }
                break :common common_frame;
            } else null;
        }
        var begin: usize = 0;
        while (begin < input.len) {
            const end = @min(input.len, begin + light.dependency_batch_max);
            var dependencies: [light.dependency_batch_max]light.Dependencies = undefined;
            try self.lightDependencies(input[begin..end], dependencies[0 .. end - begin]);
            for (output.frames[begin..end], dependencies[0 .. end - begin]) |*frame, dependency| {
                const bytes = frame.* orelse continue;
                const expected = light.Prefix.revisions(bytes) catch {
                    frame.* = null;
                    continue;
                };
                if (!std.mem.eql(u64, &expected, &dependency.revisions)) frame.* = null;
            }
            begin = end;
        }
        output.used = read_batch.used;
        std.debug.assert(output.used <= output.bytes.len);
        if (additional) |batch| batch.submitted = true;
    }

    pub fn lightPrefixes(self: *Store, input: []const light.PrefixRequest, snapshots: []light.PrefixSnapshot) !void {
        std.debug.assert(input.len == snapshots.len and input.len <= light.prefix_batch_max);
        if (input.len == 0) return;
        const read_lease = self.acquireRead();
        defer read_lease.end();
        const workspace = read_lease.workspace;
        const timing = self.light_reading.start();
        defer timing.end();
        self.derived_tables.lockSharedUncancelable(self.io);
        defer self.derived_tables.unlockShared(self.io);
        var begin: usize = 0;
        while (begin < input.len) {
            const end = @min(input.len, begin + light.dependency_batch_max);
            var requests: [light.dependency_batch_max]light.Request = undefined;
            var dependencies: [light.dependency_batch_max]light.Dependencies = undefined;
            for (input[begin..end], requests[0 .. end - begin]) |request, *query| query.* = .{ .column = request.column, .minimum = request.minimum, .count = request.count };
            try self.lightDependencies(requests[0 .. end - begin], dependencies[0 .. end - begin]);
            for (input[begin..end], dependencies[0 .. end - begin], begin..) |request, dependency, slot| {
                @memcpy(workspace.classification_keys[slot][0..21], &metadataKey(request.column, dependency.revisions));
                workspace.overlays[slot] = .{ .key = workspace.classification_keys[slot][0..21], .destination = request.destination };
            }
            begin = end;
        }
        const use = self.derived.use();
        defer use.end();
        if (!self.derivedCurrent(use)) {
            @memset(workspace.lengths[0..input.len], null);
        } else self.lights.prefixesBatch(workspace.overlays[0..input.len], workspace.lengths[0..input.len]) catch |err| {
            self.failDerived(use, err);
            @memset(workspace.lengths[0..input.len], null);
        };
        for (input, snapshots, workspace.lengths[0..input.len]) |request, *snapshot, length| {
            snapshot.length = length;
            if (length) |n| _ = light.Prefix.read(request.destination[0..n]) catch |err| {
                if (err != error.Outdated) self.failDerived(use, err);
                snapshot.length = null;
            };
        }
    }

    /// Deletes the light metadata a column has under other revisions of its
    /// neighbourhood than the one `keep` names. Readers build the key from the current
    /// revisions, so such a record is never read again.
    fn dropSupersededMetadata(self: *Store, use: storage.DiskCache.Use, keep: *const [21]u8) void {
        var storage_keys: [16][64]u8 = undefined;
        var entries: [16]records.ScanKey = undefined;
        var writes: [16]records.Write = undefined;
        var after: [64]u8 = undefined;
        @memcpy(after[0..13], keep[0..13]);
        var cursor: records.ScanCursor = .{ .after = &after, .after_len = 13 };
        while (true) {
            for (&storage_keys, &entries) |*key, *entry| entry.* = .{ .key = key };
            const result = self.lights.scanKeys(&cursor, &entries) catch |err| return self.failDerived(use, err);
            var count: usize = 0;
            var more = result.more;
            for (entries[0..result.count]) |entry| {
                if (entry.key_len != keep.len or !std.mem.eql(u8, entry.key[0..13], keep[0..13])) {
                    more = false;
                    break;
                }
                if (std.mem.eql(u8, entry.key[0..keep.len], keep)) continue;
                writes[count] = .{ .key = entry.key[0..entry.key_len], .value = null };
                count += 1;
            }
            if (count != 0) self.lights.putBatch(writes[0..count]) catch |err| return self.failDerived(use, err);
            if (!more) break;
        }
    }

    fn metadataKey(column: light.Column, revisions: [9]u64) [21]u8 {
        var key: [21]u8 = undefined;
        @memcpy(key[0..13], &column.key(.metadata));
        std.crypto.hash.Blake3.hash(std.mem.asBytes(&revisions), key[13..], .{});
        return key;
    }

    pub fn putDeliveryRecords(self: *Store, writes: []const records.Write) !void {
        std.debug.assert(writes.len <= records.Table.read_batch_size);
        if (writes.len == 0) return;
        for (writes) |write| {
            std.debug.assert(write.key.len == delivery.key_bytes and write.key[0] == 1);
            std.debug.assert(write.value != null);
            const column = try delivery.Column.read(write.value.?);
            if (column.frame.len == 0) return error.InvalidArgument;
            std.debug.assert(std.mem.eql(u8, write.key, &delivery.key(column.column)));
        }
        self.derived_tables.lockUncancelable(self.io);
        defer self.derived_tables.unlock(self.io);
        var begin: usize = 0;
        while (begin < writes.len) {
            const count: usize = @min(writes.len - begin, light.dependency_batch_max);
            var keys: [records.Table.read_batch_size][13]u8 = undefined;
            var values: [records.Table.read_batch_size][8]u8 = undefined;
            var requests: [records.Table.read_batch_size]records.Get = undefined;
            var lengths: [records.Table.read_batch_size]?usize = undefined;
            var expected: [light.dependency_batch_max][9]u64 = undefined;
            for (writes[begin..][0..count], 0..) |write, index| {
                const column: light.Column = .{ .world = std.mem.readInt(u32, write.key[1..5], .big), .x = std.mem.readInt(i32, write.key[5..9], .big), .z = std.mem.readInt(i32, write.key[9..13], .big) };
                const bundle = try delivery.Column.read(write.value.?);
                expected[index] = try light.Prefix.revisions(bundle.frame);
                for (try column.neighbors(), 0..) |neighbor, at| {
                    const slot = index * 9 + at;
                    keys[slot] = neighbor.key(.revision);
                    requests[slot] = .{ .key = &keys[slot], .destination = &values[slot] };
                }
            }
            {
                self.table_lock.lockSharedUncancelable(self.io);
                defer self.table_lock.unlockShared(self.io);
                try self.revisions.getBatch(requests[0 .. count * 9], lengths[0 .. count * 9]);
            }
            var accepted: [2 * light.dependency_batch_max]records.Write = undefined;
            var metadata_keys: [light.dependency_batch_max][21]u8 = undefined;
            var valid: usize = 0;
            for (writes[begin..][0..count], expected[0..count], 0..) |write, revisions, index| {
                const unchanged = for (revisions, 0..) |revision, at| {
                    const slot = index * 9 + at;
                    const actual = if (lengths[slot]) |length| value: {
                        if (length != 8) return error.Corrupt;
                        break :value std.mem.readInt(u64, &values[slot], .little);
                    } else 0;
                    if (actual != revision) break false;
                } else true;
                if (!unchanged) continue;
                accepted[valid] = write;
                valid += 1;
                const bundle = try delivery.Column.read(write.value.?);
                metadata_keys[index] = metadataKey(bundle.column, revisions);
                accepted[valid] = .{ .key = &metadata_keys[index], .value = bundle.frame[0..try light.Prefix.encodedLength(bundle.frame)] };
                valid += 1;
            }
            if (self.beginDerivedWrite()) |use| {
                defer use.end();
                // Every second accepted write is the metadata of the one before it.
                var written: usize = 1;
                while (written < valid) : (written += 2) self.dropSupersededMetadata(use, accepted[written].key[0..21]);
                self.lights.putBatch(accepted[0..valid]) catch |err| self.failDerived(use, err);
                self.commitDerived(use);
            }
            begin += count;
        }
    }

    pub fn savedLightColumns(self: *Store, cursor: *records.ScanCursor, output: []light.Column) !records.ScanResult {
        std.debug.assert(output.len > 0 and output.len <= records.Table.read_batch_size);
        var keys: [records.Table.read_batch_size][64]u8 = undefined;
        var entries: [records.Table.read_batch_size]records.ScanKey = undefined;
        for (keys[0..output.len], entries[0..output.len]) |*key, *entry| entry.* = .{ .key = key };
        if (cursor.after_len == 0) {
            std.debug.assert(cursor.after.len >= 13);
            cursor.after[0] = 1;
            cursor.after_len = 1;
        }
        self.derived_tables.lockSharedUncancelable(self.io);
        defer self.derived_tables.unlockShared(self.io);
        const use = self.derived.use();
        defer use.end();
        if (!self.derivedCurrent(use)) return .{ .count = 0, .more = false };
        const result = self.lights.scanKeys(cursor, entries[0..output.len]) catch |err| {
            self.failDerived(use, err);
            return .{ .count = 0, .more = false };
        };
        var count: usize = 0;
        for (entries[0..result.count]) |entry| {
            if (entry.key[0] != 1) return .{ .count = count, .more = false };
            if (entry.key_len != 13) return error.Corrupt;
            output[count] = .{ .world = std.mem.readInt(u32, entry.key[1..5], .big), .x = std.mem.readInt(i32, entry.key[5..9], .big), .z = std.mem.readInt(i32, entry.key[9..13], .big) };
            count += 1;
        }
        return .{ .count = count, .more = result.more };
    }

    pub fn putLight(self: *Store, column: light.Column, revisions: [9]u64, frame: []const u8) !bool {
        if (frame.len == 0) return error.InvalidArgument;
        self.derived_tables.lockUncancelable(self.io);
        defer self.derived_tables.unlock(self.io);
        var keys: [9][13]u8 = undefined;
        var values: [9][8]u8 = undefined;
        var requests: [9]records.Get = undefined;
        var lengths: [9]?usize = undefined;
        for (try column.neighbors(), &keys, &values, &requests) |neighbor, *key, *value, *request| {
            key.* = neighbor.key(.revision);
            request.* = .{ .key = key, .destination = value };
        }
        {
            self.table_lock.lockSharedUncancelable(self.io);
            defer self.table_lock.unlockShared(self.io);
            try self.revisions.getBatch(&requests, &lengths);
        }
        for (revisions, lengths, &values) |expected, length, *value| {
            const actual = if (length) |n| actual: {
                if (n != 8) return error.Corrupt;
                break :actual std.mem.readInt(u64, value, .little);
            } else 0;
            if (actual != expected) return false;
        }
        const key = column.key(.light);
        const metadata_key = metadataKey(column, revisions);
        const prefix_length = try light.Prefix.encodedLength(frame);
        var column_record = try delivery.Column.Builder.begin(self.writer.light_record, column, frame, 0);
        const use = self.beginDerivedWrite() orelse return false;
        defer use.end();
        self.dropSupersededMetadata(use, &metadata_key);
        self.lights.putBatch(&.{
            .{ .key = &key, .value = column_record.finish() },
            .{ .key = &metadata_key, .value = frame[0..prefix_length] },
        }) catch |err| {
            self.failDerived(use, err);
            return false;
        };
        self.commitDerived(use);
        return use.ready();
    }

    /// Columns one patched light read or write may name.
    pub const patched_batch_max = 64;

    /// Stores, replaces or with a null value deletes the patched light of several columns
    /// in the disposable cache, as one write. False when the cache took none of it.
    pub fn putPatchedLights(self: *Store, columns: []const light.Column, values: []const ?[]const u8) bool {
        std.debug.assert(columns.len == values.len and columns.len != 0 and columns.len <= patched_batch_max);
        var keys: [patched_batch_max][13]u8 = undefined;
        var writes: [patched_batch_max]records.Write = undefined;
        for (columns, values, keys[0..columns.len], writes[0..columns.len]) |column, value, *key, *write| {
            if (value) |bytes| std.debug.assert(bytes.len != 0 and bytes.len <= light.maximum_bytes);
            key.* = column.key(.patched);
            write.* = .{ .key = key, .value = value };
        }
        self.derived_tables.lockUncancelable(self.io);
        defer self.derived_tables.unlock(self.io);
        const use = self.beginDerivedWrite() orelse return false;
        defer use.end();
        self.lights.putBatch(writes[0..columns.len]) catch |err| {
            self.failDerived(use, err);
            return false;
        };
        self.commitDerived(use);
        return use.ready();
    }

    /// Reads the patched light of several columns into one buffer. A value is null when
    /// the cache holds none, also after the cache was emptied or dropped. A value the
    /// buffer had no room left for is null and not complete.
    pub fn patchedLights(self: *Store, columns: []const light.Column, output: *records.PackedRead) void {
        std.debug.assert(columns.len == output.values.len and columns.len == output.complete.len and columns.len != 0 and columns.len <= patched_batch_max);
        var keys: [patched_batch_max][13]u8 = undefined;
        var slices: [patched_batch_max][]const u8 = undefined;
        for (columns, keys[0..columns.len], slices[0..columns.len]) |column, *key, *slice| {
            key.* = column.key(.patched);
            slice.* = key;
        }
        output.used = 0;
        @memset(output.values, null);
        @memset(output.complete, true);
        self.derived_tables.lockSharedUncancelable(self.io);
        defer self.derived_tables.unlockShared(self.io);
        const use = self.derived.use();
        defer use.end();
        if (!self.derivedCurrent(use)) return;
        self.lights.getPacked(slices[0..columns.len], output) catch |err| {
            self.failDerived(use, err);
            @memset(output.values, null);
            @memset(output.complete, true);
        };
    }

    /// Deletes patched light records, a batch at a time. True while more may remain.
    /// Patched light describes blocks that may never have been saved, so what an earlier
    /// process left behind is deleted at startup.
    pub fn clearPatchedLights(self: *Store) bool {
        var keys: [patched_batch_max][64]u8 = undefined;
        var entries: [patched_batch_max]records.ScanKey = undefined;
        for (&keys, &entries) |*key, *entry| entry.* = .{ .key = key };
        // The scan leaves the last key it saw here, and keys of other kinds are longer.
        var after: [64]u8 = undefined;
        const kind = (light.Column{ .world = 0, .x = 0, .z = 0 }).key(.patched)[0];
        after[0] = kind;
        var cursor: records.ScanCursor = .{ .after = &after, .after_len = 1 };
        self.derived_tables.lockUncancelable(self.io);
        defer self.derived_tables.unlock(self.io);
        const use = self.beginDerivedWrite() orelse return false;
        defer use.end();
        const result = self.lights.scanKeys(&cursor, &entries) catch |err| {
            self.failDerived(use, err);
            return false;
        };
        var writes: [patched_batch_max]records.Write = undefined;
        var count: usize = 0;
        for (entries[0..result.count]) |entry| {
            if (entry.key[0] != kind) break;
            writes[count] = .{ .key = entry.key[0..entry.key_len], .value = null };
            count += 1;
        }
        if (count == 0) {
            self.commitDerived(use);
            return false;
        }
        self.lights.putBatch(writes[0..count]) catch |err| {
            self.failDerived(use, err);
            return false;
        };
        self.commitDerived(use);
        return use.ready() and count == result.count and result.more;
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
            if (!self.writing) for (self.merger.slots, 0..) |*slot, index| {
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
        defer self.endWrite(false);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.bases.failed) return error.FailedTransaction;
        while (self.bases.dirty_entries.count != 0) {
            const count = @min(self.bases.dirty_entries.count, self.bases.backend.capacity);
            const leases = self.writer.eviction[0..count];
            for (self.bases.dirty_entries.values()[0..count], leases) |slot, *lease| lease.* = self.bases.pin(slot);
            try self.writeTilesLocked(leases);
        }
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
            try batch.plan(input[begin..], capacity, 2, 0);
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
