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
        record_workspaces: *records.Workspaces,
        metrics: *metrics.Registry,
        storage: storage.Space,
    };

    deps: Dependencies,
    config: Configuration,
    cache: SlotCache,
    items: records.Cache,
    references: ReferenceCache,
    verified: []Stamp,

    observers: ?*Observer = null,

    pub const Observer = struct {
        pub const Target = struct { dirty: *u64, changed: ?storage.system.IndexSet.Signal = null };
        const Entry = struct { slots: []const u16, target: Target };
        next: ?*Observer = null,
        revision: u64 = 0,
        owners: std.AutoHashMapUnmanaged(u128, Entry) = .empty,

        /// Slots and target storage stay borrowed until unwatch or removal. Mark a bit when changing its slot number.
        pub fn watch(self: *Observer, owner: u128, slots: []const u16, target: Target) void {
            assert(slots.len > 0 and slots.len <= 64 and !self.owners.contains(owner));
            for (slots, 0..) |slot, index| for (slots[0..index]) |previous| assert(slot != previous);
            self.revision += 1;
            self.owners.putAssumeCapacityNoClobber(owner, .{ .slots = slots, .target = target });
            target.dirty.* |= @as(u64, std.math.maxInt(u64)) >> @intCast(64 - slots.len);
            if (target.changed) |signal| signal.notify();
        }

        pub fn unwatch(self: *Observer, owner: u128) void {
            self.revision += 1;
            const removed = self.owners.remove(owner);
            assert(removed);
        }
    };

    pub fn observe(self: *Inventories, allocator: std.mem.Allocator, capacity: usize) !*Observer {
        const observer = try allocator.create(Observer);
        errdefer allocator.destroy(observer);
        observer.* = .{ .next = self.observers };
        try observer.owners.ensureTotalCapacity(allocator, @intCast(capacity));
        self.observers = observer;
        return observer;
    }

    pub fn unobserve(self: *Inventories, allocator: std.mem.Allocator, observer: *Observer) void {
        var entry = &self.observers;
        while (entry.* != observer) entry = &entry.*.?.next;
        entry.* = observer.next;
        observer.owners.deinit(allocator);
        allocator.destroy(observer);
    }

    fn changed(self: *Inventories, slot: Slot) void {
        var next = self.observers;
        while (next) |observer| : (next = observer.next) {
            if (observer.owners.get(slot.owner)) |entry| {
                for (entry.slots, 0..) |number, index| {
                    if (slot.index == number) {
                        entry.target.dirty.* |= @as(u64, 1) << @intCast(index);
                        observer.revision += 1;
                        if (entry.target.changed) |signal| signal.notify();
                        break;
                    }
                }
            }
        }
    }

    const Stamp = struct { generation: u64 = 0, revision: u64 = 0 };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration, deps: Dependencies) !*Inventories {
        const self = try allocate(allocator, io, config, deps);
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
        self.cache.backend.index.directory = root;
        self.references.backend.counts.directory = root;
        self.references.backend.retired.directory = root;
        self.items.backend.directory = root;
        return self;
    }

    pub fn allocate(allocator: std.mem.Allocator, io: std.Io, config: Configuration, deps: Dependencies) !*Inventories {
        const table_resources = deps.record_workspaces.resources;
        if (config.cache_slots < 2 or config.cache_items == 0 or config.max_item_bytes == 0) return error.InvalidArgument;
        var slots = try Slots.init(allocator, .{ .space = deps.storage, .root_offset = 8, .resources = table_resources }, @min(config.cache_slots, Slots.write_batch_size));
        errdefer slots.deinit(allocator);
        const self = try allocator.create(Inventories);
        self.* = .{
            .verified = try allocator.alloc(Stamp, config.cache_items),
            .deps = deps,
            .config = config,
            .cache = try SlotCache.init(allocator, io, slots, .{
                .metrics = deps.metrics,
                .metrics_namespace = "inventories.slots",
                .slots = config.cache_slots,
                .key_bytes = 18,
                .value_bytes = encoded_bytes,
            }),
            .references = try ReferenceCache.init(allocator, io, .{ .counts = .{ .space = deps.storage, .root_offset = 24, .resources = table_resources }, .retired = .{ .space = deps.storage, .root_offset = 32, .resources = table_resources } }, .{
                .metrics = deps.metrics,
                .metrics_namespace = "inventories.references",
                .slots = @max(128, config.cache_items),
                .key_bytes = 32,
                .value_bytes = 8,
            }),
            .items = try records.Cache.init(allocator, io, .{ .space = deps.storage, .root_offset = 16, .resources = table_resources }, .{
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
    pub fn defineItem(self: *Inventories, parts: []const []const u8) !ItemId {
        var length: usize = 0;
        var hash = std.crypto.hash.Blake3.init(.{});
        for (parts) |part| {
            if (part.len > self.config.max_item_bytes - length) return error.ItemTooLarge;
            length += part.len;
            hash.update(part);
        }
        if (length == 0) return error.ItemTooLarge;
        var item: ItemId = undefined;
        hash.final(&item);
        const key = item;
        const lease = try self.items.acquire(&key);
        defer lease.release();
        if (lease.read() == null) {
            const destination = lease.edit();
            var offset: usize = 0;
            for (parts) |part| {
                @memcpy(destination[offset..][0..part.len], part);
                offset += part.len;
            }
            lease.commit(length);
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
        self.changed(slot);
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

        var references: ReferenceChanges = .{};
        for (edits, leases[0..edits.len]) |edit, lease| {
            references.change((try decode(lease.read())).stack, edit.stack);
        }
        try self.adjustReferences(&references);
        for (edits, leases[0..edits.len]) |edit, lease| {
            encode(.{ .stack = edit.stack, .revision = edit.revision + 1 }, lease.edit());
            lease.commit(encoded_bytes);
            self.changed(edit.slot);
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
        self.changed(slot);
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
        var references: ReferenceChanges = .{};
        references.change(old_source, source.stack);
        references.change(old_destination, destination.stack);
        try self.adjustReferences(&references);
        encode(source, leases[0].edit());
        encode(destination, leases[1].edit());
        leases[0].commit(encoded_bytes);
        leases[1].commit(encoded_bytes);
        self.changed(request.from);
        self.changed(request.to);
        assert((if (source.stack) |stack| stack.count else @as(u16, 0)) + @as(u32, request.count) == existing.count);
        return .moved;
    }

    const ReferenceChanges = struct {
        const Change = struct {
            item: ItemId,
            delta: i64,
            fn lessThan(_: void, a: Change, b: Change) bool {
                return std.mem.order(u8, &a.item, &b.item) == .lt;
            }
        };
        entries: [256]Change = undefined,
        count: usize = 0,

        fn add(self: *ReferenceChanges, item: ItemId, delta: i64) void {
            assert(self.count < self.entries.len);
            self.entries[self.count] = .{ .item = item, .delta = delta };
            self.count += 1;
        }

        fn coalesce(self: *ReferenceChanges) void {
            std.sort.pdq(Change, self.entries[0..self.count], {}, Change.lessThan);
            var count: usize = 0;
            for (self.entries[0..self.count]) |entry| {
                if (count != 0 and std.mem.eql(u8, &self.entries[count - 1].item, &entry.item)) {
                    self.entries[count - 1].delta += entry.delta;
                } else {
                    self.entries[count] = entry;
                    count += 1;
                }
            }
            self.count = count;
        }

        fn change(self: *ReferenceChanges, previous: ?Stack, next: ?Stack) void {
            if (previous) |stack| self.add(stack.item, -1);
            if (next) |stack| self.add(stack.item, 1);
        }
    };

    fn changeReferences(self: *Inventories, previous: ?Stack, next: ?Stack) !void {
        var changes: ReferenceChanges = .{};
        changes.change(previous, next);
        try self.adjustReferences(&changes);
    }

    fn adjustReferences(self: *Inventories, changes: *ReferenceChanges) !void {
        errdefer self.deps.storage.fail();
        changes.coalesce();
        var keys: [128][]const u8 = undefined;
        var deltas: [128]i64 = undefined;
        var leases: [128]ReferenceCache.Lease = undefined;
        var cursor: usize = 0;
        while (cursor < changes.count) {
            var count: usize = 0;
            while (cursor < changes.count and count < keys.len) : (cursor += 1) {
                if (changes.entries[cursor].delta == 0) continue;
                keys[count] = &changes.entries[cursor].item;
                deltas[count] = changes.entries[cursor].delta;
                count += 1;
            }
            if (count == 0) continue;
            try self.references.acquireMany(keys[0..count], leases[0..count]);
            defer for (leases[0..count]) |lease| lease.release();
            var updated: [128]u64 = undefined;
            for (leases[0..count], deltas[0..count], updated[0..count]) |lease, delta, *value| {
                const bytes = lease.read() orelse return error.UnknownItem;
                if (bytes.len != 8) return error.Corrupt;
                const previous = std.mem.readInt(u64, bytes[0..8], .little);
                const result = @as(i128, previous) + delta;
                if (result < 0 or result > std.math.maxInt(u64)) return error.InvalidItemReference;
                value.* = @intCast(result);
            }
            for (leases[0..count], updated[0..count]) |lease, value| {
                std.mem.writeInt(u64, lease.edit()[0..8], value, .little);
                lease.commit(8);
            }
        }
    }

    /// Retain when assigning persistent state outside slots. Checkpoint hooks only serialize that state.
    pub fn retainItems(self: *Inventories, items: []const ItemId) !void {
        try self.changeItems(items, 1);
    }

    pub fn releaseItems(self: *Inventories, items: []const ItemId) !void {
        try self.changeItems(items, -1);
    }

    fn changeItems(self: *Inventories, items: []const ItemId, delta: i64) !void {
        var cursor: usize = 0;
        while (cursor < items.len) {
            const count = @min(items.len - cursor, 128);
            var changes: ReferenceChanges = .{};
            for (items[cursor..][0..count]) |item| changes.add(item, delta);
            try self.adjustReferences(&changes);
            cursor += count;
        }
    }

    pub fn checkpoint(self: *Inventories, _: storage.Space) !void {
        errdefer self.deps.storage.fail();
        try self.items.flush();
        try self.cache.flush();
        try self.references.flush();
        var after: [32]u8 = undefined;
        var cursor: records.ScanCursor = .{ .after = &after };
        var keys: [records.Table.write_batch_size][32]u8 = undefined;
        var values: [records.Table.write_batch_size][1]u8 = undefined;
        var entries: [records.Table.write_batch_size]records.ScanEntry = undefined;
        for (&entries, &keys, &values) |*entry, *key, *value| entry.* = .{ .key = key, .value = value };
        while (true) {
            const batch = try self.references.backend.retired.scan(&cursor, &entries);
            var cursor_in_batch: usize = 0;
            while (cursor_in_batch < batch.count) {
                const count = @min(batch.count - cursor_in_batch, self.items.entries.len);
                var slices: [records.Table.write_batch_size][]const u8 = undefined;
                var counts: [records.Table.write_batch_size]ReferenceCache.Lease = undefined;
                var definitions: [records.Table.write_batch_size]records.Cache.Lease = undefined;
                for (entries[cursor_in_batch..][0..count], slices[0..count]) |entry, *key| {
                    if (entry.key_len != 32) return error.Corrupt;
                    key.* = entry.key[0..entry.key_len];
                }
                try self.references.acquireMany(slices[0..count], counts[0..count]);
                defer for (counts[0..count]) |lease| lease.release();
                try self.items.acquireMany(slices[0..count], definitions[0..count]);
                defer for (definitions[0..count]) |lease| lease.release();
                for (counts[0..count], definitions[0..count]) |reference, definition| {
                    const bytes = reference.read() orelse return error.Corrupt;
                    if (bytes.len != 8 or std.mem.readInt(u64, bytes[0..8], .little) != 0) return error.Corrupt;
                    if (definition.read() == null) return error.Corrupt;
                }
                for (counts[0..count], definitions[0..count]) |reference, definition| {
                    definition.remove();
                    reference.remove();
                }
                cursor_in_batch += count;
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
