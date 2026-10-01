const std = @import("std");
const storage = @import("storage");
const records = @import("records");

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
        storage: storage.Namespace,
    };

    deps: Dependencies,
    config: Configuration,
    cache: records.Cache,
    items: records.Cache,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration, deps: Dependencies) !*Inventories {
        if (config.cache_slots < 2 or config.cache_items == 0 or config.max_item_bytes == 0) return error.InvalidArgument;

        const self = try allocator.create(Inventories);
        self.* = .{
            .deps = deps,
            .config = config,
            .cache = try records.Cache.init(allocator, io, deps.storage, .{
                .slots = config.cache_slots,
                .key_bytes = 19,
                .value_bytes = encoded_bytes,
            }),
            .items = try records.Cache.init(allocator, io, deps.storage, .{
                .slots = config.cache_items,
                .key_bytes = 33,
                .value_bytes = config.max_item_bytes,
            }),
        };
        return self;
    }

    /// Item definitions are immutable, content-addressed canonical bytes.
    /// Moving a stack changes ownership records, never copies its item payload.
    pub fn defineItem(self: *Inventories, encoded: []const u8) !ItemId {
        if (encoded.len == 0 or encoded.len > self.config.max_item_bytes)
            return error.ItemTooLarge;

        var item: ItemId = undefined;
        std.crypto.hash.Blake3.hash(encoded, &item, .{});
        var key: [33]u8 = undefined;
        key[0] = 2;
        key[1..].* = item;
        const lease = try self.items.acquire(&key);
        defer lease.release();

        if (lease.read() == null) {
            @memcpy(lease.edit()[0..encoded.len], encoded);
            lease.commit(encoded.len);
        }

        return item;
    }

    pub fn acquireItem(self: *Inventories, item: ItemId) !records.Cache.Lease {
        var key: [33]u8 = undefined;
        key[0] = 2;
        key[1..].* = item;

        const lease = try self.items.acquire(&key);
        errdefer lease.release();

        const bytes = lease.read() orelse return error.UnknownItem;
        if (bytes.len == 0 or bytes.len > self.config.max_item_bytes)
            return error.Corrupt;

        var digest: ItemId = undefined;
        std.crypto.hash.Blake3.hash(bytes, &digest, .{});
        if (!std.mem.eql(u8, &digest, &item))
            return error.Corrupt;

        return lease;
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
        assert((try decode(lease.read())).stack == null);
        lease.remove();
    }

    pub fn getMany(self: *Inventories, slots: []const Slot, contents: []Contents) !void {
        if (slots.len > 128 or slots.len != contents.len)
            return error.WorkingSetTooLarge;

        var keys: [128][19]u8 = undefined;
        var slices: [128][]const u8 = undefined;
        var leases: [128]records.Cache.Lease = undefined;

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

        var keys: [128][19]u8 = undefined;
        var slices: [128][]const u8 = undefined;
        var leases: [128]records.Cache.Lease = undefined;

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

        encode(.{ .stack = stack, .revision = old.revision + 1 }, lease.edit());
        lease.commit(encoded_bytes);
        return true;
    }

    pub fn move(self: *Inventories, request: Move) !MoveResult {
        if (std.meta.eql(request.from, request.to) or request.count == 0 or request.maximum_stack == 0)
            return error.InvalidArgument;

        const source_key = encodeKey(request.from);
        const destination_key = encodeKey(request.to);
        var leases: [2]records.Cache.Lease = undefined;
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

        const source_bytes = leases[0].edit();
        const destination_bytes = leases[1].edit();
        const destination_count = if (destination.stack) |stack| stack.count else @as(u16, 0);
        destination.stack = .{ .item = existing.item, .count = destination_count + request.count };
        source.stack = if (existing.count == request.count) null else .{ .item = existing.item, .count = existing.count - request.count };
        source.revision += 1;
        destination.revision += 1;
        encode(source, source_bytes);
        encode(destination, destination_bytes);
        leases[0].commit(encoded_bytes);
        leases[1].commit(encoded_bytes);
        assert((if (source.stack) |stack| stack.count else @as(u16, 0)) + @as(u32, request.count) == existing.count);
        return .moved;
    }

    pub fn checkpoint(self: *Inventories, _: storage.Namespace) !void {
        try self.items.flush();
        try self.cache.flush();
    }
};

const encoded_bytes = 42;

fn encodeKey(slot: Slot) [19]u8 {
    var bytes: [19]u8 = undefined;
    bytes[0] = 1;
    std.mem.writeInt(u128, bytes[1..17], slot.owner, .big);
    std.mem.writeInt(u16, bytes[17..19], slot.index, .big);
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
