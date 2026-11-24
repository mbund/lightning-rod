const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const BlockSynchronization = @import("terrain").block_sync.BlockSynchronization;
const Chunks = @import("chunks").Chunks;
const Generation = @import("terrain").generation.Generation;
const Inventories = @import("inventories").Inventories;
const Lighting = @import("terrain").lighting.Lighting;
const Players = @import("players").players.Players;
const RegionDebug = @import("replication").region_debug.RegionDebug;
const Streaming = @import("terrain").streaming.Streaming;
const ThreadedTerrain = @import("terrain").terrain.ThreadedTerrain;
const connection_plugins = @import("connection").plugins;
const sessions = @import("sessions");
const protocols = @import("protocols");
const host = @import("host");
const tps = @import("tps");
const game_data = @import("game_data");
const terrain_chunks = @import("chunks");
const client = @import("client.zig");
const assert = std.debug.assert;

pub const std_options: std.Options = .{ .log_level = .info };
const maximum = 128;
const Workload = struct {
    ticks: usize,
    warmup: usize,
    players: usize,
    burst_slots: usize,
    metrics_export: bool,
    prefetch: u2,
    /// Keep columns until they leave client storage instead of the delivery radius.
    retain: bool,
    /// Blocks each player flies along +x before turning back. Zero bounces in a box.
    round_trip: u32,
    /// Per-stage CPU timers read the clock in hot loops, so they stay off for throughput runs.
    detailed_timers: bool,
    /// Whole blocks per second along the flight path.
    speed: u32,
    /// Players stand on a grid this many wide, with these block gaps along x and z.
    /// Gaps past the view diameter give every player a frontier of its own.
    columns: usize,
    spacing: [2]u32,
    /// Ticks between one player's block edits. Zero edits nothing.
    edit_interval: u32,
    /// Blocks ahead of the player along +x where its edits land. Past the view radius they
    /// reach terrain the player has not been sent yet.
    edit_lead: u32,
    /// Side of the cube of blocks one edit places and later removes. One is a single block.
    /// A larger cube is centred on a column corner, so it spans four columns.
    edit_size: u32,
    /// The block state edits place, by name. Water makes every edit a fluid that falls and spreads.
    edit_block: []const u8,
};

