const std = @import("std");
const schema = @import("schema.zig");
const Emitter = @import("emit.zig").Emitter;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const input_path = args.next() orelse return error.MissingInput;
    const output_path = args.next() orelse return error.MissingOutput;
    const version_path = args.next() orelse return error.MissingVersion;
    const override_number = args.next();
    if (args.next() != null) return error.TooManyArguments;
    const document = try read(init.io, allocator, input_path);
    const version = try read(init.io, allocator, version_path);
    const protocol_number: i32 = if (override_number) |number| try std.fmt.parseInt(i32, number, 10) else @intCast((try schema.get(version, "version")).integer);
    const graph = try schema.Graph.init(allocator, document);
    const file = try std.Io.Dir.createFile(.cwd(), init.io, output_path, .{});
    defer file.close(init.io);
    var buffer: [16 * 1024]u8 = undefined;
    var output = file.writer(init.io, &buffer);
    var emitter = Emitter{ .graph = &graph, .out = &output.interface, .allocator = allocator, .protocol_number = protocol_number };
    try emitter.run();
    const types = try schema.object(try schema.get(document, "types"));
    if (types.get("entityMetadataEntry")) |metadata| {
        const mappings = metadata.array.items[1].array.items[1].object.get("type").?.array.items[1].object.get("mappings").?.object;
        try output.interface.writeAll("pub const MetadataType = enum(i32) {\n");
        for (mappings.keys(), mappings.values()) |id, name|
            try output.interface.print("@\"{s}\" = {s},\n", .{ name.string, id });
        try output.interface.writeAll("};\n");
    }
    try output.interface.flush();
}

fn read(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !std.json.Value {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    return (try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always })).value;
}
