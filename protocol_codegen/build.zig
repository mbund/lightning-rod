const std = @import("std");
const codegen = @import("codegen.zig");
const contracts = @import("contracts.zig");

pub const Codegen = codegen.Codegen;
pub const Json = codegen.Json;
pub const JavaVersion = @import("java_version.zig").JavaVersion;

pub fn build(b: *std.Build) void {
    inline for (.{ "protocol", "registry" }) |name| {
        const tool = b.addExecutable(.{
            .name = name ++ "-codegen",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/" ++ name ++ ".zig"),
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        });
        b.installArtifact(tool);
        if (comptime std.mem.eql(u8, name, "protocol")) contracts.add(b, tool);
    }
}
