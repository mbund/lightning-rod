const std = @import("std");
const lightning_rod = @import("lightning_rod");

pub const Terminal = struct {
    pub const Configuration = struct { enabled: bool = true, interval_ms: u32 = 1000, maximum_metrics: usize = 2048 };
    registry: *lightning_rod.metrics.Registry,
    io: std.Io,
    allocator: std.mem.Allocator,
    config: Configuration,
    snapshots: []lightning_rod.metrics.Snapshot,
    stopped: std.Io.Event = .unset,
    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, registry: *lightning_rod.metrics.Registry, config: Configuration) !Terminal {
        if (config.interval_ms == 0 or config.maximum_metrics == 0) return error.InvalidConfiguration;
        var configured = config;
        configured.enabled = config.enabled and try std.Io.File.stdout().supportsAnsiEscapeCodes(io);
        return .{ .registry = registry, .io = io, .allocator = allocator, .config = configured, .snapshots = try allocator.alloc(lightning_rod.metrics.Snapshot, if (configured.enabled) config.maximum_metrics else 0) };
    }

    pub fn start(self: *Terminal) !void {
        if (self.config.enabled) self.thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, execute, .{self});
    }

    fn execute(self: *Terminal) void {
        while (!self.stopped.isSet()) {
            self.render() catch return;
            self.stopped.waitTimeout(self.io, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(self.config.interval_ms) } }) catch |err| switch (err) {
                error.Timeout => {},
                else => return,
            };
        }
    }

    pub fn stop(self: *Terminal) void {
        self.stopped.set(self.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    pub fn deinit(self: *Terminal) void {
        std.debug.assert(self.thread == null);
        self.allocator.free(self.snapshots);
    }

    fn render(self: *Terminal) !void {
        const records = try self.registry.snapshotTree(self.snapshots);
        var bytes: [16 * 1024]u8 = undefined;
        var output = std.Io.Writer.fixed(&bytes);
        output.writeAll("\x1b[H\x1b[2JLightning Rod — Simulation\n\nPlugin                              last us     max us    memory KiB\n") catch unreachable;
        for (records) |record| {
            if (record.kind != .timer or !std.mem.endsWith(u8, record.name, ".tick")) continue;
            const name = record.name[0 .. record.name.len - ".tick".len];
            var memory: u64 = 0;
            for (records) |candidate| {
                if (candidate.kind == .gauge and std.mem.startsWith(u8, candidate.name, name) and std.mem.eql(u8, candidate.name[name.len..], ".persistent_memory")) memory = candidate.value;
            }
            output.print("{s:<35} {d:>8} {d:>10} {d:>13}\n", .{ name, record.value / 1000, record.maximum / 1000, memory / 1024 }) catch break;
        }
        try std.Io.File.stdout().writeStreamingAll(self.io, output.buffered());
    }
};
