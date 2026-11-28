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
const BlockSynchronization = @import("terrain").block_sync.BlockSynchronization;
const Streaming = @import("terrain").streaming.Streaming;
const Terrain = @import("terrain").terrain.Terrain;
const Generation = @import("terrain").generation.Generation;

/// With --stream, the terrain work a server does beside the simulation, done on the same thread
/// after each tick, so players' streams open and entities reach them, the same every run.
var streamed: ?*Terrain = null;

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
    pages: usize = 1024,
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
    /// Ticks before anything is placed: with streaming, enough for every column to reach every
    /// client, so what is measured is the rest.
    warm: usize = 200,
    /// Every tick, tracking's answers held to the rule asked of every pair: slow, for checking.
    check_tracking: bool = false,
    /// Every cow in love once they settle, so they breed and their calves follow them.
    love: bool = false,
    /// Every player holds wheat once the cows settle, so the cows near follow them.
    tempt: bool = false,
    /// A perf control FIFO to enable recording on as measuring starts (perf record -D -1 --control).
    perf_control: ?[]const u8 = null,
    /// Ticks between block edits among the cows, a fence placed then taken away.
    edit_interval: usize = 0,
    /// Edits each edit interval puts among the cows at once, over four sections in one batch:
    /// fences one time, air the next.
    edit_flood: usize = 0,
    /// Block edits mobs hold for their paths; past them they answer early.
    mob_edits: u32 = 16384,
    /// Experience orbs scattered around the players, apart enough not to merge or follow anyone.
    orbs: usize = 0,
    /// Boats dropped in a grid around the players, three blocks apart, to land and rest.
    boats: usize = 0,
    /// After every measured tick, the kernel drops what it caches of the world's files, so
    /// reads reach the disk.
    drop_page_cache: bool = false,
    /// Arrows in a volley, shot from above the players by the first of them.
    arrows: usize = 0,
    /// Ticks between volleys while measuring; zero shoots one that lands before measuring.
    volley_interval: usize = 0,
    /// Dropped items spread around the players, left to settle before measuring.
    drops: usize = 0,
    /// Blocks between drops: wide enough, and the far ones lie beyond every player's view.
    drop_spacing: usize = 2,
    /// Items dropped together on each spot, of two kinds, to merge as they land.
    drop_stack: usize = 1,
    /// Flying arrows far from every player with their columns not forced: they freeze.
    unforced: bool = false,
    /// Drops stand on a stone platform, and every so many ticks the block under the next one
    /// goes, so it falls, on its own tick of four.
    drop_edits: usize = 0,
    /// Resting items tick every tick, as sleeping must match.
    no_item_sleep: bool = false,
    /// Arrows that fly the whole run: high above the world and far from players, they read no
    /// chunks and have no viewers, so what they cost is their ticks and their paging.
    flying: usize = 0,
    /// The measured tick before which projectiles save, forget and load again, as on a restart.
    restart_at: ?usize = null,
    /// MiB of memory entity state lives in, every kind's tables together: past it, the server stops.
    entity_memory: ?usize = null,
    /// Streams chunks to the players after each tick, as the terrain thread does, so replication
    /// sends what it would: off, players never see anything.
    stream: bool = false,
    /// Flying projectiles with nothing near sleep; off, every one ticks every tick.
    sleep: bool = true,
    /// Print a digest of every projectile and the packets so far after each measured tick, for
    /// runs with and without sleeping to be compared line by line.
    digest: bool = false,
    /// Storage through io_uring, as servers run, rather than buffered reads.
    uring: bool = false,
};

/// A volley of arrows from a cannon above the players, fanned out and falling within the
/// chunks around them.
fn volley(simulation: *Simulation, world: u32, count: usize, round: usize) !void {
    const projectiles = simulation.get(vanilla.Projectiles);
    const items = simulation.get(vanilla.Items);
    const arrow = try items.define("minecraft:arrow");
    for (0..count) |index| {
        // Between runs of spawns nothing is held: memory makes room for the next.
        if (index % 64 == 63) try simulation.get(vanilla.Entities).settle();
        const turn = @as(f64, @floatFromInt(index + round * 7)) * 2.399963;
        const direction: [3]f64 = .{ @cos(turn), 0.3, @sin(turn) };
        try projectiles.launch(.{
            .kind = .arrow,
            .world = world,
            .position = .{ 8.5, 72, 8.5 },
            .velocity = projectiles.aim(direction, 1.2, 1.0),
            .owner = 0,
            .stack = .{ .item = arrow, .count = 1 },
            .pickup = .disallowed,
        });
    }
}

