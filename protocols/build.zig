const std = @import("std");
pub const catalog = @import("catalog.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const minimum = b.option([]const u8, "from", "Minimum supported Minecraft release") orelse "1.21.6";
    const names = b.option([]const u8, "releases", "Comma-separated supported Minecraft releases") orelse "";
    const selected = b.allocator.alloc(catalog.Version, catalog.versions.len) catch @panic("out of memory");
    var count: usize = 0;

    if (names.len == 0) {
        const versions = catalog.fromMinimumMinecraftVersion(minimum) orelse
            std.debug.panic("unknown protocol minimum '{s}'", .{minimum});
        @memcpy(selected[0..versions.len], versions);
        count = versions.len;
    } else {
        var releases = std.mem.splitScalar(u8, names, ',');
        while (releases.next()) |name| {
            const index = catalog.releaseIndex(name) orelse
                std.debug.panic("unknown protocol release '{s}'", .{name});
            const version = catalog.versions[index];
            var duplicate = false;
            for (selected[0..count]) |previous|
                duplicate = duplicate or previous.protocol_number == version.protocol_number;
            if (duplicate) continue;
            selected[count] = version;
            count += 1;
        }
    }
    if (count == 0) @panic("select at least one protocol");

    const java = b.dependency("minecraft_java", .{ .target = target, .optimize = optimize });
    const gameplay = b.dependency("game_data", .{ .target = target, .optimize = optimize });
    const sessions = b.dependency("sessions", .{ .target = target, .optimize = optimize });
    const support = b.dependency("encoding", .{ .target = target, .optimize = optimize }).module("encoding");
    const nbt = b.dependency("nbt", .{ .target = target, .optimize = optimize }).module("nbt");
    var source: std.Io.Writer.Allocating = .init(b.allocator);
    defer source.deinit();
    const out = &source.writer;
    out.writeAll("const std = @import(\"std\");\n") catch @panic("out of memory");
    for (selected[0..count], 0..) |_, index|
        out.print("const version_{} = @import(\"version_{}\");\n", .{ index, index }) catch @panic("out of memory");
    for (selected[0..count], 0..) |version, index| {
        out.print("comptime {{ if (version_{}.protocol_number != {} or !std.mem.eql(u8, version_{}.minecraft_name, \"{s}\")) @compileError(\"protocol catalog mismatch\"); }}\n", .{ index, version.protocol_number, index, version.minecraft_version }) catch @panic("out of memory");
        out.print("comptime {{ if (version_{}.releases.len != {}) @compileError(\"protocol release mismatch\"); }}\n", .{ index, version.accepted_names.len }) catch @panic("out of memory");
        for (version.accepted_names, 0..) |name, release_index|
            out.print("comptime {{ if (!std.mem.eql(u8, version_{}.releases[{}], \"{s}\")) @compileError(\"protocol release mismatch\"); }}\n", .{ index, release_index, name }) catch @panic("out of memory");
    }
    out.writeAll("pub const entries = .{\n") catch @panic("out of memory");
    for (0..count) |index|
        out.print("    version_{},\n", .{index}) catch @panic("out of memory");
    out.writeAll("};\n") catch @panic("out of memory");

    const versions = b.createModule(.{
        .root_source_file = b.addWriteFiles().add("selected_protocols.zig", source.written()),
        .target = target,
        .optimize = optimize,
    });
    for (selected[0..count], 0..) |version, index|
        versions.addImport(b.fmt("version_{}", .{index}), b.dependency(version.package, .{ .target = target, .optimize = optimize }).module("protocol"));

    const module = b.addModule("protocols", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "minecraft_java", .module = java.module("minecraft_java") },
            .{ .name = "sessions", .module = sessions.module("sessions") },
            .{ .name = "wire", .module = gameplay.module("schema") },
            .{ .name = "catalog", .module = versions },
            .{ .name = "registry", .module = gameplay.module("registry") },
            .{ .name = "support", .module = support },
            .{ .name = "nbt", .module = nbt },
        },
    });
    b.getInstallStep().dependOn(&b.addLibrary(.{ .name = "protocols", .root_module = module }).step);
}
