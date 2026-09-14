const std = @import("std");
const schema = @import("schema.zig");
const Emitter = @import("emit.zig").Emitter;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const input_path = args.next() orelse return error.MissingInput;
    const output_path = args.next() orelse return error.MissingOutput;
    const corrections_path = args.next();
    if (args.next() != null) return error.TooManyArguments;

    const document = try read(init.io, allocator, input_path);
    if (corrections_path) |path| {
        const corrections = try schema.object(try read(init.io, allocator, path));

        for (corrections.keys(), corrections.values()) |phase, directions_json| {
            const directions = try schema.object(directions_json);

            for (directions.keys(), directions.values()) |direction, replacements_json| {
                var types = try schema.object(try schema.get(try schema.get(try schema.get(document, phase), direction), "types"));
                const replacements = try schema.object(replacements_json);

                for (replacements.keys(), replacements.values()) |name, replacement| {
                    const target = types.getPtr(name) orelse return error.UnknownCorrection;
                    target.* = replacement;
                }
            }
        }
    }

    const graph = try schema.Graph.init(allocator, document);
    const file = try std.Io.Dir.createFile(.cwd(), init.io, output_path, .{});
    defer file.close(init.io);
    var buffer: [16 * 1024]u8 = undefined;
    var output = file.writer(init.io, &buffer);
    var emitter = Emitter{ .graph = &graph, .out = &output.interface, .allocator = allocator };
    try emitter.run();
    try output.interface.flush();
}

fn read(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !std.json.Value {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    return (try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always })).value;
}
