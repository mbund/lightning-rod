const builtin = @import("builtin");
const std = @import("std");

pub fn initialize() void {
    @disableInstrumentation();
    comptime std.debug.assert(!builtin.link_libc);
    if (builtin.os.tag != .linux) @compileError("the deterministic fuzz runner requires Linux");
    const Filter = extern struct { code: u16, jt: u8 = 0, jf: u8 = 0, k: u32 };
    const Program = extern struct { len: u16, filter: [*]const Filter };
    const linux = std.os.linux;
    var filters: [10]Filter = undefined;
    filters[0] = .{ .code = linux.BPF.LD | linux.BPF.W | linux.BPF.ABS, .k = 0 };
    var count: usize = 1;
    inline for (.{ "clone", "clone3", "fork", "vfork" }) |name| {
        if (@hasField(linux.SYS, name)) {
            filters[count] = .{ .code = linux.BPF.JMP | linux.BPF.JEQ | linux.BPF.K, .jf = 1, .k = @intFromEnum(@field(linux.SYS, name)) };
            filters[count + 1] = .{ .code = linux.BPF.RET | linux.BPF.K, .k = linux.SECCOMP.RET.TRAP };
            count += 2;
        }
    }
    filters[count] = .{ .code = linux.BPF.RET | linux.BPF.K, .k = linux.SECCOMP.RET.ALLOW };
    const program: Program = .{ .len = @intCast(count + 1), .filter = &filters };
    if (linux.errno(linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0)) != .SUCCESS or
        linux.errno(linux.seccomp(linux.SECCOMP.SET_MODE_FILTER, 0, &program)) != .SUCCESS) @panic("cannot enforce single-threaded fuzzing");
}

pub const Environment = struct {
    threaded: std.Io.Threaded,
    vtable: std.Io.VTable,
    prng: std.Random.DefaultPrng,
    time: i96 = 0,
    path: []const u8,
    lock: std.Io.File,

    pub fn init(comptime name: []const u8, seed: u64) !Environment {
        @disableInstrumentation();
        var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
        var vtable = threaded.io().vtable.*;
        vtable.random = random;
        vtable.randomSecure = randomSecure;
        vtable.now = now;
        vtable.clockResolution = clockResolution;
        vtable.sleep = sleep;
        const path = ".zig-cache/fuzz-work/" ++ name;
        const native = threaded.io();
        try std.Io.Dir.cwd().createDirPath(native, ".zig-cache/fuzz-work");
        const lock = try std.Io.Dir.cwd().createFile(native, path ++ ".lock", .{ .truncate = false, .lock = .exclusive });
        errdefer lock.close(native);
        try std.Io.Dir.cwd().deleteTree(native, path);
        try std.Io.Dir.cwd().createDirPath(native, path);
        return .{ .threaded = threaded, .vtable = vtable, .prng = .init(seed), .path = path ++ "/world", .lock = lock };
    }

    pub fn deinit(self: *Environment) void {
        @disableInstrumentation();
        std.Io.Dir.cwd().deleteTree(self.io(), std.fs.path.dirname(self.path).?) catch @panic("cannot clean fuzz workspace");
        self.lock.close(self.io());
        self.threaded.deinit();
    }

    pub fn io(self: *Environment) std.Io {
        @disableInstrumentation();
        return .{ .userdata = &self.threaded, .vtable = &self.vtable };
    }

    fn owner(raw: ?*anyopaque) *Environment {
        @disableInstrumentation();
        const threaded: *std.Io.Threaded = @ptrCast(@alignCast(raw.?));
        return @alignCast(@fieldParentPtr("threaded", threaded));
    }

    fn random(raw: ?*anyopaque, buffer: []u8) void {
        @disableInstrumentation();
        owner(raw).prng.random().bytes(buffer);
    }

    fn randomSecure(raw: ?*anyopaque, buffer: []u8) std.Io.RandomSecureError!void {
        @disableInstrumentation();
        random(raw, buffer);
    }

    fn now(raw: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
        @disableInstrumentation();
        const self = owner(raw);
        self.time += 1;
        return .{ .nanoseconds = self.time };
    }

    fn clockResolution(_: ?*anyopaque, _: std.Io.Clock) std.Io.Clock.ResolutionError!std.Io.Duration {
        @disableInstrumentation();
        return .{ .nanoseconds = 1 };
    }

    fn sleep(raw: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        @disableInstrumentation();
        const self = owner(raw);
        const duration = timeout.toDurationFromNow(self.io()) orelse @panic("unbounded sleep in deterministic fuzzing");
        self.time += @max(0, duration.raw.nanoseconds);
    }
};
