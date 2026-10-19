const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    std.debug.assert(args.len > 3);
    const cwd = std.Io.Dir.cwd();
    // Bound concurrent registry JVMs independently of the compiler's job budget.
    const lock = try cwd.createFile(init.io, args[2], .{ .truncate = false, .lock = .exclusive });
    defer lock.close(init.io);
    const log = try cwd.createFile(init.io, args[1], .{ .read = true });
    defer log.close(init.io);
    var child = try std.process.spawn(init.io, .{ .argv = args[3..], .stdout = .{ .file = log }, .stderr = .{ .file = log } });
    const result = try child.wait(init.io);
    if (result == .exited and result.exited == 0) return;
    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var reader = log.reader(init.io, &read_buffer);
    var writer = std.Io.File.stderr().writerStreaming(init.io, &write_buffer);
    _ = try reader.interface.streamRemaining(&writer.interface);
    try writer.interface.flush();
    switch (result) {
        .exited => |code| std.process.exit(code),
        else => return error.RegistrySnapshotFailed,
    }
}
