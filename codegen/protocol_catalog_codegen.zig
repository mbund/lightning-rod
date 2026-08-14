const std = @import("std");

const Version = struct {
    minecraft_name: []const u8,
    accepted_names: []const []const u8,
    protocol_number: []const u8,
    schema: []const u8,
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const output_path = args.next() orelse return error.MissingOutputPath;
    const schema_count = try std.fmt.parseInt(usize, args.next() orelse return error.MissingSchemaCount, 10);
    const version_count = try std.fmt.parseInt(usize, args.next() orelse return error.MissingVersionCount, 10);
    const default_index = try std.fmt.parseInt(usize, args.next() orelse return error.MissingDefaultVersion, 10);
    const canonical_index = try std.fmt.parseInt(usize, args.next() orelse return error.MissingCanonicalVersion, 10);
    if (default_index >= version_count or canonical_index >= version_count) return error.InvalidSelectedVersion;

    const versions = try allocator.alloc(Version, version_count);
    for (versions) |*version| {
        version.minecraft_name = args.next() orelse return error.MissingMinecraftName;
        version.protocol_number = args.next() orelse return error.MissingProtocolNumber;
        version.schema = args.next() orelse return error.MissingSchemaIndex;
        const accepted_count = try std.fmt.parseInt(usize, args.next() orelse return error.MissingAcceptedNameCount, 10);
        const accepted_names = try allocator.alloc([]const u8, accepted_count);
        for (accepted_names) |*name| name.* = args.next() orelse return error.MissingAcceptedName;
        version.accepted_names = accepted_names;
    }
    if (args.next() != null) return error.TooManyArguments;
    try writeCatalog(init.io, output_path, schema_count, versions, default_index, canonical_index);
}

fn writeCatalog(
    io: std.Io,
    output_path: []const u8,
    schema_count: usize,
    versions: []const Version,
    default_index: usize,
    canonical_index: usize,
) !void {
    const file = try std.Io.Dir.createFile(.cwd(), io, output_path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const out = &writer.interface;
    try out.writeAll("// Generated from build/protocols.zig. Do not edit.\n\nconst std = @import(\"std\");\n");
    for (0..schema_count) |index| try out.print("const schema_{} = @import(\"protocol_schema_{}\");\n", .{ index, index });
    for (versions, 0..) |_, index| try out.print("const registry_{} = @import(\"protocol_registry_{}\");\n", .{ index, index });
    try out.writeAll("\npub const Version = enum(u8) {\n");
    for (versions, 0..) |_, index| try out.print("    version_{},\n", .{index});
    try out.writeAll("\n    pub fn protocolNumber(self: Version) i32 {\n        return switch (self) {\n");
    for (versions, 0..) |version, index| try out.print("            .version_{} => {s},\n", .{ index, version.protocol_number });
    try out.writeAll("        };\n    }\n\n    pub fn minecraftName(self: Version) []const u8 {\n        return switch (self) {\n");
    for (versions, 0..) |version, index| try out.print("            .version_{} => \"{s}\",\n", .{ index, version.minecraft_name });
    try out.writeAll("        };\n    }\n");
    try out.writeAll("};\n\n");
    for (versions, 0..) |version, index| try writeVersion(out, version, index);
    try out.writeAll("pub const entries = .{\n");
    for (versions, 0..) |_, index| try out.print("    version_{},\n", .{index});
    try out.writeAll("};\n\npub const Support = struct {\n    id: []const u8,\n    version: Version,\n    protocol_number: i32,\n};\n\npub const support = [_]Support{\n");
    for (versions, 0..) |_, index|
        try out.print("    .{{ .id = version_{}.id, .version = version_{}.version, .protocol_number = version_{}.protocol_number }},\n", .{ index, index, index });
    try out.print("}};\n\npub const default = Version.version_{};\n", .{default_index});
    try out.print("pub const canonical = Version.version_{};\n", .{canonical_index});
    try out.writeAll("\npub fn fromMinecraftName(name: []const u8) ?Version {\n");
    for (versions, 0..) |version, index| {
        for (version.accepted_names) |name|
            try out.print("    if (std.mem.eql(u8, name, \"{s}\")) return .version_{};\n", .{ name, index });
    }
    try out.writeAll("    return null;\n}\n");
    try writer.interface.flush();
}

fn writeVersion(out: *std.Io.Writer, version: Version, index: usize) !void {
    try out.print("pub const version_{} = struct {{\n", .{index});
    try out.print("    pub const id = \"minecraft:protocol/{s}\";\n", .{version.minecraft_name});
    try out.print("    pub const version = Version.version_{};\n", .{index});
    try out.print("    pub const protocol_number: i32 = {s};\n", .{version.protocol_number});
    try out.print("    pub const minecraft_name = \"{s}\";\n", .{version.minecraft_name});
    if (version.accepted_names.len == 0) return error.MissingAcceptedName;
    if (version.accepted_names.len == 1)
        try out.print("    pub const status_name = \"{s}\";\n", .{version.accepted_names[0]})
    else
        try out.print("    pub const status_name = \"{s} - {s}\";\n", .{ version.accepted_names[0], version.accepted_names[version.accepted_names.len - 1] });
    try out.print("    pub const Protocol = schema_{s};\n", .{version.schema});
    try out.print("    pub const Registry = registry_{};\n", .{index});
    try out.writeAll("};\n\n");
}
