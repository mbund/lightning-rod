const std = @import("std");

pub fn alloc(
    comptime T: type,
    allocator: std.mem.Allocator,
    len: usize,
) std.mem.Allocator.Error![]T {
    return alignedAlloc(T, allocator, .of(T), len);
}

pub fn alignedAlloc(
    comptime T: type,
    allocator: std.mem.Allocator,
    comptime alignment: std.mem.Alignment,
    len: usize,
) std.mem.Allocator.Error![]align(alignment.toByteUnits()) T {
    const byte_count = std.math.mul(usize, @sizeOf(T), len) catch
        return error.OutOfMemory;
    if (byte_count == 0) {
        const address = comptime alignment.backward(std.math.maxInt(usize));
        const pointer: [*]align(alignment.toByteUnits()) T = @ptrFromInt(address);
        return pointer[0..0];
    }
    const bytes = allocator.rawAlloc(byte_count, alignment, @returnAddress()) orelse
        return error.OutOfMemory;
    const pointer: [*]align(alignment.toByteUnits()) T = @ptrCast(@alignCast(bytes));
    return pointer[0..len];
}

pub fn create(
    comptime T: type,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!*T {
    const values = try alloc(T, allocator, 1);
    return &values[0];
}
