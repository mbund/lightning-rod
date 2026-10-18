const std = @import("std");

pub const PluginAllocator = struct {
    storage: std.heap.FixedBufferAllocator,
    sealed: bool = false,
    owner: ?usize = null,
    owner_start: usize = 0,
    plugin_bytes: []u64 = &.{},

    pub fn init(bytes: []u8) PluginAllocator {
        return .{ .storage = std.heap.FixedBufferAllocator.init(bytes) };
    }

    pub fn allocator(self: *PluginAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &Adapter.vtable };
    }

    pub fn seal(self: *PluginAllocator) void {
        std.debug.assert(!self.sealed);
        self.sealed = true;
    }

    pub fn used(self: *const PluginAllocator) usize {
        return self.storage.end_index;
    }

    pub fn owns(self: *const PluginAllocator, pointer: anytype) bool {
        const address = @intFromPtr(pointer);
        const begin = @intFromPtr(self.storage.buffer.ptr);
        return address >= begin and address - begin < self.storage.buffer.len;
    }

    pub fn ownsCurrentPluginAllocation(self: *const PluginAllocator, pointer: anytype) bool {
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

    pub fn currentPluginBytes(self: *const PluginAllocator) usize {
        std.debug.assert(self.owner != null);
        return self.storage.end_index - self.owner_start;
    }

    pub fn trackPlugins(self: *PluginAllocator, plugin_bytes: []u64) void {
        self.requireOpen();
        std.debug.assert(self.owner == null);
        std.debug.assert(self.plugin_bytes.len == 0);
        self.plugin_bytes = plugin_bytes;
        @memset(plugin_bytes, 0);
    }

    pub fn beginPlugin(self: *PluginAllocator, index: usize) void {
        self.requireOpen();
        std.debug.assert(self.owner == null);
        std.debug.assert(index < self.plugin_bytes.len);
        self.owner = index;
        self.owner_start = self.storage.end_index;
    }

    pub fn endPlugin(self: *PluginAllocator) void {
        const index = self.owner orelse unreachable;
        std.debug.assert(self.storage.end_index >= self.owner_start);
        self.plugin_bytes[index] = @intCast(self.storage.end_index - self.owner_start);
        self.owner = null;
        self.owner_start = 0;
    }

    fn requireOpen(self: *const PluginAllocator) void {
        if (self.sealed)
            @panic("plugin used its initialization allocator after initialization completed");
    }

    fn alloc(self: *PluginAllocator, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        self.requireOpen();
        return std.heap.FixedBufferAllocator.alloc(&self.storage, len, alignment, return_address);
    }

    fn resize(self: *PluginAllocator, bytes: []u8, alignment: std.mem.Alignment, len: usize, return_address: usize) bool {
        self.requireOpen();
        return std.heap.FixedBufferAllocator.resize(&self.storage, bytes, alignment, len, return_address);
    }

    fn remap(self: *PluginAllocator, bytes: []u8, alignment: std.mem.Alignment, len: usize, return_address: usize) ?[*]u8 {
        self.requireOpen();
        return std.heap.FixedBufferAllocator.remap(&self.storage, bytes, alignment, len, return_address);
    }

    fn free(self: *PluginAllocator, bytes: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        self.requireOpen();
        std.heap.FixedBufferAllocator.free(&self.storage, bytes, alignment, return_address);
    }

    const Adapter = struct {
        const vtable: std.mem.Allocator.VTable = .{
            .alloc = Adapter.allocate,
            .resize = @This().resize,
            .remap = @This().remap,
            .free = @This().free,
        };

        fn instance(raw: *anyopaque) *PluginAllocator {
            return @ptrCast(@alignCast(raw));
        }

        fn allocate(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
            return PluginAllocator.alloc(instance(raw), len, alignment, return_address);
        }

        fn resize(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, return_address: usize) bool {
            return PluginAllocator.resize(instance(raw), bytes, alignment, len, return_address);
        }

        fn remap(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, return_address: usize) ?[*]u8 {
            return PluginAllocator.remap(instance(raw), bytes, alignment, len, return_address);
        }

        fn free(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, return_address: usize) void {
            PluginAllocator.free(instance(raw), bytes, alignment, return_address);
        }
    };
};
