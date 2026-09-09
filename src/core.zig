const composition = @import("core/composition.zig");
const server = @import("core/server.zig");

pub const Configuration = composition.Configuration;
pub const Memory = composition.Memory;

pub fn Server(comptime Selections: type) type {
    return server.Server(Selections);
}
