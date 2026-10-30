const std = @import("std");
const lightning_rod = @import("lightning_rod");
const host = @import("host");
const protocols = @import("protocols");
const sessions = @import("sessions");
const vanilla = @import("vanilla");
const reload = @import("reload");
const execve = @import("reload_execve");
const islands_api = @import("island.zig");
const Island = islands_api.Island;
const catalog_api = @import("catalog.zig");
const Catalog = catalog_api.Catalog;
const routing = @import("router.zig");
const Presence = @import("session_presence.zig").Presence;
const ChatChannel = @import("global_chat.zig").Channel;
const Worlds = @import("worlds.zig").Worlds;
const records = @import("records");
const Slots = @import("slots.zig").Slots;

const header = "LRSKY001";
const Router = routing.Router;

pub const Configuration = struct {
    port: u16 = 25565,
    workers: usize = 2,
    directory: []const u8 = "lightning-rod-data/skyblock",
    startup_report: bool = false,
};

pub fn main(init: std.process.Init) !void {
    var arguments = init.minimal.args.iterate();
    defer arguments.deinit();
    var config: Configuration = .{};
    _ = arguments.skip();
    while (arguments.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--port=")) {
            config.port = try std.fmt.parseInt(u16, arg[7..], 10);
        } else if (std.mem.startsWith(u8, arg, "--workers=")) {
            config.workers = try std.fmt.parseInt(usize, arg[10..], 10);
        } else if (std.mem.startsWith(u8, arg, "--world=")) {
            config.directory = arg[8..];
        } else if (std.mem.eql(u8, arg, "--startup-report")) {
            config.startup_report = true;
        } else return error.UnknownArgument;
    }
    try run(init, config);
}

