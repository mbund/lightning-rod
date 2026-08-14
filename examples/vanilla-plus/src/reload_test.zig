const std = @import("std");
const support = @import("reload_test_support");

test "Vanilla+ reload completes with disk-backed plugin storage" {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const cwd_directory = try cwd.openDir(io, ".", .{});
    defer cwd_directory.close(io);
    var module_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const module_path_len = try cwd_directory.realPathFile(
        io,
        support.tick_module_default_path,
        &module_path_buffer,
    );
    var cwd_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_path_len = try cwd_directory.realPath(io, &cwd_path_buffer);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var temporary_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const temporary_path_len = try temporary.dir.realPath(
        io,
        &temporary_path_buffer,
    );
    try std.Io.Threaded.chdir(temporary_path_buffer[0..temporary_path_len]);
    defer std.Io.Threaded.chdir(cwd_path_buffer[0..cwd_path_len]) catch
        @panic("failed to restore reload test working directory");

    var manager = try support.TickModuleManager.init(
        io,
        module_path_buffer[0..module_path_len],
        128 * 1024 * 1024 * 1024,
        .disk,
    );
    defer manager.deinit();

    try manager.loadInitial(0);
    for (0..8) |_| try support.exerciseReloadableTick(
        &manager,
        std.testing.allocator,
    );

    try manager.prepareReload(&.{772});
    try manager.save();
    try manager.transitionPreparedReload(0, 0);
    try support.exerciseReloadableTick(&manager, std.testing.allocator);
}
