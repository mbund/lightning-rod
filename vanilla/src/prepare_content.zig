const std = @import("std");
const game_data = @import("game_data");
const datapacks = @import("datapacks");
const recipes = @import("recipes.zig");
const decoder = @import("datapack_decoder.zig");
const content = @import("content_types.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    const destination = arguments.next() orelse return error.MissingOutput;
    const definitions = try prepare(allocator);
    const format = (try datapacks.Archive.init(game_data.vanilla_pack)).version;
    var output: std.Io.Writer.Allocating = .init(allocator);
    try output.writer.print("pub const datapack_format = .{{ .major = {d}, .minor = {d} }};\n", .{ format.major, format.minor });
    try output.writer.writeAll("pub fn definitions(comptime T: type) T { return ");
    try writeValue(&output.writer, definitions);
    try output.writer.writeAll("; }\n");
    const file = try std.Io.Dir.cwd().createFile(init.io, destination, .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, output.written());
}

pub fn prepare(allocator: std.mem.Allocator) !content.Definitions {
    var builder = datapacks.Builder.init(allocator, allocator, .{});
    try builder.archive("minecraft:vanilla", game_data.vanilla_pack);
    const resources = try builder.finish();
    var definitions = try decoder.decode(allocator, allocator, &resources, .{ .baseline = true });
    var fuels: std.ArrayList(recipes.FuelDefinition) = .empty;
    var remainders: std.ArrayList(recipes.RemainderDefinition) = .empty;
    var rules = game_data.fuels.rules();
    while (try rules.next()) |rule| try fuels.append(allocator, .{
        .input = if (rule.kind == .item) .{ .item = rule.name } else .{ .tag = rule.name },
        .ticks = if (rule.kind == .remove) 0 else rule.ticks,
    });
    for (game_data.registry.item_names, 0..) |name, index| {
        if (game_data.fuels.remainder(@intCast(index))) |item| try remainders.append(allocator, .{ .input = .{ .item = name }, .item = game_data.registry.item_names[item] });
    }
    try fuels.append(allocator, .{ .input = .{ .item = "minecraft:bucket" }, .ticks = 0, .slot_limit = 1 });
    definitions.fuels = fuels.items;
    definitions.remainders = remainders.items;
    definitions.fuel_conversions = &.{.{ .input = "minecraft:wet_sponge", .fuel = "minecraft:bucket", .result = "minecraft:water_bucket" }};
    return definitions;
}

pub fn writeValue(writer: *std.Io.Writer, value: anytype) anyerror!void {
    switch (@typeInfo(@TypeOf(value))) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => {
                if (pointer.child == u8) {
                    try writer.print("\"{f}\"", .{std.zig.fmtString(value)});
                } else {
                    try writer.writeAll("&.{");
                    for (value) |element| {
                        try writeValue(writer, element);
                        try writer.writeAll(",\n");
                    }
                    try writer.writeByte('}');
                }
            },
            .one => {
                if (@typeInfo(pointer.child) == .@"opaque" or @typeInfo(pointer.child) == .@"fn") return error.UnexpectedVanillaHandler;
                try writer.writeByte('&');
                try writeValue(writer, value.*);
            },
            else => return error.InvalidDefinitionPointer,
        },
        .@"struct" => |info| {
            try writer.writeAll(".{");
            inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
                const omitted = if (comptime attrs.default_value_ptr != null) blk: {
                    const value_field = @field(value, name);
                    const default = attrs.defaultValue(Field).?;
                    const equal = if (comptime @typeInfo(Field) == .pointer and @typeInfo(Field).pointer.size == .slice)
                        value_field.len == 0 and default.len == 0
                    else
                        std.meta.eql(value_field, default);
                    break :blk equal;
                } else false;
                if (!omitted) {
                    try writer.print(".@\"{s}\"=", .{name});
                    try writeValue(writer, @field(value, name));
                    try writer.writeAll(",\n");
                }
            }
            try writer.writeByte('}');
        },
        .@"union" => switch (value) {
            inline else => |payload, tag| {
                try writer.print(".{{.@\"{s}\"=", .{@tagName(tag)});
                try writeValue(writer, payload);
                try writer.writeByte('}');
            },
        },
        .@"enum" => try writer.print(".@\"{s}\"", .{@tagName(value)}),
        .optional => if (value) |present| try writeValue(writer, present) else try writer.writeAll("null"),
        .array => {
            try writer.writeAll(".{");
            for (value) |element| {
                try writeValue(writer, element);
                try writer.writeAll(",\n");
            }
            try writer.writeByte('}');
        },
        .int => try writer.print("{d}", .{value}),
        .float => try writer.print("{e}", .{value}),
        .bool => try writer.writeAll(if (value) "true" else "false"),
        .void => try writer.writeAll("{}"),
        else => return error.UnexpectedDefinitionType,
    }
}
