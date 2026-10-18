//! Adapted from Ghostty at 189af86eac5e91e1b282bdaf371f369c3863591f.
//! Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors.
//! Distributed under the MIT license in LICENSE.
//!
//! Zig 0.16 disables loop vectorization. Remove this override when compiler_rt
//! supplies an efficient memset. See Ghostty's src/quirks_memset.zig.

const std = @import("std");
const builtin = @import("builtin");

const vector_bytes = @min(128, 2 * (std.simd.suggestVectorLength(u8) orelse 8));
const zero_fill_min = 16 * 1024;
const zva_enabled = builtin.cpu.arch == .aarch64 and builtin.os.tag != .freestanding;

// COFF rejects the duplicate definitions when a consumer also links the CRT.
const enabled = std.simd.suggestVectorLength(u8) != null and
    builtin.object_format != .c and
    builtin.object_format != .coff;

comptime {
    if (enabled) @export(&memset, .{
        .name = "memset",
        .linkage = .strong,
        .visibility = .hidden,
    });
}

fn memset(destination: ?[*]u8, value: c_int, length: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);

    if (length == 0) return destination;
    const bytes = destination.?;
    const byte: u8 = @truncate(@as(c_uint, @bitCast(value)));

    if (length >= vector_bytes) {
        if (comptime zva_enabled) {
            if (length >= zero_fill_min and byte == 0) zero: {
                if (zvaSize() != 64) break :zero;
                const zeros: @Vector(64, u8) = @splat(0);
                const address = @intFromPtr(bytes);
                const aligned = std.mem.alignForward(usize, address, 64);
                bytes[0..64].* = zeros;

                // DC ZVA writes a whole aligned cache line. Keep it inside the allocation.
                var cursor: [*]u8 = @ptrFromInt(aligned);
                const end = address + length;
                while (@intFromPtr(cursor) + 64 <= end) : (cursor += 64) {
                    asm volatile ("dc zva, %[ptr]"
                        :
                        : [ptr] "r" (cursor),
                        : .{ .memory = true });
                }
                bytes[length - 64 ..][0..64].* = zeros;
                return destination;
            }
        }

        const repeated: @Vector(vector_bytes, u8) = @splat(byte);
        var offset: usize = 0;
        while (offset + vector_bytes <= length) : (offset += vector_bytes) {
            bytes[offset..][0..vector_bytes].* = repeated;
            // Prevent LLVM from replacing this loop with a recursive memset call.
            asm volatile ("" ::: .{ .memory = true });
        }
        // Overlap the last vector so every store stays inside the allocation.
        if (offset != length) bytes[length - vector_bytes ..][0..vector_bytes].* = repeated;
        return destination;
    }

    comptime std.debug.assert(vector_bytes <= 128);
    if (comptime vector_bytes > 64) {
        if (length >= 64) {
            const repeated: @Vector(64, u8) = @splat(byte);
            bytes[0..64].* = repeated;
            bytes[length - 64 ..][0..64].* = repeated;
            return destination;
        }
    }
    if (length >= 16) {
        const repeated: @Vector(16, u8) = @splat(byte);
        bytes[0..16].* = repeated;
        bytes[length - 16 ..][0..16].* = repeated;
        if (length > 32) {
            bytes[16..32].* = repeated;
            bytes[length - 32 ..][0..16].* = repeated;
        }
        return destination;
    }
    if (length >= 8) {
        const repeated: @Vector(8, u8) = @splat(byte);
        bytes[0..8].* = repeated;
        bytes[length - 8 ..][0..8].* = repeated;
        return destination;
    }
    if (length >= 4) {
        const repeated: @Vector(4, u8) = @splat(byte);
        bytes[0..4].* = repeated;
        bytes[length - 4 ..][0..4].* = repeated;
        return destination;
    }
    var offset: usize = 0;
    while (offset < length) : (offset += 1) {
        bytes[offset] = byte;
        asm volatile ("" ::: .{ .memory = true });
    }
    return destination;
}

var zva_size: std.atomic.Value(usize) = .init(0);

fn zvaSize() usize {
    const cached = zva_size.load(.monotonic);
    if (cached != 0) return cached;
    const identifier = asm ("mrs %[out], dczid_el0"
        : [out] "=r" (-> u64),
    );
    // Bit 4 prohibits DC ZVA. Bits 0 through 3 encode its size in four-byte words.
    const size: usize = if (identifier & 0x10 != 0) 1 else @as(usize, 4) << @intCast(identifier & 0xf);
    // Every thread observes the same hardware capability.
    zva_size.store(size, .monotonic);
    return size;
}

test "memset exported symbol selects the override" {
    const symbol = @extern(*const fn (?[*]u8, c_int, usize) callconv(.c) ?[*]u8, .{ .name = "memset" });
    if (enabled)
        try std.testing.expectEqual(@intFromPtr(&memset), @intFromPtr(symbol));
}

test "memset alignment lengths return value and guard bytes" {
    var buffer: [4 * vector_bytes + 33]u8 = undefined;
    for (0..vector_bytes + 1) |offset| {
        for (0..buffer.len - offset) |length| {
            for ([_]u8{ 0, 0x5c, 0xff }) |value| {
                @memset(&buffer, 0xaa);
                const region = buffer[offset..][0..length];
                try std.testing.expectEqual(region.ptr, memset(region.ptr, value, length).?);
                for (buffer[0..offset]) |byte| try std.testing.expectEqual(0xaa, byte);
                for (region) |byte| try std.testing.expectEqual(value, byte);
                for (buffer[offset + length ..]) |byte| try std.testing.expectEqual(0xaa, byte);
            }
        }
    }
    try std.testing.expectEqual(null, memset(null, 0x11, 0));
    var one: [1]u8 = .{0xaa};
    try std.testing.expectEqual(@as([*]u8, &one), memset(&one, 0x11, 0).?);
    try std.testing.expectEqual(0xaa, one[0]);
}

test "memset uses the low byte of a C int" {
    var buffer: [4]u8 = undefined;
    _ = memset(&buffer, -1, buffer.len);
    for (buffer) |byte| try std.testing.expectEqual(0xff, byte);
    _ = memset(&buffer, 0x1234, buffer.len);
    for (buffer) |byte| try std.testing.expectEqual(0x34, byte);
}

test "memset large fills preserve their boundaries" {
    const buffer = try std.testing.allocator.alloc(u8, 2 * zero_fill_min + 66);
    defer std.testing.allocator.free(buffer);

    for ([_]usize{ zero_fill_min - 1, zero_fill_min, zero_fill_min + 63, 2 * zero_fill_min }) |length| {
        for (0..65) |offset| {
            for ([_]u8{ 0, 0x5c, 0xaa }) |value| {
                @memset(buffer, 0xff);
                const region = buffer[1 + offset ..][0..length];
                _ = memset(region.ptr, value, length);
                for (buffer[0 .. 1 + offset]) |byte| try std.testing.expectEqual(0xff, byte);
                for (region) |byte| try std.testing.expectEqual(value, byte);
                for (buffer[1 + offset + length ..]) |byte| try std.testing.expectEqual(0xff, byte);
            }
        }
    }
}
