const blob = @import("blob.zig");
const key_order = @import("key_order.zig");
const std = @import("std");
const storage = @import("storage");
const metrics = @import("metrics");

const assert = std.debug.assert;
const maximum_key = 64;
const node_header_size = 16;
const cell_header_size = 8;
const maximum_cells = (storage.page_size - node_header_size) / (cell_header_size + 1);
const maximum_depth = 16;
const maximum_batch = 192;
const maximum_sorted_batch = 4096;
const maximum_outputs = maximum_batch + 3;
const working_cells = maximum_cells * 3 + maximum_batch;
const inline_threshold = (storage.page_size - node_header_size) / 3 - cell_header_size - maximum_key;
const local_limit = (storage.page_size - node_header_size) * 2 / 3 - cell_header_size - maximum_key;
const maximum_local = storage.page_size - node_header_size - cell_header_size - maximum_key;
const node_version = 2;

const Direct = struct {
    pages: usize,
    prefix: usize,

    fn layout(length: usize, prefix: usize) Direct {
        assert(prefix <= length);
        const remaining = length - prefix;
        return .{ .pages = remaining / storage.page_size + @intFromBool(remaining % storage.page_size != 0), .prefix = prefix };
    }
    fn bytes(self: Direct) usize {
        return self.pages * 8 + self.prefix;
    }
};

const NodeBatch = struct {
    space: storage.Space,
    ids: *[storage.batch_size]storage.PageId,
    pages: *[storage.batch_size]storage.Page,
    count: usize = 0,

    fn read(self: *const NodeBatch, id: storage.PageId, destination: *storage.Page) storage.Error!void {
        try self.readMany(&.{.{ .id = id, .destination = destination }});
    }

    fn readMany(self: *const NodeBatch, reads: []const storage.Read) storage.Error!void {
        assert(reads.len <= storage.batch_size);
        var missing: [storage.batch_size]storage.Read = undefined;
        var count: usize = 0;
        for (reads) |request| {
            for (self.ids[0..self.count], self.pages[0..self.count]) |cached_id, *page| {
                if (cached_id == request.id) {
                    @memcpy(request.destination, page[request.offset..][0..request.destination.len]);
                    break;
                }
            } else {
                missing[count] = request;
                count += 1;
            }
        }
        try self.space.readPages(missing[0..count]);
    }

    fn reserve(self: *NodeBatch, id: storage.PageId) storage.Error!*storage.Page {
        for (self.ids[0..self.count], 0..) |cached, at| if (cached == id) return &self.pages[at];
        if (self.count == self.ids.len) try self.flush();
        const at = self.count;
        self.ids[at] = id;
        self.count += 1;
        return &self.pages[at];
    }

    fn discard(self: *NodeBatch, id: storage.PageId) void {
        for (self.ids[0..self.count], 0..) |cached_id, at| {
            if (cached_id != id) continue;
            self.count -= 1;
            self.ids[at] = self.ids[self.count];
            self.pages[at] = self.pages[self.count];
            return;
        }
    }

    fn flush(self: *NodeBatch) storage.Error!void {
        if (self.count == 0) return;
        var writes: [storage.batch_size]storage.Write = undefined;
        for (writes[0..self.count], self.ids[0..self.count], self.pages[0..self.count]) |*request, id, *page| request.* = .{ .id = id, .source = page };
        try self.space.writePages(writes[0..self.count]);
        self.count = 0;
    }
};

const CellView = struct {
    key: []const u8,
    value: []const u8,
    length: u32,
    reference: u64,
    flags: u16,
    prefix: u16,

    inline fn decode(page: *const storage.Page, at: usize, branch: bool) storage.Error!CellView {
        if (at > page.len or page.len - at < cell_header_size) return error.Corrupt;
        const key_len = std.mem.readInt(u16, page[at..][0..2], .little);
        const representation = std.mem.readInt(u16, page[at + 2 ..][0..2], .little);
        const flags = representation & 3;
        const prefix = representation >> 2;
        const length = std.mem.readInt(u32, page[at + 4 ..][0..4], .little);
        if (key_len == 0 or key_len > maximum_key or (branch != (flags == 2)) or (branch and length != 0) or (flags == 1 and length == 0)) return error.Corrupt;
        if ((flags == 0 or flags == 2) and prefix != 0) return error.Corrupt;
        if ((flags == 1 or flags == 3) and prefix >= length) return error.Corrupt;
        const size: usize = if (flags == 0) length else if (flags == 3) Direct.layout(length, prefix).bytes() else 8 + @as(usize, prefix);
        if (size > maximum_local) return error.Corrupt;
        if (flags == 3 and Direct.layout(length, prefix).pages == 0) return error.Corrupt;
        const start = at + cell_header_size;
        if (key_len > page.len - start or size > page.len - start - key_len) return error.Corrupt;
        const value = page[start + key_len ..][0..size];
        const reference = if (flags == 1 or flags == 2) std.mem.readInt(u64, value[0..8], .little) else 0;
        if ((flags == 1 or flags == 2) and reference == 0) return error.Corrupt;
        return .{ .key = page[start..][0..key_len], .value = value, .length = length, .reference = reference, .flags = flags, .prefix = prefix };
    }

    fn bytes(self: CellView) usize {
        return cell_header_size + self.key.len + self.value.len;
    }
};

const Navigation = struct {
    content: ?storage.PageLease.Content = null,
    used: u64 = 0,
    offsets: [maximum_cells + 1]u16 = undefined,
    count: usize = 0,
    branch: bool = false,
    next: u64 = 0,

    fn decode(self: *Navigation, page: *const storage.Page) storage.Error!void {
        self.content = null;
        if (!std.mem.eql(u8, page[0..4], "LRBT") or page[4] > 1 or page[5] != node_version) return error.Corrupt;
        const count = std.mem.readInt(u16, page[6..8], .little);
        const branch = page[4] != 0;
        const next = std.mem.readInt(u64, page[8..16], .little);
        if (count > maximum_cells or (branch and (count == 0 or next != 0))) return error.Corrupt;
        var at: usize = node_header_size;
        var previous: []const u8 = &.{};
        for (0..count) |index| {
            const cell = try CellView.decode(page, at, branch);
            if (index != 0 and key_order.compare(previous, cell.key) != .lt) return error.Corrupt;
            self.offsets[index] = @intCast(at);
            previous = cell.key;
            at += cell.bytes();
        }
        self.offsets[count] = @intCast(at);
        self.count = count;
        self.branch = branch;
        self.next = next;
    }
};

const NodeView = struct {
    page: *const storage.Page,
    navigation: *const Navigation,

    fn cell(self: NodeView, index: usize) CellView {
        assert(index < self.navigation.count);
        // Navigation validates every cell against the leased page content.
        // Subsequent lookups only reconstruct borrowed slices.
        const at = self.navigation.offsets[index];
        const end = self.navigation.offsets[index + 1];
        const key_len = std.mem.readInt(u16, self.page[at..][0..2], .little);
        const representation = std.mem.readInt(u16, self.page[at + 2 ..][0..2], .little);
        const flags = representation & 3;
        const length = std.mem.readInt(u32, self.page[at + 4 ..][0..4], .little);
        const start = at + cell_header_size;
        const value = self.page[start + key_len .. end];
        return .{
            .key = self.page[start..][0..key_len],
            .value = value,
            .length = length,
            .reference = if (flags == 1 or flags == 2) std.mem.readInt(u64, value[0..8], .little) else 0,
            .flags = flags,
            .prefix = representation >> 2,
        };
    }

    fn keyAt(self: NodeView, index: usize) []const u8 {
        assert(index < self.navigation.count);
        const at = self.navigation.offsets[index];
        const length = std.mem.readInt(u16, self.page[at..][0..2], .little);
        return self.page[at + cell_header_size ..][0..length];
    }

    fn lowerBound(self: NodeView, key: []const u8) usize {
        var low: usize = 0;
        var high = self.navigation.count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (key_order.compare(self.keyAt(middle), key) == .lt) low = middle + 1 else high = middle;
        }
        return low;
    }
};

