const std = @import("std");
const production = @import("section_visibility_world.zig");
const streaming = @import("streaming.zig");
const reference = @import("visibility_bench.zig");
const chunks = @import("chunks");
const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const worlds = @import("worlds");
const lighting = @import("lighting.zig");
const visibility = @import("section_visibility.zig");
const section_hull = @import("section_hull.zig");
const chunk_encoding = @import("chunk_encoding.zig");
const chunk_horizon = @import("chunk_horizon.zig");
const game_data = @import("game_data");
const sessions = @import("sessions");
const protocols = @import("protocols");
const packets = @import("minecraft_packets");
const assert = std.debug.assert;

const Options = struct {
    world: ?[]const u8 = null,
    radius: u8 = 32,
    players: usize = 32,
    clusters: usize = 1,
    spacing: u32 = 0,
    head: [3]i32 = .{ 8, 150, 8 },
    oracle: bool = true,
    edit_repeat: usize = 0,
    movement_steps: usize = 0,
    speed: u32 = 80,
    bytes: bool = false,
    hull: bool = false,
    /// Columns farther than the radius plus this many chunks are forgotten by the client and
    /// sent again on return. Null keeps every column forever.
    unload_slack: ?i32 = null,
    /// Travel out for half the ticks, then back along the same path.
    round_trip: bool = false,
};

const Overlay = struct { section: chunks.Section, solid: [64]u64 };

const Baker = struct {
    terrain: *chunks.Chunks,
    geometry: production.World,
    world: u32,
    minimum: i32,
    height: usize,
    radius: u8,
    prepared: []chunks.classification.Prepared,
    classified: []chunks.encoding.Classification,
    summaries: []chunks.classification.ColumnSummary,
    overlays: [8]Overlay = undefined,
    overlay_count: usize = 0,
    // Per player, as streaming tracks it, so fast flight keeps section-wide reuse.
    paces: []production.Pace,

    fn init(allocator: std.mem.Allocator, terrain: *chunks.Chunks, world: u32, minimum: i32, height: usize, radius: u8, views: usize) !Baker {
        if (height == 0 or height > lighting.maximum_sections) return error.UnsupportedWorldHeight;
        const metadata = try streaming.Streaming.prepareMetadata(allocator, terrain);
        const prepared = try allocator.alloc(chunks.classification.Prepared, production.World.batch_max);
        const buffers = try allocator.alloc([production.prepared_codec.maximum]u8, prepared.len);
        for (prepared, buffers) |*entry, *buffer| entry.* = .{ .bytes = buffer };
        const side = 2 * @as(usize, radius) + 1;
        return .{
            .terrain = terrain,
            .geometry = try .init(allocator, .{ .columns = (side + 2) * (side + 2), .summary_columns = (side + 2) * (side + 2) * views, .views = views, .radius = radius, .properties = metadata.properties }),
            .world = world,
            .minimum = minimum,
            .height = height,
            .radius = radius,
            .prepared = prepared,
            .classified = try allocator.alloc(chunks.encoding.Classification, prepared.len),
            .summaries = try allocator.alloc(chunks.classification.ColumnSummary, chunks.classification.column_batch_max),
            .paces = paces: {
                const paces = try allocator.alloc(production.Pace, views);
                @memset(paces, .{});
                break :paces paces;
            },
        };
    }

    fn overlay(self: *Baker, section: chunks.Section) ?*Overlay {
        for (self.overlays[0..self.overlay_count]) |*entry| if (std.meta.eql(entry.section, section)) return entry;
        return null;
    }

    fn learnSources(self: *Baker, positions: []const chunks.Section) !void {
        assert(positions.len > 0 and positions.len <= production.World.batch_max);
        var reads: [production.World.batch_max]chunks.Chunks.ClassificationRequest = undefined;
        var disk: [production.World.batch_max]chunks.Chunks.ClassificationRequest = undefined;
        var disk_count: usize = 0;
        for (positions, 0..) |position, index| {
            self.prepared[index].length = 0;
            reads[index] = .{ .section = position, .result = &self.classified[index], .prepared = &self.prepared[index] };
            if (self.overlay(position)) |entry| {
                const bits: @Vector(64, u64) = entry.solid;
                const common: u8 = if (@reduce(.Or, bits) == 0) 2 else if (@reduce(.And, bits) == std.math.maxInt(u64)) production.occluder_property else 0;
                self.classified[index] = .{ .known = .{ .common = common, .property = production.occluder_property, .selected = entry.solid } };
            } else {
                disk[disk_count] = reads[index];
                disk_count += 1;
            }
        }
        if (disk_count != 0) try self.terrain.classify(disk[0..disk_count], self.geometry.properties, production.occluder_property);
        for (self.classified[0..positions.len], positions) |value, position| if (value == .unavailable) {
            std.log.err("missing baked visibility at world={d} section={d},{d},{d}", .{ position.world, position.x, position.y, position.z });
            return error.MissingStoredVisibility;
        };
        _ = try self.geometry.learnClassifications(reads[0..positions.len], self.minimum, self.height, .source);
    }

    fn solve(self: *Baker, index: usize, point: [3]i32, masks: []u32, force: bool) !void {
        if (force) self.geometry.invalidateView(index);
        self.paces[index].observe(point);
        const precision = self.paces[index].precision();
        if (!force and self.geometry.reuse(index, self.world, point, self.minimum, self.height, self.radius, precision)) {
            @memcpy(masks, self.geometry.views[index].masks);
            return;
        }
        var positions: [27]chunks.Section = undefined;
        const required = production.World.sourceRequirements(self.world, self.minimum, self.height, point, &positions);
        for (required) |section| if (!self.geometry.known(section, self.minimum, self.height)) {
            try self.learnSources(required);
            break;
        };
        var origin: production.Source = undefined;
        const source = self.geometry.narrowSource(self.world, self.minimum, self.height, point, precision, &origin) orelse return error.MissingSource;
        if (source.cells == 0) return error.ObserverInsideOccluder;
        self.geometry.begin(index, source, self.minimum, self.height, self.radius);
        var steps: usize = 0;
        while (!self.geometry.ready(index)) : (steps += 1) {
            assert(steps < 16 * masks.len * self.height);
            const advanced = self.geometry.advance();
            if (advanced.requests.len != 0) try self.learnColumns(advanced.requests);
        }
        assert(masks.len == self.geometry.views[index].masks.len);
        @memcpy(masks, self.geometry.views[index].masks);
    }

    fn learnColumns(self: *Baker, columns: []const chunks.classification.Column) !void {
        assert(columns.len > 0 and columns.len <= self.summaries.len);
        const summaries = self.summaries[0..columns.len];
        try self.terrain.summarize(columns, summaries, self.geometry.properties, production.occluder_property);
        for (columns, summaries) |column, *summary_| {
            for (self.overlays[0..self.overlay_count]) |entry| {
                if (entry.section.world != column.world or entry.section.x != column.x or entry.section.z != column.z) continue;
                const offset = entry.section.y - column.minimum;
                if (offset < 0 or offset >= column.count) continue;
                const at: usize = @intCast(offset);
                const bit = @as(u32, 1) << @intCast(at);
                const bits: @Vector(64, u64) = entry.solid;
                const common: u8 = if (@reduce(.Or, bits) == 0) 2 else if (@reduce(.And, bits) == std.math.maxInt(u64)) production.occluder_property else 0;
                summary_.known |= bit;
                summary_.common[at] = common;
                summary_.prefixed &= ~bit;
                if (common == 0) {
                    const classified: chunks.encoding.Classification.Known = .{ .common = common, .property = production.occluder_property, .selected = entry.solid };
                    _ = try production.prepared_codec.encode(&classified, self.prepared[0].bytes);
                    @memcpy(summary_.prefixes[at][0..visibility.Section.prefix_bytes], self.prepared[0].bytes[0..visibility.Section.prefix_bytes]);
                    summary_.prefix_bytes = visibility.Section.prefix_bytes;
                    summary_.prefixed |= bit;
                }
            }
        }
        _ = try self.geometry.learnColumnTopology(columns, summaries);
    }

    fn editable(self: *Baker, section: chunks.Section) !*Overlay {
        return self.overlay(section) orelse create: {
            assert(self.overlay_count < self.overlays.len);
            var classification: chunks.encoding.Classification = undefined;
            try self.terrain.classify(&.{.{ .section = section, .result = &classification }}, self.geometry.properties, production.occluder_property);
            if (classification != .known) return error.MissingStoredVisibility;
            const result = &self.overlays[self.overlay_count];
            self.overlay_count += 1;
            result.* = .{ .section = section, .solid = classification.known.selected };
            break :create result;
        };
    }

    fn edit(self: *Baker, section: chunks.Section, positions: []const u12, solid: bool) !void {
        const entry = try self.editable(section);
        for (positions) |position| {
            const mask = @as(u64, 1) << @intCast(position % 64);
            if (solid) entry.solid[position / 64] |= mask else entry.solid[position / 64] &= ~mask;
        }
        self.geometry.changed(self.world, self.minimum, .{ .minimum = .{ section.x * 16, section.y * 16, section.z * 16 }, .maximum = .{ section.x * 16 + 16, section.y * 16 + 16, section.z * 16 + 16 } }, false);
    }
};

