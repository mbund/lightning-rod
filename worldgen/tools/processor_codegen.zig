const std = @import("std");

const maximum_file_bytes = 4 * 1024 * 1024;
const maximum_lists = 512;

const Input = union(enum) { always, random_block: struct { block: []const u8, probability: f32 } };
const Position = union(enum) { always, axis_linear: struct { axis: u8, minimum_chance: f32, maximum_chance: f32, minimum_distance: i32, maximum_distance: i32 } };
const Rule = struct {
    input: Input,
    position: Position,
    output: []const u8,
};
const List = struct { id: []const u8, rules: []const Rule };

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const input_path = args.next() orelse return error.MissingInputPath;
    const output_path = args.next() orelse return error.MissingOutputPath;
    if (args.next() != null) return error.UnexpectedArgument;

    var directory = try std.Io.Dir.cwd().openDir(init.io, input_path, .{ .iterate = true });
    defer directory.close(init.io);
    var walker = try directory.walk(allocator);
    defer walker.deinit();
    var lists: std.ArrayListUnmanaged(List) = .empty;
    while (try walker.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".json")) continue;
        if (lists.items.len == maximum_lists) return error.TooManyProcessorLists;
        if (try parseList(init.io, allocator, directory, entry.path)) |list|
            try lists.append(allocator, list);
    }
    std.mem.sort(List, lists.items, {}, lessList);
    try writeSource(init.io, allocator, output_path, lists.items);
}

fn parseList(io: std.Io, allocator: std.mem.Allocator, directory: std.Io.Dir, path: []const u8) !?List {
    const bytes = try directory.readFileAlloc(io, path, allocator, .limited(maximum_file_bytes));
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    const root = try object(parsed.value);
    const processors = try array(try required(root, "processors"));
    var rules: std.ArrayListUnmanaged(Rule) = .empty;
    for (processors.items) |processor_value| {
        const processor = try object(processor_value);
        const kind = try string(try required(processor, "processor_type"));
        if (!std.mem.eql(u8, kind, "minecraft:rule")) return null;
        const values = try array(try required(processor, "rules"));
        for (values.items) |value| try rules.append(allocator, (try parseRule(allocator, value)) orelse return null);
    }
    return .{
        .id = try namespaced(allocator, path[0 .. path.len - ".json".len]),
        .rules = rules.items,
    };
}

fn parseRule(allocator: std.mem.Allocator, value: std.json.Value) !?Rule {
    const rule = try object(value);
    const location = try object(try required(rule, "location_predicate"));
    if (!std.mem.eql(u8, try string(try required(location, "predicate_type")), "minecraft:always_true")) return null;
    return .{
        .input = (try parseInput(allocator, try required(rule, "input_predicate"))) orelse return null,
        .position = if (rule.get("position_predicate")) |position|
            (try parsePosition(position)) orelse return null
        else
            .always,
        .output = try canonicalState(allocator, try required(rule, "output_state")),
    };
}

fn parseInput(allocator: std.mem.Allocator, value: std.json.Value) !?Input {
    const predicate = try object(value);
    const kind = try string(try required(predicate, "predicate_type"));
    if (std.mem.eql(u8, kind, "minecraft:always_true")) return .always;
    if (!std.mem.eql(u8, kind, "minecraft:random_block_match")) return null;
    return .{ .random_block = .{
        .block = try namespaced(allocator, try string(try required(predicate, "block"))),
        .probability = try float(try required(predicate, "probability")),
    } };
}

fn parsePosition(value: std.json.Value) !?Position {
    const predicate = try object(value);
    const kind = try string(try required(predicate, "predicate_type"));
    if (std.mem.eql(u8, kind, "minecraft:always_true")) return .always;
    if (!std.mem.eql(u8, kind, "minecraft:axis_aligned_linear_pos")) return null;
    const axis_text = try string(try required(predicate, "axis"));
    if (axis_text.len != 1 or std.mem.indexOfScalar(u8, "xyz", axis_text[0]) == null) return error.InvalidAxis;
    return .{ .axis_linear = .{
        .axis = axis_text[0],
        .minimum_chance = try float(try required(predicate, "min_chance")),
        .maximum_chance = try float(try required(predicate, "max_chance")),
        .minimum_distance = try integer(try required(predicate, "min_dist")),
        .maximum_distance = try integer(try required(predicate, "max_dist")),
    } };
}

