const std = @import("std");

pub fn allMarkers(init: std.process.Init, artifacts: []const u8, peers: []const []const u8, suffix: []const u8) !bool {
    for (peers) |peer| {
        const path = try std.fmt.allocPrint(init.gpa, "{s}/{s}{s}", .{ artifacts, peer, suffix });
        defer init.gpa.free(path);
        std.Io.Dir.cwd().access(init.io, path, .{}) catch return false;
    }

    return true;
}
