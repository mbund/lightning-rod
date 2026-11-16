const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const Chunks = @import("chunks").Chunks;
const Inventories = @import("inventories").Inventories;
const Players = @import("players").players.Players;
const Replication = @import("replication").replication.Replication;
const Visibility = @import("replication").visibility.Visibility;
const sessions = @import("sessions");
const network = @import("networking");
const protocols = @import("protocols");
const tps = @import("tps");
const game_data = @import("game_data");

pub const std_options: std.Options = .{ .log_level = .err };

const Mode = enum { idle, moving, one_moving, spread, hidden, boundary };
const Protocol = protocols.implementations[0].Protocol;
const Sink = struct {
    pub fn notify(_: *Sink, _: std.Io) void {}
    pub fn queueReceive(_: *Sink, _: std.Io, _: network.Handle, _: []u8) network.QueueError!void {
        unreachable;
    }
    pub fn queueSend(_: *Sink, _: std.Io, _: network.Handle, _: []const std.posix.iovec_const) network.QueueError!void {
        unreachable;
    }
    pub fn close(_: *Sink, _: std.Io, _: network.Handle, _: network.CloseReason) void {
        unreachable;
    }
    pub fn releaseConnection(_: *Sink, _: std.Io, _: network.Handle) void {
        unreachable;
    }
    pub fn submit(_: *Sink, _: std.Io) !void {
        unreachable;
    }
    pub fn poll(_: *Sink, _: std.Io, _: ?std.Io.Timeout, _: []network.Event) !usize {
        unreachable;
    }
};

const Policy = struct {
    pub const id = "benchmark:visibility";
    pub const Configuration = struct {};
    pub const Dependencies = struct { visibility: *Visibility };
    layer: Visibility.Layer,
    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Policy {
        const self = try allocator.create(Policy);
        self.* = .{ .layer = try deps.visibility.createLayer() };
        return self;
    }
};
const defaults = lightning_rod.plugin.compose(.{ vanilla.plugins(), lightning_rod.plugin.configured(tps.Tps, .{}), lightning_rod.plugin.configured(Policy, .{}) });
const Simulation = lightning_rod.Simulation(@TypeOf(defaults));

const Options = struct {
    players: ?usize = null,
    capacity: ?usize = null,
    pages: usize = 2048,
    mode: ?Mode = null,
    ticks: usize = 1000,
    samples: usize = 3,
    instrumentation: bool = true,
    detail: bool = false,
    paced: bool = false,
    /// Cows on a grid around the players, settled before measuring.
    cows: usize = 0,
    /// Blocks between neighbouring cows, and how far east of the players the field's middle is.
    cow_spacing: f64 = 2,
    cow_offset: f64 = 0,
    /// Ticks the cows get to settle before measuring.
    settle: usize = 400,
    /// A perf control FIFO to enable recording on as measuring starts (perf record -D -1 --control).
    perf_control: ?[]const u8 = null,
    /// Ticks between block edits among the cows, a fence placed then taken away.
    edit_interval: usize = 0,
};

