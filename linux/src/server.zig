const networking = @import("network_uring");
const profiles = @import("profiles");
const reload = @import("reload_execve");

pub const SingleSimulation = profiles.SingleSimulation;
pub const Startup = profiles.Startup;

pub fn Server(comptime Plugins: type, comptime Endpoint: type, comptime SessionPlugins: type, comptime Router: type) type {
    return profiles.Server(Plugins, Endpoint, networking.Transport(.{ .connections = 264, .operations = 1024, .events = 2048 }), reload, SessionPlugins, Router);
}
