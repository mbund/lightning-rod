const std = @import("std");
const rod = @import("lightning_rod");

pub const Plugin = struct {
    pub const id = "lightning_rod:tui";

    pub const Configuration = struct {
        enabled: bool = true,
        interval_ticks: u32 = 20,
    };

    config: Configuration,
    ticks: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, configuration: Configuration) !*Plugin {
        if (configuration.interval_ticks == 0) return error.InvalidConfiguration;

        const self = try allocator.create(Plugin);
        self.* = .{ .config = configuration };
        self.config.enabled = configuration.enabled and try std.Io.File.stdout().supportsAnsiEscapeCodes(io);
        return self;
    }

    pub fn tick(self: *Plugin, io: std.Io) void {
        if (!self.config.enabled) return;
        self.ticks += 1;
        if (self.ticks < self.config.interval_ticks) return;
        self.ticks = 0;
        const metrics = rod.metrics.snapshot() orelse return;
        var bytes: [16 * 1024]u8 = undefined;
        var output = std.Io.Writer.fixed(&bytes);
        output.writeAll("\x1b[H\x1b[2JLightning Rod — Simulation\n\nPlugin                              last us     max us    memory KiB\n") catch unreachable;

        for (metrics.plugins) |record| {
            output.print("{s:<35} {d:>8} {d:>10} {d:>13}\n", .{ record.name, record.last_ns / 1000, record.max_ns / 1000, record.persistent_bytes / 1024 }) catch break;
        }

        std.Io.File.stdout().writeStreamingAll(io, output.buffered()) catch {
            self.config.enabled = false;
        };
    }
};
