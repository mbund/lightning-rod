const networking = @import("network_uring");
const profiles = @import("profiles");
const persistence = @import("storage_local");
const reload = @import("reload_execve");

pub const Reload = reload;
pub const SingleSimulation = profiles.SingleSimulation;

pub fn Server(comptime Plugins: type, comptime Endpoint: type, comptime SessionPlugins: type, comptime Router: type) type {
    return profiles.Server(Plugins, Endpoint, networking.Transport(.{ .connections = 264, .operations = 1024, .events = 2048 }), persistence.Store, Reload, SessionPlugins, Router);
}
