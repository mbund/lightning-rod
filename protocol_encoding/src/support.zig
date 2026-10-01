const std = @import("std");
const builtin = @import("builtin");
const nbt_codec = @import("nbt");
pub const cursor = @import("cursor.zig");
pub const scan = @import("scan.zig");

pub const ReadError = error{
    UnexpectedPacketId,
    ExtraDataAfterEndOfPacket,
    EndOfStream,
    NegativeLength,
    InvalidNbtTag,
    NbtDepthLimit,
    NbtNodeLimit,
    LengthOverflow,
    VarIntTooLong,
    VarLongTooLong,
    CollectionTooLarge,
};

pub const WriteError = error{
    InvalidCompletion,
    InvalidTag,
    LengthMismatch,
    EndOfStream,
    NegativeLength,
    LengthOverflow,
    TooManyItems,
    MissingItems,
};

const SEGMENT_BITS = 0x7F;
const CONTINUE_BIT = 0x80;
pub const maximum_sequence_elements: usize = 65_536;
const nbt_max_depth = 128;

pub const UUID = u128;
pub const lpVec3 = struct { x: f64, y: f64, z: f64 };
pub const restBuffer = []const u8;
pub const nbt = []const u8;
pub const optionalNbt = ?[]const u8;
pub const anonymousNbt = []const u8;
pub const anonOptionalNbt = ?[]const u8;

pub fn read_int(buffer: []const u8, comptime T: type) !struct { T, []const u8 } {
    const size = @divExact(@typeInfo(T).int.bits, 8);
    if (buffer.len < size) return error.EndOfStream;

    const value = std.mem.readInt(T, buffer[0..size], .big);
    const rest = buffer[size..];
    return .{ value, rest };
}

pub fn read_varint(buffer: []const u8) !struct { i32, []const u8 } {
    var value: i32 = 0;
    var rest = buffer;

    for (0..5) |i| {
        if (rest.len == 0) return error.EndOfStream;

        const b = @as(i32, rest[0]);
        rest = rest[1..];
        value |= (b & SEGMENT_BITS) << (@as(u5, @intCast(i)) * 7);
        if (b & CONTINUE_BIT == 0) return .{ value, rest };
    }

    return error.VarIntTooLong;
}

pub fn read_varlong(buffer: []const u8) !struct { i64, []const u8 } {
    var value: i64 = 0;
    var rest = buffer;

    for (0..10) |i| {
        if (rest.len == 0) return error.EndOfStream;

        const b = @as(i64, rest[0]);
        rest = rest[1..];
        value |= (b & SEGMENT_BITS) << (@as(u6, @intCast(i)) * 7);
        if (b & CONTINUE_BIT == 0) return .{ value, rest };
    }

    return error.VarLongTooLong;
}

pub fn read_u8(buffer: []const u8) !struct { u8, []const u8 } {
    return read_int(buffer, u8);
}

pub fn read_u16(buffer: []const u8) !struct { u16, []const u8 } {
    return read_int(buffer, u16);
}

pub fn read_u32(buffer: []const u8) !struct { u32, []const u8 } {
    return read_int(buffer, u32);
}

pub fn read_u64(buffer: []const u8) !struct { u64, []const u8 } {
    return read_int(buffer, u64);
}

pub fn read_i8(buffer: []const u8) !struct { i8, []const u8 } {
    return read_int(buffer, i8);
}

pub fn read_i16(buffer: []const u8) !struct { i16, []const u8 } {
    return read_int(buffer, i16);
}

pub fn read_i32(buffer: []const u8) !struct { i32, []const u8 } {
    return read_int(buffer, i32);
}

pub fn read_i64(buffer: []const u8) !struct { i64, []const u8 } {
    return read_int(buffer, i64);
}

pub fn read_bool(buffer: []const u8) !struct { bool, []const u8 } {
    const value, const rest = try read_u8(buffer);
    return .{ value != 0, rest };
}

pub fn read_f32(buffer: []const u8) !struct { f32, []const u8 } {
    const value, const rest = try read_u32(buffer);
    return .{ @bitCast(value), rest };
}

pub fn read_f64(buffer: []const u8) !struct { f64, []const u8 } {
    const value, const rest = try read_u64(buffer);
    return .{ @bitCast(value), rest };
}

pub fn read_UUID(buffer: []const u8) !struct { u128, []const u8 } {
    return read_int(buffer, u128);
}

