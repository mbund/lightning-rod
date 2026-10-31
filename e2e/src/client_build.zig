const std = @import("std");

pub const Clients = struct {
    b: *std.Build,
    tests: []const u8,
    bundles: std.StringHashMap(std.Build.LazyPath),

    pub fn init(b: *std.Build, tests: []const u8) Clients {
        return .{
            .b = b,
            .tests = tests,
            .bundles = .init(b.allocator),
        };
    }

    pub fn get(self: *Clients, version: []const u8) std.Build.LazyPath {
        if (self.bundles.get(version)) |bundle| return bundle;
        const b = self.b;
        const Version = struct { release: []const u8, api: []const u8, fabric: []const u8 };
        b.dependOnFileContents(b.path("client/versions.json"));
        const filename = b.root.joinString(b.allocator, "client/versions.json") catch @panic("OOM");
        const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, filename, b.allocator, .limited(64 * 1024)) catch @panic("Cannot read client versions");
        const versions = std.json.parseFromSliceLeaky([]const Version, b.allocator, bytes, .{}) catch @panic("Invalid client versions");
        const selected = for (versions) |entry| {
            if (std.mem.eql(u8, entry.release, version)) break entry;
        } else std.debug.panic("Unsupported client version: {s}", .{version});
        const files = b.addWriteFiles();
        for ([_][]const u8{ "build.gradle", "settings.gradle", "gradle.properties", "versions.json" }) |file| {
            _ = files.addCopyFile(b.path(b.pathJoin(&.{ "client", file })), b.pathJoin(&.{ version, file }));
        }
        const run = std.Build.Step.Run.create(b, b.fmt("prepare Minecraft client {s}", .{version}));
        run.rename_step_with_output_arg = false;
        const client = std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, b.root.joinString(b.allocator, "client") catch @panic("OOM"), b.allocator) catch @panic("Cannot resolve client sources");
        const tests = std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, self.tests, b.allocator) catch @panic("Cannot resolve client fixtures");
        run.setCwd(.{ .cwd_relative = client });
        run.addFileArg(b.path("client/gradlew"));
        run.addArgs(&.{ "--no-daemon", "-p" });
        run.addDirectoryArg(files.getDirectory().path(b, version));
        run.addArgs(&.{
            b.fmt("-Pminecraft_version={s}", .{version}),
            b.fmt("-Pclient_api={s}", .{selected.api}),
            b.fmt("-Pfabric_api_version={s}", .{selected.fabric}),
            b.fmt("-PclientSource={s}", .{client}),
            b.fmt("-PtestRoot={s}", .{tests}),
            "exportRuntime",
        });
        const output = run.addPrefixedOutputDirectoryArg("-PruntimeOutput=", b.fmt("clients/{s}", .{version})).dirname();
        for ([_][]const u8{ "build.gradle", "settings.gradle", "gradle.properties", "versions.json", "gradlew", "gradle/wrapper/gradle-wrapper.jar", "gradle/wrapper/gradle-wrapper.properties" }) |file| {
            run.addFileInput(b.path(b.pathJoin(&.{ "client", file })));
        }
        _ = run.captureStdErr(.{ .basename = "gradle-stderr.log" });
        if (b.graph.environ_map.get("JAVA_HOME")) |jdk| run.addFileInput(.{ .cwd_relative = b.pathJoin(&.{ jdk, "release" }) });
        addInputs(b, run, b.root.joinString(b.allocator, "client/src") catch @panic("OOM"));
        addInputs(b, run, self.tests);
        self.bundles.put(version, output) catch @panic("OOM");
        return output;
    }
};

fn addInputs(b: *std.Build, run: *std.Build.Step.Run, root: []const u8) void {
    b.dependOnDirectoryMetadata(.{ .cwd_relative = root });
    const directory = std.Io.Dir.cwd().openDir(b.graph.io, root, .{ .iterate = true }) catch @panic("Cannot open client inputs");
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
            b.dependOnDirectoryMetadata(.{ .cwd_relative = b.pathJoin(&.{ root, entry.path }) });
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
    for (files.items) |file| run.addFileInput(.{ .cwd_relative = b.pathJoin(&.{ root, file }) });
}
