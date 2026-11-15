const std = @import("std");
pub const Error = error{ OutOfMemory, Corrupt, BufferTooSmall, InvalidArgument };

pub const Compressor = struct {
    memory: []align(64) u8,
    context: *CCtx,
    allocator: std.mem.Allocator,
    maximum: usize,
    parameters: Parameters,
    current: Parameters,
    active: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, level: c_int, maximum: usize) Error!Compressor {
        if (level < 1 or level > 22 or maximum == 0) return error.InvalidArgument;
        const parameters = ZSTD_getCParams(level, maximum, 0);
        const length = try check(ZSTD_estimateCCtxSize_usingCParams(parameters));
        const memory = try allocator.alignedAlloc(u8, .@"64", length);
        errdefer allocator.free(memory);
        const context = ZSTD_initStaticCCtx(memory.ptr, memory.len) orelse return error.OutOfMemory;
        _ = try check(ZSTD_CCtx_setCParams(context, parameters));
        // Static contexts start with zeroed frame parameters.
        _ = try check(ZSTD_CCtx_setParameter(context, content_size_flag, 1));
        _ = try check(ZSTD_CCtx_setParameter(context, checksum_flag, 1));
        return .{ .memory = memory, .context = context, .allocator = allocator, .maximum = maximum, .parameters = parameters, .current = parameters };
    }

    pub fn deinit(self: *Compressor) void {
        std.debug.assert(!self.active.load(.acquire));
        self.allocator.free(self.memory);
        self.* = undefined;
    }

    pub fn encode(self: *Compressor, input: []const u8, output: []u8) Error![]const u8 {
        return self.encodeParameters(self.parameters, self.maximum, input, output);
    }

    /// The owner must remain at a stable address. Encoders use its workspace sequentially.
    pub const Encoder = struct {
        owner: *Compressor,
        parameters: Parameters,
        maximum: usize,

        pub fn encode(self: Encoder, input: []const u8, output: []u8) Error![]const u8 {
            return self.owner.encodeParameters(self.parameters, self.maximum, input, output);
        }
    };

    pub fn borrow(self: *Compressor, level: c_int, maximum: usize) Error!Encoder {
        if (level < 1 or level > 22 or maximum == 0 or maximum > self.maximum) return error.InvalidArgument;
        const parameters = ZSTD_getCParams(level, maximum, 0);
        if (try check(ZSTD_estimateCCtxSize_usingCParams(parameters)) > self.memory.len) return error.InvalidArgument;
        return .{ .owner = self, .parameters = parameters, .maximum = maximum };
    }

    fn encodeParameters(self: *Compressor, parameters: Parameters, maximum: usize, input: []const u8, output: []u8) Error![]const u8 {
        if (input.len > maximum) return error.InvalidArgument;
        if (output.len == 0) return error.BufferTooSmall;
        const was_active = self.active.swap(true, .acq_rel);
        std.debug.assert(!was_active);
        defer {
            const owned = self.active.swap(false, .release);
            std.debug.assert(owned);
        }
        if (!std.meta.eql(self.current, parameters)) {
            _ = try check(ZSTD_CCtx_setCParams(self.context, parameters));
            self.current = parameters;
        }
        const length = check(ZSTD_compress2(self.context, output.ptr, output.len, input.ptr, input.len)) catch |err| {
            // A failed frame may leave a session active. Parameters can change only between sessions.
            _ = try check(ZSTD_CCtx_reset(self.context, reset_session));
            return err;
        };
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
        return self.decodeFrame(input, output);
    }

    /// The frame occupies the buffer's suffix. Scratch is used only when overlap is unsafe.
    pub fn decodeSuffix(self: *Decompressor, buffer: []u8, length: usize, maximum: usize, scratch: []u8) Error![]const u8 {
        if (length > buffer.len or maximum > buffer.len) return error.InvalidArgument;
        var input: []const u8 = buffer[buffer.len - length ..];
        const content = try decodedBound(input, maximum);
        var inplace = content <= buffer.len - length;
        if (!inplace) {
            const margin = try check(ZSTD_decompressionMargin(input.ptr, input.len));
            inplace = margin <= buffer.len - @as(usize, @intCast(content));
        }
        if (!inplace) {
            if (scratch.len < length) return error.BufferTooSmall;
            @memcpy(scratch[0..length], input);
            input = scratch[0..length];
        }
        return self.decodeFrame(input, buffer[0..if (inplace) @intCast(content) else maximum]);
    }

    fn decodeFrame(self: *Decompressor, input: []const u8, output: []u8) Error![]const u8 {
        const length = try check(ZSTD_decompressDCtx(self.context, output.ptr, output.len, input.ptr, input.len));
        return output[0..length];
    }
};

pub fn bound(length: usize) usize {
    return ZSTD_compressBound(length);
}

pub fn decodedBound(frame: []const u8, maximum: usize) Error!usize {
    const length = try check(ZSTD_findFrameCompressedSize(frame.ptr, frame.len));
    if (length != frame.len) return error.Corrupt;
    var size = ZSTD_getFrameContentSize(frame.ptr, frame.len);
    if (size == std.math.maxInt(u64) - 1) return error.Corrupt;
    if (size == std.math.maxInt(u64)) {
        size = ZSTD_decompressBound(frame.ptr, frame.len);
        if (size == std.math.maxInt(u64) - 1) return error.Corrupt;
        size = @min(size, maximum);
    }
    if (size > maximum) return error.BufferTooSmall;
    return @intCast(size);
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
const content_size_flag: c_int = 200;
const reset_session: c_int = 1;
const Code = enum(c_uint) { allocation = 64, destination_size = 70, _ };
extern fn ZSTD_getErrorCode(usize) Code;
extern fn ZSTD_estimateDCtxSize() usize;
extern fn ZSTD_initStaticCCtx([*]align(64) u8, usize) ?*CCtx;
extern fn ZSTD_initStaticDCtx([*]align(64) u8, usize) ?*DCtx;
extern fn ZSTD_CCtx_setParameter(*CCtx, c_int, c_int) usize;
extern fn ZSTD_CCtx_reset(*CCtx, c_int) usize;
extern fn ZSTD_compress2(*CCtx, [*]u8, usize, [*]const u8, usize) usize;
extern fn ZSTD_decompressDCtx(*DCtx, [*]u8, usize, [*]const u8, usize) usize;
extern fn ZSTD_findFrameCompressedSize([*]const u8, usize) usize;
extern fn ZSTD_getFrameContentSize([*]const u8, usize) u64;
extern fn ZSTD_decompressBound([*]const u8, usize) u64;
extern fn ZSTD_decompressionMargin([*]const u8, usize) usize;
extern fn ZSTD_isError(usize) c_uint;
extern fn ZSTD_compressBound(usize) usize;

const Parameters = extern struct { window_log: c_uint, chain_log: c_uint, hash_log: c_uint, search_log: c_uint, minimum_match: c_uint, target_length: c_uint, strategy: c_int };
extern fn ZSTD_getCParams(c_int, u64, usize) Parameters;
extern fn ZSTD_estimateCCtxSize_usingCParams(Parameters) usize;
extern fn ZSTD_CCtx_setCParams(*CCtx, Parameters) usize;
