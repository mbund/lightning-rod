const std = @import("std");
const builtin = @import("builtin");
const lightning_rod = @import("lightning_rod");
const sessions = @import("sessions");
const storage = @import("storage");
const reload = @import("reload");
const scheduler = @import("scheduler.zig");
const session_plugins = @import("session_plugins.zig");

pub const Scheduler = scheduler.Scheduler;
pub const SingleSimulation = sessions.SingleSimulation;

var interrupted = std.atomic.Value(bool).init(false);
var reload_requested = std.atomic.Value(bool).init(false);

pub fn Server(comptime Plugins: type, comptime Endpoint: type, comptime Transport: type, comptime Store: type, comptime Reload: type, comptime SessionSelections: type, comptime Router: type) type {
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
            storage_path: []const u8 = "lightning-rod-data/world",
            persistence: ?storage.Storage = null,
            memory: lightning_rod.Configuration = .{ .memory_bytes = 32 * 1024 * 1024, .temporary_bytes = 256 * 1024 },
            reload: ?Reload.Configuration = if (builtin.os.tag == .linux) .{} else null,
            reload_manifest: ?[]const u8 = null,
        };

        pub const Instance = struct {
            plugins: Plugins,
            storage_path: []const u8,
            persistence: ?storage.Storage = null,
            endpoint: ?**sessions.Service = null,
            max_players: usize = 4,
            memory: lightning_rod.Configuration = .{ .memory_bytes = 512 * 1024, .temporary_bytes = 16 * 1024 },
            output_pages: usize = 1,
            packet_bytes: usize = 384 * 1024,
        };

        pub const ManyOptions = struct {
            instances: []const Instance,
            session_plugins: SessionSelections,
            router: Router,
            session_memory_bytes: usize = 64 * 1024,
            protocols: *const Endpoint.Protocols,
            workers: usize = 2,
            max_players: usize = 32,
            address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 25565 } },
            compression_threshold: ?usize = 256,
        };

        pub fn runMany(init: std.process.Init, options: ManyOptions) !void {
            return runManyWithEnvironment(init, options, .{});
        }

        pub fn runManyWithEnvironment(init: std.process.Init, options: ManyOptions, environment: anytype) !void {
            if (options.instances.len == 0 or options.workers == 0 or options.max_players == 0 or options.max_players > Transport.capacity.connections -| 8)
                return error.InvalidConfiguration;

            interrupted.store(false, .release);
            var signals: Signals = undefined;
            try signals.install();
            defer signals.restore();
            const transport = try init.gpa.create(Transport);
            defer init.gpa.destroy(transport);
            transport.* = try Transport.init(init.io, .{ .address = options.address });
            defer transport.deinit(init.io);
            const stores = try init.gpa.alloc(?Store, options.instances.len);
            defer init.gpa.free(stores);
            const endpoints = try init.gpa.alloc(*sessions.Service, options.instances.len);
            defer init.gpa.free(endpoints);
            const Schedule = Scheduler(Plugins);
            const jobs = try init.gpa.alloc(Schedule.Job, options.instances.len);
            defer init.gpa.free(jobs);
            const slots = try init.gpa.alloc(Schedule.Slot, @min(options.workers, options.instances.len));
            defer init.gpa.free(slots);
            @memset(slots, .{});
            var initialized: usize = 0;
            defer for (jobs[0..initialized], stores[0..initialized]) |*job, *store| {
                if (job.simulation.state != .closed)
                    job.simulation.close(.{
                        .clock = .awake,
                        .raw = .{ .nanoseconds = std.Io.Clock.now(.awake, init.io).nanoseconds + 5 * std.time.ns_per_s },
                    }) catch std.process.exit(1);
                job.simulation.deinit(init.gpa);
                job.endpoint.deinit();
                if (store.*) |*local| local.deinit(init.io);
            };

            for (options.instances, stores, endpoints, jobs) |instance, *store, *endpoint, *job| {
                if (instance.max_players == 0 or instance.max_players > options.max_players)
                    return error.InvalidPlayerCapacity;

                if (instance.persistence == null) if (std.fs.path.dirname(instance.storage_path)) |parent|
                    try std.Io.Dir.cwd().createDirPath(init.io, parent);

                store.* = if (instance.persistence == null) try Store.init(init.gpa, init.io, .{
                    .path = instance.storage_path,
                    .max_value_bytes = 64 * 1024,
                    .buffer_bytes = 16 * 1024,
                }) else null;
                errdefer if (store.*) |*local| local.deinit(init.io);
                const backend = instance.persistence orelse store.*.?.interface();
                endpoint.* = try sessions.Service.init(init.gpa, init.io, transport.transport(), .{
                    .connections = instance.max_players,
                    .protocols = &options.protocols.values,
                    .pages = instance.output_pages,
                    .page_bytes = instance.packet_bytes,
                });
                errdefer endpoint.*.deinit();

                if (instance.endpoint) |out|
                    out.* = endpoint.*;

                const simulation = try lightning_rod.Simulation(Plugins).init(init.gpa, init.io, backend, instance.memory);
                errdefer {
                    simulation.close(.{
                        .clock = .awake,
                        .raw = .{ .nanoseconds = std.Io.Clock.now(.awake, init.io).nanoseconds + 5 * std.time.ns_per_s },
                    }) catch std.process.exit(1);
                    simulation.deinit(init.gpa);
                }

                job.* = .{
                    .simulation = simulation,
                    .endpoint = endpoint.*,
                    .deadline = std.Io.Clock.now(.awake, init.io).nanoseconds,
                };

                try simulation.initialize(instance.plugins, lightning_rod.plugin.environment(.{ .sessions = endpoint.* }, environment));
                std.log.info("event=simulation_ready index={d} arena_bytes={d} session_endpoint_bytes={d} storage_bytes={d} total_bytes={d}", .{
                    initialized,
                    simulation.bytes.len,
                    endpoint.*.memoryBytes(),
                    (if (store.*) |*local| local.memoryBytes() else 0),
                    simulation.bytes.len + endpoint.*.memoryBytes() + (if (store.*) |*local| local.memoryBytes() else 0),
                });
                initialized += 1;
            }

            var wakeup: std.Io.Event = .unset;
            const session_runtime = try SessionRuntime.init(init.gpa, init.io, options.session_plugins, lightning_rod.plugin.environment(.{ .endpoints = endpoints }, environment), options.session_memory_bytes, options.max_players + 8);
            defer session_runtime.deinit();
            var router = options.router;
            const session_worker = try SessionWorker.init(init.gpa, init.io, transport.transport(), .{
                .connections = options.max_players + 8,
                .max_players = options.max_players,
                .protocols = options.protocols,
                .hooks = session_runtime,
                .router = &router,
                .wakeup = &wakeup,
                .compression_threshold = options.compression_threshold,
            }, endpoints);
            defer session_worker.deinit();
            var worker: Worker = .{ .sessions = session_worker };
            const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
            std.log.info("event=server_ready max_players={d} simulations={d} workers={d}", .{ options.max_players, jobs.len, slots.len });
            var failure: ?anyerror = null;
            Schedule.run(init.io, jobs, slots, &interrupted, &wakeup) catch |err| {
                failure = err;
                std.log.err("event=simulation_failed reason={s}", .{@errorName(err)});
            };

            for (jobs, 0..) |*job, index| {
                job.simulation.close(.{
                    .clock = .awake,
                    .raw = .{ .nanoseconds = std.Io.Clock.now(.awake, init.io).nanoseconds + 5 * std.time.ns_per_s },
                }) catch |err| {
                    failure = err;
                    std.log.err("event=shutdown_failed reason={s}", .{@errorName(err)});
                };

                std.log.info("event=simulation_totals index={d} ticks={d} maximum_tick_ns={d} maximum_work_ns={d}", .{
                    index,
                    job.simulation.completed_tick,
                    job.simulation.maximum_tick_ns,
                    job.simulation.maximum_work_ns,
                });
            }

            session_worker.stop();
            const shutdown_deadline = std.Io.Clock.now(.awake, init.io).nanoseconds + 5 * std.time.ns_per_s;

            while (!worker.done.load(.acquire)) {
                for (endpoints) |endpoint|
                    while (endpoint.next()) |event|
                        if (event == .input)
                            endpoint.release(event.input.handle);

                if (std.Io.Clock.now(.awake, init.io).nanoseconds >= shutdown_deadline)
                    std.process.exit(1);

                std.Io.sleep(init.io, .fromMilliseconds(1), .awake) catch {};
            }

            thread.join();

            if (worker.failed.load(.acquire))
                std.process.exit(1);

            if (failure) |err|
                return err;
        }

        pub fn run(init: std.process.Init, options: Options) !void {
            return runWithEnvironment(init, options, .{});
        }

        pub fn runWithEnvironment(init: std.process.Init, options: Options, environment: anytype) !void {
            if (options.max_players == 0 or options.max_players > Transport.capacity.connections -| 8)
                return error.InvalidPlayerCapacity;

            if (options.reload != null) {
                const manifest = options.reload_manifest orelse return error.MissingResumeManifest;
                if (!std.mem.startsWith(u8, manifest, &Reload.manifest)) return error.InvalidResumeManifest;
                std.mem.doNotOptimizeAway(manifest.ptr);
            }

            var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const executable = if (options.reload) |config| config.executable orelse executable_buffer[0..try std.process.executablePath(init.io, &executable_buffer)] else null;
            var reload_request: reload.Request = .{ .enabled = executable != null and builtin.os.tag == .linux };
            interrupted.store(false, .release);
            reload_requested.store(false, .release);
            var signals: Signals = undefined;
            try signals.install();
            defer signals.restore();

            var incoming = try Reload.incoming(init);
            defer if (incoming) |file| file.close(init.io);
            var input_buffer: [4096]u8 = undefined;
            var input: std.Io.File.Reader = undefined;
            var inherited_listener: ?i32 = null;
            var compression = options.compression_threshold;
            var resumed_tick: ?u64 = null;
            if (incoming) |file| {
                input = file.reader(init.io, &input_buffer);
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

            if (options.persistence == null) if (std.fs.path.dirname(options.storage_path)) |parent|
                try std.Io.Dir.cwd().createDirPath(init.io, parent);

            var local_store: ?Store = if (options.persistence == null)
                try Store.init(init.gpa, init.io, .{ .path = options.storage_path, .max_value_bytes = 1024 * 1024 })
            else
                null;
            defer if (local_store) |*local| local.deinit(init.io);
            const store = options.persistence orelse local_store.?.interface();
            if (resumed_tick) |tick|
                if (store.lastTick() != tick)
                    return error.ResumeCheckpointMismatch;

            const transport = try init.gpa.create(Transport);
            defer init.gpa.destroy(transport);
            transport.* = try Transport.init(init.io, .{ .address = options.address, .inherited_listener = inherited_listener });
            defer transport.deinit(init.io);
            const service = try sessions.Service.init(init.gpa, init.io, transport.transport(), .{
                .connections = options.max_players,
                .protocols = &options.protocols.values,
            });
            defer service.deinit();
            const endpoints = [_]*sessions.Service{service};
            const session_runtime = try SessionRuntime.init(init.gpa, init.io, options.session_plugins, lightning_rod.plugin.environment(.{ .sessions = service }, environment), options.session_memory_bytes, options.max_players + 8);
            defer session_runtime.deinit();
            var router = options.router;
            const session_worker = try SessionWorker.init(init.gpa, init.io, transport.transport(), .{
                .connections = options.max_players + 8,
                .max_players = options.max_players,
                .protocols = options.protocols,
                .hooks = session_runtime,
                .router = &router,
                .compression_threshold = compression,
            }, &endpoints);
            defer session_worker.deinit();

            if (incoming) |file| {
                session_worker.engine.readResume(&input.interface) catch |err| {
                    std.log.err("event=resume_failed reason={s}", .{@errorName(err)});
                    std.process.exit(1);
                };

                const native = transport.transport().inheritance.?;
                for (session_worker.engine.connections) |connection|
                    if (connection.handle) |handle|
                        try Reload.cloexec(native.descriptor(native.context, handle), true);

                file.close(init.io);
                incoming = null;
            }

            var simulation = try lightning_rod.Simulation(Plugins).init(init.gpa, init.io, store, options.memory);
            var simulation_closed = false;
            defer {
                if (!simulation_closed) simulation.close(.{
                    .clock = .awake,
                    .raw = .{ .nanoseconds = std.Io.Clock.now(.awake, init.io).nanoseconds + 5 * std.time.ns_per_s },
                }) catch |err| {
                    std.log.err("event=shutdown_failed reason={s}", .{@errorName(err)});
                    std.process.exit(1);
                };

                simulation.deinit(init.gpa);
            }
            const dependencies = lightning_rod.plugin.environment(.{ .sessions = service, .reload_request = &reload_request }, environment);
            try simulation.initialize(options.plugins, dependencies);

            if (resumed_tick != null) {
                reload_request.result = .succeeded;
                reload_request.elapsed_ms = @intCast(@divTrunc(std.Io.Clock.now(.awake, init.io).nanoseconds - reload_request.started_ns, std.time.ns_per_ms));
            }

            if (resumed_tick != null)
                std.log.info("event=reload_resumed tick={d} players={d}", .{ simulation.completed_tick, session_worker.engine.admitted });

            var worker: Worker = .{ .sessions = session_worker };
            var thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
            std.log.info("event=server_ready max_players={d}", .{options.max_players});
            var deadline = std.Io.Clock.now(.awake, init.io).nanoseconds;
            var failure: ?anyerror = null;

            running: while (!interrupted.load(.acquire) and !worker.failed.load(.acquire)) {
                service.beginTick();
                simulation.tick() catch |err| {
                    service.endTick(false);
                    failure = err;
                    std.log.err("event=simulation_failed completed_tick={d} reason={s}", .{ simulation.completed_tick, @errorName(err) });
                    break;
                };
                service.endTick(true);
                service.flush();

                if (simulation.last_tick_ns > 50 * std.time.ns_per_ms)
                    std.log.warn("event=slow_tick tick={d} ns={d} simulation_ns={d} checkpoint_ns={d} submit_ns={d}", .{
                        simulation.completed_tick,
                        simulation.last_tick_ns,
                        simulation.simulation_ns,
                        simulation.checkpoint_ns,
                        simulation.submit_ns,
                    });

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
                    std.log.info("event=reload_started tick={d}", .{simulation.completed_tick});
                    const until = std.Io.Clock.now(.awake, init.io).nanoseconds + 30 * std.time.ns_per_s;
                    simulation.close(.{ .clock = .awake, .raw = .{ .nanoseconds = until } }) catch |err| {
                        std.log.err("event=reload_checkpoint_failed reason={s}", .{@errorName(err)});
                        std.process.exit(1);
                    };
                    simulation_closed = true;
                    session_worker.requestReload(removed);

                    while (!worker.done.load(.acquire)) {
                        while (service.next()) |event|
                            if (event == .input)
                                service.release(event.input.handle);

                        if (std.Io.Clock.now(.awake, init.io).nanoseconds >= until) {
                            std.log.err("event=reload_quiesce_timeout", .{});
                            std.process.exit(1);
                        }

                        std.Io.sleep(init.io, .fromMilliseconds(1), .awake) catch {};
                    }

                    thread.join();

                    if (worker.failed.load(.acquire))
                        std.process.exit(1);

                    while (service.next()) |event|
                        if (event == .input)
                            service.release(event.input.handle);

                    attemptReload(Reload, SessionWorker, init, image, session_worker, store.lastTick(), &reload_request) catch |err| std.log.err("event=reload_fallback reason={s}", .{@errorName(err)});
                    simulation.deinit(init.gpa);
                    simulation = lightning_rod.Simulation(Plugins).init(init.gpa, init.io, store, options.memory) catch std.process.exit(1);
                    simulation_closed = false;
                    simulation.initialize(options.plugins, dependencies) catch std.process.exit(1);
                    reload_request.result = .rolled_back;
                    reload_request.elapsed_ms = @intCast(@divTrunc(std.Io.Clock.now(.awake, init.io).nanoseconds - reload_request.started_ns, std.time.ns_per_ms));
                    session_worker.restart();
                    worker = .{ .sessions = session_worker };
                    thread = std.Thread.spawn(.{}, Worker.run, .{&worker}) catch std.process.exit(1);
                    deadline = std.Io.Clock.now(.awake, init.io).nanoseconds;
                    continue;
                };

                if (simulation.completed_tick % 100 == 0)
                    std.log.info("event=tick_metrics tick={d} last_ns={d} maximum_ns={d}", .{
                        simulation.completed_tick,
                        simulation.last_tick_ns,
                        simulation.maximum_tick_ns,
                    });

                if (simulation.completed_tick % 100 == 0) {
                    if (local_store) |*local| {
                        std.log.info("event=storage_metrics index_ns={d} page_write_ns={d} value_write_ns={d} page_writes={d} value_writes={d} page_bytes={d} value_bytes={d}", .{
                            local.index_ns,
                            local.page_write_ns,
                            local.value_write_ns,
                            local.page_buffer.writes,
                            local.value_buffer.writes,
                            local.page_buffer.written_bytes,
                            local.value_buffer.written_bytes,
                        });

                        std.log.info("event=durability_metrics submitted={d} durable={d} wait_ns={d} values_ns={d} pages_ns={d} root_ns={d}", .{
                            local.last_tick,
                            local.durable_tick,
                            local.sync_wait_ns,
                            local.value_sync_ns,
                            local.page_sync_ns,
                            local.root_sync_ns,
                        });

                        std.log.info("event=read_metrics batches={d} calls={d} wait_ns={d}", .{
                            local.read_batches,
                            local.value_reads,
                            local.read_wait_ns,
                        });
                    }
                }

                deadline += 50 * std.time.ns_per_ms;
                const now = std.Io.Clock.now(.awake, init.io).nanoseconds;
                if (deadline < now)
                    deadline = now;

                while (std.Io.Clock.now(.awake, init.io).nanoseconds < deadline and !interrupted.load(.acquire) and !worker.failed.load(.acquire)) {
                    const progressed = simulation.progress() catch |err| {
                        failure = err;
                        std.log.err("event=simulation_work_failed completed_tick={d} reason={s}", .{ simulation.completed_tick, @errorName(err) });
                        break :running;
                    };

                    if (simulation.work_ns > 50 * std.time.ns_per_ms)
                        std.log.warn("event=slow_tick work_ns={d}", .{simulation.work_ns});

                    service.flush();
                    if (progressed == .progressed)
                        continue;

                    if (service.waitOutput(.{ .deadline = .{ .clock = .awake, .raw = .{ .nanoseconds = deadline } } }))
                        continue;

                    const remaining = deadline - std.Io.Clock.now(.awake, init.io).nanoseconds;

                    if (remaining > 0)
                        std.Io.sleep(init.io, .fromNanoseconds(@intCast(remaining)), .awake) catch {};
                }
            }

            simulation.close(.{
                .clock = .awake,
                .raw = .{ .nanoseconds = std.Io.Clock.now(.awake, init.io).nanoseconds + 5 * std.time.ns_per_s },
            }) catch |err| {
                std.log.err("event=shutdown_failed reason={s}", .{@errorName(err)});
                failure = err;
            };
            simulation_closed = simulation.state == .closed;
            session_worker.stop();
            const shutdown_deadline = std.Io.Clock.now(.awake, init.io).nanoseconds + 5 * std.time.ns_per_s;

            while (!worker.done.load(.acquire)) {
                while (service.next()) |event|
                    if (event == .input)
                        service.release(event.input.handle);

                if (std.Io.Clock.now(.awake, init.io).nanoseconds >= shutdown_deadline) {
                    std.log.err("event=sessions_shutdown_timeout", .{});
                    std.process.exit(1);
                }

                std.Io.sleep(init.io, .fromMilliseconds(1), .awake) catch {};
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

fn SessionThread(comptime SessionWorker: type) type {
    return struct {
        const Worker = @This();
        sessions: *SessionWorker,
        failed: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),

        fn run(self: *Worker) void {
            defer self.done.store(true, .release);

            while (true) {
                self.sessions.pump(.{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(50) } }) catch |err| {
                    std.log.err("event=sessions_failed reason={s}", .{@errorName(err)});
                    self.failed.store(true, .release);
                    interrupted.store(true, .release);
                    return;
                };
                if (self.sessions.stopping.load(.acquire) and self.sessions.drained())
                    return;

                if (self.sessions.reload_state.load(.acquire) == .parked)
                    return;
            }
        }
    };
}

