const std = @import("std");

pub const Box = struct {
    minimum: [3]i32,
    maximum: [3]i32,

    pub fn validate(self: Box) void {
        for (0..3) |axis| std.debug.assert(self.minimum[axis] < self.maximum[axis]);
    }
};
