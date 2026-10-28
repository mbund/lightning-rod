const std = @import("std");
const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const encoding = @import("encoding.zig");

const tile_side = 2;
const tile_sections = tile_side * tile_side;
const header_bytes = tile_sections * @sizeOf(u16);
const section_bytes = 8193;
const tile_bytes = header_bytes + tile_sections * section_bytes;

pub const Store = struct {
    tiles: records.Cache,
    scratch: []u8,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    // Table pages mutate in place. Cached tiles remain independent of this lock.
    table_lock: std.Io.RwLock = .init,
    available: std.Io.Condition = .init,
    readers: usize = 0,
    writing: bool = false,
    draining: bool = false,
    mutating: []bool,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, space: storage.Space, capacity: usize, registry: *metrics.Registry, table_resources: *records.Resources) !Store {
        var self = try allocate(allocator, io, space, capacity, registry, table_resources);
        try self.open();
        return self;
    }

    pub fn open(self: *Store) !void {
        const space = self.tiles.backend.space;
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
        self.tiles.backend.directory = root;
    }

    pub fn allocate(allocator: std.mem.Allocator, io: std.Io, space: storage.Space, capacity: usize, registry: *metrics.Registry, table_resources: *records.Resources) !Store {
        if (capacity == 0) return error.InvalidArgument;
        const scratch = try allocator.alloc(u8, tile_bytes);
        errdefer allocator.free(scratch);
        const mutating = try allocator.alloc(bool, capacity);
        errdefer allocator.free(mutating);
        @memset(mutating, false);
        return .{ .io = io, .scratch = scratch, .mutating = mutating, .tiles = try records.Cache.init(allocator, io, .{ .space = space, .root_offset = 8, .resources = table_resources }, .{
            .slots = capacity,
            .key_bytes = 16,
            .value_bytes = tile_bytes,
            .metrics = registry,
            .metrics_namespace = "chunks.tiles",
        }) };
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

        fn plan(self: *Batch, input: []const []const u8, capacity: usize) !void {
            std.debug.assert(self.count == 0 and self.unique == 0);
            std.debug.assert(input.len > 0 and input.len <= self.addresses.len and capacity > 0);
            var buckets: [512]u16 = @splat(absent);
            for (input) |key| {
                const at = try address(key);
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
        try self.readBatch(requests, lengths, false);
    }

    pub fn decodeBatch(self: *Store, requests: []const records.Get, lengths: []?usize) !void {
        try self.readBatch(requests, lengths, true);
    }

    fn readBatch(self: *Store, requests: []const records.Get, lengths: []?usize, comptime decoded: bool) !void {
        if (requests.len != lengths.len) return error.InvalidArgument;
        var begin: usize = 0;
        while (begin < requests.len) {
            const offered: usize = @min(192, requests.len - begin);
            var input: [192][]const u8 = undefined;
            for (requests[begin..][0..offered], input[0..offered]) |request, *key| key.* = request.key;
            var batch: Batch = .{};
            try batch.plan(input[0..offered], self.tiles.entries.len);
            const count = batch.count;
            self.readWindow(&batch, requests[begin..][0..count], lengths[begin..][0..count], decoded) catch |err| switch (err) {
                error.WritebackRequired => {
                    try self.loadForEviction(batch.keys[0..batch.unique]);
                    continue;
                },
                else => return err,
            };
            begin += count;
        }
    }

    fn readWindow(self: *Store, batch: *const Batch, requests: []const records.Get, lengths: []?usize, comptime decoded: bool) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.draining) self.available.waitUncancelable(self.io, &self.mutex);
        self.readers += 1;
        defer {
            std.debug.assert(self.readers > 0);
            self.readers -= 1;
            self.available.broadcast(self.io);
        }
        var leases: [192]records.Cache.Lease = undefined;
        const held = leases[0..batch.unique];
        try self.loadTilesLocked(batch.keys[0..batch.unique], held, false);
        defer for (held) |lease| lease.release();
        var values: [192]?[]const u8 = undefined;
        for (held, values[0..held.len]) |lease, *value| value.* = lease.read();
        self.mutex.unlock(self.io);
        defer self.mutex.lockUncancelable(self.io);
        for (requests, batch.addresses[0..batch.count], batch.mapping[0..batch.count], lengths) |request, at, group, *length| {
            const bytes = values[group];
            const location = try locate(bytes, at.part);
            const size = location.end - location.begin;
            length.* = if (size == 0) null else size;
            if (size != 0) {
                const encoded = bytes.?[location.begin..location.end];
                if (decoded) {
                    length.* = try encoding.decodeTo(encoded, request.destination);
                } else {
                    if (size > request.destination.len) return error.BufferTooSmall;
                    @memcpy(request.destination[0..size], encoded);
                }
            }
        }
    }

    fn loadTilesLocked(self: *Store, keys: []const []const u8, held: []records.Cache.Lease, comptime writer: bool) !void {
        while (true) {
            if (!writer) while (true) {
                const blocked = for (keys) |key| {
                    if (self.tiles.lookup.get(key)) |slot| if (self.mutating[slot]) break true;
                } else false;
                if (!blocked) break;
                self.available.waitUncancelable(self.io, &self.mutex);
            };
            var victims: [192]records.Cache.Lease = undefined;
            const reservation = try self.tiles.reserveMany(keys, held, &victims, self.tiles.entries.len);
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
            if (self.tiles.failed) return error.FailedTransaction;
            var reads: [192]records.Get = undefined;
            var fills: [192]records.Cache.Fill = undefined;
            var sizes: [192]?usize = undefined;
            var loading: usize = 0;
            var waiting = false;
            for (held) |lease| {
                const entry = &self.tiles.entries[lease.index];
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
                break :blk self.tiles.backend.getBatch(reads[0..loading], sizes[0..loading]);
            };
            self.mutex.lockUncancelable(self.io);
            if (result) |_| {
                for (fills[0..loading], sizes[0..loading]) |fill, length| fill.load(length);
                self.tiles.metrics.reads.add(loading);
            } else |err| {
                for (fills[0..loading]) |fill| fill.cancel();
                self.tiles.failed = true;
                self.available.broadcast(self.io);
                return err;
            }
            self.available.broadcast(self.io);
        }
    }

    fn writeTilesLocked(self: *Store, held: []const records.Cache.Lease) !void {
        var writes: [192]records.Write = undefined;
        for (held, writes[0..held.len]) |lease, *write| {
            std.debug.assert(self.writing and self.tiles.entries[lease.index].dirty);
            write.* = .{ .key = lease.key(), .value = lease.read() };
        }
        self.mutex.unlock(self.io);
        const result = blk: {
            self.table_lock.lockUncancelable(self.io);
            defer self.table_lock.unlock(self.io);
            break :blk self.tiles.writeBack(writes[0..held.len]);
        };
        self.mutex.lockUncancelable(self.io);
        for (held) |lease| {
            if (result) |_| {
                lease.markWritten();
            } else |_| {}
            lease.release();
        }
        self.available.broadcast(self.io);
        result catch |err| {
            self.tiles.failed = true;
            self.tiles.backend.fail();
            return err;
        };
    }

    fn loadForEviction(self: *Store, keys: []const []const u8) !void {
        self.beginWrite();
        defer self.endWrite();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var held: [192]records.Cache.Lease = undefined;
        try self.loadTilesLocked(keys, held[0..keys.len], true);
        for (held[0..keys.len]) |lease| lease.release();
        self.available.broadcast(self.io);
    }

    fn beginWrite(self: *Store) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.writing) self.available.waitUncancelable(self.io, &self.mutex);
        self.writing = true;
    }

    fn endWrite(self: *Store) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.writing);
        self.writing = false;
        self.available.broadcast(self.io);
    }

    pub fn putBatch(self: *Store, writes: []const records.Write) !void {
        self.beginWrite();
        defer self.endWrite();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        errdefer self.fail();
        var begin: usize = 0;
        while (begin < writes.len) {
            const offered: usize = @min(192, writes.len - begin);
            var input: [192][]const u8 = undefined;
            for (writes[begin..][0..offered], input[0..offered]) |write, *key| key.* = write.key;
            var batch: Batch = .{};
            try batch.plan(input[0..offered], self.tiles.entries.len);
            const count = batch.count;
            var leases: [192]records.Cache.Lease = undefined;
            const held = leases[0..batch.unique];
            try self.loadTilesLocked(batch.keys[0..batch.unique], held, true);
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
                    if (self.tiles.entries[lease.index].pins != 1) break true;
                } else false;
                if (!borrowed) break;
                self.available.waitUncancelable(self.io, &self.mutex);
            }
            for (leases[0..batch.unique], 0..) |lease, group| {
                const old = lease.read();
                var parts: [tile_sections][]const u8 = undefined;
                var locations: [tile_sections]Location = undefined;
                var replaced: [tile_sections]bool = @splat(false);
                for (&parts, &locations, 0..) |*part, *location, section| {
                    location.* = try locate(old, section);
                    part.* = if (old) |bytes| bytes[location.begin..location.end] else &.{};
                }
                var member = batch.first[group];
                while (member != Batch.absent) {
                    std.debug.assert(member < count and batch.mapping[member] == group);
                    const write = writes[begin + member];
                    const target = batch.addresses[member];
                    member = batch.next[member];
                    const value = write.value orelse &.{};
                    if (value.len > section_bytes or (value.len != 0 and (value.len < 3 or value[0] > 2 or (value[0] == 0 and value.len != 3) or (value[0] == 1 and value.len != section_bytes)))) return error.InvalidArgument;
                    parts[target.part] = value;
                    replaced[target.part] = true;
                }
                var length: usize = header_bytes;
                var changed = false;
                var resized = false;
                for (parts, locations) |part, location| {
                    const previous = if (old) |bytes| bytes[location.begin..location.end] else &.{};
                    length += part.len;
                    changed = changed or !std.mem.eql(u8, previous, part);
                    resized = resized or part.len != previous.len;
                }
                if (!changed) continue;
                if (length == header_bytes) {
                    lease.remove();
                    continue;
                }
                if (resized) {
                    for (&parts, locations, replaced) |*part, location, replacement| {
                        if (replacement) continue;
                        const preserved = self.scratch[location.begin..location.end];
                        @memcpy(preserved, part.*);
                        part.* = preserved;
                    }
                }
                const bytes = lease.edit();
                var offset: usize = header_bytes;
                for (parts, replaced, 0..) |part, replacement, section| {
                    if (resized or replacement) @memcpy(bytes[offset..][0..part.len], part);
                    std.mem.writeInt(u16, bytes[section * 2 ..][0..2], @intCast(part.len), .little);
                    offset += part.len;
                }
                std.debug.assert(offset == length);
                lease.commit(length);
            }
            begin += count;
        }
    }

    pub fn flush(self: *Store) !void {
        self.beginWrite();
        defer self.endWrite();
        self.mutex.lockUncancelable(self.io);
        self.draining = true;
        while (self.readers != 0) self.available.waitUncancelable(self.io, &self.mutex);
        self.mutex.unlock(self.io);
        defer {
            self.mutex.lockUncancelable(self.io);
            self.draining = false;
            self.available.broadcast(self.io);
            self.mutex.unlock(self.io);
        }
        self.table_lock.lockUncancelable(self.io);
        defer self.table_lock.unlock(self.io);
        try self.tiles.flush();
    }

    pub fn fail(self: *Store) void {
        self.tiles.backend.fail();
    }
};

test "tile groups preserve maximal prefixes and stable member order" {
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
            try batch.plan(input[begin..], capacity);
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
                    const expected = try Store.address(input[begin + current]);
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
                const next = try Store.address(input[begin + batch.count]);
                for (batch.keys[0..batch.unique]) |key| try std.testing.expect(!std.mem.eql(u8, key, &next.key));
            }
            begin += batch.count;
        }
    }
}
