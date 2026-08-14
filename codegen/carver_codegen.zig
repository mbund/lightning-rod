const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const directory = args.next() orelse return error.MissingConfiguredCarverDirectory;
    const output_path = args.next() orelse return error.MissingOutputPath;
    if (args.next() != null) return error.UnexpectedArgument;

    const cwd = std.Io.Dir.cwd();
    const cave = try readConfig(init.io, cwd, allocator, directory, "cave.json");
    const underground = try readConfig(
        init.io,
        cwd,
        allocator,
        directory,
        "cave_extra_underground.json",
    );
    const canyon = try readConfig(init.io, cwd, allocator, directory, "canyon.json");
    var output = std.array_list.Managed(u8).init(allocator);
    try output.appendSlice(
        \\pub const FloatRange = struct { minimum: f32, maximum: f32 };
        \\pub const Cave = struct {
        \\    probability: f32,
        \\    minimum_y: i32,
        \\    maximum_y: i32,
        \\    lava_above_bottom: i32,
        \\    horizontal_radius: FloatRange,
        \\    vertical_radius: FloatRange,
        \\    floor_level: FloatRange,
        \\    y_scale: FloatRange,
        \\};
        \\pub const Canyon = struct {
        \\    probability: f32,
        \\    minimum_y: i32,
        \\    maximum_y: i32,
        \\    lava_above_bottom: i32,
        \\    vertical_rotation: FloatRange,
        \\    y_scale: f32,
        \\    thickness_minimum: f32,
        \\    thickness_maximum: f32,
        \\    thickness_plateau: f32,
        \\    distance_factor: FloatRange,
        \\    horizontal_radius_factor: FloatRange,
        \\    vertical_radius_default_factor: f32,
        \\    vertical_radius_center_factor: f32,
        \\    width_smoothness: u8,
        \\};
        \\
    );
    try writeCave(&output, "cave", cave);
    try writeCave(&output, "cave_extra_underground", underground);
    try writeCanyon(&output, canyon);
    try cwd.writeFile(init.io, .{ .sub_path = output_path, .data = output.items });
}

fn readConfig(
    io: std.Io,
    cwd: std.Io.Dir,
    allocator: std.mem.Allocator,
    directory: []const u8,
    name: []const u8,
) !std.json.ObjectMap {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, name });
    const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(256 * 1024));
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    return (parsed.value.object.get("config") orelse return error.MissingCarverConfig).object;
}

fn writeCave(
    output: *std.array_list.Managed(u8),
    name: []const u8,
    config: std.json.ObjectMap,
) !void {
    const y = object(config, "y");
    const horizontal = object(config, "horizontal_radius_multiplier");
    const vertical = object(config, "vertical_radius_multiplier");
    const floor = object(config, "floor_level");
    const y_scale = object(config, "yScale");
    try output.print(
        \\pub const {s}: Cave = .{{
        \\    .probability = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .minimum_y = {d},
        \\    .maximum_y = {d},
        \\    .lava_above_bottom = {d},
        \\    .horizontal_radius = .{{ .minimum = @bitCast(@as(u32, 0x{x:0>8})), .maximum = @bitCast(@as(u32, 0x{x:0>8})) }},
        \\    .vertical_radius = .{{ .minimum = @bitCast(@as(u32, 0x{x:0>8})), .maximum = @bitCast(@as(u32, 0x{x:0>8})) }},
        \\    .floor_level = .{{ .minimum = @bitCast(@as(u32, 0x{x:0>8})), .maximum = @bitCast(@as(u32, 0x{x:0>8})) }},
        \\    .y_scale = .{{ .minimum = @bitCast(@as(u32, 0x{x:0>8})), .maximum = @bitCast(@as(u32, 0x{x:0>8})) }},
        \\}};
        \\
    , .{
        name,
        bits(try number(config, "probability")),
        try yOffset(object(y, "min_inclusive")),
        try yOffset(object(y, "max_inclusive")),
        try integer(object(config, "lava_level"), "above_bottom"),
        bits(try number(horizontal, "min_inclusive")),
        bits(try number(horizontal, "max_exclusive")),
        bits(try number(vertical, "min_inclusive")),
        bits(try number(vertical, "max_exclusive")),
        bits(try number(floor, "min_inclusive")),
        bits(try number(floor, "max_exclusive")),
        bits(try number(y_scale, "min_inclusive")),
        bits(try number(y_scale, "max_exclusive")),
    });
}

