const std = @import("std");
const builtin = @import("builtin");
const lightning_rod = @import("lightning_rod");
const reload = @import("reload");
const host = @import("host");
const sessions = @import("sessions");
const vanilla = @import("vanilla");
pub const Startup = host.Startup;

pub fn Server(comptime Plugins: type, comptime Endpoint: type, comptime SessionPlugins: type, comptime Router: type) type {
    if (!builtin.single_threaded) @compileError("the embedded profile requires a single-threaded application");
    const Network = sessions.Embedded(Endpoint, SessionPlugins, Router);
    const Process = host.Process(Plugins, Network);
    return struct {
        pub const Options = Process.Options;

        pub fn run(memory: *lightning_rod.Memory, init: std.process.Init, options: Options, environment: anytype) !void {
            const process = try Process.init(memory, init, options, environment);
            defer process.deinit();
            const simulation = process.simulation;
            const network = process.network;
            const request = &process.reloading.request;
            const generation = try vanilla.Generation.init(memory.allocator("generation"), init.io, simulation.get(vanilla.Chunks).generation, 0);
            defer generation.deinit();
            try generation.start();
            defer generation.stop();
            var terrain: vanilla.Terrain = .{ .chunks = simulation.get(vanilla.Chunks), .streaming = simulation.get(vanilla.Streaming), .blocks = simulation.get(vanilla.BlockSynchronization), .io = init.io };
            terrain.start();
            defer terrain.stop();
            try network.start();
            defer network.stop();
            try process.ready();
            var deadline = std.Io.Clock.now(.awake, init.io).nanoseconds;
            while (!process.interrupted.requested()) {
                try network.poll();
                try terrain.poll();
                {
                    const tick = simulation.server_tick.start();
                    defer tick.end();
                    try simulation.tick();
                }
                if (process.reload_requested.swap(false, .acq_rel) and !request.pending and request.enabled) try request.stage(reload.signal_token);
                if (request.pending) {
                    const image = process.reloading.prepare(init.io) catch |err| {
                        request.result = .rejected;
                        request.elapsed_ms = host.elapsedMs(init.io, request.started_ns);
                        std.log.err("event=reload_rejected reason={s}", .{@errorName(err)});
                        continue;
                    };
                    defer image.close(init.io);
                    const until = host.timing.shutdownDeadline(init.io);
                    const quiesce = process.reload_quiesce.start();
                    try network.core.prepareReload(init.io, image.compatibility());
                    try network.pause(until);
                    terrain.stop();
                    quiesce.end();
                    try process.save(until);
                    process.executeReload(image) catch |err| std.log.err("event=reload_fallback reason={s}", .{@errorName(err)});
                    terrain.start();
                    try network.resumeReload();
                    if (process.exporter) |*value| try value.restart(init.io);
                    request.result = .rolled_back;
                    request.elapsed_ms = host.elapsedMs(init.io, request.started_ns);
                    deadline = std.Io.Clock.now(.awake, init.io).nanoseconds;
                    continue;
                }
                _ = try process.store.pollMaintenance(.{ .index_entries = 8, .pages = 8 });
                try simulation.poll();
                if (process.exporter) |*value| try value.poll(init.io);
                deadline = host.timing.nextTick(deadline, std.Io.Clock.now(.awake, init.io).nanoseconds);
                while (terrain.chunks.ready().isSet() and std.Io.Clock.now(.awake, init.io).nanoseconds < deadline) {
                    terrain.chunks.ready().reset();
                    try terrain.poll();
                    try network.poll();
                }
                if (!process.interrupted.requested()) try std.Io.Timeout.sleep(.{ .deadline = .{ .clock = .awake, .raw = .{ .nanoseconds = deadline } } }, init.io);
            }
        }
    };
}