const Scenario = struct {
    points: [][3]i32,
    expected: []u32,
};

fn cpu(io: std.Io) i96 {
    return std.Io.Clock.now(.cpu_thread, io).nanoseconds;
}

fn movementBench(io: std.Io, baker: *Baker, scenario: Scenario, masks: []u32, output: *std.Io.Writer, steps: usize, speed: u32, measure_bytes: bool, hull: bool, unload_slack: ?i32, round_trip: bool) !void {
    var tracked: ?Tracker = if (measure_bytes) try Tracker.init(std.heap.page_allocator, baker.radius, @intCast(steps * speed / 20), scenario.points, hull, unload_slack) else null;
    const visits = baker.geometry.visits;
    const restored = baker.geometry.restored;
    const resolutions = baker.geometry.section_resolutions;
    const queries = baker.geometry.started;
    const shared = baker.geometry.shared;
    const reuses = baker.geometry.topology_reuses;
    const lookups = baker.geometry.topology_lookups;
    var digest = std.hash.Wyhash.init(0);
    var solve_ns: i96 = 0;
    var worst_tick_ns: i96 = 0;
    for (1..steps + 1) |step| {
        var tick_ns: i96 = 0;
        for (scenario.points, 0..) |original, index| {
            var point = original;
            // A round trip turns back at the midpoint and retraces the path.
            const progress = if (round_trip and step > steps / 2) steps - step else step;
            point[0] += @intCast(progress * speed / 20);
            const solve_started = cpu(io);
            try baker.solve(index, point, masks, false);
            tick_ns += cpu(io) - solve_started;
            digest.update(std.mem.sliceAsBytes(masks));
            // Disclosure bookkeeping is not timed.
            if (tracked) |*value| try value.record(baker, index, point, masks);
        }
        solve_ns += tick_ns;
        worst_tick_ns = @max(worst_tick_ns, tick_ns);
    }
    try output.print("Movement: players={d}, ticks={d}, speed={d}_blocks/s, CPU_ms={d:.2}, worst_tick_ms={d:.3}, queries={d}, shared={d}, visits={d}, restored_metadata={d}, resolutions={d}, masks_hash={x}\n", .{ scenario.points.len, steps, speed, @as(f64, @floatFromInt(solve_ns)) / std.time.ns_per_ms, @as(f64, @floatFromInt(worst_tick_ns)) / std.time.ns_per_ms, baker.geometry.started - queries, baker.geometry.shared - shared, baker.geometry.visits - visits, baker.geometry.restored - restored, baker.geometry.section_resolutions - resolutions, digest.final() });
    if (tracked) |*value| {
        var bytes = try Bytes.init(std.heap.page_allocator, baker.height, hull);
        const chunk_bytes = try bytes.total(baker, value.events.items);
        const corrections = try bytes.corrections(baker, value.corrections.items);
        const sent = chunk_bytes + corrections;
        bytes.hull = false;
        const full = try bytes.total(baker, value.full_events.items);
        try output.print("Hull: enabled={} corrections={d} correction_MiB={d:.2} chunk_MiB={d:.2} replaced_blocks={d}\n", .{ hull, value.corrections.items.len, @as(f64, @floatFromInt(corrections)) / 1048576, @as(f64, @floatFromInt(chunk_bytes)) / 1048576, bytes.replaced });
        bytes.hull = hull;
        const reveal_bytes = try bytes.total(baker, value.reveal_events.items);
        try output.print("Packets: reveals={d} reveal_sections={d} reveal_MiB={d:.2} reloads={d} full_reloads={d}\n", .{ value.reveals, value.reveal_sections, @as(f64, @floatFromInt(reveal_bytes)) / 1048576, value.reloads, value.full_reloads });
        try output.print("Bytes: packets={d} sections={d} sent_MiB={d:.2} full_packets={d} full_MiB={d:.2} saving={d:.1}% per_player_sent_MiB={d:.3}\n", .{ value.events.items.len, value.sections, @as(f64, @floatFromInt(sent)) / 1048576, value.full_events.items.len, @as(f64, @floatFromInt(full)) / 1048576, 100 * (1 - @as(f64, @floatFromInt(sent)) / @as(f64, @floatFromInt(full))), @as(f64, @floatFromInt(sent)) / 1048576 / @as(f64, @floatFromInt(scenario.points.len)) });
    }
    try output.print("Topology: retained_columns={d}, shared_lookups={d}\n", .{ baker.geometry.topology_reuses - reuses, baker.geometry.topology_lookups - lookups });
}