pub fn run(init: std.process.Init, config: Configuration) !void {
    var memory = lightning_rod.Memory.init(std.heap.page_allocator, init.io);
    defer memory.deinit();
    const allocator = memory.allocator("bootstrap");
    var registry = try lightning_rod.metrics.Registry.init(memory.allocator("metrics"), init.io, .{ .capacity = 512 });
    defer registry.deinit();
    var started = host.Startup.capture(init.io);
    if (config.startup_report) started.report = .stdout();
    const catalog_count = islands_api.maximum;
    const port = config.port;
    const pool_size = config.workers;
    const directory = config.directory;
    if (pool_size == 0 or pool_size > 4 or directory.len == 0) return error.InvalidConfiguration;
    const root_path = try std.fs.path.join(allocator, &.{ directory, "sessions" });
    defer allocator.free(root_path);
    var root_store = try lightning_rod.storage.Store.init(memory.allocator("storage"), init.io, .{ .path = root_path, .metrics = &registry, .readers = pool_size * 2 + 1 });
    defer root_store.deinit();
    var catalog = try Catalog.open(&root_store);
    var world_storage = try Worlds.init(&root_store, init.io);
    const chat = try allocator.create(ChatChannel);
    defer allocator.destroy(chat);
    chat.* = .{ .io = init.io };
    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = executable_buffer[0..try std.process.executablePath(init.io, &executable_buffer)];
    var shutdown: host.Shutdown = .{ .io = init.io };
    var reload_requested = std.atomic.Value(bool).init(false);
    var signals: host.Signals = .{ .shutdown = &shutdown, .reload_requested = &reload_requested };
    try signals.install();
    defer signals.restore();
    const protocol_allocator = memory.allocator("protocols");
    const content = try vanilla.prepareDefinitions(memory.allocator("definitions"));
    _ = try vanilla.Datapacks.init(memory.allocator("datapacks"), init.io, .{ .sources = &.{.{ .collection = "datapacks" }} }, content);
    var selected = try protocols.Default.init(protocol_allocator);
    defer selected.deinit(protocol_allocator);
    try vanilla.definition_provider.configureProtocols(content, protocols.Default, protocol_allocator, &selected);
    const session_plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.configured(protocols.Handshake, .{}),
        vanilla.session_plugins(&selected),
        lightning_rod.plugin.configured(Presence, .{ .catalog = &catalog, .chat = chat }),
    });
    const Network = sessions.Threaded(protocols.Endpoint, @TypeOf(session_plugins), Router);
    Network.retainReload(execve);
    var endpoints: [islands_api.maximum]Network.EndpointConfiguration = undefined;
    for (endpoints[0..catalog_count], catalog.ids[0..catalog_count]) |*endpoint, id| endpoint.* = .{
        .id = id,
        .connections = if (id == catalog.ids[0]) catalog_api.maximum_players else catalog_api.island_connections,
    };
    const network_config: Network.Configuration = .{
        .plugins = session_plugins,
        .protocols = &selected,
        .router = .{ .catalog = &catalog },
        .max_players = catalog_api.maximum_players,
        .max_pending_wire_bytes = 1024 * 1024,
        .endpoints = endpoints[0..catalog_count],
        .inherited_listener = try host.inheritedListener(init),
        .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = port } },
    };
    var reloading = try execve.Service.init(allocator, init, executable);
    defer reloading.deinit();
    var incoming = try execve.incoming(init);
    defer if (incoming) |value| value.file.close(init.io);
    var input_buffer: [4096]u8 = undefined;
    var input: std.Io.File.Reader = undefined;
    var handoff: ?lightning_rod.Resume = null;
    var expected_ticks: [islands_api.maximum]?u64 = @splat(null);
    var reply_island: u16 = std.math.maxInt(u16);
    var reply: reload.Request = .{ .enabled = true };
    if (incoming) |value| {
        input = value.file.reader(init.io, &input_buffer);
        const reader = &input.interface;
        if (!std.mem.eql(u8, try reader.takeArray(execve.manifest.len), &execve.manifest) or
            !std.mem.eql(u8, try reader.takeArray(header.len), header)) return error.InvalidResume;
        const resumed_islands = try reader.takeInt(u16, .little);
        if (resumed_islands != catalog_count) return error.InvalidResume;
        reply_island = try reader.takeInt(u16, .little);
        if (reply_island != std.math.maxInt(u16) and reply_island >= catalog_count) return error.InvalidResume;
        reply.started_ns = try reader.takeInt(i96, .little);
        if (reply.started_ns < 0 or reply.started_ns > started.wall_ns) return error.InvalidResume;
        const token_len = try reader.takeInt(u16, .little);
        if (token_len > reply.reply_bytes.len) return error.InvalidResume;
        try reader.readSliceAll(reply.reply_bytes[0..token_len]);
        reply.reply_len = token_len;
        for (expected_ticks[0..resumed_islands]) |*tick| tick.* = try reader.takeInt(u64, .little);
        handoff = .{ .reader = reader, .file_reader = &input };
    }
    var routing_table: sessions.Routing = .{ .endpoints = &.{} };
    const islands = try allocator.alloc(Island, islands_api.maximum);
    defer allocator.free(islands);
    const workers = try allocator.alloc(islands_api.Pool.Worker, pool_size);
    defer allocator.free(workers);
    var workers_initialized: usize = 0;
    defer for (workers[0..workers_initialized]) |worker| worker.record_resources.deinit();
    for (workers, 0..) |*worker, index| {
        worker.* = .{
            .io = init.io,
            .record_resources = try records.Resources.init(memory.allocator("records"), init.io, .{ .readers = 2, .writers = 2 }),
            .index = index,
        };
        workers_initialized += 1;
    }
    var slots = try Slots.init(memory.allocator("islands"), catalog_api.maximum_active);
    defer slots.deinit();
    var pool: islands_api.Pool = .{ .workers = workers, .slots = &slots };
    for (islands[0..catalog_count], expected_ticks[0..catalog_count], catalog.ids[0..catalog_count], 0..) |*island, expected_tick, id, index| {
        island.* = .{
            .id = id,
            .worlds = &world_storage,
            .record_resources = workers[index % pool_size].record_resources,
            .io = init.io,
            .wakeup = &workers[index % pool_size].background_ready,
            .routing = &routing_table,
            .catalog = &catalog,
            .content = content,
            .chat = chat,
            .index = index,
            .worker = index % pool_size,
            .expected_tick = expected_tick,
        };
    }
    const worlds = islands[0..catalog_count];
    for (worlds) |*island| try island.load();
    const network = try Network.init(allocator, init.io, network_config, .{ .memory = &memory, .metrics = &registry, .handoff = if (handoff) |*value| value else null });
    defer network.deinit();
    if (incoming) |value| {
        value.file.close(init.io);
        incoming = null;
    }
    routing_table = network.core.routing;
    try pool.reserve(worlds);
    var maintenance: lightning_rod.storage.Maintenance = .{ .store = &root_store };
    try maintenance.start();
    defer maintenance.stop();
    try pool.start(worlds);
    defer pool.stop();
    defer pool.apply(worlds, .close) catch |err| std.debug.panic("island shutdown: {t}", .{err});
    try pool.reconcile(worlds);
    try network.start();
    defer network.stop();
    memory.seal();
    if (reply_island != std.math.maxInt(u16)) {
        reply.sequence = 1;
        reply.result = .succeeded;
        reply.elapsed_ms = host.elapsedMs(init.io, reply.started_ns);
        worlds[reply_island].request = reply;
    }
    const ready = host.Startup.capture(init.io);
    try started.publish(init.io, ready);
    var active_count: usize = 0;
    for (worlds) |*island| active_count += @intFromBool(island.simulation != null);
    std.log.info("event=server_ready worlds={d} world_limit={d} workers={d} startup_ms={d:.3}", .{ active_count, catalog_api.maximum_active, pool_size, @as(f64, @floatFromInt(ready.wall_ns - started.wall_ns)) / std.time.ns_per_ms });
    var deadline = std.Io.Clock.now(.awake, init.io).nanoseconds;
    while (!shutdown.requested()) {
        try pool.apply(worlds, .tick);
        try pool.reconcile(worlds);
        try network.check();
        try maintenance.check();
        var save_requested = false;
        for (worlds) |*island| if (island.simulation) |simulation| {
            save_requested = save_requested or simulation.save_requested.requested;
        };
        if (save_requested) {
            try pool.apply(worlds, .save);
            try catalog.write(try root_store.openSpace("skyblock:islands"));
            try root_store.submitSync(try root_store.commit(root_store.lastTick() + 1));
        }
        var requested = reload_requested.swap(false, .acq_rel);
        reply_island = std.math.maxInt(u16);
        for (worlds, 0..) |*island, index| if (island.request.pending) {
            if (reply_island == std.math.maxInt(u16)) reply_island = @intCast(index);
            island.request.pending = false;
            requested = true;
        };
        if (requested) {
            reply = if (reply_island == std.math.maxInt(u16)) .{ .enabled = true } else worlds[reply_island].request;
            reply.started_ns = std.Io.Clock.now(.awake, init.io).nanoseconds;
            reloading.request = reply;
            const image = reloading.prepare(init.io) catch |err| {
                std.log.err("event=reload_rejected reason={t}", .{err});
                if (reply_island != std.math.maxInt(u16)) worlds[reply_island].request.result = .rejected;
                continue;
            };
            defer image.close(init.io);
            reply = reloading.request;
            try network.core.prepareReload(init.io, image.compatibility());
            try network.pause(host.timing.shutdownDeadline(init.io));
            try pool.apply(worlds, .pause);
            maintenance.stop();
            try pool.apply(worlds, .save);
            try catalog.write(try root_store.openSpace("skyblock:islands"));
            try root_store.waitDurableUntil(try root_store.commit(root_store.lastTick() + 1), host.timing.shutdownDeadline(init.io));
            const snapshot = try execve.create();
            defer snapshot.close(init.io);
            var output_buffer: [4096]u8 = undefined;
            var output = snapshot.writer(init.io, &output_buffer);
            const writer = &output.interface;
            try writer.writeAll(&execve.manifest);
            try writer.writeAll(header);
            try writer.writeInt(u16, @intCast(catalog_count), .little);
            try writer.writeInt(u16, reply_island, .little);
            try writer.writeInt(i96, reply.started_ns, .little);
            try writer.writeInt(u16, reply.reply_len, .little);
            try writer.writeAll(reply.token());
            for (worlds) |*island| {
                const tick = if (island.scope) |scope| scope.tick else 0;
                try writer.writeInt(u64, tick, .little);
            }
            var descriptors: [264]i32 = undefined;
            const count = try network.core.writeReload(init.io, image.compatibility(), writer, &descriptors);
            try writer.flush();
            try execve.seal(snapshot);
            std.log.info("event=reload_exec islands={d}", .{catalog_count});
            reloading.execute(image, init.io, snapshot, descriptors[0..count]) catch |err| std.log.err("event=reload_fallback reason={t}", .{err});
            try maintenance.start();
            try network.resumeReload();
            try pool.apply(worlds, .resume_io);
            if (reply_island != std.math.maxInt(u16)) {
                reply.sequence += 1;
                reply.result = .rolled_back;
                reply.elapsed_ms = host.elapsedMs(init.io, reply.started_ns);
                worlds[reply_island].request = reply;
            }
            deadline = std.Io.Clock.now(.awake, init.io).nanoseconds;
            continue;
        }
        deadline = host.timing.nextTick(deadline, std.Io.Clock.now(.awake, init.io).nanoseconds);
        try std.Io.Timeout.sleep(.{ .deadline = .{ .clock = .awake, .raw = .{ .nanoseconds = deadline } } }, init.io);
    }
    try pool.apply(worlds, .pause);
    try pool.apply(worlds, .close);
    try catalog.write(try root_store.openSpace("skyblock:islands"));
    network.stop();
    try root_store.waitDurableUntil(try root_store.commit(root_store.lastTick() + 1), host.timing.shutdownDeadline(init.io));
}
