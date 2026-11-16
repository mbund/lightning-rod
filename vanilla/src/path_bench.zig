//! What a path search costs: every golden terrain's search, a few rounds over, counting the
//! instructions and thread CPU time spent inside the searches alone. Run alone, on a quiet core:
//!   taskset -c 8 zig build bench-paths

const std = @import("std");
const linux = std.os.linux;
const defaults = @import("vanilla_definitions").defaults;
const mob_blocks = @import("vanilla_mobs").mob_blocks;
const pathfinding = @import("vanilla_mobs").pathfinding;
const Terrain = @import("path_terrain.zig").Terrain;

const scenarios = 1000;
const rounds = 5;

test "path search cost" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const deps = try defaults.prepare(allocator);
    const blocks = try mob_blocks.MobBlocks.init(allocator, deps.blocks);
    var terrain = try Terrain.init(allocator);
    var search = try pathfinding.Search.init(allocator, 16384);
    const output = try allocator.alloc(pathfinding.PathNode, 512);
    const counter = try Instructions.open();
    defer counter.close();
    var instructions: u64 = 0;
    var cpu: i96 = 0;
    var nodes: u64 = 0;
    for (0..rounds) |_| {
        for (1..scenarios + 1) |seed| {
            const scenario = terrain.generate(@intCast(seed));
            const level = terrain.level(blocks);
            const cpu_before = std.Io.Clock.now(.cpu_thread, std.testing.io).nanoseconds;
            const before = counter.read();
            const found = try search.findPath(&level, &scenario.mob, scenario.request, output);
            instructions += counter.read() - before;
            cpu += std.Io.Clock.now(.cpu_thread, std.testing.io).nanoseconds - cpu_before;
            nodes += search.node_count;
            if (found) |path| std.mem.doNotOptimizeAway(path.count);
        }
    }
    const searches: f64 = scenarios * rounds;
    std.debug.print("\npath search: {d:.0} instructions, {d:.2} us of CPU, {d:.1} nodes made, per search over {d} searches\n", .{
        @as(f64, @floatFromInt(instructions)) / searches,
        @as(f64, @floatFromInt(cpu)) / searches / 1000,
        @as(f64, @floatFromInt(nodes)) / searches,
        scenarios * rounds,
    });
}

/// User space instructions this thread retires, on the efficiency cores of a hybrid CPU where
/// there are some, as the benchmarks pin there.
const Instructions = struct {
    fd: linux.fd_t,

    fn open() !Instructions {
        var attr: linux.perf_event_attr = .{ .type = .HARDWARE, .config = @backingInt(linux.PERF.COUNT.HW.INSTRUCTIONS) | @as(u64, pmuType()) << 32 };
        attr.flags.exclude_kernel = true;
        attr.flags.exclude_hv = true;
        const result = linux.perf_event_open(&attr, 0, -1, -1, 0);
        if (linux.errno(result) != .SUCCESS) return error.PerfUnavailable;
        return .{ .fd = @intCast(result) };
    }

    fn close(self: Instructions) void {
        _ = linux.close(self.fd);
    }

    fn read(self: Instructions) u64 {
        var value: u64 = 0;
        const result = linux.read(self.fd, std.mem.asBytes(&value), @sizeOf(u64));
        std.debug.assert(linux.errno(result) == .SUCCESS and result == @sizeOf(u64));
        return value;
    }

    /// The cpu_atom PMU's type, or zero for the CPU's only one.
    fn pmuType() u32 {
        var buffer: [16]u8 = undefined;
        const fd = linux.open("/sys/bus/event_source/devices/cpu_atom/type", .{}, 0);
        if (linux.errno(fd) != .SUCCESS) return 0;
        defer _ = linux.close(@intCast(fd));
        const length = linux.read(@intCast(fd), &buffer, buffer.len);
        if (linux.errno(length) != .SUCCESS) return 0;
        return std.fmt.parseInt(u32, std.mem.trim(u8, buffer[0..length], " \n"), 10) catch 0;
    }
};
