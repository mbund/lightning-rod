const std = @import("std");

pub fn directory(options: std.Io.Dir.OpenOptions) !std.testing.TmpDir {
    const io = std.testing.io;
    const parent = try std.Io.Dir.cwd().createDirPathOpen(io, ".zig-cache/tmp", .{});
    errdefer parent.close(io);
    for (0..128) |index| {
        var identity: [12]u8 = @splat(0);
        std.mem.writeInt(u32, identity[0..4], std.testing.random_seed, .little);
        std.mem.writeInt(u64, identity[4..12], index, .little);
        var name: [16]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&name, &identity);
        // Interrupted tests can leave directories behind. Claim a fresh directory atomically.
        parent.createDir(io, &name, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        errdefer parent.deleteTree(io, &name) catch {};
        return .{ .dir = try parent.openDir(io, &name, options), .parent_dir = parent, .sub_path = name };
    }
    return error.TemporaryDirectoryCollision;
}
