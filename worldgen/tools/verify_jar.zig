const std = @import("std");

const maximum_jar_bytes = 64 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const jar_path = args.next() orelse return error.MissingJarPath;
    const expected_text = args.next() orelse return error.MissingDigest;
    const stamp_path = args.next() orelse return error.MissingStampPath;
    if (args.next() != null) return error.UnexpectedArgument;
    if (expected_text.len != 40) return error.InvalidDigest;

    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        jar_path,
        init.gpa,
        .limited(maximum_jar_bytes),
    );
    defer init.gpa.free(bytes);
    var actual: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(bytes, &actual, .{});
    var expected: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, expected_text) catch
        return error.InvalidDigest;
    if (!std.mem.eql(u8, &actual, &expected)) return error.DigestMismatch;
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = stamp_path,
        .data = expected_text,
    });
}
