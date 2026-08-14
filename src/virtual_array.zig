const std = @import("std");
const huge_pages = @import("huge_page_allocator.zig");

const posix = std.posix;

pub fn Array(comptime T: type) type {
    return struct {
        const Self = @This();

        mapping: []align(std.heap.page_size_min) u8,
        values: []T,
        committed: usize = 0,

        pub fn init(capacity: usize) !Self {
            if (capacity == 0) return error.InvalidVirtualArrayCapacity;
            const byte_count = std.math.mul(usize, capacity, @sizeOf(T)) catch
                return error.VirtualArrayCapacityOverflow;
            const mapped_bytes = std.mem.alignForward(
                usize,
                byte_count,
                std.heap.pageSize(),
            );
            const mapping = try posix.mmap(
                null,
                mapped_bytes,
                .{},
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
                -1,
                0,
            );
            const pointer: [*]T = @ptrCast(@alignCast(mapping.ptr));
            return .{
                .mapping = mapping,
                .values = pointer[0..capacity],
            };
        }

        pub fn deinit(self: *Self) void {
            posix.munmap(self.mapping);
            self.* = undefined;
        }

        pub fn ensure(self: *Self, count: usize) ![]T {
            if (count > self.values.len) return error.VirtualArrayCapacityExceeded;
            if (count <= self.committed) return self.values[0..count];
            const old_bytes = self.committedBytes();
            const new_bytes = std.mem.alignForward(
                usize,
                count * @sizeOf(T),
                std.heap.pageSize(),
            );
            const pages: []align(std.heap.page_size_min) u8 =
                @alignCast(self.mapping[old_bytes..new_bytes]);
            try protect(pages, .{ .READ = true, .WRITE = true });
            @memset(std.mem.sliceAsBytes(self.values[self.committed..count]), 0);
            self.committed = count;
            return self.values[0..count];
        }

        pub fn shrink(self: *Self, count: usize) ![]T {
            if (count > self.committed) return error.VirtualArrayCannotGrowByShrinking;
            if (count == self.committed) return self.values[0..count];
            const old_bytes = self.committedBytes();
            const new_bytes = std.mem.alignForward(
                usize,
                count * @sizeOf(T),
                std.heap.pageSize(),
            );
            const pages: []align(std.heap.page_size_min) u8 =
                @alignCast(self.mapping[new_bytes..old_bytes]);
            try protect(pages, .{});
            try huge_pages.discard(pages);
            self.committed = count;
            return self.values[0..count];
        }

        pub fn committedBytes(self: *const Self) usize {
            return std.mem.alignForward(
                usize,
                self.committed * @sizeOf(T),
                std.heap.pageSize(),
            );
        }
    };
}

fn protect(
    memory: []align(std.heap.page_size_min) u8,
    protection: posix.PROT,
) !void {
    if (memory.len == 0) return;
    switch (posix.errno(posix.system.mprotect(
        memory.ptr,
        memory.len,
        protection,
    ))) {
        .SUCCESS => {},
        .NOMEM => return error.OutOfMemory,
        .ACCES => return error.AccessDenied,
        .INVAL => return error.InvalidVirtualArrayProtection,
        else => |err| return posix.unexpectedErrno(err),
    }
}

test "virtual array commits a stable prefix" {
    var array = try Array(u64).init(1024 * 1024);
    defer array.deinit();
    const address = @intFromPtr(array.values.ptr);
    const first = try array.ensure(17);
    first[16] = 91;
    const second = try array.ensure(4097);
    try std.testing.expectEqual(address, @intFromPtr(second.ptr));
    try std.testing.expectEqual(@as(u64, 91), second[16]);
    try std.testing.expectEqual(@as(u64, 0), second[4096]);
    try std.testing.expect(array.committedBytes() < array.mapping.len);
}

test "virtual array discards a suffix and can recommit it" {
    var array = try Array(u64).init(1024 * 1024);
    defer array.deinit();
    const address = @intFromPtr(array.values.ptr);
    const large = try array.ensure(4097);
    large[4096] = 91;
    _ = try array.shrink(17);
    const recommitted = try array.ensure(4097);
    try std.testing.expectEqual(address, @intFromPtr(recommitted.ptr));
    try std.testing.expectEqual(@as(u64, 0), recommitted[4096]);
}
