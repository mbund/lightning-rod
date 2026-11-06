const std = @import("std");
pub const Error = error{ OutOfMemory, Corrupt, BufferTooSmall, InvalidArgument };

pub const Compressor = struct {
    memory: []align(64) u8,
    context: *CCtx,
    allocator: std.mem.Allocator,
    maximum: usize,

    pub fn init(allocator: std.mem.Allocator, level: c_int, maximum: usize) Error!Compressor {
        if (level < 1 or level > 22 or maximum == 0) return error.InvalidArgument;
        const parameters = ZSTD_getCParams(level, maximum, 0);
        const length = try check(ZSTD_estimateCCtxSize_usingCParams(parameters));
        const memory = try allocator.alignedAlloc(u8, .@"64", length);
        errdefer allocator.free(memory);
        const context = ZSTD_initStaticCCtx(memory.ptr, memory.len) orelse return error.OutOfMemory;
        _ = try check(ZSTD_CCtx_setCParams(context, parameters));
        _ = try check(ZSTD_CCtx_setParameter(context, checksum_flag, 1));
        return .{ .memory = memory, .context = context, .allocator = allocator, .maximum = maximum };
    }

    pub fn deinit(self: *Compressor) void {
        self.allocator.free(self.memory);
        self.* = undefined;
    }

    pub fn encode(self: *Compressor, input: []const u8, output: []u8) Error![]const u8 {
        if (input.len > self.maximum) return error.InvalidArgument;
        if (output.len == 0) return error.BufferTooSmall;
        const length = try check(ZSTD_compress2(self.context, output.ptr, output.len, input.ptr, input.len));
        std.debug.assert(length <= output.len);
        return output[0..length];
    }
};

pub const Decompressor = struct {
    memory: []align(64) u8,
    context: *DCtx,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Error!Decompressor {
        const length = try check(ZSTD_estimateDCtxSize());
        const memory = try allocator.alignedAlloc(u8, .@"64", length);
        errdefer allocator.free(memory);
        const context = ZSTD_initStaticDCtx(memory.ptr, memory.len) orelse return error.OutOfMemory;
        return .{ .memory = memory, .context = context, .allocator = allocator };
    }

    pub fn deinit(self: *Decompressor) void {
        self.allocator.free(self.memory);
        self.* = undefined;
    }

    pub fn decode(self: *Decompressor, input: []const u8, output: []u8) Error![]const u8 {
        const frame = try check(ZSTD_findFrameCompressedSize(input.ptr, input.len));
        if (frame != input.len) return error.Corrupt;
        const length = try check(ZSTD_decompressDCtx(self.context, output.ptr, output.len, input.ptr, input.len));
        return output[0..length];
    }
};

pub fn bound(length: usize) usize {
    return ZSTD_compressBound(length);
}

fn check(value: usize) Error!usize {
    if (ZSTD_isError(value) != 0) return switch (ZSTD_getErrorCode(value)) {
        .allocation => error.OutOfMemory,
        .destination_size => error.BufferTooSmall,
        else => error.Corrupt,
    };
    return value;
}

const CCtx = opaque {};
const DCtx = opaque {};
const checksum_flag: c_int = 201;
const Code = enum(c_uint) { allocation = 64, destination_size = 70, _ };
extern fn ZSTD_getErrorCode(usize) Code;
extern fn ZSTD_estimateDCtxSize() usize;
extern fn ZSTD_initStaticCCtx([*]align(64) u8, usize) ?*CCtx;
extern fn ZSTD_initStaticDCtx([*]align(64) u8, usize) ?*DCtx;
extern fn ZSTD_CCtx_setParameter(*CCtx, c_int, c_int) usize;
extern fn ZSTD_compress2(*CCtx, [*]u8, usize, [*]const u8, usize) usize;
extern fn ZSTD_decompressDCtx(*DCtx, [*]u8, usize, [*]const u8, usize) usize;
extern fn ZSTD_findFrameCompressedSize([*]const u8, usize) usize;
extern fn ZSTD_isError(usize) c_uint;
extern fn ZSTD_compressBound(usize) usize;

const Parameters = extern struct { window_log: c_uint, chain_log: c_uint, hash_log: c_uint, search_log: c_uint, minimum_match: c_uint, target_length: c_uint, strategy: c_int };
extern fn ZSTD_getCParams(c_int, u64, usize) Parameters;
extern fn ZSTD_estimateCCtxSize_usingCParams(Parameters) usize;
extern fn ZSTD_CCtx_setCParams(*CCtx, Parameters) usize;
