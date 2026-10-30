const std = @import("std");

const Manifest = struct {
    version: []const u8,
    main: []const u8,
    jvm: []const []const u8,
    args: []const []const u8,
    classpath: []const []const u8,
    test_classpath: []const []const u8,
    templates: []const struct { name: []const u8, contents: []const u8 },
};

pub const Bundle = struct {
    root: []const u8,
    manifest: Manifest,

    pub fn open(init: std.process.Init, version: []const u8, roots: []const []const u8) !Bundle {
        const allocator = init.arena.allocator();
        const root = root: {
            for (roots) |parent| {
                const candidate = try std.fs.path.join(allocator, &.{ parent, version });
                std.Io.Dir.cwd().access(init.io, candidate, .{}) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };
                break :root candidate;
            }
            if (roots.len != 0) return error.ClientBundleUnavailable;
            const prepared = init.environ_map.get("LIGHTNING_ROD_E2E_CLIENTS") orelse return error.ClientBundleUnavailable;
            break :root try std.fs.path.join(allocator, &.{ prepared, version });
        };
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, try std.fs.path.join(allocator, &.{ root, "runtime.json" }), allocator, .limited(4 * 1024 * 1024));
        const parsed = try std.json.parseFromSlice(Manifest, allocator, bytes, .{ .allocate = .alloc_always });
        if (!std.mem.eql(u8, parsed.value.version, version)) return error.ClientBundleVersionMismatch;
        return .{ .root = root, .manifest = parsed.value };
    }

    pub fn command(self: Bundle, init: std.process.Init, run: []const u8, properties: []const []const u8, arguments: []const []const u8, testing: bool) ![]const []const u8 {
        const allocator = init.arena.allocator();
        try std.Io.Dir.cwd().createDirPath(init.io, run);
        const assets = init.environ_map.get("LIGHTNING_ROD_E2E_ASSETS") orelse try std.fs.path.join(allocator, &.{
            init.environ_map.get("GRADLE_USER_HOME") orelse try std.fs.path.join(allocator, &.{ init.environ_map.get("HOME") orelse return error.HomeUnavailable, ".gradle" }),
            "caches/fabric-loom/assets",
        });
        for (self.manifest.templates) |template| {
            if (!std.mem.eql(u8, std.fs.path.basename(template.name), template.name) or std.mem.eql(u8, template.name, ".") or std.mem.eql(u8, template.name, "..")) return error.InvalidClientBundle;
            const contents = try self.expand(allocator, template.contents, run, assets);
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(allocator, &.{ run, template.name }), .data = contents });
        }
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(allocator, "java");
        for (self.manifest.jvm) |arg| try argv.append(allocator, try self.expand(allocator, arg, run, assets));
        try argv.appendSlice(allocator, properties);
        const entries = if (testing) self.manifest.test_classpath else self.manifest.classpath;
        const paths = try allocator.alloc([]const u8, entries.len);
        for (entries, paths) |entry, *path| {
            if (std.fs.path.isAbsolute(entry)) return error.InvalidClientBundle;
            path.* = try std.fs.path.join(allocator, &.{ self.root, entry });
        }
        try argv.appendSlice(allocator, &.{ "-cp", try std.mem.join(allocator, ":", paths), if (testing) "dev.lightningrod.e2e.FixtureApiTest" else self.manifest.main });
        if (!testing) for (self.manifest.args) |arg| try argv.append(allocator, try self.expand(allocator, arg, run, assets));
        try argv.appendSlice(allocator, arguments);
        return argv.toOwnedSlice(allocator);
    }

    fn expand(self: Bundle, allocator: std.mem.Allocator, value: []const u8, run: []const u8, assets: []const u8) ![]const u8 {
        const root = try std.mem.replaceOwned(u8, allocator, value, "@ROOT@", self.root);
        const directory = try std.mem.replaceOwned(u8, allocator, root, "@RUN@", run);
        return std.mem.replaceOwned(u8, allocator, directory, "@ASSETS@", assets);
    }
};
