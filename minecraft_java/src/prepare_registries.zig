const std = @import("std");
const wire = @import("wire");
const registry_packets = @import("registry_packets.zig");

const Packets = registry_packets.RegistryPackets(wire);

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 5) return error.InvalidArguments;
    const cwd = std.Io.Dir.cwd();
    const snapshot = try cwd.readFileAlloc(init.io, args[1], allocator, .limited(16 * 1024 * 1024));
    var prepared = try Packets.read(allocator, 0, snapshot, args[2]);
    defer prepared.deinit(allocator);

    var source: std.Io.Writer.Allocating = .init(allocator);
    defer source.deinit();
    const output = &source.writer;
    try output.writeAll(
        "const java = @import(\"minecraft_java\");\n" ++
            "const bytes = @embedFile(\"registry_packet_bytes\");\n\n" ++
            "pub const value: java.EmbeddedRegistries = .{\n    .packets = &.{\n",
    );
    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    for (prepared.packets.values) |packet| {
        const start = bytes.written().len;
        try bytes.writer.writeAll(packet.bytes);
        try output.print("        .{{ .bytes = bytes[{}..{}] }},\n", .{ start, bytes.written().len });
    }
    try output.writeAll("    },\n    .registries = &.{\n");
    for (prepared.registries) |registry| {
        try output.print("        .{{ .name = \"{f}\", .entries = &.{{\n", .{std.zig.fmtString(registry.name)});
        for (registry.entries) |entry|
            try output.print("            \"{f}\",\n", .{std.zig.fmtString(entry)});
        try output.writeAll("        } },\n");
    }
    try output.writeAll("    },\n};\n");
    try cwd.writeFile(init.io, .{ .sub_path = args[3], .data = source.written() });
    try cwd.writeFile(init.io, .{ .sub_path = args[4], .data = bytes.written() });
}
