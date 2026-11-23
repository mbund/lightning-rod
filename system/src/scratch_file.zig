//! A file for state that lasts only while the process runs: it has no name, so it starts
//! empty every time and nothing of it is left after. Reads and writes bypass the page cache
//! where the filesystem allows, so they cost what the disk costs; then every transfer must be
//! whole, aligned blocks of `block_bytes`, from memory aligned the same.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const block_bytes = 4096;

pub const ScratchFile = struct {
    file: std.Io.File,
    /// Whether transfers bypass the page cache.
    direct: bool,

    /// One in `directory`; `name` is used only where the filesystem cannot make a file
    /// without one, and is removed at once.
    pub fn open(io: std.Io, directory: std.Io.Dir, name: [:0]const u8) !ScratchFile {
        if (builtin.os.tag == .linux) {
            for ([_]bool{ true, false }) |direct| {
                const flags: linux.O = .{ .ACCMODE = .RDWR, .TMPFILE = true, .DIRECTORY = true, .DIRECT = direct, .CLOEXEC = true };
                if (opened(linux.openat(directory.handle, ".", flags, 0o600))) |handle| return .{ .file = .{ .handle = handle, .flags = .{ .nonblocking = false } }, .direct = direct };
            }
            // No unnamed files here: a named one, removed while open.
            for ([_]bool{ true, false }) |direct| {
                const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true, .DIRECT = direct, .CLOEXEC = true };
                if (opened(linux.openat(directory.handle, name, flags, 0o600))) |handle| {
                    const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
                    directory.deleteFile(io, name) catch |err| {
                        file.close(io);
                        return err;
                    };
                    return .{ .file = file, .direct = direct };
                }
            }
            return error.ScratchFileUnavailable;
        }
        const file = try directory.createFile(io, name, .{ .read = true, .truncate = true });
        errdefer file.close(io);
        try directory.deleteFile(io, name);
        return .{ .file = file, .direct = false };
    }

    fn opened(result: usize) ?linux.fd_t {
        if (linux.errno(result) != .SUCCESS) return null;
        return @intCast(result);
    }

    pub fn close(self: ScratchFile, io: std.Io) void {
        self.file.close(io);
    }

    /// Gives back what lies past `bytes`.
    pub fn truncate(self: ScratchFile, io: std.Io, bytes: u64) !void {
        try self.file.setLength(io, bytes);
    }
};

test "a scratch file starts empty, keeps what is written and leaves no name" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    const scratch = try ScratchFile.open(io, temporary.dir, "scratch");
    defer scratch.close(io);
    const written = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(block_bytes), block_bytes * 2);
    defer std.testing.allocator.free(written);
    for (written, 0..) |*byte, at| byte.* = @truncate(at *% 7);
    try scratch.file.writePositionalAll(io, written, block_bytes);
    const read = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(block_bytes), block_bytes);
    defer std.testing.allocator.free(read);
    try std.testing.expectEqual(@as(usize, block_bytes), try scratch.file.readPositionalAll(io, read, block_bytes * 2));
    try std.testing.expectEqualSlices(u8, written[block_bytes..], read);
    try scratch.truncate(io, block_bytes);
    try std.testing.expectEqual(@as(usize, 0), try scratch.file.readPositionalAll(io, read, block_bytes));
    var names = temporary.dir.iterate();
    try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try names.next(io));
}