/// `count` edits among the cows over the four sections around the middle, one batch, each a
/// spread of blocks a round picks.
fn flood(chunks: *Chunks, world: u32, count: usize, round: usize, state: u16) !void {
    var edits: [4][1024]@import("chunks").BlockEdit = undefined;
    var sections: [4]@import("chunks").SectionEdits = undefined;
    const each = @min(count / 4, 1024);
    for (&sections, &edits, 0..) |*section, *list, at| {
        for (list[0..each], 0..) |*edit, index| {
            // Spread over the section's floor and the layer above it, by a stride coprime to 512.
            const cell: u16 = @intCast(((index + round) * 197) % 512);
            edit.* = .{ .index = @intCast((1 + (cell >> 8)) << 8 | (cell & 0xff)), .state = state };
        }
        section.* = .{ .section = .{ .world = world, .x = @as(i32, @intCast(at % 2)) - 1, .y = 4, .z = @as(i32, @intCast(at / 2)) - 1 }, .edits = list[0..each] };
    }
    try chunks.setSections(&sections);
}

/// The block a drop on the platform stands on.
fn dropSupport(index: usize, side: usize) @import("chunks").Position {
    return .{ .x = -41 + @as(i32, @intCast(index % side)) * 2, .y = 99, .z = -41 + @as(i32, @intCast(index / side)) * 2 };
}

/// Arrows falling from far above, a block apart, a long way from every player.
fn flyers(simulation: *Simulation, world: u32, count: usize, forced: bool) !void {
    const projectiles = simulation.get(vanilla.Projectiles);
    const arrow = try simulation.get(vanilla.Items).define("minecraft:arrow");
    const side = std.math.sqrt(count) + 1;
    // No player is up there: the columns are forced to tick, or the arrows would freeze.
    const domains = simulation.get(vanilla.Domains);
    var x: i32 = @divFloor(100_000, 16);
    while (forced and x <= @divFloor(100_000 + @as(i32, @intCast(side)), 16)) : (x += 1) {
        var z: i32 = @divFloor(100_000, 16);
        while (z <= @divFloor(100_000 + @as(i32, @intCast(side)), 16)) : (z += 1) try domains.force(.{ .world = world, .x = x, .z = z });
    }
    for (0..count) |index| {
        // Between runs of spawns nothing is held: memory makes room for the next.
        if (index % 64 == 63) try simulation.get(vanilla.Entities).settle();
        try projectiles.launch(.{
            .kind = .arrow,
            .world = world,
            .position = .{ 100_000.5 + @as(f64, @floatFromInt(index % side)), 4000, 100_000.5 + @as(f64, @floatFromInt(index / side)) },
            .velocity = .{ 0, 0, 0 },
            .owner = 0,
            .stack = .{ .item = arrow, .count = 1 },
            .pickup = .disallowed,
        });
    }
}

