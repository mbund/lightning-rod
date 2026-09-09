const std = @import("std");
const authentication = @import("authentication.zig");
const io_uring_transport = @import("io_uring_transport.zig");
const session_worker = @import("session_worker.zig");
const local_packs = @import("local_packs.zig");
const logging_stdout = @import("logging_stdout.zig");
const reexec = @import("reexec.zig");
const shutdown_posix = @import("shutdown_posix.zig");
const tui_terminal = @import("tui_terminal.zig");
const lightning_rod = @import("lightning_rod");
const tui = @import("lightning_rod_tui");
const core = lightning_rod.core;
const core_exchange = lightning_rod.core_exchange;
const logging = lightning_rod.logging;
const metrics = lightning_rod.metrics;
const persistence = lightning_rod.persistence;
const plugin = lightning_rod.plugin;
const plugin_profiler = lightning_rod.plugin_profiler;
const protocol_versions = lightning_rod.protocol_versions;
const runtime = lightning_rod.runtime;
const sessions = lightning_rod.sessions;

pub const Options = struct {
    memory_bytes: usize = 128 * 1024 * 1024,
    address: []const u8 = "0.0.0.0",
    port: u16 = 25565,
    connection_capacity: usize = 64,
    exchange_capacity: usize = 64,
    transport_event_capacity: usize = 192,
    input_pages: usize = 64,
    page_bytes: usize = 32 * 1024,
    output_pages: usize = 128,
    output_page_bytes: usize = 32 * 1024,
    output_pages_per_connection: usize = 2,
    session_input_exchange_pages: u16 = 16,
    session_output_exchange_pages: u16 = 8,
    session_exchange_messages: u16 = 4_096,
    ring_entries: u16 = 256,
    tick_memory_bytes: usize = 1 * 1024 * 1024,
    log_records: usize = 512,
    log_message_bytes: usize = 1_024,
    log_priority_reserve: usize = 64,
    terminal_bytes: usize = 64 * 1024,
    maximum_arguments: usize = 32,
    maximum_in_flight_reads: usize = 128,
    maximum_packs: usize = 4_096,
    maximum_path_bytes: usize = 512,
    fail_on_tick_deadline: bool = false,
    root_path: []const u8 = "lightning-rod-data/lightning-rod.root",
    persistence: persistence.Configuration = .{
        .maximum_checkpoint_records = 256,
        .maximum_requests = 256,
        .maximum_namespace_bytes = 40,
        .maximum_key_bytes = 32,
        .maximum_value_bytes = 512 * 1024,
        .maximum_checkpoint_bytes = 2 * 1024 * 1024,
    },
};

pub fn resumeManifest(comptime protocols: anytype, comptime options: Options) reexec.Manifest.Record {
    const SessionTable = sessions.Table(options.connection_capacity, options.exchange_capacity);
    const continuation_bytes = sessions.Continuation.maximum_bytes;
    const image_bytes = reexec.Handoff.header_bytes + options.connection_capacity *
        (reexec.Handoff.record_bytes + options.page_bytes +
            options.output_pages_per_connection * options.output_page_bytes + continuation_bytes);

    return reexec.Manifest.make(
        protocol_versions.numbers(protocols),
        SessionTable.resume_id,
        SessionTable.resume_version,
        options.connection_capacity,
        continuation_bytes,
        image_bytes,
    );
}

