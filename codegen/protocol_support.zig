const std = @import("std");
const builtin = @import("builtin");
const nbt_module = @import("nbt");

pub const ReadError = error{
    ExtraDataAfterEndOfPacket,
    EndOfStream,
    NegativeLength,
    InvalidNbtTag,
    NbtDepthLimit,
    NbtNodeLimit,
    LengthOverflow,
    VarIntTooLong,
    VarLongTooLong,
};

pub const WriteError = error{
    EndOfStream,
    NegativeLength,
    LengthOverflow,
    TooManyItems,
    MissingItems,
};

const SEGMENT_BITS = 0x7F;
const CONTINUE_BIT = 0x80;
const nbt_max_depth = 128;

pub const UUID = u128;
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

pub fn read_void(buffer: []const u8) !struct { void, []const u8 } {
    return .{ {}, buffer };
}

pub fn read_pstring(buffer: []const u8, comptime Count: type) !struct { []const u8, []const u8 } {
    const length, const rest = try switch (Count) {
        i32 => read_varint(buffer),
        i64 => read_varlong(buffer),
        u8 => read_u8(buffer),
        u16 => read_u16(buffer),
        u32 => read_u32(buffer),
        else => @compileError("unsupported pstring count type"),
    };
    if (length < 0) return error.NegativeLength;
    return read_buffer_exact(rest, @intCast(length));
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

pub fn slice_to_rest(start: []const u8, rest: []const u8) []const u8 {
    return start[0 .. start.len - rest.len];
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

pub fn unpack_unsigned(packed_bits: u64, comptime shift: u16, comptime bits: u16) u64 {
    return (packed_bits >> @as(u6, @intCast(shift))) & bit_mask(bits);
}

pub fn unpack_signed(packed_bits: u64, comptime shift: u16, comptime bits: u16) i64 {
    const value = unpack_unsigned(packed_bits, shift, bits);
    if (bits == 64) return @bitCast(value);
    const sign_bit = @as(u64, 1) << @as(u6, @intCast(bits - 1));
    if ((value & sign_bit) == 0) return @intCast(value);
    return @bitCast(value | ~bit_mask(bits));
}

pub fn pack_unsigned(value: anytype, comptime bits: u16) u64 {
    return @as(u64, @intCast(value)) & bit_mask(bits);
}

pub fn pack_signed(value: anytype, comptime bits: u16) u64 {
    return @as(u64, @bitCast(@as(i64, @intCast(value)))) & bit_mask(bits);
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

    while (true) {
        if (rest.len == 0) return error.EndOfStream;
        if ((bits & ~@as(u32, SEGMENT_BITS)) == 0) {
            rest[0] = @intCast(bits);
            return rest[1..];
        }
        rest[0] = @intCast((bits & SEGMENT_BITS) | CONTINUE_BIT);
        rest = rest[1..];
        bits >>= 7;
    }
}

pub fn write_varlong(buffer: []u8, value: i64) WriteError![]u8 {
    var rest = buffer;
    var bits: u64 = @bitCast(value);

    while (true) {
        if (rest.len == 0) return error.EndOfStream;
        if ((bits & ~@as(u64, SEGMENT_BITS)) == 0) {
            rest[0] = @intCast(bits);
            return rest[1..];
        }
        rest[0] = @intCast((bits & SEGMENT_BITS) | CONTINUE_BIT);
        rest = rest[1..];
        bits >>= 7;
    }
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

pub fn write_void(buffer: []u8) WriteError![]u8 {
    return buffer;
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
    @memcpy(buffer[0..value.len], value);
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
    var stack: [nbt_max_depth]nbt_module.Frame = undefined;
    return map_nbt_read_error(nbt_module.skip_named(buffer, &stack));
}

pub fn skip_anonymous_nbt(buffer: []const u8) ReadError![]const u8 {
    var stack: [nbt_max_depth]nbt_module.Frame = undefined;
    return map_nbt_read_error(nbt_module.skip_anonymous(buffer, &stack));
}

pub fn skip_optional_nbt(buffer: []const u8) ReadError![]const u8 {
    var stack: [nbt_max_depth]nbt_module.Frame = undefined;
    return map_nbt_read_error(nbt_module.skip_optional(buffer, &stack));
}

pub fn skip_anon_optional_nbt(buffer: []const u8) ReadError![]const u8 {
    return skip_optional_nbt(buffer);
}

fn consumed_prefix(buffer: []const u8, rest: []const u8) []const u8 {
    return buffer[0 .. buffer.len - rest.len];
}

fn map_nbt_read_error(result: nbt_module.Error![]const u8) ReadError![]const u8 {
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

pub fn skip_rest(buffer: []const u8) ReadError![]const u8 {
    _ = buffer;
    return &.{};
}

pub const FinalCursor = struct {
    buffer: []const u8,

    pub fn finish(self: FinalCursor) ReadError!void {
        if (self.buffer.len != 0) {
            return error.ExtraDataAfterEndOfPacket;
        }
    }
};

pub const FinalWriteCursor = struct {
    buffer: []u8,
    rest: []u8,

    pub fn finish(self: FinalWriteCursor) []u8 {
        return self.buffer[0 .. self.buffer.len - self.rest.len];
    }
};

pub const RawPayload = struct {
    buffer: []const u8,

    pub fn payload(self: RawPayload) []const u8 {
        return self.buffer;
    }

    pub fn finish(self: RawPayload) ReadError!void {
        _ = self;
    }
};