pub fn read_lpVec3(buffer: []const u8) ReadError!struct { lpVec3, []const u8 } {
    if (buffer.len == 0) return error.EndOfStream;
    if (buffer[0] == 0) return .{ .{ .x = 0, .y = 0, .z = 0 }, buffer[1..] };
    if (buffer.len < 6) return error.EndOfStream;
    const packed_value = @as(u64, std.mem.readInt(u32, buffer[2..6], .big)) << 16 | std.mem.readInt(u16, buffer[0..2], .little);
    var scale: u64 = buffer[0] & 3;
    var rest = buffer[6..];
    if (buffer[0] & 4 != 0) {
        const continuation, const after = try read_varint(rest);
        scale |= @as(u64, @as(u32, @bitCast(continuation))) << 2;
        rest = after;
    }
    var value: lpVec3 = undefined;
    inline for (.{ "x", "y", "z" }, 0..) |field, index| {
        const quantized = @min((packed_value >> (3 + index * 15)) & 32767, 32766);
        @field(value, field) = (@as(f64, @floatFromInt(quantized)) * 2.0 / 32766.0 - 1.0) * @as(f64, @floatFromInt(scale));
    }
    return .{ value, rest };
}

pub fn write_lpVec3(buffer: []u8, value: lpVec3) WriteError![]u8 {
    var components = [_]f64{ value.x, value.y, value.z };
    var maximum: f64 = 0;
    for (&components) |*component| {
        component.* = if (std.math.isNan(component.*)) 0 else std.math.clamp(component.*, -17179869183.0, 17179869183.0);
        maximum = @max(maximum, @abs(component.*));
    }
    if (maximum < 1.0 / 32766.0) return write_u8(buffer, 0);
    if (buffer.len < 6) return error.EndOfStream;
    const scale: u64 = @intFromFloat(@ceil(maximum));
    var packed_value: u64 = scale & 3;
    if (scale > 3) packed_value |= 4;
    inline for (components, 0..) |component, index| {
        const quantized: u64 = @intFromFloat(@floor((component / @as(f64, @floatFromInt(scale)) * 0.5 + 0.5) * 32766.0 + 0.5));
        packed_value |= quantized << (3 + index * 15);
    }
    std.mem.writeInt(u16, buffer[0..2], @truncate(packed_value), .little);
    std.mem.writeInt(u32, buffer[2..6], @intCast(packed_value >> 16), .big);
    return if (scale > 3) write_varint(buffer[6..], @bitCast(@as(u32, @intCast(scale >> 2)))) else buffer[6..];
}

pub fn read_void(buffer: []const u8) !struct { void, []const u8 } {
    return .{ {}, buffer };
}

pub fn read_buffer_exact(buffer: []const u8, length: usize) !struct { []const u8, []const u8 } {
    if (buffer.len < length) return error.EndOfStream;
    return .{ buffer[0..length], buffer[length..] };
}

pub fn read_buffer_counted(buffer: []const u8, comptime Count: type) !struct { []const u8, []const u8 } {
    const length, const rest = try switch (Count) {
        i32 => read_varint(buffer),
        i64 => read_varlong(buffer),
        u8 => read_u8(buffer),
        u16 => read_u16(buffer),
        u32 => read_u32(buffer),
        else => @compileError("unsupported buffer count type"),
    };
    if (length < 0) return error.NegativeLength;
    return read_buffer_exact(rest, @intCast(length));
}

pub fn count_to_usize(value: anytype) ReadError!usize {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    if (info != .int) @compileError("count must be an integer");
    if (info.int.signedness == .signed and value < 0) return error.NegativeLength;
    return std.math.cast(usize, value) orelse error.LengthOverflow;
}

pub fn bit_mask(comptime bits: u16) u64 {
    if (bits >= 64) return std.math.maxInt(u64);
    return (@as(u64, 1) << @as(u6, @intCast(bits))) - 1;
}

pub fn read_packed_bits(buffer: []const u8, comptime bits: u16) ReadError!struct { u64, []const u8 } {
    const byte_count = (bits + 7) / 8;

    if (byte_count > 8) @compileError("packed bitfield is wider than u64");
    if (buffer.len < byte_count) return error.EndOfStream;

    var value: u64 = 0;

    for (buffer[0..byte_count]) |byte| {
        value = (value << 8) | byte;
    }

    return .{ value, buffer[byte_count..] };
}

