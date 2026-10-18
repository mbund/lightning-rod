const std = @import("std");

pub fn directory(options: std.Io.Dir.OpenOptions) !std.testing.TmpDir {
    const io = std.testing.io;
    const parent = try std.Io.Dir.cwd().createDirPathOpen(io, ".zig-cache/tmp", .{});
    errdefer parent.close(io);
    for (0..128) |_| {
        var random: [12]u8 = undefined;
        io.random(&random);
        var name: [16]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&name, &random);
        // Interrupted fuzz workers can leave directories behind. Claim a fresh directory atomically.
        parent.createDir(io, &name, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        errdefer parent.deleteTree(io, &name) catch {};
        return .{ .dir = try parent.openDir(io, &name, options), .parent_dir = parent, .sub_path = name };
    }
    return error.TemporaryDirectoryCollision;
}
