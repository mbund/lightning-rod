const std = @import("std");
const lightning_rod = @import("lightning_rod");
const sessions = @import("sessions");
const timing = @import("timing.zig");
const Shutdown = @import("shutdown.zig").Shutdown;

pub fn SimulationThread(comptime Plugins: type) type {
    return struct {
        const Self = @This();

        simulation: *lightning_rod.Simulation(Plugins),
        endpoint: *sessions.Service,
        exporter: ?*lightning_rod.metrics.Exporter = null,
        thread: ?std.Thread = null,
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,

        pub fn run(self: *Self, io: std.Io, stop: *Shutdown) void {
            defer {
                self.done.store(true, .release);
                self.endpoint.transport.notify(io);
            }
            self.loop(io, stop) catch |err| {
                self.failure = err;
                stop.request();
            };
            timing.closeSimulation(self.simulation, io) catch |err| {
                self.failure = err;
                stop.request();
            };
        }

        fn loop(self: *Self, io: std.Io, stop: *Shutdown) !void {
            var deadline = std.Io.Clock.now(.awake, io).nanoseconds;
            while (!stop.requested()) {
                const started = std.Io.Clock.now(.awake, io).nanoseconds;
                self.endpoint.beginTick();
                self.simulation.tick() catch |err| {
                    self.endpoint.endTick(false);
                    return err;
                };
                self.endpoint.endTick(true);
                self.endpoint.flush();
                self.simulation.server_tick.observe(@intCast(std.Io.Clock.now(.awake, io).nanoseconds - started));
                if (self.exporter) |exporter| try exporter.check();
                deadline = timing.nextTick(deadline, std.Io.Clock.now(.awake, io).nanoseconds);
                while (!stop.requested() and std.Io.Clock.now(.awake, io).nanoseconds < deadline) {
                    const work_started = std.Io.Clock.now(.awake, io).nanoseconds;
                    const result = try self.simulation.progress(deadline);
                    self.endpoint.flush();
                    self.simulation.server_work.observe(@intCast(std.Io.Clock.now(.awake, io).nanoseconds - work_started));
                    if (self.exporter) |exporter| try exporter.check();
                    if (result == .progressed) continue;
                    if (stop.requested()) break;
                    if (self.endpoint.waitOutput(.{ .deadline = .{ .clock = .awake, .raw = .{ .nanoseconds = deadline } } })) continue;
                    try stop.wait(deadline);
                }
            }
        }
    };
}
