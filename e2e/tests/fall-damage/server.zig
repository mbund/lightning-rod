const fixture = @import("../../src/fixture.zig");

pub const settings: fixture.Settings = .{
    .players = .{ .gamemode = .survival, .spawn = .{ .x = 0.5, .y = 73, .z = 0.5 } },
};
