const std = @import("std");
const builtin = @import("builtin");

const linux = std.os.linux;
const assert = std.debug.assert;

pub const section_name = ".lightning_rod.resume";
pub const manifest: [16]u8 = "LRRESUME".* ++ [_]u8{ 3, 0, 0, 0, 1, 0, 0, 0 };
pub const environment_key = "LIGHTNING_ROD_RESUME_FD";

pub const Configuration = struct { executable: ?[]const u8 = null };

pub const Image = struct {
    file: std.Io.File,

    /// Validate the exact open image, not a path that can change before execveat.
    pub fn open(io: std.Io, path: []const u8) !Image {
        if (builtin.os.tag != .linux) return error.UnsupportedPlatform;

        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);
        const stat = try file.stat(io);
        if (@intFromEnum(stat.permissions) & 0o111 == 0) return error.NotExecutable;

        var header: [64]u8 = undefined;
        if (try file.readPositionalAll(io, &header, 0) != header.len or !std.mem.eql(u8, header[0..4], "\x7fELF") or header[4] != 2 or header[5] != 1)
            return error.InvalidExecutable;

        const machine: u16 = switch (builtin.cpu.arch) {
            .x86_64 => 62,
            .aarch64 => 183,
            else => return error.UnsupportedPlatform,
        };
        if (std.mem.readInt(u16, header[18..20], .little) != machine) return error.InvalidExecutable;

        const offset = std.mem.readInt(u64, header[40..48], .little);
        const size = std.mem.readInt(u16, header[58..60], .little);
        const count = std.mem.readInt(u16, header[60..62], .little);
        const strings = std.mem.readInt(u16, header[62..64], .little);
        if (size != 64 or count == 0 or count > 4096 or strings >= count or offset > stat.size or @as(u64, count) * size > stat.size - offset)
            return error.InvalidExecutable;

        var section: [64]u8 = undefined;
        if (try file.readPositionalAll(io, &section, offset + @as(u64, strings) * size) != section.len) return error.InvalidExecutable;

        const names = std.mem.readInt(u64, section[24..32], .little);
        const names_len = std.mem.readInt(u64, section[32..40], .little);
        if (names > stat.size or names_len > stat.size - names) return error.InvalidExecutable;

        for (0..count) |index| {
            if (try file.readPositionalAll(io, &section, offset + index * size) != section.len) return error.InvalidExecutable;

            const name = std.mem.readInt(u32, section[0..4], .little);
            if (name >= names_len or section_name.len + 1 > names_len - name) continue;

            var bytes: [section_name.len + 1]u8 = undefined;
            if (try file.readPositionalAll(io, &bytes, names + name) != bytes.len) return error.InvalidExecutable;
            if (!std.mem.eql(u8, &bytes, section_name ++ "\x00")) continue;

            const location = std.mem.readInt(u64, section[24..32], .little);
            const length = std.mem.readInt(u64, section[32..40], .little);
            var actual: [manifest.len]u8 = undefined;
            if (length != actual.len or location > stat.size or length > stat.size - location or try file.readPositionalAll(io, &actual, location) != actual.len or !std.mem.eql(u8, &actual, &manifest))
                return error.IncompatibleResume;
            return .{ .file = file };
        }

        return error.MissingResumeManifest;
    }

    pub fn close(self: Image, io: std.Io) void {
        self.file.close(io);
    }

    pub fn execute(self: Image, init: std.process.Init, snapshot: std.Io.File, descriptors: []const i32) !noreturn {
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        const allocator = arena.allocator();
        const arguments = try init.minimal.args.toSlice(allocator);
        const argv = try allocator.allocSentinel(?[*:0]const u8, arguments.len, null);

        for (arguments, argv) |arg, *out| out.* = (try allocator.dupeZ(u8, arg)).ptr;
        const keys = init.environ_map.keys();
        const values = init.environ_map.values();
        const environ = try allocator.allocSentinel(?[*:0]const u8, keys.len + 1, null);
        var count: usize = 0;

        for (keys, values) |key, value| {
            if (std.mem.eql(u8, key, environment_key)) continue;
            environ[count] = (try std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{ key, value }, 0)).ptr;
            count += 1;
        }

        environ[count] = (try std.fmt.allocPrintSentinel(allocator, "{s}={d}", .{ environment_key, snapshot.handle }, 0)).ptr;
        count += 1;
        environ[count] = null;
        var inherited: usize = 0;
        defer for (descriptors[0..inherited]) |fd| cloexec(fd, true) catch unreachable;

        for (descriptors) |fd| {
            try cloexec(fd, false);
            inherited += 1;
        }

        try cloexec(snapshot.handle, false);
        defer cloexec(snapshot.handle, true) catch unreachable;
        const result = linux.execveat(self.file.handle, "", argv.ptr, environ.ptr, .{ .EMPTY_PATH = true, .SYMLINK_NOFOLLOW = false });
        std.log.err("event=execve_failed errno={s}", .{@tagName(linux.errno(result))});
        return error.ExecFailed;
    }
};

pub fn create() !std.Io.File {
    const result = linux.memfd_create("lightning-rod-resume", linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING);
    if (linux.errno(result) != .SUCCESS) return error.HandoffUnavailable;
    return .{ .handle = @intCast(result), .flags = .{ .nonblocking = false } };
}

pub fn seal(file: std.Io.File) !void {
    const result = linux.fcntl(file.handle, linux.F.ADD_SEALS, linux.F.SEAL_SEAL | linux.F.SEAL_SHRINK | linux.F.SEAL_GROW | linux.F.SEAL_WRITE);
    if (linux.errno(result) != .SUCCESS) return error.SealFailed;
}

pub fn cloexec(fd: i32, enabled: bool) !void {
    assert(fd >= 0);
    if (linux.errno(linux.fcntl(fd, linux.F.SETFD, if (enabled) @as(u32, linux.FD_CLOEXEC) else 0)) != .SUCCESS) return error.DescriptorFlagsFailed;
}

pub fn incoming(init: std.process.Init) !?std.Io.File {
    if (builtin.os.tag != .linux) return null;

    const value = init.environ_map.get(environment_key) orelse return null;
    const fd = try std.fmt.parseInt(i32, value, 10);
    if (fd < 3) return error.InvalidResume;
    try cloexec(fd, true);
    const seals = linux.fcntl(fd, linux.F.GET_SEALS, 0);
    if (linux.errno(seals) != .SUCCESS or seals & linux.F.SEAL_WRITE == 0) return error.InvalidResume;
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}
