const std = @import("std");
const nbt = @import("nbt");

const maximum_templates = 4_096;
const maximum_template_bytes = 16 * 1024 * 1024;
const maximum_total_bytes = 64 * 1024 * 1024;
const maximum_template_nodes = 262_144;
const maximum_template_depth = 256;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const input_path = args.next() orelse return error.MissingInputPath;
    const source_path = args.next() orelse return error.MissingSourcePath;
    const binary_path = args.next() orelse return error.MissingBinaryPath;
    if (args.next() != null) return error.UnexpectedArgument;

    var directory = try std.Io.Dir.cwd().openDir(init.io, input_path, .{ .iterate = true });
    defer directory.close(init.io);
    const paths = try collectTemplatePaths(allocator, init.io, &directory);

    var source = std.array_list.Managed(u8).init(allocator);
    var binary = std.array_list.Managed(u8).init(allocator);
    var jigsaws: std.ArrayListUnmanaged(JigsawSource) = .empty;
    const nodes = try allocator.alloc(nbt.Node, maximum_template_nodes);
    const stack = try allocator.alloc(nbt.Frame, maximum_template_depth);
    try appendSourceHeader(&source);
    for (paths) |path| {
        const compressed = try directory.readFileAlloc(init.io, path, allocator, .limited(maximum_template_bytes));
        var input: std.Io.Reader = .fixed(compressed);
        var decompressed: std.Io.Writer.Allocating = .init(allocator);
        var gzip: std.compress.flate.Decompress = .init(&input, .gzip, &.{});
        const length = try gzip.reader.streamRemaining(&decompressed.writer);
        if (length > maximum_template_bytes) return error.TemplateDataTooLarge;
        const bytes = decompressed.written();
        const info = try templateInfo(allocator, bytes, nodes, stack);
        if (binary.items.len + length > maximum_total_bytes) return error.TemplateDataTooLarge;
        const offset: u32 = @intCast(binary.items.len);
        try binary.appendSlice(bytes);
        const id = path[0 .. path.len - ".nbt".len];
        const jigsaw_first: u32 = @intCast(jigsaws.items.len);
        try jigsaws.appendSlice(allocator, info.jigsaws);
        try source.print("    .{{ .id = \"minecraft:{s}\", .offset = {}, .length = {}, .size = .{{ {}, {}, {} }}, .jigsaw_first = {}, .jigsaw_count = {} }},\n", .{
            id,
            offset,
            length,
            info.size[0],
            info.size[1],
            info.size[2],
            jigsaw_first,
            info.jigsaws.len,
        });
    }
    try source.appendSlice("};\npub const jigsaws = [_]Jigsaw{\n");
    for (jigsaws.items) |jigsaw| try source.print(
        "    .{{ .position = .{{ {}, {}, {} }}, .orientation = \"{s}\", .name = \"{s}\", .pool = \"{s}\", .target = \"{s}\", .joint = \"{s}\", .placement_priority = {}, .selection_priority = {} }},\n",
        .{
            jigsaw.position[0],        jigsaw.position[1], jigsaw.position[2],
            jigsaw.orientation,        jigsaw.name,        jigsaw.pool,
            jigsaw.target,             jigsaw.joint,       jigsaw.placement_priority,
            jigsaw.selection_priority,
        },
    );
    try source.appendSlice("};\n");
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(init.io, .{ .sub_path = source_path, .data = source.items });
    try cwd.writeFile(init.io, .{ .sub_path = binary_path, .data = binary.items });
}

fn collectTemplatePaths(allocator: std.mem.Allocator, io: std.Io, directory: *std.Io.Dir) ![]const []const u8 {
    var walker = try directory.walk(allocator);
    defer walker.deinit();
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".nbt")) continue;
        if (paths.items.len == maximum_templates) return error.TooManyTemplates;
        try paths.append(allocator, try allocator.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, lessThan);
    return paths.items;
}