fn canonicalState(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    const state = try object(value);
    const name = try namespaced(allocator, try string(try required(state, "Name")));
    const properties_value = state.get("Properties") orelse return name;
    const properties = try object(properties_value);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var iterator = properties.iterator();
    while (iterator.next()) |entry| try names.append(allocator, entry.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, lessString);
    var result = std.array_list.Managed(u8).init(allocator);
    try result.appendSlice(name);
    try result.append('[');
    for (names.items, 0..) |property, index| {
        if (index != 0) try result.append(',');
        try result.print("{s}={s}", .{ property, try string(properties.get(property).?) });
    }
    try result.append(']');
    return result.items;
}

fn writeSource(io: std.Io, allocator: std.mem.Allocator, path: []const u8, lists: []const List) !void {
    var source = std.array_list.Managed(u8).init(allocator);
    try source.appendSlice(
        \\pub const Input = union(enum) { always, random_block: struct { block: []const u8, probability: f32 } };
        \\pub const Position = union(enum) { always, axis_linear: struct { axis: u8, minimum_chance: f32, maximum_chance: f32, minimum_distance: i32, maximum_distance: i32 } };
        \\pub const Rule = struct { input: Input, position: Position, output: []const u8 };
        \\pub const List = struct { id: []const u8, first: u16, count: u16 };
        \\pub const rules = [_]Rule{
        \\
    );
    for (lists) |list| for (list.rules) |rule| try writeRule(&source, rule);
    try source.appendSlice("};\npub const lists = [_]List{\n");
    var first: usize = 0;
    for (lists) |list| {
        try source.print("    .{{ .id = \"{s}\", .first = {}, .count = {} }},\n", .{ list.id, first, list.rules.len });
        first += list.rules.len;
    }
    try source.appendSlice("};\n");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = source.items });
}

fn writeRule(source: *std.array_list.Managed(u8), rule: Rule) !void {
    try source.appendSlice("    .{ .input = ");
    switch (rule.input) {
        .always => try source.appendSlice(".always"),
        .random_block => |input| try source.print(".{{ .random_block = .{{ .block = \"{s}\", .probability = {} }} }}", .{ input.block, input.probability }),
    }
    try source.appendSlice(", .position = ");
    switch (rule.position) {
        .always => try source.appendSlice(".always"),
        .axis_linear => |position| try source.print(".{{ .axis_linear = .{{ .axis = '{c}', .minimum_chance = {}, .maximum_chance = {}, .minimum_distance = {}, .maximum_distance = {} }} }}", .{
            position.axis, position.minimum_chance, position.maximum_chance, position.minimum_distance, position.maximum_distance,
        }),
    }
    try source.print(", .output = \"{s}\" }},\n", .{rule.output});
}

fn required(map: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return map.get(name) orelse error.MissingJsonField;
}
fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |result| result,
        else => error.ExpectedJsonObject,
    };
}
fn array(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |result| result,
        else => error.ExpectedJsonArray,
    };
}
fn string(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |result| result,
        else => error.ExpectedJsonString,
    };
}
fn integer(value: std.json.Value) !i32 {
    return switch (value) {
        .integer => |result| @intCast(result),
        else => error.ExpectedJsonInteger,
    };
}
fn float(value: std.json.Value) !f32 {
    return switch (value) {
        .float => |result| @floatCast(result),
        .integer => |result| @floatFromInt(result),
        else => error.ExpectedJsonNumber,
    };
}
fn namespaced(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    return if (std.mem.indexOfScalar(u8, value, ':') != null) allocator.dupe(u8, value) else std.fmt.allocPrint(allocator, "minecraft:{s}", .{value});
}
fn lessString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}
fn lessList(_: void, left: List, right: List) bool {
    return lessString({}, left.id, right.id);
}
