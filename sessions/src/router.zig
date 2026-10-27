const protocol = @import("protocol.zig");

pub fn Route(comptime T: type) type {
    return union(enum) {
        destination: T,
        pending,
        reject,
    };
}

pub const SingleSimulation = struct {
    pub const Destination = u32;

    pub fn route(_: *SingleSimulation, _: protocol.Profile) Route(Destination) {
        return .{ .destination = 0 };
    }
};
