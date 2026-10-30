const std = @import("std");

pub const Clients = struct {
    b: *std.Build,
    tests: std.Build.LazyPath,
    prepare: *std.Build.Step.Compile,
    bundles: std.StringHashMap(std.Build.LazyPath),

    pub fn init(b: *std.Build, tests: std.Build.LazyPath) Clients {
        return .{
            .b = b,
            .tests = tests,
            .prepare = b.addExecutable(.{ .name = "prepare-e2e-client", .root_module = b.createModule(.{
                .root_source_file = b.path("src/prepare_client.zig"),
                .target = b.graph.host,
            }) }),
            .bundles = .init(b.allocator),
        };
    }

    pub fn get(self: *Clients, version: []const u8) std.Build.LazyPath {
        if (self.bundles.get(version)) |bundle| return bundle;
        const b = self.b;
        const Version = struct { release: []const u8, api: []const u8, fabric: []const u8 };
        const bytes = b.build_root.handle.readFileAlloc(b.graph.io, "client/versions.json", b.allocator, .limited(64 * 1024)) catch @panic("Cannot read client versions");
        const versions = std.json.parseFromSliceLeaky([]const Version, b.allocator, bytes, .{}) catch @panic("Invalid client versions");
        const selected = for (versions) |entry| {
            if (std.mem.eql(u8, entry.release, version)) break entry;
        } else std.debug.panic("Unsupported client version: {s}", .{version});
        const run = b.addRunArtifact(self.prepare);
        run.step.name = b.fmt("prepare Minecraft client {s}", .{version});
        run.setCwd(b.path("."));
        run.addArg(b.build_root.handle.realPathFileAlloc(b.graph.io, "client", b.allocator) catch @panic("Cannot resolve client sources"));
        run.addArg(std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, self.tests.getPath(b), b.allocator) catch @panic("Cannot resolve client fixtures"));
        run.addArgs(&.{ version, selected.api, selected.fabric });
        const output = run.addOutputDirectoryArg("clients");
        for ([_][]const u8{ "build.gradle", "settings.gradle", "gradle.properties", "versions.json", "gradlew", "gradle/wrapper/gradle-wrapper.jar", "gradle/wrapper/gradle-wrapper.properties" }) |file| {
            run.addFileInput(b.path(b.pathJoin(&.{ "client", file })));
        }
        if (b.graph.environ_map.get("JAVA_HOME")) |jdk| run.addFileInput(.{ .cwd_relative = b.pathJoin(&.{ jdk, "release" }) });
        addInputs(b, run, b.path("client/src"));
        addInputs(b, run, self.tests);
        self.bundles.put(version, output) catch @panic("OOM");
        return output;
    }
};

fn addInputs(b: *std.Build, run: *std.Build.Step.Run, root: std.Build.LazyPath) void {
    const directory = std.Io.Dir.cwd().openDir(b.graph.io, root.getPath(b), .{ .iterate = true }) catch @panic("Cannot open client inputs");
    defer directory.close(b.graph.io);
    var walker = directory.walkSelectively(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    var files: std.ArrayList([]const u8) = .empty;
    while (walker.next(b.graph.io) catch @panic("Cannot read client inputs")) |entry| {
        if (entry.kind == .directory) {
            const excluded = [_][]const u8{ ".zig-cache", "zig-out", "zig-pkg", "artifacts" };
            if (for (excluded) |name| {
                if (std.mem.eql(u8, entry.basename, name)) break true;
            } else false) continue;
            walker.enter(b.graph.io, entry) catch @panic("Cannot open client inputs");
        } else if (entry.kind == .file) {
            if (std.mem.endsWith(u8, entry.basename, ".zig") or std.mem.eql(u8, entry.basename, "build.zig.zon")) continue;
            files.append(b.allocator, b.dupe(entry.path)) catch @panic("OOM");
        }
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.lessThan(u8, a, c);
        }
    }.lessThan);
    for (files.items) |file| run.addFileInput(root.path(b, file));
}
