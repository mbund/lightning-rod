const std = @import("std");

pub fn build(b: *std.Build) void {
    const version = b.option([]const u8, "minecraft-version", "Minecraft release to extract") orelse @panic("missing -Dminecraft-version");
    const api = b.option([]const u8, "api", "Registry extractor API variant");
    const command = if (b.graph.host.result.os.tag == .windows)
        b.addSystemCommand(&.{ "cmd", "/c", "extract.bat", version, api orelse "" })
    else
        b.addSystemCommand(&.{ "./extract.sh", version, api orelse "" });
    command.setCwd(b.path("."));
    const output = command.addOutputFileArg("registries.bin");
    command.addPrefixedDirectoryArg("-PsourceDir=", b.path("src"));
    command.addPrefixedFileArg("-PextractScript=", b.path(if (b.graph.host.result.os.tag == .windows) "extract.bat" else "extract.sh"));
    command.addPrefixedFileArg("-PbuildScript=", b.path("build.gradle"));
    command.addPrefixedFileArg("-PsettingsFile=", b.path("settings.gradle"));
    command.addPrefixedFileArg("-PgradleProperties=", b.path("gradle.properties"));
    command.addPrefixedFileArg("-PversionsFile=", b.path("versions.json"));
    b.addNamedLazyPath("snapshot", output);
    b.step("snapshot", "Extract the selected Minecraft registries").dependOn(&command.step);
}