pub fn Server(
    comptime protocols: anytype,
    comptime Selection: type,
    comptime options: Options,
) type {
    _ = protocol_versions.numbers(protocols);
    const Transport = io_uring_transport.Transport(.{
        .connections = options.connection_capacity,
        .input_pages = options.input_pages,
        .page_bytes = options.page_bytes,
        .output_pages = options.output_pages,
        .output_page_bytes = options.output_page_bytes,
        .output_pages_per_connection = options.output_pages_per_connection,
        .event_capacity = options.transport_event_capacity,
        .completion_batch = options.exchange_capacity,
        .ring_entries = options.ring_entries,
    });
    const SessionTable = sessions.Table(options.connection_capacity, options.exchange_capacity);
    const SessionExchange = core_exchange.SessionExchange(.{
        .to_core_pages = options.session_input_exchange_pages,
        .to_sessions_pages = options.session_output_exchange_pages,
        .to_core_page_bytes = options.output_page_bytes,
        .to_sessions_page_bytes = lightning_rod.minecraft_session.Codec.max_packet_bytes,
        .to_core_messages = options.session_exchange_messages,
        .to_sessions_messages = options.session_exchange_messages,
    });
    const SessionWorker = session_worker.Worker(
        Transport,
        SessionTable,
        SessionExchange,
        options.exchange_capacity,
        options.connection_capacity,
        options.output_pages_per_connection * options.output_page_bytes,
        sessions.Continuation.maximum_bytes,
        1,
    );
    const PackDriver = local_packs.Driver(.{
        .maximum_in_flight_reads = options.maximum_in_flight_reads,
        .maximum_packs = options.maximum_packs,
        .maximum_path_bytes = options.maximum_path_bytes,
    });
    const Terminal = tui_terminal.Terminal(options.terminal_bytes);
    const Core = core.Server(Selection);
    const tick_memory_bytes = std.math.add(usize, options.tick_memory_bytes, plugin.minimumTickScratchBytes(Selection)) catch
        @compileError("tick scratch capacity exceeds addressable memory");
    const Reloader = reexec.ProductionWorker(SessionWorker, options.maximum_arguments);
    const has_tui = plugin.indexOfId(Selection, tui.Plugin.id) != null;
    const continuation_bytes = sessions.Continuation.maximum_bytes;
    const image_bytes = reexec.Handoff.header_bytes + options.connection_capacity *
        (reexec.Handoff.record_bytes + options.page_bytes +
            options.output_pages_per_connection * options.output_page_bytes + continuation_bytes);
    const MemoryPlan = struct {
        limit: usize,
        core: usize,
        host: usize,
        transport: usize,
        sessions: usize,
        persistence_bytes: usize,
        reload: usize,
        reload_transition: usize,
        logging_bytes: usize,

        fn calculate() !@This() {
            const checkpoint = try persistence.maximumCheckpointBytes(options.persistence);
            const index = try persistence.Store.maximumDiskIndexBytes(options.persistence, .live);
            const recovery_index = try persistence.Store.maximumDiskIndexBytes(options.persistence, .recovery);
            const compaction_index = try persistence.Store.maximumDiskIndexBytes(options.persistence, .compaction);
            const transport_bytes = @sizeOf(Transport);
            const sessions_bytes = try sum(&.{
                @sizeOf(SessionTable),
                @sizeOf(SessionExchange),
                @sizeOf(SessionWorker),
                lightning_rod.minecraft_session.Codec.max_packet_bytes,
            });
            const persistence_bytes = try sum(&.{
                recovery_index,
                compaction_index,
                index,
                options.persistence.maximum_value_bytes,
                checkpoint,
                @sizeOf(PackDriver),
                @sizeOf(persistence.Access),
                options.maximum_path_bytes,
            });
            const reload_bytes = try std.math.add(usize, @sizeOf(Reloader), continuation_bytes);
            const logging_bytes = try std.math.add(
                usize,
                try logging.Queue.reservedBytes(options.log_records, options.log_message_bytes),
                if (has_tui) @sizeOf(Terminal) else 0,
            );
            const host_bytes = try sum(&.{ transport_bytes, sessions_bytes, persistence_bytes, reload_bytes, image_bytes, logging_bytes });
            const minimum_core = try std.math.add(usize, tick_memory_bytes, 1024 * 1024);
            if (host_bytes > options.memory_bytes or options.memory_bytes - host_bytes < minimum_core)
                return error.ConfiguredMemoryMaximumExceeded;
            return .{
                .limit = options.memory_bytes,
                .core = options.memory_bytes - host_bytes,
                .host = host_bytes,
                .transport = transport_bytes,
                .sessions = sessions_bytes,
                .persistence_bytes = persistence_bytes,
                .reload = reload_bytes,
                .reload_transition = image_bytes,
                .logging_bytes = logging_bytes,
            };
        }

        fn sum(values: []const usize) !usize {
            var total: usize = 0;
            for (values) |value| total = try std.math.add(usize, total, value);
            return total;
        }
    };

    return struct {
        const Self = @This();

        pub const resume_manifest = resumeManifest(protocols, options);

        pub fn run(init: std.process.Init, selected: Selection, meta: anytype, auth_provider: ?lightning_rod.session_api.Authentication) !void {
            serve(init, selected, meta, auth_provider) catch |err| {
                report(init.io, err);
                return err;
            };
        }

        fn serve(init: std.process.Init, selected: Selection, meta: anytype, auth_provider: ?lightning_rod.session_api.Authentication) !void {
            var io = init.io;
            const memory = try MemoryPlan.calculate();
            const planned_storage = try lightning_rod.preallocated.alignedAlloc(
                u8,
                std.heap.page_allocator,
                .@"64",
                memory.limit,
            );
            // The whole reservation is owned by FixedBufferAllocator.  Avoid
            // Allocator.free's ReleaseSafe poison pass over otherwise untouched
            // pages; this defer runs after every allocator-backed teardown below.
            defer std.heap.page_allocator.rawFree(planned_storage, .@"64", @returnAddress());
            var planned = std.heap.FixedBufferAllocator.init(planned_storage);
            const allocator = planned.allocator();
            var runtime_metrics: metrics.Runtime = .{};
            runtime_metrics.setMemory(.{
                .limit = memory.limit,
                .planned = memory.host + memory.core,
                .host = memory.host,
                .transport = memory.transport,
                .sessions = memory.sessions,
                .persistence = memory.persistence_bytes,
                .reload = memory.reload,
                .reload_transition = memory.reload_transition,
                .logging = memory.logging_bytes,
            });
            const arguments = try init.minimal.args.toSlice(init.arena.allocator());
            if (arguments.len == 0 or arguments.len > options.maximum_arguments)
                return error.InvalidReloadArguments;
            const image = try lightning_rod.preallocated.alloc(u8, allocator, image_bytes);
            var inherited = try reexec.inherited(arguments, image);
            errdefer if (inherited) |*resumed| resumed.close();
            var logs = try logging.Queue.init(
                allocator,
                options.log_records,
                options.log_message_bytes,
                options.log_priority_reserve,
            );
            logging.install(&logs);
            defer logging.uninstall(&logs);
            var stdout = logging_stdout.Stdout.init(io, &logs);
            defer stdout.flush();
            std.log.info(
                "event=memory_plan limit_bytes={d} core_bytes={d} host_bytes={d} transport_bytes={d} sessions_bytes={d} persistence_bytes={d} reload_bytes={d} reload_transition_bytes={d} logging_bytes={d}",
                .{ memory.limit, memory.core, memory.host, memory.transport, memory.sessions, memory.persistence_bytes, memory.reload, memory.reload_transition, memory.logging_bytes },
            );
            std.log.info(
                "event=session_memory table_bytes={d} exchange_bytes={d} worker_bytes={d} packet_scratch_bytes={d}",
                .{ @sizeOf(SessionTable), @sizeOf(SessionExchange), @sizeOf(SessionWorker), lightning_rod.minecraft_session.Codec.max_packet_bytes },
            );
            var storage = try Storage.init(allocator, io);
            defer storage.deinit(allocator);
            storage.packs.bindMetrics(&runtime_metrics);
            runtime_metrics.setPersistenceKeys(storage.store.liveRecords(), 0);
            const transport = try initializeTransport(allocator, &inherited);
            defer transport.deinit();
            const table = try lightning_rod.preallocated.create(SessionTable, allocator);
            table.initialize();
            var auth = authentication.Offline.init(&io);
            table.setAuthentication(auth_provider orelse auth.interface(), 30 * std.time.ns_per_s);
            var clock = Clock{ .io = io };
            var session_settings = sessions.Sessions.init(protocol_versions.defaultNumber(protocols));
            const server = try Core.create(allocator, io, storage.store.interface(), .{
                .memory_bytes = memory.core,
                .tick_bytes = tick_memory_bytes,
            }, clock.counter());
            var runtime_started = false;
            defer if (!runtime_started) closeStartup(server, io, &stdout);
            try server.initialize(selected, .{ .sessions = &session_settings, .persistence = storage.access, .runtime_metrics = &runtime_metrics, .meta = meta });
            const core_memory = server.memory();
            std.log.info(
                "event=core_memory capacity_bytes={d} generation_bytes={d} tick_bytes={d} headroom_bytes={d}",
                .{ core_memory.capacity_bytes, core_memory.generation_used_bytes, core_memory.tick_capacity_bytes, core_memory.headroomBytes() },
            );
            sessions.Catalog(protocols).install(table, try session_settings.configurationPlan());
            if (!table.setCompressionThreshold(session_settings.compressionThreshold()))
                return error.InvalidCompressionThreshold;
            const shared = try lightning_rod.preallocated.create(SessionExchange, allocator);
            shared.initialize();
            var input = core_exchange.InputProducer(SessionExchange).init(shared);
            const output_lanes = [_]*SessionExchange{shared};
            const worker = try lightning_rod.preallocated.create(SessionWorker, allocator);
            worker.* = try SessionWorker.init(
                transport,
                table,
                &output_lanes,
                input.ingress(),
                io,
                .{ .context = &clock, .now_ns = Clock.now },
                session_settings.statusProvider(),
            );
            worker.bindCore(server.sessionsBoundary());
            worker.bindMetrics(&runtime_metrics);
            var reload = try Reload.init(allocator, init.minimal.environ.block.slice, arguments, image, worker, server);
            defer reload.deinit(allocator);
            try reload.restore(&inherited);
            try drive(init, allocator, &logs, &stdout, storage.store, storage.packs, worker, shared, server, &runtime_metrics, &reload.value, &runtime_started);
        }

        fn closeStartup(server: *Core, io: std.Io, stdout: *logging_stdout.Stdout) void {
            const deadline = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + 5 * std.time.ns_per_s;
            _ = server.beginClose(deadline);
            while (server.closeProgress() != .complete) {
                if (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds >= deadline) {
                    std.log.err("event=plugin_startup_cleanup_timeout", .{});
                    stdout.flush();
                    std.process.exit(1);
                }
                std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {
                    stdout.flush();
                    std.process.exit(1);
                };
            }
        }

        fn initializeTransport(allocator: std.mem.Allocator, inherited: *?reexec.Resume) !*Transport {
            const transport = try lightning_rod.preallocated.create(Transport, allocator);
            if (inherited.*) |resumed|
                try transport.initializeResumed(resumed.listener, 0)
            else
                try transport.initialize(.{ .address = try std.Io.net.IpAddress.parse(options.address, options.port) });
            return transport;
        }

        fn drive(
            init: std.process.Init,
            allocator: std.mem.Allocator,
            logs: *logging.Queue,
            stdout: *logging_stdout.Stdout,
            store: *persistence.Store,
            packs: *PackDriver,
            worker: *SessionWorker,
            shared: *SessionExchange,
            server: *Core,
            runtime_metrics: *metrics.Runtime,
            reload: *Reloader,
            runtime_started: *bool,
        ) !void {
            var input = core_exchange.InputConsumer(SessionExchange).init(shared);
            server.bindInputDrain(input.inputDrain());
            var output = try worker.outputLane(shared);
            const packet_scratch = try lightning_rod.preallocated.alloc(u8, allocator, lightning_rod.minecraft_session.Codec.max_packet_bytes);
            var packets = sessions.PacketBridge.init(
                server.sessionsBoundary(),
                output.egress(),
                .{ .context = worker, .state = packet_bridgeOutputState },
                packet_scratch,
            );
            server.bindPacketRuntime(packets.runtime());
            try worker.start();
            defer {
                worker.stop();
                worker.deinit();
            }
            const core_cpu = try pinCoreThread();
            std.log.info("event=core_cpu_affinity cpu={d}", .{core_cpu});
            var signals: shutdown_posix.Signals = .{};
            try signals.init();
            defer signals.deinit();
            if (comptime has_tui) {
                const terminal = try lightning_rod.preallocated.create(Terminal, allocator);
                terminal.* = Terminal.init(
                    init.io,
                    server.get(tui.Plugin),
                    runtime_metrics,
                    store,
                    0,
                    .{},
                );
                const enabled = try tuiRequested(init);
                if (enabled) try terminal.enter();
                defer if (enabled) terminal.leave() catch {};
                var auxiliary = [_]runtime.Backend{terminal.backend()};
                runtime_started.* = true;
                return runRuntime(init.io, worker, packs, server, reload, signals.interface(), if (enabled) &auxiliary else &.{}, if (enabled) terminal.loggingBackend(logs) else stdout.interface());
            }
            runtime_started.* = true;
            return runRuntime(init.io, worker, packs, server, reload, signals.interface(), &.{}, stdout.interface());
        }

        fn runRuntime(
            io: std.Io,
            worker: *SessionWorker,
            packs: *PackDriver,
            server: *Core,
            reload: *Reloader,
            shutdown: runtime.Shutdown,
            auxiliary: []runtime.Backend,
            log_backend: runtime.Backend,
        ) void {
            runtime.run(.{
                .io = io,
                .transport = worker.backend(),
                .persistence = packs.interface(),
                .logging = log_backend,
                .auxiliary_backends = auxiliary,
                .shutdown = shutdown,
                .sessions = worker.runtime(),
                .core = server.runtime(),
                .reloader = reload.operation(),
                .limits = .{ .fail_on_tick_deadline = options.fail_on_tick_deadline },
            }) catch |err| {
                std.log.err("event=server_runtime_failed error={s}", .{@errorName(err)});
                _ = log_backend.complete(io, options.log_records);
                _ = log_backend.submit(io);
                for (auxiliary) |backend| _ = backend.beginShutdown(io);
                std.process.exit(1);
            };
        }

        fn packet_bridgeOutputState(raw: *const anyopaque, connection: lightning_rod.transport.Connection) ?lightning_rod.SessionOutputState {
            const worker: *const SessionWorker = @ptrCast(@alignCast(raw));
            return worker.outputState(connection);
        }

        fn pinCoreThread() !usize {
            const allowed = try std.posix.sched_getaffinity(0);
            const word_bits = @bitSizeOf(usize);
            var selected: ?usize = null;
            for (allowed, 0..) |word, word_index| {
                if (word == 0) continue;
                selected = word_index * word_bits + @ctz(word);
                break;
            }
            const cpu = selected orelse return error.NoAllowedCpu;
            var target = [_]usize{0} ** allowed.len;
            target[cpu / word_bits] = @as(usize, 1) << @intCast(cpu % word_bits);
            try std.os.linux.sched_setaffinity(0, &target);
            return cpu;
        }

        const Storage = struct {
            store: *persistence.Store,
            source: *persistence.Store,
            output: *persistence.Store,
            value: []u8,
            recovery: []u8,
            packs: *PackDriver,
            access: *persistence.Access,
            path: []u8,

            fn init(allocator: std.mem.Allocator, io: std.Io) !Storage {
                const checkpoint_bytes = try persistence.maximumCheckpointBytes(options.persistence);
                const packs = try lightning_rod.preallocated.create(PackDriver, allocator);
                const store = try persistence.Store.initDiskIndex(allocator, options.persistence, .live, packs.diskIndexIo());
                const source = try persistence.Store.initDiskIndex(allocator, options.persistence, .recovery, packs.diskIndexIo());
                const output = try persistence.Store.initDiskIndex(allocator, options.persistence, .compaction, packs.compactionIndexIo());
                const value = try allocator.alloc(u8, options.persistence.maximum_value_bytes);
                const recovery = try allocator.alloc(u8, checkpoint_bytes);
                const path = try allocator.alloc(u8, options.maximum_path_bytes);
                const cwd = std.Io.Dir.cwd();
                const parent_path = std.fs.path.dirname(options.root_path) orelse ".";
                try cwd.createDirPath(io, parent_path);
                var parent = try cwd.openDir(io, parent_path, .{});
                defer parent.close(io);
                const parent_length = try parent.realPath(io, path);
                const suffix = try std.fmt.bufPrint(path[parent_length..], "/{s}", .{std.fs.path.basename(options.root_path)});
                try packs.init(io, path[0 .. parent_length + suffix.len], store, recovery);
                errdefer packs.deinit();
                try packs.configureMaintenance(source, output, value, recovery);
                const access = try lightning_rod.preallocated.create(persistence.Access, allocator);
                access.* = persistence.Access.init(.{
                    .interface = store.interface(),
                    .loader = packs.loader(),
                    .maximum_checkpoint_records = options.persistence.maximum_checkpoint_records,
                });
                return .{ .store = store, .source = source, .output = output, .value = value, .recovery = recovery, .packs = packs, .access = access, .path = path };
            }

            fn deinit(self: *Storage, allocator: std.mem.Allocator) void {
                self.packs.deinit();
                allocator.free(self.path);
                allocator.free(self.recovery);
                allocator.free(self.value);
            }
        };

        const Reload = struct {
            continuation: []u8,
            candidate: reexec.SelfCandidate(options.maximum_arguments),
            value: Reloader,

            fn init(allocator: std.mem.Allocator, environment: [:null]const ?[*:0]const u8, arguments: []const [:0]const u8, image: []u8, worker: *SessionWorker, server: *Core) !Reload {
                const continuation = try lightning_rod.preallocated.alloc(u8, allocator, continuation_bytes);
                var self: Reload = .{
                    .continuation = continuation,
                    .candidate = .{ .executable = arguments[0], .arguments = arguments, .expected = &resume_manifest },
                    .value = undefined,
                };
                self.value.init(.{
                    .worker = worker,
                    .core = server.runtime(),
                    .candidate = self.candidate.candidate(),
                    .candidate_fd = &self.candidate.validated_fd,
                    .arguments = arguments,
                    .environment = environment,
                    .image = image,
                    .continuation = continuation,
                });
                return self;
            }

            fn deinit(self: *Reload, allocator: std.mem.Allocator) void {
                allocator.free(self.continuation);
            }

            fn restore(self: *Reload, inherited: *?reexec.Resume) !void {
                if (inherited.*) |*resumed| {
                    var image = resumed.*;
                    inherited.* = null;
                    try self.value.restore(&image);
                }
            }
        };

        const Clock = struct {
            io: std.Io,

            fn counter(self: *const Clock) plugin_profiler.Counter {
                return .{ .context = self, .read_fn = now };
            }

            fn interface(self: *const Clock) sessions.Clock {
                return .{ .context = self, .vtable = &.{ .now_ns = now } };
            }

            fn now(context: *const anyopaque) u64 {
                const self: *const Clock = @ptrCast(@alignCast(context));
                return @intCast(std.Io.Clock.Timestamp.now(self.io, .awake).raw.nanoseconds);
            }
        };

        fn tuiRequested(init: std.process.Init) !bool {
            const arguments = try init.minimal.args.toSlice(init.arena.allocator());
            for (arguments[1..]) |argument| if (std.mem.eql(u8, argument, "--tui")) return true;
            return false;
        }

        fn report(io: std.Io, err: anyerror) void {
            var storage: [256]u8 = undefined;
            const message = std.fmt.bufPrint(&storage, "lightning_rod server failed: {s}\n", .{@errorName(err)}) catch "lightning_rod server failed\n";
            std.Io.File.stderr().writeStreamingAll(io, message) catch {};
        }
    };
}