const ValueReads = struct {
    data: blob.ReadBatch,

    fn begin(self: *ValueReads, space: storage.Space, indices: []blob.Index, cache: storage.Read.Cache) void {
        self.data.space = space;
        self.data.indices = indices;
        self.data.cache = cache;
        self.data.count = 0;
        self.data.blob_count = 0;
    }

    fn flush(self: *ValueReads) storage.Error!void {
        try self.data.flush();
    }

    fn append(self: *ValueReads, cell: CellView, destination: []u8, comptime prefix: bool) storage.Error!usize {
        if (!prefix and destination.len < cell.length) return error.BufferTooSmall;
        const count = @min(destination.len, cell.length);
        if (cell.flags == 0) {
            @memcpy(destination[0..count], cell.value[0..count]);
            return count;
        }
        if (cell.flags == 3) {
            const layout = Direct.layout(cell.length, cell.prefix);
            const local = @min(count, layout.prefix);
            @memcpy(destination[0..local], cell.value[layout.pages * 8 ..][0..local]);
            var offset = local;
            for (0..layout.pages) |at| {
                if (offset == count) break;
                const length = @min(storage.page_size, count - offset);
                try self.data.append(@fromBackingInt(@intCast(std.mem.readInt(u64, cell.value[at * 8 ..][0..8], .little))), destination[offset..][0..length]);
                offset += length;
            }
            assert(offset == count);
            return count;
        }
        assert(cell.flags == 1 and cell.prefix < cell.length);
        const local = @min(count, cell.prefix);
        @memcpy(destination[0..local], cell.value[8..][0..local]);
        if (count == local) return count;
        _ = if (prefix) try self.data.appendBlobPrefix(@fromBackingInt(@intCast(cell.reference)), cell.length - cell.prefix, destination[local..count]) else try self.data.appendBlob(@fromBackingInt(@intCast(cell.reference)), cell.length - cell.prefix, destination[local..count]);
        return count;
    }
};

pub const Get = struct {
    pub const Placement = enum { start, end };
    key: []const u8,
    destination: []u8,
    placement: Placement = .start,

    fn destinationFor(self: Get, length: usize) storage.Error![]u8 {
        if (length > self.destination.len) return error.BufferTooSmall;
        return switch (self.placement) {
            .start => self.destination[0..length],
            .end => self.destination[self.destination.len - length ..],
        };
    }
};
pub const PackedRead = struct {
    bytes: []u8,
    values: []?[]const u8,
    complete: []bool,
    used: usize = 0,
    prefix_bytes: ?usize = null,
};
pub const PackedBatch = struct { keys: []const []const u8, output: *PackedRead };
const PackedTarget = struct { output: *PackedRead, index: usize };
pub const Write = struct {
    key: []const u8,
    value: ?[]const u8,
};
pub const ScanCursor = struct { after: []u8, after_len: usize = 0 };
pub const ScanEntry = struct { key: []u8, value: []u8, key_len: usize = 0, value_len: usize = 0 };
pub const ScanKey = struct { key: []u8, key_len: usize = 0 };
pub const ScanResult = struct { count: usize, more: bool };

const Cell = struct {
    key: [maximum_key]u8 = undefined,
    key_len: u8 = 0,
    value: []const u8 = &.{},
    length: u32 = 0,
    reference: u64 = 0,
    flags: u16 = 0,
    prefix: u16 = 0,

    fn bytes(self: *const Cell) usize {
        return 8 + @as(usize, self.key_len) + if (self.flags != 2) self.value.len else @as(usize, 8);
    }
    fn view(self: *const Cell) CellView {
        return .{ .key = self.keySlice(), .value = self.value, .length = self.length, .reference = self.reference, .flags = self.flags, .prefix = self.prefix };
    }
    fn keySlice(self: *const Cell) []const u8 {
        return self.key[0..self.key_len];
    }
};

const UpdateWorkspace = struct {
    blob_indices: [storage.batch_size]blob.Index = undefined,
    path: [maximum_depth]storage.Page = undefined,
    /// The branch at each depth of the last descent, its page still in path and its navigation
    /// validated, for the next update of the same batch to descend without decoding it again.
    /// Anything an update changes above a leaf forgets them all.
    known: [maximum_depth]?storage.PageId = @splat(null),
    /// The table they are of, and the store as the last batch left it: writer workspaces serve
    /// every table of their resources, and other writers may come between batches.
    known_revision: ?KnownRevision = null,
    navigation: [maximum_depth]Navigation = undefined,
    cells: [working_cells]Cell = undefined,
    parent_cells: [maximum_cells]Cell = undefined,
    peer_cells: [2][maximum_cells]Cell = undefined,
    peer_pages: [2]storage.Page = undefined,
    descriptors: [maximum_batch][local_limit]u8 = undefined,
    writes: [storage.batch_size]storage.Write = undefined,
    children: [maximum_outputs]Cell = undefined,
};

const KnownRevision = struct { table: TableIdentity, identity: [16]u8, token: u64, mutation: u64 };

const TableIdentity = struct {
    store: *storage.Store,
    space: storage.SpaceId,
    root: @FieldType(storage.Space, "root"),
    directory: ?storage.PageId,
    offset: u16,
};

fn WorkspacePool(comptime Workspace: type) type {
    return struct {
        const Self = @This();
        const Slot = struct { workspace: Workspace = undefined, table: ?TableIdentity = null };
        const Lease = struct {
            pool: *Self,
            resources: *Resources,
            index: usize,
            slot: *Slot,
            workspace: *Workspace,

            fn end(self: Lease) void {
                self.resources.mutex.lockUncancelable(self.resources.io);
                assert(self.slot == &self.pool.slots[self.index] and self.slot.table != null);
                const bit = @as(u64, 1) << @intCast(self.index);
                assert(self.pool.available & bit == 0);
                self.slot.table = null;
                self.pool.available |= bit;
                const before = self.resources.borrowed.fetchSub(1, .release);
                assert(before > 0);
                self.resources.mutex.unlock(self.resources.io);
                self.pool.changed.signal(self.resources.io);
            }
        };
        slots: []Slot,
        available: u64,
        changed: std.Io.Condition = .init,

        fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            assert(capacity > 0 and capacity <= 64);
            const slots = try allocator.alloc(Slot, capacity);
            for (slots) |*slot| slot.table = null;
            return .{ .slots = slots, .available = @as(u64, std.math.maxInt(u64)) >> @intCast(64 - capacity) };
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            assert(self.available == @as(u64, std.math.maxInt(u64)) >> @intCast(64 - self.slots.len));
            for (self.slots) |*slot| assert(slot.table == null);
            allocator.free(self.slots);
        }

        fn acquireLocked(self: *Self, resources: *Resources) Lease {
            while (self.available == 0) self.changed.waitUncancelable(resources.io, &resources.mutex);
            const index = @ctz(self.available);
            self.available &= self.available - 1;
            const slot = &self.slots[index];
            assert(slot.table == null);
            return .{ .pool = self, .resources = resources, .index = index, .slot = slot, .workspace = &slot.workspace };
        }

        fn memoryBytes(self: *const Self) usize {
            return self.slots.len * @sizeOf(Slot);
        }
    };
}