// Flight speed is set in whole blocks per second. Positions advance by fractions per tick.
const ticks_per_second = 20;
// Edits land just under the flight path, in the open air above the terrain.
const edit_height = 149;
const plugins = lightning_rod.plugin.compose(.{
    lightning_rod.plugin.replace(vanilla.plugins(), .{
        lightning_rod.plugin.configured(Streaming, .{ .prefetch = 3 }),
        lightning_rod.plugin.configured(Players, .{ .spawn = .{ .x = 0.5, .y = 150, .z = 0.5 } }),
    }),
    lightning_rod.plugin.configured(tps.Tps, .{}),
    lightning_rod.plugin.configured(RegionDebug, .{}),
});
const session_plugins_type = @TypeOf(lightning_rod.plugin.compose(.{
    lightning_rod.plugin.configured(protocols.Handshake, .{}),
    connection_plugins(@as(*protocols.Default, undefined)),
}));
const Network = sessions.Threaded(protocols.Endpoint, session_plugins_type, sessions.SingleSimulation);
const Process = host.Process(@TypeOf(plugins), Network);

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--server")) {
        if (args.len != 22) return error.InvalidServerArguments;
        return server(init, args[2], args[3], try std.fmt.parseInt(i32, args[4], 10), .{
            .ticks = try std.fmt.parseInt(usize, args[5], 10),
            .warmup = try std.fmt.parseInt(usize, args[6], 10),
            .players = try std.fmt.parseInt(usize, args[7], 10),
            .burst_slots = try std.fmt.parseInt(usize, args[8], 10),
            .metrics_export = try parseBoolean(args[9]),
            .prefetch = try std.fmt.parseInt(u2, args[10], 10),
            .retain = try parseBoolean(args[11]),
            .round_trip = try std.fmt.parseInt(u32, args[12], 10),
            .detailed_timers = try parseBoolean(args[13]),
            .speed = try std.fmt.parseInt(u32, args[14], 10),
            .columns = try std.fmt.parseInt(usize, args[15], 10),
            .spacing = .{ try std.fmt.parseInt(u32, args[16], 10), try std.fmt.parseInt(u32, args[17], 10) },
            .edit_interval = try std.fmt.parseInt(u32, args[18], 10),
            .edit_lead = try std.fmt.parseInt(u32, args[19], 10),
            .edit_size = try std.fmt.parseInt(u32, args[20], 10),
            .edit_block = args[21],
        });
    }
    var world: ?[]const u8 = null;
    var directory: []const u8 = ".zig-cache/stress";
    var ticks: usize = 600;
    var warmup: usize = 600;
    var player_count: usize = maximum;
    var burst_slots: usize = 8;
    var metrics_export = true;
    var prefetch: u2 = 3;
    var retain = true;
    var round_trip: u32 = 0;
    var detailed_timers = false;
    var speed: u32 = 80;
    var columns: usize = 8;
    var spacing: [2]u32 = .{ 48, 40 };
    var edit_interval: u32 = 0;
    var edit_lead: u32 = 0;
    var edit_size: u32 = 1;
    var edit_block: []const u8 = "minecraft:stone";
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        if (index + 1 == args.len) return error.MissingArgument;
        if (std.mem.eql(u8, args[index], "--world")) world = args[index + 1] else if (std.mem.eql(u8, args[index], "--output")) directory = args[index + 1] else if (std.mem.eql(u8, args[index], "--ticks")) ticks = try std.fmt.parseInt(usize, args[index + 1], 10) else if (std.mem.eql(u8, args[index], "--warmup-ticks")) warmup = try std.fmt.parseInt(usize, args[index + 1], 10) else if (std.mem.eql(u8, args[index], "--players")) player_count = try std.fmt.parseInt(usize, args[index + 1], 10) else if (std.mem.eql(u8, args[index], "--burst-slots")) burst_slots = try std.fmt.parseInt(usize, args[index + 1], 10) else if (std.mem.eql(u8, args[index], "--metrics-export")) metrics_export = try parseBoolean(args[index + 1]) else if (std.mem.eql(u8, args[index], "--prefetch")) prefetch = try std.fmt.parseInt(u2, args[index + 1], 10) else if (std.mem.eql(u8, args[index], "--retain")) retain = try parseBoolean(args[index + 1]) else if (std.mem.eql(u8, args[index], "--round-trip")) round_trip = try std.fmt.parseInt(u32, args[index + 1], 10) else if (std.mem.eql(u8, args[index], "--detailed-timers")) detailed_timers = try parseBoolean(args[index + 1]) else if (std.mem.eql(u8, args[index], "--speed")) speed = try std.fmt.parseInt(u32, args[index + 1], 10) else if (std.mem.eql(u8, args[index], "--columns")) columns = try std.fmt.parseInt(usize, args[index + 1], 10) else if (std.mem.eql(u8, args[index], "--spacing-x")) spacing[0] = try std.fmt.parseInt(u32, args[index + 1], 10) else if (std.mem.eql(u8, args[index], "--spacing-z")) spacing[1] = try std.fmt.parseInt(u32, args[index + 1], 10) else if (std.mem.eql(u8, args[index], "--edit-interval")) edit_interval = try std.fmt.parseInt(u32, args[index + 1], 10) else if (std.mem.eql(u8, args[index], "--edit-lead")) edit_lead = try std.fmt.parseInt(u32, args[index + 1], 10) else if (std.mem.eql(u8, args[index], "--edit-size")) edit_size = try std.fmt.parseInt(u32, args[index + 1], 10) else if (std.mem.eql(u8, args[index], "--edit-block")) edit_block = args[index + 1] else return error.UnknownArgument;
    }
    if (speed == 0 or speed > 400) return error.InvalidSpeed;
    if (columns == 0 or columns > maximum) return error.InvalidGrid;
    // A round trip flies out and back once, so it sets the flight length.
    if (round_trip != 0) {
        ticks = 2 * (std.math.divCeil(usize, @as(usize, round_trip) * ticks_per_second, speed) catch unreachable);
    }
    if (ticks == 0 or ticks > 72000 or warmup > 72000) return error.InvalidDuration;
    if (player_count == 0 or player_count > maximum) return error.InvalidPlayerCount;
    if (burst_slots == 0 or burst_slots > 8) return error.InvalidBurstCapacity;
    const source = world orelse return error.MissingWorld;
    const io = init.io;
    const allocator = init.arena.allocator();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, directory);
    const copy = try std.fs.path.join(allocator, &.{ directory, "world" });
    const source_real = try cwd.realPathFileAlloc(io, source, allocator);
    const destination_real = cwd.realPathFileAlloc(io, copy, allocator) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (destination_real) |real| if (std.mem.eql(u8, source_real, real)) return error.SourceEqualsOutput;
    try cwd.copyFile(source, cwd, copy, io, .{});
    const wal = try std.fmt.allocPrint(allocator, "{s}.wal", .{copy});
    cwd.copyFile(try std.fmt.allocPrint(allocator, "{s}.wal", .{source}), cwd, wal, io, .{}) catch |err| {
        if (err != error.FileNotFound) return err;
        cwd.deleteFile(io, wal) catch |remove_error| if (remove_error != error.FileNotFound) return remove_error;
    };
    const address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var listener = try address.listen(io, .{});
    var listener_open = true;
    defer if (listener_open) listener.deinit(io);
    const destination = listener.socket.address;
    const fd = try std.fmt.allocPrint(allocator, "{d}", .{listener.socket.handle});
    const log = try cwd.createFile(io, try std.fs.path.join(allocator, &.{ directory, "server.log" }), .{});
    defer log.close(io);
    const result = try cwd.createFile(io, try std.fs.path.join(allocator, &.{ directory, "usage.txt" }), .{});
    defer result.close(io);
    var executable: [std.fs.max_path_bytes]u8 = undefined;
    const name = executable[0..try std.process.executablePath(io, &executable)];
    var child = try std.process.spawn(io, .{ .argv = &.{ name, "--server", copy, directory, fd, try std.fmt.allocPrint(allocator, "{d}", .{ticks}), try std.fmt.allocPrint(allocator, "{d}", .{warmup}), try std.fmt.allocPrint(allocator, "{d}", .{player_count}), try std.fmt.allocPrint(allocator, "{d}", .{burst_slots}), if (metrics_export) "true" else "false", try std.fmt.allocPrint(allocator, "{d}", .{prefetch}), if (retain) "true" else "false", try std.fmt.allocPrint(allocator, "{d}", .{round_trip}), if (detailed_timers) "true" else "false", try std.fmt.allocPrint(allocator, "{d}", .{speed}), try std.fmt.allocPrint(allocator, "{d}", .{columns}), try std.fmt.allocPrint(allocator, "{d}", .{spacing[0]}), try std.fmt.allocPrint(allocator, "{d}", .{spacing[1]}), try std.fmt.allocPrint(allocator, "{d}", .{edit_interval}), try std.fmt.allocPrint(allocator, "{d}", .{edit_lead}), try std.fmt.allocPrint(allocator, "{d}", .{edit_size}), edit_block }, .stdin = .ignore, .stdout = .{ .file = result }, .stderr = .{ .file = log }, .inherit_files = &.{.{ .handle = listener.socket.handle, .flags = .{ .nonblocking = false } }} });
    listener.deinit(io);
    listener_open = false;
    var clients: [maximum]client.Client = undefined;
    var threads: [maximum]?std.Thread = @splat(null);
    defer {
        child.kill(io);
        for (&threads) |*thread| if (thread.*) |value| value.join();
    }
    for (clients[0..player_count], threads[0..player_count], 0..) |*bot, *thread, slot| {
        bot.* = .{ .io = io, .address = destination, .index = slot };
        thread.* = try std.Thread.spawn(.{}, client.Client.run, .{bot});
    }
    const term = try child.wait(io);
    for (threads[0..player_count]) |*thread| {
        thread.*.?.join();
        thread.* = null;
    }
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(io, &buffer);
    var bytes: usize = 0;
    var packets: usize = 0;
    var chunks: usize = 0;
    var chunk_bytes: usize = 0;
    var unloads: usize = 0;
    for (clients[0..player_count]) |bot| {
        chunk_bytes += bot.chunk_bytes;
        unloads += bot.unloads;
        try output.interface.print("client={d} played={} chunks={d} bytes={d} failure={s}\n", .{ bot.index, bot.played, bot.chunks, bot.bytes, if (bot.failure) |err| @errorName(err) else "none" });
        bytes += bot.bytes;
        packets += bot.packets;
        chunks += bot.chunks;
    }
    try output.interface.print("chunk_MiB={d:.2} unloads={d}\n", .{ @as(f64, @floatFromInt(chunk_bytes)) / 1048576, unloads });
    try output.interface.print("{d} real TCP protocol clients: bytes={d} packets={d} chunks={d}\nReport: {s}/usage.txt\n", .{ player_count, bytes, packets, chunks, directory });
    try output.interface.flush();
    if (term != .exited or term.exited != 0) return error.ServerFailed;
    for (clients[0..player_count]) |bot| if (!bot.played or bot.failure != null or bot.chunks == 0) return error.ClientFailed;
}