fn incrementalBench(io: std.Io, baker: *Baker, scenario: *const Scenario, masks: []u32, output: *std.Io.Writer, repeat: usize) !void {
    var section: chunks.Section = .{ .world = baker.world, .x = @divFloor(scenario.points[0][0], 16), .y = @divFloor(scenario.points[0][1], 16) - 1, .z = @divFloor(scenario.points[0][2], 16) };
    var selected: [100]u12 = undefined;
    var found: usize = 0;
    while (section.y >= baker.minimum) : (section.y -= 1) {
        var classified: chunks.encoding.Classification = undefined;
        try baker.terrain.classify(&.{.{ .section = section, .result = &classified }}, baker.geometry.properties, production.occluder_property);
        if (classified != .known) return error.MissingStoredVisibility;
        found = 0;
        for (classified.known.selected, 0..) |word, index| {
            var bits = word;
            while (bits != 0 and found < selected.len) : (bits &= bits - 1) {
                selected[found] = @intCast(index * 64 + @ctz(bits));
                found += 1;
            }
        }
        if (found == selected.len) break;
    }
    if (found != selected.len) return error.NoEditableTerrain;
    _ = try baker.editable(section);
    try output.print("\nIncremental edits at {d},{d},{d}\n", .{ section.x, section.y, section.z });
    try output.writeAll("Edit       blocks   mark_us   metadata_us   query_us     total_us       visits\n");
    const cases = [_]struct { count: usize, solid: bool }{ .{ .count = 1, .solid = false }, .{ .count = 100, .solid = false }, .{ .count = 100, .solid = true } };
    for (cases) |case| {
        const visits = baker.geometry.visits;
        const started = cpu(io);
        try baker.edit(section, selected[0..case.count], case.solid);
        const marked = cpu(io);
        try baker.learnSources(&.{section});
        const learned = cpu(io);
        for (scenario.points, 0..) |point, index| {
            if (baker.geometry.ready(index)) continue;
            try baker.solve(index, point, masks, false);
        }
        const finished = cpu(io);
        try output.print("{s:<9} {d:>6} {d:>9.2} {d:>13.2} {d:>11.2} {d:>11.2} {d:>12}\n", .{ if (case.solid) "restore" else "remove", case.count, @as(f64, @floatFromInt(marked - started)) / std.time.ns_per_us, @as(f64, @floatFromInt(learned - marked)) / std.time.ns_per_us, @as(f64, @floatFromInt(finished - learned)) / std.time.ns_per_us, @as(f64, @floatFromInt(finished - started)) / std.time.ns_per_us, baker.geometry.visits - visits });
        try output.flush();
        var build_times: [7]i96 = undefined;
        var details: visibility.Section = .{};
        for (&build_times) |*time| {
            const beginning = cpu(io);
            details.build(&baker.overlay(section).?.solid, &baker.geometry.workspace, &baker.geometry.prepared_scratch);
            time.* = cpu(io) - beginning;
            std.mem.doNotOptimizeAway(&details);
        }
        std.mem.sort(i96, &build_times, {}, std.sort.asc(i96));
        try output.print("  section bake alone: median_CPU_us={d:.2}, components={d}, boundary_components={d}, prepared_bytes={d}\n", .{ @as(f64, @floatFromInt(build_times[3])) / std.time.ns_per_us, details.components, details.boundary_components, details.prepared_data.len });
        for (scenario.points, 0..) |_, index| @memcpy(scenario.expected[index * masks.len ..][0..masks.len], baker.geometry.views[index].masks);
        const reference_started = cpu(io);
        for (scenario.points, 0..) |point, index| {
            try baker.solve(index, point, masks, true);
            if (!std.mem.eql(u32, masks, scenario.expected[index * masks.len ..][0..masks.len])) {
                var difference: usize = 0;
                for (masks, scenario.expected[index * masks.len ..][0..masks.len]) |a, b| difference += @popCount(a ^ b);
                std.log.err("incremental mismatch row={d} sections={d}", .{ index, difference });
                return error.IncrementalMismatch;
            }
        }
        try output.print("  all masks match fresh full solves, reference_CPU_us={d:.2}\n", .{@as(f64, @floatFromInt(cpu(io) - reference_started)) / std.time.ns_per_us});
    }
    if (repeat != 0) {
        const started = cpu(io);
        for (0..repeat) |_| for ([_]bool{ false, true }) |solid| {
            try baker.edit(section, selected[0..1], solid);
            try baker.learnSources(&.{section});
            for (scenario.points, 0..) |point, index| {
                if (!baker.geometry.ready(index)) try baker.solve(index, point, masks, false);
            }
        };
        try output.print("edit-only loop: edits={d}, CPU_us/edit={d:.2}\n", .{ repeat * 2, @as(f64, @floatFromInt(cpu(io) - started)) / @as(f64, @floatFromInt(repeat * 2)) / std.time.ns_per_us });
        for (scenario.points, 0..) |point, index| {
            @memcpy(scenario.expected[index * masks.len ..][0..masks.len], baker.geometry.views[index].masks);
            try baker.solve(index, point, masks, true);
            if (!std.mem.eql(u32, masks, scenario.expected[index * masks.len ..][0..masks.len])) return error.IncrementalMismatch;
        }
    }
}

