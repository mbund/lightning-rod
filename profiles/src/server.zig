const timing = @import("timing.zig");
const std = @import("std");
const builtin = @import("builtin");
const lightning_rod = @import("lightning_rod");
const sessions = @import("sessions");
const metrics = lightning_rod.metrics;
const storage = @import("storage");
const Store = storage.Store;
const reload = @import("reload");
const simulation_thread = @import("simulation_thread.zig");
const session_plugins = @import("session_plugins.zig");
const Shutdown = @import("shutdown.zig").Shutdown;

pub const SingleSimulation = sessions.SingleSimulation;
pub const Startup = timing.Startup;

pub fn Server(comptime Plugins: type, comptime Endpoint: type, comptime Transport: type, comptime Reload: type, comptime SessionSelections: type, comptime Router: type) type {
    return struct {
        const SessionRuntime = session_plugins.Runtime(Endpoint, SessionSelections);
        const SessionWorker = sessions.Worker(Endpoint, SessionRuntime, Router);
        const Worker = SessionThread(SessionWorker);
        pub const Options = struct {
            plugins: Plugins,
            session_plugins: SessionSelections,
            router: Router,
            session_memory_bytes: usize = 64 * 1024,
            protocols: *const Endpoint.Protocols,
            address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 25565 } },
            max_players: usize = 32,
            compression_threshold: ?usize = 256,
            metrics: metrics.Registry.Configuration = .{ .capacity = 512 },
            metrics_export: ?metrics.Exporter.Configuration = null,
            storage_path: []const u8 = "lightning-rod-data/world",
            persistence: ?*storage.Store = null,
            simulation: lightning_rod.Configuration = .{ .memory_bytes = 32 * 1024 * 1024, .temporary_bytes = 256 * 1024 },
            reload: ?Reload.Configuration = if (builtin.os.tag == .linux) .{} else null,
            /// Capture at application entry to include preparation before Server.run.
            startup: ?Startup = null,
        };

        pub const Instance = struct {
            plugins: Plugins,
            storage_path: []const u8,
            persistence: ?*storage.Store = null,
            endpoint: ?**sessions.Service = null,
            max_players: usize = 4,
            simulation: lightning_rod.Configuration = .{ .memory_bytes = 512 * 1024, .temporary_bytes = 16 * 1024 },
            output_pages: usize = 1,
            packet_bytes: usize = 384 * 1024,
        };

        pub const ManyOptions = struct {
            instances: []const Instance,
            session_plugins: SessionSelections,
            router: Router,
            session_memory_bytes: usize = 64 * 1024,
            protocols: *const Endpoint.Protocols,
            max_players: usize = 32,
            address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 25565 } },
            compression_threshold: ?usize = 256,
            metrics: metrics.Registry.Configuration = .{ .capacity = 512 },
            metrics_export: ?metrics.Exporter.Configuration = null,
        };

        pub fn runMany(allocator: std.mem.Allocator, init: std.process.Init, options: ManyOptions, environment: anytype) !void {
            if (options.instances.len == 0 or options.max_players == 0 or options.max_players > Transport.capacity.connections -| 8)
                return error.InvalidConfiguration;

            var interrupted: Shutdown = .{ .io = init.io };
            var signals: Signals = .{ .shutdown = &interrupted };
            try signals.install();
            defer signals.restore();
            const transport = try allocator.create(Transport);
            defer allocator.destroy(transport);
            transport.* = try Transport.init(init.io, .{ .address = options.address });
            defer transport.deinit(init.io);
            const registries = try allocator.alloc(Registries, options.instances.len);
            defer allocator.free(registries);
            var registry_count: usize = 0;
            defer for (registries[0..registry_count], 0..) |*registry, i| {
                registry.deinit(allocator, init.io, options.metrics_export, i);
            };
            for (registries) |*registry| {
                registry.* = try Registries.init(allocator, init.io, options.metrics);
                registry_count += 1;
            }
            var session_metrics = try metrics.Registry.init(allocator, init.io, options.metrics);
            defer {
                metrics.Exporter.writeSnapshotFile(allocator, init.io, &session_metrics, options.metrics_export, "sessions", 0) catch std.process.exit(1);
                session_metrics.deinit();
            }
            const stores = try allocator.alloc(?Store, options.instances.len);
            defer allocator.free(stores);
            const endpoints = try allocator.alloc(*sessions.Service, options.instances.len);
            defer allocator.free(endpoints);
            const notification_endpoints: []const *sessions.Service = endpoints;
            const Simulation = simulation_thread.SimulationThread(Plugins);
            const observations = try allocator.alloc(?metrics.Exporter, options.instances.len);
            defer allocator.free(observations);
            @memset(observations, null);
            const jobs = try allocator.alloc(Simulation, options.instances.len);
            defer allocator.free(jobs);
            var initialized: usize = 0;
            defer for (jobs[0..initialized], stores[0..initialized], observations[0..initialized], 0..) |*job, *store, *observation, i| {
                if (job.simulation.state != .closed)
                    timing.closeSimulation(job.simulation, init.io) catch std.process.exit(1);
                if (observation.*) |*exporter| exporter.deinit(allocator, &job.simulation.metrics) catch std.process.exit(1);
                metrics.Exporter.writeSnapshotFile(allocator, init.io, &job.simulation.metrics, options.metrics_export, "simulation", i) catch std.process.exit(1);
                job.simulation.deinit(allocator);
                job.endpoint.deinit();
                if (store.*) |*local| local.deinit();
            };

            for (options.instances, stores, endpoints, jobs, registries) |instance, *store, *endpoint, *job, *registry| {
                if (instance.max_players == 0 or instance.max_players > options.max_players)
                    return error.InvalidPlayerCapacity;

                store.* = if (instance.persistence == null) try Store.init(allocator, init.io, .{
                    .path = instance.storage_path,
                    .metrics = &registry.storage,
                    .submission = if (builtin.os.tag == .linux) .uring else .standard,
                }) else null;
                errdefer if (store.*) |*local| local.deinit();
                const backend = instance.persistence orelse &store.*.?;
                endpoint.* = try sessions.Service.init(allocator, init.io, transport.transport(), .{
                    .connections = instance.max_players,
                    .metrics = &registry.producer,
                    .protocols = &options.protocols.values,
                    .pages = instance.output_pages,
                    .page_bytes = instance.packet_bytes,
                });
                errdefer endpoint.*.deinit();

                if (instance.endpoint) |out|
                    out.* = endpoint.*;

                const simulation = try lightning_rod.Simulation(Plugins).init(allocator, init.io, backend, instance.simulation);
                errdefer {
                    timing.closeSimulation(simulation, init.io) catch std.process.exit(1);
                    simulation.deinit(allocator);
                }

                job.* = .{
                    .simulation = simulation,
                    .endpoint = endpoint.*,
                };

                const observation = &observations[initialized];
                if (try createExporter(allocator, init.io, &simulation.metrics, options.metrics_export, initialized)) |recorder| {
                    observation.* = recorder;
                    job.exporter = &observation.*.?;
                }

                errdefer if (observation.*) |*exporter| exporter.deinit(allocator, &simulation.metrics) catch std.process.exit(1);
                try simulation.initialize(instance.plugins, lightning_rod.plugin.environment(.{ .sessions = endpoint.*, .persistence = backend, .metrics = &simulation.metrics }, environment));
                std.log.info("event=simulation_ready index={d} arena_bytes={d} session_endpoint_bytes={d} storage_bytes={d} total_bytes={d}", .{
                    initialized,
                    simulation.bytes.len,
                    endpoint.*.memoryBytes(),
                    (if (store.*) |*local| local.memoryBytes() else 0),
                    simulation.bytes.len + endpoint.*.memoryBytes() + (if (store.*) |*local| local.memoryBytes() else 0),
                });
                initialized += 1;
            }

            const session_runtime = try SessionRuntime.init(allocator, init.io, options.session_plugins, lightning_rod.plugin.environment(.{ .endpoints = endpoints, .metrics = &session_metrics }, environment), options.session_memory_bytes, options.max_players + 8);
            defer session_runtime.deinit();
            var router = options.router;
            const session_worker = try SessionWorker.init(allocator, init.io, transport.transport(), .{
                .connections = options.max_players + 8,
                .max_players = options.max_players,
                .protocols = options.protocols,
                .hooks = session_runtime,
                .router = &router,
                .compression_threshold = options.compression_threshold,
                .metrics = &session_metrics,
            }, endpoints);
            defer session_worker.deinit();
            interrupted.endpoints.store(&notification_endpoints, .release);
            defer interrupted.endpoints.store(null, .release);
            defer {
                interrupted.request();
                for (jobs) |*job| if (job.thread) |thread| thread.join();
            }
            for (jobs) |*job| job.thread = try std.Thread.spawn(.{}, Simulation.run, .{ job, init.io, &interrupted });
            std.log.info("event=server_ready max_players={d} simulations={d}", .{ options.max_players, jobs.len });
            var failure: ?anyerror = null;
            var shutdown_deadline: ?i96 = null;
            while (true) {
                if (interrupted.requested() and shutdown_deadline == null)
                    shutdown_deadline = timing.shutdownDeadline(init.io).raw.nanoseconds;
                var done = true;
                for (jobs) |*job| {
                    const closed = job.done.load(.acquire);
                    done = done and closed;
                    if (closed) {
                        while (job.endpoint.next()) |event| if (event == .input) job.endpoint.release(event.input.handle);
                        if (job.failure) |err| failure = err;
                    }
                }
                if (done) session_worker.stop();
                session_worker.pump(.{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(50) } }) catch |err| {
                    failure = err;
                    interrupted.request();
                    session_worker.stop();
                };
                if (session_worker.stopping.load(.acquire) and session_worker.drained() and done) break;
                if (shutdown_deadline) |deadline| if (std.Io.Clock.now(.awake, init.io).nanoseconds >= deadline) std.process.exit(1);
            }
            for (jobs) |*job| {
                job.thread.?.join();
                job.thread = null;
            }
            if (failure) |err| return err;
        }

        pub fn run(allocator: std.mem.Allocator, init: std.process.Init, options: Options, environment: anytype) !void {
            const startup = options.startup orelse Startup.capture(init.io);
            const initialization_started = std.Io.Clock.now(.awake, init.io);
            const initialization_cpu_started = std.Io.Clock.now(.cpu_thread, init.io);
            if (options.max_players == 0 or options.max_players > Transport.capacity.connections -| 8)
                return error.InvalidPlayerCapacity;

            if (options.reload != null) Reload.retainManifest(Endpoint);

            var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const executable = if (options.reload) |config| config.executable orelse executable_buffer[0..try std.process.executablePath(init.io, &executable_buffer)] else null;
            var reload_request: reload.Request = .{ .enabled = executable != null and builtin.os.tag == .linux };
            var interrupted: Shutdown = .{ .io = init.io };
            var reload_requested = std.atomic.Value(bool).init(false);
            var signals: Signals = .{ .shutdown = &interrupted, .reload_requested = &reload_requested };
            try signals.install();
            defer signals.restore();

            var incoming = try Reload.incoming(init);
            const executing_ns = if (incoming) |handoff| handoff.executing_ns else null;
            defer if (incoming) |handoff| handoff.file.close(init.io);
            var input_buffer: [4096]u8 = undefined;
            var input: std.Io.File.Reader = undefined;
            var inherited_listener: ?i32 = null;
            var compression = options.compression_threshold;
            var resumed_tick: ?u64 = null;
            if (incoming) |handoff| {
                input = handoff.file.reader(init.io, &input_buffer);
                const header = try input.interface.takeArray(Reload.manifest.len);
                if (!std.mem.eql(u8, header, &Reload.manifest))
                    return error.InvalidResume;

                inherited_listener = try input.interface.takeInt(i32, .little);
                const threshold = try input.interface.takeInt(i32, .little);
                if (threshold < -1)
                    return error.InvalidResume;

                compression = if (threshold == -1) null else @intCast(threshold);
                resumed_tick = try input.interface.takeInt(u64, .little);
                reload_request.started_ns = try input.interface.takeInt(i96, .little);
                const token_len = try input.interface.takeInt(u16, .little);

                if (token_len <= reload_request.reply_bytes.len) {
                    try input.interface.readSliceAll(reload_request.reply_bytes[0..token_len]);
                    reload_request.reply_len = token_len;
                } else try input.interface.discardAll(token_len);
                reload_request.sequence = 1;
                try Reload.cloexec(inherited_listener.?, true);
            }

            var registry = try Registries.init(allocator, init.io, options.metrics);
            defer registry.deinit(allocator, init.io, options.metrics_export, 0);
            const initialization = try registry.producer.timer(.{ .name = "server.initialize", .description = "Server initialization after protocol preparation" });
            const initialization_cpu = try registry.producer.timer(.{ .name = "server.initialize.cpu", .description = "Server initialization on the owning thread", .clock = .thread_cpu });
            const initialize_storage = try registry.producer.timer(.{ .name = "server.initialize.storage", .description = "Open and recover storage" });
            const initialize_sessions = try registry.producer.timer(.{ .name = "server.initialize.sessions", .description = "Initialize session transport, buffers, and plugins" });
            const initialize_simulation = try registry.producer.timer(.{ .name = "server.initialize.simulation", .description = "Initialize simulation memory and plugins" });
            const reload_duration = try registry.producer.timer(.{ .name = "server.reload", .description = "Successful reload including session quiescing and process replacement" });
            const reload_before = try registry.producer.timer(.{ .name = "server.reload.before_exec", .description = "Reload request through the final timestamp in the old process" });
            const reload_replacement = try registry.producer.timer(.{ .name = "server.reload.replacement", .description = "Final old-process timestamp through new-process entry including exec runtime startup and scheduling" });
            const reload_after = try registry.producer.timer(.{ .name = "server.reload.after_exec", .description = "New-process entry through server readiness" });
            const startup_total = try registry.producer.timer(.{ .name = "server.startup", .description = "Process entry through server readiness" });
            const startup_cpu = try registry.producer.timer(.{ .name = "server.startup.cpu", .description = "Startup work on the main thread", .clock = .thread_cpu });
            const reload_checkpoint = try registry.producer.timer(.{ .name = "server.reload.checkpoint", .description = "Checkpoint and force durability before reload" });
            const reload_quiesce = try registry.producer.timer(.{ .name = "server.reload.quiesce", .description = "Return local socket buffer ownership before process replacement" });
            const initialize_transport = try registry.producer.timer(.{ .name = "server.initialize.sessions.transport", .description = "Initialize socket transport" });
            const initialize_endpoint = try registry.producer.timer(.{ .name = "server.initialize.sessions.endpoint", .description = "Allocate session endpoint state" });
            const initialize_session_plugins = try registry.producer.timer(.{ .name = "server.initialize.sessions.plugins", .description = "Initialize session plugins" });
            const initialize_worker = try registry.producer.timer(.{ .name = "server.initialize.sessions.worker", .description = "Allocate and initialize session worker" });
            const initialize_resume = try registry.producer.timer(.{ .name = "server.initialize.sessions.resume", .description = "Restore encrypted session handoff" });
            const initialize_simulation_memory = try registry.producer.timer(.{ .name = "server.initialize.simulation.memory", .description = "Allocate simulation memory and instruments" });
            const initialize_exporter = try registry.producer.timer(.{ .name = "server.initialize.simulation.exporter", .description = "Initialize simulation metric exporter" });
            const initialize_plugins = try registry.producer.timer(.{ .name = "server.initialize.simulation.plugins", .description = "Initialize gameplay plugins" });
            const initialize_players = try registry.producer.timer(.{ .name = "server.initialize.simulation.players", .description = "Restore simulation players" });
            const reload_validate = try registry.producer.timer(.{ .name = "server.reload.validate", .description = "Validate replacement executable and supported protocols" });
            const reload_export = try registry.producer.timer(.{ .name = "server.reload.metrics_export", .description = "Finish observation stream and export simulation session and storage snapshots" });
            var session_metrics = try metrics.Registry.init(allocator, init.io, options.metrics);
            defer {
                metrics.Exporter.writeSnapshotFile(allocator, init.io, &session_metrics, options.metrics_export, "sessions", 0) catch std.process.exit(1);
                session_metrics.deinit();
            }
            const storage_started = initialize_storage.start();
            var local_store: ?Store = if (options.persistence == null)
                try Store.init(allocator, init.io, .{ .path = options.storage_path, .metrics = &registry.storage, .submission = if (builtin.os.tag == .linux) .uring else .standard })
            else
                null;
            defer if (local_store) |*local| local.deinit();
            const store = options.persistence orelse &local_store.?;
            if (resumed_tick) |tick|
                if (store.lastTick() != tick)
                    return error.ResumeCheckpointMismatch;
            storage_started.end();

            const sessions_started = initialize_sessions.start();
            const transport_started = initialize_transport.start();
            const transport = try allocator.create(Transport);
            defer allocator.destroy(transport);
            transport.* = try Transport.init(init.io, .{ .address = options.address, .inherited_listener = inherited_listener });
            defer transport.deinit(init.io);
            transport_started.end();
            const endpoint_started = initialize_endpoint.start();
            const service = try sessions.Service.init(allocator, init.io, transport.transport(), .{
                .connections = options.max_players,
                .metrics = &registry.producer,
                .protocols = &options.protocols.values,
            });
            defer service.deinit();
            const endpoints = [_]*sessions.Service{service};
            const notification_endpoints: []const *sessions.Service = &endpoints;
            interrupted.endpoints.store(&notification_endpoints, .release);
            defer interrupted.endpoints.store(null, .release);
            endpoint_started.end();
            const session_plugins_started = initialize_session_plugins.start();
            const session_runtime = try SessionRuntime.init(allocator, init.io, options.session_plugins, lightning_rod.plugin.environment(.{ .sessions = service, .metrics = &session_metrics }, environment), options.session_memory_bytes, options.max_players + 8);
            defer session_runtime.deinit();
            session_plugins_started.end();
            var router = options.router;
            const worker_started = initialize_worker.start();
            const session_worker = try SessionWorker.init(allocator, init.io, transport.transport(), .{
                .connections = options.max_players + 8,
                .max_players = options.max_players,
                .protocols = options.protocols,
                .hooks = session_runtime,
                .router = &router,
                .compression_threshold = compression,
                .metrics = &session_metrics,
            }, &endpoints);
            defer session_worker.deinit();

            worker_started.end();
            const resume_started = initialize_resume.start();
            if (incoming) |handoff| {
                session_worker.engine.readResume(&input.interface) catch |err| {
                    std.log.err("event=resume_failed reason={s}", .{@errorName(err)});
                    std.process.exit(1);
                };

                const native = transport.transport().inheritance.?;
                for (session_worker.engine.connections) |connection|
                    if (connection.handle) |handle|
                        try Reload.cloexec(native.descriptor(handle), true);

                handoff.file.close(init.io);
                incoming = null;
            }
            resume_started.end();
            sessions_started.end();

            const simulation_started = initialize_simulation.start();
            const simulation_memory_started = initialize_simulation_memory.start();
            var simulation = try lightning_rod.Simulation(Plugins).init(allocator, init.io, store, options.simulation);
            var simulation_closed = false;
            defer {
                if (!simulation_closed) timing.closeSimulation(simulation, init.io) catch |err| {
                    std.log.err("event=shutdown_failed reason={s}", .{@errorName(err)});
                    std.process.exit(1);
                };

                metrics.Exporter.writeSnapshotFile(allocator, init.io, &simulation.metrics, options.metrics_export, "simulation", 0) catch std.process.exit(1);
                simulation.deinit(allocator);
            }
            simulation_memory_started.end();
            const exporter_started = initialize_exporter.start();
            var evidence = try createExporter(allocator, init.io, &simulation.metrics, options.metrics_export, 0);
            defer if (evidence) |*recorder| recorder.deinit(allocator, &simulation.metrics) catch std.process.exit(1);
            exporter_started.end();
            const dependencies = lightning_rod.plugin.environment(.{ .sessions = service, .reload_request = &reload_request, .persistence = store }, environment);
            const plugins_started = initialize_plugins.start();
            try simulation.initialize(options.plugins, lightning_rod.plugin.environment(.{ .metrics = &simulation.metrics }, dependencies));
            plugins_started.end();
            const players_started = initialize_players.start();
            if (resumed_tick != null) try session_worker.restorePlayers();
            players_started.end();
            simulation_started.end();
            initialization.observe(@intCast(std.Io.Clock.now(.awake, init.io).nanoseconds - initialization_started.nanoseconds));
            initialization_cpu.observe(@intCast(std.Io.Clock.now(.cpu_thread, init.io).nanoseconds - initialization_cpu_started.nanoseconds));

            var worker: Worker = .{ .sessions = session_worker, .shutdown = &interrupted };
            var thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
            const ready = Startup.capture(init.io);
            const startup_ns: u64 = @intCast(ready.wall_ns - startup.wall_ns);
            startup_total.observe(startup_ns);
            startup_cpu.observe(@intCast(ready.cpu_ns - startup.cpu_ns));
            if (executing_ns) |executing| {
                if (reload_request.started_ns > executing or executing > startup.wall_ns or startup.wall_ns > ready.wall_ns) std.process.exit(1);
                reload_request.result = .succeeded;
                const elapsed = ready.wall_ns - reload_request.started_ns;
                reload_duration.observe(@intCast(elapsed));
                reload_before.observe(@intCast(executing - reload_request.started_ns));
                reload_replacement.observe(@intCast(startup.wall_ns - executing));
                reload_after.observe(@intCast(ready.wall_ns - startup.wall_ns));
                reload_request.elapsed_ms = @intCast(@divTrunc(elapsed, std.time.ns_per_ms));
            }

            if (resumed_tick != null)
                std.log.info("event=reload_resumed tick={d} players={d}", .{ simulation.completed_tick, session_worker.engine.admitted });

            startup.publish(init.io, ready) catch std.process.exit(1);
            std.log.info("event=server_ready max_players={d} startup_ms={d:.3}", .{
                options.max_players,
                @as(f64, @floatFromInt(startup_ns)) / std.time.ns_per_ms,
            });
            var deadline = std.Io.Clock.now(.awake, init.io).nanoseconds;
            var failure: ?anyerror = null;

            running: while (!interrupted.requested() and !worker.failed.load(.acquire)) {
                const tick_started = std.Io.Clock.now(.awake, init.io).nanoseconds;
                service.beginTick();
                simulation.tick() catch |err| {
                    service.endTick(false);
                    failure = err;
                    std.log.err("event=simulation_failed completed_tick={d} reason={s}", .{ simulation.completed_tick, @errorName(err) });
                    break;
                };
                service.endTick(true);
                service.flush();

                simulation.server_tick.observe(@intCast(std.Io.Clock.now(.awake, init.io).nanoseconds - tick_started));
                if (evidence) |recorder| recorder.check() catch |err| {
                    failure = err;
                    break;
                };

                if (comptime builtin.os.tag == .linux) {
                    if (reload_requested.swap(false, .acq_rel) and !reload_request.pending and reload_request.enabled)
                        try reload_request.stage(reload.signal_token);
                }

                if (comptime builtin.os.tag == .linux) if (reload_request.pending) {
                    reload_request.pending = false;
                    reload_request.sequence += 1;
                    reload_request.result = null;
                    reload_request.started_ns = std.Io.Clock.now(.awake, init.io).nanoseconds;
                    const path = executable orelse continue;
                    const validation_started = reload_validate.start();
                    const image = Reload.Image.open(init.io, path) catch |err| {
                        reload_request.result = .rejected;
                        reload_request.elapsed_ms = @intCast(@divTrunc(std.Io.Clock.now(.awake, init.io).nanoseconds - reload_request.started_ns, std.time.ns_per_ms));
                        std.log.err("event=reload_rejected reason={s}", .{@errorName(err)});
                        continue;
                    };
                    defer image.close(init.io);
                    var removed: [Endpoint.versions.len]bool = undefined;
                    inline for (Endpoint.versions, 0..) |Version, index|
                        removed[index] = !try image.supports(init.io, Version.protocol_number, null);
                    validation_started.end();
                    std.log.info("event=reload_started tick={d}", .{simulation.completed_tick});
                    const until = std.Io.Clock.now(.awake, init.io).nanoseconds + 30 * std.time.ns_per_s;
                    const checkpoint_duration = reload_checkpoint.start();
                    simulation.close(.{ .clock = .awake, .raw = .{ .nanoseconds = until } }) catch |err| {
                        std.log.err("event=reload_checkpoint_failed reason={s}", .{@errorName(err)});
                        std.process.exit(1);
                    };
                    checkpoint_duration.end();
                    simulation_closed = true;
                    const quiesce_duration = reload_quiesce.start();
                    session_worker.requestReload(removed);

                    while (!worker.done.load(.acquire)) {
                        worker.resetNotification();
                        while (service.next()) |event|
                            if (event == .input)
                                service.release(event.input.handle);

                        if (std.Io.Clock.now(.awake, init.io).nanoseconds >= until) {
                            std.log.err("event=reload_quiesce_timeout", .{});
                            std.process.exit(1);
                        }

                        if (!worker.done.load(.acquire))
                            worker.changed.waitTimeout(init.io, .{ .deadline = .{ .clock = .awake, .raw = .{ .nanoseconds = until } } }) catch |err| if (err != error.Timeout) std.process.exit(1);
                    }

                    thread.join();
                    quiesce_duration.end();

                    if (worker.failed.load(.acquire))
                        std.process.exit(1);

                    while (service.next()) |event|
                        if (event == .input)
                            service.release(event.input.handle);

                    const export_started = reload_export.start();
                    if (evidence) |*recorder| recorder.deinit(allocator, &simulation.metrics) catch std.process.exit(1);
                    evidence = null;
                    metrics.Exporter.writeSnapshotFile(allocator, init.io, &simulation.metrics, options.metrics_export, "simulation", 0) catch std.process.exit(1);
                    metrics.Exporter.writeSnapshotFile(allocator, init.io, &session_metrics, options.metrics_export, "sessions", 0) catch std.process.exit(1);
                    metrics.Exporter.writeSnapshotFile(allocator, init.io, &registry.storage, options.metrics_export, "storage", 0) catch std.process.exit(1);
                    export_started.end();
                    attemptReload(Reload, SessionWorker, allocator, init, image, session_worker, store, &reload_request, &registry.producer, options.metrics_export) catch |err| std.log.err("event=reload_fallback reason={s}", .{@errorName(err)});
                    simulation.deinit(allocator);
                    simulation = lightning_rod.Simulation(Plugins).init(allocator, init.io, store, options.simulation) catch std.process.exit(1);
                    simulation_closed = false;
                    // Rollback creates new counters even though the process survives.
                    // Preserve the old segment and start a fresh recorder baseline.
                    evidence = createExporter(allocator, init.io, &simulation.metrics, options.metrics_export, 0) catch std.process.exit(1);
                    simulation.initialize(options.plugins, lightning_rod.plugin.environment(.{ .metrics = &simulation.metrics }, dependencies)) catch std.process.exit(1);
                    reload_request.result = .rolled_back;
                    reload_request.elapsed_ms = @intCast(@divTrunc(std.Io.Clock.now(.awake, init.io).nanoseconds - reload_request.started_ns, std.time.ns_per_ms));
                    session_worker.restart();
                    session_worker.restorePlayers() catch std.process.exit(1);
                    worker = .{ .sessions = session_worker, .shutdown = &interrupted };
                    thread = std.Thread.spawn(.{}, Worker.run, .{&worker}) catch std.process.exit(1);
                    deadline = std.Io.Clock.now(.awake, init.io).nanoseconds;
                    continue;
                };

                deadline = timing.nextTick(deadline, std.Io.Clock.now(.awake, init.io).nanoseconds);

                while (std.Io.Clock.now(.awake, init.io).nanoseconds < deadline and !interrupted.requested() and !worker.failed.load(.acquire)) {
                    const work_started = std.Io.Clock.now(.awake, init.io).nanoseconds;
                    const progressed = simulation.progress(deadline) catch |err| {
                        failure = err;
                        std.log.err("event=simulation_work_failed completed_tick={d} reason={s}", .{ simulation.completed_tick, @errorName(err) });
                        break :running;
                    };

                    service.flush();
                    simulation.server_work.observe(@intCast(std.Io.Clock.now(.awake, init.io).nanoseconds - work_started));
                    if (evidence) |recorder| recorder.check() catch |err| {
                        failure = err;
                        break :running;
                    };

                    if (progressed == .progressed)
                        continue;

                    if (interrupted.requested()) break;
                    if (service.waitOutput(.{ .deadline = .{ .clock = .awake, .raw = .{ .nanoseconds = deadline } } }))
                        continue;

                    interrupted.wait(deadline) catch |err| {
                        failure = err;
                        break :running;
                    };
                }
            }

            timing.closeSimulation(simulation, init.io) catch |err| {
                std.log.err("event=shutdown_failed reason={s}", .{@errorName(err)});
                if (err == error.Timeout) std.process.exit(1);
                failure = err;
            };
            simulation_closed = simulation.state == .closed;
            session_worker.stop();
            const shutdown_deadline = timing.shutdownDeadline(init.io).raw.nanoseconds;

            while (!worker.done.load(.acquire)) {
                worker.resetNotification();
                while (service.next()) |event|
                    if (event == .input)
                        service.release(event.input.handle);

                if (std.Io.Clock.now(.awake, init.io).nanoseconds >= shutdown_deadline) {
                    std.log.err("event=sessions_shutdown_timeout", .{});
                    std.process.exit(1);
                }

                if (!worker.done.load(.acquire))
                    worker.changed.waitTimeout(init.io, .{ .deadline = .{ .clock = .awake, .raw = .{ .nanoseconds = shutdown_deadline } } }) catch |err| if (err != error.Timeout) std.process.exit(1);
            }

            thread.join();

            if (!simulation_closed)
                std.process.exit(1);

            if (worker.failed.load(.acquire))
                std.process.exit(1);

            if (failure) |err|
                return err;
        }
    };
}