fn parseBoolean(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidBoolean;
}

/// The edits that set every block of a cube to one state, grouped by section.
const Cube = struct {
    /// A side of 16 or less touches at most two sections along each axis.
    const side_max = 16;
    const sections_max = 8;
    sections: [sections_max]terrain_chunks.SectionEdits = undefined,
    edits: *[sections_max][4096]terrain_chunks.BlockEdit,

    fn fill(self: *Cube, world: terrain_chunks.World, low: [3]i32, side: u32, state: u16) []const terrain_chunks.SectionEdits {
        assert(side != 0 and side <= side_max);
        var lengths: [sections_max]usize = @splat(0);
        var count: usize = 0;
        const span: i32 = @intCast(side);
        var y: i32 = low[1];
        while (y < low[1] + span) : (y += 1) {
            var z: i32 = low[2];
            while (z < low[2] + span) : (z += 1) {
                var x: i32 = low[0];
                while (x < low[0] + span) : (x += 1) {
                    const position: terrain_chunks.Position = .{ .x = x, .y = y, .z = z };
                    const section = terrain_chunks.sectionAt(world, position);
                    const slot = for (self.sections[0..count], 0..) |known, index| {
                        if (std.meta.eql(known.section, section)) break index;
                    } else slot: {
                        assert(count < sections_max);
                        self.sections[count] = .{ .section = section, .edits = &.{} };
                        count += 1;
                        break :slot count - 1;
                    };
                    self.edits[slot][lengths[slot]] = .{ .index = terrain_chunks.localIndex(position), .state = state };
                    lengths[slot] += 1;
                }
            }
        }
        for (self.sections[0..count], 0..) |*section, slot| section.edits = self.edits[slot][0..lengths[slot]];
        return self.sections[0..count];
    }
};
fn server(init: std.process.Init, world: []const u8, directory: []const u8, fd: i32, workload: Workload) !void {
    const ticks = workload.ticks;
    const warmup = workload.warmup;
    const player_count = workload.players;
    const burst_slots = workload.burst_slots;
    if (player_count == 0 or player_count > maximum) return error.InvalidPlayerCount;
    if (burst_slots == 0 or burst_slots > 8) return error.InvalidBurstCapacity;
    if (workload.edit_size == 0 or workload.edit_size > Cube.side_max) return error.InvalidEditSize;
    var memory = lightning_rod.Memory.init(lightning_rod.system.huge_page_allocator, init.io);
    defer memory.deinit();
    const allocator = memory.allocator("bootstrap");
    var catalog = try protocols.Default.init(allocator);
    defer catalog.deinit(allocator);
    const session_plugins = lightning_rod.plugin.compose(.{ lightning_rod.plugin.configured(protocols.Handshake, .{}), connection_plugins(&catalog) });
    var chunk_configuration = Chunks.Configuration.forPlayers(player_count);
    chunk_configuration.storage_batch_groups = burst_slots;
    const gameplay = lightning_rod.plugin.replace(plugins, .{
        lightning_rod.plugin.configured(Players, Players.Configuration{ .maximum = player_count, .spawn = .{ .x = 0.5, .y = 150, .z = 0.5 } }),
        lightning_rod.plugin.configured(Chunks, chunk_configuration),
        lightning_rod.plugin.configured(Streaming, Streaming.Configuration{ .prefetch = workload.prefetch, .retain_client_storage = workload.retain }),
    });
    const process = try Process.init(&memory, init, .{
        .plugins = gameplay,
        .network = .{
            .plugins = session_plugins,
            .protocols = &catalog,
            .router = .{},
            .max_players = player_count,
            .input_burst_slots = @min(2, burst_slots),
            .decode_slots = @min(2, burst_slots),
            .configuration_slots = burst_slots,
            .endpoints = &.{.{ .id = 0, .connections = player_count }},
            .inherited_listener = fd,
        },
        .storage_path = world,
        .storage_readers = 2,
        .metrics = .{ .capacity = 512, .detailed_timers = workload.detailed_timers },
        .metrics_export = if (workload.metrics_export) .{ .directory = directory } else null,
    }, .{});
    defer process.deinit();
    const simulation = process.simulation;
    const network = process.network;
    try vanilla.definition_provider.configureProtocols(vanilla.definition_provider.from(@TypeOf(simulation.*), simulation), protocols.Endpoint.Protocols, memory.allocator("content_protocols"), &catalog);
    const generation = try Generation.init(memory.allocator("generation"), init.io, simulation.get(Chunks).generation, 1);
    defer generation.deinit();
    try generation.start();
    defer generation.stop();
    var maintenance: lightning_rod.storage.Maintenance = .{ .store = process.store };
    try maintenance.start();
    defer maintenance.stop();
    var background: ThreadedTerrain = .{ .terrain = .{ .chunks = simulation.get(Chunks), .streaming = simulation.get(Streaming), .blocks = simulation.get(BlockSynchronization), .io = init.io }, .io = init.io };
    try background.start();
    defer background.stop();
    try network.start();
    defer network.stop();
    // Registries are frozen before readiness, and allocation is sealed after it.
    const flight_start = try reserveCapture(process, allocator);
    const flight_turn = try reserveCapture(process, allocator);
    const flight_end = try reserveCapture(process, allocator);
    var flight_captured: u2 = 0;
    try process.ready();
    var directions: [maximum][2]f64 = undefined;
    var placed: [maximum]bool = @splat(false);
    var starts: [maximum]f64 = undefined;
    var random = std.Random.DefaultPrng.init(0x4e81bac);
    const step = @as(f64, @floatFromInt(workload.speed)) / ticks_per_second;
    for (&directions) |*direction| {
        const angle = random.random().float(f64) * std.math.pi * 2;
        direction.* = .{ @cos(angle) * step, @sin(angle) * step };
    }
    const players = simulation.get(Players);
    const player_states = simulation.get(vanilla.PlayerStates);
    var moving: usize = 0;
    var waiting: usize = 0;
    var joined: usize = 0;
    var deadline = std.Io.Clock.now(.awake, init.io).nanoseconds;
    var missing_sum: usize = 0;
    var complete_ticks: usize = 0;
    var peak_scratch: usize = 0;
    var edits: usize = 0;
    var placed_blocks: [maximum]?[3]i32 = @splat(null);
    var cube_edits: [Cube.sections_max][4096]terrain_chunks.BlockEdit = undefined;
    var cube: Cube = .{ .edits = &cube_edits };
    const cube_side: i32 = @intCast(workload.edit_size);
    const edit_state: u16 = @intCast(game_data.registry.blockStateId(workload.edit_block) orelse return error.UnknownEditBlock);
    const terrain = simulation.get(Chunks);
    const started_tick = simulation.completed_tick;
    while (moving < ticks) {
        try network.check();
        try background.check();
        try maintenance.check();
        if (simulation.get(vanilla.Flat).generated_sections.load(.monotonic) != 0) return error.IncompleteImportedTerrain;
        {
            const tick = simulation.server_tick.start();
            defer tick.end();
            try simulation.tick();
        }
        var scratch: usize = 0;
        for (simulation.plugin_metrics) |instrument| if (instrument.temporary_bytes.record) |record| {
            scratch += record.scalar.load(.monotonic);
        };
        peak_scratch = @max(peak_scratch, scratch);
        joined = 0;
        for (players.activeSlots()) |slot| {
            const player = &players.records[slot];
            if (player.stage != .ready) continue;
            joined += 1;
            player_states.of(player).flying = true;
            if (!placed[slot]) {
                const rows = (player_count + workload.columns - 1) / workload.columns;
                player.position.x = (@as(f64, @floatFromInt(slot % workload.columns)) - @as(f64, @floatFromInt(workload.columns - 1)) / 2) * @as(f64, @floatFromInt(workload.spacing[0]));
                starts[slot] = player.position.x;
                player.position.y = 150;
                player.position.z = (@as(f64, @floatFromInt(slot / workload.columns)) - @as(f64, @floatFromInt(rows - 1)) / 2) * @as(f64, @floatFromInt(workload.spacing[1]));
                placed[slot] = true;
            }
            if (joined != 0 and waiting >= warmup and workload.round_trip != 0) {
                // Out along +x, then back over the same columns.
                const half = ticks / 2;
                const progress = if (moving < half) moving else 2 * half - @min(2 * half, moving);
                const distance = @min(@as(f64, @floatFromInt(progress)) * step, @as(f64, @floatFromInt(workload.round_trip)));
                player.position.x = starts[slot] + distance;
            } else if (joined != 0 and waiting >= warmup) {
                if (@abs(player.position.x + directions[slot][0]) > 240) directions[slot][0] = -directions[slot][0];
                if (@abs(player.position.z + directions[slot][1]) > 80) directions[slot][1] = -directions[slot][1];
                player.position.x += directions[slot][0];
                player.position.z += directions[slot][1];
            }
        }
        try players.rebuildIndexes();
        if (joined == player_count) {
            if (waiting < warmup) waiting += 1 else {
                if (moving == 0) {
                    capture(process, flight_start);
                    flight_captured = 1;
                }
                if (moving == ticks / 2) {
                    capture(process, flight_turn);
                    flight_captured = 2;
                }
                moving += 1;
                if (workload.edit_interval != 0) for (players.activeSlots()) |slot| {
                    // Players take turns, so every tick carries its share of the edits.
                    if ((moving + slot) % workload.edit_interval != 0) continue;
                    const record = &players.records[slot];
                    // Each player places a cube and takes it away again on its next turn, so
                    // every edit changes terrain and the world ends as it began.
                    if (placed_blocks[slot]) |low| {
                        try terrain.setSections(cube.fill(record.world, low, workload.edit_size, game_data.registry.block_air_default_state));
                        placed_blocks[slot] = null;
                    } else {
                        const ahead = @as(i32, @intFromFloat(@floor(record.position.x))) + @as(i32, @intCast(workload.edit_lead));
                        const across: i32 = @intFromFloat(@floor(record.position.z));
                        // A single block lands where the player looks. A cube is centred on the
                        // nearest column corner.
                        const low: [3]i32 = if (cube_side == 1) .{ ahead, edit_height, across } else .{ @divFloor(ahead + 8, 16) * 16 - @divFloor(cube_side, 2), edit_height + 1 - cube_side, @divFloor(across + 8, 16) * 16 - @divFloor(cube_side, 2) };
                        try terrain.setSections(cube.fill(record.world, low, workload.edit_size, edit_state));
                        placed_blocks[slot] = low;
                    }
                    edits += workload.edit_size * workload.edit_size * workload.edit_size;
                };
                const snapshot = simulation.get(Streaming).snapshotVisibility();
                var missing: usize = 0;
                var center_lag: usize = 0;
                var open_cursors: usize = 0;
                var setting_up: usize = 0;
                var missing_players: usize = 0;
                const radius = simulation.get(Streaming).deliveryRadius();
                const side: usize = @intCast(2 * radius + 1);
                // A column is missing while a player has not been sent it inside the delivery radius.
                for (players.activeSlots()) |slot| {
                    const record = &players.records[slot];
                    const center = snapshot.viewCenter(slot);
                    const actual_x: i32 = @intFromFloat(@floor(record.position.x / 16));
                    const actual_z: i32 = @intFromFloat(@floor(record.position.z / 16));
                    center_lag += @max(@abs(actual_x - center.x), @abs(actual_z - center.z));
                    const missing_before = missing;
                    var z = center.z - radius;
                    while (z <= center.z + radius) : (z += 1) {
                        var x = center.x - radius;
                        while (x <= center.x + radius) : (x += 1) {
                            if (!Streaming.Horizon.contains(radius, center, .{ .x = x, .z = z })) continue;
                            missing += @intFromBool(!snapshot.visible(slot, record, record.world, x, z));
                        }
                    }
                    missing_players += @intFromBool(missing != missing_before);
                }
                // The per-tick series separates a growing backlog (too little throughput) from a steady lag.
                for (players.activeSlots()) |slot| {
                    const stream = snapshot.streams[slot];
                    open_cursors += @intFromBool(stream.cursor < side * side);
                    setting_up += @intFromBool(stream.setup != .streaming);
                }
                std.log.info("event=stress_missing tick={d} missing={d} center_lag={d} open_cursors={d} setting_up={d} missing_players={d}", .{ moving, missing, center_lag, open_cursors, setting_up, missing_players });
                missing_sum += missing;
                complete_ticks += @intFromBool(missing == 0);
            }
        } else if (waiting != 0 or moving != 0) return error.PlayerLostDuringStress;
        if (joined != player_count and simulation.completed_tick - started_tick > 1200) return error.ClientAdmissionTimeout;
        if ((simulation.completed_tick - started_tick) % 100 == 0) {
            const stalled = simulation.get(Streaming);
            var stages: [16]usize = @splat(0);
            var configuring: usize = 0;
            for (players.activeSlots()) |slot| {
                stages[@backingInt(players.records[slot].stage)] += 1;
                configuring += @intFromBool(players.records[slot].configuring);
            }
            std.log.info("event=stress_stages active={d} configuring={d} stages={any} pool_active={d}/{d}", .{ players.activeSlots().len, configuring, stages[0..10], process.network.core.output_pool.active_units, process.network.core.output_pool.units() });
            std.log.info("event=stress_progress players={d} warmup={d}/{d} flight={d}/{d} stalls_idle={d} stalls_epoch={d} stalls_candidates={d} stalls_pool={d} stalls_credit={d} new_columns={d} deferred_cold={d}", .{ joined, waiting, warmup, moving, ticks, stalled.stalls.idle.value(), stalled.stalls.epoch.value(), stalled.stalls.candidates.value(), stalled.stalls.pool.value(), stalled.stalls.credit.value(), stalled.deliveries.new_columns.value(), stalled.deliveries.deferred_cold.value() });
        }
        try simulation.poll();
        if (process.exporter) |*exporter| try exporter.poll(init.io);
        deadline = host.timing.nextTick(deadline, std.Io.Clock.now(.awake, init.io).nanoseconds);
        try std.Io.Timeout.sleep(.{ .deadline = .{ .clock = .awake, .raw = .{ .nanoseconds = deadline } } }, init.io);
    }
    var os_memory: [8192]u8 = undefined;
    const rollup = try std.Io.Dir.cwd().readFile(init.io, "/proc/self/smaps_rollup", &os_memory);
    background.stop();
    network.stop();
    generation.stop();
    maintenance.stop();
    if (simulation.get(vanilla.Flat).generated_sections.load(.monotonic) != 0) return error.IncompleteImportedTerrain;
    var report_buffer: [8192]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &report_buffer);
    try output.interface.print("players={d} flight_ticks={d} warmup_ticks={d} speed={d}_blocks/s complete_horizon_ticks={d} mean_missing_columns={d:.2} block_edits={d}\nreserved_MiB={d:.2} assigned_MiB={d:.2}\n", .{ joined, ticks, warmup, workload.speed, complete_ticks, @as(f64, @floatFromInt(missing_sum)) / @as(f64, @floatFromInt(ticks)), edits, @as(f64, @floatFromInt(memory.reserved_bytes)) / 1048576, @as(f64, @floatFromInt(memory.assigned_bytes)) / 1048576 });
    capture(process, flight_end);
    std.debug.assert(flight_captured == 2);
    try flightMetrics("Outbound", flight_start, flight_turn, ticks / 2, &output.interface);
    try flightMetrics("Return", flight_turn, flight_end, ticks - ticks / 2, &output.interface);
    try flightMetrics("Flight", flight_start, flight_end, ticks, &output.interface);
    try usage(process, &output.interface);
    try reservations(process, &output.interface);
    try output.interface.print("Tick scratch: peak_bytes={d} capacity_bytes={d}\n", .{ peak_scratch, simulation.temporary.buffer.len });
    var lines = std.mem.splitScalar(u8, rollup, '\n');
    try output.interface.writeAll("\nLinux memory residency with worker threads running:\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Rss:") or std.mem.startsWith(u8, line, "Anonymous:") or std.mem.startsWith(u8, line, "AnonHugePages:") or std.mem.startsWith(u8, line, "Swap:"))
            try output.interface.print("{s}\n", .{line});
    }
    try output.interface.flush();
}