fn imported(init: std.process.Init, options: Options, output: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = bounded.allocator();
    var registry = try metrics.Registry.init(allocator, init.io, .{ .enabled = false });
    defer registry.deinit();
    try std.Io.Dir.cwd().access(init.io, options.world.?, .{});
    var database = try storage.Store.init(allocator, init.io, .{ .path = options.world.? });
    defer database.deinit();
    const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 16 }, .{ .storage = try database.openSpace(worlds.Worlds.id) });
    const world = dimensions.find("minecraft:overworld") orelse return error.MissingOverworld;
    const terrain = try chunks.Chunks.init(allocator, init.io, .{ .cache_sections = 48, .demand_sections = 24, .cache_groups = 8 }, .{ .metrics = &registry, .storage = try database.openSpace(chunks.Chunks.id), .record_workspaces = try records.Workspaces.init(allocator, init.io, .{}) });
    const tick = database.lastTick();
    var baker = try Baker.init(allocator, terrain, world.id, world.dimension.minimumSection(), world.dimension.sectionCount(), options.radius, options.players);
    const columns = (2 * @as(usize, options.radius) + 1) * (2 * @as(usize, options.radius) + 1);
    const scenario: Scenario = .{ .points = try allocator.alloc([3]i32, options.players), .expected = try allocator.alloc(u32, options.players * columns) };
    const masks = try allocator.alloc(u32, columns);
    var width: usize = 1;
    while (width * width < (options.players + options.clusters - 1) / options.clusters) width += 1;
    for (scenario.points, 0..) |*point, index| {
        const offset = (2 * @as(i32, @intCast(index % options.clusters)) - @as(i32, @intCast(options.clusters - 1))) * 1024;
        point.* = .{ options.head[0] + offset + @as(i32, @intCast(index / options.clusters % width)) * 16, options.head[1], options.head[2] + @as(i32, @intCast(index / options.clusters / width)) * 16 };
        if (options.spacing != 0) {
            const columns_wide = @min(options.players, 8);
            const rows = try std.math.divCeil(usize, options.players, columns_wide);
            const x = (2 * @as(i64, @intCast(index % columns_wide)) - @as(i64, @intCast(columns_wide - 1))) * options.spacing * 8;
            const z = (2 * @as(i64, @intCast(index / columns_wide)) - @as(i64, @intCast(rows - 1))) * options.spacing * 8;
            point[0] = std.math.cast(i32, @as(i64, options.head[0]) + x) orelse return error.InvalidPosition;
            point[2] = std.math.cast(i32, @as(i64, options.head[2]) + z) orelse return error.InvalidPosition;
        }
        while (point[1] < (baker.minimum + @as(i32, @intCast(baker.height))) * 16) {
            const state = try terrain.getBlock(baker.world, .{ .x = point[0], .y = point[1], .z = point[2] });
            if (baker.geometry.properties[state] & production.occluder_property == 0) break;
            point[1] += 16;
        }
    }
    const reserved = bounded.allocated_bytes - bounded.freed_bytes;
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    const started = cpu(init.io);
    for (scenario.points, 0..) |point, index| try baker.solve(index, point, masks, true);
    try output.print("Imported terrain: players={d}, radius={d}, height={d}, head={any}, clusters={d}, spacing_chunks={d}, reserved_MiB={d:.2}\n", .{ options.players, options.radius, baker.height, options.head, options.clusters, options.spacing, @as(f64, @floatFromInt(reserved)) / 1048576 });
    try output.print("Initial solve: CPU_ms={d:.2}, visits={d}, restored_metadata={d}\n", .{ @as(f64, @floatFromInt(cpu(init.io) - started)) / std.time.ns_per_ms, baker.geometry.visits, baker.geometry.restored });
    try output.flush();
    if (options.movement_steps != 0) {
        try movementBench(init.io, &baker, scenario, masks, output, options.movement_steps, options.speed, options.bytes, options.hull, options.unload_slack, options.round_trip);
    } else try incrementalBench(init.io, &baker, &scenario, masks, output, options.edit_repeat);
    assert(database.lastTick() == tick and !bounded.has_induced_failure);
    assert(reserved == bounded.allocated_bytes - bounded.freed_bytes);
    try output.writeAll("runtime allocations=0, edits use an in-memory overlay, source world is not written\n");
}

