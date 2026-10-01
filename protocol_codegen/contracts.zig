const std = @import("std");

pub fn add(b: *std.Build, generator: *std.Build.Step.Compile) void {
    const check = b.step("check", "Check generated restricted-writer contracts and encoding");
    const support = b.dependency("encoding", .{ .target = b.graph.host, .optimize = .Debug }).module("encoding");
    const files = b.addWriteFiles();
    const source = schema(b, generator, support, files, "source", 1, "i32", "u8", "number", false);
    const cases = .{
        .{ "extension", "i32", "u8", "number", "restricted", @as(?[]const u8, null) },
        .{ "payload", "varlong", "u8", "number", "restricted", changed },
        .{ "header", "i32", "i32", "number", "restricted", changed },
        .{ "removed", "i32", "u8", "removed", "restricted", "destination protocol has no case number" },
        .{ "full", "i32", "u8", "number", "full", changed },
        .{ "nested_changed", "varlong", "u8", "number", "nested_changed", "error: Payload changed between source protocol 1 and target protocol 2. Supply a compatible concrete writer." },
        .{ "nested_upgrade", "varlong", "u8", "number", "nested_upgrade", @as(?[]const u8, null) },
        .{ "nested_missing", "varlong", "u8", "number", "nested_missing", "no nested writer for Payload" },
        .{ "wrong_completion", "i32", "u8", "number", "wrong_completion", "error: expected type 'cursor.End(cursor.Destination(\"Payload\"[0..7]),.write)', found 'cursor.End(cursor.Destination(\"Maybe\"[0..5]),.write)'" },
        .{ "dispatch_payload", "varlong", "u8", "number", "dispatch_payload", "error: i32 changed between source protocol 1 and target protocol 2. Supply a compatible concrete writer." },
    };
    inline for (cases) |case| {
        const target = schema(b, generator, support, files, case[0], 2, case[1], case[2], case[3], true);
        const options = b.addOptions();
        options.addOption([]const u8, "mode", case[4]);
        const executable = b.addExecutable(.{
            .name = "contract-" ++ case[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/contracts.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
                .imports = &.{
                    .{ .name = "source", .module = source },
                    .{ .name = "target", .module = target },
                    .{ .name = "options", .module = options.createModule() },
                    .{ .name = "support", .module = support },
                },
            }),
        });
        if (@as(?[]const u8, case[5])) |message| {
            executable.expect_errors = .{ .contains = message };
            check.dependOn(&executable.step);
        } else check.dependOn(&b.addRunArtifact(executable).step);
    }
}

fn schema(b: *std.Build, generator: *std.Build.Step.Compile, support: *std.Build.Module, files: *std.Build.Step.WriteFile, name: []const u8, version: i32, number_type: []const u8, key_type: []const u8, number_name: []const u8, extended: bool) *std.Build.Module {
    const json = b.fmt(
        \\{{"types":{{"u8":"native","i32":"native","varint":"native","varlong":"native","bool":"native","void":"native",
        \\"Entry":["container",[{{"name":"key","type":"{s}"}},{{"name":"type","type":["mapper",{{"type":"varint","mappings":{{"{d}":"{s}","8":"other","9":"recursive"{s}}}}}]}},{{"name":"value","type":["switch",{{"compareTo":"type","fields":{{"{s}":"{s}","other":"{s}","recursive":["option","Entry"]{s}}}}}]}}]],
        \\"Payload":["container",[{{"name":"type","type":["mapper",{{"type":"varint","mappings":{{"{d}":"number"}}}}]}},{{"name":"value","type":["switch",{{"compareTo":"type","fields":{{"number":"{s}"}}}}]}}]],
        \\"Outer":["container",[{{"name":"entry","type":"Payload"}}]],
        \\"List":["array",{{"type":"Payload","countType":"varint"}}],"Maybe":["option","Payload"],
        \\"Extras":["container",[{{"name":"entries","type":"List"}},{{"name":"optional","type":"Maybe"}}]]}},
        \\"handshaking":{s},"status":{s},"login":{s},"configuration":{s},"play":{s}}}
    , .{
        key_type,
        @as(i32, if (extended) 19 else 7),
        number_name,
        if (extended) ",\"20\":\"added\"" else "",
        number_name,
        number_type,
        if (extended) "i32" else "bool",
        if (extended) ",\"added\":\"varlong\"" else "",
        @as(i32, if (extended) 19 else 7),
        number_type,
        empty_phase,
        empty_phase,
        empty_phase,
        empty_phase,
        empty_phase,
    });
    const command = b.addRunArtifact(generator);
    command.addFileArg(files.add(b.fmt("{s}.json", .{name}), json));
    const output = command.addOutputFileArg("schema.zig");
    command.addFileArg(files.add(b.fmt("{s}-version.json", .{name}), b.fmt("{{\"version\":{d}}}", .{version})));
    return b.createModule(.{ .root_source_file = output, .target = b.graph.host, .optimize = .Debug, .imports = &.{.{ .name = "protocol_support", .module = support }} });
}

const empty_phase = "{\"toServer\":{\"types\":{}},\"toClient\":{\"types\":{}}}";
const changed = "error: Entry changed between source protocol 1 and target protocol 2. Supply a compatible concrete writer.";