fn run(allocator: std.mem.Allocator, io: std.Io, options: Options, count: usize, mode: Mode, writer: *std.Io.Writer) !void {
    var memory = lightning_rod.Memory.init(allocator, io);
    defer memory.deinit();
    const backing = memory.allocator("tick-bench");
    const directory = try std.fmt.allocPrint(backing, ".zig-cache/tick-bench/{d}-{d}-{s}", .{ std.os.linux.getpid(), count, @tagName(mode) });
    try std.Io.Dir.cwd().createDirPath(io, directory);
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    const path = try std.fmt.allocPrint(backing, "{s}/world", .{directory});
    var store = try lightning_rod.storage.Store.init(backing, io, .{ .path = path, .io_mode = .standard });
    defer store.deinit();
    var sink: Sink = .{};
    var catalog = try protocols.Default.init(backing);
    defer catalog.deinit(backing);
    const selected = &catalog.values;
    const maximum = options.capacity orelse @max(32, count);
    if (maximum < count or maximum == 0) return error.InvalidCapacity;
    const service = try sessions.Service.init(backing, io, .{ .context = &sink, .vtable = network.Transport.adapter(Sink) }, .{ .connections = maximum, .pages = options.pages, .page_bytes = 32768, .buffer_bytes = 128 * 1024, .protocols = selected });
    defer service.deinit();
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(vanilla.plugins(), .{
            lightning_rod.plugin.configured(Players, .{ .maximum = maximum, .render_distance = 8 }),
            lightning_rod.plugin.configured(Chunks, Chunks.Configuration.forPlayers(maximum)),
            lightning_rod.plugin.configured(vanilla.Mobs, .{ .maximum = @max(1024, options.cows) }),
            lightning_rod.plugin.configured(sessions.World, .{ .endpoint = service }),
            lightning_rod.plugin.configured(vanilla.RecipeBook, .{ .packet_bytes = service.config.page_bytes }),
        }),
        lightning_rod.plugin.configured(tps.Tps, .{}),
        lightning_rod.plugin.configured(Policy, .{}),
    });
    const simulation = try Simulation.init(backing, io, &store, .{ .autosave = .{ .ticks = null }, .temporary_bytes = 256 * 1024, .metrics = .{ .capacity = 512, .enabled = options.instrumentation } });
    try simulation.initialize(plugins, .{ .metrics = &simulation.metrics });
    defer {
        simulation.close(.{ .clock = .awake, .raw = .{ .nanoseconds = std.Io.Clock.now(.awake, io).nanoseconds + 5 * std.time.ns_per_s } }) catch @panic("benchmark shutdown failed");
        simulation.deinit(backing);
    }
    const players = simulation.get(Players);
    const player_states = simulation.get(vanilla.PlayerStates);
    const spawn_world = try players.spawnWorld();
    const handles = try backing.alloc(sessions.Handle, count);
    const buffers = [2][][64]u8{ try backing.alloc([64]u8, count), try backing.alloc([64]u8, count) };
    const payloads = [2][][1][]const u8{ try backing.alloc([1][]const u8, count), try backing.alloc([1][]const u8, count) };
    for (players.records[0..count], 0..) |*player, index| {
        handles[index] = .{ .index = @intCast(index), .generation = 1 };
        player.* = .{ .handle = handles[index], .uuid = index + 1, .name_len = 1, .protocol = selected[0].number, .world = spawn_world, .stage = .ready, .loaded = true, .on_ground = true, .position = .{ .x = if (mode == .spread) @as(f64, @floatFromInt(index * 512)) + 8 else 8, .y = 65, .z = 8 } };
        player_states.records[index] = .{ .uuid = player.uuid, .gamemode = .creative };
        player.name[0] = 'p';
        for (0..2) |phase| {
            const packet = try Protocol.play.toServer.write(&buffers[phase][index]).position_look();
            const x = try packet.x(player.position.x + @as(f64, @floatFromInt(phase)) * 0.125);
            const y = try x.y(player.position.y);
            const z = try y.z(player.position.z);
            const yaw = try z.yaw(@as(f32, @floatFromInt(phase)) * 5);
            const pitch = try yaw.pitch(0);
            payloads[phase][index][0] = (try pitch.flags(.{ .onGround = true, .hasHorizontalCollision = false })).finish();
        }
    }
    players.rebuildIndexes();
    const visibility = simulation.get(Visibility);
    const layer = simulation.get(Policy).layer;
    if (mode == .hidden) try layer.updateMany(&.{.{ .subjects = handles[0..count], .channels = &.{visibility.player_entity}, .excluded = true }});
    const stages = try backing.alloc(lightning_rod.metrics.Snapshot, simulation.metrics.count);
    const before = try backing.alloc(lightning_rod.metrics.Snapshot, simulation.metrics.count);
    const cpus = try backing.alloc(u64, options.samples);
    const walls = try backing.alloc(u64, options.samples);
    if (options.detail) {
        const replication = simulation.get(Replication);
        const mining = simulation.get(vanilla.Mining);
        const equipment = simulation.get(vanilla.Equipment);
        try writer.print("# protocols={d} metrics={d} instrumentation={any} assigned_bytes={d}\n", .{ selected.len, simulation.metrics.count, options.instrumentation, memory.assigned_bytes });
        try writer.print("# replication_records_bytes={d} mining_masks_bytes={d} equipment_masks_bytes={d}\n", .{ replication.lifecycle.entries.len * @sizeOf(@TypeOf(replication.lifecycle.entries[0])), mining.selections.memoryBytes(), equipment.selections.memoryBytes() });
    }
    memory.seal();
    var tick_time: u64 = 0;
    var packets: u64 = 0;
    var recipients: u64 = 0;
    for (0..200) |tick| try advance(simulation, service, handles[0..count], payloads[tick % 2], mode, &packets, &recipients, &tick_time);
    const mobs = simulation.get(vanilla.Mobs);
    if (options.cows > 0) {
        // A square field on the flat grass, its middle east of the players at 8, 8 by the offset.
        const side = std.math.sqrt(options.cows - 1) + 1;
        for (0..options.cows) |index| {
            const x = 8.5 + options.cow_offset + options.cow_spacing * (@as(f64, @floatFromInt(index % side)) - @as(f64, @floatFromInt(side / 2)));
            const z = 8.5 + options.cow_spacing * (@as(f64, @floatFromInt(index / side)) - @as(f64, @floatFromInt(side / 2)));
            _ = try mobs.spawn(.{ .species = .cow, .world = spawn_world, .position = .{ x, 65, z }, .yaw = 0 });
        }
        for (0..options.settle) |tick| try advance(simulation, service, handles[0..count], payloads[tick % 2], mode, &packets, &recipients, &tick_time);
    }
    const fence: u16 = @intCast(game_data.registry.blockStateId("minecraft:oak_fence[east=false,north=false,south=false,waterlogged=false,west=false]").?);
    const air: u16 = @intCast(game_data.registry.blockStateId("minecraft:air").?);
    var edits: usize = 0;
    const ticks_before = try allocator.alloc(i32, mobs.mobs.len);
    defer allocator.free(ticks_before);
    for (mobs.mobs, ticks_before) |mob, *tick_count| tick_count.* = mob.tick_count;
    const searches_before = mobs.path_searches;
    const skipped_before = mobs.travels_skipped;
    const idle_before = mobs.idle_ticks;
    const run_before = mobs.travels_run;
    const recomputes_before = mobs.edit_recomputes;
    if (options.perf_control) |control| {
        const fifo = try std.Io.Dir.cwd().openFile(io, control, .{ .mode = .write_only });
        defer fifo.close(io);
        try fifo.writeStreamingAll(io, "enable\n");
    }
    const inventories = simulation.get(Inventories);
    const chunks = simulation.get(Chunks);
    const reads = inventories.cache.metrics.reads.value() + inventories.items.metrics.reads.value() + chunks.cache.metrics.reads.value();
    _ = simulation.metrics.snapshot(before);
    tick_time = 0;
    packets = 0;
    recipients = 0;
    for (0..options.samples) |sample| {
        const cpu = std.Io.Clock.now(.cpu_thread, io).nanoseconds;
        const wall = std.Io.Clock.now(.awake, io).nanoseconds;
        for (0..options.ticks) |tick| {
            if (options.paced) try std.Io.sleep(io, .fromMilliseconds(50), .awake);
            if (options.edit_interval > 0 and tick % options.edit_interval == 0) {
                // Eight spots among the cows in turn, each a fence one time and air again the next.
                const spot: i32 = @intCast((edits / 2) % 8);
                try simulation.get(Chunks).setBlock(spawn_world, .{ .x = 8 + 4 * (spot - 4), .y = 65, .z = 9 }, if (edits % 2 == 0) fence else air);
                edits += 1;
            }
            try advance(simulation, service, handles[0..count], payloads[tick % 2], mode, &packets, &recipients, &tick_time);
        }
        cpus[sample] = @intCast(std.Io.Clock.now(.cpu_thread, io).nanoseconds - cpu);
        walls[sample] = @intCast(std.Io.Clock.now(.awake, io).nanoseconds - wall);
    }
    // Cows walk into sections they have not read yet, so only a world without them is steady.
    if (options.cows == 0 and reads != inventories.cache.metrics.reads.value() + inventories.items.metrics.reads.value() + chunks.cache.metrics.reads.value()) return error.UnexpectedSteadyStateReads;
    const snapshots = simulation.metrics.snapshot(stages);
    std.mem.sort(u64, cpus, {}, std.sort.asc(u64));
    std.mem.sort(u64, walls, {}, std.sort.asc(u64));
    const ticks = options.ticks * options.samples;
    const tick_ns = tick_time / ticks;
    try writer.print("{s: <10} {d: >7} {d: >7} {d: >11.2} {d: >11.2} {d: >11.2} {d: >10.2} {d: >12.2}\n", .{ @tagName(mode), count, maximum, @as(f64, @floatFromInt(cpus[options.samples / 2])) / @as(f64, @floatFromInt(options.ticks)) / 1000, @as(f64, @floatFromInt(walls[options.samples / 2])) / @as(f64, @floatFromInt(options.ticks)) / 1000, @as(f64, @floatFromInt(tick_ns)) / 1000, @as(f64, @floatFromInt(packets)) / @as(f64, @floatFromInt(ticks)), @as(f64, @floatFromInt(recipients)) / @as(f64, @floatFromInt(ticks)) });
    var resting: usize = 0;
    var ticked: usize = 0;
    for (mobs.active.values()) |index| {
        if (mobs.mobs[index].resting) resting += 1;
        if (mobs.mobs[index].tick_count != ticks_before[index]) ticked += 1;
        const mob = &mobs.mobs[index];
        if (options.detail and !mob.resting and mob.tick_count != ticks_before[index] and ticked % 97 == 0) try writer.print("  awake {any} v={any} ground={} hc={} fall={d} water={}\n", .{ mob.position, mob.velocity, mob.on_ground, mob.horizontal_collision, mob.fall_distance, mob.touching_water });
    }
    if (options.cows > 0) try writer.print("  audience_changes={d} cows={d} ticked={d} resting={d} idle_ticks={d} travels_skipped={d} travels_run={d} path_searches={d:.3}/tick edits={d} edit_recomputes={d} edits_dropped={d} sections_decoded={d}\n", .{ simulation.get(vanilla.MobReplication).audience_changes, mobs.active.values().len, ticked, resting, mobs.idle_ticks - idle_before, mobs.travels_skipped - skipped_before, mobs.travels_run - run_before, @as(f64, @floatFromInt(mobs.path_searches - searches_before)) / @as(f64, @floatFromInt(ticks)), edits, mobs.edit_recomputes - recomputes_before, mobs.edits_dropped, mobs.copies.decoded });
    if (options.detail) for (snapshots, before[0..snapshots.len]) |after, previous| {
        if (after.kind == .counter) {
            const operations = after.value - previous.value;
            if (operations != 0) try writer.print("  {s} {d:.2} /tick\n", .{ after.name, @as(f64, @floatFromInt(operations)) / @as(f64, @floatFromInt(ticks)) });
            continue;
        }
        if (after.kind != .timer or !std.mem.endsWith(u8, after.name, ".tick")) continue;
        const calls = after.count - previous.count;
        if (calls == 0) continue;
        try writer.print("  {s} {d:.2} us/tick\n", .{ after.name, @as(f64, @floatFromInt(after.total - previous.total)) / @as(f64, @floatFromInt(ticks)) / 1000 });
    };
    try writer.flush();
}

