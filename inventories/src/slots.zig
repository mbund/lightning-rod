const std = @import("std");
const storage = @import("storage");
const records = @import("records");

const slot_bytes = 42;
const slots_per_block = @bitSizeOf(u16);
const maximum_block_bytes = 2 + slots_per_block * slot_bytes;
const maximum_batch = 192;

pub const Slots = struct {
    index: records.Table,
    const Address = struct { block: [18]u8, slot: u4 };

    fn address(key: []const u8) storage.Error!Address {
        if (key.len != 18) return error.InvalidArgument;
        const slot = std.mem.readInt(u16, key[16..18], .big);
        var result: Address = .{ .block = undefined, .slot = @intCast(slot % slots_per_block) };
        @memcpy(result.block[0..16], key[0..16]);
        std.mem.writeInt(u16, result.block[16..18], slot / slots_per_block, .big);
        return result;
    }

    pub fn getBatch(self: Slots, requests: []const records.Get, lengths: []?usize) storage.Error!void {
        if (requests.len != lengths.len or requests.len > maximum_batch) return error.InvalidArgument;
        var keys: [maximum_batch][18]u8 = undefined;
        var values: [maximum_batch][maximum_block_bytes]u8 = undefined;
        var reads: [maximum_batch]records.Get = undefined;
        var sizes: [maximum_batch]?usize = undefined;
        var mapping: [maximum_batch]usize = undefined;
        var count: usize = 0;
        for (requests, mapping[0..requests.len]) |request, *block| {
            const at = try address(request.key);
            var index: usize = 0;
            while (index < count and !std.mem.eql(u8, &keys[index], &at.block)) index += 1;
            block.* = index;
            if (index == count) {
                keys[count] = at.block;
                reads[count] = .{ .key = &keys[count], .destination = &values[count] };
                count += 1;
            }
        }
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

    pub fn putBatch(self: Slots, writes: []const records.Write) storage.Error!void {
        errdefer self.fail();
        if (writes.len > maximum_batch) return error.InvalidArgument;
        var order: [maximum_batch]u16 = undefined;
        for (order[0..writes.len], 0..) |*index, at| index.* = @intCast(at);
        std.mem.sort(u16, order[0..writes.len], writes, struct {
            fn less(items: []const records.Write, a: u16, b: u16) bool {
                const result = std.mem.order(u8, items[a].key, items[b].key);
                return if (result == .eq) a < b else result == .lt;
            }
        }.less);
        var keys: [maximum_batch][18]u8 = undefined;
        var values: [maximum_batch][maximum_block_bytes]u8 = undefined;
        var reads: [maximum_batch]records.Get = undefined;
        var sizes: [maximum_batch]?usize = undefined;
        var updates: [maximum_batch]records.Write = undefined;
        var count: usize = 0;
        for (order[0..writes.len]) |position| {
            const at = try address(writes[position].key);
            if (count != 0 and std.mem.eql(u8, &keys[count - 1], &at.block)) continue;
            keys[count] = at.block;
            reads[count] = .{ .key = &keys[count], .destination = &values[count] };
            count += 1;
        }
        try self.index.getBatch(reads[0..count], sizes[0..count]);
        var next: usize = 0;
        for (keys[0..count], values[0..count], sizes[0..count], updates[0..count]) |*key, *value, size, *update| {
            var slots: [slots_per_block][slot_bytes]u8 = undefined;
            var mask: u16 = 0;
            if (size) |length| {
                if (length < 2) return error.Corrupt;
                mask = std.mem.readInt(u16, value[0..2], .little);
                if (length != 2 + @as(usize, @popCount(mask)) * slot_bytes) return error.Corrupt;
                var offset: usize = 2;
                for (&slots, 0..) |*slot, at| {
                    if (mask & (@as(u16, 1) << @intCast(at)) == 0) continue;
                    @memcpy(slot, value[offset..][0..slot_bytes]);
                    offset += slot_bytes;
                }
            }
            while (next < writes.len) {
                const write = writes[order[next]];
                const at = try address(write.key);
                if (!std.mem.eql(u8, key, &at.block)) break;
                const bit = @as(u16, 1) << at.slot;
                if (write.value) |bytes| {
                    if (bytes.len != slot_bytes) return error.InvalidArgument;
                    @memcpy(&slots[at.slot], bytes);
                    mask |= bit;
                } else mask &= ~bit;
                next += 1;
            }
            std.mem.writeInt(u16, value[0..2], mask, .little);
            var length: usize = 2;
            for (&slots, 0..) |*slot, at| {
                if (mask & (@as(u16, 1) << @intCast(at)) == 0) continue;
                @memcpy(value[length..][0..slot_bytes], slot);
                length += slot_bytes;
            }
            update.* = .{ .key = key, .value = if (mask == 0) null else value[0..length] };
        }
        try self.index.putBatch(updates[0..count]);
    }

    pub fn fail(self: Slots) void {
        self.index.fail();
    }
};
