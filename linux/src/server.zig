const std = @import("std");
const authentication = @import("authentication.zig");
const io_uring_transport = @import("io_uring_transport.zig");
const local_packs = @import("local_packs.zig");
const logging_stdout = @import("logging_stdout.zig");
const reexec = @import("reexec.zig");
const shutdown_posix = @import("shutdown_posix.zig");
const tui_terminal = @import("tui_terminal.zig");
const lightning_rod = @import("lightning_rod");
const tui = @import("lightning_rod_tui");
const core = lightning_rod.core;
const logging = lightning_rod.logging;
const persistence = lightning_rod.persistence;
const plugin = lightning_rod.plugin;
const plugin_profiler = lightning_rod.plugin_profiler;
const protocol_versions = lightning_rod.protocol_versions;
const runtime = lightning_rod.runtime;
const sessions = lightning_rod.sessions;

pub const Options = struct {
    address: []const u8 = "0.0.0.0",
    port: u16 = 25565,
    connection_capacity: usize = 80,
    exchange_capacity: usize = 1_024,
    input_pages: usize = 80,
    page_bytes: usize = 60 * 1024,
    output_pages: usize = 128,
    output_page_bytes: usize = 64 * 1024,
    output_pages_per_connection: usize = 8,
    ring_entries: u16 = 512,
    core_memory_bytes: usize = 512 * 1024 * 1024,
    tick_memory_bytes: usize = 4 * 1024 * 1024,
    log_records: usize = 512,
    log_message_bytes: usize = 1_024,
    log_priority_reserve: usize = 64,
    terminal_bytes: usize = 64 * 1024,
    maximum_arguments: usize = 32,
    maximum_in_flight_reads: usize = 64,
    maximum_packs: usize = 4_096,
    maximum_path_bytes: usize = 512,
    root_path: []const u8 = "lightning-rod.root",
    persistence: persistence.Configuration = .{
        .maximum_keys = 16_384,
        .maximum_checkpoint_records = 64,
        .maximum_requests = 128,
        .maximum_namespace_bytes = 64,
        .maximum_key_bytes = 64,
        .maximum_value_bytes = 512 * 1024,
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
        .event_capacity = options.exchange_capacity,
        .completion_batch = options.exchange_capacity,
        .ring_entries = options.ring_entries,
    });
    const SessionTable = sessions.Table(options.connection_capacity, options.exchange_capacity);
    const PackDriver = local_packs.Driver(.{
        .maximum_in_flight_reads = options.maximum_in_flight_reads,
        .maximum_packs = options.maximum_packs,
        .maximum_path_bytes = options.maximum_path_bytes,
    });
    const Terminal = tui_terminal.Terminal(options.terminal_bytes);
    const Core = core.Server(Selection);
    const Reloader = reexec.Production(Transport, SessionTable, options.maximum_arguments);
    const has_tui = plugin.indexOfId(Selection, tui.Plugin.id) != null;
    const continuation_bytes = sessions.Continuation.maximum_bytes;
    const image_bytes = reexec.Handoff.header_bytes + options.connection_capacity *
        (reexec.Handoff.record_bytes + options.page_bytes +
            options.output_pages_per_connection * options.output_page_bytes + continuation_bytes);

    return struct {
        const Self = @This();

        pub const resume_manifest = resumeManifest(protocols, options);

        pub fn run(init: std.process.Init, selected: Selection, meta: anytype) !void {
            serve(init, selected, meta) catch |err| {
                report(init.io, err);
                return err;
            };
        }

        fn serve(init: std.process.Init, selected: Selection, meta: anytype) !void {
            var io = init.io;
            const arguments = try init.minimal.args.toSlice(init.arena.allocator());
            if (arguments.len == 0 or arguments.len > options.maximum_arguments)
                return error.InvalidReloadArguments;
            const image = try init.gpa.alloc(u8, image_bytes);
            defer init.gpa.free(image);
            var inherited = try reexec.inherited(arguments, image);
            errdefer if (inherited) |*resumed| resumed.close();
            var logs = try logging.Queue.init(
                init.gpa,
                options.log_records,
                options.log_message_bytes,
                options.log_priority_reserve,
            );
            logging.install(&logs);
            defer logging.uninstall(&logs);
            var stdout = logging_stdout.Stdout.init(io, &logs);
            defer stdout.flush();
            var storage = try Storage.init(init.gpa, io);
            defer storage.deinit(init.gpa);
            const transport = try initializeTransport(init.gpa, &inherited);
            defer transport.deinit();
            const table = try init.gpa.create(SessionTable);
            table.initialize();
            var auth = authentication.Offline.init(&io);
            table.setAuthentication(auth.interface(), 30 * std.time.ns_per_s);
            var clock = Clock{ .io = io };
            var session_settings = sessions.Sessions.init(protocol_versions.defaultNumber(protocols));
            const server = try Core.init(init.gpa, io, selected, storage.store.interface(), .{
                .maximum_bytes = options.core_memory_bytes,
                .tick_bytes = options.tick_memory_bytes,
            }, clock.counter(), .{ .sessions = &session_settings, .persistence = storage.access, .meta = meta });
            sessions.Catalog(protocols).install(table, try session_settings.configurationPlan());
            if (!table.setCompressionThreshold(session_settings.compressionThreshold()))
                return error.InvalidCompressionThreshold;
            var reload = try Reload.init(init, arguments, image, transport, table, server);
            defer reload.deinit(init.gpa);
            try reload.restore(&inherited);
            try drive(init, &logs, &stdout, storage.packs, transport, table, &clock, session_settings.statusProvider(), server, &reload.value);
        }

        fn initializeTransport(allocator: std.mem.Allocator, inherited: *?reexec.Resume) !*Transport {
            const transport = try allocator.create(Transport);
            if (inherited.*) |resumed|
                try transport.initializeResumed(resumed.listener, 0)
            else
                try transport.initialize(.{ .address = try std.Io.net.IpAddress.parse(options.address, options.port) });
            return transport;
        }

        fn drive(
            init: std.process.Init,
            logs: *logging.Queue,
            stdout: *logging_stdout.Stdout,
            packs: *PackDriver,
            transport: *Transport,
            table: *SessionTable,
            clock: *Clock,
            status: sessions.Status,
            server: *Core,
            reload: *Reloader,
        ) !void {
            var driver = sessions.Driver.init(
                table.interface(),
                transport.transport(),
                clock.interface(),
                status,
                server.sessionsBoundary(),
            );
            server.bindPacketRuntime(driver.packetRuntime());
            var signals: shutdown_posix.Signals = .{};
            try signals.init();
            defer signals.deinit();
            if (comptime has_tui) {
                const terminal = try init.gpa.create(Terminal);
                terminal.* = Terminal.init(init.io, server.get(tui.Plugin), .{});
                const enabled = try tuiRequested(init);
                if (enabled) try terminal.enter();
                defer if (enabled) terminal.leave() catch {};
                var auxiliary = [_]runtime.Backend{terminal.backend()};
                return runRuntime(init.io, transport, packs, &driver, server, reload, signals.interface(), if (enabled) &auxiliary else &.{}, if (enabled) terminal.loggingBackend(logs) else stdout.interface());
            }
            return runRuntime(init.io, transport, packs, &driver, server, reload, signals.interface(), &.{}, stdout.interface());
        }

        fn runRuntime(
            io: std.Io,
            transport: *Transport,
            packs: *PackDriver,
            driver: *sessions.Driver,
            server: *Core,
            reload: *Reloader,
            shutdown: runtime.Shutdown,
            auxiliary: []runtime.Backend,
            log_backend: runtime.Backend,
        ) !void {
            try runtime.run(.{
                .io = io,
                .transport = transport.backend(),
                .persistence = packs.interface(),
                .logging = log_backend,
                .auxiliary_backends = auxiliary,
                .shutdown = shutdown,
                .sessions = driver.runtime(),
                .core = server.runtime(),
                .reloader = reload.operation(),
            });
        }

        const Storage = struct {
            store: *persistence.Store,
            source: *persistence.Store,
            output: *persistence.Store,
            value: []u8,
            compaction: []u8,
            packs: *PackDriver,
            access: *persistence.Access,
            path: []u8,

            fn init(allocator: std.mem.Allocator, io: std.Io) !Storage {
                const checkpoint_bytes = try persistence.maximumCheckpointBytes(options.persistence);
                const store = try persistence.Store.initIndex(allocator, options.persistence);
                const source = try persistence.Store.initIndex(allocator, options.persistence);
                const output = try persistence.Store.initIndex(allocator, options.persistence);
                const value = try allocator.alloc(u8, options.persistence.maximum_value_bytes);
                const compaction = try allocator.alloc(u8, checkpoint_bytes);
                const recovery = try allocator.alloc(u8, checkpoint_bytes);
                defer allocator.free(recovery);
                const path = try allocator.alloc(u8, options.maximum_path_bytes);
                const file = try std.Io.Dir.cwd().createFile(io, options.root_path, .{ .read = true, .truncate = false });
                const packs = try allocator.create(PackDriver);
                const length = try file.realPath(io, path);
                try packs.init(io, file, path[0..length], store, recovery);
                try packs.configureMaintenance(source, output, value, compaction);
                const access = try allocator.create(persistence.Access);
                access.* = persistence.Access.init(.{
                    .interface = store.interface(),
                    .loader = packs.loader(),
                    .maximum_checkpoint_records = options.persistence.maximum_checkpoint_records,
                });
                return .{ .store = store, .source = source, .output = output, .value = value, .compaction = compaction, .packs = packs, .access = access, .path = path };
            }

            fn deinit(self: *Storage, allocator: std.mem.Allocator) void {
                self.packs.deinit();
                allocator.free(self.path);
                allocator.free(self.compaction);
                allocator.free(self.value);
            }
        };

        const Reload = struct {
            continuation: []u8,
            candidate: reexec.SelfCandidate(options.maximum_arguments),
            value: Reloader,

            fn init(process: std.process.Init, arguments: []const [:0]const u8, image: []u8, transport: *Transport, table: *SessionTable, server: *Core) !Reload {
                const continuation = try process.gpa.alloc(u8, continuation_bytes);
                var self: Reload = .{
                    .continuation = continuation,
                    .candidate = .{ .executable = arguments[0], .arguments = arguments, .expected = &resume_manifest },
                    .value = undefined,
                };
                self.value.init(.{
                    .transport = transport,
                    .sessions = table,
                    .core = server.runtime(),
                    .candidate = self.candidate.candidate(),
                    .candidate_fd = &self.candidate.validated_fd,
                    .arguments = arguments,
                    .environment = process.minimal.environ.block.slice,
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
            const message = std.fmt.bufPrint(&storage, "lightning_rod startup failed: {s}\n", .{@errorName(err)}) catch "lightning_rod startup failed\n";
            std.Io.File.stderr().writeStreamingAll(io, message) catch {};
        }
    };
}
