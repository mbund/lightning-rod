const runtime = @import("lightning_rod").runtime;

pub const Interface = runtime.Shutdown;
pub const Outcome = runtime.Outcome;

const Never = struct {
    fn requested(_: *anyopaque) bool {
        return false;
    }

    fn begin(_: *anyopaque) Outcome {
        return .ok;
    }
};

const never_vtable: Interface.VTable = .{
    .requested = Never.requested,
    .begin = Never.begin,
};

pub fn never() Interface {
    return .{ .context = @ptrFromInt(1), .vtable = &never_vtable };
}

test "never shutdown source remains inactive" {
    const source = never();
    try @import("std").testing.expect(!source.requested());
    try @import("std").testing.expectEqual(Outcome.ok, source.begin());
}
