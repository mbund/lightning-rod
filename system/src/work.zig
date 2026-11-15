const std = @import("std");

pub const Cost = struct {
    operations: usize = 0,
    bytes: usize = 0,
};

pub const Limits = struct {
    guaranteed: Cost,
    burst: Cost,

    pub fn maximum(self: Limits, owners: usize) error{Overflow}!Cost {
        return .{
            .operations = try std.math.add(usize, try std.math.mul(usize, owners, self.guaranteed.operations), self.burst.operations),
            .bytes = try std.math.add(usize, try std.math.mul(usize, owners, self.guaranteed.bytes), self.burst.bytes),
        };
    }

    pub fn validate(self: Limits, owners: usize, largest: Cost) !void {
        _ = try self.maximum(owners);
        const one = try self.maximum(1);
        if (self.guaranteed.operations == 0 or (largest.bytes != 0 and self.guaranteed.bytes == 0) or largest.operations > one.operations or largest.bytes > one.bytes) return error.InvalidWorkLimits;
    }
};

pub const Allowance = struct {
    guaranteed: *Cost,
    burst: *Cost,

    pub fn take(self: Allowance, cost: Cost) bool {
        std.debug.assert(cost.operations != 0);
        if (cost.operations -| self.guaranteed.operations > self.burst.operations or cost.bytes -| self.guaranteed.bytes > self.burst.bytes) return false;
        const operations = @min(cost.operations, self.guaranteed.operations);
        const bytes = @min(cost.bytes, self.guaranteed.bytes);
        self.guaranteed.operations -= operations;
        self.guaranteed.bytes -= bytes;
        self.burst.operations -= cost.operations - operations;
        self.burst.bytes -= cost.bytes - bytes;
        return true;
    }
};

test "work admission charges both dimensions together and preserves other owners guarantees" {
    const limits: Limits = .{ .guaranteed = .{ .operations = 2, .bytes = 8 }, .burst = .{ .operations = 1, .bytes = 16 } };
    try limits.validate(2, .{ .operations = 1, .bytes = 24 });
    var burst = limits.burst;
    var first = limits.guaranteed;
    var second = limits.guaranteed;
    const a: Allowance = .{ .guaranteed = &first, .burst = &burst };
    const b: Allowance = .{ .guaranteed = &second, .burst = &burst };
    try std.testing.expect(!a.take(.{ .operations = 1, .bytes = 25 }));
    try std.testing.expectEqual(limits.guaranteed, first);
    try std.testing.expectEqual(limits.burst, burst);
    try std.testing.expect(a.take(.{ .operations = 3, .bytes = 24 }));
    try std.testing.expect(!a.take(.{ .operations = 1 }));
    try std.testing.expect(b.take(.{ .operations = 2, .bytes = 8 }));
    try std.testing.expectEqual(Cost{}, burst);
    try std.testing.expectError(error.InvalidWorkLimits, limits.validate(2, .{ .operations = 1, .bytes = 25 }));
    try std.testing.expectError(error.Overflow, limits.maximum(std.math.maxInt(usize)));
    const no_resident_bytes: Limits = .{ .guaranteed = .{ .operations = 1 }, .burst = .{ .bytes = 24 } };
    try std.testing.expectError(error.InvalidWorkLimits, no_resident_bytes.validate(1, .{ .operations = 1, .bytes = 24 }));
}
