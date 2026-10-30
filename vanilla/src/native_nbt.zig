const std = @import("std");
const custom_data = @import("custom_data.zig");

pub fn encode(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    try output.writer.writeByte(tag(@TypeOf(value)));
    try payload(&output.writer, value);
    return output.toOwnedSlice();
}

fn tag(comptime T: type) u8 {
    return switch (@typeInfo(T)) {
        .bool => 1,
        .int => |info| if (info.bits <= 32) 3 else 4,
        .float => 6,
        .@"enum" => 8,
        .pointer => |pointer| if (pointer.size == .slice and pointer.child != u8) 9 else 8,
        .@"struct", .@"union" => 10,
        .optional => |info| tag(info.child),
        else => @compileError("unsupported native NBT type"),
    };
}

fn field(writer: *std.Io.Writer, name: []const u8, value: anytype) !void {
    if (@typeInfo(@TypeOf(value)) == .optional) {
        if (value) |present| try field(writer, name, present);
        return;
    }
    if (@typeInfo(@TypeOf(value)) == .@"union") {
        if (value == .constant) {
            try field(writer, name, value.constant);
            return;
        }
    }
    try writer.writeByte(tag(@TypeOf(value)));
    try custom_data.writeString(writer, name);
    try payload(writer, value);
}

fn payload(writer: *std.Io.Writer, value: anytype) anyerror!void {
    switch (@typeInfo(@TypeOf(value))) {
        .bool => try writer.writeByte(@intFromBool(value)),
        .int => |info| if (info.bits <= 32) try writer.writeInt(i32, @intCast(value), .big) else try writer.writeInt(i64, @intCast(value), .big),
        .float => try writer.writeInt(u64, @bitCast(@as(f64, value)), .big),
        .@"enum" => try custom_data.writeString(writer, @tagName(value)),
        .pointer => |pointer| {
            if (comptime pointer.size == .slice and pointer.child != u8) {
                if (value.len > std.math.maxInt(i32)) return error.NbtListTooLarge;
                try writer.writeByte(tag(pointer.child));
                try writer.writeInt(i32, @intCast(value.len), .big);
                for (value) |entry| try payload(writer, entry);
            } else try custom_data.writeString(writer, value);
        },
        .@"struct" => |info| {
            inline for (info.fields) |member| try field(writer, member.name, @field(value, member.name));
            try writer.writeByte(0);
        },
        .@"union" => {
            switch (value) {
                .constant => unreachable,
                .uniform => |range| {
                    try field(writer, "type", @as([]const u8, "minecraft:uniform"));
                    try field(writer, "min_inclusive", range.min_inclusive);
                    try field(writer, "max_inclusive", range.max_inclusive);
                    try writer.writeByte(0);
                },
            }
        },
        else => unreachable,
    }
}
