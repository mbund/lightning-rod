const networking = @import("network_uring");
const profiles = @import("profiles");

pub const Reload = profiles.Reload;

pub fn Profile(comptime Plugins: type) type {
    return profiles.Profile(Plugins, networking.Transport(.{ .connections = 264, .operations = 1024, .events = 2048 }));
}