pub const Resources = struct {
    pub const Configuration = struct { readers: usize = 2, writers: usize = 1, navigation_pages: usize = 64, cached_locations: usize = 4096, metrics: ?*metrics.Registry = null };
    const Location = struct {
        generation: u64 = 0,
        checksum: u64 = 0,
        page: storage.PageId = @fromBackingInt(0),
        hash: u64 = 0,
        offset: u16 = 0,
    };
    const ReadWorkspace = struct {
        const Context = struct {
            table: ?TableIdentity = null,
            revision: storage.Space.Revision = undefined,
            generation: u64 = 0,
            root: ?storage.PageId = null,
            used: u64 = 0,
        };
        pages: [storage.batch_size]storage.Page,
        cells: [maximum_cells]Cell,
        navigation: []Navigation,
        fallback: Navigation,
        borrowed: [storage.batch_size]storage.PageLease,
        blob_indices: [storage.batch_size]blob.Index,
        values: ValueReads,
        ids: [storage.batch_size]storage.PageId,
        active: [storage.batch_size]bool,
        first: [storage.batch_size]u16,
        tails: [storage.batch_size]u16,
        next: [storage.batch_size]u16,
        unique: [storage.batch_size]storage.PageId,
        groups: [std.math.ceilPowerOfTwoAssert(usize, storage.batch_size * 2)]u16,
        views: [storage.batch_size]*const storage.Page,
        navigation_clock: u64,
        locations: []Location,
        contexts: [8]Context,
        last_context: ?usize,
        location_clock: u64,
        location_generation: u64,
        located: [storage.batch_size]?Location,
        depths: [storage.batch_size]u8,

        fn beginRead(self: *ReadWorkspace, table: Table) storage.Error!?storage.PageId {
            const revision = try table.space.revision();
            const identity = table.identity();
            assert(self.location_clock != std.math.maxInt(u64));
            self.location_clock += 1;
            var selected: ?usize = null;
            if (self.last_context) |index| if (std.meta.eql(self.contexts[index].table.?, identity)) {
                selected = index;
            };
            if (selected == null) {
                var oldest: usize = 0;
                for (self.contexts, 0..) |context, index| {
                    if (context.table) |previous| if (std.meta.eql(previous, identity)) {
                        selected = index;
                        break;
                    };
                    if (context.used < self.contexts[oldest].used) oldest = index;
                }
                if (selected == null) {
                    selected = oldest;
                    self.contexts[oldest] = .{ .table = identity };
                }
            }
            const context = &self.contexts[selected.?];
            if (context.generation == 0 or !std.meta.eql(context.revision, revision)) {
                context.root = try table.getRoot();
                context.revision = revision;
                context.generation = self.location_clock;
            }
            context.used = self.location_clock;
            self.last_context = selected;
            self.location_generation = context.generation;
            return context.root;
        }

        fn locate(self: *ReadWorkspace, key: []const u8) ?*const Location {
            if (self.locations.len == 0) return null;
            const hash = std.hash.Wyhash.hash(0, key);
            const slot = &self.locations[hash % self.locations.len];
            if (slot.generation != self.location_generation or slot.hash != hash) return null;
            return slot;
        }

        fn rememberLocation(self: *ReadWorkspace, key: []const u8, content: storage.PageLease.Content, offset: u16) void {
            assert(key.len > 0 and key.len <= maximum_key and offset < storage.page_size);
            if (self.locations.len == 0) return;
            const hash = std.hash.Wyhash.hash(0, key);
            self.locations[hash % self.locations.len] = .{
                .generation = self.location_generation,
                .checksum = content.checksum,
                .page = content.page,
                .hash = hash,
                .offset = offset,
            };
        }

        fn navigate(self: *ReadWorkspace, content: storage.PageLease.Content) *Navigation {
            assert(self.navigation_clock != std.math.maxInt(u64));
            self.navigation_clock += 1;
            const ways = @min(self.navigation.len, 4);
            const buckets = (self.navigation.len + ways - 1) / ways;
            const bucket: usize = @intCast(content.checksum % buckets);
            const width = self.navigation.len / buckets;
            const extra = self.navigation.len % buckets;
            const begin = bucket * width + @min(bucket, extra);
            const candidates = self.navigation[begin..][0 .. width + @intFromBool(bucket < extra)];
            var selected = &candidates[0];
            for (candidates) |*candidate| {
                if (candidate.content) |previous| if (std.meta.eql(content, previous)) {
                    candidate.used = self.navigation_clock;
                    return candidate;
                };
                if (candidate.used < selected.used) selected = candidate;
            }
            selected.used = self.navigation_clock;
            return selected;
        }
    };
    const WriteWorkspace = struct {
        update: UpdateWorkspace,
        ids: [storage.batch_size]storage.PageId,
        pages: [storage.batch_size]storage.Page,
        order: [maximum_sorted_batch]u16,
        sorted: [maximum_batch]Write,
        borrowed: [storage.batch_size]storage.PageLease,
    };
    const Readers = WorkspacePool(ReadWorkspace);
    const Writers = WorkspacePool(WriteWorkspace);
    allocator: std.mem.Allocator,
    io: std.Io,
    readers: Readers,
    navigation: []Navigation,
    locations: []Location,
    writers: Writers,
    mutex: std.Io.Mutex = .init,
    borrowed: std.atomic.Value(usize) = .init(0),
    navigation_decoded: metrics.Counter = .{},
    navigation_branches_decoded: metrics.Counter = .{},
    navigation_reused: metrics.Counter = .{},
    locations_reused: metrics.Counter = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration) !*Resources {
        if (config.readers == 0 or config.readers > 64 or config.writers == 0 or config.writers > 64 or config.navigation_pages == 0) return error.InvalidArgument;
        const self = try allocator.create(Resources);
        errdefer allocator.destroy(self);
        var readers = try Readers.init(allocator, config.readers);
        errdefer readers.deinit(allocator);
        const navigation = try allocator.alloc(Navigation, try std.math.mul(usize, config.readers, config.navigation_pages));
        errdefer allocator.free(navigation);
        @memset(navigation, .{});
        const locations = try allocator.alloc(Location, try std.math.mul(usize, config.readers, config.cached_locations));
        errdefer allocator.free(locations);
        @memset(locations, .{});
        for (readers.slots, 0..) |*slot, index| {
            slot.workspace.navigation = navigation[index * config.navigation_pages ..][0..config.navigation_pages];
            slot.workspace.navigation_clock = 0;
            slot.workspace.locations = locations[index * config.cached_locations ..][0..config.cached_locations];
            slot.workspace.contexts = @splat(.{});
            slot.workspace.last_context = null;
            slot.workspace.location_clock = 0;
            slot.workspace.location_generation = 0;
        }
        const decoded = if (config.metrics) |registry| try registry.counter(.{ .name = "records.navigation.decoded", .description = "Record index pages structurally validated" }) else metrics.Counter{};
        const branches = if (config.metrics) |registry| try registry.counter(.{ .name = "records.navigation.branches_decoded", .description = "Record branch index pages structurally validated" }) else metrics.Counter{};
        const reused = if (config.metrics) |registry| try registry.counter(.{ .name = "records.navigation.reused", .description = "Validated record index navigation reused" }) else metrics.Counter{};
        const locations_reused = if (config.metrics) |registry| try registry.counter(.{ .name = "records.locations.reused", .description = "Records located without retraversing the index" }) else metrics.Counter{};
        const writers = try Writers.init(allocator, config.writers);
        self.* = .{ .allocator = allocator, .io = io, .readers = readers, .writers = writers, .navigation = navigation, .locations = locations, .locations_reused = locations_reused, .navigation_decoded = decoded, .navigation_branches_decoded = branches, .navigation_reused = reused };
        return self;
    }

    pub fn deinit(self: *Resources) void {
        assert(self.borrowed.load(.acquire) == 0);
        const allocator = self.allocator;
        allocator.free(self.locations);
        allocator.free(self.navigation);
        self.readers.deinit(allocator);
        self.writers.deinit(allocator);
        allocator.destroy(self);
    }

    fn acquireRead(self: *Resources, table: TableIdentity) Readers.Lease {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const lease = self.readers.acquireLocked(self);
        for (self.writers.slots) |*slot| if (slot.table) |writer| {
            assert(!std.meta.eql(writer, table));
        };
        assert(lease.slot.table == null);
        lease.slot.table = table;
        _ = self.borrowed.fetchAdd(1, .acquire);
        return lease;
    }

    fn acquireWrite(self: *Resources, table: TableIdentity) Writers.Lease {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const lease = self.writers.acquireLocked(self);
        for (self.readers.slots) |*slot| if (slot.table) |reader| {
            assert(!std.meta.eql(reader, table));
        };
        for (self.writers.slots) |*slot| if (slot.table) |writer| {
            assert(!std.meta.eql(writer, table));
        };
        assert(lease.slot.table == null);
        lease.slot.table = table;
        _ = self.borrowed.fetchAdd(1, .acquire);
        return lease;
    }

    pub fn memoryBytes(self: *const Resources) usize {
        return @sizeOf(Resources) + self.readers.memoryBytes() + self.writers.memoryBytes() + self.navigation.len * @sizeOf(Navigation) + self.locations.len * @sizeOf(Location);
    }
};

pub const Workspaces = struct {
    pub const id = "lightning_rod:record_workspaces";
    pub const Configuration = struct { shared: ?*Resources = null, readers: usize = 2, writers: usize = 1, navigation_pages: usize = 64, cached_locations: usize = 4096, metrics: ?*metrics.Registry = null };
    resources: *Resources,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration) !*Workspaces {
        const self = try allocator.create(Workspaces);
        errdefer allocator.destroy(self);
        self.* = .{ .resources = config.shared orelse try Resources.init(allocator, io, .{ .readers = config.readers, .writers = config.writers, .navigation_pages = config.navigation_pages, .cached_locations = config.cached_locations, .metrics = config.metrics }) };
        return self;
    }
};

