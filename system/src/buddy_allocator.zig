//! A general allocator confined to one region reserved up front: it never asks for more, so what
//! does not fit fails with `OutOfMemory`. Blocks are powers of two; an allocation takes the
//! smallest that fits, splitting larger free blocks in halves, and a freed block merges with its
//! free half, its buddy, back up to the largest block it can, so the region does not fragment
//! over time. Freed memory is filled with `poison`, and in safe builds an allocation checks its
//! block is still poison, catching writes after free. Thread safe.
//!
//! The only bookkeeping is one bit per possible block saying whether it is free: `free` is given
//! the length and alignment `alloc` was, so the block size is computed again, not stored.
const std = @import("std");
const assert = std.debug.assert;
const Alignment = std.mem.Alignment;

pub const BuddyAllocator = struct {
    pub const min_block = 64;
    pub const poison: u8 = 0xaa;
    const Word = usize;
    const word_bits = @bitSizeOf(Word);
    const max_orders = @bitSizeOf(usize);

    region: []u8,
    /// One bitset per order, order 0 holding the smallest blocks, each starting on a word.
    bits: []Word,
    order_words: [max_orders]usize = @splat(0),
    orders: u6,
    locked: std.atomic.Value(bool) = .init(false),
    /// Bytes of the blocks handed out, and the most there have been at once.
    used: usize = 0,
    peak: usize = 0,

    /// The words of bookkeeping a region of this many bytes needs.
    pub fn bitWords(region_len: usize) usize {
        var total: usize = 0;
        var blocks = region_len / min_block;
        while (blocks != 0) : (blocks /= 2) total += std.math.divCeil(usize, blocks, word_bits) catch unreachable;
        return total;
    }

    /// Takes the region, a power of two of at least `min_block` bytes, and its bookkeeping, and
    /// poisons the region, which also makes the system back every page of it now.
    pub fn init(region: []u8, bits: []Word) BuddyAllocator {
        assert(region.len >= min_block and std.math.isPowerOfTwo(region.len));
        assert(bits.len == bitWords(region.len));
        const orders: u6 = @intCast(std.math.log2_int(usize, region.len / min_block) + 1);
        var self: BuddyAllocator = .{ .region = region, .bits = bits, .orders = orders };
        var at: usize = 0;
        for (0..orders) |order| {
            self.order_words[order] = at;
            at += std.math.divCeil(usize, blockCount(region.len, @intCast(order)), word_bits) catch unreachable;
        }
        @memset(bits, 0);
        // At first the whole region is one free block.
        self.setFree(orders - 1, 0, true);
        @memset(region, poison);
        return self;
    }

    pub fn allocator(self: *BuddyAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn blockCount(region_len: usize, order: u6) usize {
        return (region_len / min_block) >> order;
    }

    fn blockBytes(order: u6) usize {
        return @as(usize, min_block) << order;
    }

    /// The order of the block an allocation of this length and alignment takes.
    fn orderOf(self: *const BuddyAllocator, len: usize, alignment: Alignment) ?u6 {
        const bytes = @max(len, alignment.toByteUnits(), min_block);
        if (bytes > self.region.len) return null;
        const rounded = std.math.ceilPowerOfTwo(usize, bytes) catch return null;
        return @intCast(std.math.log2_int(usize, rounded / min_block));
    }

    fn isFree(self: *const BuddyAllocator, order: u6, index: usize) bool {
        const word = self.bits[self.order_words[order] + index / word_bits];
        return word >> @intCast(index % word_bits) & 1 != 0;
    }

    fn setFree(self: *BuddyAllocator, order: u6, index: usize, free_: bool) void {
        const word = &self.bits[self.order_words[order] + index / word_bits];
        const mask = @as(Word, 1) << @intCast(index % word_bits);
        if (free_) word.* |= mask else word.* &= ~mask;
    }

    fn firstFree(self: *const BuddyAllocator, order: u6) ?usize {
        const words = std.math.divCeil(usize, blockCount(self.region.len, order), word_bits) catch unreachable;
        for (self.bits[self.order_words[order]..][0..words], 0..) |word, offset| {
            if (word != 0) return offset * word_bits + @ctz(word);
        }
        return null;
    }

    fn lock(self: *BuddyAllocator) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlock(self: *BuddyAllocator) void {
        self.locked.store(false, .release);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
        const self: *BuddyAllocator = @ptrCast(@alignCast(context));
        const order = self.orderOf(len, alignment) orelse return null;
        // A block is at least its alignment and lies a multiple of its size into the region, so
        // it is aligned as far as the region is.
        if (!alignment.check(@intFromPtr(self.region.ptr))) return null;
        const offset = taken: {
            self.lock();
            defer self.unlock();
            var from = order;
            const found = while (from < self.orders) : (from += 1) {
                if (self.firstFree(from)) |index| break index;
            } else return null;
            self.setFree(from, found, false);
            // Split down to the size asked for, leaving each right half free.
            var index = found;
            while (from > order) {
                from -= 1;
                index *= 2;
                self.setFree(from, index + 1, true);
            }
            self.used += blockBytes(order);
            self.peak = @max(self.peak, self.used);
            break :taken index * blockBytes(order);
        };
        const block = self.region[offset..][0..blockBytes(order)];
        if (std.debug.runtime_safety) {
            if (std.mem.indexOfNone(u8, block, &.{poison})) |at|
                std.debug.panic("buddy allocator: block at offset {d} was written after it was freed (byte {d})", .{ offset, at });
        }
        return block.ptr;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, _: usize) void {
        const self: *BuddyAllocator = @ptrCast(@alignCast(context));
        const order = self.orderOf(memory.len, alignment).?;
        const offset = @intFromPtr(memory.ptr) - @intFromPtr(self.region.ptr);
        assert(offset < self.region.len and offset % blockBytes(order) == 0);
        // The block is still the caller's until it is marked free, so it is poisoned first.
        @memset(self.region[offset..][0..blockBytes(order)], poison);
        self.lock();
        defer self.unlock();
        self.used -= blockBytes(order);
        var index = offset / blockBytes(order);
        var at = order;
        // Merge with the buddy while it is free too.
        while (at + 1 < self.orders and self.isFree(at, index ^ 1)) : (at += 1) {
            self.setFree(at, index ^ 1, false);
            index /= 2;
        }
        assert(!self.isFree(at, index));
        self.setFree(at, index, true);
    }

    /// In place while the new length takes a block of the same size.
    fn resize(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) bool {
        const self: *BuddyAllocator = @ptrCast(@alignCast(context));
        return self.orderOf(new_len, alignment) == self.orderOf(memory.len, alignment);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        return if (resize(context, memory, alignment, new_len, return_address)) memory.ptr else null;
    }

    /// Whether everything handed out came back and merged into the one block it began as.
    pub fn whole(self: *BuddyAllocator) bool {
        self.lock();
        defer self.unlock();
        return self.used == 0 and self.isFree(self.orders - 1, 0);
    }
};

const testing = std.testing;

fn testInstance(comptime region_len: usize) !struct { region: []align(std.heap.page_size_min) u8, bits: []usize, buddy: *BuddyAllocator } {
    const region = try testing.allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), region_len);
    const bits = try testing.allocator.alloc(usize, BuddyAllocator.bitWords(region_len));
    const buddy = try testing.allocator.create(BuddyAllocator);
    buddy.* = .init(region, bits);
    return .{ .region = region, .bits = bits, .buddy = buddy };
}