fn appendSourceHeader(source: *std.array_list.Managed(u8)) !void {
    try source.appendSlice(
        \\pub const Entry = struct { id: []const u8, offset: u32, length: u32, size: [3]i32, jigsaw_first: u32, jigsaw_count: u16 };
        \\pub const Jigsaw = struct { position: [3]i32, orientation: []const u8, name: []const u8, pool: []const u8, target: []const u8, joint: []const u8, placement_priority: i32, selection_priority: i32 };
        \\pub const bytes = @embedFile("structure_templates_1.21.8.bin");
        \\pub const entries = [_]Entry{
        \\
    );
}

const TemplateInfo = struct { size: [3]i32, jigsaws: []const JigsawSource };
const JigsawSource = struct {
    position: [3]i32,
    orientation: []const u8,
    name: []const u8,
    pool: []const u8,
    target: []const u8,
    joint: []const u8,
    placement_priority: i32,
    selection_priority: i32,
};

fn templateInfo(allocator: std.mem.Allocator, bytes: []const u8, nodes: []nbt.Node, stack: []nbt.Frame) !TemplateInfo {
    const document = try nbt.scan_named(bytes, nodes, stack);
    const size_node = document.childNamed("size") orelse return error.InvalidStructureTemplate;
    const info = try size_node.listInfo();
    if (info.child_tag != .int or info.len != 3) return error.InvalidStructureTemplate;
    var result: [3]i32 = undefined;
    var values = size_node.childIterator(document.nodes);
    for (&result) |*value| value.* = try (values.next() orelse
        return error.InvalidStructureTemplate).int();
    if (values.next() != null) return error.InvalidStructureTemplate;
    return .{ .size = result, .jigsaws = try templateJigsaws(allocator, document) };
}

fn templateJigsaws(allocator: std.mem.Allocator, document: nbt.Document) ![]const JigsawSource {
    const palette = document.childNamed("palette") orelse blk: {
        const palettes = document.childNamed("palettes") orelse return error.InvalidStructureTemplate;
        var iterator = palettes.childIterator(document.nodes);
        break :blk iterator.next() orelse return error.InvalidStructureTemplate;
    };
    const palette_info = try palette.listInfo();
    if (palette_info.child_tag != .compound) return error.InvalidStructureTemplate;
    const is_jigsaw = try allocator.alloc(bool, palette_info.len);
    const orientations = try allocator.alloc([]const u8, palette_info.len);
    var palette_entries = palette.childIterator(document.nodes);
    for (is_jigsaw, orientations) |*matches, *orientation| {
        const entry = palette_entries.next() orelse return error.InvalidStructureTemplate;
        const name = entry.childNamed(document.nodes, "Name") orelse return error.InvalidStructureTemplate;
        matches.* = std.mem.eql(u8, try name.string(), "minecraft:jigsaw");
        orientation.* = "north_up";
        if (entry.childNamed(document.nodes, "Properties")) |properties| {
            if (properties.childNamed(document.nodes, "orientation")) |value| {
                orientation.* = try value.string();
            }
        }
    }
    if (palette_entries.next() != null) return error.InvalidStructureTemplate;

    const blocks = document.childNamed("blocks") orelse return error.InvalidStructureTemplate;
    const block_info = try blocks.listInfo();
    if (block_info.child_tag != .compound) return error.InvalidStructureTemplate;
    var result: std.ArrayListUnmanaged(JigsawSource) = .empty;
    var entries = blocks.childIterator(document.nodes);
    while (entries.next()) |entry| {
        const state_node = entry.childNamed(document.nodes, "state") orelse return error.InvalidStructureTemplate;
        const state = try state_node.int();
        if (state < 0 or state >= is_jigsaw.len) return error.InvalidStructureTemplate;
        if (!is_jigsaw[@intCast(state)]) continue;
        const data = entry.childNamed(document.nodes, "nbt") orelse return error.InvalidStructureTemplate;
        try result.append(allocator, .{
            .position = try intVector(entry, document.nodes, "pos"),
            .orientation = orientations[@intCast(state)],
            .name = try optionalString(data, document.nodes, "name", "minecraft:empty"),
            .pool = try optionalString(data, document.nodes, "pool", "minecraft:empty"),
            .target = try optionalString(data, document.nodes, "target", "minecraft:empty"),
            .joint = try optionalString(data, document.nodes, "joint", ""),
            .placement_priority = try optionalInt(data, document.nodes, "placement_priority"),
            .selection_priority = try optionalInt(data, document.nodes, "selection_priority"),
        });
    }
    return result.items;
}

fn intVector(parent: nbt.Node, nodes: []const nbt.Node, name: []const u8) ![3]i32 {
    const node = parent.childNamed(nodes, name) orelse return error.InvalidStructureTemplate;
    const info = try node.listInfo();
    if (info.child_tag != .int or info.len != 3) return error.InvalidStructureTemplate;
    var result: [3]i32 = undefined;
    var values = node.childIterator(nodes);
    for (&result) |*value| {
        const child = values.next() orelse return error.InvalidStructureTemplate;
        value.* = try child.int();
    }
    return result;
}

fn optionalString(parent: nbt.Node, nodes: []const nbt.Node, name: []const u8, default: []const u8) ![]const u8 {
    const node = parent.childNamed(nodes, name) orelse return default;
    return node.string();
}

fn optionalInt(parent: nbt.Node, nodes: []const nbt.Node, name: []const u8) !i32 {
    const node = parent.childNamed(nodes, name) orelse return 0;
    return node.int();
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}
