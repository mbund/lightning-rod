const std = @import("std");
const sessions = @import("sessions");

const assert = std.debug.assert;

pub const headroom = sessions.shared_headroom;
pub const maximum = (1 << 21) - 1;
pub const Error = error{ InvalidPacket, BufferTooSmall };

pub const Workspace = struct {
    pub const memory_limit = 1024 * 1024;
    compressor: *Compressor,
    decompressor: *Decompressor,
    memory_bytes: usize,

    /// Each workspace owns a compressor/decompressor pair. Allocation stays outside packet handling.
    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!Workspace {
        assert(allocation_context == null);
        var context: AllocationContext = .{ .allocator = allocator };
        allocation_context = &context;
        defer allocation_context = null;
        const compressor = libdeflate_alloc_compressor_ex(1, &.{}) orelse return error.OutOfMemory;
        errdefer libdeflate_free_compressor(compressor);
        const decompressor = libdeflate_alloc_decompressor_ex(&.{}) orelse return error.OutOfMemory;
        return .{ .compressor = compressor, .decompressor = decompressor, .memory_bytes = context.bytes };
    }

    pub fn deinit(self: *Workspace) void {
        libdeflate_free_decompressor(self.decompressor);
        libdeflate_free_compressor(self.compressor);
        self.* = undefined;
    }

    /// Payload starts at headroom. Uncompressed framing borrows it in place. Compressed framing
    /// borrows destination. Neither survives reuse of its owner.
    pub fn encode(self: *Workspace, storage: []u8, length: usize, threshold: ?usize, destination: []u8) Error![]u8 {
        if (length == 0 or length > maximum) return error.InvalidPacket;
        if (storage.len < headroom or length > storage.len - headroom) return error.BufferTooSmall;
        if (threshold) |limit| {
            if (length >= limit) return self.compress(storage[headroom..][0..length], destination);
        }

        const end = headroom + length;
        var start: usize = headroom;
        if (threshold != null) {
            start -= 1;
            storage[start] = 0;
        }
        const body_length = end - start;
        if (body_length > maximum) return error.InvalidPacket;
        const prefix = width(body_length);
        start -= prefix;
        write(storage[start..][0..prefix], body_length);
        assert(end <= storage.len);
        return storage[start..end];
    }

    pub fn compress(self: *Workspace, packet: []const u8, destination: []u8) Error![]u8 {
        if (packet.len == 0 or packet.len > maximum) return error.InvalidPacket;
        if (destination.len < headroom + 9) return error.BufferTooSmall;

        const length = libdeflate_zlib_compress(self.compressor, packet.ptr, packet.len, destination[headroom..].ptr, destination.len - headroom);
        if (length == 0) return error.BufferTooSmall;
        const end = headroom + length;
        var start = headroom - width(packet.len);
        write(destination[start..headroom], packet.len);
        const body_length = end - start;
        if (body_length > maximum) return error.InvalidPacket;
        const prefix = width(body_length);
        start -= prefix;
        write(destination[start..][0..prefix], body_length);
        assert(end <= destination.len);
        return destination[start..end];
    }

    /// Input excludes the outer frame length. Plain payloads borrow input. Inflated payloads borrow
    /// destination. Both expire when their owner reuses it.
    pub fn decode(self: *Workspace, input: []const u8, threshold: ?usize, destination: []u8) Error![]const u8 {
        if (input.len == 0 or input.len > maximum) return error.InvalidPacket;

        const limit = threshold orelse return input;
        var length: usize = 0;
        var prefix: usize = 0;

        while (true) {
            if (prefix == 3 or prefix == input.len) return error.InvalidPacket;

            const byte = input[prefix];
            length |= @as(usize, byte & 127) << @intCast(7 * prefix);
            prefix += 1;
            if (byte & 128 == 0) break;
        }

        const body = input[prefix..];
        if (length == 0) {
            if (body.len == 0 or body.len >= limit) return error.InvalidPacket;
            return body;
        }

        if (length < limit or length > maximum) return error.InvalidPacket;
        if (length > destination.len) return error.BufferTooSmall;

        var consumed: usize = 0;
        var produced: usize = 0;
        const result = libdeflate_zlib_decompress_ex(self.decompressor, body.ptr, body.len, destination.ptr, length, &consumed, &produced);
        if (result != 0 or consumed != body.len or produced != length) return error.InvalidPacket;
        return destination[0..length];
    }
};

fn width(value: usize) usize {
    assert(value > 0 and value <= maximum);
    return 1 + @as(usize, @intFromBool(value >= 128)) + @as(usize, @intFromBool(value >= 16384));
}

fn write(bytes: []u8, value: usize) void {
    assert(bytes.len == width(value));

    for (bytes, 0..) |*byte, i| byte.* = @as(u8, @intCast((value >> @intCast(i * 7)) & 127)) | (@as(u8, @intFromBool(i + 1 < bytes.len)) << 7);
}

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
extern fn libdeflate_zlib_decompress_ex(*Decompressor, [*]const u8, usize, [*]u8, usize, *usize, *usize) c_int;

// Libdeflate allocates only during init and has no callback context. The header
// retains the allocator so destruction can run on a different thread.
const AllocationContext = struct { allocator: std.mem.Allocator, bytes: usize = 0 };
const AllocationHeader = struct { allocator: std.mem.Allocator, length: usize };
const allocation_header = std.mem.alignForward(usize, @sizeOf(AllocationHeader), 16);
threadlocal var allocation_context: ?*AllocationContext = null;
fn allocate(size: usize) callconv(.c) ?*anyopaque {
    const context = allocation_context orelse return null;
    const length = std.math.add(usize, size, allocation_header) catch return null;
    if (length > Workspace.memory_limit - context.bytes) return null;
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
