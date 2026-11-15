const std = @import("std");
const assert = std.debug.assert;

pub const fragments = @import("fragments.zig");
pub const Error = error{ InvalidData, BufferTooSmall };
pub const memory_limit = 1024 * 1024;

pub fn checksum(bytes: []const u8) u32 {
    return libdeflate_adler32(1, bytes.ptr, bytes.len);
}

pub const Encoder = struct {
    handle: *Compressor,
    memory_bytes: usize,
    /// The last fragment left the match tables cleared, so the next one skips clearing them.
    clean: bool = false,

    pub fn init(allocator: std.mem.Allocator, level: u4) error{OutOfMemory}!Encoder {
        assert(level <= 12 and allocation_context == null);
        var context: AllocationContext = .{ .allocator = allocator };
        allocation_context = &context;
        defer allocation_context = null;
        const handle = libdeflate_alloc_compressor_ex(level, &.{}) orelse return error.OutOfMemory;
        return .{ .handle = handle, .memory_bytes = context.bytes };
    }

    pub fn deinit(self: *Encoder) void {
        libdeflate_free_compressor(self.handle);
        self.* = undefined;
    }

    pub fn encode(self: *Encoder, input: []const u8, output: []u8) Error![]u8 {
        // Ordinary compression clears the tables itself and leaves them used.
        self.clean = false;
        const length = libdeflate_zlib_compress(self.handle, input.ptr, input.len, output.ptr, output.len);
        if (length == 0) return error.BufferTooSmall;
        assert(length <= output.len);
        return output[0..length];
    }

    /// A nonfinal raw stream ending at a byte boundary. Null when the output does not fit or
    /// the input needed more than one block.
    pub fn fragment(self: *Encoder, input: []const u8, output: []u8) ?[]u8 {
        assert(input.len > 0);
        const length = lightning_rod_deflate_fragment(self.handle, input.ptr, input.len, output.ptr, output.len, &self.clean);
        if (length == 0) return null;
        assert(length <= output.len and output[0] & 1 == 0);
        return output[0..length];
    }
};

pub const Decoder = struct {
    handle: *Decompressor,
    memory_bytes: usize,

    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!Decoder {
        assert(allocation_context == null);
        var context: AllocationContext = .{ .allocator = allocator };
        allocation_context = &context;
        defer allocation_context = null;
        const handle = libdeflate_alloc_decompressor_ex(&.{}) orelse return error.OutOfMemory;
        return .{ .handle = handle, .memory_bytes = context.bytes };
    }

    pub fn deinit(self: *Decoder) void {
        libdeflate_free_decompressor(self.handle);
        self.* = undefined;
    }

    pub fn decode(self: *Decoder, input: []const u8, output: []u8) Error![]u8 {
        var consumed: usize = 0;
        var produced: usize = 0;
        const result = libdeflate_zlib_decompress_ex(self.handle, input.ptr, input.len, output.ptr, output.len, &consumed, &produced);
        if (result != 0 or consumed != input.len) return error.InvalidData;
        assert(produced <= output.len);
        return output[0..produced];
    }
};

extern fn libdeflate_adler32(u32, [*]const u8, usize) u32;

const Compressor = opaque {};
const Decompressor = opaque {};
const AllocatorOptions = extern struct {
    sizeof_options: usize = @sizeOf(AllocatorOptions),
    malloc_func: *const fn (usize) callconv(.c) ?*anyopaque = allocate,
    free_func: *const fn (?*anyopaque) callconv(.c) void = release,
};
extern fn libdeflate_alloc_compressor_ex(c_int, *const AllocatorOptions) ?*Compressor;
extern fn libdeflate_free_compressor(*Compressor) void;
extern fn libdeflate_alloc_decompressor_ex(*const AllocatorOptions) ?*Decompressor;
extern fn libdeflate_free_decompressor(*Decompressor) void;
extern fn libdeflate_zlib_compress(*Compressor, [*]const u8, usize, [*]u8, usize) usize;
extern fn lightning_rod_deflate_fragment(*Compressor, [*]const u8, usize, [*]u8, usize, *bool) usize;
extern fn libdeflate_zlib_decompress_ex(*Decompressor, [*]const u8, usize, [*]u8, usize, *usize, *usize) c_int;

// Libdeflate allocates only during init and has no callback context.
// The header retains the allocator for destruction on a different thread.
const AllocationContext = struct { allocator: std.mem.Allocator, bytes: usize = 0 };
const AllocationHeader = struct { allocator: std.mem.Allocator, length: usize };
const allocation_header = std.mem.alignForward(usize, @sizeOf(AllocationHeader), 16);
threadlocal var allocation_context: ?*AllocationContext = null;

fn allocate(size: usize) callconv(.c) ?*anyopaque {
    const context = allocation_context orelse return null;
    const length = std.math.add(usize, size, allocation_header) catch return null;
    if (length > memory_limit - context.bytes) return null;
    const bytes: [*]align(16) u8 = @alignCast(context.allocator.rawAlloc(length, .@"16", @returnAddress()) orelse return null);
    const header: *AllocationHeader = @ptrCast(bytes);
    header.* = .{ .allocator = context.allocator, .length = length };
    context.bytes += length;
    return @ptrCast(bytes + allocation_header);
}

fn release(pointer: ?*anyopaque) callconv(.c) void {
    const bytes: [*]align(16) u8 = @alignCast(@as([*]u8, @ptrCast(pointer orelse return)) - allocation_header);
    const header = @as(*const AllocationHeader, @ptrCast(bytes)).*;
    header.allocator.rawFree(bytes[0..header.length], .@"16", @returnAddress());
}