const Node = struct {
    cells: []Cell = &.{},
    count: usize = 0,
    branch: bool = false,
    next: u64 = 0,

    fn decode(page: *const storage.Page, cells: []Cell) storage.Error!Node {
        if (!std.mem.eql(u8, page[0..4], "LRBT") or page[4] > 1 or page[5] != node_version) return error.Corrupt;
        var self: Node = .{ .cells = cells, .count = std.mem.readInt(u16, page[6..8], .little), .branch = page[4] != 0, .next = std.mem.readInt(u64, page[8..16], .little) };
        if (self.count > maximum_cells or self.count > cells.len or (self.branch and self.next != 0)) return error.Corrupt;
        var at: usize = node_header_size;
        for (self.cells[0..self.count], 0..) |*cell, index| {
            const view = try CellView.decode(page, at, self.branch);
            cell.* = .{ .key_len = @intCast(view.key.len), .value = if (view.flags != 2) view.value else &.{}, .length = view.length, .reference = view.reference, .flags = view.flags, .prefix = view.prefix };
            @memcpy(cell.key[0..view.key.len], view.key);
            at += view.bytes();
            if (index != 0 and key_order.compare(self.cells[index - 1].keySlice(), cell.keySlice()) != .lt) return error.Corrupt;
        }
        if (self.branch and self.count == 0) return error.Corrupt;
        return self;
    }
    fn encode(self: *const Node, page: *storage.Page, begin: usize, end: usize, next: u64) void {
        @memset(page, 0);
        @memcpy(page[0..4], "LRBT");
        page[4] = @intFromBool(self.branch);
        page[5] = node_version;
        std.mem.writeInt(u16, page[6..8], @intCast(end - begin), .little);
        std.mem.writeInt(u64, page[8..16], next, .little);
        var at: usize = 16;
        for (self.cells[begin..end]) |*cell| {
            assert(at + cell.bytes() <= page.len);
            std.mem.writeInt(u16, page[at..][0..2], cell.key_len, .little);
            std.mem.writeInt(u16, page[at + 2 ..][0..2], cell.flags | (cell.prefix << 2), .little);
            std.mem.writeInt(u32, page[at + 4 ..][0..4], cell.length, .little);
            at += 8;
            @memcpy(page[at..][0..cell.key_len], cell.keySlice());
            at += cell.key_len;
            if (cell.flags != 2) {
                @memcpy(page[at..][0..cell.value.len], cell.value);
                at += cell.value.len;
            } else {
                std.mem.writeInt(u64, page[at..][0..8], cell.reference, .little);
                at += 8;
            }
        }
    }
    fn lowerBound(self: *const Node, key: []const u8) usize {
        var low: usize = 0;
        var high = self.count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (key_order.compare(self.cells[middle].keySlice(), key) == .lt) low = middle + 1 else high = middle;
        }
        return low;
    }
    fn insert(self: *Node, at: usize, cell: Cell) void {
        assert(self.count < self.cells.len and at <= self.count);
        std.mem.copyBackwards(Cell, self.cells[at + 1 .. self.count + 1], self.cells[at..self.count]);
        self.cells[at] = cell;
        self.count += 1;
    }
    fn remove(self: *Node, at: usize) void {
        assert(at < self.count);
        std.mem.copyForwards(Cell, self.cells[at .. self.count - 1], self.cells[at + 1 .. self.count]);
        self.count -= 1;
    }
};

