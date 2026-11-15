const std = @import("std");
const builtin = @import("builtin");

const backing = std.heap.page_allocator;
const huge_page_bytes = 2 * 1024 * 1024;

/// Linux may promote these mappings without requiring a reserved HugeTLB pool.
pub const allocator: std.mem.Allocator = .{
    .ptr = backing.ptr,
    .vtable = if (builtin.os.tag == .linux) &vtable else backing.vtable,
};

const vtable: std.mem.Allocator.VTable = .{
    .alloc = alloc,
    .resize = backing.vtable.resize,
    .remap = backing.vtable.remap,
    .free = backing.vtable.free,
};

fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
    // Alignment permits huge pages on first touch without rounding up physical capacity.
    const mapped_alignment = if (length >= huge_page_bytes) alignment.max(.fromByteUnits(huge_page_bytes)) else alignment;
    const bytes = backing.vtable.alloc(context, length, mapped_alignment, address) orelse return null;
    std.posix.madvise(@alignCast(bytes), length, std.posix.MADV.HUGEPAGE) catch |err|
        std.log.warn("event=huge_page_advice_failed reason={s}", .{@errorName(err)});
    return bytes;
}

test "huge page backing preserves aligned allocations through resize and reuse" {
    const original = try allocator.alignedAlloc(u8, .@"64", 4 * 1024 * 1024);
    @memset(original, 37);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(original.ptr) % 64);
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(usize, 0), @intFromPtr(original.ptr) % huge_page_bytes);
    const smaller = allocator.remap(original, 2 * 1024 * 1024) orelse return error.TestUnexpectedResult;
    defer allocator.free(smaller);
    for (smaller) |byte| try std.testing.expectEqual(@as(u8, 37), byte);
}
