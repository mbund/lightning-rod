//! What each fuzz input runs in: a deterministic Io, whose time and randomness come from the
//! input's seed, and a workspace of its own, emptied between inputs.
const std = @import("std");
const DeterministicIo = @import("system").DeterministicIo;

pub const Environment = struct {
    deterministic: DeterministicIo,
    path: []const u8,
    lock: std.Io.File,

    pub fn init(comptime name: []const u8, seed: u64) !Environment {
        @disableInstrumentation();
        var deterministic: DeterministicIo = .init(std.testing.allocator, .{ .seed = seed });
        errdefer deterministic.deinit();
        const path = ".zig-cache/fuzz-work/" ++ name;
        // The workspace is the real file system's, through the Io beneath the deterministic one.
        const native = deterministic.threaded.io();
        try std.Io.Dir.cwd().createDirPath(native, ".zig-cache/fuzz-work");
        const lock = try std.Io.Dir.cwd().createFile(native, path ++ ".lock", .{ .truncate = false, .lock = .exclusive });
        errdefer lock.close(native);
        try std.Io.Dir.cwd().deleteTree(native, path);
        try std.Io.Dir.cwd().createDirPath(native, path);
        return .{ .deterministic = deterministic, .path = path ++ "/world", .lock = lock };
    }

    pub fn deinit(self: *Environment) void {
        @disableInstrumentation();
        std.Io.Dir.cwd().deleteTree(self.io(), std.fs.path.dirname(self.path).?) catch @panic("cannot clean fuzz workspace");
        self.lock.close(self.io());
        self.deterministic.deinit();
    }

    pub fn io(self: *Environment) std.Io {
        @disableInstrumentation();
        return self.deterministic.io();
    }
};