pub fn main(init: std.process.Init) !void {
    var options: Options = .{};
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    defer args.deinit();
    _ = args.next();
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const output = &stdout.interface;
    while (args.next()) |argument| {
        if (std.mem.eql(u8, argument, "--bytes")) {
            options.bytes = true;
            continue;
        }
        if (std.mem.eql(u8, argument, "--hull")) {
            options.bytes = true;
            options.hull = true;
            continue;
        }
        if (std.mem.eql(u8, argument, "--no-oracle")) {
            options.oracle = false;
            continue;
        }
        if (std.mem.eql(u8, argument, "--round-trip")) {
            options.round_trip = true;
            continue;
        }
        if (std.mem.eql(u8, argument, "--help")) {
            try output.writeAll("zig build incremental --release=safe -- [--world PATH] [--players 1..256] [--radius 1..35] [--clusters 1..8] [--spacing CHUNKS] [--head X Y Z] [--edit-repeat N] [--movement-steps N] [--speed BLOCKS_PER_SECOND] [--bytes] [--hull] [--unload-slack CHUNKS] [--round-trip] [--no-oracle]\n--unload-slack forgets columns beyond the radius plus CHUNKS, as the client does, and charges both schemes again on return.\n--round-trip travels out for half the ticks and back for the rest.\n--bytes records disclosure along the movement path and reports exact compressed chunk packet bytes, including resends, against sending full terrain.\n--hull also replaces hidden blocks with section fillers and counts true-state corrections within one section of each player.\nClusters are 2048 blocks apart and players within a cluster are 16 blocks apart.\nWithout --world, only synthetic oracle checks run.\n");
            try output.flush();
            return;
        }
        const value = args.next() orelse return error.MissingArgument;
        if (std.mem.eql(u8, argument, "--world")) options.world = value else if (std.mem.eql(u8, argument, "--players")) options.players = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, argument, "--radius")) options.radius = try std.fmt.parseInt(u8, value, 10) else if (std.mem.eql(u8, argument, "--clusters")) options.clusters = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, argument, "--spacing")) options.spacing = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, argument, "--edit-repeat")) options.edit_repeat = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, argument, "--movement-steps")) options.movement_steps = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, argument, "--speed")) options.speed = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, argument, "--unload-slack")) options.unload_slack = try std.fmt.parseInt(i32, value, 10) else if (std.mem.eql(u8, argument, "--head")) {
            options.head[0] = try std.fmt.parseInt(i32, value, 10);
            for (options.head[1..]) |*coordinate| coordinate.* = try std.fmt.parseInt(i32, args.next() orelse return error.MissingArgument, 10);
        } else return error.UnknownArgument;
    }
    if (options.radius == 0 or options.radius > 35 or options.players == 0 or options.players > 256 or options.clusters == 0 or options.clusters > 8 or options.clusters > options.players or options.edit_repeat > 1000000 or options.movement_steps > 1000000 or options.speed == 0 or options.speed > 1000 or (options.unload_slack != null and (options.unload_slack.? < 0 or options.unload_slack.? > 3))) return error.InvalidOptions;
    if (options.oracle) {
        try reference.verifyIncremental(init, output);
        if (options.world) |path| try reference.verifyImportedIncremental(init, path, output);
    }
    if (options.world != null) try imported(init, options, output);
    try output.flush();
}