fn advance(simulation: *Simulation, service: *sessions.Service, handles: []const sessions.Handle, payloads: []const [1][]const u8, mode: Mode, packets: *u64, recipients: *u64, tick_time: *u64) !void {
    for (handles) |handle| {
        service.credit[handle.index].store(@as(u64, handle.generation) << 32 | sessions.Service.active | service.config.buffer_bytes, .release);
        if (mode != .idle and mode != .boundary and (mode != .one_moving or handle.index == 0)) {
            service.releases[handle.index].store(0, .release);
            if (!service.push(.{ .input = .{ .handle = handle, .protocol = protocols.implementations[0].protocol_number, .packets = .{ .packets = &payloads[handle.index] } } })) return error.BenchmarkInputFull;
        }
    }
    const tick_started = std.Io.Clock.now(.awake, simulation.io).nanoseconds;
    const timer = simulation.server_tick.start();
    if (mode == .boundary) {
        service.beginTick();
        service.endTick(true);
        service.flush();
    } else try simulation.tick();
    timer.end();
    tick_time.* += @intCast(std.Io.Clock.now(.awake, simulation.io).nanoseconds - tick_started);
    var batch = service.outputBatch();
    while (batch.next()) |packet| {
        packets.* += 1;
        recipients.* += packet.recipients.len;
        service.recycle(simulation.io, &.{packet});
    }
    for (handles) |handle| _ = service.releases[handle.index].swap(0, .acq_rel);
}