const Registries = struct {
    storage: metrics.Registry,
    producer: metrics.Registry,

    fn init(allocator: std.mem.Allocator, io: std.Io, config: metrics.Registry.Configuration) !Registries {
        var storage_registry = try metrics.Registry.init(allocator, io, config);
        errdefer storage_registry.deinit();
        return .{ .storage = storage_registry, .producer = try metrics.Registry.init(allocator, io, config) };
    }

    fn exportSnapshots(self: *const Registries, allocator: std.mem.Allocator, io: std.Io, config: ?metrics.Exporter.Configuration, index: usize) !void {
        try metrics.Exporter.writeSnapshotFile(allocator, io, &self.storage, config, "storage", index);
        try metrics.Exporter.writeSnapshotFile(allocator, io, &self.producer, config, "producer", index);
    }

    fn deinit(self: *Registries, allocator: std.mem.Allocator, io: std.Io, config: ?metrics.Exporter.Configuration, index: usize) void {
        self.exportSnapshots(allocator, io, config, index) catch std.process.exit(1);
        self.producer.deinit();
        self.storage.deinit();
    }
};

fn createExporter(allocator: std.mem.Allocator, io: std.Io, registry: *metrics.Registry, config: ?metrics.Exporter.Configuration, index: usize) !?metrics.Exporter {
    const selected = config orelse return null;
    return try metrics.Exporter.init(allocator, io, registry, selected, index, &.{ "server.tick", "server.work" });
}

