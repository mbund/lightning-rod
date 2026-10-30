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
        previous: ?*Block = null,
        bytes: []u8,
        alignment: std.mem.Alignment,
        fixed: std.heap.FixedBufferAllocator,
        requests: ?*Request = null,
        live: usize = 0,
    };
    const Request = struct {
        next: ?*Request,
        free_previous: ?*Request = null,
        free_next: ?*Request = null,
        block: *Block,
        owner: *Owner,
        length: usize,
        capacity: usize,
        released: bool = false,

        fn payload(self: *Request) [*]u8 {
            const bytes: [*]u8 = std.mem.asBytes(self);
            return bytes + @sizeOf(Request);
        }
    };

    backing: std.mem.Allocator,
    io: std.Io,
    blocks: ?*Block = null,
    small: ?*Block = null,
    free_requests: ?*Request = null,
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
            var available = memory.free_requests;
            while (available) |request| : (available = request.free_next) {
                if (request.capacity >= length and @intFromPtr(request.payload()) % alignment.toByteUnits() == 0) {
                    removeFree(memory, request);
                    const split = std.mem.alignForward(usize, @intFromPtr(request.payload()) + length, @alignOf(Request));
                    const end = @intFromPtr(request.payload()) + request.capacity;
                    if (split <= end and end - split >= @sizeOf(Request) + 16) {
                        const remainder: *Request = @ptrFromInt(split);
                        remainder.* = .{ .next = request.block.requests, .block = request.block, .owner = context, .length = 0, .capacity = end - split - @sizeOf(Request), .released = true };
                        request.block.requests = remainder;
                        insertFree(memory, remainder);
                        request.capacity = length;
                    }
                    request.owner = context;
                    request.length = length;
                    request.released = false;
                    request.block.live += 1;
                    context.bytes += length;
                    memory.assigned_bytes += length;
                    return request.payload();
                }
            }
            // Small objects must not pin large replaceable buffers.
            const dedicated = length > std.heap.pageSize() / 2;
            if (!dedicated) if (memory.small) |block| if (allocate(context, block, length, alignment, return_address)) |result| return result;
            const backing_alignment = alignment.max(.of(Block));
            const prefix = alignment.forward(@sizeOf(Block));
            const required = std.math.add(usize, prefix + @sizeOf(Request) + @alignOf(Request) - 1 + alignment.toByteUnits() - 1, length) catch return null;
            const page_size = std.heap.pageSize();
            const padded = std.math.add(usize, required, page_size - 1) catch return null;
            const size = std.mem.alignBackward(usize, padded, page_size);
            const bytes = (memory.backing.rawAlloc(size, backing_alignment, return_address) orelse return null)[0..size];
            const block: *Block = @ptrCast(@alignCast(bytes.ptr));
            block.* = .{ .next = memory.blocks, .bytes = bytes, .alignment = backing_alignment, .fixed = .init(bytes[prefix..]) };
            if (memory.blocks) |head| {
                std.debug.assert(head.previous == null);
                head.previous = block;
            }
            memory.blocks = block;
            if (!dedicated) memory.small = block;
            memory.reserved_bytes += size;
            return allocate(context, block, length, alignment, return_address) orelse unreachable;
        }

        fn allocate(context: *Owner, block: *Block, length: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
            const combined_alignment = alignment.max(.of(Request));
            const prefix = combined_alignment.forward(@sizeOf(Request));
            const total = std.math.add(usize, prefix, length) catch return null;
            const allocation = block.fixed.allocator().rawAlloc(total, combined_alignment, return_address) orelse return null;
            const payload = allocation + prefix;
            const request = header(payload);
            request.* = .{ .next = block.requests, .block = block, .owner = context, .length = length, .capacity = length };
            std.debug.assert(request.payload() == payload);
            std.debug.assert(@intFromPtr(payload) % alignment.toByteUnits() == 0);
            block.requests = request;
            block.live += 1;
            context.bytes += length;
            context.memory.assigned_bytes += length;
            return payload;
        }

        fn header(payload: [*]u8) *Request {
            // Alignment padding precedes the header, including in split holes.
            const bytes: []align(@alignOf(Request)) u8 = @alignCast((payload - @sizeOf(Request))[0..@sizeOf(Request)]);
            return std.mem.bytesAsValue(Request, bytes);
        }

        fn lookup(context: *Owner, bytes: []u8) *Request {
            const request = header(bytes.ptr);
            std.debug.assert(request.owner == context);
            std.debug.assert(!request.released and request.length == bytes.len);
            std.debug.assert(request.length <= request.capacity);
            return request;
        }

        fn insertFree(memory: *Memory, request: *Request) void {
            std.debug.assert(request.released);
            std.debug.assert(request.free_previous == null and request.free_next == null);
            request.free_next = memory.free_requests;
            if (memory.free_requests) |head| {
                std.debug.assert(head.free_previous == null);
                head.free_previous = request;
            }
            memory.free_requests = request;
        }

        fn removeFree(memory: *Memory, request: *Request) void {
            std.debug.assert(request.released);
            if (request.free_previous) |previous| {
                std.debug.assert(previous.free_next == request);
                previous.free_next = request.free_next;
            } else {
                std.debug.assert(memory.free_requests == request);
                memory.free_requests = request.free_next;
            }
            if (request.free_next) |next| {
                std.debug.assert(next.free_previous == request);
                next.free_previous = request.free_previous;
            }
            request.free_previous = null;
            request.free_next = null;
        }

        fn resize(raw: *anyopaque, bytes: []u8, _: std.mem.Alignment, length: usize, _: usize) bool {
            const memory = owner(raw).memory;
            memory.mutex.lockUncancelable(memory.io);
            defer memory.mutex.unlock(memory.io);
            if (memory.sealed) @panic("backing resize after initialization");
            const request = lookup(owner(raw), bytes);
            if (length > request.capacity) return false;
            memory.assigned_bytes = memory.assigned_bytes - request.length + length;
            request.owner.bytes = request.owner.bytes - request.length + length;
            request.length = length;
            return true;
        }

        fn remap(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, length: usize, return_address: usize) ?[*]u8 {
            return if (resize(raw, bytes, alignment, length, return_address)) bytes.ptr else null;
        }

        fn free(raw: *anyopaque, bytes: []u8, _: std.mem.Alignment, return_address: usize) void {
            const context = owner(raw);
            const memory = context.memory;
            memory.mutex.lockUncancelable(memory.io);
            defer memory.mutex.unlock(memory.io);
            const request = lookup(context, bytes);
            request.released = true;
            context.bytes -= request.length;
            memory.assigned_bytes -= request.length;
            const block = request.block;
            std.debug.assert(block.live > 0);
            block.live -= 1;
            insertFree(memory, request);
            if (block.live != 0) return;
            var available = block.requests;
            while (available) |entry| : (available = entry.next) removeFree(memory, entry);
            if (block.previous) |previous| {
                std.debug.assert(previous.next == block);
                previous.next = block.next;
            } else {
                std.debug.assert(memory.blocks == block);
                memory.blocks = block.next;
            }
            if (block.next) |next| {
                std.debug.assert(next.previous == block);
                next.previous = block.previous;
            }
            if (memory.small == block) memory.small = null;
            memory.reserved_bytes -= block.bytes.len;
            memory.backing.rawFree(block.bytes, block.alignment, return_address);
        }
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
    try std.testing.expectEqual(@as(usize, 256), memory.assigned_bytes);
    try std.testing.expectEqual(@as(usize, 0), memory.owners[0].bytes);
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

