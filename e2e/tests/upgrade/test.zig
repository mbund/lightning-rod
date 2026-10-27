const std = @import("std");
const builtin = @import("builtin");
const protocols = @import("protocol_catalog");
const artifacts_api = @import("../../src/artifacts.zig");
const child = @import("../../src/child.zig");
const reload = @import("reload_execve");

pub const Test = struct {
    executable: []const u8,
    replacement: []const u8,
    arguments: [2][]const u8,
    replaced: bool = false,
    released: bool = false,

    pub fn prepare(init: std.process.Init, current: []const u8, artifacts: []const u8, world: []const u8, revision: []const u8, process_group: *std.atomic.Value(std.posix.pid_t)) !Test {
        const allocator = init.arena.allocator();
        const root = std.mem.trim(u8, try command(init, &.{ "git", "rev-parse", "--show-toplevel" }, null), "\r\n");
        const previous = std.mem.trim(u8, try command(init, &.{ "git", "rev-parse", "--verify", "--end-of-options", try std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{revision}) }, root), "\r\n");
        const head = std.mem.trim(u8, try command(init, &.{ "git", "rev-parse", "HEAD" }, root), "\r\n");
        var names: [protocols.versions.len - 1][]const u8 = undefined;
        var count: usize = 0;
        for (protocols.versions) |version| {
            if (version.protocol_number == protocols.latest.protocol_number) continue;
            names[count] = version.minecraft_version;
            count += 1;
        }
        std.debug.assert(count == names.len);
        const releases = try std.mem.join(allocator, ",", &names);
        const cache = try std.fs.path.join(allocator, &.{ root, "e2e/.zig-cache/upgrades", previous });
        const checkout = try std.fs.path.join(allocator, &.{ cache, "source" });
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(init.io, cache);
        const lock = try cwd.createFile(init.io, try std.fs.path.join(allocator, &.{ cache, "build.lock" }), .{ .truncate = false, .lock = .exclusive });
        defer lock.close(init.io);
        const complete = try std.fs.path.join(allocator, &.{ cache, "checkout.complete" });
        const exists = if (cwd.access(init.io, complete, .{})) |_| true else |err| switch (err) {
            error.FileNotFound => false,
            else => return err,
        };
        if (!exists) {
            try cwd.deleteTree(init.io, checkout);
            try cwd.createDir(init.io, checkout, .default_dir);
            const archive = try std.fs.path.join(allocator, &.{ cache, "source.tar" });
            _ = try command(init, &.{ "git", "archive", "--format=tar", "--output", archive, previous }, root);
            _ = try command(init, &.{ "tar", "-xf", archive, "-C", checkout }, root);
            try cwd.deleteFile(init.io, archive);
            try cwd.writeFile(init.io, .{ .sub_path = complete, .data = previous });
        }
        const prefix = try std.fs.path.join(allocator, &.{ cache, protocols.latest.minecraft_version });
        const log = try cwd.createFile(init.io, try std.fs.path.join(allocator, &.{ artifacts, "previous-build.log" }), .{});
        defer log.close(init.io);
        const zig = init.environ_map.get("LIGHTNING_ROD_E2E_ZIG") orelse "zig";
        const argv: []const []const u8 = &.{ zig, "build", try std.fmt.allocPrint(allocator, "-Doptimize={s}", .{@tagName(builtin.mode)}), try std.fmt.allocPrint(allocator, "-Dreleases={s}", .{releases}), "--prefix", prefix };
        const build_directory = try std.fs.path.join(allocator, &.{ checkout, "examples/vanilla" });
        const compiler = try std.process.spawn(init.io, .{
            .argv = argv,
            .cwd = .{ .path = build_directory },
            .environ_map = init.environ_map,
            .stdin = .ignore,
            .stdout = .{ .file = log },
            .stderr = .{ .file = log },
            .pgid = 0,
        });
        var build: child.ManagedChild = .{ .child = compiler, .group = compiler.id orelse return error.ProcessIdUnavailable };
        process_group.store(build.group, .release);
        defer {
            build.stop(init.io);
            process_group.store(0, .release);
        }
        const result = try build.child.wait(init.io);
        if (result != .exited or result.exited != 0) return error.PreviousServerBuildFailed;

        const executable = try std.fs.path.join(allocator, &.{ world, "upgrade-server" });
        const replacement = try std.fs.path.join(allocator, &.{ world, "upgrade-next" });
        try cwd.copyFile(try std.fs.path.join(allocator, &.{ prefix, "bin/lightning_rod" }), cwd, executable, init.io, .{});
        try cwd.copyFile(current, cwd, replacement, init.io, .{});
        const evidence = try std.json.Stringify.valueAlloc(allocator, .{
            .previous_revision = previous,
            .current_revision = head,
            .current_worktree_dirty = (try command(init, &.{ "git", "status", "--porcelain" }, root)).len != 0,
            .withheld_version = protocols.latest.minecraft_version,
            .previous_releases = releases,
            .current_executable = current,
        }, .{});
        try cwd.writeFile(init.io, .{ .sub_path = try std.fs.path.join(allocator, &.{ artifacts, "upgrade.json" }), .data = evidence });
        const key = init.environ_map.get("LIGHTNING_ROD_E2E_KEY") orelse return error.MissingEncryptionKey;
        return .{
            .executable = executable,
            .replacement = replacement,
            .arguments = .{
                try std.fmt.allocPrint(allocator, "--encryption-key={s}", .{key}),
                try std.fmt.allocPrint(allocator, "--metrics-directory={s}", .{artifacts}),
            },
        };
    }

    pub fn poll(self: *Test, init: std.process.Init, artifacts: []const u8, peers: []const []const u8, server: std.posix.pid_t) !void {
        std.debug.assert(peers.len == 3);
        if (!self.replaced and try artifacts_api.allMarkers(init, artifacts, peers[0..2], ".upgrade-before") and
            try artifacts_api.allMarkers(init, artifacts, peers[2..3], ".upgrade-rejected"))
        {
            const previous = reload.Image.open(init.io, self.executable) catch |err| {
                std.log.err("event=upgrade_incompatible_previous reason={t}", .{err});
                return error.UpgradeHandoffIncompatible;
            };
            defer previous.close(init.io);
            const next = try reload.Image.open(init.io, self.replacement);
            defer next.close(init.io);
            if (previous.supports(protocols.latest.protocol_number, null)) return error.LatestProtocolNotWithheld;
            if (!next.supports(protocols.latest.protocol_number, null)) return error.LatestProtocolNotAdded;
            const existing = protocols.versions[protocols.releaseIndex(protocols.latest.minecraft_version).? - 1];
            if (!previous.supports(existing.protocol_number, null) or !next.supports(existing.protocol_number, null)) return error.ExistingProtocolRemoved;
            try std.Io.Dir.cwd().rename(self.replacement, .cwd(), self.executable, init.io);
            try std.posix.kill(server, .USR1);
            self.replaced = true;
        }
        if (self.replaced and !self.released and try artifacts_api.allMarkers(init, artifacts, peers[0..2], ".upgrade-after")) {
            try std.Io.Dir.cwd().writeFile(init.io, .{
                .sub_path = try std.fs.path.join(init.arena.allocator(), &.{ artifacts, "upgrade.retry" }),
                .data = "ready",
            });
            self.released = true;
        }
    }
};

fn command(init: std.process.Init, argv: []const []const u8, directory: ?[]const u8) ![]const u8 {
    const result = try std.process.run(init.arena.allocator(), init.io, .{
        .argv = argv,
        .cwd = if (directory) |path| .{ .path = path } else .inherit,
        .environ_map = init.environ_map,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    if (result.term != .exited or result.term.exited != 0) {
        std.log.err("event=upgrade_command_failed command={s} stderr={s}", .{ argv[0], result.stderr });
        return error.UpgradeCommandFailed;
    }
    return result.stdout;
}