fn SessionThread(comptime SessionWorker: type) type {
    return struct {
        const Worker = @This();
        sessions: *SessionWorker,
        shutdown: *Shutdown,
        failed: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        changed: std.Io.Event = .unset,

        fn resetNotification(self: *Worker) void {
            // Acquire the last notification before rechecking shared state.
            _ = @atomicRmw(std.Io.Event, &self.changed, .Xchg, .unset, .acq_rel);
        }

        fn run(self: *Worker) void {
            defer {
                self.done.store(true, .release);
                self.changed.set(self.sessions.io);
            }

            while (true) {
                self.sessions.pump(.{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(50) } }) catch |err| {
                    std.log.err("event=sessions_failed reason={s}", .{@errorName(err)});
                    self.failed.store(true, .release);
                    self.shutdown.request();
                    return;
                };
                self.changed.set(self.sessions.io);
                if (self.sessions.stopping.load(.acquire) and self.sessions.drained())
                    return;

                if (self.sessions.reload_state.load(.acquire) == .parked)
                    return;
            }
        }
    };
}

fn attemptReload(comptime Reload: type, comptime SessionWorker: type, allocator: std.mem.Allocator, init: std.process.Init, image: Reload.Image, worker: *SessionWorker, store: *storage.Store, request: *const reload.Request, registry: *metrics.Registry, export_config: ?metrics.Exporter.Configuration) !noreturn {
    const validation = try registry.timer(.{ .name = "server.reload.handoff.validate", .description = "Validate resume formats for connected sessions" });
    const sessions_timer = try registry.timer(.{ .name = "server.reload.handoff.sessions", .description = "Serialize session ownership and encryption state" });
    const seal_timer = try registry.timer(.{ .name = "server.reload.handoff.seal", .description = "Flush and seal the handoff memfd" });
    const handoff_bytes = try registry.gauge(.{ .name = "server.reload.handoff.bytes", .description = "Sealed reload handoff size", .unit = .bytes });
    const handoff = try registry.timer(.{ .name = "server.reload.handoff", .description = "Create serialize and seal the reload handoff" });
    const handoff_started = handoff.start();
    const validation_started = validation.start();
    const tick = store.lastTick();
    for (worker.engine.connections) |connection| {
        if (connection.handle == null) continue;
        if (connection.protocol) |protocol| {
            const Engine = @TypeOf(worker.engine.*);
            if (!try image.supports(init.io, protocol.number, Engine.endpoint.resumeFormat(&connection.lifecycle.?))) return error.ReloadProtocolUnsupported;
        }
    }
    validation_started.end();
    const file = try Reload.create();
    defer file.close(init.io);
    var buffer: [4096]u8 = undefined;
    var output = file.writer(init.io, &buffer);
    const writer = &output.interface;
    const native = worker.engine.networking.inheritance.?;
    var descriptors: [265]i32 = undefined;
    descriptors[0] = native.listener();
    var count: usize = 1;

    for (worker.engine.connections) |connection|
        if (connection.handle) |handle| {
            descriptors[count] = native.descriptor(handle);
            count += 1;
        };

    try writer.writeAll(&Reload.manifest);
    try writer.writeInt(i32, descriptors[0], .little);
    try writer.writeInt(i32, if (worker.config.compression_threshold) |threshold| @intCast(threshold) else -1, .little);
    try writer.writeInt(u64, tick, .little);
    try writer.writeInt(i96, request.started_ns, .little);
    try writer.writeInt(u16, request.reply_len, .little);
    try writer.writeAll(request.token());
    const sessions_started = sessions_timer.start();
    try worker.engine.writeResume(writer);
    sessions_started.end();
    const seal_started = seal_timer.start();
    try writer.flush();
    try Reload.seal(file);
    handoff_bytes.set((try file.stat(init.io)).size);
    seal_started.end();
    handoff_started.end();
    try metrics.Exporter.writeSnapshotFile(allocator, init.io, registry, export_config, "producer", 0);
    std.log.info("event=reload_exec tick={d} players={d}", .{ tick, count - 1 });
    return image.execute(allocator, init, file, descriptors[0..count]);
}

