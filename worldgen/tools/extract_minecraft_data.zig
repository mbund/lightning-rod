const std = @import("std");

const maximum_entries = 32_768;

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const jar_path = args.next() orelse return error.MissingJarPath;
    const output_path = args.next() orelse return error.MissingOutputPath;
    if (args.next() != null) return error.UnexpectedArgument;

    const cwd = std.Io.Dir.cwd();
    const jar = try cwd.openFile(init.io, jar_path, .{});
    defer jar.close(init.io);
    var reader_buffer: [64 * 1024]u8 = undefined;
    var reader = jar.reader(init.io, &reader_buffer);
    var destination = try cwd.createDirPathOpen(init.io, output_path, .{});
    defer destination.close(init.io);

    var iterator = try std.zip.Iterator.init(&reader);
    var filename: [std.fs.max_path_bytes]u8 = undefined;
    var entry_count: usize = 0;
    while (try iterator.next()) |entry| {
        if (entry_count == maximum_entries) return error.TooManyZipEntries;
        entry_count += 1;
        if (entry.filename_len > filename.len) return error.ZipFilenameTooLong;
        try reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try reader.interface.readSliceAll(filename[0..entry.filename_len]);
        const path = filename[0..entry.filename_len];
        if (!wanted(path)) continue;
        try entry.extract(&reader, .{}, &filename, destination);
    }
}

fn wanted(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "data/minecraft/worldgen/") or
        std.mem.startsWith(u8, path, "data/minecraft/structure/");
}
