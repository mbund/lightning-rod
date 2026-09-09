const std = @import("std");
const plugin_profiler = @import("plugin_profiler.zig");
const preallocated = @import("preallocated");

pub const Arena = struct {
    bytes: []u8,
    fixed: std.heap.FixedBufferAllocator,
    accounted_end: usize = 0,

    pub fn create(allocator: std.mem.Allocator, capacity: usize) !*Arena {
        if (capacity == 0) return error.InvalidCapacity;
        const bytes = try preallocated.alloc(u8, allocator, capacity);
        return createIn(allocator, bytes);
    }

    pub fn createIn(allocator: std.mem.Allocator, bytes: []u8) !*Arena {
        if (bytes.len == 0) return error.InvalidCapacity;
        const self = try preallocated.create(Arena, allocator);
        self.* = .{ .bytes = bytes, .fixed = std.heap.FixedBufferAllocator.init(bytes) };
        return self;
    }

    pub fn begin(self: *Arena) std.mem.Allocator {
        self.fixed.reset();
        self.accounted_end = 0;
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn finish(self: *Arena) void {
        self.fixed.reset();
        self.accounted_end = 0;
    }

    fn account(self: *Arena) void {
        if (self.fixed.end_index <= self.accounted_end) return;
        plugin_profiler.recordTickMemory(self.fixed.end_index - self.accounted_end);
        self.accounted_end = self.fixed.end_index;
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *Arena = @ptrCast(@alignCast(context));
        const result = std.heap.FixedBufferAllocator.alloc(&self.fixed, len, alignment, return_address);
        if (result != null) self.account();
        return result;
    }

    fn resize(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, return_address: usize) bool {
        const self: *Arena = @ptrCast(@alignCast(context));
        const result = std.heap.FixedBufferAllocator.resize(&self.fixed, bytes, alignment, len, return_address);
        if (result) self.account();
        return result;
    }

    fn remap(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, return_address: usize) ?[*]u8 {
        const self: *Arena = @ptrCast(@alignCast(context));
        const result = std.heap.FixedBufferAllocator.remap(&self.fixed, bytes, alignment, len, return_address);
        if (result != null) self.account();
        return result;
    }

    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *Arena = @ptrCast(@alignCast(context));
        std.heap.FixedBufferAllocator.free(&self.fixed, bytes, alignment, return_address);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

test "temporary arena is bounded, resettable, and records reservations" {
    var bytes: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&bytes);
    var profiler: plugin_profiler.Profiler = .{};
    var profile_bytes: [32 * 1024]u8 = undefined;
    var profile_fixed = std.heap.FixedBufferAllocator.init(&profile_bytes);
    try profiler.allocate(profile_fixed.allocator(), 1, 0);
    profiler.setCounter(.{ .context = &test_counter, .read_fn = readTestCounter });
    try profiler.setEnabled(true);
    profiler.beginTick();
    const started = plugin_profiler.beginPlugin(0, 0, 0);
    const arena = try Arena.create(fixed.allocator(), 128);
    _ = try arena.begin().alloc(u8, 32);
    arena.finish();
    _ = try arena.begin().alloc(u8, 64);
    plugin_profiler.endPlugin(0, started);
    profiler.finishTick();
    try std.testing.expectEqual(@as(usize, 128), arena.bytes.len);
    try std.testing.expectEqual(@as(u64, 96), profiler.plugins[0].tick_memory_last_bytes);
}

fn readTestCounter(context: *const anyopaque) u64 {
    const value: *std.atomic.Value(u64) = @ptrCast(@alignCast(@constCast(context)));
    return value.fetchAdd(1, .monotonic);
}

var test_counter: std.atomic.Value(u64) = .init(1);
