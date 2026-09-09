const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const url = args.next() orelse return error.MissingUrl;
    const output_path = args.next() orelse return error.MissingOutputPath;
    if (args.next() != null) return error.UnexpectedArgument;

    const cwd = std.Io.Dir.cwd();
    const output = try cwd.createFile(init.io, output_path, .{ .exclusive = true });
    errdefer cwd.deleteFile(init.io, output_path) catch {};
    defer output.close(init.io);

    var output_buffer: [16 * 1024]u8 = undefined;
    var writer = output.writer(init.io, &output_buffer);
    var client = std.http.Client{ .allocator = init.gpa, .io = init.io };
    defer client.deinit();
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer.interface,
    });
    if (response.status != .ok) return error.DownloadFailed;
    try writer.end();
}
