const std = @import("std");

const maximum_file_bytes = 4 * 1024 * 1024;
const maximum_pools = 512;

const PoolSource = struct {
    id: []const u8,
    fallback: []const u8,
    elements: []const ElementSource,
};

const ElementSource = struct {
    template: []const u8,
    processors: []const u8,
    weight: u16,
};

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
    var pools: std.ArrayListUnmanaged(PoolSource) = .empty;
    while (try walker.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".json")) continue;
        if (!std.mem.startsWith(u8, entry.path, "bastion/")) continue;
        if (pools.items.len == maximum_pools) return error.TooManyPools;
        try pools.append(allocator, try parsePool(init.io, allocator, directory, entry.path));
    }
    std.mem.sort(PoolSource, pools.items, {}, lessPool);
    try writeSource(init.io, allocator, output_path, pools.items);
}

fn parsePool(
    io: std.Io,
    allocator: std.mem.Allocator,
    directory: std.Io.Dir,
    path: []const u8,
) !PoolSource {
    const bytes = try directory.readFileAlloc(io, path, allocator, .limited(maximum_file_bytes));
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    const root = try object(parsed.value);
    const values = try array(try required(root, "elements"));
    const elements = try allocator.alloc(ElementSource, values.items.len);
    for (values.items, elements) |value, *result| {
        const entry = try object(value);
        const weight = try positiveU16(try required(entry, "weight"));
        const element = try object(try required(entry, "element"));
        const kind = try string(try required(element, "element_type"));
        if (!std.mem.eql(u8, kind, "minecraft:single_pool_element"))
            return error.UnsupportedPoolElement;
        result.* = .{
            .template = try namespaced(allocator, try string(try required(element, "location"))),
            .processors = try processorId(allocator, try required(element, "processors")),
            .weight = weight,
        };
    }
    const stem = path[0 .. path.len - ".json".len];
    return .{
        .id = try namespaced(allocator, stem),
        .fallback = try namespaced(allocator, try string(try required(root, "fallback"))),
        .elements = elements,
    };
}

fn writeSource(io: std.Io, allocator: std.mem.Allocator, path: []const u8, pools: []const PoolSource) !void {
    var source = std.array_list.Managed(u8).init(allocator);
    try source.appendSlice(
        \\pub const Element = struct { template: []const u8, processors: []const u8 };
        \\pub const Pool = struct { id: []const u8, fallback: []const u8, first: u16, count: u16 };
        \\pub const elements = [_]Element{
        \\
    );
    var element_count: usize = 0;
    for (pools) |pool| for (pool.elements) |element| for (0..element.weight) |_| {
        try source.print("    .{{ .template = \"{s}\", .processors = \"{s}\" }},\n", .{
            element.template,
            element.processors,
        });
        element_count += 1;
    };
    try source.appendSlice("};\npub const pools = [_]Pool{\n");
    var first: usize = 0;
    for (pools) |pool| {
        var count: usize = 0;
        for (pool.elements) |element| count += element.weight;
        try source.print("    .{{ .id = \"{s}\", .fallback = \"{s}\", .first = {}, .count = {} }},\n", .{
            pool.id,
            pool.fallback,
            first,
            count,
        });
        first += count;
    }
    std.debug.assert(first == element_count);
    try source.appendSlice("};\n");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = source.items });
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

fn positiveU16(value: std.json.Value) !u16 {
    const number = switch (value) {
        .integer => |result| result,
        else => return error.ExpectedJsonInteger,
    };
    if (number <= 0 or number > std.math.maxInt(u16)) return error.InvalidWeight;
    return @intCast(number);
}

fn namespaced(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, value, ':') != null) return allocator.dupe(u8, value);
    return std.fmt.allocPrint(allocator, "minecraft:{s}", .{value});
}

fn processorId(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |result| namespaced(allocator, result),
        .array => |result| if (result.items.len == 0)
            allocator.dupe(u8, "minecraft:empty")
        else
            error.UnsupportedInlineProcessors,
        .object => |result| blk: {
            const processors = try array(try required(result, "processors"));
            if (processors.items.len != 0) return error.UnsupportedInlineProcessors;
            break :blk allocator.dupe(u8, "minecraft:empty");
        },
        else => error.InvalidProcessors,
    };
}

fn lessPool(_: void, left: PoolSource, right: PoolSource) bool {
    return std.mem.order(u8, left.id, right.id) == .lt;
}