const Signals = if (builtin.os.tag == .windows) struct {
    shutdown: *Shutdown,
    reload_requested: ?*std.atomic.Value(bool) = null,
    var active = std.atomic.Value(?*@This()).init(null);

    fn install(self: *@This()) !void {
        const previous = active.swap(self, .acq_rel);
        std.debug.assert(previous == null);
        errdefer active.store(null, .release);
        if (SetConsoleCtrlHandler(handler, 1) == 0)
            return error.SignalHandlerFailed;
    }

    fn restore(_: *@This()) void {
        _ = SetConsoleCtrlHandler(handler, 0);
        active.store(null, .release);
    }

    fn handler(code: u32) callconv(.winapi) i32 {
        if (code != 0 and code != 1 and code != 2 and code != 6)
            return 0;

        const self = active.load(.acquire) orelse return 0;
        self.shutdown.request();
        return 1;
    }

    extern "kernel32" fn SetConsoleCtrlHandler(?*const fn (u32) callconv(.winapi) i32, i32) callconv(.winapi) i32;
} else struct {
    shutdown: *Shutdown,
    reload_requested: ?*std.atomic.Value(bool) = null,
    old_int: std.posix.Sigaction = undefined,
    old_term: std.posix.Sigaction = undefined,
    old_usr1: std.posix.Sigaction = undefined,
    var active = std.atomic.Value(?*@This()).init(null);

    fn install(self: *@This()) !void {
        const previous = active.swap(self, .acq_rel);
        std.debug.assert(previous == null);
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = handler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &action, &self.old_int);
        std.posix.sigaction(.TERM, &action, &self.old_term);
        std.posix.sigaction(.USR1, &action, &self.old_usr1);
    }

    fn restore(self: *@This()) void {
        std.posix.sigaction(.INT, &self.old_int, null);
        std.posix.sigaction(.TERM, &self.old_term, null);
        std.posix.sigaction(.USR1, &self.old_usr1, null);
        active.store(null, .release);
    }

    fn handler(signal: std.posix.SIG) callconv(.c) void {
        const self = active.load(.acquire) orelse return;
        if (signal == .USR1) {
            if (self.reload_requested) |request| request.store(true, .release);
        } else {
            self.shutdown.request();
        }
    }
};
