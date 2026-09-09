const builtin = @import("builtin");
const std = @import("std");

pub fn main(init: std.process.Init.Minimal) void {
    bindLifetimeToParent();

    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    for (builtin.test_functions) |test_function| {
        switch (runOne(init, test_function)) {
            .passed => passed += 1,
            .skipped => skipped += 1,
            .failed => failed += 1,
        }
    }
    std.debug.print("{d} passed, {d} skipped, {d} failed\n", .{ passed, skipped, failed });
    if (failed != 0) std.process.exit(1);
}

const Result = enum { passed, skipped, failed };

fn runOne(init: std.process.Init.Minimal, test_function: std.builtin.TestFn) Result {
    std.testing.allocator_instance = .{};
    std.testing.io_instance = .init(std.testing.allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    std.testing.log_level = .warn;
    std.testing.environ = init.environ;

    var test_error: ?anyerror = null;
    test_function.func() catch |err| {
        test_error = err;
    };
    std.testing.io_instance.deinit();
    const leaked = std.testing.allocator_instance.deinit() == .leak;
    return result(test_function.name, test_error, leaked);
}

fn result(name: []const u8, test_error: ?anyerror, leaked: bool) Result {
    if (test_error) |err| {
        if (err == error.SkipZigTest) {
            std.debug.print("SKIP {s}\n", .{name});
            return .skipped;
        }
        std.debug.print("FAIL {s}: {t}\n", .{ name, err });
        return .failed;
    }
    if (leaked) {
        std.debug.print("FAIL {s}: leaked memory\n", .{name});
        return .failed;
    }
    std.debug.print("PASS {s}\n", .{name});
    return .passed;
}

fn bindLifetimeToParent() void {
    if (comptime builtin.os.tag != .linux) return;
    const parent = std.posix.getppid();
    _ = std.posix.prctl(.SET_PDEATHSIG, .{@intFromEnum(std.posix.SIG.KILL)}) catch
        @panic("failed to bind test lifetime to build parent");
    if (std.posix.getppid() != parent) std.process.exit(1);
}
