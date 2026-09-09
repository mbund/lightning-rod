const std = @import("std");

pub const Allocator = struct {
    storage: std.heap.FixedBufferAllocator,
    sealed: bool = false,
    owner: ?usize = null,
    owner_start: usize = 0,
    plugin_bytes: []u64 = &.{},

    pub fn init(bytes: []u8) Allocator {
        return .{ .storage = std.heap.FixedBufferAllocator.init(bytes) };
    }

    pub fn allocator(self: *Allocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn seal(self: *Allocator) void {
        std.debug.assert(!self.sealed);
        self.sealed = true;
    }

    pub fn used(self: *const Allocator) usize {
        return self.storage.end_index;
    }

    pub fn owns(self: *const Allocator, pointer: anytype) bool {
        const address = @intFromPtr(pointer);
        const begin = @intFromPtr(self.storage.buffer.ptr);
        return address >= begin and address - begin < self.storage.buffer.len;
    }

    pub fn ownsCurrentPluginAllocation(self: *const Allocator, pointer: anytype) bool {
        const Pointer = @typeInfo(@TypeOf(pointer)).pointer;
        if (@sizeOf(Pointer.child) == 0) {
            const expected = std.mem.Alignment.of(Pointer.child).backward(std.math.maxInt(usize));
            return @intFromPtr(pointer) == expected;
        }
        const start = self.owner_start;
        const end = self.storage.end_index;
        std.debug.assert(self.owner != null);
        if (start == end) return false;
        const address = @intFromPtr(pointer);
        const begin = @intFromPtr(self.storage.buffer.ptr);
        if (address < begin) return false;
        const offset = address - begin;
        return offset >= start and offset < end and @sizeOf(Pointer.child) <= end - offset;
    }

    pub fn currentPluginBytes(self: *const Allocator) usize {
        std.debug.assert(self.owner != null);
        return self.storage.end_index - self.owner_start;
    }

    pub fn trackPlugins(self: *Allocator, plugin_bytes: []u64) void {
        self.requireOpen();
        std.debug.assert(self.owner == null);
        std.debug.assert(self.plugin_bytes.len == 0);
        self.plugin_bytes = plugin_bytes;
        @memset(plugin_bytes, 0);
    }

    pub fn beginPlugin(self: *Allocator, index: usize) void {
        self.requireOpen();
        std.debug.assert(self.owner == null);
        std.debug.assert(index < self.plugin_bytes.len);
        self.owner = index;
        self.owner_start = self.storage.end_index;
    }

    pub fn endPlugin(self: *Allocator) void {
        const index = self.owner orelse unreachable;
        std.debug.assert(self.storage.end_index >= self.owner_start);
        self.plugin_bytes[index] = @intCast(self.storage.end_index - self.owner_start);
        self.owner = null;
        self.owner_start = 0;
    }

    fn requireOpen(self: *const Allocator) void {
        if (self.sealed)
            @panic("plugin used its generation allocator after initialization completed");
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *Allocator = @ptrCast(@alignCast(context));
        self.requireOpen();
        return std.heap.FixedBufferAllocator.alloc(&self.storage, len, alignment, return_address);
    }

    fn resize(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, return_address: usize) bool {
        const self: *Allocator = @ptrCast(@alignCast(context));
        self.requireOpen();
        return std.heap.FixedBufferAllocator.resize(&self.storage, bytes, alignment, len, return_address);
    }

    fn remap(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, return_address: usize) ?[*]u8 {
        const self: *Allocator = @ptrCast(@alignCast(context));
        self.requireOpen();
        return std.heap.FixedBufferAllocator.remap(&self.storage, bytes, alignment, len, return_address);
    }

    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *Allocator = @ptrCast(@alignCast(context));
        self.requireOpen();
        std.heap.FixedBufferAllocator.free(&self.storage, bytes, alignment, return_address);
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

test "generation allocator attributes aligned reservations to their plugin" {
    var bytes: [256]u8 = undefined;
    var plugin_bytes = [_]u64{ 0, 0 };
    var generation = Allocator.init(&bytes);
    generation.trackPlugins(&plugin_bytes);
    generation.beginPlugin(1);
    _ = try generation.allocator().alignedAlloc(u8, .@"64", 65);
    generation.endPlugin();
    try std.testing.expectEqual(@as(u64, generation.used()), plugin_bytes[1]);
    try std.testing.expectEqual(@as(u64, 0), plugin_bytes[0]);
}

test "generation allocator distinguishes the current plugin allocation interval" {
    var bytes: [256]u8 = undefined;
    var plugin_bytes = [_]u64{ 0, 0 };
    var generation = Allocator.init(&bytes);
    generation.trackPlugins(&plugin_bytes);
    generation.beginPlugin(0);
    const first = try generation.allocator().create(u8);
    generation.endPlugin();
    generation.beginPlugin(1);
    const second = try generation.allocator().create(u8);
    try std.testing.expect(generation.ownsCurrentPluginAllocation(second));
    const incomplete: *[2]u8 = @ptrCast(second);
    try std.testing.expect(!generation.ownsCurrentPluginAllocation(incomplete));
    try std.testing.expect(!generation.ownsCurrentPluginAllocation(first));
    generation.endPlugin();
}
