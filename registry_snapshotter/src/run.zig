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
    var complete = result == .exited and result.exited == 0;
    for (args[3..]) |arg| {
        inline for (.{ "snapshot", "lighting", "fuel", "physics", "pack" }) |name| {
            const prefix = "-P" ++ name ++ "Output=";
            if (std.mem.startsWith(u8, arg, prefix)) cwd.access(init.io, arg[prefix.len..], .{}) catch {
                complete = false;
            };
        }
    }
    if (complete) return;
    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var reader = log.reader(init.io, &read_buffer);
    var writer = std.Io.File.stderr().writerStreaming(init.io, &write_buffer);
    _ = try reader.interface.streamRemaining(&writer.interface);
    try writer.interface.flush();
    switch (result) {
        .exited => |code| std.process.exit(if (code == 0) 1 else code),
        else => return error.RegistrySnapshotFailed,
    }
}
