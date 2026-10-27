const std = @import("std");
const lightning_rod = @import("lightning_rod");
const profile = @import("profile");

pub const Startup = profile.Startup;
pub const Server = profile.Server;

pub fn metricsExport(init: std.process.Init) ?lightning_rod.metrics.Exporter.Configuration {
    const directory = init.environ_map.get("LIGHTNING_ROD_METRICS_DIRECTORY") orelse return null;
    return .{ .directory = directory, .stop_file = "metrics.stop" };
}
