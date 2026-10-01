const protocol = @import("protocol.zig");

pub const Route = union(enum) {
    destination: usize,
    pending,
    reject,
};

pub const SingleSimulation = struct {
    pub fn route(_: *SingleSimulation, _: protocol.Profile) Route {
        return .{ .destination = 0 };
    }
};