fn freeInstance(instance: anytype) void {
    testing.allocator.free(instance.region);
    testing.allocator.free(instance.bits);
    testing.allocator.destroy(instance.buddy);
}

test "passes the standard library's allocator checks" {
    const instance = try testInstance(1 << 20);
    defer freeInstance(instance);
    const buddy = instance.buddy;
    try std.heap.testAllocator(buddy.allocator());
    try std.heap.testAllocatorAligned(buddy.allocator());
    try std.heap.testAllocatorLargeAlignment(buddy.allocator());
    try std.heap.testAllocatorAlignedShrink(buddy.allocator());
    try testing.expect(buddy.whole());
}

test "splits for small blocks and merges back into the whole region" {
    const instance = try testInstance(4096);
    defer freeInstance(instance);
    const allocator = instance.buddy.allocator();
    const small = try allocator.alloc(u8, 1);
    const medium = try allocator.alloc(u8, 200);
    const large = try allocator.alloc(u8, 2048);
    try testing.expectEqual(@as(usize, 64 + 256 + 2048), instance.buddy.used);
    // Nothing of 2048 bytes is left whole, and nothing larger than the region fits at all.
    try testing.expectError(error.OutOfMemory, allocator.alloc(u8, 2048));
    try testing.expectError(error.OutOfMemory, allocator.alloc(u8, 8192));
    allocator.free(medium);
    allocator.free(small);
    try testing.expect(!instance.buddy.whole());
    allocator.free(large);
    try testing.expect(instance.buddy.whole());
    try testing.expectEqual(@as(usize, 64 + 256 + 2048), instance.buddy.peak);
}

