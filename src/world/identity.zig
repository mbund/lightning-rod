const std = @import("std");

pub const Handle = packed struct(u32) {
    index: u16,
    generation: u16,

    pub fn eql(a: Handle, b: Handle) bool {
        return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
    }
};

pub const Key = packed struct(u128) {
    value: u128,
};

pub const DimensionId = packed struct(u16) {
    index: u16,
};
pub const GeneratorId = enum(u16) { _ };

pub const invalid = Handle{
    .index = std.math.maxInt(u16),
    .generation = 0,
};

pub fn valid(handle: Handle) bool {
    return handle.generation != 0 and handle.index != std.math.maxInt(u16);
}

test "world handles include their generation" {
    const first = Handle{ .index = 7, .generation = 1 };
    const replacement = Handle{ .index = 7, .generation = 2 };
    try std.testing.expect(!first.eql(replacement));
    try std.testing.expect(!valid(invalid));
}
