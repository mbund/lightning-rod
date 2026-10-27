const std = @import("std");
const lightning_rod = @import("lightning_rod");
const storage = @import("storage");
const reload = @import("reload");
const sessions = @import("sessions");
const execve = @import("reload_execve");
const timing = @import("timing.zig");
const Shutdown = @import("shutdown.zig").Shutdown;
const Signals = @import("signals.zig").Signals;
const host = @import("host.zig");

pub fn Process(comptime Plugins: type, comptime Network: type) type {
    return struct {
        const Self = @This();
        const Simulation = lightning_rod.Simulation(Plugins);
        pub const Options = struct {
            plugins: Plugins,
            network: Network.Configuration,
            registry: ?*lightning_rod.metrics.Registry = null,
            metrics: lightning_rod.metrics.Registry.Configuration = .{ .capacity = 512 },
            metrics_export: ?lightning_rod.metrics.Exporter.Configuration = null,
            storage_path: []const u8 = "lightning-rod-data/world",
            storage_readers: usize = 1,
            persistence: ?*storage.Store = null,
            simulation: lightning_rod.Configuration = .{},
            reload: ?execve.Configuration = .{},
            startup: ?timing.Startup = null,
        };

        allocator: std.mem.Allocator,
        memory: *lightning_rod.Memory,
        simulation_allocator: std.mem.Allocator,
        export_allocator: std.mem.Allocator,
        executable: ?[]u8,
        io: std.Io,
        startup: timing.Startup,
        reloading: execve.Service,
        interrupted: Shutdown,
        reload_requested: std.atomic.Value(bool) = .init(false),
        signals: Signals = undefined,
        incoming: ?execve.Incoming,
        owned_registry: ?lightning_rod.metrics.Registry,
        owned_store: ?storage.Store,
        store: *storage.Store,
        network: *Network,
        simulation: *Simulation,
        exporter: ?lightning_rod.metrics.Exporter,
        descriptors: []i32,
        startup_total: lightning_rod.metrics.Timer,
        startup_cpu: lightning_rod.metrics.Timer,
        reload_duration: lightning_rod.metrics.Timer,
        reload_before: lightning_rod.metrics.Timer,
        reload_replacement: lightning_rod.metrics.Timer,
        reload_after: lightning_rod.metrics.Timer,
        reload_checkpoint: lightning_rod.metrics.Timer,
        reload_quiesce: lightning_rod.metrics.Timer,

        pub fn init(memory: *lightning_rod.Memory, process_init: std.process.Init, options: Options, environment: anytype) !*Self {
            const allocator = memory.allocator("host");
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .memory = memory,
                .simulation_allocator = memory.allocator("simulation"),
                .export_allocator = memory.allocator("metrics_export"),
                .executable = null,
                .io = process_init.io,
                .startup = options.startup orelse timing.Startup.capture(process_init.io),
                .reloading = undefined,
                .interrupted = .{ .io = process_init.io },
                .incoming = null,
                .owned_registry = null,
                .owned_store = null,
                .store = undefined,
                .network = undefined,
                .simulation = undefined,
                .exporter = null,
                .descriptors = undefined,
                .startup_total = undefined,
                .startup_cpu = undefined,
                .reload_duration = undefined,
                .reload_before = undefined,
                .reload_replacement = undefined,
                .reload_after = undefined,
                .reload_checkpoint = undefined,
                .reload_quiesce = undefined,
            };
            if (options.reload != null) Network.retainReload(execve);
            var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const executable = if (options.reload) |config| config.executable orelse executable_buffer[0..try std.process.executablePath(process_init.io, &executable_buffer)] else null;
            self.executable = if (executable) |path| try allocator.dupe(u8, path) else null;
            errdefer if (self.executable) |path| allocator.free(path);
            self.reloading = try execve.Service.init(allocator, process_init, self.executable);
            errdefer self.reloading.deinit();
            const request = &self.reloading.request;
            self.signals = .{ .shutdown = &self.interrupted, .reload_requested = &self.reload_requested };
            try self.signals.install();
            errdefer self.signals.restore();
            self.incoming = try execve.incoming(process_init);
            errdefer if (self.incoming) |value| value.file.close(process_init.io);
            var input_buffer: [4096]u8 = undefined;
            var input: std.Io.File.Reader = undefined;
            var resumed_tick: ?u64 = null;
            var handoff: ?lightning_rod.Resume = null;
            if (self.incoming) |value| {
                input = value.file.reader(process_init.io, &input_buffer);
                const header = try reload.handoff.Header.read(&input.interface, &request.reply_bytes);
                resumed_tick = header.tick;
                request.started_ns = header.started_ns;
                request.reply_len = @intCast(header.reply_token.len);
                request.sequence = 1;
                handoff = .{ .reader = &input.interface, .file_reader = &input };
            }
            self.owned_registry = if (options.registry == null) try .init(memory.allocator("metrics"), process_init.io, options.metrics) else null;
            errdefer if (self.owned_registry) |*value| value.deinit();
            const registry = options.registry orelse &self.owned_registry.?;
            self.startup_total = try registry.timer(.{ .name = "server.startup", .description = "Process entry through server readiness" });
            self.startup_cpu = try registry.timer(.{ .name = "server.startup.cpu", .description = "Startup work on the owning thread", .clock = .thread_cpu });
            self.reload_duration = try registry.timer(.{ .name = "server.reload", .description = "Complete successful process replacement" });
            self.reload_before = try registry.timer(.{ .name = "server.reload.before_exec", .description = "Reload request through old process execution" });
            self.reload_replacement = try registry.timer(.{ .name = "server.reload.replacement", .description = "Executable replacement and process entry" });
            self.reload_after = try registry.timer(.{ .name = "server.reload.after_exec", .description = "Replacement process entry through readiness" });
            self.reload_checkpoint = try registry.timer(.{ .name = "server.reload.checkpoint", .description = "Save complete simulation and wait for durability" });
            self.reload_quiesce = try registry.timer(.{ .name = "server.reload.quiesce", .description = "Pause network and terrain components" });
            self.owned_store = if (options.persistence == null) try storage.Store.init(memory.allocator("storage"), process_init.io, .{ .path = options.storage_path, .metrics = registry, .readers = options.storage_readers }) else null;
            errdefer if (self.owned_store) |*store| store.deinit();
            self.store = options.persistence orelse &self.owned_store.?;
            if (resumed_tick) |tick| if (tick != self.store.lastTick()) return error.ResumeCheckpointMismatch;
            var network_configuration = options.network;
            if (network_configuration.inherited_listener == null) network_configuration.inherited_listener = try host.inheritedListener(process_init);
            self.network = try Network.init(allocator, process_init.io, network_configuration, .{ .memory = memory, .metrics = registry, .handoff = if (handoff) |*value| value else null });
            errdefer self.network.deinit();
            self.descriptors = try allocator.alloc(i32, options.network.max_players + 9);
            errdefer allocator.free(self.descriptors);
            var configuration = options.simulation;
            configuration.metrics.parent = registry;
            const simulation_allocator = self.simulation_allocator;
            self.simulation = try Simulation.init(simulation_allocator, process_init.io, self.store, configuration);
            errdefer {
                if (self.simulation.state != .closed) timing.closeSimulation(self.simulation, process_init.io) catch |err| std.debug.panic("simulation shutdown: {t}", .{err});
                self.simulation.deinit(simulation_allocator);
            }
            const plugins = lightning_rod.plugin.replace(options.plugins, .{
                lightning_rod.plugin.configured(sessions.World, .{ .endpoint = self.network.core.routing.endpoints[0] }),
                lightning_rod.plugin.configured(reload.Reload, .{ .request = request }),
            });
            try self.simulation.initialize(plugins, lightning_rod.plugin.environment(.{ .memory = memory, .metrics = &self.simulation.metrics }, environment));
            self.exporter = if (options.metrics_export) |config| try .init(self.export_allocator, process_init.io, &self.simulation.metrics, config, 0, &.{ "server.tick", "server.work" }) else null;
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.exporter) |*value| value.deinit(self.export_allocator, self.io, &self.simulation.metrics) catch |err| std.debug.panic("metrics shutdown: {t}", .{err});
            if (self.simulation.state != .closed) timing.closeSimulation(self.simulation, self.io) catch |err| std.debug.panic("simulation shutdown: {t}", .{err});
            self.simulation.deinit(self.simulation_allocator);
            self.allocator.free(self.descriptors);
            self.network.deinit();
            if (self.owned_store) |*store| store.deinit();
            if (self.owned_registry) |*value| value.deinit();
            if (self.incoming) |value| value.file.close(self.io);
            self.signals.restore();
            self.reloading.deinit();
            if (self.executable) |path| self.allocator.free(path);
            self.allocator.destroy(self);
        }

        pub fn ready(self: *Self) !void {
            self.memory.seal();
            const captured = timing.Startup.capture(self.io);
            self.startup_total.observe(@intCast(captured.wall_ns - self.startup.wall_ns));
            self.startup_cpu.observe(@intCast(captured.cpu_ns - self.startup.cpu_ns));
            if (self.incoming) |value| {
                const request = &self.reloading.request;
                const executing = value.executing_ns;
                if (request.started_ns > executing or executing > self.startup.wall_ns or self.startup.wall_ns > captured.wall_ns) return error.InvalidResume;
                request.result = .succeeded;
                self.reload_duration.observe(@intCast(captured.wall_ns - request.started_ns));
                self.reload_before.observe(@intCast(executing - request.started_ns));
                self.reload_replacement.observe(@intCast(self.startup.wall_ns - executing));
                self.reload_after.observe(@intCast(captured.wall_ns - self.startup.wall_ns));
                request.elapsed_ms = @intCast(@divTrunc(captured.wall_ns - request.started_ns, std.time.ns_per_ms));
                std.log.info("event=reload_resumed tick={d}", .{self.simulation.completed_tick});
                value.file.close(self.io);
                self.incoming = null;
            }
            try self.startup.publish(self.io, captured);
            std.log.info("event=server_ready startup_ms={d:.3}", .{@as(f64, @floatFromInt(captured.wall_ns - self.startup.wall_ns)) / std.time.ns_per_ms});
        }

        pub fn save(self: *Self, deadline: std.Io.Clock.Timestamp) !void {
            const checkpoint = self.reload_checkpoint.start();
            try self.simulation.save(deadline);
            checkpoint.end();
            if (self.exporter) |*value| try value.finish(self.io);
            std.log.info("event=reload_started tick={d}", .{self.simulation.completed_tick});
        }

        pub fn executeReload(self: *Self, image: execve.Image) !noreturn {
            const file = try execve.create();
            defer file.close(self.io);
            var buffer: [4096]u8 = undefined;
            var output = file.writer(self.io, &buffer);
            const request = &self.reloading.request;
            const header: reload.handoff.Header = .{ .tick = self.store.lastTick(), .started_ns = request.started_ns, .reply_token = request.token() };
            try header.write(&output.interface);
            const count = try self.network.core.writeReload(self.io, image.compatibility(), &output.interface, self.descriptors);
            try output.interface.flush();
            try execve.seal(file);
            if (self.exporter) |*value| try value.capture(self.io);
            std.log.info("event=reload_exec tick={d}", .{self.simulation.completed_tick});
            return self.reloading.execute(image, self.io, file, self.descriptors[0..count]);
        }
    };
}
