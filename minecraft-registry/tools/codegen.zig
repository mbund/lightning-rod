const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const input_path = args.next() orelse return error.MissingBlocksPath;
    const minecraft_version = args.next() orelse return error.MissingMinecraftVersion;
    const output_path = args.next() orelse return error.MissingOutputPath;
    if (args.next() != null) return error.UnexpectedArgument;

    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(init.io, input_path, allocator, .limited(64 * 1024 * 1024));
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    const blocks = parsed.value.array.items;
    if (blocks.len == 0 or blocks.len > std.math.maxInt(u16)) return error.InvalidBlockCount;

    var output = std.array_list.Managed(u8).init(allocator);
    try output.print(
        "// Generated canonical block identities. Do not edit.\n\npub const minecraft_version = \"{s}\";\n\npub const Block = enum(u16) {{\n",
        .{minecraft_version},
    );
    for (blocks, 0..) |entry, index| {
        const object = entry.object;
        const id = object.get("id").?.integer;
        if (id != index) return error.NonContiguousBlockIds;
        try output.print("    {s} = {d},\n", .{ object.get("name").?.string, index });
    }
    try output.appendSlice("};\n\npub const names = [_][]const u8{\n");
    for (blocks) |entry| try output.print("    \"{s}\",\n", .{entry.object.get("name").?.string});
    try output.appendSlice("};\n\npub const default_states = [_]u32{\n");
    for (blocks) |entry| try output.print("    {d},\n", .{entry.object.get("defaultState").?.integer});
    try output.appendSlice("};\n\npub const state_offsets = [_]u32{\n");
    for (blocks) |entry| try output.print("    {d},\n", .{entry.object.get("minStateId").?.integer});
    const final_state = blocks[blocks.len - 1].object.get("maxStateId").?.integer + 1;
    try output.print("    {d},\n}};\n\npub const state_names = [_][]const u8{{\n", .{final_state});
    for (blocks) |entry| {
        const block = entry.object;
        const minimum: usize = @intCast(block.get("minStateId").?.integer);
        const maximum: usize = @intCast(block.get("maxStateId").?.integer);
        for (0..maximum - minimum + 1) |offset| {
            try output.appendSlice("    \"");
            try writeBlockStateName(&output, block, offset);
            try output.appendSlice("\",\n");
        }
    }
    try output.appendSlice("};\n\npub const state_blocks = [_]Block{\n");
    for (blocks) |entry| {
        const block = entry.object;
        const minimum: usize = @intCast(block.get("minStateId").?.integer);
        const maximum: usize = @intCast(block.get("maxStateId").?.integer);
        for (minimum..maximum + 1) |_| try output.print("    .{s},\n", .{block.get("name").?.string});
    }
    try output.appendSlice("};\n");
    try cwd.writeFile(init.io, .{ .sub_path = output_path, .data = output.items });
}

fn writeBlockStateName(
    output: *std.array_list.Managed(u8),
    block: std.json.ObjectMap,
    offset: usize,
) !void {
    try output.print("minecraft:{s}", .{block.get("name").?.string});
    const properties = block.get("states").?.array.items;
    if (properties.len == 0) return;
    try output.append('[');
    for (properties, 0..) |property_value, property_index| {
        const property = property_value.object;
        var stride: usize = 1;
        for (properties[property_index + 1 ..]) |later|
            stride *= @intCast(later.object.get("num_values").?.integer);
        const value_count: usize = @intCast(property.get("num_values").?.integer);
        const value_index = (offset / stride) % value_count;
        const value = if (property.get("values")) |values|
            values.array.items[value_index].string
        else if (std.mem.eql(u8, property.get("type").?.string, "bool"))
            if (value_index == 0) "true" else "false"
        else
            return error.MissingBlockStateValues;
        try output.print("{s}{s}={s}", .{
            if (property_index == 0) "" else ",",
            property.get("name").?.string,
            value,
        });
    }
    try output.append(']');
}