fn run(allocator: std.mem.Allocator, io: std.Io, options: Options, count: usize, mode: Mode, writer: *std.Io.Writer) !void {
    var memory = lightning_rod.Memory.init(allocator, io);
    defer memory.deinit();
    const backing = memory.allocator("tick-bench");
    const directory = try std.fmt.allocPrint(backing, ".zig-cache/tick-bench/{d}-{d}-{s}", .{ std.os.linux.getpid(), count, @tagName(mode) });
    try std.Io.Dir.cwd().createDirPath(io, directory);
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    const path = try std.fmt.allocPrint(backing, "{s}/world", .{directory});
    var store = try lightning_rod.storage.Store.init(backing, io, .{ .path = path, .io_mode = if (options.uring) .uring else .standard });
    defer store.deinit();
    // The page cache belongs to the file, so descriptors of our own can drop it.
    var cached_files: [2]?std.Io.File = .{ null, null };
    defer for (cached_files) |file| if (file) |open| open.close(io);
    if (options.drop_page_cache) for (&cached_files, [_][]const u8{ "", ".wal" }) |*file, suffix| {
        const name = try std.fmt.allocPrint(backing, "{s}{s}", .{ path, suffix });
        file.* = try std.Io.Dir.cwd().openFile(io, name, .{});
    };
    var sink: Sink = .{};
    var catalog = try protocols.Default.init(backing);
    defer catalog.deinit(backing);
    const selected = &catalog.values;
    const maximum = options.capacity orelse @max(32, count);
    if (maximum < count or maximum == 0) return error.InvalidCapacity;
    const service = try sessions.Service.init(backing, io, .{ .context = &sink, .vtable = network.Transport.adapter(Sink) }, .{ .connections = maximum, .pages = options.pages, .page_bytes = 65536, .credit_bytes = 128 * 1024, .protocols = selected });
    defer service.deinit();
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(vanilla.plugins(), .{
            lightning_rod.plugin.configured(Players, .{ .maximum = maximum, .render_distance = 8 }),
            lightning_rod.plugin.configured(Chunks, Chunks.Configuration.forPlayers(maximum)),
            lightning_rod.plugin.configured(vanilla.Entities, .{ .memory = if (options.entity_memory) |mib| mib * 1024 * 1024 else 64 * 1024 * 1024 }),
            lightning_rod.plugin.configured(vanilla.Mobs, .{ .edits = options.mob_edits }),
            lightning_rod.plugin.configured(vanilla.Projectiles, .{ .sleep = options.sleep }),
            lightning_rod.plugin.configured(vanilla.ProjectileReplication, .{ .trace_sends = options.digest }),
            lightning_rod.plugin.configured(vanilla.ItemEntities, .{ .sleep = !options.no_item_sleep }),
            lightning_rod.plugin.configured(vanilla.MobReplication, .{ .trace_sends = options.digest }),
            lightning_rod.plugin.configured(vanilla.ItemReplication, .{ .trace_sends = options.digest }),
            lightning_rod.plugin.configured(vanilla.ExperienceReplication, .{ .trace_sends = options.digest }),
            lightning_rod.plugin.configured(vanilla.BoatReplication, .{ .trace_sends = options.digest }),
            lightning_rod.plugin.configured(Inventories, .{ .cache_items = 10 }),
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
    if (options.digest) {
        wire_streams = try backing.alloc(u64, count);
        @memset(wire_streams, 0);
    }
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
    try players.rebuildIndexes();
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
        try writer.print("# replication_records_bytes={d} mining_masks_bytes={d} equipment_masks_bytes={d}\n", .{ replication.lifecycle.memoryBytes(), mining.selections.memoryBytes(), equipment.selections.memoryBytes() });
    }
    // Streaming asks for chunks the tick never reads, which only a worker generates, as the
    // server's do.
    const generation: ?*Generation = if (options.stream) try Generation.init(backing, io, simulation.get(Chunks).generation, 1) else null;
    defer if (generation) |worker| worker.deinit();
    if (generation) |worker| try worker.start();
    defer if (generation) |worker| worker.stop();
    memory.seal();
    var terrain: Terrain = .{ .chunks = simulation.get(Chunks), .streaming = simulation.get(Streaming), .blocks = simulation.get(BlockSynchronization), .io = io };
    if (options.stream) {
        terrain.start();
        streamed = &terrain;
    }
    defer if (options.stream) {
        streamed = null;
        terrain.stop();
    };
    var tick_time: u64 = 0;
    var packets: u64 = 0;
    var recipients: u64 = 0;
    checking_tracking = options.check_tracking;
    for (0..options.warm) |tick| try advance(simulation, service, handles[0..count], payloads[tick % 2], mode, &packets, &recipients, &tick_time);
    const mobs = simulation.get(vanilla.Mobs);
    const cow_species = simulation.get(vanilla.Cow).species;
    if (options.cows > 0) {
        // A square field on the flat grass, its middle east of the players at 8, 8 by the offset.
        const side = std.math.sqrt(options.cows - 1) + 1;
        for (0..options.cows) |index| {
            const x = 8.5 + options.cow_offset + options.cow_spacing * (@as(f64, @floatFromInt(index % side)) - @as(f64, @floatFromInt(side / 2)));
            const z = 8.5 + options.cow_spacing * (@as(f64, @floatFromInt(index / side)) - @as(f64, @floatFromInt(side / 2)));
            _ = try mobs.spawn(.{ .species = cow_species, .world = spawn_world, .position = .{ x, 65, z }, .yaw = 0 });
            // Between runs of spawns nothing is held: memory makes room for the next.
            if (index % 64 == 63) try simulation.get(vanilla.Entities).settle();
        }
        for (0..options.settle) |tick| try advance(simulation, service, handles[0..count], payloads[tick % 2], mode, &packets, &recipients, &tick_time);
        if (options.love) for (0..mobs.active.count) |active_at| {
            const index = mobs.active.at(active_at);
            try mobs.setInLove((try mobs.get(simulation.get(vanilla.Entities).directory.entry(@intCast(index)).id)).?, null);
        };
        if (options.tempt) {
            const wheat = try simulation.get(vanilla.Items).define("minecraft:wheat");
            const held = simulation.get(Inventories);
            for (players.records[0..count]) |player| {
                const at: @import("inventories").Slot = .{ .owner = player.uuid, .index = 36 + @as(u16, player_states.of(&player).selected_slot) };
                const was = try held.get(at);
                if (!try held.set(at, was.revision, .{ .item = wheat, .count = 1 })) return error.WheatConflict;
            }
        }
    }
    if (options.arrows > 0 and options.volley_interval == 0) {
        if (count == 0) return error.ArrowsNeedAPlayer;
        try volley(simulation, spawn_world, options.arrows, 0);
        for (0..100) |tick| {
            try advance(simulation, service, handles[0..count], payloads[tick % 2], mode, &packets, &recipients, &tick_time);
            if (options.detail and tick % 10 == 0) try writer.print("  settle tick={d} arrows={d}\n", .{ tick, simulation.get(vanilla.Projectiles).activeCount() });
        }
    }
    if (options.drops > 0) {
        const dropped = simulation.get(vanilla.ItemEntities);
        const stone = try simulation.get(vanilla.Items).define("minecraft:stone");
        const dirt = try simulation.get(vanilla.Items).define("minecraft:dirt");
        const side = std.math.sqrt(options.drops) + 1;
        for (0..options.drops) |index| {
            // Two blocks apart, so they do not merge, in the chunks around the players.
            const spacing: f64 = @floatFromInt(options.drop_spacing);
            const x: f64 = -40.5 + @as(f64, @floatFromInt(index % side)) * spacing;
            const z: f64 = -40.5 + @as(f64, @floatFromInt(index / side)) * spacing;
            if (options.drop_edits > 0) try simulation.get(Chunks).setBlock(spawn_world, dropSupport(index, side), game_data.registry.block_stone_default_state);
            for (0..options.drop_stack) |level| {
                const offset: f64 = @floatFromInt(level);
                const kind = if (level % 3 == 2) dirt else stone;
                _ = try dropped.create(spawn_world, .{ x + offset * 0.07, (if (options.drop_edits > 0) @as(f64, 100) else 90) + offset * 0.3, z - offset * 0.05 }, .{ offset * 0.01, 0, 0 }, .{ .item = kind, .count = 1 });
            }
            // Between runs of spawns nothing is held: memory makes room for the next.
            if (index % 64 == 63) try simulation.get(vanilla.Entities).settle();
        }
        for (0..200) |tick| {
            try advance(simulation, service, handles[0..count], payloads[tick % 2], mode, &packets, &recipients, &tick_time);
            if (options.digest) try writer.print("settle tick={d} items={x} asleep={d}\n", .{ tick, try simulation.get(vanilla.ItemEntities).digest(), simulation.get(vanilla.ItemEntities).asleepCount() });
        }
    }
    if (options.orbs > 0) {
        const experience = simulation.get(vanilla.Experience);
        const side = std.math.sqrt(options.orbs) + 1;
        for (0..options.orbs) |index| {
            // Three blocks apart, more than an orb's merge reach, and out past the players' pull.
            const x: f64 = 40.5 + @as(f64, @floatFromInt(index % side)) * 3;
            const z: f64 = 40.5 + @as(f64, @floatFromInt(index / side)) * 3;
            try experience.award(spawn_world, .{ x, 70, z }, 1 + @as(i32, @intCast(index % 7)));
            // Between runs of spawns nothing is held: memory makes room for the next.
            if (index % 64 == 63) try simulation.get(vanilla.Entities).settle();
        }
    }
    if (options.boats > 0) {
        const boats = simulation.get(vanilla.Boats);
        const side = std.math.sqrt(options.boats) + 1;
        for (0..options.boats) |index| {
            // Three blocks apart, more than a boat is wide, in the chunks around the players.
            const x: f64 = -40.5 + @as(f64, @floatFromInt(index % side)) * 3;
            const z: f64 = 20.5 + @as(f64, @floatFromInt(index / side)) * 3;
            _ = try boats.spawn(.{ .model = .{ .variant = @fromBackingInt(@intCast(index % 10)) }, .world = spawn_world, .position = .{ x, 80, z } });
            // Between runs of spawns nothing is held: memory makes room for the next.
            if (index % 64 == 63) try simulation.get(vanilla.Entities).settle();
        }
    }
    if (options.flying > 0) {
        if (count == 0) return error.ArrowsNeedAPlayer;
        try flyers(simulation, spawn_world, options.flying, !options.unforced);
        for (0..40) |tick| {
            try advance(simulation, service, handles[0..count], payloads[tick % 2], mode, &packets, &recipients, &tick_time);
            if (options.digest) try writer.print("warm tick={d} projectiles={x} sent={x} sleeping={d}\n", .{ tick, try simulation.get(vanilla.Projectiles).digest(), simulation.get(vanilla.ProjectileReplication).traced(), simulation.get(vanilla.Projectiles).sleepingCount() });
        }
    }
    var volleys: usize = 0;
    const fence: u16 = @intCast(game_data.registry.blockStateId("minecraft:oak_fence[east=false,north=false,south=false,waterlogged=false,west=false]").?);
    const air: u16 = @intCast(game_data.registry.blockStateId("minecraft:air").?);
    var edits: usize = 0;
    const ticks_before = try allocator.alloc(i32, mobs.slotCount());
    defer allocator.free(ticks_before);
    for (0..mobs.active.count) |active_at| {
        const index = mobs.active.at(active_at);
        ticks_before[index] = (try mobs.copyAt(@intCast(index))).idle.tick_count;
    }
    const searches_before = mobs.path_searches;
    const skipped_before = mobs.travels_skipped;
    const idle_before = mobs.idle_ticks;
    const blocks_before = mobs.idle_blocks;
    const rare_before = mobs.rare_lanes;
    const run_before = mobs.travels_run;
    const recomputes_before = mobs.edit_recomputes;
    const tracking_before = simulation.get(vanilla.Tracking).stats;
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
    // Every thread's, the store's readers among them.
    var process_cpus: u64 = 0;
    for (0..options.samples) |sample| {
        const cpu = std.Io.Clock.now(.cpu_thread, io).nanoseconds;
        const process_cpu = std.Io.Clock.now(.cpu_process, io).nanoseconds;
        const wall = std.Io.Clock.now(.awake, io).nanoseconds;
        for (0..options.ticks) |tick| {
            if (options.paced) try std.Io.sleep(io, .fromMilliseconds(50), .awake);
            if (options.edit_flood > 0 and options.edit_interval > 0 and tick % options.edit_interval == 0) {
                try flood(simulation.get(Chunks), spawn_world, options.edit_flood, tick / options.edit_interval, if ((tick / options.edit_interval) % 2 == 0) fence else air);
            } else if (options.edit_interval > 0 and tick % options.edit_interval == 0) {
                // Eight spots among the cows in turn, each a fence one time and air again the next.
                const spot: i32 = @intCast((edits / 2) % 8);
                try simulation.get(Chunks).setBlock(spawn_world, .{ .x = 8 + 4 * (spot - 4), .y = 65, .z = 9 }, if (edits % 2 == 0) fence else air);
                edits += 1;
            }
            if (options.drop_edits > 0 and tick % options.drop_edits == 0) {
                const side = std.math.sqrt(options.drops) + 1;
                const index = (tick / options.drop_edits) % options.drops;
                try simulation.get(Chunks).setBlock(spawn_world, dropSupport(index, side), game_data.registry.block_air_default_state);
            }
            if (options.arrows > 0 and options.volley_interval > 0 and tick % options.volley_interval == 0) {
                if (count == 0) return error.ArrowsNeedAPlayer;
                try volley(simulation, spawn_world, options.arrows, volleys);
                volleys += 1;
            }
            if (options.restart_at == tick) try simulation.get(vanilla.Projectiles).restart();
            try advance(simulation, service, handles[0..count], payloads[tick % 2], mode, &packets, &recipients, &tick_time);
            for (cached_files) |file| if (file) |open| {
                _ = std.os.linux.fadvise(open.handle, 0, 0, std.os.linux.POSIX_FADV.DONTNEED);
            };
            if (options.digest) try writer.print("digest tick={d} mobs={x} orbs={x} projectiles={x} sent={x} items={x} mob_sent={x} item_sent={x} orb_sent={x} boats={x} boat_sent={x} packets={d} recipients={d} sleeping={d} items_asleep={d} wire={x}\n", .{ tick, try mobs.digest(), try simulation.get(vanilla.Experience).digest(), try simulation.get(vanilla.Projectiles).digest(), simulation.get(vanilla.ProjectileReplication).traced(), try simulation.get(vanilla.ItemEntities).digest(), simulation.get(vanilla.MobReplication).traced(), simulation.get(vanilla.ItemReplication).traced(), simulation.get(vanilla.ExperienceReplication).traced(), try simulation.get(vanilla.Boats).digest(), simulation.get(vanilla.BoatReplication).traced(), packets, recipients, simulation.get(vanilla.Projectiles).sleepingCount(), simulation.get(vanilla.ItemEntities).asleepCount(), wireDigest() });
        }
        cpus[sample] = @intCast(std.Io.Clock.now(.cpu_thread, io).nanoseconds - cpu);
        process_cpus += @intCast(std.Io.Clock.now(.cpu_process, io).nanoseconds - process_cpu);
        walls[sample] = @intCast(std.Io.Clock.now(.awake, io).nanoseconds - wall);
    }
    if (options.perf_control) |control| {
        const fifo = try std.Io.Dir.cwd().openFile(io, control, .{ .mode = .write_only });
        defer fifo.close(io);
        try fifo.writeStreamingAll(io, "disable\n");
    }
    // Cows walk into sections they have not read yet, so only a world without them is steady.
    // Items streaming through caches smaller than they are read on purpose, as are columns streamed.
    if (!options.stream and options.cows == 0 and options.orbs == 0 and options.volley_interval == 0 and options.drop_edits == 0 and reads != inventories.cache.metrics.reads.value() + inventories.items.metrics.reads.value() + chunks.cache.metrics.reads.value()) return error.UnexpectedSteadyStateReads;
    const snapshots = simulation.metrics.snapshot(stages);
    std.mem.sort(u64, cpus, {}, std.sort.asc(u64));
    std.mem.sort(u64, walls, {}, std.sort.asc(u64));
    const ticks = options.ticks * options.samples;
    const tick_ns = tick_time / ticks;
    try writer.print("{s: <10} {d: >7} {d: >7} {d: >11.2} {d: >11.2} {d: >11.2} {d: >10.2} {d: >12.2}\n", .{ @tagName(mode), count, maximum, @as(f64, @floatFromInt(cpus[options.samples / 2])) / @as(f64, @floatFromInt(options.ticks)) / 1000, @as(f64, @floatFromInt(walls[options.samples / 2])) / @as(f64, @floatFromInt(options.ticks)) / 1000, @as(f64, @floatFromInt(tick_ns)) / 1000, @as(f64, @floatFromInt(packets)) / @as(f64, @floatFromInt(ticks)), @as(f64, @floatFromInt(recipients)) / @as(f64, @floatFromInt(ticks)) });
    try writer.print("  process_cpu={d:.2}us/tick (every thread)\n", .{@as(f64, @floatFromInt(process_cpus)) / @as(f64, @floatFromInt(ticks)) / 1000});
    var resting: usize = 0;
    var ticked: usize = 0;
    for (0..mobs.active.count) |active_at| {
        const index = mobs.active.at(active_at);
        const copy = try mobs.copyAt(@intCast(index));
        const mob = &copy;
        if (mob.motion.resting) resting += 1;
        if (mob.idle.tick_count != ticks_before[index]) ticked += 1;
        if (options.detail and !mob.motion.resting and mob.idle.tick_count != ticks_before[index] and ticked % 97 == 0) try writer.print("  awake {any} v={any} ground={} hc={} fall={d} water={}\n", .{ mob.motion.position, mob.motion.velocity, mob.motion.on_ground, mob.motion.horizontal_collision, mob.motion.fall_distance, mob.entity.touching_water });
    }
    {
        const pool = &simulation.get(vanilla.Entities).pool;
        const held = simulation.get(vanilla.Entities);
        try writer.print("  entity pool pages={d} used={d} entities={d}\n", .{ pool.pageCount(), pool.pageCount() - pool.freeCount(), held.directory.count() });
    }
    {
        const tracking = simulation.get(vanilla.Tracking);
        const done = tracking.stats;
        const was = tracking_before;
        const per: f64 = @floatFromInt(ticks);
        try writer.print("  tracking logged={d:.1} quiet={d:.1} anchored={d:.2} slack_moves={d:.1} columns={d:.1} measured={d:.1} asked={d:.1} changed={d:.1} near={d:.1} walks={d:.2} boxes={d:.1} exact={d:.2} tiles={d} /tick\n", .{ @as(f64, @floatFromInt(done.logged - was.logged)) / per, @as(f64, @floatFromInt(done.logged_quiet - was.logged_quiet)) / per, @as(f64, @floatFromInt(done.anchored - was.anchored)) / per, @as(f64, @floatFromInt(done.slack_moves - was.slack_moves)) / per, @as(f64, @floatFromInt(done.columns - was.columns)) / per, @as(f64, @floatFromInt(done.measured - was.measured)) / per, @as(f64, @floatFromInt(done.asked - was.asked)) / per, @as(f64, @floatFromInt(done.changed - was.changed)) / per, @as(f64, @floatFromInt(done.near_measured - was.near_measured)) / per, @as(f64, @floatFromInt(done.edge_walks - was.edge_walks)) / per, @as(f64, @floatFromInt(done.boxes - was.boxes)) / per, @as(f64, @floatFromInt(done.exact - was.exact)) / per, done.tiles_made });
    }
    if (options.arrows > 0 or options.flying > 0) try writer.print("  arrows={d} ticking={d} volleys={d} sleeping={d}\n", .{ simulation.get(vanilla.Projectiles).activeCount(), simulation.get(vanilla.Projectiles).tickingCount(), volleys, simulation.get(vanilla.Projectiles).sleepingCount() });
    if (options.cows > 0) try writer.print("  domain_revision={d} audience_changes={d} cows={d} ticked={d} resting={d} idle_ticks={d} blocks={d} rare_lanes={d} travels_skipped={d} travels_run={d} path_searches={d:.3}/tick edits={d} edit_recomputes={d} edits_answered_early={d} sections_decoded={d}\n", .{ mobs.domain_revision, simulation.get(vanilla.MobReplication).audience_changes, mobs.active.count, ticked, resting, mobs.idle_ticks - idle_before, mobs.idle_blocks - blocks_before, mobs.rare_lanes - rare_before, mobs.travels_skipped - skipped_before, mobs.travels_run - run_before, @as(f64, @floatFromInt(mobs.path_searches - searches_before)) / @as(f64, @floatFromInt(ticks)), edits, mobs.edit_recomputes - recomputes_before, mobs.edits_answered_early, simulation.get(vanilla.Levels).copies.decoded });
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

/// Whether each tick holds tracking to the rule, as `--check-tracking` asks.
var checking_tracking = false;

/// Each player's stream of packets so far, hashed, when digests are asked: what clients receive,
/// however replication groups its sends.
var wire_streams: []u64 = &.{};

/// boss_bar in 1.21.8, the release the check builds: other releases hash it too.
const boss_bar_id: ?u8 = if (protocols.implementations[0].protocol_number == 772) 9 else null;

/// A packet's id, its first varint: 255 for one too short to have it.
fn packetId(bytes: []const u8) u8 {
    var at: usize = 0;
    const id = varint(bytes, &at) orelse return 255;
    return @intCast(@min(id, 255));
}

fn varint(bytes: []const u8, at: *usize) ?u32 {
    var value: u32 = 0;
    var shift: u5 = 0;
    while (at.* < bytes.len) {
        const byte = bytes[at.*];
        at.* += 1;
        value |= @as(u32, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return value;
        if (shift == 28) return null;
        shift += 7;
    }
    return null;
}

fn wireDigest() u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.sliceAsBytes(wire_streams));
    return hasher.final();
}

fn advance(simulation: *Simulation, service: *sessions.Service, handles: []const sessions.Handle, payloads: []const [1][]const u8, mode: Mode, packets: *u64, recipients: *u64, tick_time: *u64) !void {
    for (handles) |handle| {
        service.credit[handle.index].store(@as(u64, handle.generation) << 32 | sessions.Service.active | service.config.credit_bytes, .release);
        if (mode != .idle and mode != .boundary and (mode != .one_moving or handle.index == 0)) {
            service.releases[handle.index].store(0, .release);
            if (!service.push(.{ .input = .{ .handle = handle, .protocol = protocols.implementations[0].protocol_number, .packets = .{ .packets = &payloads[handle.index] } } })) return error.BenchmarkInputFull;
        }
    }
    // As a server does: a bound nearly reached stops it before the next tick.
    if (simulation.stopReason()) |reason| return reason;
    const tick_started = std.Io.Clock.now(.awake, simulation.io).nanoseconds;
    const timer = simulation.server_tick.start();
    if (mode == .boundary) {
        service.beginTick();
        service.endTick(true);
        service.flush();
    } else try simulation.tick();
    if (checking_tracking) try simulation.get(vanilla.Tracking).check();
    if (streamed) |terrain| try terrain.poll();
    timer.end();
    tick_time.* += @intCast(std.Io.Clock.now(.awake, simulation.io).nanoseconds - tick_started);
    var batch = service.outputBatch();
    while (batch.next()) |packet| {
        // Packet by packet, as each recipient's client gets them, however they were packed.
        var pieces = sessions.Pieces.of(packet);
        while (pieces.next()) |bytes| {
            packets.* += 1;
            recipients.* += packet.recipients.len;
            if (wire_streams.len != 0) {
                // The bench's boss bar shows its tick times, which no two runs share.
                if (packetId(bytes) == boss_bar_id) continue;
                var each = packet.recipients.iterator();
                while (each.next()) |handle| wire_streams[handle.index] = std.hash.Wyhash.hash(wire_streams[handle.index], bytes);
            }
        }
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
        } else if (std.mem.eql(u8, argument, "--love")) {
            options.love = true;
        } else if (std.mem.eql(u8, argument, "--tempt")) {
            options.tempt = true;
        } else if (std.mem.startsWith(u8, argument, "--settle=")) {
            options.settle = try std.fmt.parseInt(usize, argument[9..], 10);
        } else if (std.mem.startsWith(u8, argument, "--cow-offset=")) {
            options.cow_offset = try std.fmt.parseFloat(f64, argument[13..]);
        } else if (std.mem.startsWith(u8, argument, "--arrows=")) {
            options.arrows = try std.fmt.parseInt(usize, argument[9..], 10);
        } else if (std.mem.startsWith(u8, argument, "--restart-at=")) {
            options.restart_at = try std.fmt.parseInt(usize, argument[13..], 10);
        } else if (std.mem.eql(u8, argument, "--stream")) {
            options.stream = true;
        } else if (std.mem.startsWith(u8, argument, "--entity-memory=")) {
            options.entity_memory = try std.fmt.parseInt(usize, argument[16..], 10);
        } else if (std.mem.eql(u8, argument, "--unforced")) {
            options.unforced = true;
        } else if (std.mem.startsWith(u8, argument, "--drop-stack=")) {
            options.drop_stack = try std.fmt.parseInt(usize, argument[13..], 10);
        } else if (std.mem.startsWith(u8, argument, "--drop-spacing=")) {
            options.drop_spacing = try std.fmt.parseInt(usize, argument[15..], 10);
        } else if (std.mem.startsWith(u8, argument, "--drop-edits=")) {
            options.drop_edits = try std.fmt.parseInt(usize, argument[13..], 10);
        } else if (std.mem.eql(u8, argument, "--no-item-sleep")) {
            options.no_item_sleep = true;
        } else if (std.mem.startsWith(u8, argument, "--drops=")) {
            options.drops = try std.fmt.parseInt(usize, argument[8..], 10);
        } else if (std.mem.eql(u8, argument, "--check-tracking")) {
            options.check_tracking = true;
        } else if (std.mem.startsWith(u8, argument, "--warm=")) {
            options.warm = try std.fmt.parseInt(usize, argument[7..], 10);
        } else if (std.mem.startsWith(u8, argument, "--flying=")) {
            options.flying = try std.fmt.parseInt(usize, argument[9..], 10);
        } else if (std.mem.startsWith(u8, argument, "--volley-interval=")) {
            options.volley_interval = try std.fmt.parseInt(usize, argument[18..], 10);
        } else if (std.mem.startsWith(u8, argument, "--edit-interval=")) {
            options.edit_interval = try std.fmt.parseInt(usize, argument[16..], 10);
        } else if (std.mem.eql(u8, argument, "--detail")) {
            options.detail = true;
        } else if (std.mem.eql(u8, argument, "--no-sleep")) {
            options.sleep = false;
        } else if (std.mem.startsWith(u8, argument, "--edit-flood=")) {
            options.edit_flood = try std.fmt.parseInt(usize, argument[13..], 10);
        } else if (std.mem.startsWith(u8, argument, "--orbs=")) {
            options.orbs = try std.fmt.parseInt(usize, argument[7..], 10);
        } else if (std.mem.startsWith(u8, argument, "--boats=")) {
            options.boats = try std.fmt.parseInt(usize, argument[8..], 10);
        } else if (std.mem.eql(u8, argument, "--drop-page-cache")) {
            options.drop_page_cache = true;
        } else if (std.mem.startsWith(u8, argument, "--mob-edits=")) {
            options.mob_edits = try std.fmt.parseInt(u32, argument[12..], 10);
        } else if (std.mem.eql(u8, argument, "--digest")) {
            options.digest = true;
        } else if (std.mem.eql(u8, argument, "--uring")) {
            options.uring = true;
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
