//! Forbids the fuzz runner new threads, so every run is the one deterministic thread it was. The
//! runner copies this file beside it, so it imports nothing but std.
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
