const builtin = @import("builtin");
const std = @import("std");

pub const Error = error{
    UnsupportedPlatform,
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NameTooLong,
    AccessDenied,
    PermissionDenied,
    InvalidExecutable,
    FileSystem,
    FileNotFound,
    NotDirectory,
    FileBusy,
    Unexpected,
};

pub fn replaceFd(
    fd: std.posix.fd_t,
    argv: [*:null]const ?[*:0]const u8,
    environment: [*:null]const ?[*:0]const u8,
) Error!noreturn {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedPlatform;
    const linux = std.os.linux;
    const result = linux.execveat(fd, "", argv, environment, .{
        .SYMLINK_NOFOLLOW = false,
        .EMPTY_PATH = true,
    });
    switch (linux.errno(result)) {
        .SUCCESS => unreachable,
        .@"2BIG", .NOMEM => return error.SystemResources,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .INVAL, .NOEXEC, .LIBBAD => return error.InvalidExecutable,
        .IO, .LOOP, .ISDIR => return error.FileSystem,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDirectory,
        .TXTBSY => return error.FileBusy,
        else => return error.Unexpected,
    }
}
