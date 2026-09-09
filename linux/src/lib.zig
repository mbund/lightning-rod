const std = @import("std");
const server = @import("server.zig");
const reexec = @import("reexec.zig");

pub const Configuration = server.Options;

pub fn Profile(comptime protocols: anytype, comptime Plugins: type, comptime configuration: Configuration) type {
    return struct {
        pub const Settings = struct {
            plugins: Plugins,
        };

        pub export const lightning_rod_resume_manifest linksection(reexec.Manifest.section_name) = server.resumeManifest(protocols, configuration);

        pub fn run(init: std.process.Init, settings: Settings) !void {
            const Server = server.Server(protocols, Plugins, configuration);
            try Server.run(init, settings.plugins, .{});
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
        };

        pub export const lightning_rod_resume_manifest linksection(reexec.Manifest.section_name) = server.resumeManifest(protocols, configuration);

        pub fn run(init: std.process.Init, settings: Settings) !void {
            const Server = server.Server(protocols, Plugins, configuration);
            try Server.run(init, settings.plugins, settings.meta);
        }
    };
}
