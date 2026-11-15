const std = @import("std");

const assert = std.debug.assert;

pub const Manifest = struct {
    version: []const u8,
    /// The javac release fixtures compile for.
    java_release: u8,
    main: []const u8,
    jvm: []const []const u8,
    args: []const []const u8,
    classpath: []const []const u8,
    test_classpath: []const []const u8,
    templates: []const struct { name: []const u8, contents: []const u8 },
};

/// A client runtime exported by the Gradle build, without any test's fixtures.
pub const Bundle = struct {
    root: []const u8,
    manifest: Manifest,

    pub fn open(init: std.process.Init, root: []const u8, version: []const u8) !Bundle {
        const allocator = init.arena.allocator();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, try std.fs.path.join(allocator, &.{ root, "runtime.json" }), allocator, .limited(4 * 1024 * 1024));
        const parsed = try std.json.parseFromSlice(Manifest, allocator, bytes, .{ .allocate = .alloc_always });
        if (!std.mem.eql(u8, parsed.value.version, version)) return error.ClientBundleVersionMismatch;
        // The first entry holds the recorder's client classes.
        if (parsed.value.classpath.len == 0) return error.InvalidClientBundle;
        for (parsed.value.classpath) |entry| if (std.fs.path.isAbsolute(entry)) return error.InvalidClientBundle;
        for (parsed.value.test_classpath) |entry| if (std.fs.path.isAbsolute(entry)) return error.InvalidClientBundle;
        return .{ .root = root, .manifest = parsed.value };
    }

    /// Absolute classpath entries of the client, for compiling fixtures against it.
    pub fn classpath(self: Bundle, allocator: std.mem.Allocator) ![]const u8 {
        const paths = try allocator.alloc([]const u8, self.manifest.classpath.len);
        for (self.manifest.classpath, paths) |entry, *path| path.* = try std.fs.path.join(allocator, &.{ self.root, entry });
        return std.mem.join(allocator, ":", paths);
    }

    pub const Launch = union(enum) {
        /// Runs the client with a test's compiled fixture classes.
        fixtures: []const u8,
        /// Runs the fixture API tests outside the game.
        api_test,
    };

    pub fn command(self: Bundle, init: std.process.Init, run: []const u8, properties: []const []const u8, arguments: []const []const u8, launch: Launch) ![]const []const u8 {
        const allocator = init.arena.allocator();
        try std.Io.Dir.cwd().createDirPath(init.io, run);
        const assets = init.environ_map.get("LIGHTNING_ROD_E2E_ASSETS") orelse try std.fs.path.join(allocator, &.{
            init.environ_map.get("GRADLE_USER_HOME") orelse try std.fs.path.join(allocator, &.{ init.environ_map.get("HOME") orelse return error.HomeUnavailable, ".gradle" }),
            "caches/fabric-loom/assets",
        });
        for (self.manifest.templates) |template| {
            if (!std.mem.eql(u8, std.fs.path.basename(template.name), template.name) or std.mem.eql(u8, template.name, ".") or std.mem.eql(u8, template.name, "..")) return error.InvalidClientBundle;
            var contents = try self.expand(allocator, template.contents, run, assets);
            if (launch == .fixtures and std.mem.eql(u8, template.name, "launch.cfg")) contents = try joinFixtures(allocator, contents, try std.fs.path.join(allocator, &.{ self.root, self.manifest.classpath[0] }), launch.fixtures);
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(allocator, &.{ run, template.name }), .data = contents });
        }
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(allocator, "java");
        for (self.manifest.jvm) |arg| try argv.append(allocator, try self.expand(allocator, arg, run, assets));
        try argv.appendSlice(allocator, properties);
        const entries = if (launch == .api_test) self.manifest.test_classpath else self.manifest.classpath;
        const paths = try allocator.alloc([]const u8, entries.len + @intFromBool(launch == .fixtures));
        for (entries, paths[0..entries.len]) |entry, *path| path.* = try std.fs.path.join(allocator, &.{ self.root, entry });
        if (launch == .fixtures) paths[entries.len] = launch.fixtures;
        try argv.appendSlice(allocator, &.{ "-cp", try std.mem.join(allocator, ":", paths), if (launch == .api_test) "dev.lightningrod.e2e.FixtureApiTest" else self.manifest.main });
        if (launch == .fixtures) for (self.manifest.args) |arg| try argv.append(allocator, try self.expand(allocator, arg, run, assets));
        try argv.appendSlice(allocator, arguments);
        return argv.toOwnedSlice(allocator);
    }

    fn expand(self: Bundle, allocator: std.mem.Allocator, value: []const u8, run: []const u8, assets: []const u8) ![]const u8 {
        const root = try std.mem.replaceOwned(u8, allocator, value, "@ROOT@", self.root);
        const directory = try std.mem.replaceOwned(u8, allocator, root, "@RUN@", run);
        return std.mem.replaceOwned(u8, allocator, directory, "@ASSETS@", assets);
    }
};

/// Fabric loads each mod from one class path group. Fixtures join the recorder's group, the one
/// holding the bundle's first classpath entry, so they share its class loader and package.
fn joinFixtures(allocator: std.mem.Allocator, launch: []const u8, recorder: []const u8, fixtures: []const u8) ![]const u8 {
    assert(std.fs.path.isAbsolute(fixtures));
    const key = "fabric.classPathGroups=";
    const start = (std.mem.indexOf(u8, launch, key) orelse return error.InvalidClientBundle) + key.len;
    const end = std.mem.indexOfScalarPos(u8, launch, start, '\n') orelse launch.len;
    // Groups are separated by a doubled path separator, their entries by a single one.
    var group_start = start;
    while (group_start <= end) {
        const group_end = if (std.mem.indexOf(u8, launch[group_start..end], "::")) |offset| group_start + offset else end;
        var entries = std.mem.splitScalar(u8, launch[group_start..group_end], ':');
        while (entries.next()) |entry| {
            if (std.mem.eql(u8, entry, recorder))
                return std.mem.concat(allocator, u8, &.{ launch[0..group_end], ":", fixtures, launch[group_end..] });
        }
        group_start = group_end + 2;
    }
    return error.InvalidClientBundle;
}

test "fixtures join the recorder class path group" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const single = "commonProperties\n\tfabric.classPathGroups=/a/main:/a/client\nclientArgs\n";
    try std.testing.expectEqualStrings("commonProperties\n\tfabric.classPathGroups=/a/main:/a/client:/f\nclientArgs\n", try joinFixtures(allocator, single, "/a/client", "/f"));
    const split = "\tfabric.classPathGroups=/a/main:/a/client::/api/common:/api/client\n";
    try std.testing.expectEqualStrings("\tfabric.classPathGroups=/a/main:/a/client:/f::/api/common:/api/client\n", try joinFixtures(allocator, split, "/a/client", "/f"));
    try std.testing.expectEqualStrings("\tfabric.classPathGroups=/api/common::/a/main:/a/client:/f\n", try joinFixtures(allocator, "\tfabric.classPathGroups=/api/common::/a/main:/a/client\n", "/a/client", "/f"));
    try std.testing.expectError(error.InvalidClientBundle, joinFixtures(allocator, "commonProperties\n", "/a/client", "/f"));
    try std.testing.expectError(error.InvalidClientBundle, joinFixtures(allocator, split, "/b/client", "/f"));
}
