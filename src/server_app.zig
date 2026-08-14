const std = @import("std");
const async_log = @import("async_log.zig");
const plugin_api = @import("plugin_api.zig");
const reactor = @import("reactor.zig");

pub const std_options: std.Options = .{ .logFn = async_log.logFn };

fn panicWithPluginContext(message: []const u8, return_address: ?usize) noreturn {
    if (plugin_api.activeSystem()) |active| {
        std.debug.print(
            "\n=== LIGHTNING ROD PLUGIN PANIC ===\n" ++
                "panic:  {s}\nphase:  {s}\nplugin: {s} (profile index {d})\n" ++
                "system: {s} (plugin system index {d})\n",
            .{ message, active.phase, active.plugin_id, active.plugin_index, active.system_type, active.system_index },
        );
        if (active.tick) |tick| std.debug.print("tick:    {d}\n", .{tick});
        if (active.subject) |subject| std.debug.print("subject: connection/player slot {d}\n", .{subject});
        std.debug.print("==================================\n\n", .{});
    }
    std.debug.defaultPanic(message, return_address);
}

pub const panic = std.debug.FullPanic(panicWithPluginContext);

pub fn run(comptime Profile: type, init: std.process.Init) !void {
    comptime validateProfile(Profile);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        printUsage();
        return;
    }
    const options = parseRunOptions(args[1..]) catch |err| {
        printUsage();
        return err;
    };
    try reactor.run(init, options);
}

fn validateProfile(comptime Profile: type) void {
    if (!@hasDecl(Profile, "Plugins"))
        @compileError("server profile must export Plugins");
    if (!@hasDecl(Profile, "create"))
        @compileError("server profile must export create");
    if (!@hasDecl(Profile, "stores"))
        @compileError("server profile must export stores");
    if (!@hasDecl(Profile, "commandDeclarations"))
        @compileError("server profile must export commandDeclarations");
    if (!@hasDecl(Profile, "configuration"))
        @compileError("server profile must export compile-time configuration");
    if (!@hasDecl(Profile, "protocols"))
        @compileError("server profile must export configured protocol plugins");
    Profile.configuration.validate();
}

fn parseRunOptions(args: []const []const u8) !reactor.RunOptions {
    var options: reactor.RunOptions = .{};
    for (args) |argument| {
        if (std.mem.eql(u8, argument, "--tui")) {
            if (options.tui) return error.DuplicateArgument;
            options.tui = true;
        } else if (std.mem.startsWith(u8, argument, "--cpu=")) {
            if (options.cpu != null) return error.DuplicateArgument;
            options.cpu = try parseInteger(usize, argument, "--cpu=");
        } else return error.InvalidArguments;
    }
    return options;
}

fn parseInteger(comptime T: type, argument: []const u8, comptime prefix: []const u8) !T {
    const value = argument[prefix.len..];
    if (value.len == 0) return error.InvalidArguments;
    return std.fmt.parseInt(T, value, 10) catch error.InvalidArguments;
}

fn printUsage() void {
    std.debug.print(
        "usage: lightning_rod [--tui] [--cpu=N]\n" ++
            "configuration is compiled into the tick module\n",
        .{},
    );
}

test "run options are bounded and unambiguous" {
    try std.testing.expect((try parseRunOptions(&.{"--tui"})).tui);
    try std.testing.expectEqual(@as(?usize, 7), (try parseRunOptions(&.{"--cpu=7"})).cpu);
    try std.testing.expectError(error.InvalidArguments, parseRunOptions(&.{"--unknown"}));
    try std.testing.expectError(error.DuplicateArgument, parseRunOptions(&.{ "--tui", "--tui" }));
}