pub fn write_packed_bits(buffer: []u8, comptime bits: u16, value: u64) WriteError![]u8 {
    const byte_count = (bits + 7) / 8;

    if (byte_count > 8) @compileError("packed bitfield is wider than u64");
    if (buffer.len < byte_count) return error.EndOfStream;

    var i: usize = 0;

    while (i < byte_count) : (i += 1) {
        const shift: u6 = @intCast((byte_count - 1 - i) * 8);
        buffer[i] = @intCast((value >> shift) & 0xff);
    }

    return buffer[byte_count..];
}

pub fn write_int(buffer: []u8, value: anytype) WriteError![]u8 {
    const T = @TypeOf(value);
    const size = @divExact(@typeInfo(T).int.bits, 8);
    if (buffer.len < size) return error.EndOfStream;
    std.mem.writeInt(T, buffer[0..size], value, .big);
    return buffer[size..];
}

pub fn write_varint(buffer: []u8, value: i32) WriteError![]u8 {
    var rest = buffer;
    var bits: u32 = @bitCast(value);

    for (0..5) |_| {
        if (rest.len == 0) return error.EndOfStream;
        if ((bits & ~@as(u32, SEGMENT_BITS)) == 0) {
            rest[0] = @intCast(bits);
            return rest[1..];
        }

        rest[0] = @intCast((bits & SEGMENT_BITS) | CONTINUE_BIT);
        rest = rest[1..];
        bits >>= 7;
    }

    unreachable;
}

pub fn write_varlong(buffer: []u8, value: i64) WriteError![]u8 {
    var rest = buffer;
    var bits: u64 = @bitCast(value);

    for (0..10) |_| {
        if (rest.len == 0) return error.EndOfStream;
        if ((bits & ~@as(u64, SEGMENT_BITS)) == 0) {
            rest[0] = @intCast(bits);
            return rest[1..];
        }

        rest[0] = @intCast((bits & SEGMENT_BITS) | CONTINUE_BIT);
        rest = rest[1..];
        bits >>= 7;
    }

    unreachable;
}

pub fn write_u8(buffer: []u8, value: u8) WriteError![]u8 {
    return write_int(buffer, value);
}

pub fn write_u16(buffer: []u8, value: u16) WriteError![]u8 {
    return write_int(buffer, value);
}

pub fn write_u32(buffer: []u8, value: u32) WriteError![]u8 {
    return write_int(buffer, value);
}

pub fn write_u64(buffer: []u8, value: u64) WriteError![]u8 {
    return write_int(buffer, value);
}

pub fn write_i8(buffer: []u8, value: i8) WriteError![]u8 {
    return write_int(buffer, value);
}

pub fn write_i16(buffer: []u8, value: i16) WriteError![]u8 {
    return write_int(buffer, value);
}

pub fn write_i32(buffer: []u8, value: i32) WriteError![]u8 {
    return write_int(buffer, value);
}

pub fn write_i64(buffer: []u8, value: i64) WriteError![]u8 {
    return write_int(buffer, value);
}

pub fn write_bool(buffer: []u8, value: bool) WriteError![]u8 {
    return write_u8(buffer, if (value) 1 else 0);
}

pub fn write_f32(buffer: []u8, value: f32) WriteError![]u8 {
    return write_u32(buffer, @bitCast(value));
}

pub fn write_f64(buffer: []u8, value: f64) WriteError![]u8 {
    return write_u64(buffer, @bitCast(value));
}

pub fn write_UUID(buffer: []u8, value: u128) WriteError![]u8 {
    return write_int(buffer, value);
}

pub fn write_count(buffer: []u8, comptime Count: type, length: usize) WriteError![]u8 {
    switch (Count) {
        i32 => {
            if (length > @as(usize, @intCast(std.math.maxInt(i32)))) return error.LengthOverflow;
            return write_varint(buffer, @intCast(length));
        },
        i64 => {
            if (length > @as(usize, @intCast(std.math.maxInt(i64)))) return error.LengthOverflow;
            return write_varlong(buffer, @intCast(length));
        },
        u8 => {
            if (length > std.math.maxInt(u8)) return error.LengthOverflow;
            return write_u8(buffer, @intCast(length));
        },
        u16 => {
            if (length > std.math.maxInt(u16)) return error.LengthOverflow;
            return write_u16(buffer, @intCast(length));
        },
        u32 => {
            if (length > std.math.maxInt(u32)) return error.LengthOverflow;
            return write_u32(buffer, @intCast(length));
        },
        else => @compileError("unsupported count type"),
    }
}

pub fn write_pstring(buffer: []u8, value: []const u8, comptime Count: type) WriteError![]u8 {
    const rest = try write_count(buffer, Count, value.len);
    return write_bytes(rest, value);
}