test "initialization replacements reuse holes and release empty backing pages" {
    var memory = Memory.init(std.testing.allocator, std.testing.io);
    defer memory.deinit();
    const allocator = memory.allocator("content");
    const first = try allocator.alloc(u8, 128);
    const second = try allocator.alloc(u8, 128);
    @memset(second, 33);
    allocator.free(first);
    const replacement = try allocator.alloc(u8, 64);
    try std.testing.expectEqual(first.ptr, replacement.ptr);
    for (second) |byte| try std.testing.expectEqual(@as(u8, 33), byte);
    allocator.free(second);
    allocator.free(replacement);
    try std.testing.expectEqual(@as(usize, 0), memory.reserved_bytes);
    try std.testing.expectEqual(@as(usize, 0), memory.assigned_bytes);
    for (0..8) |_| {
        const large = try allocator.alloc(u8, 1024 * 1024);
        allocator.free(large);
        try std.testing.expectEqual(@as(usize, 0), memory.reserved_bytes);
    }
}

test "small objects do not retain a freed large initialization buffer" {
    var memory = Memory.init(std.testing.allocator, std.testing.io);
    defer memory.deinit();
    const allocator = memory.allocator("content");
    const first = try allocator.alloc(u8, 64);
    const baseline = memory.reserved_bytes;
    const large = try allocator.alloc(u8, 1024 * 1024);
    const second = try allocator.alloc(u8, 64);
    allocator.free(large);
    try std.testing.expectEqual(baseline, memory.reserved_bytes);
    allocator.free(first);
    allocator.free(second);
    try std.testing.expectEqual(@as(usize, 0), memory.reserved_bytes);
}