fn attemptReload(comptime Reload: type, comptime SessionWorker: type, init: std.process.Init, image: Reload.Image, worker: *SessionWorker, tick: u64, request: *const reload.Request) !noreturn {
    for (worker.engine.connections) |connection| {
        if (connection.handle == null) continue;
        if (connection.protocol) |protocol| {
            const Engine = @TypeOf(worker.engine.*);
            if (!try image.supports(init.io, protocol.number, Engine.endpoint.resumeFormat(&connection.lifecycle.?))) return error.ReloadProtocolUnsupported;
        }
    }
    const file = try Reload.create();
    defer file.close(init.io);
    var buffer: [4096]u8 = undefined;
    var output = file.writer(init.io, &buffer);
    const writer = &output.interface;
    const native = worker.engine.networking.inheritance.?;
    var descriptors: [265]i32 = undefined;
    descriptors[0] = native.listener(native.context);
    var count: usize = 1;

    for (worker.engine.connections) |connection|
        if (connection.handle) |handle| {
            descriptors[count] = native.descriptor(native.context, handle);
            count += 1;
        };

    try writer.writeAll(&Reload.manifest);
    try writer.writeInt(i32, descriptors[0], .little);
    try writer.writeInt(i32, if (worker.config.compression_threshold) |threshold| @intCast(threshold) else -1, .little);
    try writer.writeInt(u64, tick, .little);
    try writer.writeInt(i96, request.started_ns, .little);
    try writer.writeInt(u16, request.reply_len, .little);
    try writer.writeAll(request.token());
    try worker.engine.writeResume(writer);
    try writer.flush();
    try Reload.seal(file);
    std.log.info("event=reload_exec tick={d} players={d}", .{ tick, count - 1 });
    return image.execute(init, file, descriptors[0..count]);
}

const Signals = if (builtin.os.tag == .windows) struct {
    fn install(_: *@This()) !void {
        if (SetConsoleCtrlHandler(handler, 1) == 0)
            return error.SignalHandlerFailed;
    }

    fn restore(_: *@This()) void {
        _ = SetConsoleCtrlHandler(handler, 0);
    }

    fn handler(code: u32) callconv(.winapi) i32 {
        if (code != 0 and code != 1 and code != 2 and code != 6)
            return 0;

        interrupted.store(true, .monotonic);
        return 1;
    }

    extern "kernel32" fn SetConsoleCtrlHandler(?*const fn (u32) callconv(.winapi) i32, i32) callconv(.winapi) i32;
} else struct {
    old_int: std.posix.Sigaction,
    old_term: std.posix.Sigaction,
    old_usr1: std.posix.Sigaction,

    fn install(self: *@This()) !void {
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
    }

    fn handler(signal: std.posix.SIG) callconv(.c) void {
        if (signal == .USR1) {
            reload_requested.store(true, .monotonic);
        } else {
            interrupted.store(true, .monotonic);
        }
    }
};
