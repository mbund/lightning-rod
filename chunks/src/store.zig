const std = @import("std");
const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");

const tile_side = 2;
const tile_sections = tile_side * tile_side;
const header_bytes = tile_sections * @sizeOf(u16);
const section_bytes = 8193;
const tile_bytes = header_bytes + tile_sections * section_bytes;

pub const Store = struct {
    tiles: records.Cache,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, space: storage.Space, capacity: usize, registry: *metrics.Registry) !Store {
        if (capacity == 0) return error.InvalidArgument;
        const root = try space.getRoot() orelse blk: {
            var ids: [1]storage.PageId = undefined;
            try space.allocatePages(&ids);
            var page: storage.Page = @splat(0);
            @memcpy(page[0..8], "LRCHNK02");
            try space.writePages(&.{.{ .id = ids[0], .source = &page }});
            try space.setRoot(ids[0]);
            break :blk ids[0];
        };
        var page: storage.Page = undefined;
        try space.readPages(&.{.{ .id = root, .destination = &page }});
        if (!std.mem.eql(u8, page[0..8], "LRCHNK02")) return error.Corrupt;
        return .{ .tiles = try records.Cache.init(allocator, io, records.Table.rooted(space, root, 8), .{
            .slots = capacity,
            .key_bytes = 16,
            .value_bytes = tile_bytes,
            .metrics = registry,
            .metrics_namespace = "chunks.tiles",
        }) };
    }

    const Address = struct { key: [16]u8, part: usize };
    fn address(key: []const u8) !Address {
        if (key.len != 16) return error.InvalidArgument;
        const x = std.mem.readInt(i32, key[4..8], .big);
        const z = std.mem.readInt(i32, key[8..12], .big);
        var result: Address = .{ .key = undefined, .part = @intCast(@mod(x, tile_side) * tile_side + @mod(z, tile_side)) };
        @memcpy(result.key[0..4], key[0..4]);
        std.mem.writeInt(i32, result.key[4..8], @divFloor(x, tile_side), .big);
        std.mem.writeInt(i32, result.key[8..12], @divFloor(z, tile_side), .big);
        @memcpy(result.key[12..16], key[12..16]);
        return result;
    }

    const Location = struct { begin: usize = header_bytes, end: usize = header_bytes, total: usize = header_bytes };
    fn locate(bytes: ?[]const u8, part: usize) !Location {
        var result: Location = .{};
        const value = bytes orelse return result;
        if (value.len < header_bytes or value.len > tile_bytes) return error.Corrupt;
        for (0..tile_sections) |index| {
            const length = std.mem.readInt(u16, value[index * 2 ..][0..2], .little);
            if (length > section_bytes or length > value.len - result.total) return error.Corrupt;
            if (length != 0 and (length < 3 or value[result.total] > 2 or (value[result.total] == 0 and length != 3) or (value[result.total] == 1 and length != section_bytes))) return error.Corrupt;
            if (index == part) {
                result.begin = result.total;
                result.end = result.total + length;
            }
            result.total += length;
        }
        if (result.total != value.len) return error.Corrupt;
        return result;
    }

    pub fn getBatch(self: *Store, requests: []const records.Get, lengths: []?usize) !void {
        if (requests.len != lengths.len) return error.InvalidArgument;
        var begin: usize = 0;
        while (begin < requests.len) {
            const count: usize = @min(192, self.tiles.entries.len, requests.len - begin);
            var addresses: [192]Address = undefined;
            var keys: [192][]const u8 = undefined;
            var leases: [192]records.Cache.Lease = undefined;
            for (requests[begin..][0..count], addresses[0..count], keys[0..count]) |request, *at, *key| {
                at.* = try address(request.key);
                key.* = &at.key;
            }
            try self.tiles.acquireMany(keys[0..count], leases[0..count]);
            defer for (leases[0..count]) |lease| lease.release();
            for (requests[begin..][0..count], addresses[0..count], leases[0..count], lengths[begin..][0..count]) |request, at, lease, *length| {
                const bytes = lease.read();
                const location = try locate(bytes, at.part);
                const size = location.end - location.begin;
                length.* = if (size == 0) null else size;
                if (size > request.destination.len) return error.BufferTooSmall;
                if (size != 0) @memcpy(request.destination[0..size], bytes.?[location.begin..location.end]);
            }
            begin += count;
        }
    }

    pub fn putBatch(self: *Store, writes: []const records.Write) !void {
        errdefer self.fail();
        var begin: usize = 0;
        while (begin < writes.len) {
            const count: usize = @min(192, self.tiles.entries.len, writes.len - begin);
            var addresses: [192]Address = undefined;
            var keys: [192][]const u8 = undefined;
            var leases: [192]records.Cache.Lease = undefined;
            for (writes[begin..][0..count], addresses[0..count], keys[0..count]) |write, *at, *key| {
                at.* = try address(write.key);
                key.* = &at.key;
            }
            try self.tiles.acquireMany(keys[0..count], leases[0..count]);
            defer for (leases[0..count]) |lease| lease.release();
            for (writes[begin..][0..count], addresses[0..count], leases[0..count]) |write, at, lease| {
                const old = lease.read();
                const location = try locate(old, at.part);
                const value = write.value orelse &.{};
                if (value.len > section_bytes or (value.len != 0 and (value.len < 3 or value[0] > 2 or (value[0] == 0 and value.len != 3) or (value[0] == 1 and value.len != section_bytes)))) return error.InvalidArgument;
                if (old) |bytes| {
                    if (std.mem.eql(u8, bytes[location.begin..location.end], value)) continue;
                } else if (value.len == 0) continue;
                const length = location.total - (location.end - location.begin) + value.len;
                if (length == header_bytes) {
                    lease.remove();
                    continue;
                }
                const bytes = lease.edit();
                if (old == null) @memset(bytes[0..header_bytes], 0);
                const tail = bytes[location.end..location.total];
                const moved = bytes[location.begin + value.len .. length];
                if (value.len > location.end - location.begin) std.mem.copyBackwards(u8, moved, tail) else std.mem.copyForwards(u8, moved, tail);
                @memcpy(bytes[location.begin..][0..value.len], value);
                std.mem.writeInt(u16, bytes[at.part * 2 ..][0..2], @intCast(value.len), .little);
                lease.commit(length);
            }
            begin += count;
        }
    }

    pub fn flush(self: *Store) !void {
        try self.tiles.flush();
    }

    pub fn fail(self: Store) void {
        self.tiles.backend.fail();
    }
};
