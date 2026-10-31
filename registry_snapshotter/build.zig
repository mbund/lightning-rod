const std = @import("std");

pub fn build(b: *std.Build) void {
    const version = b.option([]const u8, "minecraft-version", "Minecraft release to extract") orelse @panic("missing -Dminecraft-version");
    const api = b.option([]const u8, "api", "Registry extractor API variant");
    if (b.graph.environ_map.get("LIGHTNING_ROD_REGISTRIES")) |directory| {
        const snapshot: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ directory, b.fmt("{s}.bin", .{version}) }) };
        b.addNamedLazyPath("snapshot", snapshot);
        b.addNamedLazyPath("lighting", .{ .cwd_relative = b.pathJoin(&.{ directory, b.fmt("{s}-lighting.bin", .{version}) }) });
        b.addNamedLazyPath("fuels", .{ .cwd_relative = b.pathJoin(&.{ directory, b.fmt("{s}-fuels.bin", .{version}) }) });
        b.addNamedLazyPath("physics", .{ .cwd_relative = b.pathJoin(&.{ directory, b.fmt("{s}-physics.bin", .{version}) }) });
        b.addNamedLazyPath("pack", .{ .cwd_relative = b.pathJoin(&.{ directory, b.fmt("{s}-pack.bin", .{version}) }) });
        _ = b.step("snapshot", "Use the prepared Minecraft registries");
        return;
    }
    const files = b.addWriteFiles();
    const directory = b.fmt("{s}-{s}", .{ version, api orelse "default" });
    for ([_][]const u8{ "build.gradle", "settings.gradle", "gradle.properties", "versions.json" }) |name|
        _ = files.addCopyFile(b.path(name), b.fmt("{s}/{s}", .{ directory, name }));
    _ = files.addCopyDirectory(b.path("src"), b.fmt("{s}/src", .{directory}), .{});

    const command = std.Build.Step.Run.create(b, b.fmt("extract Minecraft {s} registries", .{version}));
    command.rename_step_with_output_arg = false;
    _ = command.captureStdOut(.{ .basename = "gradle.log" });
    _ = command.captureStdErr(.{ .basename = "gradle-stderr.log" });
    if (b.graph.host.result.os.tag == .linux) {
        command.addArgs(&.{ "flock", "--exclusive" });
        command.addDirectoryArg(b.graph.path(.global_cache, "registry-snapshotter.lock"));
    }
    if (b.graph.host.result.os.tag == .windows) command.addArgs(&.{ "cmd", "/c" });
    command.addFileArg(b.path(if (b.graph.host.result.os.tag == .windows) "gradlew.bat" else "gradlew"));
    command.addFileInput(b.path("gradle/wrapper/gradle-wrapper.jar"));
    command.addFileInput(b.path("gradle/wrapper/gradle-wrapper.properties"));
    command.setCwd(b.path("."));
    command.addArgs(&.{ "--no-daemon", "--project-dir" });
    command.addDirectoryArg(files.getDirectory().path(b, directory));
    command.addArg("--project-cache-dir");
    _ = command.addOutputDirectoryArg("gradle-project-cache");
    command.addArgs(&.{ "registrySnapshot", b.fmt("-Pminecraft_version={s}", .{version}) });
    if (api) |selected| command.addArg(b.fmt("-Pregistry_api={s}", .{selected}));
    const output = command.addPrefixedOutputFileArg("-PsnapshotOutput=", "registries.bin");
    _ = command.addPrefixedOutputDirectoryArg("-PbuildRoot=", "gradle-build");
    command.addArg("lightingSnapshot");
    b.addNamedLazyPath("lighting", command.addPrefixedOutputFileArg("-PlightingOutput=", "lighting.bin"));
    b.addNamedLazyPath("fuels", command.addPrefixedOutputFileArg("-PfuelOutput=", "fuels.bin"));
    b.addNamedLazyPath("physics", command.addPrefixedOutputFileArg("-PphysicsOutput=", "physics.bin"));
    b.addNamedLazyPath("pack", command.addPrefixedOutputFileArg("-PpackOutput=", "pack.bin"));
    b.addNamedLazyPath("snapshot", output);
    b.step("snapshot", "Extract the selected Minecraft registries").dependOn(&command.step);
}

pub fn apiForVersion(b: *std.Build, version: []const u8) []const u8 {
    b.dependOnFileContents(b.path("versions.json"));
    const filename = b.root.joinString(b.allocator, "versions.json") catch @panic("OOM");
    const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, filename, b.allocator, .limited(64 * 1024)) catch @panic("cannot read registry API catalog");
    const versions = std.json.parseFromSliceLeaky([]const struct { release: []const u8, api: []const u8 }, b.allocator, bytes, .{}) catch @panic("invalid registry API catalog");
    for (versions) |entry| if (std.mem.eql(u8, entry.release, version)) return entry.api;
    return "current";
}
