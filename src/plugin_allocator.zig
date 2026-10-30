const std = @import("std");

pub const PluginAllocator = struct {
    const Allocation = struct {
        next: ?*Allocation,
        bytes: []u8,
        payload: []u8,
        alignment: std.mem.Alignment,
        owner: ?usize,
    };

    const OwnerAllocator = struct { parent: *PluginAllocator, index: usize };
    owners: []OwnerAllocator = &.{},
    backing: std.mem.Allocator,
    limit: usize,
    allocated: usize = 0,
    first: ?*Allocation = null,
    sealed: bool = false,
    owner: ?usize = null,
    plugin_bytes: []u64 = &.{},

    pub fn init(backing: std.mem.Allocator, limit: usize) PluginAllocator {
        return .{ .backing = backing, .limit = limit };
    }

    pub fn deinit(self: *PluginAllocator) void {
        var next = self.first;
        while (next) |allocation| {
            next = allocation.next;
            self.backing.rawFree(allocation.bytes, allocation.alignment, @returnAddress());
        }
        self.* = undefined;
    }

    pub fn allocator(self: *PluginAllocator) std.mem.Allocator {
        if (self.owner) |index| return .{ .ptr = &self.owners[index], .vtable = &Bound.vtable };
        return .{ .ptr = self, .vtable = &Adapter.vtable };
    }

    pub fn seal(self: *PluginAllocator) void {
        std.debug.assert(!self.sealed and self.owner == null);
        self.sealed = true;
    }

    pub fn used(self: *const PluginAllocator) usize {
        return self.allocated;
    }

    pub fn owns(self: *const PluginAllocator, pointer: anytype) bool {
        return self.find(@intFromPtr(pointer), 1) != null;
    }

    pub fn ownsCurrentPluginAllocation(self: *const PluginAllocator, pointer: anytype) bool {
        const Pointer = @typeInfo(@TypeOf(pointer)).pointer;
        if (@sizeOf(Pointer.child) == 0) {
            const expected = std.mem.Alignment.of(Pointer.child).backward(std.math.maxInt(usize));
            return @intFromPtr(pointer) == expected;
        }
        std.debug.assert(self.owner != null);
        const allocation = self.find(@intFromPtr(pointer), @sizeOf(Pointer.child)) orelse return false;
        return allocation.owner == self.owner;
    }

    // A plugin may return an unrelated pointer. Do not read a header through it.
    fn find(self: *const PluginAllocator, address: usize, size: usize) ?*Allocation {
        var next = self.first;
        while (next) |allocation| : (next = allocation.next) {
            const begin = @intFromPtr(allocation.payload.ptr);
            if (address < begin) continue;
            const offset = address - begin;
            if (offset <= allocation.payload.len and size <= allocation.payload.len - offset) return allocation;
        }
        return null;
    }

    pub fn currentPluginBytes(self: *const PluginAllocator) usize {
        std.debug.assert(self.owner != null);
        return @intCast(self.plugin_bytes[self.owner.?]);
    }

    pub fn trackPlugins(self: *PluginAllocator, plugin_bytes: []u64) !void {
        self.requireOpen();
        std.debug.assert(self.owner == null and self.plugin_bytes.len == 0);
        self.plugin_bytes = plugin_bytes;
        @memset(plugin_bytes, 0);
        self.owners = try self.allocator().alloc(OwnerAllocator, plugin_bytes.len);
        for (self.owners, 0..) |*context, index| context.* = .{ .parent = self, .index = index };
    }

    pub fn beginPlugin(self: *PluginAllocator, index: usize) void {
        self.requireOpen();
        std.debug.assert(self.owner == null and index < self.plugin_bytes.len);
        self.owner = index;
    }

    pub fn endPlugin(self: *PluginAllocator) void {
        std.debug.assert(self.owner != null);
        self.owner = null;
    }

    fn requireOpen(self: *const PluginAllocator) void {
        if (self.sealed) @panic("plugin used its initialization allocator after initialization completed");
    }

    fn alloc(self: *PluginAllocator, length: usize, alignment: std.mem.Alignment, return_address: usize, owner: ?usize) ?[*]u8 {
        self.requireOpen();
        const prefix = alignment.forward(@sizeOf(Allocation));
        const total = std.math.add(usize, prefix, length) catch return null;
        if (total > self.limit - self.allocated) return null;
        const backing_alignment = alignment.max(.of(Allocation));
        const bytes = (self.backing.rawAlloc(total, backing_alignment, return_address) orelse return null)[0..total];
        const header_bytes: []align(@alignOf(Allocation)) u8 = @alignCast(bytes[0..@sizeOf(Allocation)]);
        const allocation = std.mem.bytesAsValue(Allocation, header_bytes);
        allocation.* = .{ .next = self.first, .bytes = bytes, .payload = bytes[prefix..], .alignment = backing_alignment, .owner = owner };
        self.first = allocation;
        self.allocated += total;
        if (owner) |index| self.plugin_bytes[index] += total;
        return allocation.payload.ptr;
    }

    fn resize(self: *PluginAllocator, bytes: []u8, _: std.mem.Alignment, length: usize, _: usize) bool {
        self.requireOpen();
        const allocation = self.find(@intFromPtr(bytes.ptr), bytes.len) orelse unreachable;
        std.debug.assert(allocation.payload.ptr == bytes.ptr and allocation.payload.len == bytes.len);
        const prefix = @intFromPtr(bytes.ptr) - @intFromPtr(allocation.bytes.ptr);
        if (length > allocation.bytes.len - prefix) return false;
        allocation.payload.len = length;
        return true;
    }

    fn free(self: *PluginAllocator, bytes: []u8, _: std.mem.Alignment, return_address: usize) void {
        self.requireOpen();
        const allocation = self.find(@intFromPtr(bytes.ptr), bytes.len) orelse unreachable;
        std.debug.assert(allocation.payload.ptr == bytes.ptr and allocation.payload.len == bytes.len);
        var linked = &self.first;
        while (linked.* != allocation) linked = &linked.*.?.next;
        linked.* = allocation.next;
        self.allocated -= allocation.bytes.len;
        if (allocation.owner) |index| self.plugin_bytes[index] -= allocation.bytes.len;
        self.backing.rawFree(allocation.bytes, allocation.alignment, return_address);
    }

    const Bound = struct {
        const vtable: std.mem.Allocator.VTable = .{ .alloc = @This().allocate, .resize = @This().resize, .remap = @This().remap, .free = @This().free };
        fn context(raw: *anyopaque) *OwnerAllocator {
            return @ptrCast(@alignCast(raw));
        }
        fn allocate(raw: *anyopaque, length: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
            const owner = context(raw);
            return owner.parent.alloc(length, alignment, return_address, owner.index);
        }
        fn resize(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, length: usize, return_address: usize) bool {
            return context(raw).parent.resize(bytes, alignment, length, return_address);
        }
        fn remap(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, length: usize, return_address: usize) ?[*]u8 {
            return if (@This().resize(raw, bytes, alignment, length, return_address)) bytes.ptr else null;
        }
        fn free(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, return_address: usize) void {
            context(raw).parent.free(bytes, alignment, return_address);
        }
    };

    const Adapter = struct {
        const vtable: std.mem.Allocator.VTable = .{ .alloc = Adapter.allocate, .resize = Adapter.resize, .remap = Adapter.remap, .free = Adapter.free };

        fn instance(raw: *anyopaque) *PluginAllocator {
            return @ptrCast(@alignCast(raw));
        }
        fn allocate(raw: *anyopaque, length: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
            return instance(raw).alloc(length, alignment, return_address, null);
        }
        fn resize(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, length: usize, return_address: usize) bool {
            return instance(raw).resize(bytes, alignment, length, return_address);
        }
        fn remap(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, length: usize, return_address: usize) ?[*]u8 {
            return if (instance(raw).resize(bytes, alignment, length, return_address)) bytes.ptr else null;
        }
        fn free(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, return_address: usize) void {
            instance(raw).free(bytes, alignment, return_address);
        }
    };
};