const Captured = [3][]lightning_rod.metrics.Snapshot;

fn registriesOf(process: *Process) [3]*lightning_rod.metrics.Registry {
    return .{ &process.owned_registry.?, &process.network.core.registry, &process.simulation.metrics };
}

fn reserveCapture(process: *Process, allocator: std.mem.Allocator) !Captured {
    var captured: Captured = undefined;
    for (registriesOf(process), &captured) |registry, *destination| {
        destination.* = try allocator.alloc(lightning_rod.metrics.Snapshot, registry.count);
    }
    return captured;
}

fn capture(process: *Process, captured: Captured) void {
    for (registriesOf(process), captured) |registry, destination| {
        std.debug.assert(destination.len == registry.count);
        _ = registry.snapshot(destination);
    }
}

/// Timers and counters between two captures, so warmup, admission, and the idle return leg
/// do not dilute per-tick cost. Wall timers on worker threads include waiting.
fn flightMetrics(label: []const u8, start: Captured, end: Captured, ticks: usize, output: *std.Io.Writer) !void {
    std.debug.assert(ticks > 0);
    try output.print("\n{s} timers ({d} ticks)                       clock        count    total_ms  ms_per_tick   max_ms\n", .{ label, ticks });
    for (start, end) |before, after| {
        std.debug.assert(before.len == after.len);
        for (before, after) |previous, current| {
            if (current.kind != .timer or current.count == previous.count) continue;
            const total = nanosecondsToMilliseconds(current.total - previous.total);
            try output.print("{s:<48} {t:<10} {d:>8} {d:>11.2} {d:>12.3} {d:>8.2}\n", .{ current.name, current.clock, current.count - previous.count, total, total / @as(f64, @floatFromInt(ticks)), nanosecondsToMilliseconds(current.maximum) });
        }
    }
    try output.print("\n{s} counters                                         delta    per_tick\n", .{label});
    for (start, end) |before, after| {
        for (before, after) |previous, current| {
            if (current.kind != .counter or current.value == previous.value) continue;
            const delta = current.value - previous.value;
            try output.print("{s:<52} {d:>10} {d:>11.1}\n", .{ current.name, delta, @as(f64, @floatFromInt(delta)) / @as(f64, @floatFromInt(ticks)) });
        }
    }
}

