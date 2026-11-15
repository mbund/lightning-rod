const std = @import("std");

pub fn compare(a: []const u8, b: []const u8) std.math.Order {
    const count = @min(a.len, b.len);
    var offset: usize = 0;
    if (count >= 8) {
        const last = count - 8;
        while (offset < last) : (offset += 8) {
            const left = std.mem.readInt(u64, a[offset..][0..8], .big);
            const right = std.mem.readInt(u64, b[offset..][0..8], .big);
            if (left != right) return std.math.order(left, right);
        }
        const left = std.mem.readInt(u64, a[last..][0..8], .big);
        const right = std.mem.readInt(u64, b[last..][0..8], .big);
        return if (left != right) std.math.order(left, right) else std.math.order(a.len, b.len);
    }
    if (count - offset >= 4) {
        const left = std.mem.readInt(u32, a[offset..][0..4], .big);
        const right = std.mem.readInt(u32, b[offset..][0..4], .big);
        if (left != right) return std.math.order(left, right);
        offset += 4;
    }
    if (count - offset >= 2) {
        const left = std.mem.readInt(u16, a[offset..][0..2], .big);
        const right = std.mem.readInt(u16, b[offset..][0..2], .big);
        if (left != right) return std.math.order(left, right);
        offset += 2;
    }
    if (count != offset and a[offset] != b[offset]) return std.math.order(a[offset], b[offset]);
    return std.math.order(a.len, b.len);
}

test "word ordering matches byte ordering at every key length and shared prefix" {
    var random = std.Random.DefaultPrng.init(0xc157);
    var left: [72]u8 = undefined;
    var right: [72]u8 = undefined;
    for (0..65) |left_len| for (0..65) |right_len| for (0..@min(left_len, right_len) + 1) |prefix| {
        random.random().bytes(&left);
        random.random().bytes(&right);
        @memcpy(right[3..][0..prefix], left[1..][0..prefix]);
        const lhs = left[1..][0..left_len];
        const rhs = right[3..][0..right_len];
        try std.testing.expectEqual(std.mem.order(u8, lhs, rhs), compare(lhs, rhs));
        try std.testing.expectEqual(std.mem.order(u8, rhs, lhs), compare(rhs, lhs));
        try std.testing.expectEqual(std.math.Order.eq, compare(lhs, lhs));
    };
}
