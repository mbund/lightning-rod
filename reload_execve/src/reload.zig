const std = @import("std");
const builtin = @import("builtin");
const reload = @import("reload");

const assert = std.debug.assert;

const section_name = ".lightning_rod.resume";
pub const manifest = reload.handoff.manifest;

pub const Service = struct {
    request: reload.Request,
    arguments: ?Arguments,
    executable: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, process: std.process.Init, executable: ?[]const u8) !Service {
        return .{ .request = .{ .enabled = executable != null }, .arguments = if (executable != null) try Arguments.init(allocator, process) else null, .executable = executable, .allocator = allocator };
    }

    pub fn deinit(self: *Service) void {
        if (self.arguments) |*arguments| arguments.deinit(self.allocator);
    }

    pub fn prepare(self: *Service, io: std.Io) !Image {
        self.request.pending = false;
        self.request.sequence += 1;
        self.request.result = null;
        self.request.started_ns = std.Io.Clock.now(.awake, io).nanoseconds;
        return Image.open(io, self.executable orelse return error.ReloadUnavailable);
    }

    pub fn execute(self: *Service, image: Image, io: std.Io, snapshot: std.Io.File, descriptors: []const i32) !noreturn {
        return image.execute(&self.arguments.?, io, snapshot, descriptors);
    }
};

pub fn retainManifest(comptime Endpoint: type) void {
    if (comptime builtin.os.tag == .linux) {
        const Executable = struct {
            const bytes linksection(section_name) = manifest ++ Endpoint.resume_manifest;
            comptime {
                // A fixed symbol rejects conflicting endpoint manifests in one executable.
                @export(&bytes, .{
                    .name = "lightning_rod_resume_manifest",
                    .linkage = .strong,
                    .visibility = .hidden,
                });
            }
        };
        std.mem.doNotOptimizeAway(&Executable.bytes);
    }
}
pub const environment_key = "LIGHTNING_ROD_RESUME_FD";

pub const Configuration = struct { executable: ?[]const u8 = null };

pub const Arguments = struct {
    argv: [:null]?[*:0]const u8,
    environ: [:null]?[*:0]const u8,
    resume_index: usize,
    resume_environment: [128]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, process: std.process.Init) !Arguments {
        const arguments = try process.minimal.args.toSlice(allocator);
        defer allocator.free(arguments);
        const argv = try allocator.allocSentinel(?[*:0]const u8, arguments.len, null);
        var copied: usize = 0;
        errdefer {
            for (argv[0..copied]) |argument| allocator.free(std.mem.span(argument.?));
            allocator.free(argv);
        }
        for (arguments, argv) |argument, *destination| {
            destination.* = (try allocator.dupeSentinel(u8, argument, 0)).ptr;
            copied += 1;
        }
        const keys = process.environ_map.keys();
        const values = process.environ_map.values();
        const environ = try allocator.allocSentinel(?[*:0]const u8, keys.len + 1, null);
        @memset(environ, null);
        var count: usize = 0;
        errdefer {
            for (environ[0..count]) |entry| allocator.free(std.mem.span(entry.?));
            allocator.free(environ);
        }
        for (keys, values) |key, value| {
            if (std.mem.eql(u8, key, environment_key)) continue;
            environ[count] = (try std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{ key, value }, 0)).ptr;
            count += 1;
        }
        return .{ .argv = argv, .environ = environ, .resume_index = count };
    }

    pub fn deinit(self: *Arguments, allocator: std.mem.Allocator) void {
        for (self.argv) |argument| allocator.free(std.mem.span(argument.?));
        for (self.environ[0..self.resume_index]) |entry| allocator.free(std.mem.span(entry.?));
        allocator.free(self.argv);
        allocator.free(self.environ);
        self.* = undefined;
    }
};