fn nanosecondsToMilliseconds(value: u64) f64 {
    return @as(f64, @floatFromInt(value)) / std.time.ns_per_ms;
}

fn reservations(process: *Process, output: *std.Io.Writer) !void {
    const simulation = process.simulation;
    const streaming = simulation.get(Streaming);
    const chunks = simulation.get(Chunks);
    const store = &chunks.cache.backend.store;
    const compressed = &store.bases.backend;
    const lighting = simulation.get(Lighting);
    var read_bytes: usize = 0;
    var codecs: usize = compressed.compressor.memory.len + store.merger.codec.memory.len;
    for (compressed.readers) |reader| {
        read_bytes += reader.bytes.len;
        codecs += reader.codec.memory.len;
    }
    var lighting_engines: usize = 0;
    var lighting_states: usize = 0;
    inline for (.{lighting.background}) |workspace| {
        lighting_states += std.mem.sliceAsBytes(workspace.states).len;
        inline for (.{ "materials", "rows", "blocks", "links", "decreases", "decrease_queue", "decrease_queued", "source_bounds", "restore_rows", "horizontal", "window_columns", "cursors", "scroll_edges", "scroll_masks" }) |field|
            lighting_engines += std.mem.sliceAsBytes(@field(workspace.engine, field)).len;
    }
    try output.writeAll("\nReservation breakdown                         bytes       MiB\n");
    const rows = .{
        .{ "Visibility topology tiles", std.mem.sliceAsBytes(streaming.geometry.tiles).len },
        .{ "Visibility mixed section cache", std.mem.sliceAsBytes(streaming.geometry.mixed).len },
        .{ "Visibility metadata values", streaming.geometry.prepared_records.len + std.mem.sliceAsBytes(streaming.geometry.prepared_pool.nodes).len + std.mem.sliceAsBytes(streaming.geometry.prepared_pool.blocks).len + std.mem.sliceAsBytes(streaming.geometry.prepared_pool.available_roots).len },
        .{ "Visibility flood query", std.mem.sliceAsBytes(streaming.geometry.query.topology).len + std.mem.sliceAsBytes(streaming.geometry.query.masks).len + std.mem.sliceAsBytes(streaming.geometry.query.known).len + std.mem.sliceAsBytes(streaming.geometry.query.incoming_cones).len },
        .{ "Visibility snapshot metadata", std.mem.sliceAsBytes(streaming.geometry.views).len },
        .{ "Visibility snapshot masks", streaming.geometry.views.len * std.mem.sliceAsBytes(streaming.geometry.views[0].masks).len * 2 },
        .{ "Player lighting receipts", std.mem.sliceAsBytes(streaming.light_receipts.entries).len },
        .{ "Player section masks", 6 * std.mem.sliceAsBytes(streaming.occluded).len },
        .{ "Section cache values", chunks.cache.values.len },
        .{ "Decoded group values", store.bases.values.len },
        .{ "Chunk writer staging (frames or patches)", compressed.staging.len },
        .{ "Overlay reads and decode fallback", read_bytes },
        .{ "Prepared merge frames", store.merger.frames.len },
        .{ "Group codec workspaces", codecs },
        .{ "Group scratch and merge raw", store.scratch.len + store.merger.raw.len },
        .{ "Merge section scratch", store.merger.sections.len },
        .{ "Lighting computation engines", lighting_engines },
        .{ "Lighting block snapshots", lighting_states },
        .{ "Lighting stored light", if (lighting.store) |light| light.memory() else 0 },
        .{ "Stored lighting codec workspaces", lighting.stored_workspace.fragment_baker.memoryBytes() + lighting.stored_workspace.fragment_decoder.frame.len + lighting.stored_workspace.fragment_decoder.codec.memory_bytes },
        .{ "Stored lighting bake buffer", lighting.stored_workspace.raw.len },
        .{ "Stored lighting prepared frames", lighting.prepared.len * lighting.stored_workspace.raw.len },
        .{ "WAL page index", process.store.locations.memoryBytes() },
        .{ "Storage cached and read frames", std.mem.sliceAsBytes(process.store.resources.frames).len },
    };
    inline for (rows) |row| try output.print("{s:<44} {d:>10} {d:>9.3}\n", .{ row[0], row[1], @as(f64, @floatFromInt(row[1])) / 1048576 });
}

