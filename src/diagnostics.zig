const std = @import("std");

pub const Value = union(enum) {
    signed: i64,
    unsigned: u64,
    float: f64,
    text: []const u8,
};

pub inline fn integer(value: anytype) Value {
    return switch (@typeInfo(@TypeOf(value))) {
        .int => |info| if (info.signedness == .signed)
            .{ .signed = @intCast(value) }
        else
            .{ .unsigned = @intCast(value) },
        .comptime_int => if (value < 0)
            .{ .signed = value }
        else
            .{ .unsigned = value },
        else => @compileError("diagnostic integer value must be an integer"),
    };
}

pub inline fn float(value: anytype) Value {
    return .{ .float = @floatCast(value) };
}

pub inline fn text(value: []const u8) Value {
    return .{ .text = value };
}

pub fn panic(message: []const u8, values: []const Value) noreturn {
    var storage: [1024]u8 = undefined;
    @panic(formatMessage(message, values, &storage));
}

pub fn FullPanic(comptime panicFn: fn ([]const u8, ?usize) noreturn) type {
    return struct {
        pub const call = panicFn;

        fn panicValues(message: []const u8, values: []const Value) noreturn {
            var storage: [1024]u8 = undefined;
            panicFn(formatMessage(message, values, &storage), @returnAddress());
        }

        pub fn sentinelMismatch(expected: anytype, found: @TypeOf(expected)) noreturn {
            _ = found;
            panicFn("sentinel mismatch", @returnAddress());
        }

        pub fn unwrapError(err: anyerror) noreturn {
            panicValues("attempt to unwrap error", &.{text(@errorName(err))});
        }

        pub fn outOfBounds(index: usize, len: usize) noreturn {
            panicValues("index out of bounds (index, len)", &.{ integer(index), integer(len) });
        }

        pub fn startGreaterThanEnd(start: usize, end: usize) noreturn {
            panicValues("start index is larger than end index (start, end)", &.{ integer(start), integer(end) });
        }

        pub fn inactiveUnionField(active: anytype, accessed: @TypeOf(active)) noreturn {
            panicValues("access of inactive union field (active, accessed)", &.{ text(@tagName(active)), text(@tagName(accessed)) });
        }

        pub fn sliceCastLenRemainder(src_len: usize) noreturn {
            panicValues("slice length does not divide exactly into destination elements", &.{integer(src_len)});
        }

        pub fn reachedUnreachable() noreturn {
            panicFn("reached unreachable code", @returnAddress());
        }

        pub fn unwrapNull() noreturn {
            panicFn("attempt to use null value", @returnAddress());
        }

        pub fn castToNull() noreturn {
            panicFn("cast causes pointer to be null", @returnAddress());
        }

        pub fn incorrectAlignment() noreturn {
            panicFn("incorrect alignment", @returnAddress());
        }

        pub fn invalidErrorCode() noreturn {
            panicFn("invalid error code", @returnAddress());
        }

        pub fn integerOutOfBounds() noreturn {
            panicFn("integer does not fit in destination type", @returnAddress());
        }

        pub fn integerOverflow() noreturn {
            panicFn("integer overflow", @returnAddress());
        }

        pub fn shlOverflow() noreturn {
            panicFn("left shift overflowed bits", @returnAddress());
        }

        pub fn shrOverflow() noreturn {
            panicFn("right shift overflowed bits", @returnAddress());
        }

        pub fn divideByZero() noreturn {
            panicFn("division by zero", @returnAddress());
        }

        pub fn exactDivisionRemainder() noreturn {
            panicFn("exact division produced remainder", @returnAddress());
        }

        pub fn integerPartOutOfBounds() noreturn {
            panicFn("integer part of floating point value out of bounds", @returnAddress());
        }

        pub fn corruptSwitch() noreturn {
            panicFn("switch on corrupt value", @returnAddress());
        }

        pub fn shiftRhsTooBig() noreturn {
            panicFn("shift amount is greater than the type size", @returnAddress());
        }

        pub fn invalidEnumValue() noreturn {
            panicFn("invalid enum value", @returnAddress());
        }

        pub fn forLenMismatch() noreturn {
            panicFn("for loop over objects with non-equal lengths", @returnAddress());
        }

        pub fn copyLenMismatch() noreturn {
            panicFn("source and destination arguments have non-equal lengths", @returnAddress());
        }

        pub fn memcpyAlias() noreturn {
            panicFn("@memcpy arguments alias", @returnAddress());
        }

        pub fn noreturnReturned() noreturn {
            panicFn("'noreturn' function returned", @returnAddress());
        }
    };
}

fn formatMessage(message: []const u8, values: []const Value, storage: *[1024]u8) []const u8 {
    var writer = std.Io.Writer.fixed(storage);
    writer.writeAll(message) catch return message;
    for (values, 0..) |value, index| {
        writer.writeAll(if (index == 0) ": " else ", ") catch return message;
        switch (value) {
            .signed => |number| writeSigned(&writer, number) catch return message,
            .unsigned => |number| writeUnsigned(&writer, number) catch return message,
            .float => |number| writeHex(&writer, @bitCast(number)) catch return message,
            .text => |bytes| writer.writeAll(bytes) catch return message,
        }
    }
    return writer.buffered();
}

fn writeSigned(writer: *std.Io.Writer, value: i64) std.Io.Writer.Error!void {
    if (value >= 0) return writeUnsigned(writer, @intCast(value));
    try writer.writeByte('-');
    return writeUnsigned(writer, @as(u64, @intCast(-(value + 1))) + 1);
}

fn writeUnsigned(writer: *std.Io.Writer, value: u64) std.Io.Writer.Error!void {
    var storage: [20]u8 = undefined;
    var index = storage.len;
    var remaining = value;
    for (0..storage.len) |_| {
        index -= 1;
        storage[index] = @intCast('0' + remaining % 10);
        remaining /= 10;
        if (remaining == 0) break;
    }
    return writer.writeAll(storage[index..]);
}

fn writeHex(writer: *std.Io.Writer, value: u64) std.Io.Writer.Error!void {
    const digits = "0123456789abcdef";
    var storage: [18]u8 = undefined;
    storage[0] = '0';
    storage[1] = 'x';
    var index = storage.len;
    var remaining = value;
    for (0..16) |_| {
        index -= 1;
        storage[index] = digits[@intCast(remaining & 0xf)];
        remaining >>= 4;
        if (remaining == 0) break;
    }
    const digits_len = storage.len - index;
    std.mem.copyForwards(u8, storage[2 .. 2 + digits_len], storage[index..]);
    return writer.writeAll(storage[0 .. 2 + digits_len]);
}