/// Mutations require exclusive ownership of the table. Independent tables may share workspaces.
pub const Table = struct {
    pub const read_batch_size = maximum_batch;
    pub const write_batch_size = maximum_batch;
    space: storage.Space,
    resources: *Resources,
    directory: ?storage.PageId = null,
    root_offset: u16 = 0,
    value_cache: storage.Read.Cache = .retain,

    fn identity(self: Table) TableIdentity {
        return .{ .store = self.space.store, .space = self.space.id, .root = self.space.root, .directory = self.directory, .offset = self.root_offset };
    }

    pub fn init(space: storage.Space, resources: *Resources) Table {
        return .{ .space = space, .resources = resources };
    }
    pub fn rooted(space: storage.Space, directory: storage.PageId, offset: u16, resources: *Resources) Table {
        assert(offset <= storage.page_size - 8);
        return .{ .space = space, .directory = directory, .root_offset = offset, .resources = resources };
    }
    fn getRoot(self: Table) storage.Error!?storage.PageId {
        const directory = self.directory orelse return self.space.getRoot();
        var bytes: [8]u8 = undefined;
        try self.space.readPages(&.{.{ .id = directory, .offset = self.root_offset, .destination = &bytes }});
        const id = std.mem.readInt(u64, &bytes, .little);
        return if (id == 0) null else @fromBackingInt(@intCast(id));
    }
    fn setRoot(self: Table, root: ?storage.PageId) storage.Error!void {
        const directory = self.directory orelse return self.space.setRoot(root);
        var page: storage.Page = undefined;
        try self.space.readPages(&.{.{ .id = directory, .destination = &page }});
        std.mem.writeInt(u64, page[self.root_offset..][0..8], if (root) |id| @backingInt(id) else 0, .little);
        try self.space.writePages(&.{.{ .id = directory, .source = &page }});
    }
    pub fn fail(self: Table) void {
        self.space.fail();
    }

    pub fn get(self: Table, key: []const u8, destination: []u8) storage.Error!?usize {
        var lengths: [1]?usize = undefined;
        try self.getBatch(&.{.{ .key = key, .destination = destination }}, &lengths);
        return lengths[0];
    }
    pub fn getBatch(self: Table, requests: []const Get, lengths: []?usize) storage.Error!void {
        return self.readBatch(requests, lengths, .values, null);
    }

    /// Copy at most destination.len bytes per value. Lengths report the bytes copied.
    pub fn prefixesBatch(self: Table, requests: []const Get, lengths: []?usize) storage.Error!void {
        return self.readBatch(requests, lengths, .prefixes, null);
    }

    /// Values borrow the buffer. Entries must fit individually. Remaining space bounds each batch.
    pub fn getPacked(self: Table, keys: []const []const u8, output: *PackedRead) storage.Error!void {
        return self.getPackedMany(&.{.{ .keys = keys, .output = output }});
    }

    pub fn getPackedMany(self: Table, batches: []const PackedBatch) storage.Error!void {
        var requests: [maximum_batch]Get = undefined;
        var lengths: [maximum_batch]?usize = undefined;
        var targets: [maximum_batch]PackedTarget = undefined;
        var count: usize = 0;
        for (batches) |batch| {
            const output = batch.output;
            if (batch.keys.len != output.values.len or batch.keys.len != output.complete.len or batch.keys.len > maximum_batch - count) return error.InvalidArgument;
            output.used = 0;
            @memset(output.values, null);
            @memset(output.complete, true);
            for (batch.keys, 0..) |key, index| {
                requests[count] = .{ .key = key, .destination = &.{} };
                targets[count] = .{ .output = output, .index = index };
                count += 1;
            }
        }
        try self.readBatch(requests[0..count], lengths[0..count], .packed_values, targets[0..count]);
        for (batches) |batch| assert(batch.output.used <= batch.output.bytes.len);
    }

    pub fn lengthsBatch(self: Table, keys: []const []const u8, lengths: []?usize) storage.Error!void {
        if (keys.len != lengths.len or keys.len > maximum_batch) return error.InvalidArgument;
        var requests: [maximum_batch]Get = undefined;
        for (keys, requests[0..keys.len]) |key, *request| request.* = .{ .key = key, .destination = &.{} };
        return self.readBatch(requests[0..keys.len], lengths, .lengths, null);
    }

    fn readBatch(self: Table, requests: []const Get, lengths: []?usize, comptime mode: enum { values, lengths, packed_values, prefixes }, packed_targets: ?[]const PackedTarget) storage.Error!void {
        if (requests.len != lengths.len) return error.InvalidArgument;
        if (requests.len == 0) return;
        const lease = self.resources.acquireRead(self.identity());
        defer lease.end();
        var decoded: u64 = 0;
        var branches_decoded: u64 = 0;
        var reused: u64 = 0;
        var locations_reused: u64 = 0;
        defer {
            self.resources.navigation_decoded.add(decoded);
            self.resources.navigation_branches_decoded.add(branches_decoded);
            self.resources.navigation_reused.add(reused);
            self.resources.locations_reused.add(locations_reused);
        }
        @memset(lengths, null);
        if (mode == .packed_values) {
            assert(packed_targets.?.len == requests.len);
        }
        for (requests) |request| if (request.key.len == 0 or request.key.len > maximum_key) return error.InvalidArgument;
        const root = try lease.workspace.beginRead(self) orelse return;
        const values = &lease.workspace.values;
        values.begin(self.space, &lease.workspace.blob_indices, self.value_cache);
        const pages = &lease.workspace.pages;
        var begin: usize = 0;
        while (begin < requests.len) {
            const count: usize = @min(storage.batch_size, requests.len - begin);
            const ids = &lease.workspace.ids;
            const active = &lease.workspace.active;
            const first = &lease.workspace.first;
            const tails = &lease.workspace.tails;
            const next = &lease.workspace.next;
            const unique = &lease.workspace.unique;
            for (requests[begin..][0..count], 0..) |request, index| {
                const cached = lease.workspace.locate(request.key);
                lease.workspace.located[index] = if (cached) |location| location.* else null;
                ids[index] = if (cached) |location| location.page else root;
            }
            @memset(active[0..count], true);
            @memset(lease.workspace.depths[0..count], 0);
            const borrowed = &lease.workspace.borrowed;
            while (true) {
                var reading: usize = 0;
                const slots = std.math.ceilPowerOfTwoAssert(usize, count * 2);
                const groups = lease.workspace.groups[0..slots];
                @memset(groups, storage.batch_size);
                for (ids[0..count], active[0..count], 0..) |id, live, index| {
                    if (!live) continue;
                    var slot: usize = @intCast(std.hash.Wyhash.hash(0, std.mem.asBytes(&id)) & (slots - 1));
                    while (groups[slot] != storage.batch_size and unique[groups[slot]] != id) slot = (slot + 1) & (slots - 1);
                    const group = groups[slot];
                    if (group == storage.batch_size) {
                        groups[slot] = @intCast(reading);
                        unique[reading] = id;
                        first[reading] = @intCast(index);
                        tails[reading] = @intCast(index);
                        reading += 1;
                    } else {
                        next[tails[group]] = @intCast(index);
                        tails[group] = @intCast(index);
                    }
                    next[index] = storage.batch_size;
                }
                if (reading == 0) break;
                {
                    const views = &lease.workspace.views;
                    var held: usize = 0;
                    assert(reading <= storage.batch_size);
                    if (self.space.borrowPages(unique[0..reading], borrowed[0..reading])) |_| {
                        held = reading;
                        for (borrowed[0..reading], views[0..reading]) |page, *view| view.* = page.bytes();
                    } else |err| {
                        if (err != error.CachePinned) return err;
                        var reads: [storage.batch_size]storage.Read = undefined;
                        for (unique[0..reading], pages[0..reading], reads[0..reading], views[0..reading]) |id, *page, *read, *view| {
                            read.* = .{ .id = id, .destination = page };
                            view.* = page;
                        }
                        try self.space.readPages(reads[0..reading]);
                    }
                    defer storage.PageLease.releaseMany(borrowed[0..held]);
                    for (views[0..reading], 0..) |bytes, page_index| {
                        const content = if (held == 0) null else borrowed[page_index].content();
                        const navigating = navigating: {
                            var index = first[page_index];
                            while (index != storage.batch_size) : (index = next[index]) {
                                if (lease.workspace.located[index] == null) break :navigating true;
                            }
                            break :navigating false;
                        };
                        const navigation: ?*Navigation = if (!navigating) null else navigation: {
                            const retained = content != null and (bytes[4] != 0 or unique[page_index] == root);
                            const value = if (retained) lease.workspace.navigate(content.?) else &lease.workspace.fallback;
                            if (!retained or value.content == null or !std.meta.eql(content.?, value.content.?)) {
                                decoded += 1;
                                try value.decode(bytes);
                                branches_decoded += @intFromBool(value.branch);
                                value.content = content;
                            } else reused += 1;
                            break :navigation value;
                        };
                        var index = first[page_index];
                        while (index != storage.batch_size) : (index = next[index]) {
                            assert(index < count and active[index] and ids[index] == unique[page_index]);
                            const request = requests[begin + index];
                            const cell = if (lease.workspace.located[index]) |cached| located: {
                                lease.workspace.located[index] = null;
                                ids[index] = root;
                                // Hash matches are hints. Validate the leased image and full key before accepting one.
                                if (content == null or content.?.checksum != cached.checksum) continue;
                                const value = try CellView.decode(bytes, cached.offset, false);
                                if (!std.mem.eql(u8, value.key, request.key)) continue;
                                active[index] = false;
                                locations_reused += 1;
                                break :located value;
                            } else found: {
                                if (lease.workspace.depths[index] == maximum_depth) return error.Corrupt;
                                lease.workspace.depths[index] += 1;
                                const node: NodeView = .{ .page = bytes, .navigation = navigation.? };
                                const position = node.lowerBound(request.key);
                                if (navigation.?.branch) {
                                    ids[index] = @fromBackingInt(@intCast(node.cell(@min(position, navigation.?.count - 1)).reference));
                                    continue;
                                }
                                active[index] = false;
                                if (position == navigation.?.count) continue;
                                const value = node.cell(position);
                                if (!std.mem.eql(u8, value.key, request.key)) continue;
                                if (content) |validated| lease.workspace.rememberLocation(request.key, validated, navigation.?.offsets[position]);
                                break :found value;
                            };
                            if (mode == .lengths) {
                                lengths[begin + index] = cell.length;
                            } else {
                                const destination = if (mode == .packed_values) target: {
                                    const target = packed_targets.?[begin + index];
                                    const output = target.output;
                                    const length = if (output.prefix_bytes) |limit| @min(cell.length, limit) else cell.length;
                                    if (length > output.bytes.len) return error.BufferTooSmall;
                                    if (length > output.bytes.len - output.used) {
                                        output.complete[target.index] = false;
                                        continue;
                                    }
                                    const bytes_out = output.bytes[output.used..][0..length];
                                    output.used += length;
                                    output.values[target.index] = bytes_out;
                                    break :target bytes_out;
                                } else try request.destinationFor(if (mode == .prefixes) @min(cell.length, request.destination.len) else cell.length);
                                lengths[begin + index] = if (mode == .packed_values and packed_targets.?[begin + index].output.prefix_bytes != null)
                                    try values.append(cell, destination, true)
                                else
                                    try values.append(cell, destination, mode == .prefixes);
                            }
                        }
                    }
                }
            }
            begin += count;
        }
        if (mode != .lengths) try values.flush();
    }
    fn makeCell(self: Table, key: []const u8, value: []const u8, occupied: usize, descriptor: *[local_limit]u8, data: *blob.WriteBatch) storage.Error!Cell {
        assert(occupied <= storage.page_size - node_header_size);
        if (key.len == 0 or key.len > maximum_key or value.len > std.math.maxInt(u32)) return error.InvalidArgument;
        var cell: Cell = .{ .key_len = @intCast(key.len), .length = @intCast(value.len), .value = value };
        @memcpy(cell.key[0..key.len], key);
        if (value.len > inline_threshold) {
            var layout = Direct.layout(value.len, value.len % storage.page_size);
            const header = cell_header_size + key.len;
            const available = storage.page_size - node_header_size - occupied;
            const spilled = Direct.layout(value.len, 0);
            const spilled_bytes = header + spilled.bytes();
            // Either choice can consume one extra page. Keep the larger gap available
            // for following cells when spilling the remainder avoids a leaf split.
            if (layout.bytes() > local_limit or (header + layout.bytes() > available and
                layout.prefix > occupied + (spilled.pages - layout.pages) * 8 and spilled_bytes <= available))
            {
                layout = spilled;
            }
            if (layout.pages == 0) return cell;
            if (layout.bytes() <= local_limit) {
                cell.flags = 3;
                cell.prefix = @intCast(layout.prefix);
                cell.value = descriptor[0..layout.bytes()];
                @memcpy(descriptor[layout.pages * 8 ..][0..layout.prefix], value[0..layout.prefix]);
                var begin: usize = 0;
                var offset = layout.prefix;
                while (begin < layout.pages) {
                    const count = @min(storage.batch_size, layout.pages - begin);
                    var ids: [storage.batch_size]storage.PageId = undefined;
                    try self.space.allocatePages(ids[0..count]);
                    for (ids[0..count], 0..) |id, at| {
                        std.mem.writeInt(u64, descriptor[(begin + at) * 8 ..][0..8], @backingInt(id), .little);
                        const length = @min(value.len - offset, storage.page_size);
                        try data.append(id, value[offset..][0..length]);
                        offset += length;
                    }
                    begin += count;
                }
                assert(offset == value.len);
            } else {
                cell.flags = 1;
                cell.reference = @backingInt(try data.write(value));
                std.mem.writeInt(u64, descriptor[0..8], cell.reference, .little);
                cell.value = descriptor[0..8];
            }
        }
        return cell;
    }

    pub fn put(self: Table, key: []const u8, value: ?[]const u8) storage.Error!void {
        try self.putBatch(&.{.{ .key = key, .value = value }});
    }
    pub fn putBatch(self: Table, writes: []const Write) storage.Error!void {
        if (writes.len == 0) return;
        const mutation = self.space.mutate();
        defer mutation.end();
        errdefer self.fail();
        const lease = self.resources.acquireWrite(self.identity());
        defer lease.end();
        const workspace = lease.workspace;
        try self.recall(&workspace.update);
        var nodes: NodeBatch = .{ .space = self.space, .ids = &workspace.ids, .pages = &workspace.pages };
        var begin: usize = 0;
        while (begin < writes.len) {
            const count = @min(writes.len - begin, maximum_sorted_batch);
            const batch = writes[begin..][0..count];
            const order = &workspace.order;
            const sorted = &workspace.sorted;
            for (batch, order[0..count], 0..) |write, *index, at| {
                if (write.key.len == 0 or write.key.len > maximum_key) return error.InvalidArgument;
                index.* = @intCast(at);
            }
            std.mem.sort(u16, order[0..count], batch, struct {
                fn less(items: []const Write, a: u16, b: u16) bool {
                    const result = key_order.compare(items[a].key, items[b].key);
                    return if (result == .eq) a < b else result == .lt;
                }
            }.less);
            var at: usize = 0;
            while (at < count) {
                var unique: usize = 0;
                while (at < count and unique < sorted.len) {
                    const index = order[at];
                    at += 1;
                    if (at < count and std.mem.eql(u8, batch[index].key, batch[order[at]].key)) continue;
                    sorted[unique] = batch[index];
                    unique += 1;
                }
                var applied: usize = 0;
                const window = @min(storage.batch_size, @max(1, self.space.borrowCapacity() / 2));
                while (applied < unique) {
                    const limit = applied + @min(window, unique - applied);
                    const held = &workspace.borrowed;
                    const kept = try self.prefetch(sorted[applied..limit], &nodes, &workspace.update, held);
                    assert(kept <= limit - applied);
                    defer storage.PageLease.releaseMany(held[0..kept]);
                    while (applied < limit) {
                        const consumed = try self.update(sorted[applied..unique], &nodes, &workspace.update);
                        assert(consumed > 0 and consumed <= unique - applied);
                        applied += consumed;
                    }
                }
            }
            begin += count;
        }
        try nodes.flush();
        workspace.update.known_revision = try self.knownRevision();
    }

    /// Retains leaf leases in held[0..result] until the caller finishes its update window.
    /// Keeps the branches the last batch descended through when nothing has written a page of
    /// the store since: any write moves its mutation count.
    fn recall(self: Table, workspace: *UpdateWorkspace) storage.Error!void {
        const now = try self.knownRevision();
        const same = if (workspace.known_revision) |then| std.meta.eql(then, now) else false;
        if (!same) workspace.known = @splat(null);
        workspace.known_revision = null;
    }

    /// Where the store is now, for the next batch to see whether it moved.
    fn knownRevision(self: Table) storage.Error!KnownRevision {
        const revision = try self.space.revision();
        return .{ .table = self.identity(), .identity = revision.identity, .token = revision.token, .mutation = revision.mutation };
    }

    fn prefetch(self: Table, writes: []const Write, nodes: *const NodeBatch, workspace: *UpdateWorkspace, held: []storage.PageLease) storage.Error!usize {
        assert(writes.len <= storage.batch_size and held.len >= writes.len);
        if (writes.len < 2) return 0;
        const root = try self.getRoot() orelse return 0;
        var ids: [storage.batch_size]storage.PageId = @splat(root);
        var active: [storage.batch_size]bool = @splat(true);
        var depth: usize = 0;
        while (depth < maximum_depth) : (depth += 1) {
            var unique: [storage.batch_size]storage.PageId = undefined;
            var mapping: [storage.batch_size]usize = undefined;
            var views: [storage.batch_size]*const storage.Page = undefined;
            var missing: [storage.batch_size]storage.PageId = undefined;
            var missing_positions: [storage.batch_size]usize = undefined;
            var reading: usize = 0;
            var misses: usize = 0;
            for (ids[0..writes.len], active[0..writes.len], mapping[0..writes.len]) |id, live, *mapped| {
                if (!live) continue;
                var index: usize = 0;
                while (index < reading and unique[index] != id) index += 1;
                mapped.* = index;
                if (index != reading) continue;
                unique[reading] = id;
                reading += 1;
                // Dirty nodes may contain child links that have not reached storage yet.
                const pending = for (nodes.ids[0..nodes.count], nodes.pages[0..nodes.count]) |cached, *page| {
                    if (cached == id) break page;
                } else null;
                if (pending) |page| {
                    views[index] = page;
                } else {
                    missing_positions[misses] = index;
                    missing[misses] = id;
                    misses += 1;
                }
            }
            if (reading == 0) return 0;
            if (misses != 0) self.space.borrowPages(missing[0..misses], held[0..misses]) catch |err| {
                if (err == error.CachePinned) return 0;
                return err;
            };
            var retained = false;
            defer if (!retained) storage.PageLease.releaseMany(held[0..misses]);
            for (held[0..misses], missing_positions[0..misses]) |lease, index| views[index] = lease.bytes();
            for (views[0..reading], 0..) |bytes, page_index| {
                // A leaf is only kept at hand here; the update reads and checks it.
                const branch = bytes[4] != 0;
                const navigation = &workspace.navigation[depth];
                if (branch and workspace.known[depth] != unique[page_index]) {
                    // The update descends through it next: it keeps the page and its navigation.
                    workspace.known[depth] = null;
                    @memcpy(&workspace.path[depth], bytes);
                    try navigation.decode(&workspace.path[depth]);
                    if (!navigation.branch) return error.Corrupt;
                    if (reading == 1) workspace.known[depth] = unique[page_index];
                }
                const node: NodeView = .{ .page = &workspace.path[depth], .navigation = navigation };
                for (writes, 0..) |write, index| {
                    if (!active[index] or mapping[index] != page_index) continue;
                    if (branch) {
                        const position = node.lowerBound(write.key);
                        ids[index] = @fromBackingInt(@intCast(node.cell(@min(position, navigation.count - 1)).reference));
                    } else active[index] = false;
                }
            }
            const pending = for (active[0..writes.len]) |live| {
                if (live) break true;
            } else false;
            if (!pending) {
                retained = true;
                return misses;
            }
        }
        return error.Corrupt;
    }

    fn update(self: Table, writes: []const Write, nodes: *NodeBatch, workspace: *UpdateWorkspace) storage.Error!usize {
        assert(writes.len != 0 and writes.len <= maximum_batch);
        const first = writes[0];
        const path = &workspace.path;
        var ids: [maximum_depth]storage.PageId = undefined;
        var positions: [maximum_depth]usize = undefined;
        var depth: usize = 0;
        var rightmost = true;
        const cells = &workspace.cells;
        const parent_cells = &workspace.parent_cells;
        const peer_cells = &workspace.peer_cells;
        const peer_pages = &workspace.peer_pages;
        if (try self.getRoot()) |root| ids[0] = root else {
            var missing: usize = 0;
            while (missing < writes.len and writes[missing].value == null) missing += 1;
            if (missing != 0) return missing;
            var allocated: [1]storage.PageId = undefined;
            try self.space.allocatePages(&allocated);
            ids[0] = allocated[0];
            const empty: Node = .{};
            empty.encode(try nodes.reserve(ids[0]), 0, 0, 0);
            try self.setRoot(ids[0]);
        }
        var node: Node = undefined;
        // Branches descend by navigation, as the last update left them where it can; the leaf
        // is decoded whole, as it is rewritten.
        while (true) {
            const known = workspace.known[depth] == ids[depth];
            if (!known) {
                workspace.known[depth] = null;
                try nodes.read(ids[depth], &path[depth]);
            }
            if (path[depth][4] == 0) {
                node = try Node.decode(&path[depth], cells);
                positions[depth] = node.lowerBound(first.key);
                if (node.branch) return error.Corrupt;
                break;
            }
            const navigation = &workspace.navigation[depth];
            if (!known) {
                try navigation.decode(&path[depth]);
                if (!navigation.branch) return error.Corrupt;
                workspace.known[depth] = ids[depth];
            }
            const view: NodeView = .{ .page = &path[depth], .navigation = navigation };
            positions[depth] = @min(view.lowerBound(first.key), navigation.count - 1);
            if (positions[depth] + 1 != navigation.count) rightmost = false;
            if (depth + 1 == maximum_depth) return error.NoSpace;
            ids[depth + 1] = @fromBackingInt(@intCast(view.cell(positions[depth]).reference));
            depth += 1;
        }
        var height = depth + 1;
        const upper = if (node.count != 0) node.cells[node.count - 1] else null;
        var used: usize = 0;
        var changed = false;
        const descriptors = &workspace.descriptors;
        var data: blob.WriteBatch = .{ .space = self.space, .writes = &workspace.writes };
        var accounted: usize = 0;
        var leaf_bytes: usize = 0;
        var freeing: blob.FreeBatch = .{ .space = self.space, .indices = &workspace.blob_indices };
        for (writes) |write| {
            if (!rightmost and upper != null and key_order.compare(write.key, upper.?.keySlice()) == .gt) break;
            const at = node.lowerBound(write.key);
            if (at == node.count or !std.mem.eql(u8, node.cells[at].keySlice(), write.key)) continue;
            const cell = &node.cells[at];
            if (cell.flags == 1) try freeing.appendBlob(@fromBackingInt(@intCast(cell.reference)), cell.length - cell.prefix);
            if (cell.flags == 3) {
                const layout = Direct.layout(cell.length, cell.prefix);
                for (0..layout.pages) |index| try freeing.appendPage(@fromBackingInt(@intCast(std.mem.readInt(u64, cell.value[index * 8 ..][0..8], .little))));
            }
        }
        try freeing.flush();
        for (writes) |write| {
            if (!rightmost and upper != null and key_order.compare(write.key, upper.?.keySlice()) == .gt) break;
            const at = node.lowerBound(write.key);
            const exists = at < node.count and std.mem.eql(u8, node.cells[at].keySlice(), write.key);
            used += 1;
            if (exists and write.value != null and node.cells[at].flags == 0 and std.mem.eql(u8, node.cells[at].value, write.value.?)) continue;
            if (!exists and write.value == null) continue;
            if (exists and write.value == null) node.remove(at);
            for (node.cells[accounted..at]) |*cell| {
                if (leaf_bytes + cell.bytes() > storage.page_size - node_header_size) leaf_bytes = 0;
                leaf_bytes += cell.bytes();
            }
            accounted = at;
            if (write.value) |value| {
                const cell = try self.makeCell(write.key, value, leaf_bytes, &descriptors[used - 1], &data);
                if (exists) node.cells[at] = cell else node.insert(at, cell);
                if (leaf_bytes + cell.bytes() > storage.page_size - node_header_size) leaf_bytes = 0;
                leaf_bytes += cell.bytes();
                accounted += 1;
            }
            changed = true;
        }
        assert(used != 0);
        if (!changed) return used;
        try data.flush();
        const children = &workspace.children;
        while (true) {
            if (depth == 0 and node.branch and node.count == 1) {
                workspace.known = @splat(null);
                const child: storage.PageId = @fromBackingInt(@intCast(node.cells[0].reference));
                try self.setRoot(child);
                nodes.discard(ids[0]);
                try self.space.freePages(&.{ids[0]});
                ids[0] = child;
                try nodes.read(child, &path[0]);
                node = try Node.decode(&path[0], cells);
                height -= 1;
                continue;
            }
            var old_ids: [3]storage.PageId = undefined;
            old_ids[0] = ids[depth];
            var replaced: usize = 1;
            var node_bytes: usize = node_header_size;
            for (node.cells[0..node.count]) |*cell| node_bytes += cell.bytes();
            if (depth != 0 and (node_bytes > storage.page_size or node_bytes < storage.page_size / 2)) {
                workspace.known = @splat(null);
                const parent = try Node.decode(&path[depth - 1], parent_cells);
                const at = positions[depth - 1];
                const first_peer = @min(at -| 1, parent.count -| 3);
                replaced = @min(parent.count, 3);
                var peers: [3]Node = undefined;
                var reading: usize = 0;
                var reads: [2]storage.Read = undefined;
                for (old_ids[0..replaced], 0..) |*id, index| {
                    const position = first_peer + index;
                    id.* = @fromBackingInt(@intCast(parent.cells[position].reference));
                    if (position == at) continue;
                    reads[reading] = .{ .id = id.*, .destination = &peer_pages[reading] };
                    reading += 1;
                }
                try nodes.readMany(reads[0..reading]);
                reading = 0;
                for (peers[0..replaced], 0..) |*peer, index| {
                    if (first_peer + index == at) {
                        peer.* = node;
                    } else {
                        peer.* = try Node.decode(&peer_pages[reading], &peer_cells[reading]);
                        reading += 1;
                        if (peer.branch != node.branch or peer.count == 0) return error.Corrupt;
                    }
                    if (!node.branch and index != 0 and peers[index - 1].next != @backingInt(old_ids[index])) return error.Corrupt;
                }
                var selected_begin: usize = 0;
                var selected_end: usize = replaced;
                var growth: isize = std.math.maxInt(isize);
                const pivot = at - first_peer;
                // Minimize page growth first, then the number of existing pages rewritten.
                for (0..pivot + 1) |begin| {
                    for (pivot + 1..replaced + 1) |end| {
                        if (end - begin == 1 and replaced > 1 and node_bytes < storage.page_size / 2) continue;
                        var required: usize = 1;
                        var occupied: usize = node_header_size;
                        for (peers[begin..end]) |peer| for (peer.cells[0..peer.count]) |*cell| {
                            if (occupied + cell.bytes() > storage.page_size) {
                                required += 1;
                                occupied = node_header_size;
                            }
                            occupied += cell.bytes();
                        };
                        const added = @as(isize, @intCast(required)) - @as(isize, @intCast(end - begin));
                        if (added < growth or (added == growth and end - begin < selected_end - selected_begin)) {
                            growth = added;
                            selected_begin = begin;
                            selected_end = end;
                        }
                    }
                }
                var prefix: usize = 0;
                var total: usize = 0;
                for (peers[selected_begin..selected_end], selected_begin..) |peer, index| {
                    if (index == pivot) prefix = total;
                    total += peer.count;
                }
                assert(total <= node.cells.len);
                std.mem.copyBackwards(Cell, node.cells[prefix .. prefix + node.count], node.cells[0..node.count]);
                var offset: usize = 0;
                for (peers[selected_begin..selected_end], selected_begin..) |peer, index| {
                    if (index != pivot) @memcpy(node.cells[offset..][0..peer.count], peer.cells[0..peer.count]);
                    offset += peer.count;
                }
                node.count = total;
                node.next = peers[selected_end - 1].next;
                std.mem.copyForwards(storage.PageId, old_ids[0 .. selected_end - selected_begin], old_ids[selected_begin..selected_end]);
                replaced = selected_end - selected_begin;
                ids[depth] = old_ids[0];
                positions[depth - 1] = first_peer + selected_begin;
            }
            var child_count: usize = 0;
            if (node.count == 0) {
                if (depth != 0 and !node.branch) {
                    var level = depth;
                    while (level != 0) {
                        level -= 1;
                        if (positions[level] == 0) continue;
                        const parent = try Node.decode(&path[level], parent_cells);
                        var predecessor: storage.PageId = @fromBackingInt(@intCast(parent.cells[positions[level] - 1].reference));
                        var preceding_page: storage.Page = undefined;
                        var steps: usize = 0;
                        while (true) {
                            try nodes.read(predecessor, &preceding_page);
                            var preceding = try Node.decode(&preceding_page, &peer_cells[0]);
                            if (!preceding.branch) {
                                if (preceding.next != @backingInt(ids[depth])) return error.Corrupt;
                                preceding.encode(try nodes.reserve(predecessor), 0, preceding.count, node.next);
                                break;
                            }
                            if (steps == maximum_depth) return error.Corrupt;
                            steps += 1;
                            predecessor = @fromBackingInt(@intCast(preceding.cells[preceding.count - 1].reference));
                        }
                        break;
                    }
                }
                nodes.discard(ids[depth]);
                try self.space.freePages(&.{ids[depth]});
            } else {
                var boundaries: [maximum_outputs + 1]usize = undefined;
                var output_ids: [maximum_outputs]storage.PageId = undefined;
                const capacity = storage.page_size - node_header_size;
                var pages_needed: [working_cells + 1]u16 = undefined;
                pages_needed[node.count] = 0;
                var suffix_pages: u16 = 1;
                var suffix_bytes: usize = 0;
                var remaining_bytes: usize = 0;
                var cell_index = node.count;
                while (cell_index != 0) {
                    cell_index -= 1;
                    const bytes = node.cells[cell_index].bytes();
                    if (suffix_bytes + bytes > capacity) {
                        suffix_pages += 1;
                        suffix_bytes = 0;
                    }
                    suffix_bytes += bytes;
                    remaining_bytes += bytes;
                    pages_needed[cell_index] = suffix_pages;
                }
                child_count = pages_needed[0];
                if (child_count > output_ids.len) return error.Corrupt;
                boundaries[0] = 0;
                for (0..child_count) |child| {
                    const remaining_pages = child_count - child;
                    const first_cell = boundaries[child];
                    var prefix: usize = 0;
                    var selected_bytes: usize = 0;
                    var selected = first_cell;
                    var imbalance: usize = std.math.maxInt(usize);
                    // The suffix must still fit after choosing a balanced boundary.
                    for (node.cells[first_cell..node.count], first_cell + 1..) |*cell, at| {
                        prefix += cell.bytes();
                        if (prefix > capacity) break;
                        if (pages_needed[at] > remaining_pages - 1 or node.count - at < remaining_pages - 1) continue;
                        const weighted = prefix * remaining_pages;
                        const difference = @max(weighted, remaining_bytes) - @min(weighted, remaining_bytes);
                        if (difference <= imbalance) {
                            selected = at;
                            selected_bytes = prefix;
                            imbalance = difference;
                        }
                    }
                    assert(selected > first_cell);
                    boundaries[child + 1] = selected;
                    remaining_bytes -= selected_bytes;
                }
                assert(remaining_bytes == 0);
                const reused = @min(child_count, replaced);
                @memcpy(output_ids[0..reused], old_ids[0..reused]);
                try self.space.allocatePages(output_ids[reused..child_count]);
                for (old_ids[reused..replaced]) |id| nodes.discard(id);
                try self.space.freePages(old_ids[reused..replaced]);
                var begin: usize = 0;
                while (begin < child_count) {
                    const count = @min(storage.batch_size, child_count - begin);
                    for (0..count) |offset| {
                        const at = begin + offset;
                        const next = if (node.branch) 0 else if (at + 1 < child_count) @backingInt(output_ids[at + 1]) else node.next;
                        node.encode(try nodes.reserve(output_ids[at]), boundaries[at], boundaries[at + 1], next);
                        children[at] = node.cells[boundaries[at + 1] - 1];
                        children[at].flags = 2;
                        children[at].length = 0;
                        children[at].value = &.{};
                        children[at].reference = @backingInt(output_ids[at]);
                        children[at].prefix = 0;
                    }
                    begin += count;
                }
            }
            if (depth == 0) {
                workspace.known = @splat(null);
                if (child_count == 0) try self.setRoot(null);
                if (child_count <= 1) return used;
                if (height == maximum_depth) return error.NoSpace;
                height += 1;
                node = .{ .cells = cells, .branch = true };
                for (children[0..child_count], 0..) |child, at| node.insert(at, child);
                var allocated: [1]storage.PageId = undefined;
                try self.space.allocatePages(&allocated);
                ids[0] = allocated[0];
                try self.setRoot(allocated[0]);
                continue;
            }
            depth -= 1;
            // A node rewritten in place under the same key leaves its parent as it was.
            if (replaced == 1 and child_count == 1 and workspace.known[depth] == ids[depth]) {
                const view: NodeView = .{ .page = &path[depth], .navigation = &workspace.navigation[depth] };
                const cell = view.cell(positions[depth]);
                if (cell.reference == children[0].reference and std.mem.eql(u8, cell.key, children[0].keySlice())) return used;
            }
            workspace.known = @splat(null);
            node = try Node.decode(&path[depth], cells);
            const at = positions[depth];
            if (replaced == 1 and child_count == 1 and node.cells[at].reference == children[0].reference and
                std.mem.eql(u8, node.cells[at].keySlice(), children[0].keySlice())) return used;
            for (0..replaced) |_| node.remove(at);
            for (children[0..child_count], 0..) |child, offset| node.insert(at + offset, child);
        }
    }

    pub fn scan(self: Table, cursor: *ScanCursor, output: []ScanEntry) storage.Error!ScanResult {
        return self.scanBatch(cursor, true, output);
    }

    pub fn scanKeys(self: Table, cursor: *ScanCursor, output: []ScanKey) storage.Error!ScanResult {
        if (output.len > maximum_batch) return error.InvalidArgument;
        return self.scanBatch(cursor, false, output);
    }

    fn scanBatch(self: Table, cursor: *ScanCursor, comptime include_values: bool, output: [](if (include_values) ScanEntry else ScanKey)) storage.Error!ScanResult {
        if (output.len == 0 or cursor.after_len > cursor.after.len or cursor.after_len > maximum_key) return error.InvalidArgument;
        const lease = self.resources.acquireRead(self.identity());
        defer lease.end();
        const saved_length = cursor.after_len;
        var saved: [maximum_key]u8 = undefined;
        @memcpy(saved[0..saved_length], cursor.after[0..saved_length]);
        errdefer {
            @memcpy(cursor.after[0..saved_length], saved[0..saved_length]);
            cursor.after_len = saved_length;
        }
        var id = try self.getRoot() orelse return .{ .count = 0, .more = false };
        var count: usize = 0;
        var depth: usize = 0;
        var page: storage.Page = undefined;
        const cells = &lease.workspace.cells;
        const values: if (include_values) *ValueReads else void = if (include_values) &lease.workspace.values else {};
        if (include_values) values.begin(self.space, &lease.workspace.blob_indices, self.value_cache);
        var node: Node = undefined;
        while (true) {
            if (depth == maximum_depth) return error.Corrupt;
            try self.space.readPages(&.{.{ .id = id, .destination = &page }});
            node = try Node.decode(&page, cells);
            if (!node.branch) break;
            depth += 1;
            const at = @min(node.lowerBound(cursor.after[0..cursor.after_len]), node.count - 1);
            id = @fromBackingInt(@intCast(node.cells[at].reference));
        }
        var at = node.lowerBound(cursor.after[0..cursor.after_len]);
        if (node.count == 0) return error.Corrupt;
        if (at < node.count and std.mem.eql(u8, node.cells[at].keySlice(), cursor.after[0..cursor.after_len])) at += 1;
        while (true) {
            while (at < node.count and count < output.len) : (at += 1) {
                const cell = &node.cells[at];
                const row = &output[count];
                if (row.key.len < cell.key_len or cursor.after.len < cell.key_len) return error.BufferTooSmall;
                @memcpy(row.key[0..cell.key_len], cell.keySlice());
                row.key_len = cell.key_len;
                if (include_values) row.value_len = try values.append(cell.view(), row.value, false);
                @memcpy(cursor.after[0..cell.key_len], cell.keySlice());
                cursor.after_len = cell.key_len;
                count += 1;
            }
            if (count == output.len or node.next == 0) {
                if (include_values) try values.flush();
                return .{ .count = count, .more = at < node.count or node.next != 0 };
            }
            const last = node.cells[node.count - 1];
            id = @fromBackingInt(@intCast(node.next));
            try self.space.readPages(&.{.{ .id = id, .destination = &page }});
            node = try Node.decode(&page, cells);
            if (node.branch or node.count == 0 or key_order.compare(last.keySlice(), node.cells[0].keySlice()) != .lt) return error.Corrupt;
            at = 0;
        }
    }
};
