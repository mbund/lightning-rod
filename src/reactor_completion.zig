const std = @import("std");

pub const Kind = enum(u8) {
    accept = 1,
    recv = 2,
    send = 3,
    close = 4,
    log = 5,
    tick_timeout = 6,
};

pub const Tag = struct {
    kind: Kind,
    index: u16,
    token: u32,

    pub fn pack(self: Tag) u64 {
        return (@as(u64, @intFromEnum(self.kind)) << 56) |
            (@as(u64, self.token) << 16) |
            @as(u64, self.index);
    }

    pub fn unpack(value: u64) Tag {
        return .{
            .kind = @enumFromInt(@as(u8, @intCast(value >> 56))),
            .token = @intCast((value >> 16) & std.math.maxInt(u32)),
            .index = @intCast(value & std.math.maxInt(u16)),
        };
    }
};

test "tags preserve every field" {
    const expected = Tag{
        .kind = .recv,
        .index = std.math.maxInt(u16),
        .token = std.math.maxInt(u32),
    };
    try std.testing.expectEqualDeep(expected, Tag.unpack(expected.pack()));
}