test "resizes in place only within the block" {
    const instance = try testInstance(4096);
    defer freeInstance(instance);
    const allocator = instance.buddy.allocator();
    var bytes = try allocator.alloc(u8, 100);
    try testing.expect(allocator.resize(bytes, 128));
    bytes = bytes.ptr[0..128];
    try testing.expect(!allocator.resize(bytes, 129));
    try testing.expect(allocator.resize(bytes, 65));
    bytes = bytes.ptr[0..65];
    allocator.free(bytes);
    try testing.expect(instance.buddy.whole());
}

test "freed memory is poisoned" {
    const instance = try testInstance(4096);
    defer freeInstance(instance);
    const allocator = instance.buddy.allocator();
    const bytes = try allocator.alloc(u8, 300);
    @memset(bytes, 7);
    const offset = @intFromPtr(bytes.ptr) - @intFromPtr(instance.region.ptr);
    allocator.free(bytes);
    for (instance.region[offset..][0..512]) |byte| try testing.expectEqual(BuddyAllocator.poison, byte);
}

test "random allocations never overlap and always merge back" {
    const instance = try testInstance(1 << 16);
    defer freeInstance(instance);
    const allocator = instance.buddy.allocator();
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    const random = prng.random();
    const Live = struct { bytes: []u8, mark: u8 };
    var live: [64]?Live = @splat(null);
    for (0..20_000) |step| {
        const slot = &live[random.uintLessThan(usize, live.len)];
        if (slot.*) |held| {
            for (held.bytes) |byte| try testing.expectEqual(held.mark, byte);
            allocator.free(held.bytes);
            slot.* = null;
        } else {
            const len = random.intRangeAtMost(usize, 1, 3000);
            const bytes = allocator.alloc(u8, len) catch continue;
            const mark: u8 = @truncate(step);
            @memset(bytes, mark);
            slot.* = .{ .bytes = bytes, .mark = mark };
        }
    }
    for (&live) |*slot| if (slot.*) |held| {
        for (held.bytes) |byte| try testing.expectEqual(held.mark, byte);
        allocator.free(held.bytes);
    };
    try testing.expect(instance.buddy.whole());
}

test "threads share one region" {
    const instance = try testInstance(1 << 20);
    defer freeInstance(instance);
    const allocator = instance.buddy.allocator();
    const Worker = struct {
        fn run(shared: std.mem.Allocator, seed: u64) void {
            var prng = std.Random.DefaultPrng.init(seed);
            const random = prng.random();
            for (0..2000) |_| {
                const len = random.intRangeAtMost(usize, 1, 2000);
                const bytes = shared.alloc(u8, len) catch continue;
                @memset(bytes, 1);
                shared.free(bytes);
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| thread.* = try std.Thread.spawn(.{}, Worker.run, .{ allocator, testing.random_seed +% index });
    for (threads) |thread| thread.join();
    try testing.expect(instance.buddy.whole());
}
