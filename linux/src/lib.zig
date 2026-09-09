const std = @import("std");
const server = @import("server.zig");
const reexec = @import("reexec.zig");

pub const SessionWorker = @import("session_worker.zig").Worker;
pub const TickPool = @import("tick_pool.zig").Pool;
pub const TickTask = @import("tick_pool.zig").Task;
pub const authentication = @import("authentication.zig");

pub const Configuration = server.Options;

pub fn Profile(comptime protocols: anytype, comptime Plugins: type, comptime configuration: Configuration) type {
    return struct {
        pub const Settings = struct {
            plugins: Plugins,
            authentication: ?@import("lightning_rod").session_api.Authentication = null,
        };

        pub export const lightning_rod_resume_manifest linksection(reexec.Manifest.section_name) = server.resumeManifest(protocols, configuration);

        pub fn run(init: std.process.Init, settings: Settings) !void {
            const Server = server.Server(protocols, Plugins, configuration);
            try Server.run(init, settings.plugins, .{}, settings.authentication);
        }
    };
}

pub fn ProfileWithMeta(
    comptime protocols: anytype,
    comptime Plugins: type,
    comptime Meta: type,
    comptime configuration: Configuration,
) type {
    return struct {
        pub const Settings = struct {
            plugins: Plugins,
            meta: Meta,
            authentication: ?@import("lightning_rod").session_api.Authentication = null,
        };

        pub export const lightning_rod_resume_manifest linksection(reexec.Manifest.section_name) = server.resumeManifest(protocols, configuration);

        pub fn run(init: std.process.Init, settings: Settings) !void {
            const Server = server.Server(protocols, Plugins, configuration);
            try Server.run(init, settings.plugins, settings.meta, settings.authentication);
        }
    };
}
