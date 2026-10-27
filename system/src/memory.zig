const std = @import("std");

pub const Memory = struct {
    const maximum_owners = 128;
    const Owner = struct {
        memory: *Memory,
        name: []const u8,
        bytes: usize = 0,
    };
    const Block = struct {
        next: ?*Block,
        bytes: []u8,
        alignment: std.mem.Alignment,
        fixed: std.heap.FixedBufferAllocator,
    };

    backing: std.mem.Allocator,
    io: std.Io,
    blocks: ?*Block = null,
    reserved_bytes: usize = 0,
    assigned_bytes: usize = 0,
    owners: [maximum_owners]Owner = undefined,
    count: usize = 0,
    sealed: bool = false,
    mutex: std.Io.Mutex = .init,

    pub fn init(backing: std.mem.Allocator, io: std.Io) Memory {
        return .{ .backing = backing, .io = io };
    }

    pub fn deinit(self: *Memory) void {
        var next = self.blocks;
        while (next) |block| {
            next = block.next;
            self.backing.rawFree(block.bytes, block.alignment, @returnAddress());
        }
        self.* = undefined;
    }

    pub fn allocator(self: *Memory, comptime name: []const u8) std.mem.Allocator {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.sealed) @panic("memory owner registered after initialization");
        comptime std.debug.assert(name.len != 0);
        for (self.owners[0..self.count]) |*owner| {
            if (std.mem.eql(u8, owner.name, name)) return .{ .ptr = owner, .vtable = &Adapter.vtable };
        }
        std.debug.assert(self.count < self.owners.len);
        const owner = &self.owners[self.count];
        owner.* = .{ .memory = self, .name = name };
        self.count += 1;
        return .{ .ptr = owner, .vtable = &Adapter.vtable };
    }

    pub fn seal(self: *Memory) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(!self.sealed);
        self.sealed = true;
        for (self.owners[0..self.count]) |owner|
            std.log.info("event=memory_reserved owner={s} bytes={d}", .{ owner.name, owner.bytes });
        std.log.info("event=memory_sealed scope=managed reserved_bytes={d} assigned_bytes={d} overhead_bytes={d}", .{ self.reserved_bytes, self.assigned_bytes, self.reserved_bytes - self.assigned_bytes });
    }

    const Adapter = struct {
        const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

        fn owner(raw: *anyopaque) *Owner {
            return @ptrCast(@alignCast(raw));
        }

        fn alloc(raw: *anyopaque, length: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
            const context = owner(raw);
            const memory = context.memory;
            memory.mutex.lockUncancelable(memory.io);
            defer memory.mutex.unlock(memory.io);
            if (memory.sealed) @panic("backing allocation after initialization");
            if (memory.blocks) |block| {
                const before = block.fixed.end_index;
                if (block.fixed.allocator().rawAlloc(length, alignment, return_address)) |result| {
                    const assigned = block.fixed.end_index - before;
                    context.bytes += assigned;
                    memory.assigned_bytes += assigned;
                    return result;
                }
            }
            const backing_alignment = alignment.max(.of(Block));
            const prefix = alignment.forward(@sizeOf(Block));
            const required = std.math.add(usize, prefix, length) catch return null;
            const page_size = std.heap.pageSize();
            const padded = std.math.add(usize, required, page_size - 1) catch return null;
            const size = std.mem.alignBackward(usize, padded, page_size);
            const bytes = (memory.backing.rawAlloc(size, backing_alignment, return_address) orelse return null)[0..size];
            const block: *Block = @ptrCast(@alignCast(bytes.ptr));
            block.* = .{ .next = memory.blocks, .bytes = bytes, .alignment = backing_alignment, .fixed = .init(bytes[prefix..]) };
            const result = block.fixed.allocator().rawAlloc(length, alignment, return_address) orelse unreachable;
            memory.blocks = block;
            memory.reserved_bytes += size;
            memory.assigned_bytes += block.fixed.end_index;
            context.bytes += block.fixed.end_index;
            return result;
        }

        fn resize(raw: *anyopaque, bytes: []u8, _: std.mem.Alignment, length: usize, _: usize) bool {
            const memory = owner(raw).memory;
            memory.mutex.lockUncancelable(memory.io);
            defer memory.mutex.unlock(memory.io);
            if (memory.sealed) @panic("backing resize after initialization");
            return length <= bytes.len;
        }

        fn remap(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, length: usize, return_address: usize) ?[*]u8 {
            return if (resize(raw, bytes, alignment, length, return_address)) bytes.ptr else null;
        }

        // Individual frees retain backing pages until deinit.
        fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}
    };
};

test "initialization requests determine capacity and sealing retains live allocations" {
    var memory = Memory.init(std.testing.allocator, std.testing.io);
    defer memory.deinit();
    try std.testing.expectEqual(@as(usize, 0), memory.reserved_bytes);
    const first = memory.allocator("first");
    const second = memory.allocator("second");
    const a = try first.alignedAlloc(u8, .@"64", 256);
    const b = try second.alloc(u8, 256);
    @memset(a, 11);
    @memset(b, 22);
    first.free(a);
    try std.testing.expectEqual(@as(usize, 512), memory.assigned_bytes);
    try std.testing.expectEqual(@as(usize, 256), memory.owners[0].bytes);
    try std.testing.expectEqual(@as(usize, 256), memory.owners[1].bytes);
    const large = try second.alignedAlloc(u8, .@"64", 1024 * 1024);
    @memset(large, 33);
    const reserved = memory.reserved_bytes;
    const address = large.ptr;
    memory.seal();
    try std.testing.expectEqual(reserved, memory.reserved_bytes);
    try std.testing.expectEqual(address, large.ptr);
    try std.testing.expectEqual(@as(u8, 22), b[0]);
    for (large) |byte| try std.testing.expectEqual(@as(u8, 33), byte);
}

test "small initialization allocations share backing pages" {
    var memory = Memory.init(std.testing.allocator, std.testing.io);
    defer memory.deinit();
    const allocator = memory.allocator("small");
    var allocations: [16][]u8 = undefined;
    for (&allocations, 0..) |*bytes, index| {
        bytes.* = try allocator.alloc(u8, 17);
        @memset(bytes.*, @intCast(index));
    }
    try std.testing.expectEqual(std.heap.pageSize(), memory.reserved_bytes);
    memory.seal();
    for (allocations, 0..) |bytes, index| for (bytes) |byte| {
        try std.testing.expectEqual(@as(u8, @intCast(index)), byte);
    };
}
