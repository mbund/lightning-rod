const std = @import("std");
const builtin = @import("builtin");
const lightning_rod = @import("lightning_rod");
const storage = @import("storage");
const reload = @import("reload");
const host = @import("host");
const sessions = @import("sessions");
const vanilla = @import("vanilla");
const execve = @import("reload_execve");
pub const Startup = host.Startup;

pub fn Server(comptime Plugins: type, comptime Endpoint: type, comptime SessionPlugins: type, comptime Router: type) type {
    if (builtin.single_threaded) @compileError("the Linux profile requires a multithreaded application");
    const Network = sessions.Threaded(Endpoint, SessionPlugins, Router);
    const Process = host.Process(Plugins, Network);
    return struct {
        pub const Options = struct {
            plugins: Plugins,
            network: Network.Configuration,
            registry: ?*lightning_rod.metrics.Registry = null,
            metrics: lightning_rod.metrics.Registry.Configuration = .{ .capacity = 512 },
            metrics_export: ?lightning_rod.metrics.Exporter.Configuration = null,
            generation_workers: usize = 1,
            storage_path: []const u8 = "lightning-rod-data/world",
            storage_readers: usize = 2,
            persistence: ?*storage.Store = null,
            simulation: lightning_rod.Configuration = .{},
            reload: ?execve.Configuration = .{},
            startup: ?Startup = null,
        };

        pub fn run(memory: *lightning_rod.Memory, init: std.process.Init, options: Options, environment: anytype) !void {
            if (options.generation_workers == 0 or options.generation_workers > 64) return error.InvalidGenerationWorkers;
            const process = try Process.init(memory, init, .{
                .plugins = options.plugins,
                .network = options.network,
                .registry = options.registry,
                .metrics = options.metrics,
                .metrics_export = options.metrics_export,
                .storage_path = options.storage_path,
                .storage_readers = options.storage_readers,
                .persistence = options.persistence,
                .simulation = options.simulation,
                .reload = options.reload,
                .startup = options.startup,
            }, environment);
            defer process.deinit();
            const simulation = process.simulation;
            const network = process.network;
            const request = &process.reloading.request;
            const generation = try vanilla.Generation.init(memory.allocator("generation"), init.io, simulation.get(vanilla.Chunks).generation, options.generation_workers);
            defer generation.deinit();
            try generation.start();
            defer generation.stop();
            var maintenance: storage.Maintenance = .{ .store = process.store };
            try maintenance.start();
            defer maintenance.stop();
            var background: vanilla.ThreadedTerrain = .{
                .terrain = .{ .chunks = simulation.get(vanilla.Chunks), .streaming = simulation.get(vanilla.Streaming), .blocks = simulation.get(vanilla.BlockSynchronization), .io = init.io },
                .io = init.io,
            };
            try background.start();
            defer background.stop();
            try network.start();
            defer network.stop();
            try process.ready();
            var deadline = std.Io.Clock.now(.awake, init.io).nanoseconds;
            while (!process.interrupted.requested()) {
                try network.check();
                try background.check();
                try maintenance.check();
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
                    try background.pause(until);
                    maintenance.stop();
                    quiesce.end();
                    try process.save(until);
                    process.executeReload(image) catch |err| std.log.err("event=reload_fallback reason={s}", .{@errorName(err)});
                    try maintenance.start();
                    background.resumeReload();
                    try network.resumeReload();
                    if (process.exporter) |*value| try value.restart(init.io);
                    request.result = .rolled_back;
                    request.elapsed_ms = host.elapsedMs(init.io, request.started_ns);
                    deadline = std.Io.Clock.now(.awake, init.io).nanoseconds;
                    continue;
                }
                try simulation.poll();
                if (process.exporter) |*value| try value.poll(init.io);
                deadline = host.timing.nextTick(deadline, std.Io.Clock.now(.awake, init.io).nanoseconds);
                if (!process.interrupted.requested()) try std.Io.Timeout.sleep(.{ .deadline = .{ .clock = .awake, .raw = .{ .nanoseconds = deadline } } }, init.io);
            }
        }
    };
}
