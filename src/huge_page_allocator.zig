const std = @import("std");
const builtin = @import("builtin");

const page_allocator_vtable = std.heap.page_allocator.vtable;
const log = std.log.scoped(.allocator);
const madv_populate_write: u32 = 23;

pub const huge_page_bytes: usize = 2 * 1024 * 1024;

pub const allocator: std.mem.Allocator = .{
    .ptr = std.heap.page_allocator.ptr,
    .vtable = if (builtin.target.os.tag == .linux)
        &vtable
    else
        page_allocator_vtable,
};

const vtable: std.mem.Allocator.VTable = .{
    .alloc = allocate,
    .resize = resize,
    .remap = remap,
    .free = page_allocator_vtable.free,
};

fn allocate(
    context: *anyopaque,
    len: usize,
    alignment: std.mem.Alignment,
    return_address: usize,
) ?[*]u8 {
    const pointer = page_allocator_vtable.alloc(
        context,
        len,
        alignment,
        return_address,
    ) orelse return null;
    advise(pointer[0..len]);
    commit(pointer[0..len]) catch {
        page_allocator_vtable.free(context, pointer[0..len], alignment, return_address);
        return null;
    };
    return pointer;
}

fn resize(
    context: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    return_address: usize,
) bool {
    if (!page_allocator_vtable.resize(context, memory, alignment, new_len, return_address))
        return false;
    if (new_len > memory.len)
        commit(memory.ptr[0..new_len]) catch return false;
    return true;
}

fn remap(
    _: *anyopaque,
    _: []u8,
    _: std.mem.Alignment,
    _: usize,
    _: usize,
) ?[*]u8 {
    return null;
}

pub fn advise(memory: []u8) void {
    adviseFallible(memory) catch |err|
        log.warn("event=huge_page_advice_failed error={s}", .{@errorName(err)});
}

fn adviseFallible(memory: []u8) !void {
    if (comptime builtin.target.os.tag != .linux) return;
    const pages = pageAlignedInterior(memory) orelse return;
    try std.posix.madvise(pages.ptr, pages.len, std.posix.MADV.HUGEPAGE);
}

pub fn discard(memory: []u8) !void {
    if (comptime builtin.target.os.tag != .linux) return;
    const pages = pageAlignedInterior(memory) orelse return;
    try std.posix.madvise(pages.ptr, pages.len, std.posix.MADV.DONTNEED);
}

pub fn commit(memory: []u8) !void {
    if (memory.len == 0) return;
    if (comptime builtin.target.os.tag != .linux) return touchPages(memory);
    if (pageAlignedInterior(memory)) |pages|
        std.posix.madvise(pages.ptr, pages.len, madv_populate_write) catch |err| switch (err) {
            error.InvalidSyscall, error.MadviseUnavailable => try touchPages(pages),
            else => return err,
        };
    touchByte(&memory[0]);
    touchByte(&memory[memory.len - 1]);
}

fn touchPages(memory: []u8) !void {
    if (memory.len == 0) return;
    const page_size = std.heap.pageSize();
    var offset: usize = 0;
    while (offset < memory.len) : (offset += page_size) {
        touchByte(&memory[offset]);
    }
}

fn touchByte(byte: *u8) void {
    const value: *volatile u8 = byte;
    value.* = value.*;
}

fn pageAlignedInterior(
    memory: []u8,
) ?[]align(std.heap.page_size_min) u8 {
    const page_size = std.heap.pageSize();
    const address = @intFromPtr(memory.ptr);
    const start = std.mem.alignForward(usize, address, page_size);
    const end = std.mem.alignBackward(
        usize,
        std.math.add(usize, address, memory.len) catch return null,
        page_size,
    );
    if (start >= end) return null;
    const pointer: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(start);
    return pointer[0 .. end - start];
}

test "huge page allocator remains an ordinary allocator" {
    const memory = try allocator.alignedAlloc(
        u8,
        .fromByteUnits(huge_page_bytes),
        huge_page_bytes * 2,
    );
    defer allocator.free(memory);
    @memset(memory, 0x5a);
    try std.testing.expectEqual(@as(u8, 0x5a), memory[0]);
    try std.testing.expectEqual(@as(u8, 0x5a), memory[memory.len - 1]);
}

test "advice and discard accept unaligned subranges" {
    const memory = try std.heap.page_allocator.alloc(u8, huge_page_bytes * 2);
    defer std.heap.page_allocator.free(memory);
    const subrange = memory[1 .. memory.len - 1];
    try adviseFallible(subrange);
    try discard(subrange);
}

test "committing a range preserves its contents" {
    const memory = try std.heap.page_allocator.alloc(u8, huge_page_bytes * 2);
    defer std.heap.page_allocator.free(memory);
    @memset(memory, 0x5a);
    try commit(memory);
    try std.testing.expectEqual(@as(u8, 0x5a), memory[0]);
    try std.testing.expectEqual(@as(u8, 0x5a), memory[memory.len - 1]);
}

test "committing an anonymous mapping makes every page resident" {
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;
    const page_count = 16;
    const mapping = try std.posix.mmap(
        null,
        page_count * std.heap.pageSize(),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(mapping);
    try commit(mapping);
    var residency: [page_count]u8 = @splat(0);
    try std.posix.mincore(mapping.ptr, mapping.len, &residency);
    for (residency) |page| try std.testing.expect(page & 1 != 0);
}