pub fn main(init: std.process.Init) !void {
    var options: Options = .{};
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |argument| {
        if (std.mem.startsWith(u8, argument, "--players=")) {
            options.players = try std.fmt.parseInt(usize, argument[10..], 10);
        } else if (std.mem.startsWith(u8, argument, "--capacity=")) {
            options.capacity = try std.fmt.parseInt(usize, argument[11..], 10);
        } else if (std.mem.startsWith(u8, argument, "--pages=")) {
            options.pages = try std.fmt.parseInt(usize, argument[8..], 10);
        } else if (std.mem.startsWith(u8, argument, "--mode=")) {
            options.mode = std.meta.stringToEnum(Mode, argument[7..]) orelse return error.InvalidMode;
        } else if (std.mem.startsWith(u8, argument, "--ticks=")) {
            options.ticks = try std.fmt.parseInt(usize, argument[8..], 10);
        } else if (std.mem.startsWith(u8, argument, "--samples=")) {
            options.samples = try std.fmt.parseInt(usize, argument[10..], 10);
        } else if (std.mem.startsWith(u8, argument, "--cows=")) {
            options.cows = try std.fmt.parseInt(usize, argument[7..], 10);
        } else if (std.mem.startsWith(u8, argument, "--cow-spacing=")) {
            options.cow_spacing = try std.fmt.parseFloat(f64, argument[14..]);
        } else if (std.mem.startsWith(u8, argument, "--perf-control=")) {
            options.perf_control = argument[15..];
        } else if (std.mem.startsWith(u8, argument, "--settle=")) {
            options.settle = try std.fmt.parseInt(usize, argument[9..], 10);
        } else if (std.mem.startsWith(u8, argument, "--cow-offset=")) {
            options.cow_offset = try std.fmt.parseFloat(f64, argument[13..]);
        } else if (std.mem.startsWith(u8, argument, "--edit-interval=")) {
            options.edit_interval = try std.fmt.parseInt(usize, argument[16..], 10);
        } else if (std.mem.eql(u8, argument, "--detail")) {
            options.detail = true;
        } else if (std.mem.eql(u8, argument, "--paced")) {
            options.paced = true;
        } else if (std.mem.eql(u8, argument, "--no-instrumentation")) {
            options.instrumentation = false;
        } else return error.InvalidArgument;
    }
    if (options.pages == 0 or options.ticks == 0 or options.samples == 0 or options.samples > 99) return error.InvalidArgument;
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    try output.interface.writeAll("# Synthetic sessions, vanilla gameplay plus TPS, autosave off, terrain worker excluded. Boundary mode measures Sessions lifecycle without gameplay.\n# CPU/wall columns include harness work. Tick is mean simulation wall time including instrumentation. Pacing adds 50ms sleeps outside the tick.\n");
    try output.interface.writeAll("mode       players   slots      cpu_us     wall_us     tick_us    packets   recipients\n");
    const counts = [_]usize{ 0, 2, 16, 64, 256 };
    const selected_counts = [_]usize{options.players orelse 0};
    const selected: []const usize = if (options.players != null) &selected_counts else &counts;
    for (selected) |count| {
        for (std.enums.values(Mode)) |mode| {
            if (options.mode) |chosen| if (chosen != mode) continue;
            try run(std.heap.page_allocator, init.io, options, count, mode, &output.interface);
        }
    }
    try output.interface.flush();
}
