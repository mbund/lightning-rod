//! Vanilla worlds: default dimensions, spawn, time, weather and their commands.
const std = @import("std");

pub const entity_effects = @import("entity_effects.zig");
pub const world_effects = @import("world_effects.zig");
pub const default_worlds = @import("default_worlds.zig");
pub const environment = @import("environment.zig");
pub const flat = @import("flat.zig");
pub const spawn = @import("spawn.zig");
pub const teleport_commands = @import("teleport_commands.zig");
pub const time = @import("time.zig");
pub const time_commands = @import("time_commands.zig");
pub const weather = @import("weather.zig");

test {
    std.testing.refAllDecls(@This());
}
