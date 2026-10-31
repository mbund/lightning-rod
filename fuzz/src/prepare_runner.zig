const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next() orelse return error.MissingSource;
    const seed = try std.fmt.parseInt(u32, args.next() orelse return error.MissingSeed, 10);
    const destination = args.next() orelse return error.MissingDestination;
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(1024 * 1024));
    const runner = try prepare(allocator, source, seed);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = destination, .data = runner });
}

fn prepare(allocator: std.mem.Allocator, source: []const u8, seed: u32) ![]const u8 {
    var runner = source;
    runner = replace(allocator, runner, "const fuzz_abi = std.Build.abi.fuzz;", "const fuzz_abi = std.Build.abi.fuzz;\nconst environment = @import(\"environment.zig\");");
    runner = replace(allocator, runner, "pub fn main(init: std.process.Init.Minimal) void {\n    @disableInstrumentation();", "pub fn main(init: std.process.Init.Minimal) void {\n    @disableInstrumentation();\n    environment.initialize();");
    runner = replace(allocator, runner, "                const n_tests: u32 = try server.receiveBody_u32();", "                const n_tests: u32 = try server.receiveBody_u32();\n                assert(n_tests == 1);");
    // Coverage uses TLS startup. The I/O limits and seccomp filter forbid threads.
    const limits = "                    .async_limit = .nothing,\n                    .concurrent_limit = .nothing,\n";
    const init_options = "                    .argv0 = .init(init.args),\n                    .environ = init.environ,\n";
    std.debug.assert(std.mem.count(u8, runner, init_options) == 2);
    runner = std.mem.replaceOwned(u8, allocator, runner, init_options, try std.fmt.allocPrint(allocator, "{s}{s}", .{ limits, init_options })) catch @panic("OOM");
    runner = replace(allocator, runner, "                const main_instance = mode == .iterations or amount_or_instance == 0;", "                const main_instance = mode == .iterations or amount_or_instance == 0;\n                if (!main_instance) @panic(\"deterministic fuzzing requires -j1\");");
    runner = replace(allocator, runner, "                    .input_poller = undefined,\n", "");
    runner = replace(allocator, runner, "    input_poller: Io.Future(Io.Cancelable!void),\n", "");
    const start = std.mem.indexOf(u8, runner, "    export fn runner_start_input_poller() void {") orelse unreachable;
    const end = std.mem.indexOf(u8, runner, "    export fn runner_futex_wait(") orelse unreachable;
    // One worker has no peers and receives no corpus broadcasts.
    runner = try std.fmt.allocPrint(allocator, "{s}    export fn runner_start_input_poller() void {{}}\n    export fn runner_stop_input_poller() void {{}}\n\n{s}", .{ runner[0..start], runner[end..] });
    const poll_start = std.mem.indexOf(u8, runner, "    fn inputPoller() Io.Cancelable!void {") orelse unreachable;
    const poll_end = std.mem.indexOfPos(u8, runner, poll_start, "} else void = undefined;") orelse unreachable;
    runner = try std.fmt.allocPrint(allocator, "{s}{s}", .{ runner[0..poll_start], runner[poll_end..] });
    runner = replace(allocator, runner, "            .argv0 = fuzz_runner.threaded_io.argv0,", "            .async_limit = .nothing,\n            .concurrent_limit = .nothing,\n            .argv0 = fuzz_runner.threaded_io.argv0,");
    runner = replace(allocator, runner, "        builtin.test_functions[fuzz_runner.indexes[i]].func()", "        testing.environ = fuzz_runner.threaded_io.environ.process_environ;\n        builtin.test_functions[fuzz_runner.indexes[i]].func()");
    runner = replace(allocator, runner, "    if (builtin.fuzz) {\n        const cache_dir", try std.fmt.allocPrint(allocator, "    testing.random_seed = {d};\n    if (builtin.fuzz) {{\n        const cache_dir", .{seed}));
    return runner;
}

fn replace(allocator: std.mem.Allocator, source: []const u8, before: []const u8, after: []const u8) []const u8 {
    std.debug.assert(std.mem.count(u8, source, before) == 1);
    return std.mem.replaceOwned(u8, allocator, source, before, after) catch @panic("OOM");
}