test "aligned allocation headers survive splitting resizing and cross owner reuse" {
    inline for (comptime [_]std.mem.Alignment{ .@"1", .@"8", .@"64", .fromByteUnits(4096) }) |alignment| {
        var memory = Memory.init(std.testing.allocator, std.testing.io);
        defer memory.deinit();
        const first = memory.allocator("first");
        const second = memory.allocator("second");
        const original = try first.alignedAlloc(u8, alignment, 1024);
        const address = original.ptr;
        const pinned = try first.alloc(u8, 16);
        @memset(pinned, 33);
        first.free(original);
        const prefix = try second.alignedAlloc(u8, alignment, 80);
        try std.testing.expectEqual(address, prefix.ptr);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(prefix.ptr) % alignment.toByteUnits());
        const tail = try first.alloc(u8, 64);
        try std.testing.expect(@intFromPtr(tail.ptr) > @intFromPtr(prefix.ptr) + prefix.len);
        try std.testing.expect(@intFromPtr(tail.ptr) + tail.len <= @intFromPtr(address) + original.len);
        @memset(prefix, 11);
        @memset(tail, 22);
        try std.testing.expect(second.resize(prefix, 40));
        try std.testing.expectEqual(@as(usize, 40), memory.owners[1].bytes);
        const shrunk: @TypeOf(prefix) = prefix[0..40];
        try std.testing.expect(second.resize(shrunk, 80));
        for (pinned) |byte| try std.testing.expectEqual(@as(u8, 33), byte);
        for (tail) |byte| try std.testing.expectEqual(@as(u8, 22), byte);
        memory.seal();
        first.free(pinned);
        second.free(prefix);
        first.free(tail);
        try std.testing.expectEqual(@as(usize, 0), memory.assigned_bytes);
        try std.testing.expectEqual(@as(usize, 0), memory.reserved_bytes);
        try std.testing.expect(memory.blocks == null and memory.free_requests == null);
    }
}

test "interleaved block retirement preserves unrelated free records" {
    var memory = Memory.init(std.testing.allocator, std.testing.io);
    defer memory.deinit();
    const first = memory.allocator("packed");
    const second = memory.allocator("dedicated");
    const count = 512;
    var small_allocations: [count][]u8 = undefined;
    var dedicated: [count][]u8 = undefined;
    for (&small_allocations, &dedicated, 0..) |*small, *large, index| {
        small.* = try first.alloc(u8, 64);
        @memset(small.*, @truncate(index));
        large.* = try second.alloc(u8, std.heap.pageSize());
    }
    memory.seal();
    for (0..count / 2) |index| first.free(small_allocations[index * 2]);
    const available = memory.free_requests;
    for (0..count) |index| {
        second.free(dedicated[(index * 17) % count]);
        try std.testing.expectEqual(available, memory.free_requests);
    }
    try std.testing.expectEqual(@as(usize, 0), memory.owners[1].bytes);
    for (0..count / 2) |index| {
        const at = index * 2 + 1;
        for (small_allocations[at]) |byte| try std.testing.expectEqual(@as(u8, @truncate(at)), byte);
        first.free(small_allocations[at]);
    }
    try std.testing.expectEqual(@as(usize, 0), memory.assigned_bytes);
    try std.testing.expectEqual(@as(usize, 0), memory.reserved_bytes);
    try std.testing.expect(memory.blocks == null and memory.free_requests == null and memory.small == null);
}
