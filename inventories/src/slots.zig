const std = @import("std");
const storage = @import("storage");
const records = @import("records");

const assert = std.debug.assert;

const slot_bytes = 42;
const slots_per_block = @bitSizeOf(u16);
const maximum_block_bytes = 2 + slots_per_block * slot_bytes;
const maximum_batch = 192;

pub const Slots = struct {
    pub const write_batch_size = maximum_batch;
    index: records.Table,
    keys: [][18]u8,
    values: [][maximum_block_bytes]u8,
    reads: []records.Get,
    sizes: []?usize,
    mapping: []usize,
    updates: []records.Write,
    order: []u16,
    old: [maximum_block_bytes]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, index: records.Table, capacity: usize) !Slots {
        if (capacity == 0 or capacity > maximum_batch) return error.InvalidArgument;
        const keys = try allocator.alloc([18]u8, capacity);
        errdefer allocator.free(keys);
        const values = try allocator.alloc([maximum_block_bytes]u8, capacity);
        errdefer allocator.free(values);
        const reads = try allocator.alloc(records.Get, capacity);
        errdefer allocator.free(reads);
        const sizes = try allocator.alloc(?usize, capacity);
        errdefer allocator.free(sizes);
        const mapping = try allocator.alloc(usize, capacity);
        errdefer allocator.free(mapping);
        const updates = try allocator.alloc(records.Write, capacity);
        errdefer allocator.free(updates);
        const order = try allocator.alloc(u16, capacity);
        return .{ .index = index, .keys = keys, .values = values, .reads = reads, .sizes = sizes, .mapping = mapping, .updates = updates, .order = order };
    }

    pub fn deinit(self: *Slots, allocator: std.mem.Allocator) void {
        allocator.free(self.order);
        allocator.free(self.updates);
        allocator.free(self.mapping);
        allocator.free(self.sizes);
        allocator.free(self.reads);
        allocator.free(self.values);
        allocator.free(self.keys);
        self.* = undefined;
    }

    const Address = struct { block: [18]u8, slot: u4 };

    fn address(key: []const u8) storage.Error!Address {
        if (key.len != 18) return error.InvalidArgument;
        const slot = std.mem.readInt(u16, key[16..18], .big);
        var result: Address = .{ .block = undefined, .slot = @intCast(slot % slots_per_block) };
        @memcpy(result.block[0..16], key[0..16]);
        std.mem.writeInt(u16, result.block[16..18], slot / slots_per_block, .big);
        return result;
    }

    pub fn getBatch(self: *Slots, requests: []const records.Get, lengths: []?usize) storage.Error!void {
        if (requests.len != lengths.len or requests.len > self.values.len) return error.InvalidArgument;
        const keys = self.keys;
        const values = self.values;
        const reads = self.reads;
        const sizes = self.sizes;
        const mapping = self.mapping;
        const order = self.order[0..requests.len];
        var sorted = true;
        for (requests, order, 0..) |request, *position, index| {
            if (request.key.len != 18) return error.InvalidArgument;
            position.* = @intCast(index);
            if (index != 0 and sorted) sorted = std.mem.order(u8, requests[index - 1].key, request.key) != .gt;
        }
        if (!sorted) std.mem.sort(u16, order, requests, struct {
            fn less(items: []const records.Get, a: u16, b: u16) bool {
                return std.mem.order(u8, items[a].key, items[b].key) == .lt;
            }
        }.less);
        var count: usize = 0;
        for (order) |position| {
            const at = try address(requests[position].key);
            if (count == 0 or !std.mem.eql(u8, &keys[count - 1], &at.block)) {
                keys[count] = at.block;
                reads[count] = .{ .key = &keys[count], .destination = &values[count] };
                count += 1;
            }
            mapping[position] = count - 1;
        }
        assert(count <= requests.len and count <= values.len);
        try self.index.getBatch(reads[0..count], sizes[0..count]);
        for (requests, lengths, mapping[0..requests.len]) |request, *length, block| {
            const size = sizes[block] orelse {
                length.* = null;
                continue;
            };
            if (size < 2) return error.Corrupt;
            const mask = std.mem.readInt(u16, values[block][0..2], .little);
            if (size != 2 + @as(usize, @popCount(mask)) * slot_bytes) return error.Corrupt;
            const at = try address(request.key);
            const bit = @as(u16, 1) << at.slot;
            if (mask & bit == 0) {
                length.* = null;
                continue;
            }
            if (request.destination.len < slot_bytes) return error.BufferTooSmall;
            const offset = 2 + @as(usize, @popCount(mask & (bit - 1))) * slot_bytes;
            @memcpy(request.destination[0..slot_bytes], values[block][offset..][0..slot_bytes]);
            length.* = slot_bytes;
        }
    }

    pub fn putBatch(self: *Slots, writes: []const records.Write) storage.Error!void {
        errdefer self.fail();
        if (writes.len > self.values.len) return error.InvalidArgument;
        const order = self.order;
        for (order[0..writes.len], 0..) |*index, at| index.* = @intCast(at);
        std.mem.sort(u16, order[0..writes.len], writes, struct {
            fn less(items: []const records.Write, a: u16, b: u16) bool {
                const result = std.mem.order(u8, items[a].key, items[b].key);
                return if (result == .eq) a < b else result == .lt;
            }
        }.less);
        const keys = self.keys;
        const values = self.values;
        const reads = self.reads;
        const sizes = self.sizes;
        const updates = self.updates;
        var count: usize = 0;
        for (order[0..writes.len]) |position| {
            const at = try address(writes[position].key);
            if (count != 0 and std.mem.eql(u8, &keys[count - 1], &at.block)) continue;
            keys[count] = at.block;
            reads[count] = .{ .key = &keys[count], .destination = &values[count] };
            count += 1;
        }
        assert(count <= writes.len and count <= values.len);
        try self.index.getBatch(reads[0..count], sizes[0..count]);
        var next: usize = 0;
        for (keys[0..count], values[0..count], sizes[0..count], updates[0..count]) |*key, *value, size, *update| {
            var mask: u16 = 0;
            if (size) |length| {
                if (length < 2) return error.Corrupt;
                mask = std.mem.readInt(u16, value[0..2], .little);
                if (length != 2 + @as(usize, @popCount(mask)) * slot_bytes) return error.Corrupt;
            }
            const old_mask = mask;
            var replacements: [slots_per_block]?[]const u8 = @splat(null);
            while (next < writes.len) {
                const write = writes[order[next]];
                const at = try address(write.key);
                if (!std.mem.eql(u8, key, &at.block)) break;
                const bit = @as(u16, 1) << at.slot;
                if (write.value) |bytes| {
                    if (bytes.len != slot_bytes) return error.InvalidArgument;
                    replacements[at.slot] = bytes;
                    mask |= bit;
                } else mask &= ~bit;
                next += 1;
            }
            const old = &self.old;
            if (mask != old_mask) @memcpy(old[0 .. size orelse 0], value[0 .. size orelse 0]);
            std.mem.writeInt(u16, value[0..2], mask, .little);
            var length: usize = 2;
            for (replacements, 0..) |replacement, at| {
                const bit = @as(u16, 1) << @intCast(at);
                if (mask & bit == 0) continue;
                if (replacement) |bytes| {
                    @memcpy(value[length..][0..slot_bytes], bytes);
                } else if (mask != old_mask) {
                    const offset = 2 + @as(usize, @popCount(old_mask & (bit - 1))) * slot_bytes;
                    @memcpy(value[length..][0..slot_bytes], old[offset..][0..slot_bytes]);
                }
                length += slot_bytes;
            }
            update.* = .{ .key = key, .value = if (mask == 0) null else value[0..length] };
        }
        try self.index.putBatch(updates[0..count]);
    }

    pub fn fail(self: *Slots) void {
        self.index.fail();
    }
};