fn writeCanyon(
    output: *std.array_list.Managed(u8),
    config: std.json.ObjectMap,
) !void {
    const y = object(config, "y");
    const rotation = object(config, "vertical_rotation");
    const shape = object(config, "shape");
    const thickness = object(shape, "thickness");
    const distance = object(shape, "distance_factor");
    const horizontal = object(shape, "horizontal_radius_factor");
    try output.print(
        \\pub const canyon: Canyon = .{{
        \\    .probability = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .minimum_y = {d},
        \\    .maximum_y = {d},
        \\    .lava_above_bottom = {d},
        \\    .vertical_rotation = .{{ .minimum = @bitCast(@as(u32, 0x{x:0>8})), .maximum = @bitCast(@as(u32, 0x{x:0>8})) }},
        \\    .y_scale = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .thickness_minimum = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .thickness_maximum = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .thickness_plateau = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .distance_factor = .{{ .minimum = @bitCast(@as(u32, 0x{x:0>8})), .maximum = @bitCast(@as(u32, 0x{x:0>8})) }},
        \\    .horizontal_radius_factor = .{{ .minimum = @bitCast(@as(u32, 0x{x:0>8})), .maximum = @bitCast(@as(u32, 0x{x:0>8})) }},
        \\    .vertical_radius_default_factor = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .vertical_radius_center_factor = @bitCast(@as(u32, 0x{x:0>8})),
        \\    .width_smoothness = {d},
        \\}};
        \\
    , .{
        bits(try number(config, "probability")),
        try yOffset(object(y, "min_inclusive")),
        try yOffset(object(y, "max_inclusive")),
        try integer(object(config, "lava_level"), "above_bottom"),
        bits(try number(rotation, "min_inclusive")),
        bits(try number(rotation, "max_exclusive")),
        bits(try number(config, "yScale")),
        bits(try number(thickness, "min")),
        bits(try number(thickness, "max")),
        bits(try number(thickness, "plateau")),
        bits(try number(distance, "min_inclusive")),
        bits(try number(distance, "max_exclusive")),
        bits(try number(horizontal, "min_inclusive")),
        bits(try number(horizontal, "max_exclusive")),
        bits(try number(shape, "vertical_radius_default_factor")),
        bits(try number(shape, "vertical_radius_center_factor")),
        try integer(shape, "width_smoothness"),
    });
}

fn object(parent: std.json.ObjectMap, key: []const u8) std.json.ObjectMap {
    return parent.get(key).?.object;
}

fn number(parent: std.json.ObjectMap, key: []const u8) !f32 {
    return switch (parent.get(key) orelse return error.MissingCarverValue) {
        .float => |value| @floatCast(value),
        .integer => |value| @floatFromInt(value),
        else => error.InvalidCarverNumber,
    };
}

fn integer(parent: std.json.ObjectMap, key: []const u8) !i32 {
    return switch (parent.get(key) orelse return error.MissingCarverValue) {
        .integer => |value| @intCast(value),
        else => error.InvalidCarverInteger,
    };
}

fn yOffset(value: std.json.ObjectMap) !i32 {
    if (value.get("absolute")) |absolute| return switch (absolute) {
        .integer => |number_value| @intCast(number_value),
        else => error.InvalidCarverHeight,
    };
    if (value.get("above_bottom")) |offset| return switch (offset) {
        .integer => |number_value| -64 + @as(i32, @intCast(number_value)),
        else => error.InvalidCarverHeight,
    };
    return error.UnsupportedCarverHeight;
}

fn bits(value: f32) u32 {
    return @bitCast(value);
}
