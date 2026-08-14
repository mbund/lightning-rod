const std = @import("std");

pub const Schema = struct {
    minecraft_data_version: []const u8,
};

pub const Version = struct {
    minecraft_version: []const u8,
    accepted_names: []const []const u8,
    protocol_number: i32,
    schema: usize,
};

pub const schemas = [_]Schema{
    .{ .minecraft_data_version = "1.21.8" },
};

pub const versions = [_]Version{
    .{
        .minecraft_version = "1.21.6",
        .accepted_names = &.{"1.21.6"},
        .protocol_number = 771,
        .schema = 0,
    },
    .{
        .minecraft_version = "1.21.8",
        .accepted_names = &.{ "1.21.7", "1.21.8" },
        .protocol_number = 772,
        .schema = 0,
    },
};

pub const canonical = 1;
pub const default = 1;

comptime {
    if (versions.len == 0) @compileError("at least one protocol version is required");
    if (schemas.len == 0) @compileError("at least one protocol schema is required");
    for (schemas) |schema| {
        if (schema.minecraft_data_version.len == 0)
            @compileError("protocol schema Minecraft data version must not be empty");
    }
    if (canonical >= versions.len) @compileError("canonical protocol index is invalid");
    if (default >= versions.len) @compileError("default protocol index is invalid");
    for (versions, 0..) |version, index| {
        if (version.minecraft_version.len == 0)
            @compileError("protocol Minecraft version must not be empty");
        if (version.accepted_names.len == 0)
            @compileError("protocol version must accept at least one client name");
        for (version.accepted_names, 0..) |name, name_index| {
            if (name.len == 0) @compileError("accepted Minecraft version name must not be empty");
            for (version.accepted_names[name_index + 1 ..]) |other_name| {
                if (std.mem.eql(u8, name, other_name))
                    @compileError("accepted Minecraft version names must be unique");
            }
        }
        if (version.schema >= schemas.len) @compileError("protocol schema index is invalid");
        for (versions[index + 1 ..]) |other| {
            if (version.protocol_number == other.protocol_number)
                @compileError("protocol numbers must be unique");
            for (version.accepted_names) |name| {
                for (other.accepted_names) |other_name| {
                    if (std.mem.eql(u8, name, other_name))
                        @compileError("accepted Minecraft version names must be unique");
                }
            }
        }
    }
}