fn usage(process: *Process, output: *std.Io.Writer) !void {
    try output.writeAll("\nMetric registry                    registered / limit       reserved MiB\n");
    const registries = .{ &process.owned_registry.?, &process.network.core.registry, &process.simulation.metrics };
    inline for (.{ "host", "sessions", "simulation" }, registries) |name, registry|
        try output.print("{s:<34} {d:>6} / {d:<6} {d:>20.2}\n", .{ name, registry.count, registry.records.len, @as(f64, @floatFromInt(registry.memoryBytes())) / 1048576 });
    try output.writeAll("\nBuffer pool                        peak claims / maximum claims    backing MiB\n");
    const engine = process.network.core.worker.engine;
    const pool_names = .{ "input_bursts", "configurations", "control_raw", "decoded", "packet_bursts", "control_bursts" };
    const pools = .{ &engine.input_bursts, &engine.configurations, &engine.control_raw, &engine.decoded, engine.packet_bursts, engine.control_bursts };
    inline for (pool_names, pools) |name, pool| {
        try output.print("{s:<34} {d:>6} / {d:<6} {d:>20.2}\n", .{ name, pool.maximum_in_use.load(.monotonic), pool.maximum, @as(f64, @floatFromInt(pool.bytes.len)) / 1048576 });
    }
    const pages = &process.network.core.output_pool;
    try output.print("shared output units                {d:>6} / {d:<6} {d:>20.2}\nlargest_output_reservation_bytes={d} peak_published_payload_MiB={d:.2}\n", .{ pages.peak_units, pages.units(), @as(f64, @floatFromInt(pages.bytes.len)) / 1048576, pages.largest_reservation, @as(f64, @floatFromInt(pages.peak_payload_bytes)) / 1048576 });
    const simulation = process.simulation;
    const chunks = simulation.get(Chunks);
    const streaming = simulation.get(Streaming);
    try output.writeAll("\nCache                              occupied / capacity      payload MiB / reserved MiB\n");
    const names = .{ "sections", "decoded groups", "inventory slots", "inventory items" };
    const inventories = simulation.get(Inventories);
    const caches = .{ &chunks.cache, &chunks.cache.backend.store.bases, &inventories.cache, &inventories.items };
    inline for (names, caches) |name, cache| {
        var occupied: usize = 0;
        var payload: usize = 0;
        for (cache.entries) |entry| {
            occupied += @intFromBool(entry.occupied);
            payload += if (entry.present) entry.value_len else 0;
        }
        try output.print("{s:<34} {d:>6} / {d:<6} {d:>13.2} / {d:.2}\n", .{ name, occupied, cache.entries.len, @as(f64, @floatFromInt(payload)) / 1048576, @as(f64, @floatFromInt(cache.values.len)) / 1048576 });
    }
    var classified: usize = 0;
    var mixed: usize = 0;
    for (streaming.geometry.tiles) |tile| {
        classified += @popCount(tile.known);
        mixed += @popCount(tile.known & ~(tile.open | tile.closed));
    }
    try output.print("\nVisibility: columns={d}/{d} classified_sections={d} mixed_sections={d} section_capacity={d} views={d} completed={d}\n", .{ streaming.geometry.lookup.count(), streaming.geometry.tiles.len, classified, mixed, streaming.geometry.tiles.len * streaming.geometry.tiles[0].sections.len, streaming.geometry.views.len, streaming.geometry.completed });
    try output.print("Mixed topology: used={d} peak={d} capacity={d} evictions={d}\n", .{ streaming.geometry.mixed_used, streaming.geometry.mixed_peak, streaming.geometry.mixed.len, streaming.geometry.mixed_evictions });
    const lighting = simulation.get(Lighting);
    if (lighting.store) |store| {
        const stored = store.snapshot();
        try output.print("Lighting: stored_columns={d} overflowed_columns={d} unlit_columns={d} sections={d}/{d} store_bytes={d} patches={d} failures={d} darkened={d} frames={d} restores={d} solves={d} evictions={d} overflows={d} forgotten={d} resets={d} sample_hits={d} sample_misses={d} background_relights={d}\n", .{ stored.resident, stored.overflowed, stored.unlit, stored.sections, store.bytes.len, lighting.storeMemory(), stored.patches, stored.failures, stored.darkened, stored.frames, stored.restores, stored.solves, stored.evictions, stored.overflows, stored.forgotten, stored.resets, stored.hits, stored.misses, lighting.background.work.relights });
    }
    try output.writeAll("\nPlugin                             reserved MiB\n");
    for (simulation.plugin_metrics) |instrument| {
        const record = instrument.persistent_bytes.record orelse continue;
        const snapshot = record.read();
        try output.print("{s:<60} {d:>10.2}\n", .{ snapshot.name, @as(f64, @floatFromInt(snapshot.value)) / 1048576 });
    }
    try output.writeAll("\nCache payload is the final snapshot, not a temporal peak. Pool counts are high water marks.\nRegistry allocations are retained definitions. Workspace capacity is reserved even when inactive.\nClients run in the parent process and are excluded from server reservations.\n");
}
