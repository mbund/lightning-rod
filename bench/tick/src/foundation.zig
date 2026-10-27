const std = @import("std");
const lightning_rod = @import("lightning_rod");

pub const std_options: std.Options = .{ .log_level = .err };

const Case = enum { empty, one, many, direct, storage, timer };
const Options = struct {
    case: ?Case = null,
    ticks: usize = 1_000_000,
    metrics: ?bool = null,
    uring: bool = false,
};

fn Probe(comptime index: usize) type {
    return struct {
        pub const id = std.fmt.comptimePrint("benchmark:probe_{d}", .{index});
        pub const Configuration = struct {};
        value: u64 = 0,

        pub fn init(allocator: std.mem.Allocator) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{};
            return self;
        }

        pub fn tick(self: *@This()) void {
            self.value +%= 1;
        }
    };
}

fn selections(comptime count: usize) if (count == 0) @TypeOf(.{}) else @TypeOf(lightning_rod.plugin.compose(.{ selections(count - 1), lightning_rod.plugin.configured(Probe(count - 1), .{}) })) {
    if (count == 0) return .{};
    return lightning_rod.plugin.compose(.{ selections(count - 1), lightning_rod.plugin.configured(Probe(count - 1), .{}) });
}

fn probeCount(comptime case: Case) usize {
    return switch (case) {
        .one => 1,
        .many, .direct => 32,
        else => 0,
    };
}

fn Simulation(comptime case: Case) type {
    return lightning_rod.Simulation(@TypeOf(selections(probeCount(case))));
}

fn run(comptime case: Case, allocator: std.mem.Allocator, io: std.Io, options: Options, enabled: bool, writer: *std.Io.Writer) !void {
    const count = comptime probeCount(case);
    const plugins = comptime selections(count);
    var memory = lightning_rod.Memory.init(allocator, io);
    defer memory.deinit();
    const backing = memory.allocator("foundation-bench");
    const directory = try std.fmt.allocPrint(backing, ".zig-cache/foundation-bench/{d}-{s}-{any}", .{ std.os.linux.getpid(), @tagName(case), enabled });
    try std.Io.Dir.cwd().createDirPath(io, directory);
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    const path = try std.fmt.allocPrint(backing, "{s}/world", .{directory});
    var store = try lightning_rod.storage.Store.init(backing, io, .{ .path = path, .io_mode = if (options.uring) .uring else .standard });
    defer store.deinit();
    const simulation = try Simulation(case).init(backing, io, &store, .{ .autosave = .{ .ticks = null }, .temporary_bytes = 16 * 1024, .metrics = .{ .capacity = 256, .enabled = enabled } });
    try simulation.initialize(plugins, .{});
    defer {
        simulation.close(.{ .clock = .awake, .raw = .{ .nanoseconds = std.Io.Clock.now(.awake, io).nanoseconds + 5 * std.time.ns_per_s } }) catch @panic("benchmark shutdown failed");
        simulation.deinit(backing);
    }
    memory.seal();
    for (0..200) |_| try advance(case, simulation);
    const cpu = std.Io.Clock.now(.cpu_thread, io).nanoseconds;
    const wall = std.Io.Clock.now(.awake, io).nanoseconds;
    for (0..options.ticks) |_| try advance(case, simulation);
    const elapsed = std.Io.Clock.now(.awake, io).nanoseconds - wall;
    const consumed = std.Io.Clock.now(.cpu_thread, io).nanoseconds - cpu;
    inline for (0..count) |index| {
        if (simulation.get(Probe(index)).value != options.ticks + 200) return error.IncorrectProbeCount;
    }
    try writer.print("{s: <8} {any: <7} {d: >7} {d: >12.2} {d: >12.2}\n", .{ @tagName(case), enabled, count, @as(f64, @floatFromInt(consumed)) / @as(f64, @floatFromInt(options.ticks)), @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(options.ticks)) });
    try writer.flush();
}

fn advance(comptime case: Case, simulation: *Simulation(case)) !void {
    switch (case) {
        .direct => inline for (0..32) |index| @call(.never_inline, Probe(index).tick, .{simulation.instances.pointers[index]}),
        .storage => try simulation.transaction.progress(),
        .timer => simulation.tick_duration.start().end(),
        else => {
            const timing = simulation.server_tick.start();
            try simulation.tick();
            timing.end();
        },
    }
}

pub fn main(init: std.process.Init) !void {
    var options: Options = .{};
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |argument| {
        if (std.mem.startsWith(u8, argument, "--case=")) {
            options.case = std.meta.stringToEnum(Case, argument[7..]) orelse return error.InvalidCase;
        } else if (std.mem.startsWith(u8, argument, "--ticks=")) {
            options.ticks = try std.fmt.parseInt(usize, argument[8..], 10);
        } else if (std.mem.eql(u8, argument, "--metrics")) {
            options.metrics = true;
        } else if (std.mem.eql(u8, argument, "--no-metrics")) {
            options.metrics = false;
        } else if (std.mem.eql(u8, argument, "--uring")) {
            options.uring = true;
        } else return error.InvalidArgument;
    }
    if (options.ticks == 0) return error.InvalidArgument;
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    try output.interface.writeAll("# Empty probes increment one counter each. Direct uses the same function calls without simulation or instrumentation.\ncase     metrics plugins       cpu_ns      wall_ns\n");
    inline for (std.enums.values(Case)) |case| {
        if (options.case == null or options.case.? == case) {
            for ([_]bool{ false, true }) |enabled| {
                if (options.metrics == null or options.metrics.? == enabled) try run(case, init.gpa, init.io, options, enabled, &output.interface);
            }
        }
    }
}
