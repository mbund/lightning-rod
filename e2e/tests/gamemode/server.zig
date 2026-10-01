const fixture = @import("../../src/fixture.zig");

pub const settings: fixture.Settings = .{
    .kind = .inventory,
    .players = .{ .gamemode = .survival },
};
