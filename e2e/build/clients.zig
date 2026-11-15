//! Client runtimes for each Minecraft release, and a test's fixtures compiled against them.

const std = @import("std");

pub const Clients = struct {
    /// Owns the steps.
    b: *std.Build,
    /// The e2e package, which holds the Gradle client sources and the fixture compiler.
    e2e: *std.Build.Dependency,
    /// The test's Java fixture sources, or null for the e2e package's own client checks.
    sources: ?[]const u8,
    bundles: std.StringHashMap(std.Build.LazyPath),
    fixtures: std.StringHashMap(std.Build.LazyPath),

    pub fn init(b: *std.Build, e2e: *std.Build.Dependency, sources: ?[]const u8) Clients {
        if (sources) |path| std.debug.assert(std.fs.path.isAbsolute(path));
        return .{
            .b = b,
            .e2e = e2e,
            .sources = sources,
            .bundles = .init(b.allocator),
            .fixtures = .init(b.allocator),
        };
    }

    /// The client runtime for `version`. CI prepares these once and names their parent
    /// directory in LIGHTNING_ROD_E2E_CLIENTS.
    pub fn bundle(self: *Clients, version: []const u8) std.Build.LazyPath {
        if (self.bundles.get(version)) |found| return found;
        const b = self.b;
        const output: std.Build.LazyPath = if (b.graph.environ_map.get("LIGHTNING_ROD_E2E_CLIENTS")) |prepared|
            .{ .cwd_relative = b.pathJoin(&.{ prepared, version }) }
        else
            self.gradle(version);
        self.bundles.put(b.dupe(version), output) catch @panic("OOM");
        return output;
    }

    /// The test's fixtures compiled against the client runtime for `version`.
    pub fn compiled(self: *Clients, version: []const u8) std.Build.LazyPath {
        if (self.fixtures.get(version)) |found| return found;
        const b = self.b;
        const sources = self.sources orelse @panic("This build has no fixture sources");
        const run = b.addRunArtifact(self.e2e.artifact("e2e-fixtures"));
        run.setName(b.fmt("compile fixtures for Minecraft {s}", .{version}));
        run.addDirectoryArg(self.bundle(version));
        run.addArg(version);
        run.addDirectoryArg(.{ .cwd_relative = sources });
        const output = run.addOutputDirectoryArg("fixtures");
        addInputs(b, run, sources);
        self.fixtures.put(b.dupe(version), output) catch @panic("OOM");
        return output;
    }

    fn gradle(self: *Clients, version: []const u8) std.Build.LazyPath {
        const b = self.b;
        const e2e = self.e2e.builder;
        const Version = struct { release: []const u8, api: []const u8, fabric: []const u8 };
        b.dependOnFileContents(self.e2e.path("client/versions.json"));
        const filename = e2e.root.joinString(b.allocator, "client/versions.json") catch @panic("OOM");
        const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, filename, b.allocator, .limited(64 * 1024)) catch @panic("Cannot read client versions");
        const versions = std.json.parseFromSliceLeaky([]const Version, b.allocator, bytes, .{}) catch @panic("Invalid client versions");
        const selected = for (versions) |entry| {
            if (std.mem.eql(u8, entry.release, version)) break entry;
        } else std.debug.panic("Unsupported client version: {s}", .{version});
        const files = b.addWriteFiles();
        for ([_][]const u8{ "build.gradle", "settings.gradle", "gradle.properties", "versions.json" }) |file| {
            _ = files.addCopyFile(self.e2e.path(b.pathJoin(&.{ "client", file })), b.pathJoin(&.{ version, file }));
        }
        const run = std.Build.Step.Run.create(b, b.fmt("prepare Minecraft client {s}", .{version}));
        run.rename_step_with_output_arg = false;
        const client = std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, e2e.root.joinString(b.allocator, "client") catch @panic("OOM"), b.allocator) catch @panic("Cannot resolve client sources");
        run.setCwd(.{ .cwd_relative = client });
        run.addFileArg(self.e2e.path("client/gradlew"));
        run.addArgs(&.{ "--no-daemon", "-p" });
        run.addDirectoryArg(files.getDirectory().path(b, version));
        run.addArgs(&.{
            b.fmt("-Pminecraft_version={s}", .{version}),
            b.fmt("-Pclient_api={s}", .{selected.api}),
            b.fmt("-Pfabric_api_version={s}", .{selected.fabric}),
            b.fmt("-PclientSource={s}", .{client}),
            // Each test compiles its own fixtures against this runtime.
            "-Pfixtures=",
            "exportRuntime",
        });
        const output = run.addPrefixedOutputDirectoryArg("-PruntimeOutput=", version);
        for ([_][]const u8{ "build.gradle", "settings.gradle", "gradle.properties", "versions.json", "gradlew", "gradle/wrapper/gradle-wrapper.jar", "gradle/wrapper/gradle-wrapper.properties" }) |file| {
            run.addFileInput(self.e2e.path(b.pathJoin(&.{ "client", file })));
        }
        _ = run.captureStdErr(.{ .basename = "gradle-stderr.log" });
        if (b.graph.environ_map.get("JAVA_HOME")) |jdk| run.addFileInput(.{ .cwd_relative = b.pathJoin(&.{ jdk, "release" }) });
        addInputs(b, run, b.pathJoin(&.{ client, "src" }));
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