/// Per-player disclosure along a movement path. Disclosure is monotone: once sent, a section
/// stays sent, and a newly disclosed section in a sent column resends the whole column.
const Tracker = struct {
    allocator: std.mem.Allocator,
    /// Columns per row of each player's region, which spans the horizon plus the path.
    width: usize,
    /// Section column of each player's region minimum.
    corners: [][2]i32,
    /// Sections ever disclosed, per player and region column.
    sent: [][]u32,
    /// Columns the full terrain baseline has loaded on the client.
    seen: [][]bool,
    /// Columns this scheme has ever sent, to tell reloads after an unload from first loads.
    ever: [][]bool,
    /// Columns beyond the radius plus this many chunks are forgotten; null keeps them all.
    unload_slack: ?i32,
    /// Packets that resend a loaded column because new sections became visible.
    reveals: usize = 0,
    reveal_sections: usize = 0,
    /// Packets that send a column again after the client forgot it, in each scheme.
    reloads: usize = 0,
    full_reloads: usize = 0,
    /// Columns the full terrain baseline has ever sent, to count its reloads.
    full_seen: [][]bool,
    /// With hull replacement, sections near the player whose true states were sent since
    /// their column, which carries filler, was last sent.
    corrected: ?[][]u32,
    sections: usize = 0,
    events: std.ArrayList(Event) = .empty,
    full_events: std.ArrayList(Event) = .empty,
    /// Packets that resend a loaded column for newly visible sections, also in `events`.
    reveal_events: std.ArrayList(Event) = .empty,
    corrections: std.ArrayList(chunks.Section) = .empty,

    fn init(allocator: std.mem.Allocator, radius: i32, travel_blocks: i32, points: []const [3]i32, hull: bool, unload_slack: ?i32) !Tracker {
        assert(radius > 0 and travel_blocks >= 0 and points.len > 0);
        const width: usize = @intCast(2 * radius + 1 + @divFloor(travel_blocks, 16) + 2);
        const area = width * @as(usize, @intCast(2 * radius + 1));
        const corners = try allocator.alloc([2]i32, points.len);
        for (corners, points) |*corner, point| corner.* = .{ @divFloor(point[0], 16) - radius, @divFloor(point[2], 16) - radius };
        return .{
            .allocator = allocator,
            .width = width,
            .corners = corners,
            .sent = try zeroed(u32, allocator, points.len, area),
            .seen = try zeroed(bool, allocator, points.len, area),
            .ever = try zeroed(bool, allocator, points.len, area),
            .full_seen = try zeroed(bool, allocator, points.len, area),
            .unload_slack = unload_slack,
            .corrected = if (hull) try zeroed(u32, allocator, points.len, area) else null,
        };
    }

    fn zeroed(comptime T: type, allocator: std.mem.Allocator, count: usize, area: usize) ![][]T {
        const result = try allocator.alloc([]T, count);
        for (result) |*row| {
            row.* = try allocator.alloc(T, area);
            @memset(row.*, std.mem.zeroes(T));
        }
        return result;
    }

    fn slot(self: *const Tracker, player: usize, x: i32, z: i32) usize {
        const corner = self.corners[player];
        assert(x >= corner[0] and z >= corner[1]);
        const result = @as(usize, @intCast(z - corner[1])) * self.width + @as(usize, @intCast(x - corner[0]));
        assert(result < self.sent[player].len);
        return result;
    }

    fn record(self: *Tracker, baker: *const Baker, player: usize, point: [3]i32, masks: []const u32) !void {
        const center = [2]i32{ @divFloor(point[0], 16), @divFloor(point[2], 16) };
        const radius: i32 = baker.radius;
        const side: usize = @intCast(2 * radius + 1);
        assert(masks.len == side * side);
        if (self.unload_slack) |slack| self.unload(player, center, radius + slack);
        const all: u32 = @truncate((@as(u64, 1) << @intCast(baker.height)) - 1);
        for (masks, 0..) |mask, column| {
            const x = center[0] - radius + @as(i32, @intCast(column % side));
            const z = center[1] - radius + @as(i32, @intCast(column / side));
            const at = self.slot(player, x, z);
            if (!self.seen[player][at] and chunk_horizon.contains(radius, .{ .x = center[0], .z = center[1] }, .{ .x = x, .z = z })) {
                self.seen[player][at] = true;
                self.full_reloads += @intFromBool(self.full_seen[player][at]);
                self.full_seen[player][at] = true;
                try self.full_events.append(self.allocator, .{ .x = x, .z = z, .mask = all });
            }
            const sent = &self.sent[player][at];
            const added = mask & ~sent.*;
            if (added == 0) continue;
            if (sent.* != 0) {
                self.reveals += 1;
                try self.reveal_events.append(self.allocator, .{ .x = x, .z = z, .mask = sent.* | added });
                self.reveal_sections += @popCount(added);
            } else {
                self.reloads += @intFromBool(self.ever[player][at]);
                self.ever[player][at] = true;
            }
            sent.* |= added;
            self.sections += @popCount(added);
            try self.events.append(self.allocator, .{ .x = x, .z = z, .mask = sent.* });
            if (self.corrected) |corrected| corrected[player][at] = 0;
        }
        if (self.corrected != null) try self.recordCorrections(baker, player, point);
    }

    /// The client keeps columns only near its view center, so both schemes send them again
    /// when they return.
    fn unload(self: *Tracker, player: usize, center: [2]i32, keep: i32) void {
        const corner = self.corners[player];
        for (self.sent[player], self.seen[player], 0..) |*sent, *seen, at| {
            if (sent.* == 0 and !seen.*) continue;
            const x = corner[0] + @as(i32, @intCast(at % self.width));
            const z = corner[1] + @as(i32, @intCast(at / self.width));
            if (chunk_horizon.contains(keep, .{ .x = center[0], .z = center[1] }, .{ .x = x, .z = z })) continue;
            sent.* = 0;
            seen.* = false;
            if (self.corrected) |corrected| corrected[player][at] = 0;
        }
    }

    /// Mirrors block synchronization: the 27 sections around the eye section get every true
    /// state once per column delivery.
    fn recordCorrections(self: *Tracker, baker: *const Baker, player: usize, point: [3]i32) !void {
        const corrected = self.corrected.?;
        const eye = [3]i32{ @divFloor(point[0], 16), @divFloor(point[1], 16), @divFloor(point[2], 16) };
        for (0..27) |cell| {
            const section: chunks.Section = .{
                .world = baker.world,
                .x = eye[0] + @as(i32, @intCast(cell % 3)) - 1,
                .y = eye[1] + @as(i32, @intCast(cell / 3 % 3)) - 1,
                .z = eye[2] + @as(i32, @intCast(cell / 9)) - 1,
            };
            const offset = section.y - baker.minimum;
            if (offset < 0 or offset >= baker.height) continue;
            const bit = @as(u32, 1) << @intCast(offset);
            const at = self.slot(player, section.x, section.z);
            if (self.sent[player][at] & bit == 0 or corrected[player][at] & bit != 0) continue;
            corrected[player][at] |= bit;
            try self.corrections.append(self.allocator, section);
        }
    }
};

