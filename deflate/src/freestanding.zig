const std = @import("std");

const Allocate = *const fn (usize) callconv(.c) ?*anyopaque;
const Free = *const fn (?*anyopaque) callconv(.c) void;

// Replace utils.c's allocation ABI without its process-wide fallback memory routines.
export var libdeflate_default_malloc_func: ?Allocate = null;
export var libdeflate_default_free_func: ?Free = null;

export fn libdeflate_aligned_malloc(allocate: Allocate, alignment: usize, size: usize) ?*anyopaque {
    std.debug.assert(std.math.isPowerOfTwo(alignment));
    std.debug.assert(alignment >= @alignOf(*anyopaque));
    const overhead = std.math.add(usize, @sizeOf(*anyopaque), alignment - 1) catch return null;
    const length = std.math.add(usize, size, overhead) catch return null;
    const allocation = allocate(length) orelse return null;
    const address = std.mem.alignForward(usize, @intFromPtr(allocation) + @sizeOf(*anyopaque), alignment);
    const original: **anyopaque = @ptrFromInt(address - @sizeOf(*anyopaque));
    original.* = allocation;
    return @ptrFromInt(address);
}

export fn libdeflate_aligned_free(free: Free, pointer: *anyopaque) void {
    const original: *const *anyopaque = @ptrFromInt(@intFromPtr(pointer) - @sizeOf(*anyopaque));
    free(original.*);
}
