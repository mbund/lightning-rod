//! Keys of a bounded length in byte order, for indexes walked by prefix: by time, by block, by
//! group. Pages of sorted keys under a sorted directory, so finding, adding and taking away
//! move at most a page and a directory. Room is fixed when made.

const std = @import("std");

const assert = std.debug.assert;

const page_keys = 64;
/// Neighbouring pages that together hold fewer than this become one, so every two neighbours
/// hold at least as many and a page holds a quarter of its room on average.
const merge_below = page_keys / 2;

fn order(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

pub fn SortedKeys(comptime max_key: usize) type {
    assert(max_key > 0 and max_key <= 255);
    return struct {
        const Self = @This();

        pub const Key = struct {
            bytes: [max_key]u8 = undefined,
            len: u8 = 0,

            pub fn of(bytes: []const u8) Key {
                assert(bytes.len <= max_key);
                var key: Key = .{ .len = @intCast(bytes.len) };
                @memcpy(key.bytes[0..bytes.len], bytes);
                return key;
            }

            pub fn slice(self: *const Key) []const u8 {
                return self.bytes[0..self.len];
            }
        };

        const Page = struct {
            keys: [page_keys]Key = undefined,
            len: u8 = 0,

            fn first(self: *const Page) []const u8 {
                return self.keys[0].slice();
            }
        };

        pages: []Page,
        free: []u32,
        free_count: usize,
        /// Pages in key order.
        directory: []u32,
        directory_len: usize = 0,
        count: usize = 0,
        capacity: usize,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            assert(capacity > 0);
            // Two neighbours hold `merge_below` or more, and a split's spare needs one more.
            const pages = capacity * 2 / merge_below + 4;
            const self: Self = .{
                .pages = try allocator.alloc(Page, pages),
                .free = try allocator.alloc(u32, pages),
                .free_count = pages,
                .directory = try allocator.alloc(u32, pages),
                .capacity = capacity,
            };
            for (self.free, 0..) |*page, at| page.* = @intCast(pages - 1 - at);
            return self;
        }

        /// The page a key belongs in: the last whose first key is not after it.
        fn pageFor(self: *const Self, key: []const u8) usize {
            var low: usize = 0;
            var high: usize = self.directory_len;
            while (low < high) {
                const middle = (low + high) / 2;
                if (order(self.pages[self.directory[middle]].first(), key) != .gt) low = middle + 1 else high = middle;
            }
            return if (low == 0) 0 else low - 1;
        }

        const Slot = struct { at: usize, found: bool };

        /// Where a key is or would go within a page.
        fn slotFor(page: *const Page, key: []const u8) Slot {
            var low: usize = 0;
            var high: usize = page.len;
            while (low < high) {
                const middle = (low + high) / 2;
                switch (order(page.keys[middle].slice(), key)) {
                    .lt => low = middle + 1,
                    .gt => high = middle,
                    .eq => return .{ .at = middle, .found = true },
                }
            }
            return .{ .at = low, .found = false };
        }

        pub fn contains(self: *const Self, key: []const u8) bool {
            if (self.directory_len == 0) return false;
            return slotFor(&self.pages[self.directory[self.pageFor(key)]], key).found;
        }

        fn takePage(self: *Self) !u32 {
            if (self.free_count == 0) return error.SortedKeysFull;
            self.free_count -= 1;
            const page = self.free[self.free_count];
            self.pages[page].len = 0;
            return page;
        }

        /// Adds a key; one already there stays.
        pub fn insert(self: *Self, key: []const u8) !void {
            assert(key.len <= max_key);
            if (self.directory_len == 0) {
                const page = try self.takePage();
                self.pages[page].keys[0] = .of(key);
                self.pages[page].len = 1;
                self.directory[0] = page;
                self.directory_len = 1;
                self.count = 1;
                return;
            }
            const at = self.pageFor(key);
            const page = &self.pages[self.directory[at]];
            const slot = slotFor(page, key);
            if (slot.found) return;
            if (self.count == self.capacity) return error.SortedKeysFull;
            if (page.len == page_keys) {
                // Split: the upper half moves to a new page after this one.
                const fresh = try self.takePage();
                const half = page_keys / 2;
                @memcpy(self.pages[fresh].keys[0..half], page.keys[half..page_keys]);
                self.pages[fresh].len = half;
                page.len = half;
                std.mem.copyBackwards(u32, self.directory[at + 2 .. self.directory_len + 1], self.directory[at + 1 .. self.directory_len]);
                self.directory[at + 1] = fresh;
                self.directory_len += 1;
                return self.insert(key);
            }
            std.mem.copyBackwards(Key, page.keys[slot.at + 1 .. page.len + 1], page.keys[slot.at..page.len]);
            page.keys[slot.at] = .of(key);
            page.len += 1;
            self.count += 1;
        }

        /// Takes a key away, if it was there.
        pub fn remove(self: *Self, key: []const u8) void {
            if (self.directory_len == 0) return;
            const at = self.pageFor(key);
            const page = &self.pages[self.directory[at]];
            const slot = slotFor(page, key);
            if (!slot.found) return;
            std.mem.copyForwards(Key, page.keys[slot.at .. page.len - 1], page.keys[slot.at + 1 .. page.len]);
            page.len -= 1;
            self.count -= 1;
            if (page.len == 0) return self.drop(at);
            if (at + 1 < self.directory_len) _ = self.mergeNext(at);
            if (at > 0) _ = self.mergeNext(at - 1);
        }

        /// The page after `at` joins it, if together they hold too few.
        fn mergeNext(self: *Self, at: usize) bool {
            const page = &self.pages[self.directory[at]];
            const next = &self.pages[self.directory[at + 1]];
            if (page.len + next.len >= merge_below) return false;
            @memcpy(page.keys[page.len..][0..next.len], next.keys[0..next.len]);
            page.len += next.len;
            next.len = 0;
            self.drop(at + 1);
            return true;
        }

        fn drop(self: *Self, at: usize) void {
            self.free[self.free_count] = self.directory[at];
            self.free_count += 1;
            std.mem.copyForwards(u32, self.directory[at .. self.directory_len - 1], self.directory[at + 1 .. self.directory_len]);
            self.directory_len -= 1;
        }

        /// Up to `output.len` keys after `key`, in order: copies, so the set may change before
        /// the next call.
        pub fn after(self: *const Self, key: []const u8, output: []Key) []Key {
            if (self.directory_len == 0) return output[0..0];
            var at = self.pageFor(key);
            const slot = slotFor(&self.pages[self.directory[at]], key);
            var position = if (slot.found) slot.at + 1 else slot.at;
            var count: usize = 0;
            while (count < output.len and at < self.directory_len) {
                const page = &self.pages[self.directory[at]];
                while (position < page.len and count < output.len) : (position += 1) {
                    output[count] = page.keys[position];
                    count += 1;
                }
                at += 1;
                position = 0;
            }
            return output[0..count];
        }

        pub fn clear(self: *Self) void {
            while (self.directory_len > 0) self.drop(self.directory_len - 1);
            self.count = 0;
        }
    };
}

