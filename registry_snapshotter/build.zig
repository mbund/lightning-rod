const std = @import("std");

pub fn build(b: *std.Build) void {
    const version = b.option([]const u8, "minecraft-version", "Minecraft release to extract") orelse @panic("missing -Dminecraft-version");
    const api = b.option([]const u8, "api", "Registry extractor API variant");
    const files = b.addWriteFiles();
    const directory = b.fmt("{s}-{s}", .{ version, api orelse "default" });
    for ([_][]const u8{ "build.gradle", "settings.gradle", "gradle.properties", "versions.json" }) |name|
        _ = files.addCopyFile(b.path(name), b.fmt("{s}/{s}", .{ directory, name }));
    _ = files.addCopyDirectory(b.path("src"), b.fmt("{s}/src", .{directory}), .{});

    const launcher = b.addExecutable(.{
        .name = "registry-snapshotter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/run.zig"),
            .target = b.graph.host,
        }),
    });
    const command = b.addRunArtifact(launcher);
    _ = command.addOutputFileArg("gradle.log");
    const cache = b.graph.global_cache_root.handle.realPathFileAlloc(b.graph.io, ".", b.allocator) catch |err|
        std.debug.panic("Cannot resolve the compiler cache: {s}", .{@errorName(err)});
    command.addArg(b.pathJoin(&.{ cache, "registry-snapshotter.lock" }));
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
    b.addNamedLazyPath("snapshot", output);
    b.step("snapshot", "Extract the selected Minecraft registries").dependOn(&command.step);
}
