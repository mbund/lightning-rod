const std = @import("std");

pub const Version = struct {
    package: []const u8,
    minecraft_version: []const u8,
    accepted_names: []const []const u8,
    protocol_number: i32,
};

pub const versions = [_]Version{
    .{ .package = "v1_21_5", .minecraft_version = "1.21.5", .accepted_names = &.{"1.21.5"}, .protocol_number = 770 },
    .{ .package = "v1_21_6", .minecraft_version = "1.21.6", .accepted_names = &.{"1.21.6"}, .protocol_number = 771 },
    .{ .package = "v1_21_8", .minecraft_version = "1.21.8", .accepted_names = &.{ "1.21.7", "1.21.8" }, .protocol_number = 772 },
    .{ .package = "v1_21_9", .minecraft_version = "1.21.9", .accepted_names = &.{ "1.21.9", "1.21.10" }, .protocol_number = 773 },
    .{ .package = "v1_21_11", .minecraft_version = "1.21.11", .accepted_names = &.{"1.21.11"}, .protocol_number = 774 },
    .{ .package = "v26_1", .minecraft_version = "26.1", .accepted_names = &.{ "26.1", "26.1.1", "26.1.2" }, .protocol_number = 775 },
    .{ .package = "v26_2", .minecraft_version = "26.2", .accepted_names = &.{"26.2"}, .protocol_number = 776 },
};

pub const latest: Version = latest: {
    var result = versions[0];
    for (versions) |version| {
        if (version.protocol_number > result.protocol_number) result = version;
    }
    break :latest result;
};

pub fn fromMinimumMinecraftVersion(minimum: []const u8) ?[]const Version {
    const index = releaseIndex(minimum) orelse return null;
    return versions[index..];
}

pub fn releaseIndex(name: []const u8) ?usize {
    for (versions, 0..) |version, index| {
        if (std.mem.eql(u8, version.minecraft_version, name)) return index;
        for (version.accepted_names) |accepted| if (std.mem.eql(u8, accepted, name)) return index;
    }
    return null;
}

comptime {
    for (versions, 0..) |version, index| {
        if (version.package.len == 0 or version.minecraft_version.len == 0 or version.accepted_names.len == 0)
            @compileError("invalid protocol selection");
        for (versions[index + 1 ..]) |other| {
            if (version.protocol_number == other.protocol_number) @compileError("duplicate protocol number");
            for (version.accepted_names) |name|
                for (other.accepted_names) |other_name|
                    if (std.mem.eql(u8, name, other_name)) @compileError("duplicate Minecraft release");
        }
    }
}
