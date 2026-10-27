const std = @import("std");
const assert = std.debug.assert;
const absent = std.math.maxInt(usize);

/// Single-owner grouping index. Entries and borrowed keys expire at clear.
pub fn BatchIndex(comptime K: type, comptime V: type, comptime Context: type) type {
    return struct {
        const Self = @This();
        const Slot = struct { hash: u64, bucket: usize };
        pub const Result = struct { found_existing: bool, key_ptr: *K, value_ptr: *V };

        keys: []K,
        data: []V,
        slots: []Slot,
        buckets: []usize,
        length: usize = 0,

        pub fn init(allocator: std.mem.Allocator, maximum: usize) !Self {
            assert(maximum > 0);
            const bucket_count = try std.math.ceilPowerOfTwo(usize, try std.math.mul(usize, maximum, 2));
            const keys = try allocator.alloc(K, maximum);
            errdefer allocator.free(keys);
            const data = try allocator.alloc(V, maximum);
            errdefer allocator.free(data);
            const slots = try allocator.alloc(Slot, maximum);
            errdefer allocator.free(slots);
            const buckets = try allocator.alloc(usize, bucket_count);
            @memset(buckets, absent);
            return .{ .keys = keys, .data = data, .slots = slots, .buckets = buckets };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.buckets);
            allocator.free(self.slots);
            allocator.free(self.data);
            allocator.free(self.keys);
            self.* = undefined;
        }

        pub fn count(self: *const Self) usize {
            return self.length;
        }

        pub fn values(self: *Self) []V {
            return self.data[0..self.length];
        }

        pub fn clear(self: *Self) void {
            // Recorded positions avoid hashing keys whose backing storage is about to be reused.
            for (self.slots[0..self.length], 0..) |slot, index| {
                assert(self.buckets[slot.bucket] == index);
                self.buckets[slot.bucket] = absent;
            }
            self.length = 0;
        }

        pub fn get(self: *const Self, key: K) ?V {
            const context: Context = .{};
            const hash = context.hash(key);
            var bucket: usize = @intCast(hash & (self.buckets.len - 1));
            var examined: usize = 0;
            while (self.buckets[bucket] != absent) : (bucket = (bucket + 1) & (self.buckets.len - 1)) {
                assert(examined < self.length);
                examined += 1;
                const index = self.buckets[bucket];
                assert(index < self.length);
                if (self.slots[index].hash == hash and context.eql(self.keys[index], key)) return self.data[index];
            }
            return null;
        }

        pub fn getOrPut(self: *Self, key: K) Result {
            const context: Context = .{};
            const hash = context.hash(key);
            var bucket: usize = @intCast(hash & (self.buckets.len - 1));
            var examined: usize = 0;
            while (self.buckets[bucket] != absent) : (bucket = (bucket + 1) & (self.buckets.len - 1)) {
                assert(examined < self.length);
                examined += 1;
                const index = self.buckets[bucket];
                assert(index < self.length);
                if (self.slots[index].hash == hash and context.eql(self.keys[index], key))
                    return .{ .found_existing = true, .key_ptr = &self.keys[index], .value_ptr = &self.data[index] };
            }
            assert(self.length < self.keys.len and self.buckets.len / 2 >= self.keys.len);
            const index = self.length;
            self.length += 1;
            self.keys[index] = key;
            self.slots[index] = .{ .hash = hash, .bucket = bucket };
            self.buckets[bucket] = index;
            assert(self.count() <= self.keys.len and self.buckets[bucket] == index);
            return .{ .found_existing = false, .key_ptr = &self.keys[index], .value_ptr = &self.data[index] };
        }
    };
}

test "batch index preserves colliding keys and resets only occupied buckets without allocation" {
    const Context = struct {
        pub fn hash(_: @This(), _: usize) u64 {
            return 127;
        }
        pub fn eql(_: @This(), a: usize, b: usize) bool {
            return a == b;
        }
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var index = try BatchIndex(usize, usize, Context).init(allocator, 64);
    defer index.deinit(allocator);
    failing.fail_index = failing.alloc_index;
    for (0..8) |round| {
        try std.testing.expectEqual(@as(usize, 0), index.count());
        for (0..64) |key| {
            try std.testing.expectEqual(null, index.get(key));
            const result = index.getOrPut(key);
            try std.testing.expect(!result.found_existing);
            result.value_ptr.* = round * 64 + key;
        }
        for (0..64) |key| {
            try std.testing.expectEqual(round * 64 + key, index.get(key).?);
            const result = index.getOrPut(key);
            try std.testing.expect(result.found_existing);
            try std.testing.expectEqual(round * 64 + key, result.value_ptr.*);
        }
        try std.testing.expectEqual(@as(usize, 64), index.values().len);
        index.clear();
        index.clear();
        for (index.buckets) |bucket| try std.testing.expectEqual(absent, bucket);
    }
}

test "batch index initialization releases partial allocations" {
    const Fixture = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var index = try BatchIndex(usize, usize, std.hash_map.AutoContext(usize)).init(allocator, 7);
            defer index.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Fixture.run, .{});
}

test "batch index borrows key payloads and never hashes them during clear" {
    const Context = struct {
        var hashes: usize = 0;
        pub fn hash(_: @This(), key: []const u8) u64 {
            hashes += 1;
            return std.hash.Wyhash.hash(0, key);
        }
        pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    };
    var index = try BatchIndex([]const u8, usize, Context).init(std.testing.allocator, 8);
    defer index.deinit(std.testing.allocator);
    var bytes = [_]u8{ 1, 2, 3 };
    const entry = index.getOrPut(&bytes);
    entry.value_ptr.* = 9;
    try std.testing.expect(entry.key_ptr.*.ptr == &bytes);
    const hashes = Context.hashes;
    @memset(&bytes, 0);
    index.clear();
    try std.testing.expectEqual(hashes, Context.hashes);
    try std.testing.expectEqual(null, index.get(&bytes));
}