test "keys keep their order through splits, merges and removals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Keys = SortedKeys(2);
    var keys = try Keys.init(arena.allocator(), 4096);
    var random = std.Random.DefaultPrng.init(7);
    var present: [4096]bool = @splat(false);
    for (0..40000) |step| {
        // Filling, then thinning, then both: pages split, empty and merge.
        const value = random.random().uintLessThan(u16, 4096);
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, value, .big);
        const adding = if (step < 10000) true else if (step < 20000) random.random().uintLessThan(u8, 8) == 0 else random.random().boolean();
        if (adding) {
            try keys.insert(&bytes);
            present[value] = true;
        } else {
            keys.remove(&bytes);
            present[value] = false;
        }
    }
    var expected: usize = 0;
    for (present) |is| expected += @intFromBool(is);
    try std.testing.expectEqual(expected, keys.count);
    // Walked in order from the start, a batch at a time, they are exactly those present.
    var last: [2]u8 = .{ 0, 0 };
    var last_len: usize = 0;
    var seen: usize = 0;
    var previous: ?u16 = null;
    while (true) {
        var batch: [17]Keys.Key = undefined;
        const found = keys.after(last[0..last_len], &batch);
        if (found.len == 0) break;
        for (found) |key| {
            const value = std.mem.readInt(u16, key.bytes[0..2], .big);
            try std.testing.expect(present[value]);
            if (previous) |before| try std.testing.expect(before < value);
            previous = value;
            seen += 1;
        }
        @memcpy(&last, found[found.len - 1].bytes[0..2]);
        last_len = 2;
    }
    try std.testing.expectEqual(expected, seen);
    var probe: [2]u8 = undefined;
    std.mem.writeInt(u16, &probe, previous.?, .big);
    try std.testing.expect(keys.contains(&probe));
    // Every key at once fits the room it was made with, and no more.
    keys.clear();
    for (0..4096) |value| {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, @intCast(value), .big);
        try keys.insert(&bytes);
    }
    try std.testing.expectError(error.SortedKeysFull, keys.insert(&.{0xff}));
}