pub fn write_bytes(buffer: []u8, value: []const u8) WriteError![]u8 {
    if (buffer.len < value.len) return error.EndOfStream;
    if (buffer.ptr != value.ptr) @memcpy(buffer[0..value.len], value);
    return buffer[value.len..];
}

pub fn write_buffer_counted(buffer: []u8, value: []const u8, comptime Count: type) WriteError![]u8 {
    const rest = try write_count(buffer, Count, value.len);
    return write_bytes(rest, value);
}

pub fn read_restBuffer(buffer: []const u8) ReadError!struct { restBuffer, []const u8 } {
    return .{ buffer, buffer[buffer.len..] };
}

pub fn write_restBuffer(buffer: []u8, value: restBuffer) WriteError![]u8 {
    return write_bytes(buffer, value);
}

pub fn skip_nbt(buffer: []const u8) ReadError![]const u8 {
    var stack: [nbt_max_depth]nbt_codec.Frame = undefined;
    return map_nbt_read_error(nbt_codec.skip_named(buffer, &stack));
}

pub fn skip_anonymous_nbt(buffer: []const u8) ReadError![]const u8 {
    var stack: [nbt_max_depth]nbt_codec.Frame = undefined;
    return map_nbt_read_error(nbt_codec.skip_anonymous(buffer, &stack));
}

pub fn skip_optional_nbt(buffer: []const u8) ReadError![]const u8 {
    var stack: [nbt_max_depth]nbt_codec.Frame = undefined;
    return map_nbt_read_error(nbt_codec.skip_optional(buffer, &stack));
}

pub fn skip_anon_optional_nbt(buffer: []const u8) ReadError![]const u8 {
    return skip_optional_nbt(buffer);
}

fn consumed_prefix(buffer: []const u8, rest: []const u8) []const u8 {
    return buffer[0 .. buffer.len - rest.len];
}

fn map_nbt_read_error(result: nbt_codec.Error![]const u8) ReadError![]const u8 {
    return result catch |err| switch (err) {
        error.EndOfStream => error.EndOfStream,
        error.NegativeLength => error.NegativeLength,
        error.InvalidNbtTag => error.InvalidNbtTag,
        error.NbtDepthLimit => error.NbtDepthLimit,
        error.NbtNodeLimit => error.NbtNodeLimit,
        error.LengthOverflow => error.LengthOverflow,
        error.InvalidNbtAccess,
        error.InvalidWriterState,
        error.NameTooLong,
        error.TooManyItems,
        error.MissingItems,
        => unreachable,
    };
}

pub fn read_nbt(buffer: []const u8) ReadError!struct { nbt, []const u8 } {
    const rest = try skip_nbt(buffer);
    return .{ consumed_prefix(buffer, rest), rest };
}

pub fn write_nbt(buffer: []u8, value: nbt) WriteError![]u8 {
    return write_bytes(buffer, value);
}

pub fn read_anonymousNbt(buffer: []const u8) ReadError!struct { anonymousNbt, []const u8 } {
    const rest = try skip_anonymous_nbt(buffer);
    return .{ consumed_prefix(buffer, rest), rest };
}

pub fn write_anonymousNbt(buffer: []u8, value: anonymousNbt) WriteError![]u8 {
    return write_bytes(buffer, value);
}

pub fn read_optionalNbt(buffer: []const u8) ReadError!struct { optionalNbt, []const u8 } {
    if (buffer.len == 0) return error.EndOfStream;
    if (buffer[0] == 0) return .{ null, buffer[1..] };

    const rest = try skip_optional_nbt(buffer);
    return .{ consumed_prefix(buffer, rest), rest };
}

pub fn write_optionalNbt(buffer: []u8, value: optionalNbt) WriteError![]u8 {
    return write_bytes(buffer, value orelse return write_u8(buffer, 0));
}

pub fn read_anonOptionalNbt(buffer: []const u8) ReadError!struct { anonOptionalNbt, []const u8 } {
    if (buffer.len == 0) return error.EndOfStream;
    if (buffer[0] == 0) return .{ null, buffer[1..] };

    const rest = try skip_anon_optional_nbt(buffer);
    return .{ consumed_prefix(buffer, rest), rest };
}

pub fn write_anonOptionalNbt(buffer: []u8, value: anonOptionalNbt) WriteError![]u8 {
    return write_bytes(buffer, value orelse return write_u8(buffer, 0));
}
