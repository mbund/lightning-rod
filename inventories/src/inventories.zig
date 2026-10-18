const References = @import("references.zig").References;
const Slots = @import("slots.zig").Slots;
const metrics = @import("metrics");
const std = @import("std");
const storage = @import("storage");
const records = @import("records");
const ReferenceCache = records.CacheFor(References);
const SlotCache = records.CacheFor(Slots);

const assert = std.debug.assert;

pub const ItemId = [32]u8;

pub const Slot = struct {
    owner: u128,
    index: u16,
};

pub const Stack = struct {
    item: ItemId,
    count: u16,

    pub fn sameItem(a: Stack, b: Stack) bool {
        return std.mem.eql(u8, &a.item, &b.item);
    }
};

pub const Contents = struct {
    stack: ?Stack = null,
    revision: u64 = 0,
};

pub const Move = struct {
    from: Slot,
    to: Slot,
    count: u16,
    from_revision: u64,
    to_revision: u64,
    maximum_stack: u16,
};

pub const MoveResult = enum {
    moved,
    stale,
    empty,
    incompatible,
    full,
};

pub const Edit = struct {
    slot: Slot,
    revision: u64,
    stack: ?Stack,
};

pub const Inventories = struct {
    pub const id = "lightning_rod:inventories";

    pub const Configuration = struct {
        cache_slots: usize = 256,
        cache_items: usize = 8,
        max_item_bytes: usize = 64 * 1024,
    };

    pub const Dependencies = struct {
        metrics: *metrics.Registry,
        storage: storage.Space,
    };

    deps: Dependencies,
    config: Configuration,
    cache: SlotCache,
    items: records.Cache,
    references: ReferenceCache,
    verified: []Stamp,

    const Stamp = struct { generation: u64 = 0, revision: u64 = 0 };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration, deps: Dependencies) !*Inventories {
        if (config.cache_slots < 2 or config.cache_items == 0 or config.max_item_bytes == 0) return error.InvalidArgument;

        const root = try deps.storage.getRoot() orelse blk: {
            var allocated: [1]storage.PageId = undefined;
            try deps.storage.allocatePages(&allocated);
            var page: storage.Page = @splat(0);
            @memcpy(page[0..8], "LRINVEN1");
            try deps.storage.writePages(&.{.{ .id = allocated[0], .source = &page }});
            try deps.storage.setRoot(allocated[0]);
            break :blk allocated[0];
        };
        var header: storage.Page = undefined;
        try deps.storage.readPages(&.{.{ .id = root, .destination = &header }});
        if (!std.mem.eql(u8, header[0..8], "LRINVEN1")) return error.Corrupt;
        const self = try allocator.create(Inventories);
        self.* = .{
            .verified = try allocator.alloc(Stamp, config.cache_items),
            .deps = deps,
            .config = config,
            .cache = try SlotCache.init(allocator, io, .{ .index = records.Table.rooted(deps.storage, root, 8) }, .{
                .metrics = deps.metrics,
                .metrics_namespace = "inventories.slots",
                .slots = config.cache_slots,
                .key_bytes = 18,
                .value_bytes = encoded_bytes,
            }),
            .references = try ReferenceCache.init(allocator, io, .{ .counts = records.Table.rooted(deps.storage, root, 24), .retired = records.Table.rooted(deps.storage, root, 32) }, .{
                .metrics = deps.metrics,
                .metrics_namespace = "inventories.references",
                .slots = @max(128, config.cache_items),
                .key_bytes = 32,
                .value_bytes = 8,
            }),
            .items = try records.Cache.init(allocator, io, records.Table.rooted(deps.storage, root, 16), .{
                .metrics = deps.metrics,
                .metrics_namespace = "inventories.items",
                .slots = config.cache_items,
                .key_bytes = 32,
                .value_bytes = config.max_item_bytes,
            }),
        };
        @memset(self.verified, .{});
        return self;
    }

    /// Item definitions are immutable, content-addressed canonical bytes.
    /// Moving a stack changes ownership records, never copies its item payload.
    pub fn defineItem(self: *Inventories, encoded: []const u8) !ItemId {
        if (encoded.len == 0 or encoded.len > self.config.max_item_bytes)
            return error.ItemTooLarge;

        var item: ItemId = undefined;
        std.crypto.hash.Blake3.hash(encoded, &item, .{});
        const key = item;
        const lease = try self.items.acquire(&key);
        defer lease.release();

        if (lease.read() == null) {
            @memcpy(lease.edit()[0..encoded.len], encoded);
            lease.commit(encoded.len);
        }

        const reference = try self.references.acquire(&key);
        defer reference.release();
        if (reference.read() == null) {
            @memset(reference.edit(), 0);
            reference.commit(8);
        }
        return item;
    }

    pub fn acquireItems(self: *Inventories, ids: []const ItemId, output: []records.Cache.Lease) !void {
        return self.acquireItemsBatch(128, ids, output);
    }

    fn acquireItemsBatch(self: *Inventories, comptime capacity: usize, ids: []const ItemId, output: []records.Cache.Lease) !void {
        if (ids.len != output.len or ids.len > capacity) return error.WorkingSetTooLarge;
        var keys: [capacity][32]u8 = undefined;
        var slices: [capacity][]const u8 = undefined;
        for (ids, 0..) |item, i| {
            keys[i] = item;
            slices[i] = &keys[i];
        }
        try self.items.acquireMany(slices[0..ids.len], output);
        errdefer for (output) |lease| lease.release();
        for (ids, output) |item, lease| {
            const stamp: Stamp = .{ .generation = lease.generation, .revision = lease.revision() };
            if (std.meta.eql(self.verified[lease.index], stamp)) continue;
            const bytes = lease.read() orelse return error.UnknownItem;
            if (bytes.len == 0 or bytes.len > self.config.max_item_bytes) return error.Corrupt;
            var digest: ItemId = undefined;
            std.crypto.hash.Blake3.hash(bytes, &digest, .{});
            if (!std.mem.eql(u8, &digest, &item)) return error.Corrupt;
            self.verified[lease.index] = stamp;
        }
    }

    pub fn acquireItem(self: *Inventories, item: ItemId) !records.Cache.Lease {
        var leases: [1]records.Cache.Lease = undefined;
        try self.acquireItemsBatch(1, &.{item}, &leases);
        return leases[0];
    }

    pub fn get(self: *Inventories, slot: Slot) !Contents {
        const key = encodeKey(slot);
        const lease = try self.cache.acquire(&key);
        defer lease.release();
        return decode(lease.read());
    }

    /// The owner has been retired and must never reuse this slot identity.
    pub fn retire(self: *Inventories, slot: Slot) !void {
        const key = encodeKey(slot);
        const lease = try self.cache.acquire(&key);
        defer lease.release();
        const contents = try decode(lease.read());
        assert(contents.stack == null);
        lease.remove();
    }

    pub fn getMany(self: *Inventories, slots: []const Slot, contents: []Contents) !void {
        if (slots.len > 128 or slots.len != contents.len)
            return error.WorkingSetTooLarge;

        var keys: [128][18]u8 = undefined;
        var slices: [128][]const u8 = undefined;
        var leases: [128]SlotCache.Lease = undefined;

        for (slots, 0..) |slot, index| {
            keys[index] = encodeKey(slot);
            slices[index] = &keys[index];
        }

        try self.cache.acquireMany(slices[0..slots.len], leases[0..slots.len]);
        defer for (leases[0..slots.len]) |lease| lease.release();

        for (contents, leases[0..slots.len]) |*value, lease|
            value.* = try decode(lease.read());
    }

    /// Validates every revision before changing any slot. Slots must be distinct.
    pub fn editMany(self: *Inventories, edits: []const Edit) !bool {
        if (edits.len > 128)
            return error.WorkingSetTooLarge;

        var keys: [128][18]u8 = undefined;
        var slices: [128][]const u8 = undefined;
        var leases: [128]SlotCache.Lease = undefined;

        for (edits, 0..) |edit, index| {
            for (edits[0..index]) |previous|
                assert(!std.meta.eql(previous.slot, edit.slot));

            if (edit.stack) |stack|
                if (stack.count == 0)
                    return error.InvalidArgument;

            keys[index] = encodeKey(edit.slot);
            slices[index] = &keys[index];
        }

        try self.cache.acquireMany(slices[0..edits.len], leases[0..edits.len]);
        defer for (leases[0..edits.len]) |lease| lease.release();

        for (edits, leases[0..edits.len]) |edit, lease| {
            if ((try decode(lease.read())).revision != edit.revision)
                return false;

            if (edit.revision == std.math.maxInt(u64))
                return error.RevisionExhausted;
        }

        for (edits, leases[0..edits.len]) |edit, lease| {
            try self.changeReferences((try decode(lease.read())).stack, edit.stack);
            encode(.{ .stack = edit.stack, .revision = edit.revision + 1 }, lease.edit());
            lease.commit(encoded_bytes);
        }

        return true;
    }

    pub fn set(self: *Inventories, slot: Slot, expected_revision: u64, stack: ?Stack) !bool {
        if (stack) |value|
            if (value.count == 0)
                return error.InvalidArgument;

        const key = encodeKey(slot);
        const lease = try self.cache.acquire(&key);
        defer lease.release();

        const old = try decode(lease.read());
        if (old.revision != expected_revision)
            return false;

        if (old.revision == std.math.maxInt(u64))
            return error.RevisionExhausted;

        try self.changeReferences(old.stack, stack);
        encode(.{ .stack = stack, .revision = old.revision + 1 }, lease.edit());
        lease.commit(encoded_bytes);
        return true;
    }

    pub fn move(self: *Inventories, request: Move) !MoveResult {
        if (std.meta.eql(request.from, request.to) or request.count == 0 or request.maximum_stack == 0)
            return error.InvalidArgument;

        const source_key = encodeKey(request.from);
        const destination_key = encodeKey(request.to);
        var leases: [2]SlotCache.Lease = undefined;
        try self.cache.acquireMany(&.{ &source_key, &destination_key }, &leases);
        defer for (leases) |lease| lease.release();
        var source = try decode(leases[0].read());
        var destination = try decode(leases[1].read());
        if (source.revision != request.from_revision or destination.revision != request.to_revision)
            return .stale;

        const existing = source.stack orelse return .empty;
        if (existing.count < request.count)
            return .empty;

        if (destination.stack) |stack| {
            if (!Stack.sameItem(existing, stack))
                return .incompatible;

            if (stack.count > request.maximum_stack or request.count > request.maximum_stack - stack.count)
                return .full;
        } else if (request.count > request.maximum_stack) return .full;
        if (source.revision == std.math.maxInt(u64) or destination.revision == std.math.maxInt(u64))
            return error.RevisionExhausted;

        const old_source = source.stack;
        const old_destination = destination.stack;
        const destination_count = if (destination.stack) |stack| stack.count else @as(u16, 0);
        destination.stack = .{ .item = existing.item, .count = destination_count + request.count };
        source.stack = if (existing.count == request.count) null else .{ .item = existing.item, .count = existing.count - request.count };
        source.revision += 1;
        destination.revision += 1;
        try self.changeReferences(old_source, source.stack);
        try self.changeReferences(old_destination, destination.stack);
        encode(source, leases[0].edit());
        encode(destination, leases[1].edit());
        leases[0].commit(encoded_bytes);
        leases[1].commit(encoded_bytes);
        assert((if (source.stack) |stack| stack.count else @as(u16, 0)) + @as(u32, request.count) == existing.count);
        return .moved;
    }

    fn changeReferences(self: *Inventories, previous: ?Stack, next: ?Stack) !void {
        errdefer self.deps.storage.fail();
        if (previous != null and next != null and std.mem.eql(u8, &previous.?.item, &next.?.item)) return;
        if (next) |stack| try self.adjustReference(stack.item, true);
        if (previous) |stack| try self.adjustReference(stack.item, false);
    }

    fn adjustReference(self: *Inventories, item: ItemId, retain: bool) !void {
        errdefer self.deps.storage.fail();
        const key = item;
        const lease = try self.references.acquire(&key);
        defer lease.release();
        const bytes = lease.read() orelse return error.UnknownItem;
        if (bytes.len != 8) return error.Corrupt;
        const count = std.mem.readInt(u64, bytes[0..8], .little);
        if ((!retain and count == 0) or (retain and count == std.math.maxInt(u64))) return error.InvalidItemReference;
        std.mem.writeInt(u64, lease.edit()[0..8], if (retain) count + 1 else count - 1, .little);
        lease.commit(8);
    }

    /// Retain when assigning persistent state outside slots. Checkpoint hooks only serialize that state.
    pub fn retainItems(self: *Inventories, items: []const ItemId) !void {
        for (items) |item| try self.adjustReference(item, true);
    }
    pub fn releaseItems(self: *Inventories, items: []const ItemId) !void {
        for (items) |item| try self.adjustReference(item, false);
    }

    pub fn checkpoint(self: *Inventories, _: storage.Space) !void {
        errdefer self.deps.storage.fail();
        try self.items.flush();
        try self.cache.flush();
        try self.references.flush();
        var after: [32]u8 = undefined;
        var cursor: records.ScanCursor = .{ .after = &after };
        var keys: [16][32]u8 = undefined;
        var values: [16][1]u8 = undefined;
        var entries: [16]records.ScanEntry = undefined;
        for (&entries, &keys, &values) |*entry, *key, *value| entry.* = .{ .key = key, .value = value };
        while (true) {
            const batch = try self.references.backend.retired.scan(&cursor, &entries);
            for (entries[0..batch.count]) |entry| {
                if (entry.key_len != 32) return error.Corrupt;
                const key = entry.key[0..entry.key_len];
                const count = try self.references.acquire(key);
                defer count.release();
                const bytes = count.read() orelse return error.Corrupt;
                if (bytes.len != 8 or std.mem.readInt(u64, bytes[0..8], .little) != 0) return error.Corrupt;
                const definition = try self.items.acquire(key);
                defer definition.release();
                if (definition.read() == null) return error.Corrupt;
                definition.remove();
                count.remove();
            }
            try self.items.flush();
            try self.references.flush();
            if (!batch.more) break;
        }
    }
};

const encoded_bytes = 42;

fn encodeKey(slot: Slot) [18]u8 {
    var bytes: [18]u8 = undefined;
    std.mem.writeInt(u128, bytes[0..16], slot.owner, .big);
    std.mem.writeInt(u16, bytes[16..18], slot.index, .big);
    return bytes;
}

fn encode(contents: Contents, bytes: []u8) void {
    assert(bytes.len == encoded_bytes);
    bytes[0..32].* = if (contents.stack) |stack| stack.item else @splat(0);
    std.mem.writeInt(u16, bytes[32..34], if (contents.stack) |stack| stack.count else 0, .little);
    std.mem.writeInt(u64, bytes[34..42], contents.revision, .little);
}

fn decode(value: ?[]const u8) !Contents {
    const bytes = value orelse return .{};
    if (bytes.len != encoded_bytes)
        return error.Corrupt;

    const count = std.mem.readInt(u16, bytes[32..34], .little);
    return .{
        .stack = if (count == 0) null else .{ .item = bytes[0..32].*, .count = count },
        .revision = std.mem.readInt(u64, bytes[34..42], .little),
    };
}