pub const Image = struct {
    file: std.Io.File,
    protocols_offset: u64,
    protocols_bytes: u64,
    protocols: reload.Compatibility,

    /// Validate the exact open image, not a path that can change before execveat.
    pub fn open(io: std.Io, path: []const u8) !Image {
        if (builtin.os.tag != .linux) return error.UnsupportedPlatform;

        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);
        const stat = try file.stat(io);
        if (@backingInt(stat.permissions) & 0o111 == 0) return error.NotExecutable;

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

        var name_storage: [64 * 1024]u8 = undefined;
        if (names_len > name_storage.len) return error.InvalidExecutable;
        const name_table = name_storage[0..@intCast(names_len)];
        if (try file.readPositionalAll(io, name_table, names) != name_table.len) return error.InvalidExecutable;
        var protocols: reload.Compatibility = .{};
        var compatible = false;
        var protocols_offset: u64 = 0;
        var sections: [64][64]u8 = undefined;
        var cursor: usize = 0;
        while (cursor < count) {
            const batch = @min(sections.len, count - cursor);
            const bytes = std.mem.sliceAsBytes(sections[0..batch]);
            if (try file.readPositionalAll(io, bytes, offset + cursor * size) != bytes.len) return error.InvalidExecutable;
            for (sections[0..batch]) |entry| {
                const name = std.mem.readInt(u32, entry[0..4], .little);
                if (name >= name_table.len or !std.mem.startsWith(u8, name_table[name..], section_name ++ "\x00")) continue;
                const location = std.mem.readInt(u64, entry[24..32], .little);
                const length = std.mem.readInt(u64, entry[32..40], .little);
                if (location > stat.size or length > stat.size - location) return error.InvalidExecutable;
                var actual: [manifest.len]u8 = undefined;
                if (length <= actual.len or (length - actual.len) % 12 != 0 or length - actual.len > protocols.bytes.len or
                    try file.readPositionalAll(io, &actual, location) != actual.len or !std.mem.eql(u8, &actual, &manifest)) return error.IncompatibleResume;
                if (compatible) return error.InvalidExecutable;
                compatible = true;
                protocols_offset = location + manifest.len;
                protocols.length = @intCast(length - actual.len);
                const records = protocols.bytes[0..protocols.length];
                if (try file.readPositionalAll(io, records, protocols_offset) != records.len) return error.InvalidExecutable;
            }
            cursor += batch;
        }
        if (!compatible) return error.MissingResumeManifest;
        return .{ .file = file, .protocols_offset = protocols_offset, .protocols_bytes = protocols.length, .protocols = protocols };
    }

    pub fn supports(self: *const Image, protocol: i32, format: ?u64) bool {
        return self.protocols.supports(protocol, format);
    }

    pub fn compatibility(self: *const Image) reload.Compatibility {
        return self.protocols;
    }

    pub fn close(self: Image, io: std.Io) void {
        self.file.close(io);
    }

    pub fn execute(self: Image, arguments: *Arguments, io: std.Io, snapshot: std.Io.File, descriptors: []const i32) !noreturn {
        var inherited: usize = 0;
        defer for (descriptors[0..inherited]) |fd| cloexec(fd, true) catch unreachable;

        for (descriptors) |fd| {
            try cloexec(fd, false);
            inherited += 1;
        }

        try cloexec(snapshot.handle, false);
        defer cloexec(snapshot.handle, true) catch unreachable;
        // Only formatting and execveat remain after this timestamp.
        const executing_ns = std.Io.Clock.now(.awake, io).nanoseconds;
        arguments.environ[arguments.resume_index] = (std.fmt.bufPrintSentinel(&arguments.resume_environment, "{s}={d},{d}", .{ environment_key, snapshot.handle, executing_ns }, 0) catch unreachable).ptr;
        const result = std.os.linux.execveat(self.file.handle, "", arguments.argv.ptr, arguments.environ.ptr, .{ .EMPTY_PATH = true, .SYMLINK_NOFOLLOW = false });
        std.log.err("event=execve_failed errno={s}", .{@tagName(std.os.linux.errno(result))});
        return error.ExecFailed;
    }
};

pub fn create() !std.Io.File {
    const result = std.os.linux.memfd_create("lightning-rod-resume", std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING);
    if (std.os.linux.errno(result) != .SUCCESS) return error.HandoffUnavailable;
    return .{ .handle = @intCast(result), .flags = .{ .nonblocking = false } };
}

pub fn seal(file: std.Io.File) !void {
    const result = std.os.linux.fcntl(file.handle, std.os.linux.F.ADD_SEALS, std.os.linux.F.SEAL_SEAL | std.os.linux.F.SEAL_SHRINK | std.os.linux.F.SEAL_GROW | std.os.linux.F.SEAL_WRITE);
    if (std.os.linux.errno(result) != .SUCCESS) return error.SealFailed;
}

pub fn cloexec(fd: i32, enabled: bool) !void {
    assert(fd >= 0);
    if (std.os.linux.errno(std.os.linux.fcntl(fd, std.os.linux.F.SETFD, if (enabled) @as(u32, std.os.linux.FD_CLOEXEC) else 0)) != .SUCCESS) return error.DescriptorFlagsFailed;
}

pub const Incoming = struct { file: std.Io.File, executing_ns: i96 };

pub fn incoming(init: std.process.Init) !?Incoming {
    if (builtin.os.tag != .linux) return null;

    const value = init.environ_map.get(environment_key) orelse return null;
    var fields = std.mem.splitScalar(u8, value, ',');
    const fd = try std.fmt.parseInt(i32, fields.next().?, 10);
    const executing_ns = try std.fmt.parseInt(i96, fields.next() orelse return error.InvalidResume, 10);
    if (fd < 3 or executing_ns <= 0 or fields.next() != null) return error.InvalidResume;
    try cloexec(fd, true);
    const seals = std.os.linux.fcntl(fd, std.os.linux.F.GET_SEALS, 0);
    if (std.os.linux.errno(seals) != .SUCCESS or seals & std.os.linux.F.SEAL_WRITE == 0) return error.InvalidResume;
    return .{ .file = .{ .handle = fd, .flags = .{ .nonblocking = false } }, .executing_ns = executing_ns };
}