/// One chunk packet: a column sent with every section disclosed so far.
const Event = struct { x: i32, z: i32, mask: u32 };

fn eventOrder(_: void, a: Event, b: Event) bool {
    if (a.x != b.x) return a.x < b.x;
    if (a.z != b.z) return a.z < b.z;
    return a.mask < b.mask;
}

fn sectionOrder(_: void, a: chunks.Section, b: chunks.Section) bool {
    if (a.x != b.x) return a.x < b.x;
    return a.z < b.z;
}

/// Exact compressed chunk packet sizes for recorded events, one relight per column. Terrain
/// is read from storage as a 3 by 3 column neighborhood, like the lighting workspace.
const Bytes = struct {
    const span = 3 * section_hull.side;
    const center = 4;

    wire: reference.Wire,
    /// Block states of the neighborhood, indexed ((y + 16) * span + z) * span + x.
    states: []u16,
    sections: []lighting.Section,
    biomes: [][64]u16,
    stamp: u64 = 1,
    hull: bool,
    table: section_hull.Table,
    hulled: [][section_hull.volume]u16,
    replaced: usize = 0,
    /// Blocks the hull replaced per center section of the loaded column.
    changed: [lighting.maximum_sections]usize = @splat(0),
    /// Uncompressed block change packet, sized for every cell of a section.
    raw: []u8,

    fn init(allocator: std.mem.Allocator, height: usize, hull: bool) !Bytes {
        assert(height > 0 and height <= lighting.maximum_sections);
        return .{
            .wire = try reference.Wire.init(allocator, height),
            .states = try allocator.alloc(u16, span * (height + 2) * section_hull.side * span),
            .sections = try allocator.alloc(lighting.Section, 9 * height),
            .biomes = try allocator.alloc([64]u16, 9 * height),
            .hull = hull,
            .table = try section_hull.initTable(allocator),
            .hulled = try allocator.alloc([section_hull.volume]u16, height),
            .raw = try allocator.alloc(u8, 16 + section_hull.volume * 10),
        };
    }

    fn offset(column: usize, y: usize) usize {
        assert(column < 9);
        return ((y + 1) * section_hull.side * span + column / 3 * section_hull.side) * span + column % 3 * section_hull.side;
    }

    fn extract(self: *const Bytes, column: usize, y: usize, output: *[section_hull.volume]u16) void {
        const base = offset(column, y);
        for (0..section_hull.side) |row_y| for (0..section_hull.side) |row_z| {
            const row = (row_y * section_hull.side + row_z) * section_hull.side;
            @memcpy(output[row..][0..section_hull.side], self.states[base + (row_y * span + row_z) * span ..][0..section_hull.side]);
        };
    }

    fn occupied(self: *const Bytes, height: usize, column: usize, y: i64) section_hull.Rows {
        if (y < 0 or y >= height) return @splat(@splat(0));
        var cells: [section_hull.volume]u16 = undefined;
        self.extract(column, @intCast(y), &cells);
        return section_hull.rows(&cells, self.table);
    }

    /// Replaces the center column's sections with hulled copies, like the lighting bake.
    fn applyHull(self: *Bytes, height: usize) void {
        const north = 1;
        const west = 3;
        const east = 5;
        const south = 7;
        for (0..height) |y| {
            const level: i64 = @intCast(y);
            const faces: section_hull.Faces = .{
                section_hull.face(&self.occupied(height, west, level), 1),
                section_hull.face(&self.occupied(height, east, level), 0),
                section_hull.face(&self.occupied(height, center, level - 1), 3),
                section_hull.face(&self.occupied(height, center, level + 1), 2),
                section_hull.face(&self.occupied(height, north, level), 5),
                section_hull.face(&self.occupied(height, south, level), 4),
            };
            self.extract(center, y, &self.hulled[y]);
            self.changed[y] = section_hull.apply(&self.hulled[y], &faces, self.table);
            self.replaced += self.changed[y];
            self.stamp += 1;
            self.sections[center * height + y].view = .{ .dense = &self.hulled[y] };
            self.sections[center * height + y].stamp = .{ .generation = self.stamp };
        }
    }

    fn load(self: *Bytes, baker: *Baker, x: i32, z: i32) !void {
        @memset(self.states, 0);
        const height = baker.height;
        const plains: u16 = @intCast(game_data.registry.biomeId("minecraft:plains").?);
        for (0..9) |column| for (0..height) |y| {
            const at: chunks.Section = .{ .world = baker.world, .x = x + @as(i32, @intCast(column % 3)) - 1, .y = baker.minimum + @as(i32, @intCast(y)), .z = z + @as(i32, @intCast(column / 3)) - 1 };
            const base = offset(column, y);
            const lease = try baker.terrain.acquire(at);
            defer lease.release();
            for (0..section_hull.side) |row_y| for (0..section_hull.side) |row_z| for (0..section_hull.side) |row_x| {
                self.states[base + (row_y * span + row_z) * span + row_x] = lease.get(@intCast((row_y * section_hull.side + row_z) * section_hull.side + row_x));
            };
            const biomes = &self.biomes[column * height + y];
            if (lease.biomes()) |view| {
                for (biomes, 0..) |*biome, local| biome.* = view.get(@intCast(local));
            } else @memset(biomes, plains);
            self.stamp += 1;
            self.sections[column * height + y] = .{ .stamp = .{ .generation = self.stamp }, .view = .{ .rows = self.states[base..] }, .biomes = .{ .values = biomes } };
        };
        try self.wire.engine.load(.{ .dense = self.states });
        self.wire.engine.relight(true);
        if (self.hull) self.applyHull(height);
    }

    fn size(self: *Bytes, baker: *const Baker, x: i32, z: i32, mask: u32) !usize {
        const wire = &self.wire;
        const Version = protocols.version(game_data.canonical_version);
        const mapping: packets.Registry = .{ .entities = Version.Registry.canonical_entity_to_wire, .items = Version.Registry.canonical_item_to_wire, .blocks = Version.Registry.canonical_block_to_wire, .block_states = Version.Registry.canonical_block_state_to_wire, .block_state_bits = Version.Registry.block_state_bits, .sounds = Version.Registry.canonical_sound_to_wire, .effects = Version.Registry.canonical_effect_to_wire, .attributes = Version.Registry.canonical_attribute_to_wire };
        var light_masks: [2]u32 = @splat(0);
        for (0..baker.height + 2) |section| {
            if (wire.engine.sectionNonempty(.block, .{ 1, section, 1 })) light_masks[0] |= @as(u32, 1) << @intCast(section);
            if (wire.engine.sectionNonempty(.sky, .{ 1, section, 1 })) light_masks[1] |= @as(u32, 1) << @intCast(section);
        }
        const chunk: chunk_encoding.Chunk = .{
            .x = x,
            .z = z,
            .minimum_section = baker.minimum,
            .sections = .{ .loaded = self.sections[center * baker.height ..][0..baker.height] },
            .workspace = wire.workspace,
            .biome = game_data.registry.biomeId("minecraft:plains").?,
            .light = .{ .source = .{ .computed = &wire.engine }, .count = baker.height + 2, .masks = light_masks },
            .disclosure = mask,
            .concealment = 0,
        };
        const prepared = try wire.workspace.prepare(chunk);
        const encoded = try sessions.packet_api.encode(Version, chunk_encoding.write, wire.bytes, .{ mapping, &prepared, &wire.catalog.values[0] });
        return framed(&wire.compression, encoded, wire.compressed);
    }

    /// Estimated compressed size of a block change packet carrying every true state of one
    /// center section: section position, cell count, then one variable length long per cell.
    fn correction(self: *Bytes, y: usize) !usize {
        // A section the hull left unchanged needs no correction.
        if (self.changed[y] == 0) return 0;
        var cells: [section_hull.volume]u16 = undefined;
        self.extract(center, y, &cells);
        var writer = std.Io.Writer.fixed(self.raw);
        try writer.writeInt(u64, 0, .big);
        try writer.writeUleb128(@as(u32, section_hull.volume));
        for (cells, 0..) |state, cell| {
            const local: u64 = ((cell % 16) << 8) | ((cell / 16 % 16) << 4) | (cell / 256);
            try writer.writeUleb128((@as(u64, state) << 12) | local);
        }
        return framed(&self.wire.compression, writer.buffered(), self.wire.compressed);
    }

    /// Frame size on a compressed connection: small packets are sent uncompressed.
    fn framed(compression: anytype, encoded: []const u8, destination: []u8) !usize {
        if (encoded.len >= 256) return (try compression.compress(encoded, destination)).len;
        return encoded.len + 1 + @as(usize, if (encoded.len + 1 < 128) 1 else 2);
    }

    /// Sums packet sizes, grouping events by column so each column is relit once.
    fn total(self: *Bytes, baker: *Baker, events: []Event) !u64 {
        std.mem.sort(Event, events, {}, eventOrder);
        var sum: u64 = 0;
        var index: usize = 0;
        while (index < events.len) {
            const first = events[index];
            try self.load(baker, first.x, first.z);
            var previous: ?u32 = null;
            var cached: usize = 0;
            while (index < events.len and events[index].x == first.x and events[index].z == first.z) : (index += 1) {
                if (previous != events[index].mask) {
                    cached = try self.size(baker, first.x, first.z, events[index].mask);
                    previous = events[index].mask;
                }
                sum += cached;
            }
        }
        return sum;
    }

    fn corrections(self: *Bytes, baker: *Baker, sections: []chunks.Section) !u64 {
        std.mem.sort(chunks.Section, sections, {}, sectionOrder);
        var sum: u64 = 0;
        var index: usize = 0;
        while (index < sections.len) {
            const first = sections[index];
            try self.load(baker, first.x, first.z);
            while (index < sections.len and sections[index].x == first.x and sections[index].z == first.z) : (index += 1) {
                sum += try self.correction(@intCast(sections[index].y - baker.minimum));
            }
        }
        return sum;
    }
};
