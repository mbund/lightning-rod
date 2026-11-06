const geometry_bounds = @import("bounds.zig");
const section_visibility_world = @import("section_visibility_world.zig");
const streaming_debug = @import("streaming_debug.zig");
const SpatialIndex = @import("player_spatial.zig").Index;
const metrics = @import("metrics");
const std = @import("std");
const wire_1_21_5 = @import("wire_1_21_5");
const lightning_rod = @import("lightning_rod");
const chunks = @import("chunks");
const chunk_encoding = @import("chunk_encoding.zig");
const game_data = @import("game_data");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const worlds = @import("worlds");
const players = @import("players.zig");
const storage = @import("storage");
const persistent_records = @import("records");

const lighting = @import("lighting.zig");
const assert = std.debug.assert;
const geometry_change_capacity = 256;

pub const Streaming = struct {
    pub const id = "minecraft:chunk_streaming";

    pub const Configuration = struct {
        prefetch: u2 = 0,
        occlusion: bool = true,
        occlusion_columns: ?usize = null,
        occlusion_sources: ?usize = null,
        /// Required only when a chunk source omits biome data.
        fallback_biome: ?i32 = null,
    };

    pub const Dependencies = struct {
        metrics: *metrics.Registry,
        players: *players.Players,
        chunks: *chunks.Chunks,
        sessions: *sessions.Service,
        packets: *packets.Packets,
        worlds: *worlds.Worlds,
        lighting: *lighting.Lighting,
    };

    const batch_max = 4;
    const near_radius = 3;

    const GeometryChange = struct {
        section: chunks.Section,
        bounds: geometry_bounds.Box,

        fn boundsFor(section: chunks.Section, edits: []const chunks.BlockEdit) ?geometry_bounds.Box {
            assert(edits.len > 0 and edits.len <= 4096);
            var bounds: geometry_bounds.Box = .{ .minimum = @splat(15), .maximum = @splat(0) };
            for (edits) |edit| {
                const point = [3]i32{ edit.index % 16, edit.index / 256, edit.index / 16 % 16 };
                for (0..3) |axis| {
                    bounds.minimum[axis] = @min(bounds.minimum[axis], point[axis]);
                    bounds.maximum[axis] = @max(bounds.maximum[axis], point[axis] + 1);
                }
            }
            for ([_]i32{ section.x, section.y, section.z }, 0..) |coordinate, axis| {
                const origin = std.math.mul(i32, coordinate, 16) catch return null;
                bounds.minimum[axis] = std.math.add(i32, bounds.minimum[axis], origin) catch return null;
                bounds.maximum[axis] = std.math.add(i32, bounds.maximum[axis], origin) catch return null;
            }
            bounds.validate();
            return bounds;
        }
    };

    pub const Position = struct {
        x: i32,
        z: i32,
    };

    pub const View = struct {
        handle: ?sessions.Handle,
        world: u32,
        protocol: i32,
        life: u32,
        teleport_id: i32 = 0,
        ready: bool,
        center: Position,
        eye_min: [3]i32 = .{ 0, 0, 0 },
        eye_max: i32 = 0,
        occlusion: bool = true,

        pub fn capture(player: players.Players.Player) View {
            return .{
                .eye_min = .{ @intFromFloat(@floor(player.position.x)), @intFromFloat(@floor(player.position.y + @as(f64, @as(f32, 0.2)))), @intFromFloat(@floor(player.position.z)) },
                .eye_max = @intFromFloat(@floor(player.position.y + @as(f64, @as(f32, 1.62)))),
                .occlusion = player.gamemode != .spectator,
                .handle = player.handle,
                .world = player.world,
                .protocol = player.protocol,
                .life = player.life,
                .teleport_id = player.teleport_id,
                .ready = switch (player.stage) {
                    .teleport, .awaiting_teleport, .health, .selection, .ready => !player.configuring,
                    else => false,
                },
                .center = .{ .x = @intFromFloat(@floor(player.position.x / 16)), .z = @intFromFloat(@floor(player.position.z / 16)) },
            };
        }
    };

    const LightChanges = struct {
        bits: []u64,
        words: lightning_rod.system.IndexSet,

        fn init(allocator: std.mem.Allocator, count: usize) !LightChanges {
            const bits = try allocator.alloc(u64, count);
            @memset(bits, 0);
            return .{ .bits = bits, .words = try lightning_rod.system.IndexSet.init(allocator, count) };
        }

        fn mark(self: *LightChanges, slot: SentIndex) void {
            self.bits[slot.word] |= slot.mask;
            self.words.insert(slot.word);
        }

        fn merge(self: *LightChanges, source: *LightChanges) void {
            for (source.words.values()) |word| {
                self.bits[word] |= source.bits[word];
                self.words.insert(word);
            }
            source.clear();
        }

        fn clear(self: *LightChanges) void {
            for (self.words.values()) |word| self.bits[word] = 0;
            self.words.clear();
        }
    };

    const Published = struct {
        light: LightChanges,
        mutex: std.Io.Mutex = .init,
        views: []View,
        streams: []Stream,
        sent: []u64,
        occluded: []u32,
        dirty_words: std.DynamicBitSetUnmanaged,
        changed_views: lightning_rod.system.IndexSet,
        dirty_streams: lightning_rod.system.IndexSet,
        geometry_revision: u64 = 0,
        geometry_changes: std.AutoHashMapUnmanaged(chunks.Section, geometry_bounds.Box) = .{},
        geometry_overflow: bool = false,
        epoch: u64 = 0,
        updated: bool = true,

        pub fn setStream(self: *Published, index: usize, stream: Stream) void {
            if (std.meta.eql(self.streams[index], stream)) return;
            self.streams[index] = stream;
            self.dirty_streams.insert(index);
        }
    };

    const Stream = struct {
        generation: u32 = 0,
        life: u32 = 0,
        prepared_teleport: i32 = 0,
        setup: enum { terrain, center, streaming, unloading } = .terrain,
        center: Position = .{ .x = 0, .z = 0 },
        target: Position = .{ .x = 0, .z = 0 },
        cursor: usize = 0,
        unload_cursor: usize = 0,
        minimum_section: i32 = -4,
        section_count: usize = 24,
        delivered: usize = 0,
        packet_bytes: usize = 0,
    };

    const Source = struct {
        biome: ?u16 = null,
        origin: ?*const section_visibility_world.Source = null,
        query: ?section_visibility_world.Handle = null,
        near_query: ?section_visibility_world.Handle = null,
        revision: u64 = 0,
        near_revision: u64 = 0,
        quadrants: u8 = 0,
        direction: [2]i32 = .{ 0, 0 },
        known: bool = false,
    };

    const DisclosureMasks = struct { visibility: u32, disclosure: u32 };
    const DeliveryColumn = struct { world: u32, at: Position };

    const Pending = struct {
        at: Position,
        world: u32,
        protocol: i32,
        owner: usize,
        biome: ?u16 = null,
        biome_disclosure: u32 = 0,
        disclosure: u32 = std.math.maxInt(u32),
        visibility: u32 = std.math.maxInt(u32),
    };

    geometry_changes: []GeometryChange,
    biome_sections: []?*const [64]u16,
    geometry: section_visibility_world.World,
    classifications: []chunks.encoding.Classification,
    classification_requests: []chunks.Chunks.ClassificationRequest,
    geometry_revision: u64 = 0,
    occluded: []u32,
    // Changes since the last bulk or reveal snapshot received by the client.
    stale: []u32,
    disclosed: []u32,
    biome_disclosed: []u32,
    light_receipts: []lighting.Receipt,
    refresh_bits: []u64,
    acquired_chunks: metrics.Counter,
    section_visits: metrics.Counter,
    visibility_hits: metrics.Counter,
    queries_started: metrics.Counter = .{},
    queries_completed: metrics.Counter = .{},
    queries_cancelled: metrics.Counter = .{},
    section_builds: metrics.Counter,
    concealed_sections: metrics.Counter,
    encoded_bytes: metrics.Counter,
    topology: struct {
        rebuilt: metrics.Counter = .{},
        reused: metrics.Counter = .{},
        evicted: metrics.Counter = .{},
        working_evicted: metrics.Counter = .{},
    } = .{},
    deliveries: struct {
        new_columns: metrics.Counter = .{},
        replacements: metrics.Counter = .{},
        reused: metrics.Counter = .{},
        new_sections: metrics.Counter = .{},
        repeated_sections: metrics.Counter = .{},
    } = .{},
    encoding_duration: metrics.Timer,
    lighting_duration: metrics.Timer,
    lighting_cpu: metrics.Timer,
    publication: metrics.Timer,
    cpu: struct {
        poll: metrics.Timer = .{},
        synchronization: metrics.Timer = .{},
        planning: metrics.Timer = .{},
        recipients: metrics.Timer = .{},
        geometry: metrics.Timer = .{},
        visibility: metrics.Timer = .{},
        encoding: metrics.Timer = .{},
        publication: metrics.Timer = .{},
        completion: metrics.Timer = .{},
        visibility_publication: metrics.Timer = .{},
        sources: metrics.Timer = .{},
        light_updates: metrics.Timer = .{},
    } = .{},
    deps: Dependencies,
    io: std.Io,
    native_io: std.Io,
    published: *Published,
    tracked_views: lightning_rod.system.IndexSet,
    views: []View,
    changed_players: lightning_rod.system.IndexSet,
    background_players: lightning_rod.system.IndexSet,
    occupied_players: lightning_rod.system.IndexSet,
    observers_index: SpatialIndex,
    generation_updates: []chunks.Generation.Update,
    epoch: u64 = 0,
    pending: bool = true,
    config: Configuration,
    streams: []Stream,
    recipients: []sessions.Handle,
    delivery_column: ?DeliveryColumn = null,
    sent: []u64,
    words_per_player: usize,
    visibility: Visibility,
    sources: []Source,
    origins: []section_visibility_world.Source = &.{},
    dirty_words: std.DynamicBitSetUnmanaged,
    next_player: usize = 0,
    next_occupied_player: usize = 0,
    columns_in_turn: usize = 0,
    encoding: *chunk_encoding.Workspace,
    light_staged: LightChanges,
    light_pending: LightChanges,
    changed: *std.Io.Event,
    wake_pending: bool = false,
    debug_slots: []streaming_debug.Slot = &.{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration, deps: Dependencies) !*Streaming {
        if (deps.chunks.backgroundCapacity() < 24) return error.ChunkCacheTooSmall;
        if (config.fallback_biome) |biome| if (biome < 0 or biome >= game_data.registry.biome_names.len) return error.UnsupportedBiome;

        const self = try allocator.create(Streaming);
        const streams = try allocator.alloc(Stream, deps.players.records.len);

        for (streams) |*stream| stream.* = .{};

        const side: usize = @intCast((deps.players.config.render_distance + @as(i32, config.prefetch)) * 2 + 1);
        if (config.occlusion) {
            const queries_per_player: usize = if (deps.players.config.render_distance + @as(i32, config.prefetch) > near_radius) 2 else 1;
            if (config.occlusion_sources) |sources| if (sources < queries_per_player * streams.len) return error.VisibilityCacheTooSmall;
            if (config.occlusion_columns) |columns| if (columns < (side + 2) * (side + 2)) return error.VisibilityCacheTooSmall;
        }
        const words = (side * side + 63) / 64;
        const sent = try allocator.alloc(u64, streams.len * words);
        @memset(sent, 0);
        const occluded = try allocator.alloc(u32, streams.len * side * side);
        @memset(occluded, std.math.maxInt(u32));
        const stale = try allocator.alloc(u32, occluded.len);
        @memset(stale, 0);
        const disclosed = try allocator.alloc(u32, occluded.len);
        @memset(disclosed, 0);
        const biome_disclosed = try allocator.alloc(u32, occluded.len);
        @memset(biome_disclosed, 0);
        const light_receipts = try allocator.alloc(lighting.Receipt, occluded.len);
        @memset(light_receipts, .{});
        const refresh_bits = try allocator.alloc(u64, sent.len);
        @memset(refresh_bits, 0);
        var geometry_changes: std.AutoHashMapUnmanaged(chunks.Section, geometry_bounds.Box) = .{};
        try geometry_changes.ensureTotalCapacity(allocator, geometry_change_capacity);
        const published = try allocator.create(Published);
        published.* = .{
            .geometry_changes = geometry_changes,
            .light = try LightChanges.init(allocator, sent.len),
            .views = try allocator.alloc(View, streams.len),
            .streams = try allocator.alloc(Stream, streams.len),
            .sent = try allocator.alloc(u64, sent.len),
            .occluded = try allocator.dupe(u32, occluded),
            .dirty_words = try .initEmpty(allocator, sent.len),
            .changed_views = try lightning_rod.system.IndexSet.init(allocator, streams.len),
            .dirty_streams = try lightning_rod.system.IndexSet.init(allocator, streams.len),
        };
        @memset(published.streams, .{});
        @memset(published.sent, 0);
        for (deps.players.records, published.views) |player, *view| view.* = View.capture(player);
        for (deps.players.activeSlots()) |index| published.changed_views.insert(index);
        self.* = .{
            .geometry_changes = try allocator.alloc(GeometryChange, geometry_change_capacity),
            .biome_sections = try allocator.alloc(?*const [64]u16, 9 * lighting.maximum_sections),
            .classifications = try allocator.alloc(chunks.encoding.Classification, section_visibility_world.World.batch_max),
            .classification_requests = try allocator.alloc(chunks.Chunks.ClassificationRequest, section_visibility_world.World.batch_max),
            .geometry = try section_visibility_world.World.init(allocator, .{
                .columns = if (config.occlusion) config.occlusion_columns orelse (side + 2) * (side + 2) else 1,
                .sources = if (config.occlusion) config.occlusion_sources orelse (2 * streams.len + 1) else 1,
                .radius = if (config.occlusion) @intCast((side - 1) / 2) else 0,
            }),
            .occluded = occluded,
            .stale = stale,
            .disclosed = disclosed,
            .biome_disclosed = biome_disclosed,
            .light_receipts = light_receipts,
            .refresh_bits = refresh_bits,
            .io = io,
            .native_io = io,
            .changed = deps.chunks.ready(),
            .published = published,
            .tracked_views = try lightning_rod.system.IndexSet.init(allocator, deps.players.records.len),
            .views = try allocator.dupe(View, published.views),
            .section_visits = try deps.metrics.counter(.{ .name = "streaming.visibility.visits", .description = "Sections traversed through neighboring openings" }),
            .visibility_hits = try deps.metrics.counter(.{ .name = "streaming.visibility.cache_hits", .description = "Section visibility queries reused" }),
            .queries_started = try deps.metrics.counter(.{ .name = "streaming.visibility.started", .description = "Visibility traversals started" }),
            .queries_completed = try deps.metrics.counter(.{ .name = "streaming.visibility.completed", .description = "Visibility traversals completed" }),
            .queries_cancelled = try deps.metrics.counter(.{ .name = "streaming.visibility.cancelled", .description = "Visibility traversals abandoned before completion" }),
            .section_builds = try deps.metrics.counter(.{ .name = "streaming.visibility.section_builds", .description = "Section face connectivity rebuilt" }),
            .topology = .{
                .rebuilt = try deps.metrics.counter(.{ .name = "streaming.visibility.metadata_rebuilt", .description = "Initialized section topology changed" }),
                .reused = try deps.metrics.counter(.{ .name = "streaming.visibility.metadata_reused", .description = "Edits retained identical section topology" }),
                .evicted = try deps.metrics.counter(.{ .name = "streaming.visibility.cache_evictions", .description = "Metadata columns evicted" }),
                .working_evicted = try deps.metrics.counter(.{ .name = "streaming.visibility.working_evictions", .description = "Metadata evicted inside the active query horizon" }),
            },
            .concealed_sections = try deps.metrics.counter(.{ .name = "streaming.concealed_sections", .description = "Sections encoded as uniform placeholders" }),
            .acquired_chunks = try deps.metrics.counter(.{ .name = "streaming.acquired_chunks", .description = "Chunks acquired for streaming" }),
            .encoded_bytes = try deps.metrics.counter(.{ .name = "streaming.encoded_bytes", .description = "Encoded chunk packet bytes", .unit = .bytes }),
            .deliveries = .{
                .new_columns = try deps.metrics.counter(.{ .name = "streaming.delivery.new_columns", .description = "First deliveries to a recipient" }),
                .replacements = try deps.metrics.counter(.{ .name = "streaming.delivery.replacements", .description = "Column replacements delivered to a recipient" }),
                .reused = try deps.metrics.counter(.{ .name = "streaming.delivery.reused", .description = "Refreshes satisfied by previously delivered terrain" }),
                .new_sections = try deps.metrics.counter(.{ .name = "streaming.delivery.new_sections", .description = "Sections first disclosed or replaced after a world edit" }),
                .repeated_sections = try deps.metrics.counter(.{ .name = "streaming.delivery.repeated_sections", .description = "Unchanged known sections repeated in column replacements" }),
            },
            .lighting_duration = try deps.metrics.timer(.{ .name = "streaming.lighting", .description = "Acquire and light chunk neighborhoods" }),
            .lighting_cpu = try deps.metrics.timer(.{ .name = "streaming.lighting.cpu", .description = "CPU work acquiring and lighting chunk neighborhoods", .clock = .thread_cpu }),
            .encoding_duration = try deps.metrics.timer(.{ .name = "streaming.encoding", .description = "Encode chunk packets" }),
            .publication = try deps.metrics.timer(.{ .name = "streaming.publication", .description = "Publish chunk packet batches" }),
            .cpu = .{
                .poll = try deps.metrics.timer(.{ .name = "streaming.poll.cpu", .description = "Complete chunk streaming poll", .clock = .thread_cpu }),
                .synchronization = try deps.metrics.timer(.{ .name = "streaming.synchronization.cpu", .description = "Apply simulation changes and prepare observer sources", .clock = .thread_cpu }),
                .planning = try deps.metrics.timer(.{ .name = "streaming.planning.cpu", .description = "Plan chunk delivery and unloads", .clock = .thread_cpu }),
                .recipients = try deps.metrics.timer(.{ .name = "streaming.recipients.cpu", .description = "Group recipients for chunk delivery", .clock = .thread_cpu }),
                .geometry = try deps.metrics.timer(.{ .name = "streaming.geometry.cpu", .description = "Learn occlusion geometry from chunk snapshots", .clock = .thread_cpu }),
                .visibility = try deps.metrics.timer(.{ .name = "streaming.visibility.cpu", .description = "Compute section disclosure masks", .clock = .thread_cpu }),
                .encoding = try deps.metrics.timer(.{ .name = "streaming.encoding.cpu", .description = "Encode chunk packets", .clock = .thread_cpu }),
                .publication = try deps.metrics.timer(.{ .name = "streaming.publication.cpu", .description = "Publish chunk packet batches", .clock = .thread_cpu }),
                .completion = try deps.metrics.timer(.{ .name = "streaming.completion.cpu", .description = "Record delivery and advance streaming cursors", .clock = .thread_cpu }),
                .visibility_publication = try deps.metrics.timer(.{ .name = "streaming.visibility_publication.cpu", .description = "Publish visibility to the simulation", .clock = .thread_cpu }),
                .sources = try deps.metrics.timer(.{ .name = "streaming.sources.cpu", .description = "Prepare source sections and shared visibility queries", .clock = .thread_cpu }),
                .light_updates = try deps.metrics.timer(.{ .name = "streaming.light_updates.cpu", .description = "Deliver incremental light changes", .clock = .thread_cpu }),
            },
            .encoding = try chunk_encoding.Workspace.init(allocator),
            .light_staged = try LightChanges.init(allocator, sent.len),
            .light_pending = try LightChanges.init(allocator, sent.len),
            .deps = deps,
            .changed_players = try lightning_rod.system.IndexSet.init(allocator, streams.len),
            .background_players = try lightning_rod.system.IndexSet.init(allocator, streams.len),
            .occupied_players = try lightning_rod.system.IndexSet.init(allocator, streams.len),
            .observers_index = try SpatialIndex.init(allocator, streams.len),
            .generation_updates = try allocator.alloc(chunks.Generation.Update, streams.len),
            .config = config,
            .streams = streams,
            .sources = try allocator.alloc(Source, streams.len),
            .origins = try allocator.alloc(section_visibility_world.Source, streams.len),
            .recipients = try allocator.alloc(sessions.Handle, streams.len * batch_max),
            .sent = sent,
            .dirty_words = try .initEmpty(allocator, sent.len),
            .words_per_player = words,
            .visibility = .{
                .reset = try lightning_rod.system.IndexSet.init(allocator, streams.len),
                .streams = try allocator.alloc(Stream, streams.len),
                .sent = try allocator.alloc(u64, sent.len),
                .occluded = try allocator.dupe(u32, occluded),
                .changed = try allocator.alloc(u64, sent.len),
                .changed_words = try lightning_rod.system.IndexSet.init(allocator, sent.len),
                .words_per_player = words,
                .side = @intCast(side),
                .radius = deps.players.config.render_distance,
            },
        };
        for (deps.players.activeSlots()) |index| self.updateAudience(index);
        @memset(self.visibility.streams, .{});
        @memset(self.sources, .{});
        @memset(self.visibility.sent, 0);
        try deps.chunks.observe(chunks.Observer.init(self, blocksChanged));
        try deps.sessions.subscribeOutput(self.changed);
        try deps.chunks.subscribeReady(self.changed);
        deps.players.gateTeleports(players.Players.TeleportGate.init(Streaming, self, teleportReady));
        return self;
    }

    pub fn close(self: *Streaming, _: *lightning_rod.Closing) void {
        self.deps.sessions.unsubscribeOutput(self.changed);
        self.deps.chunks.unsubscribeReady(self.changed);
    }

    pub fn tick(self: *Streaming) void {
        self.visibility.capture(self.published, self.native_io);
    }

    fn teleportReady(self: *Streaming, player: *const players.Players.Player) bool {
        const handle = player.handle.?;
        const stream = self.visibility.streams[handle.index];
        assert(player.stage == .teleport);
        return stream.generation == handle.generation and stream.life == player.life and stream.prepared_teleport == player.teleport_id;
    }

    fn placementReady(self: *const Streaming, index: usize) bool {
        const view = self.views[index];
        const stream = self.streams[index];
        return view.handle != null and view.ready and stream.generation == view.handle.?.generation and stream.life == view.life and
            stream.delivered != 0 and stream.setup == .streaming and std.meta.eql(stream.center, view.center) and self.occupiedColumn(index) == null;
    }

    pub fn attachDebug(self: *Streaming, slots: []streaming_debug.Slot) void {
        assert(self.debug_slots.len == 0 and slots.len != 0);
        self.debug_slots = slots;
    }

    pub fn requestDebug(self: *Streaming, index: usize, handle: sessions.Handle, world: u32, life: u32) void {
        self.published.mutex.lockUncancelable(self.native_io);
        const slot = &self.debug_slots[index];
        if (!std.meta.eql(slot.handle, handle) or slot.world != world or slot.life != life) slot.* = .{};
        slot.handle = handle;
        slot.world = world;
        slot.life = life;
        slot.requested = true;
        self.published.updated = true;
        self.published.mutex.unlock(self.native_io);
        self.changed.set(self.native_io);
    }

    pub fn readDebug(self: *Streaming, index: usize, handle: sessions.Handle, world: u32, life: u32, output: *streaming_debug.Snapshot) bool {
        self.published.mutex.lockUncancelable(self.native_io);
        defer self.published.mutex.unlock(self.native_io);
        const slot = &self.debug_slots[index];
        if (!slot.ready or !std.meta.eql(slot.handle, handle) or slot.world != world or slot.life != life) return false;
        output.* = slot.snapshot;
        return true;
    }

    pub fn clearDebug(self: *Streaming, index: usize) void {
        self.published.mutex.lockUncancelable(self.native_io);
        defer self.published.mutex.unlock(self.native_io);
        self.debug_slots[index] = .{};
    }

    pub fn endTick(self: *Streaming, completed: bool) void {
        if (!completed) {
            self.light_staged.clear();
            return;
        }
        const published = self.published;
        published.mutex.lockUncancelable(self.native_io);
        defer published.mutex.unlock(self.native_io);
        var changed = self.light_staged.words.count != 0;
        published.light.merge(&self.light_staged);
        for (self.deps.players.activeSlots()) |index| self.tracked_views.insert(index);
        var view_index: usize = 0;
        while (view_index < self.tracked_views.count) {
            const index = self.tracked_views.indices[view_index];
            const player = self.deps.players.records[index];
            const view = &published.views[index];
            if (player.handle == null) self.tracked_views.remove(index) else view_index += 1;
            const current = View.capture(player);
            if (!std.meta.eql(view.*, current)) {
                view.* = current;
                published.changed_views.insert(index);
                changed = true;
            }
        }
        published.updated = published.updated or changed;
        published.epoch = self.deps.sessions.backgroundEpoch() + 1;
        self.wake_pending = changed;
    }

    pub fn publish(self: *Streaming) void {
        if (!self.wake_pending) return;
        self.wake_pending = false;
        self.changed.set(self.io);
    }

    pub fn poll(self: *Streaming, io: std.Io) !bool {
        const cpu = self.cpu.poll.start();
        defer cpu.end();
        const builds = self.geometry.builds;
        const rebuilds = self.geometry.rebuilds;
        const reused = self.geometry.unchanged;
        const evictions = self.geometry.evictions;
        const working_evictions = self.geometry.working_evictions;
        const visits = self.geometry.visits;
        const hits = self.geometry.cache_hits;
        const started = self.geometry.started;
        const completed = self.geometry.completed;
        const cancelled = self.geometry.cancelled;
        defer {
            self.section_builds.add(self.geometry.builds - builds);
            self.topology.rebuilt.add(self.geometry.rebuilds - rebuilds);
            self.topology.reused.add(self.geometry.unchanged - reused);
            self.topology.evicted.add(self.geometry.evictions - evictions);
            self.topology.working_evicted.add(self.geometry.working_evictions - working_evictions);
            self.section_visits.add(self.geometry.visits - visits);
            self.visibility_hits.add(self.geometry.cache_hits - hits);
            self.queries_started.add(self.geometry.started - started);
            self.queries_completed.add(self.geometry.completed - completed);
            self.queries_cancelled.add(self.geometry.cancelled - cancelled);
        }
        if (!self.deps.chunks.ownsCurrentThread()) return error.InvalidChunkOwner;
        defer self.deps.sessions.retryBackground(self.epoch);
        const progressed = try self.sendBatch(io, batch_max);
        self.deps.sessions.flush();
        if (progressed) self.changed.set(io);
        return progressed;
    }

    fn sendBatch(self: *Streaming, _: std.Io, maximum_items: usize) !bool {
        defer self.deps.lighting.releaseDelivery();
        {
            const cpu = self.cpu.synchronization.start();
            defer cpu.end();
            const changed = &self.changed_players;
            changed.clear();
            self.published.mutex.lockUncancelable(self.native_io);
            self.epoch = self.published.epoch;
            const geometry_overflow = self.published.geometry_overflow;
            var geometry_count: usize = 0;
            if (self.geometry_revision != self.published.geometry_revision) {
                self.geometry_revision = self.published.geometry_revision;
                var changed_sections = self.published.geometry_changes.iterator();
                while (changed_sections.next()) |entry| {
                    self.geometry_changes[geometry_count] = .{ .section = entry.key_ptr.*, .bounds = entry.value_ptr.* };
                    geometry_count += 1;
                }
                self.published.geometry_changes.clearRetainingCapacity();
                self.published.geometry_overflow = false;
            }
            self.pending = self.pending or self.published.updated;
            self.published.updated = false;
            self.light_pending.merge(&self.published.light);
            if (!self.pending) {
                self.published.mutex.unlock(self.native_io);
                return false;
            }
            for (self.published.changed_views.values()) |index| {
                const previous = &self.views[index];
                const current = self.published.views[index];
                self.background_players.insert(index);
                if (!std.meta.eql(previous.handle, current.handle) or previous.world != current.world or previous.ready != current.ready or !std.meta.eql(previous.center, current.center) or (current.handle != null and !self.observers_index.contains(index))) {
                    changed.insert(index);
                }
                self.updateView(index, current);
                self.occupied_players.insert(index);
            }
            self.published.changed_views.clear();
            self.published.mutex.unlock(self.native_io);
            if (geometry_overflow) {
                self.geometry.invalidate();
            } else for (self.geometry_changes[0..geometry_count]) |change| {
                const section = change.section;
                const dimension = self.deps.worlds.get(section.world).?.dimension;
                self.geometry.changed(section.world, dimension.minimumSection(), change.bounds);
                const offset = section.y - dimension.minimumSection();
                if (offset < 0 or offset >= dimension.sectionCount()) continue;
                var nearby = self.observers_index.query(.{ .world = section.world, .x = section.x, .z = section.z }, self.deliveryRadius() + 1);
                while (nearby.next()) |index| {
                    if (self.views[index].world != section.world) continue;
                    if (@abs(@as(i64, section.x) - self.streams[index].center.x) > self.deliveryRadius() or @abs(@as(i64, section.z) - self.streams[index].center.z) > self.deliveryRadius()) continue;
                    // Visible edits arrive as deltas. Concealed edits invalidate retained terrain.
                    if (!self.sectionVisible(index, section)) self.invalidateSection(index, section);
                }
            }
            if (geometry_overflow) {
                @memset(self.stale, std.math.maxInt(u32));
                @memset(self.occluded, std.math.maxInt(u32));
                self.dirty_words.setRangeValue(.{ .start = 0, .end = self.sent.len }, true);
                for (self.background_players.values()) |index| self.occupied_players.insert(index);
            }
            if (self.config.occlusion and !geometry_overflow and geometry_count != 0) {
                var window = chunks.ReadWindow(192).init(self.deps.chunks);
                defer window.deinit();
                var views: [192]chunks.View = undefined;
                var begin: usize = 0;
                while (begin < geometry_count) {
                    const count = @min(geometry_count - begin, @min(views.len, self.deps.chunks.backgroundCapacity()));
                    var sections: [192]chunks.Section = undefined;
                    for (self.geometry_changes[begin..][0..count], sections[0..count]) |change, *section| section.* = change.section;
                    try window.readMany(sections[0..count], views[0..count]);
                    for (sections[0..count], views[0..count]) |section, view| {
                        const dimension = self.deps.worlds.get(section.world).?.dimension;
                        const offset = section.y - dimension.minimumSection();
                        if (offset < 0 or offset >= dimension.sectionCount()) continue;
                        self.geometry.learnSection(.{ .world = section.world, .x = section.x, .z = section.z, .minimum = dimension.minimumSection() }, dimension.sectionCount(), @intCast(offset), if (view == .uniform) .{ .uniform = view.uniform } else .{ .chunk = view });
                    }
                    begin += count;
                }
            }
            if (geometry_count != 0 or geometry_overflow) {
                for (self.background_players.values()) |index| {
                    const view = self.views[index];
                    const source = &self.sources[index];
                    var source_changed = geometry_overflow;
                    if (source.origin) |origin| {
                        var bounds = origin.bounds();
                        for (0..3) |axis| {
                            bounds.minimum[axis] -= section_visibility_world.camera_margin;
                            bounds.maximum[axis] += section_visibility_world.camera_margin;
                        }
                        for (self.geometry_changes[0..geometry_count]) |change| {
                            if (change.section.world != view.world) continue;
                            var touches = true;
                            for (0..3) |axis| touches = touches and change.bounds.minimum[axis] < bounds.maximum[axis] and change.bounds.maximum[axis] > bounds.minimum[axis];
                            source_changed = source_changed or touches;
                        }
                    }
                    if (source_changed) self.refresh(index, true);
                }
            }
            const updates = self.generation_updates;
            var update_count: usize = 0;
            for (changed.values()) |index| {
                const current = self.views[index];
                self.updateAudience(index);
                updates[update_count] = .{ .player = index, .interest = if (current.handle != null and current.ready) .{
                    .world = current.world,
                    .x = current.center.x,
                    .z = current.center.z,
                    .radius = @intCast(self.deliveryRadius() + 1),
                } else null };
                update_count += 1;
            }
            self.deps.chunks.generation.updateMany(updates[0..update_count]);
        }
        if (self.epoch != self.deps.sessions.backgroundEpoch() or self.epoch & 1 != 0) return false;
        defer self.publishVisibility();
        const service = self.deps.sessions;
        const radius = self.deliveryRadius();
        const side: usize = @intCast(2 * radius + 1);
        assert(maximum_items > 0 and maximum_items <= batch_max);
        const batch_limit = maximum_items;
        var pending: [batch_max]Pending = undefined;
        var count: usize = 0;
        var reserved: usize = 0;
        var released: usize = 0;
        var reservations: [batch_max]sessions.Service.Packet = undefined;
        defer for (reservations[released..reserved]) |*packet| packet.cancel();
        var progressed = false;
        var setup_progress = false;
        self.pending = false;
        {
            const cpu = self.cpu.planning.start();
            defer cpu.end();
            for (self.background_players.values()) |index| self.advanceCursor(index);
            for (0..self.background_players.count) |_| {
                const position = self.next_player % self.background_players.count;
                const index = self.background_players.indices[position];
                self.next_player = (position + 1) % self.background_players.count;
                const player = &self.views[index];
                const stream = &self.streams[index];
                const handle = player.handle orelse continue;
                if (!player.ready) continue;
                if (self.needsSource(index)) {
                    self.pending = true;
                }

                const center = player.center;

                if (stream.generation != handle.generation or stream.life != player.life) {
                    const dimension = self.deps.worlds.get(player.world).?.dimension;
                    stream.* = .{ .generation = handle.generation, .life = player.life, .center = center, .target = center, .minimum_section = dimension.minimumSection(), .section_count = dimension.sectionCount() };
                    @memset(self.occluded[index * side * side ..][0 .. side * side], std.math.maxInt(u32));
                    @memset(self.stale[index * side * side ..][0 .. side * side], 0);
                    @memset(self.disclosed[index * side * side ..][0 .. side * side], 0);
                    @memset(self.refresh_bits[index * self.words_per_player ..][0..self.words_per_player], 0);
                    @memset(self.sent[index * self.words_per_player ..][0..self.words_per_player], 0);
                    @memset(self.biome_disclosed[index * side * side ..][0 .. side * side], 0);
                    @memset(self.light_receipts[index * side * side ..][0 .. side * side], .{});
                    self.dirty_words.setRangeValue(.{ .start = index * self.words_per_player, .end = (index + 1) * self.words_per_player }, true);
                }

                self.pending = self.pending or stream.setup != .streaming or stream.cursor < side * side or
                    self.needsSource(index) or !std.meta.eql(center, stream.center);
                if (!service.canSend(handle, 1) and (stream.setup != .streaming or !std.meta.eql(center, stream.center))) continue;

                if (stream.setup == .streaming and !std.meta.eql(center, stream.center)) {
                    stream.target = center;
                    stream.unload_cursor = 0;
                    stream.setup = .unloading;
                }

                if (stream.setup == .unloading) {
                    var departing = departingPosition(stream.center, stream.target, radius, stream.unload_cursor);
                    while (departing) |at| {
                        if (self.hasSent(index, at)) break;
                        stream.unload_cursor += 1;
                        departing = departingPosition(stream.center, stream.target, radius, stream.unload_cursor);
                    }

                    if (departing == null) {
                        stream.center = stream.target;
                        self.updateAudience(index);
                        stream.cursor = 0;
                        stream.setup = .center;
                    } else {
                        progressed = try self.unloadBatch(index) or progressed;
                        continue;
                    }
                }

                if (stream.setup != .streaming) {
                    var packet = service.reserveBackground(64, self.epoch) catch |err| switch (err) {
                        error.Backpressured => continue,
                        error.Closed => return false,
                        else => return err,
                    };
                    defer packet.cancel();
                    const bytes = if (stream.setup == .terrain)
                        try self.deps.packets.writePacket(writeTerrainReady, player.protocol, packet.bytes, .{})
                    else
                        try self.deps.packets.writePacket(writeViewCenter, player.protocol, packet.bytes, .{stream.center});
                    packet.publish(bytes.len, &.{handle}) catch |err| switch (err) {
                        error.Backpressured, error.Closed => continue,
                        else => return err,
                    };
                    stream.setup = if (stream.setup == .terrain) .center else .streaming;
                    progressed = true;
                    setup_progress = true;
                    continue;
                }
            }
            var selected: ?Pending = null;
            var occupied_remaining = self.occupied_players.count;
            while (occupied_remaining != 0 and self.occupied_players.count != 0) : (occupied_remaining -= 1) {
                const position = self.next_occupied_player % self.occupied_players.count;
                const index = self.occupied_players.indices[position];
                const column = self.occupiedColumn(index) orelse {
                    if (self.streams[index].setup == .streaming or !self.views[index].ready or self.views[index].handle == null) {
                        self.occupied_players.remove(index);
                    } else self.next_occupied_player = (position + 1) % self.occupied_players.count;
                    continue;
                };
                if (!self.canDeliverColumn(index, column)) {
                    self.next_occupied_player = (position + 1) % self.occupied_players.count;
                    continue;
                }
                self.next_occupied_player = position;
                selected = .{ .at = column.at, .world = column.world, .protocol = self.views[index].protocol, .owner = index };
                break;
            }
            if (selected == null and !setup_progress) try self.prepareSources();
            if (selected == null) if (self.delivery_column) |column| {
                for (0..self.background_players.count) |offset| {
                    const position = (self.next_player + offset) % self.background_players.count;
                    const index = self.background_players.indices[position];
                    if (!self.canDeliverColumn(index, column)) continue;
                    selected = .{ .at = column.at, .world = column.world, .protocol = self.views[index].protocol, .owner = index };
                    break;
                }
            };
            if (selected == null) {
                for (0..self.background_players.count) |offset| {
                    const position = (self.next_player + offset) % self.background_players.count;
                    const index = self.background_players.indices[position];
                    const stream = self.streams[index];
                    if (stream.cursor == side * side) continue;
                    const relative = spiral(stream.cursor);
                    const column: DeliveryColumn = .{ .world = self.views[index].world, .at = .{ .x = stream.center.x + relative.x, .z = stream.center.z + relative.z } };
                    if (!self.canDeliverColumn(index, column)) continue;
                    selected = .{ .at = column.at, .world = column.world, .protocol = self.views[index].protocol, .owner = index };
                    if (position != self.next_player) self.columns_in_turn = 0;
                    self.columns_in_turn += 1;
                    assert(self.columns_in_turn <= batch_max);
                    if (self.columns_in_turn == batch_max) {
                        self.columns_in_turn = 0;
                        self.next_player = (position + 1) % self.background_players.count;
                    } else self.next_player = position;
                    break;
                }
            }
            self.delivery_column = if (selected) |item| .{ .world = item.world, .at = item.at } else null;
            if (selected) |first| {
                pending[0] = first;
                count = 1;
                var nearby = self.observers_index.query(.{ .world = first.world, .x = first.at.x, .z = first.at.z }, @intCast(radius));
                while (nearby.next()) |index| {
                    if (count == batch_limit) break;
                    if (!self.canDeliverColumn(index, self.delivery_column.?)) continue;
                    const player = self.views[index];
                    var duplicate = false;
                    for (pending[0..count]) |item| duplicate = duplicate or (item.protocol == player.protocol and self.sameDisclosure(item.owner, index, first.at));
                    if (duplicate) continue;
                    pending[count] = .{ .at = first.at, .world = first.world, .protocol = player.protocol, .owner = index };
                    count += 1;
                }
                self.pending = true;
            }
            if (selected) |first| {
                const stream = self.streams[first.owner];
                if (stream.delivered != 0 and (!self.needsSource(first.owner) or self.canConcealColumn(first.owner, first.at)) and self.columns_in_turn != 0 and
                    self.next_player == self.background_players.positions[first.owner])
                {
                    var cursor = stream.cursor;
                    const end = @min(side * side, cursor + batch_max);
                    while (count < batch_limit and self.columns_in_turn < batch_max and cursor < end) : (cursor += 1) {
                        const relative = spiral(cursor);
                        const column: DeliveryColumn = .{ .world = first.world, .at = .{ .x = stream.center.x + relative.x, .z = stream.center.z + relative.z } };
                        var duplicate = false;
                        for (pending[0..count]) |item| duplicate = duplicate or (item.world == column.world and std.meta.eql(item.at, column.at));
                        if (duplicate or !self.canDeliverColumn(first.owner, column)) continue;
                        pending[count] = .{ .at = column.at, .world = column.world, .protocol = first.protocol, .owner = first.owner };
                        count += 1;
                        self.columns_in_turn += 1;
                    }
                    if (self.columns_in_turn == batch_max) {
                        self.columns_in_turn = 0;
                        self.next_player = (self.next_player + 1) % self.background_players.count;
                    }
                }
            }
        }
        if (count == 0) return progressed;
        if (service.backgroundEpoch() != self.epoch) return progressed;
        var needing_data: usize = 0;
        for (pending[0..count]) |candidate| {
            var item = candidate;
            const owner = item.owner;
            const handle = self.views[owner].handle.?;
            const dimension = self.deps.worlds.get(item.world).?.dimension;
            const column: section_visibility_world.Column = .{ .world = item.world, .x = item.at.x, .z = item.at.z, .minimum = dimension.minimumSection() };
            if (self.hasSent(owner, item.at) and self.canConcealColumn(owner, item.at)) {
                const mask = self.sectionMask(owner, column, dimension.sectionCount());
                const desired = mask | self.constantMask(owner, column, dimension.sectionCount());
                if (service.backgroundEpoch() != self.epoch) return progressed;
                item.visibility = mask;
                item.biome_disclosure = mask;
                self.hideSections(owner, item.at, ~mask);
                self.restoreSections(owner, item.at, mask);
                if (self.canReuseColumn(owner, item.at, desired, mask)) {
                    self.deliveries.reused.add(1);
                    self.finishRefresh(&item, &.{handle});
                    progressed = true;
                    continue;
                }
            }
            pending[needing_data] = item;
            needing_data += 1;
        }
        count = needing_data;
        if (count == 0) return progressed;
        const reservation_sizes: [batch_max]usize = @splat(service.config.page_bytes);
        count = service.reserveBatch(reservation_sizes[0..count], reservations[0..count]) catch |err| switch (err) {
            error.Closed => return progressed,
            else => return err,
        };
        for (reservations[0..count]) |*packet| packet.epoch = self.epoch;
        reserved = count;
        if (count == 0) return progressed;

        {
            const cpu = self.lighting_cpu.start();
            defer cpu.end();
            var deliveries: [batch_max]lighting.Lighting.Delivery = undefined;
            var distinct: usize = 0;
            for (pending[0..count]) |item| {
                var duplicate = false;
                for (deliveries[0..distinct]) |delivery| duplicate = duplicate or (delivery.world == item.world and delivery.x == item.at.x and delivery.z == item.at.z);
                if (duplicate) continue;
                deliveries[distinct] = .{ .world = item.world, .x = item.at.x, .z = item.at.z, .dimension = self.deps.worlds.get(item.world).?.dimension };
                distinct += 1;
            }
            try self.deps.lighting.prepareDeliveries(deliveries[0..distinct]);
        }

        var publications: [batch_max]sessions.Service.Publication = undefined;
        var accepted: [batch_max]usize = undefined;
        var encoded_count: usize = 0;
        var lighting_prepared: ?DeliveryColumn = null;
        var encoded_indices: [batch_max]usize = undefined;
        var light_updates: [batch_max]lighting.Receipt.Update = undefined;
        var recipient_counts: [batch_max]usize = undefined;
        {
            const cpu = self.cpu.recipients.start();
            defer cpu.end();
            self.planRecipients(pending[0..count], recipient_counts[0..count]);
        }
        for (pending[0..count], recipient_counts[0..count], 0..) |*item, recipient_count, i| {
            const packet = &reservations[i];
            var recipients = recipient_count;
            const targets = self.recipients[i * self.views.len ..][0..self.views.len];
            const dimension = self.deps.worlds.get(item.world).?.dimension;
            const column: section_visibility_world.Column = .{ .world = item.world, .x = item.at.x, .z = item.at.z, .minimum = dimension.minimumSection() };
            const priority: chunks.GenerationPriority = .{
                .urgency = if (self.missingSections(item.owner, item.at, self.collisionMask(item.owner, column, dimension.sectionCount())) != 0) .occupied else .streaming,
                .player = item.owner,
            };
            const ready = inputs: {
                const timing = self.lighting_duration.start();
                defer timing.end();
                const cpu = self.lighting_cpu.start();
                defer cpu.end();
                break :inputs try self.deps.lighting.prepareDelivery(item.world, item.at.x, item.at.z, dimension, priority);
            };
            if (!ready or service.backgroundEpoch() != self.epoch) {
                for (reservations[i..count]) |*waiting| waiting.cancel();
                break;
            }
            {
                const cpu = self.cpu.geometry.start();
                defer cpu.end();
                if (self.config.occlusion) {
                    self.deps.lighting.deliveryBiomes(self.biome_sections[0 .. 9 * dimension.sectionCount()]);
                    self.geometry.learn(column, self.deps.lighting.deliverySections(0));
                }
            }
            var matching: usize = 0;
            var owner_included = false;
            for (targets[0..recipients]) |handle| {
                if (!self.sameDisclosure(item.owner, handle.index, item.at)) continue;
                targets[matching] = handle;
                matching += 1;
                owner_included = owner_included or handle.index == item.owner;
            }
            recipients = matching;
            assert(recipients != 0 and owner_included);
            assert(recipients != 0);
            const candidate = self.disclosureMasks(item.owner, column, dimension.sectionCount());
            // Publish authority only after any newly disclosed terrain has been delivered.
            item.visibility = candidate.visibility;
            item.disclosure = candidate.disclosure | ~((@as(u32, 1) << @intCast(dimension.sectionCount())) - 1);
            item.biome_disclosure = (item.visibility | self.collisionMask(item.owner, column, dimension.sectionCount())) & item.disclosure;
            if (service.backgroundEpoch() == self.epoch) {
                for (targets[0..recipients]) |handle| if (self.hasSent(handle.index, item.at)) {
                    self.hideSections(handle.index, item.at, ~candidate.visibility);
                    self.restoreSections(handle.index, item.at, candidate.visibility);
                };
            }
            if (self.canReuseColumn(item.owner, item.at, candidate.disclosure, item.biome_disclosure)) {
                self.deliveries.reused.add(recipients);
                packet.cancel();
                self.finishRefresh(item, targets[0..recipients]);
                progressed = true;
                continue;
            }
            const slot = self.columnIndex(item.owner, item.at);
            // Retain known terrain without granting authority to observe its current activity.
            item.disclosure |= self.disclosed[slot] & ~self.stale[slot];
            item.biome_disclosure |= self.biome_disclosed[slot] & ~self.stale[slot];
            {
                const timing = self.lighting_duration.start();
                defer timing.end();
                const cpu = self.lighting_cpu.start();
                defer cpu.end();
                if (!try self.deps.lighting.prepareDeliverySections(item.disclosure, priority) or service.backgroundEpoch() != self.epoch) {
                    for (reservations[i..count]) |*waiting| waiting.cancel();
                    break;
                }
            }
            if (self.config.occlusion) {
                const cpu = self.cpu.geometry.start();
                defer cpu.end();
                self.geometry.learn(column, self.deps.lighting.deliverySections(item.disclosure));
            }
            const stone = self.geometry.stoneMask(column, dimension.sectionCount());
            {
                const timing = self.lighting_duration.start();
                defer timing.end();
                const cpu = self.lighting_cpu.start();
                defer cpu.end();
                const delivery: DeliveryColumn = .{ .world = item.world, .at = item.at };
                if (lighting_prepared == null or !std.meta.eql(lighting_prepared.?, delivery)) {
                    var selection: u32 = 0;
                    var nearby = self.observers_index.query(.{ .world = item.world, .x = item.at.x, .z = item.at.z }, @intCast(radius));
                    while (nearby.next()) |index| {
                        if (!self.canDeliverColumn(index, .{ .world = item.world, .at = item.at })) continue;
                        const desired = self.disclosureMasks(index, column, dimension.sectionCount()).disclosure;
                        const retained = self.columnIndex(index, item.at);
                        selection |= desired | (self.disclosed[retained] & ~self.stale[retained]);
                    }
                    try self.deps.lighting.lightDelivery(selection & ((@as(u32, 1) << @intCast(dimension.sectionCount())) - 1) & ~stone);
                    lighting_prepared = delivery;
                }
                assert(item.disclosure & ((@as(u32, 1) << @intCast(dimension.sectionCount())) - 1) & ~stone & ~self.deps.lighting.deliveryData().coverage == 0);
            }
            if (service.backgroundEpoch() != self.epoch) {
                for (reservations[i..count]) |*waiting| waiting.cancel();
                break;
            }
            self.acquired_chunks.add(1);
            const encoded = encode: {
                const encoding = self.encoding_duration.start();
                defer encoding.end();
                const cpu = self.cpu.encoding.start();
                defer cpu.end();
                var light = self.deps.lighting.deliveryData();
                light.disclosure &= item.disclosure & ~stone;
                if (self.hasSent(item.owner, item.at)) {
                    const disclosed = item.disclosure & ((@as(u32, 1) << @intCast(dimension.sectionCount())) - 1);
                    const changed = self.missingSections(item.owner, item.at, disclosed);
                    light.selection = changed | (changed << 1) | (changed << 2);
                }
                const sections = self.deps.lighting.deliverySections(item.disclosure);
                var available: [9]u32 = @splat(0);
                for (0..9) |column_index| for (0..dimension.sectionCount()) |y| {
                    const biomes = if (column_index == 4) sections[y].biomes else if (self.config.occlusion) self.biome_sections[column_index * dimension.sectionCount() + y] else continue;
                    if (biomes != null) available[column_index] |= @as(u32, 1) << @intCast(y);
                };
                item.biome = disclosedBiome(sections, item.biome_disclosure);
                const neighbors: chunk_encoding.BiomeNeighborhood = .{
                    .biomes = self.biome_sections[0 .. 9 * dimension.sectionCount()],
                    .count = dimension.sectionCount(),
                    .disclosed = self.biomeMasks(item.owner, item.at, item.biome_disclosure, &available),
                };
                const sample = item.biome orelse neighbors.first();
                const biome = try self.coverBiome(item.owner, sample);
                if (item.biome_disclosure != (@as(u32, 1) << @intCast(dimension.sectionCount())) - 1) {
                    matching = 0;
                    owner_included = false;
                    for (targets[0..recipients]) |handle| {
                        const masks = self.biomeMasks(handle.index, item.at, item.biome_disclosure, &available);
                        if (!std.mem.eql(u32, &masks, &neighbors.disclosed)) continue;
                        const other = self.coverBiome(handle.index, sample) catch continue;
                        if (other != biome) continue;
                        targets[matching] = handle;
                        matching += 1;
                        owner_included = owner_included or handle.index == item.owner;
                    }
                    recipients = matching;
                    assert(recipients != 0 and owner_included);
                }
                light_updates[i] = self.retainLight(item.at, targets[0..recipients], &light);
                break :encode try self.deps.packets.writePacket(chunk_encoding.write, item.protocol, packet.bytes, .{ chunk_encoding.Chunk{
                    .x = item.at.x,
                    .z = item.at.z,
                    .sections = sections,
                    .biome = biome,
                    .minimum_section = dimension.minimumSection(),
                    .workspace = self.encoding,
                    .light = light,
                    .disclosure = item.disclosure,
                    .biome_disclosure = item.biome_disclosure,
                    .biome_neighbors = if (self.config.occlusion) &neighbors else null,
                    .concealment = 0,
                }, try self.deps.packets.definition(item.protocol) });
            };
            self.concealed_sections.add(@popCount(~item.disclosure & ((@as(u32, 1) << @intCast(dimension.sectionCount())) - 1)));
            self.encoded_bytes.add(encoded.len);
            self.streams[item.owner].packet_bytes = encoded.len;
            encoded_indices[encoded_count] = i;
            publications[encoded_count] = .{ .packet = packet, .length = encoded.len, .recipients = targets[0..recipients] };
            encoded_count += 1;
            if (service.backgroundEpoch() != self.epoch) {
                for (reservations[i + 1 .. count]) |*waiting| waiting.cancel();
                self.next_player = self.background_players.positions[item.owner];
                break;
            }
            // Publish a cold column before beginning another lighting solve.
            if (!self.deps.lighting.delivery_saved) {
                for (reservations[i + 1 .. count]) |*waiting| waiting.cancel();
                break;
            }
        }
        {
            const publication = self.publication.start();
            defer publication.end();
            const cpu = self.cpu.publication.start();
            defer cpu.end();
            service.publishManyReady(publications[0..encoded_count], accepted[0..encoded_count]);
        }
        released = count;
        const completion = self.cpu.completion.start();
        defer completion.end();
        for (encoded_indices[0..encoded_count], publications[0..encoded_count], accepted[0..encoded_count]) |item_index, publication, admitted| {
            const item = &pending[item_index];
            if (admitted != 0 and self.occupied_players.contains(item.owner)) {
                const position = self.occupied_players.positions[item.owner];
                assert(position < self.occupied_players.count and self.occupied_players.indices[position] == item.owner);
                self.next_occupied_player = (position + 1) % self.occupied_players.count;
            }
            for (publication.recipients[0..admitted]) |handle| {
                assert(self.streams[handle.index].delivered != 0 or std.meta.eql(item.at, self.streams[handle.index].center));
                if (self.sources[handle.index].biome == null) self.sources[handle.index].biome = item.biome;
                const was_sent = self.hasSent(handle.index, item.at);
                const slot = self.columnIndex(handle.index, item.at);
                if (was_sent) self.deliveries.replacements.add(1) else self.deliveries.new_columns.add(1);
                const known = if (was_sent) self.disclosed[slot] & ~self.stale[slot] else 0;
                const valid = (@as(u32, 1) << @intCast(self.streams[handle.index].section_count)) - 1;
                self.deliveries.new_sections.add(@popCount(item.disclosure & valid & ~known));
                self.deliveries.repeated_sections.add(@popCount(item.disclosure & valid & known));
                self.biome_disclosed[slot] = item.biome_disclosure;
                self.light_receipts[slot].apply(light_updates[item_index]);
                assert(self.disclosed[slot] & ~self.stale[slot] & ~item.disclosure == 0);
                self.occluded[slot] = ~item.visibility & ((@as(u32, 1) << @intCast(self.deps.worlds.get(item.world).?.dimension.sectionCount())) - 1);
                self.stale[slot] = 0;
                self.disclosed[slot] = item.disclosure & ((@as(u32, 1) << @intCast(self.streams[handle.index].section_count)) - 1);
                self.clearRefresh(handle.index, item.at);
                self.markSent(handle.index, item.at, true);
                const stream = &self.streams[handle.index];
                stream.packet_bytes = publication.length;
                stream.delivered += @intFromBool(!was_sent);
                self.advanceCursor(handle.index);
            }

            progressed = progressed or admitted != 0;
        }

        assert(released == count);
        assert(count <= maximum_items);
        return progressed;
    }

    fn unloadBatch(self: *Streaming, index: usize) !bool {
        const service = self.deps.sessions;
        const stream = &self.streams[index];
        const player = self.views[index];
        assert(stream.setup == .unloading and player.handle != null);
        var positions: [batch_max]Position = undefined;
        var cursors: [batch_max]usize = undefined;
        var count: usize = 0;
        var cursor = stream.unload_cursor;
        while (count < positions.len) : (cursor += 1) {
            const at = departingPosition(stream.center, stream.target, self.deliveryRadius(), cursor) orelse break;
            if (!self.hasSent(index, at)) continue;
            positions[count] = at;
            cursors[count] = cursor;
            count += 1;
        }
        assert(count != 0);
        var reserved_packets: [batch_max]sessions.Service.Packet = undefined;
        const sizes: [batch_max]usize = @splat(64);
        count = service.reserveBatch(sizes[0..count], reserved_packets[0..count]) catch |err| switch (err) {
            error.Closed => return false,
            else => return err,
        };
        defer service.cancelPackets(reserved_packets[0..count]);
        var publications: [batch_max]sessions.Service.Publication = undefined;
        var recipients: [batch_max][1]sessions.Handle = undefined;
        var accepted: [batch_max]usize = undefined;
        for (reserved_packets[0..count], 0..) |*packet, i| {
            packet.epoch = self.epoch;
            recipients[i] = .{player.handle.?};
            const bytes = try self.deps.packets.writePacket(writeUnload, player.protocol, packet.bytes, .{positions[i]});
            publications[i] = .{ .packet = packet, .length = bytes.len, .recipients = &recipients[i] };
        }
        service.publishManyReady(publications[0..count], accepted[0..count]);
        var progressed = false;
        var rejected = false;
        for (positions[0..count], cursors[0..count], accepted[0..count]) |at, position_cursor, admitted| {
            assert(admitted <= 1);
            if (!rejected) stream.unload_cursor = position_cursor + @intFromBool(admitted != 0);
            rejected = rejected or admitted == 0;
            if (admitted == 0) continue;
            self.markSent(index, at, false);
            stream.delivered -= 1;
            progressed = true;
        }
        // Keep the cursor before rejected entries so partial admission cannot skip an unload.
        return progressed;
    }

    fn planRecipients(self: *Streaming, pending: []const Pending, counts: []usize) void {
        assert(pending.len == counts.len and pending.len <= batch_max);
        const radius = self.deliveryRadius();
        for (pending, counts, 0..) |item, *count, i| {
            count.* = 0;
            const targets = self.recipients[i * self.views.len ..][0..self.views.len];
            var owner_found = false;
            var nearby = self.observers_index.query(.{ .world = item.world, .x = item.at.x, .z = item.at.z }, @intCast(radius));
            while (nearby.next()) |index| {
                const player = &self.views[index];
                const stream = &self.streams[index];
                const handle = player.handle orelse continue;
                if (player.world != item.world or !player.ready or player.protocol != item.protocol or stream.setup != .streaming or stream.generation != handle.generation)
                    continue;
                if (@abs(item.at.x - stream.center.x) > radius or @abs(item.at.z - stream.center.z) > radius or (self.hasSent(index, item.at) and !self.needsRefresh(index, item.at))) continue;
                if (stream.delivered == 0 and !std.meta.eql(item.at, stream.center)) continue;
                if (!self.sameDisclosure(index, item.owner, item.at)) continue;
                targets[count.*] = handle;
                count.* += 1;
                owner_found = owner_found or index == item.owner;
            }
            assert(owner_found);
            assert(count.* != 0);
        }
    }

    fn finishRefresh(self: *Streaming, item: *Pending, recipients: []const sessions.Handle) void {
        for (recipients) |handle| {
            assert(self.hasSent(handle.index, item.at));
            assert(self.missingSections(handle.index, item.at, item.visibility) == 0);
            assert(item.biome_disclosure & ~self.biome_disclosed[self.columnIndex(handle.index, item.at)] == 0);
            self.clearRefresh(handle.index, item.at);
            self.advanceCursor(handle.index);
        }
    }

    fn prepareLight(self: *Streaming, world: u32, at: Position, dimension: worlds.Worlds.Dimension, player: usize, selection: u32) !bool {
        const timing = self.lighting_duration.start();
        defer timing.end();
        const cpu = self.lighting_cpu.start();
        defer cpu.end();
        if (!try self.deps.lighting.background.prepareInputs(self.deps.chunks, world, at.x, at.z, dimension, player)) return false;
        try self.deps.lighting.lightPrepared(selection);
        return true;
    }

    fn blocksChanged(self: *Streaming, section: chunks.Section, edits: []const chunks.BlockEdit) void {
        const dimension = (self.deps.worlds.get(section.world) orelse return).dimension;
        if (section.y < dimension.minimumSection() or @as(i64, section.y) >= @as(i64, dimension.minimumSection()) + @as(i64, @intCast(dimension.sectionCount()))) return;
        const bounds = GeometryChange.boundsFor(section, edits) orelse return;
        self.published.mutex.lockUncancelable(self.native_io);
        self.published.geometry_revision += 1;
        if (self.published.geometry_changes.getPtr(section)) |previous| {
            for (0..3) |axis| {
                previous.minimum[axis] = @min(previous.minimum[axis], bounds.minimum[axis]);
                previous.maximum[axis] = @max(previous.maximum[axis], bounds.maximum[axis]);
            }
        } else if (self.published.geometry_changes.count() == geometry_change_capacity) {
            self.published.geometry_overflow = true;
        } else self.published.geometry_changes.putAssumeCapacityNoClobber(section, bounds);
        self.published.updated = true;
        self.published.mutex.unlock(self.native_io);
        const radius = self.deliveryRadius();
        var audience = self.deps.players.nearby(section.world, .{ .x = @as(f64, @floatFromInt(section.x)) * 16, .y = 0, .z = @as(f64, @floatFromInt(section.z)) * 16 }, radius + 1);
        while (audience.next()) |index| {
            const player = self.deps.players.records[index];
            if (player.handle == null or player.stage != .ready) continue;
            const center = View.capture(player).center;
            for (0..9) |column| {
                const x = std.math.add(i32, section.x, @as(i32, @intCast(column % 3)) - 1) catch continue;
                const z = std.math.add(i32, section.z, @as(i32, @intCast(column / 3)) - 1) catch continue;
                if (@abs(@as(i64, x) - center.x) > radius or @abs(@as(i64, z) - center.z) > radius) continue;
                const slot = self.sentIndex(index, .{ .x = x, .z = z });
                self.light_staged.mark(.{ .word = slot.word, .mask = slot.mask });
            }
        }
    }

    pub fn pollLight(self: *Streaming) !bool {
        const cpu = self.cpu.light_updates.start();
        defer cpu.end();
        if (self.deps.lighting.background.pending != null and self.pending) return false;
        if (self.epoch & 1 != 0 or self.epoch != self.deps.sessions.backgroundEpoch()) return false;
        if (self.light_pending.words.count == 0) return false;
        var output: [batch_max]sessions.Service.Packet = undefined;
        const reserved = self.deps.sessions.reserveMany(@min(lighting.Data.capacity, self.deps.sessions.config.page_bytes), &output) catch |err| switch (err) {
            error.Closed => return false,
            else => return err,
        };
        defer for (output[0..reserved]) |*packet| packet.cancel();
        var publications: [batch_max]sessions.Service.Publication = undefined;
        var admitted: [batch_max]usize = undefined;
        const Plan = struct { world: u32, at: Position, protocol: i32, occluded: u32, owner: usize, light: lighting.Receipt.Update };
        var plans: [batch_max]Plan = undefined;
        var planned: usize = 0;
        var attempts: usize = 0;
        var cursor: usize = 0;
        while (cursor < self.light_pending.words.count and attempts < reserved) {
            const word = self.light_pending.words.indices[cursor];
            const index = word / self.words_per_player;
            const view = self.views[index];
            const stream = self.streams[index];
            const bits = self.light_pending.bits[word];
            if (bits == 0 or view.handle == null or !view.ready or stream.generation != view.handle.?.generation or stream.life != view.life) {
                self.light_pending.bits[word] = 0;
                self.light_pending.words.remove(word);
                continue;
            }
            const bit = (word % self.words_per_player) * 64 + @ctz(bits);
            const side = self.deliveryRadius() * 2 + 1;
            const radius = self.deliveryRadius();
            const left = stream.center.x - radius;
            const top = stream.center.z - radius;
            const x = left + @mod(@as(i32, @intCast(bit % @as(usize, @intCast(side)))) - @mod(left, side), side);
            const z = top + @mod(@as(i32, @intCast(bit / @as(usize, @intCast(side)))) - @mod(top, side), side);
            const at: Position = .{ .x = x, .z = z };
            const slot = self.sentIndex(index, at);
            if (bit >= @as(usize, @intCast(side * side)) or !self.visibleView(index, view, view.world, x, z)) {
                self.light_pending.bits[word] &= ~(@as(u64, 1) << @intCast(bit % 64));
                continue;
            }
            if (!self.visibilityReady(index, at)) {
                cursor += 1;
                continue;
            }
            var duplicate = false;
            for (plans[0..planned]) |plan| duplicate = duplicate or (plan.world == view.world and plan.protocol == view.protocol and std.meta.eql(plan.at, at) and plan.occluded == self.occludedMask(index, at));
            if (duplicate) {
                cursor += 1;
                continue;
            }
            attempts += 1;
            var count: usize = 0;
            const recipients = self.recipients[planned * self.views.len ..][0..self.views.len];
            var nearby = self.visibleObservers(self.views, view.world, x, z);
            while (nearby.next()) |recipient| {
                if (self.views[recipient].protocol != view.protocol or self.occludedMask(recipient, at) != self.occludedMask(index, at)) continue;
                if (!self.visibilityReady(recipient, at)) continue;
                const other = self.sentIndex(recipient, at);
                if (self.light_pending.bits[other.word] & other.mask == 0) continue;
                recipients[count] = self.views[recipient].handle.?;
                count += 1;
            }
            assert(count != 0 and self.light_pending.bits[slot.word] & slot.mask != 0);
            const dimension = self.deps.worlds.get(view.world).?.dimension;
            if (planned != 0 and !self.deps.lighting.background.current(self.deps.chunks, view.world, x, z, dimension)) break;
            const lit = try self.prepareLight(view.world, at, dimension, index, ~self.occludedMask(index, at));
            if (self.deps.sessions.backgroundEpoch() != self.epoch) break;
            if (!lit) {
                cursor += 1;
                continue;
            }
            const packet = &output[planned];
            packet.epoch = self.epoch;
            var light = self.deps.lighting.background.data();
            light.disclosure = ~self.occludedMask(index, at);
            light.selection = (light.disclosure << 1 | 1 | (@as(u32, 1) << @intCast(light.count - 1))) & ((@as(u32, 1) << @intCast(light.count)) - 1);
            const update = self.retainLight(at, recipients[0..count], &light);
            const bytes = try self.deps.packets.writePacket(lighting.writeUpdate, view.protocol, packet.bytes, .{ x, z, light });
            publications[planned] = .{ .packet = packet, .length = bytes.len, .recipients = recipients[0..count] };
            plans[planned] = .{ .world = view.world, .at = at, .protocol = view.protocol, .occluded = self.occludedMask(index, at), .owner = index, .light = update };
            planned += 1;
            cursor += 1;
        }
        self.deps.sessions.publishManyReady(publications[0..planned], admitted[0..planned]);
        var progressed = false;
        for (plans[0..planned], publications[0..planned], admitted[0..planned]) |plan, publication, count| {
            for (publication.recipients[0..count]) |handle| {
                const other = self.sentIndex(handle.index, plan.at);
                self.light_pending.bits[other.word] &= ~other.mask;
                self.light_receipts[self.columnIndex(handle.index, plan.at)].apply(plan.light);
            }
            progressed = progressed or count != 0;
        }
        self.deps.sessions.flush();
        if (progressed) self.changed.set(self.io);
        return progressed;
    }

    fn publishVisibility(self: *Streaming) void {
        const cpu = self.cpu.visibility_publication.start();
        defer cpu.end();
        const published = self.published;
        published.mutex.lockUncancelable(self.native_io);
        defer published.mutex.unlock(self.native_io);
        var position: usize = 0;
        while (position < self.background_players.count) {
            const index = self.background_players.indices[position];
            if (self.views[index].handle == null) {
                self.streams[index] = .{};
                @memset(self.sent[index * self.words_per_player ..][0..self.words_per_player], 0);
                self.dirty_words.setRangeValue(.{ .start = index * self.words_per_player, .end = (index + 1) * self.words_per_player }, true);
                self.background_players.remove(index);
                self.occupied_players.remove(index);
            } else position += 1;
            const view = self.views[index];
            const current = &self.streams[index];
            // Collision terrain gates placement. A horizon-wide visibility solve does not.
            if (self.placementReady(index)) {
                current.prepared_teleport = view.teleport_id;
            }
            const stream = self.streams[index];
            published.setStream(index, stream);
        }
        var dirty = self.dirty_words.iterator(.{});
        while (dirty.next()) |word| {
            const range = columnRange(@intCast(self.deliveryRadius() * 2 + 1), self.words_per_player, word);
            @memcpy(published.occluded[range.begin..][0..range.count], self.occluded[range.begin..][0..range.count]);
            published.sent[word] = self.sent[word];
            published.dirty_words.set(word);
            self.dirty_words.unset(word);
        }
        self.publishDebug();
    }

    fn publishDebug(self: *const Streaming) void {
        for (self.debug_slots) |*slot| {
            if (!slot.requested) continue;
            const handle = slot.handle orelse continue;
            if (handle.index >= self.views.len) continue;
            const view = self.views[handle.index];
            const stream = self.streams[handle.index];
            if (!std.meta.eql(view.handle, handle) or view.world != slot.world or view.life != slot.life or
                stream.generation != handle.generation or stream.life != view.life) continue;
            const source = &self.sources[handle.index];
            const snapshot = &slot.snapshot;
            const side: usize = @intCast(self.deliveryRadius() * 2 + 1);
            snapshot.* = .{
                .world = view.world,
                .life = view.life,
                .epoch = self.epoch,
                .revision = self.geometry_revision,
                .cell = .{ @divFloor(view.eye_min[0], 16), @divFloor(view.eye_max, 16), @divFloor(view.eye_min[2], 16) },
                .source = if (source.origin) |origin| origin.bounds() else null,
                .component = if (source.origin) |origin| origin.component else 0,
                .occlusion_active = self.canConceal(handle.index),
                .queued_columns = stream.delivered,
                .total_columns = side * side,
            };
            const middle_y = @divFloor(view.eye_min[1], 16);
            for (0..streaming_debug.Snapshot.capacity) |i| {
                const x = view.center.x + @as(i32, @intCast(i % 3)) - 1;
                const z = view.center.z + @as(i32, @intCast(i / 3 % 3)) - 1;
                const y = middle_y + @as(i32, @intCast(i / 9)) - 1;
                const offset = y - stream.minimum_section;
                if (offset < 0 or offset >= stream.section_count) continue;
                const at: Position = .{ .x = x, .z = z };
                const bit = @as(u32, 1) << @intCast(offset);
                const column = self.columnIndex(handle.index, at);
                const queued = stream.setup == .streaming and @abs(@as(i64, x) - stream.center.x) <= self.deliveryRadius() and
                    @abs(@as(i64, z) - stream.center.z) <= self.deliveryRadius() and self.hasSent(handle.index, at);
                snapshot.sections[snapshot.count] = .{
                    .bounds = .{ .minimum = .{ x * 16, y * 16, z * 16 }, .maximum = .{ x * 16 + 16, y * 16 + 16, z * 16 + 16 } },
                    .status = streaming_debug.Status.classify(queued, self.occluded[column] & bit == 0, self.disclosed[column] & bit != 0, self.needsRefresh(handle.index, at)),
                };
                snapshot.count += 1;
            }
            slot.ready = true;
            slot.requested = false;
        }
    }

    pub const Visibility = struct {
        reset: lightning_rod.system.IndexSet,
        changed: []u64,
        changed_words: lightning_rod.system.IndexSet,
        streams: []Stream,
        sent: []u64,
        occluded: []u32,
        words_per_player: usize,
        side: i32,
        radius: i32,

        fn capture(self: *Visibility, published: *Published, io: std.Io) void {
            published.mutex.lockUncancelable(io);
            defer published.mutex.unlock(io);
            self.reset.clear();
            self.changed_words.clear();
            for (published.dirty_streams.values()) |player| {
                const stream = published.streams[player];
                const destination = &self.streams[player];
                if (stream.generation != destination.generation or stream.life != destination.life or stream.setup != destination.setup or !std.meta.eql(stream.center, destination.center)) self.reset.insert(player);
                destination.* = stream;
            }
            var dirty = published.dirty_words.iterator(.{});
            while (dirty.next()) |word| {
                var changed = self.sent[word] ^ published.sent[word];
                const range = columnRange(@intCast(self.side), self.words_per_player, word);
                for (self.occluded[range.begin..][0..range.count], published.occluded[range.begin..][0..range.count], 0..) |*old, current, bit| {
                    if (old.* != current) changed |= @as(u64, 1) << @intCast(bit);
                    old.* = current;
                }
                if (changed != 0) {
                    self.changed[word] = changed;
                    self.changed_words.insert(@intCast(word));
                }
                self.sent[word] = published.sent[word];
                published.dirty_words.unset(word);
            }
            published.dirty_streams.clear();
        }

        pub fn viewCenter(self: *const Visibility, player: usize) Position {
            return self.streams[player].center;
        }

        pub fn sectionVisible(self: *const Visibility, player: usize, record: *const players.Players.Player, section: chunks.Section) bool {
            if (!self.visible(player, record, section.world, section.x, section.z)) return false;
            const offset = std.math.clamp(section.y - self.streams[player].minimum_section, 0, @as(i32, @intCast(self.streams[player].section_count)) - 1);
            const side: usize = @intCast(self.side);
            const slot = player * side * side + @as(usize, @intCast(@mod(section.z, self.side) * self.side + @mod(section.x, self.side)));
            return self.occluded[slot] & (@as(u32, 1) << @intCast(offset)) == 0;
        }

        pub fn blockVisible(self: *const Visibility, player: usize, record: *const players.Players.Player, world: u32, point: [3]i32) bool {
            return self.sectionVisible(player, record, .{ .world = world, .x = @divFloor(point[0], 16), .y = @divFloor(point[1], 16), .z = @divFloor(point[2], 16) });
        }

        pub fn boundsVisible(self: *const Visibility, player: usize, record: *const players.Players.Player, world: u32, bounds: geometry_bounds.Box) bool {
            bounds.validate();
            const stream = self.streams[player];
            var z = @max(@divFloor(bounds.minimum[2], 16), stream.center.z - self.radius);
            while (z <= @min(@divFloor(bounds.maximum[2] - 1, 16), stream.center.z + self.radius)) : (z += 1) {
                var x = @max(@divFloor(bounds.minimum[0], 16), stream.center.x - self.radius);
                while (x <= @min(@divFloor(bounds.maximum[0] - 1, 16), stream.center.x + self.radius)) : (x += 1) {
                    var y = std.math.clamp(@divFloor(bounds.minimum[1], 16), stream.minimum_section, stream.minimum_section + @as(i32, @intCast(stream.section_count)) - 1);
                    const end = std.math.clamp(@divFloor(bounds.maximum[1] - 1, 16), stream.minimum_section, stream.minimum_section + @as(i32, @intCast(stream.section_count)) - 1);
                    while (y <= end) : (y += 1) {
                        if (self.sectionVisible(player, record, .{ .world = world, .x = x, .y = y, .z = z })) return true;
                    }
                }
            }
            return false;
        }

        pub fn visible(self: *const Visibility, player: usize, record: *const players.Players.Player, world: u32, x: i32, z: i32) bool {
            const stream = self.streams[player];
            if (record.world != world) return false;

            const handle = record.handle orelse return false;
            const radius: u64 = @intCast(self.radius);
            const slot = sentIndexFor(self.words_per_player, self.side, player, .{ .x = x, .z = z });
            return stream.generation == handle.generation and stream.life == record.life and stream.setup != .terrain and
                @abs(@as(i64, x) - stream.center.x) <= radius and @abs(@as(i64, z) - stream.center.z) <= radius and
                self.sent[slot.word] & slot.mask != 0;
        }
    };

    /// Every consumer borrows the same visibility snapshot until the next simulation tick.
    pub fn snapshotVisibility(self: *Streaming) *const Visibility {
        return &self.visibility;
    }

    pub fn deliveryRadius(self: *const Streaming) i32 {
        return self.deps.players.config.render_distance + @as(i32, self.config.prefetch);
    }

    fn updateAudience(self: *Streaming, index: usize) void {
        const view = self.views[index];
        const stream = self.streams[index];
        const handle = view.handle orelse {
            self.observers_index.update(index, null);
            return;
        };
        const center = if (stream.generation == handle.generation and stream.life == view.life) stream.center else view.center;
        self.observers_index.update(index, .{ .world = view.world, .x = center.x, .z = center.z });
    }

    pub const Observers = struct {
        owner: *const Streaming,
        views: []const View,
        query: SpatialIndex.Query,
        world: u32,
        at: Position,

        pub fn next(self: *Observers) ?usize {
            while (self.query.next()) |index| {
                if (self.owner.visibleView(index, self.views[index], self.world, self.at.x, self.at.z)) return index;
            }
            return null;
        }
    };

    /// Borrows a background snapshot and delivered chunk membership until either changes.
    pub fn visibleObservers(self: *const Streaming, views: []const View, world: u32, x: i32, z: i32) Observers {
        assert(views.len == self.views.len);
        return .{ .owner = self, .views = views, .world = world, .at = .{ .x = x, .z = z }, .query = self.observers_index.query(.{ .world = world, .x = x, .z = z }, self.deliveryRadius()) };
    }

    pub fn visibleView(self: *const Streaming, index: usize, view: View, world: u32, x: i32, z: i32) bool {
        const handle = view.handle orelse return false;
        const stream = self.streams[index];
        const radius: u64 = @intCast(self.deliveryRadius());
        return view.world == world and stream.generation == handle.generation and stream.life == view.life and
            stream.setup != .terrain and @abs(@as(i64, x) - stream.center.x) <= radius and
            @abs(@as(i64, z) - stream.center.z) <= radius and self.hasSent(index, .{ .x = x, .z = z });
    }

    const SentIndex = struct { word: usize, mask: u64 };

    fn sentIndexFor(words: usize, side: i32, index: usize, at: Position) SentIndex {
        const slot: usize = @intCast(@mod(at.z, side) * side + @mod(at.x, side));
        return .{ .word = index * words + slot / 64, .mask = @as(u64, 1) << @intCast(slot % 64) };
    }

    fn sentIndex(self: *const Streaming, index: usize, at: Position) SentIndex {
        return sentIndexFor(self.words_per_player, self.deliveryRadius() * 2 + 1, index, at);
    }

    fn hasSent(self: *const Streaming, index: usize, at: Position) bool {
        const slot = self.sentIndex(index, at);
        return self.sent[slot.word] & slot.mask != 0;
    }

    fn columnIndex(self: *const Streaming, index: usize, at: Position) usize {
        const side = self.deliveryRadius() * 2 + 1;
        return index * @as(usize, @intCast(side * side)) + @as(usize, @intCast(@mod(at.z, side) * side + @mod(at.x, side)));
    }

    fn occludedMask(self: *const Streaming, index: usize, at: Position) u32 {
        return if (self.hasSent(index, at)) self.occluded[self.columnIndex(index, at)] else std.math.maxInt(u32);
    }

    fn missingSections(self: *const Streaming, index: usize, at: Position, desired: u32) u32 {
        const slot = self.columnIndex(index, at);
        return desired & (~self.disclosed[slot] | self.stale[slot]) & ((@as(u32, 1) << @intCast(self.streams[index].section_count)) - 1);
    }

    fn retainLight(self: *const Streaming, at: Position, recipients: []const sessions.Handle, data: *lighting.Data) lighting.Receipt.Update {
        assert(recipients.len != 0 and data.retained[0] == 0 and data.retained[1] == 0);
        var retained: [2]u32 = @splat(std.math.maxInt(u32));
        for (recipients) |handle| {
            const known = self.light_receipts[self.columnIndex(handle.index, at)].retained(data.*);
            for (&retained, known) |*bits, previous| bits.* &= previous;
        }
        data.retained = retained;
        return lighting.Receipt.Update.capture(data.*);
    }

    fn canReuseColumn(self: *const Streaming, index: usize, at: Position, blocks_mask: u32, biomes_mask: u32) bool {
        return self.hasSent(index, at) and self.missingSections(index, at, blocks_mask) == 0 and
            biomes_mask & ~self.biome_disclosed[self.columnIndex(index, at)] == 0;
    }

    fn hideSections(self: *Streaming, index: usize, at: Position, hidden: u32) void {
        assert(self.hasSent(index, at));
        assert(self.streams[index].section_count > 0 and self.streams[index].section_count <= 24);
        const slot = self.columnIndex(index, at);
        const mask = (@as(u32, 1) << @intCast(self.streams[index].section_count)) - 1;
        const value = self.occluded[slot] | (hidden & mask);
        if (self.occluded[slot] == value) return;
        self.occluded[slot] = value;
        self.dirty_words.set(self.sentIndex(index, at).word);
    }

    fn restoreSections(self: *Streaming, index: usize, at: Position, visible: u32) void {
        assert(self.hasSent(index, at));
        const slot = self.columnIndex(index, at);
        const known = visible & self.disclosed[slot] & ~self.stale[slot];
        const restored = self.occluded[slot] & known;
        if (restored == 0) return;
        self.occluded[slot] &= ~restored;
        self.dirty_words.set(self.sentIndex(index, at).word);
        assert(self.occluded[slot] & known == 0);
    }

    fn needsRefresh(self: *const Streaming, index: usize, at: Position) bool {
        const slot = self.sentIndex(index, at);
        return self.refresh_bits[slot.word] & slot.mask != 0;
    }

    fn clearRefresh(self: *Streaming, index: usize, at: Position) void {
        const slot = self.sentIndex(index, at);
        self.refresh_bits[slot.word] &= ~slot.mask;
    }

    fn updateView(self: *Streaming, index: usize, current: View) void {
        const previous = self.views[index];
        const same = previous.world == current.world and previous.life == current.life and std.meta.eql(previous.handle, current.handle);
        self.views[index] = current;
        if (previous.teleport_id != current.teleport_id) self.streams[index].prepared_teleport = 0;
        const source = &self.sources[index];
        if (!same) source.biome = null;
        if (!same) source.direction = .{ 0, 0 } else if (!std.meta.eql(current.center, previous.center)) {
            source.direction = .{ current.center.x - previous.center.x, current.center.z - previous.center.z };
        }
        if (!self.config.occlusion) return;
        if (!current.occlusion) {
            if (previous.occlusion) self.refresh(index, false);
            return;
        }
        const point: [3]i32 = .{ current.eye_min[0], current.eye_max, current.eye_min[2] };
        const reusable = same and if (source.origin) |origin| origin.supports(current.world, point) else false;
        if (!reusable or previous.occlusion != current.occlusion) self.refresh(index, !reusable);
    }

    fn constantMask(self: *const Streaming, index: usize, column: section_visibility_world.Column, count: usize) u32 {
        const slot = self.columnIndex(index, .{ .x = column.x, .z = column.z });
        return self.geometry.skyAir(column, count) & ~self.stale[slot];
    }

    fn sectionMask(self: *const Streaming, index: usize, column: section_visibility_world.Column, count: usize) u32 {
        assert(self.canConcealColumn(index, .{ .x = column.x, .z = column.z }));
        assert(column.world == self.views[index].world);
        const mask = self.geometry.mask(self.columnQuery(index, .{ .x = column.x, .z = column.z }).?, column.x, column.z);
        assert(mask & ~((@as(u32, 1) << @intCast(count)) - 1) == 0);
        return mask;
    }

    fn canConceal(self: *const Streaming, index: usize) bool {
        if (!self.config.occlusion or !self.sources[index].known) return false;
        const query = self.sources[index].query orelse return false;
        return self.views[index].occlusion and self.geometry.ready(query);
    }

    fn canConcealColumn(self: *const Streaming, index: usize, at: Position) bool {
        return self.columnQuery(index, at) != null;
    }

    fn columnQuery(self: *const Streaming, index: usize, at: Position) ?section_visibility_world.Handle {
        if (!self.config.occlusion or !self.sources[index].known or !self.views[index].occlusion) return null;
        if (self.sources[index].near_query) |near| if (!self.geometry.ready(near)) return null;
        const query = self.sources[index].query orelse return null;
        if (self.geometry.readyColumn(query, at.x, at.z)) return query;
        if (self.sources[index].near_query) |near| if (self.geometry.readyColumn(near, at.x, at.z)) return near;
        return null;
    }

    fn deliveryReady(self: *const Streaming, index: usize, at: Position) bool {
        const query = self.columnQuery(index, at) orelse return false;
        const center = self.views[index].center;
        const radius = self.deliveryRadius();
        return self.geometry.readyColumns(query, .{ @max(at.x - 1, center.x - radius), @max(at.z - 1, center.z - radius) }, .{ @min(at.x + 1, center.x + radius), @min(at.z + 1, center.z + radius) });
    }

    fn disclosureMasks(self: *const Streaming, index: usize, column: section_visibility_world.Column, count: usize) DisclosureMasks {
        const occupied = self.collisionMask(index, column, count);
        if (!self.config.occlusion or !self.views[index].occlusion) {
            const all = self.unrestrictedMask(index, count);
            return .{ .visibility = all, .disclosure = all };
        }
        if (!self.canConcealColumn(index, .{ .x = column.x, .z = column.z })) return .{ .visibility = occupied, .disclosure = occupied };
        const visible = self.sectionMask(index, column, count) | occupied;
        return .{ .visibility = visible, .disclosure = visible | self.constantMask(index, column, count) };
    }

    fn occupiedColumn(self: *const Streaming, index: usize) ?DeliveryColumn {
        const view = self.views[index];
        const stream = self.streams[index];
        const handle = view.handle orelse return null;
        if (!view.ready or stream.setup != .streaming or stream.generation != handle.generation) return null;
        for (0..9) |offset| {
            const relative = spiral(offset);
            const column: DeliveryColumn = .{ .world = view.world, .at = .{ .x = view.center.x + relative.x, .z = view.center.z + relative.z } };
            if (stream.delivered == 0 and !std.meta.eql(column.at, stream.center)) continue;
            const occupied = self.collisionMask(index, .{ .world = column.world, .x = column.at.x, .z = column.at.z, .minimum = stream.minimum_section }, stream.section_count);
            if (occupied == 0) continue;
            if (!self.hasSent(index, column.at) or self.missingSections(index, column.at, occupied) != 0 or self.occludedMask(index, column.at) & occupied != 0) return column;
        }
        return null;
    }

    fn canDeliverColumn(self: *const Streaming, index: usize, column: DeliveryColumn) bool {
        const view = self.views[index];
        const handle = view.handle orelse return false;
        const stream = self.streams[index];
        if (!view.ready or view.world != column.world or stream.setup != .streaming or stream.generation != handle.generation) return false;
        const ready = self.deliveryReady(index, column.at);
        if (self.needsSource(index) and !ready) {
            const occupied = self.collisionMask(index, .{ .world = column.world, .x = column.at.x, .z = column.at.z, .minimum = stream.minimum_section }, stream.section_count);
            if (occupied == 0 or (self.hasSent(index, column.at) and self.missingSections(index, column.at, occupied) == 0 and self.occludedMask(index, column.at) & occupied == 0)) return false;
        }
        // A concealed first column has no permitted biome for padding its hidden sections.
        if (stream.delivered == 0 and !std.meta.eql(column.at, stream.center)) return false;
        const radius = self.deliveryRadius();
        if (@abs(@as(i64, column.at.x) - stream.center.x) > radius or @abs(@as(i64, column.at.z) - stream.center.z) > radius) return false;
        if (self.hasSent(index, column.at)) {
            if (!self.needsRefresh(index, column.at)) return false;
            if (self.canConcealColumn(index, column.at)) {
                const location: section_visibility_world.Column = .{ .world = column.world, .x = column.at.x, .z = column.at.z, .minimum = stream.minimum_section };
                const mask = self.sectionMask(index, location, stream.section_count);
                if (self.canReuseColumn(index, column.at, mask | self.constantMask(index, location, stream.section_count), mask)) return true;
            }
        }
        const estimate = if (stream.packet_bytes == 0) self.deps.sessions.config.page_bytes else stream.packet_bytes;
        return self.deps.sessions.packetCapacity(handle, estimate) != 0;
    }

    fn unrestrictedMask(self: *const Streaming, index: usize, count: usize) u32 {
        assert(!self.config.occlusion or !self.views[index].occlusion);
        return (@as(u32, 1) << @intCast(count)) - 1;
    }

    fn collisionMask(self: *const Streaming, index: usize, column: section_visibility_world.Column, count: usize) u32 {
        const view = self.views[index];
        assert(count > 0 and count <= lighting.maximum_sections);
        assert(column.world == view.world and view.eye_max >= view.eye_min[1]);
        for ([_]usize{ 0, 2 }, [_]i32{ column.x, column.z }) |axis, coordinate| {
            if (@divFloor(view.eye_min[axis] - 1, 16) > coordinate or @divFloor(view.eye_min[axis] + 1, 16) < coordinate) return 0;
        }
        const lower = std.math.clamp(@divFloor(view.eye_min[1] - 1, 16) - column.minimum, 0, @as(i32, @intCast(count)) - 1);
        const upper = std.math.clamp(@divFloor(view.eye_max, 16) - column.minimum, 0, @as(i32, @intCast(count)) - 1);
        return ((@as(u32, 1) << @intCast(upper + 1)) - 1) & ~((@as(u32, 1) << @intCast(lower)) - 1);
    }

    fn sameDisclosure(self: *const Streaming, a: usize, b: usize, at: Position) bool {
        if (a == b) return true;
        const stream = self.streams[a];
        assert(self.views[a].world == self.views[b].world);
        assert(stream.minimum_section == self.streams[b].minimum_section and stream.section_count == self.streams[b].section_count);
        const column: section_visibility_world.Column = .{ .world = self.views[a].world, .x = at.x, .z = at.z, .minimum = stream.minimum_section };
        if (!std.meta.eql(self.disclosureMasks(a, column, stream.section_count), self.disclosureMasks(b, column, stream.section_count))) return false;
        const left = self.columnIndex(a, at);
        const right = self.columnIndex(b, at);
        return self.stale[left] == self.stale[right] and self.disclosed[left] == self.disclosed[right] and
            self.biome_disclosed[left] == self.biome_disclosed[right];
    }

    fn disclosedBiome(sections: []const lighting.Section, disclosed: u32) ?u16 {
        for (sections, 0..) |section, y| {
            if (disclosed & (@as(u32, 1) << @intCast(y)) == 0) continue;
            if (section.biomes) |biomes| return biomes[0];
        }
        return null;
    }

    fn biomeMasks(self: *const Streaming, index: usize, at: Position, center_mask: u32, available: *const [9]u32) [9]u32 {
        var masks: [9]u32 = @splat(0);
        masks[4] = center_mask & available[4];
        if (!self.config.occlusion) return masks;
        const radius = self.deliveryRadius();
        const center = self.streams[index].center;
        assert(@abs(@as(i64, at.x) - center.x) <= radius and @abs(@as(i64, at.z) - center.z) <= radius);
        for (0..9) |column| {
            if (column == 4 or available[column] == 0) continue;
            const neighbor: Position = .{ .x = at.x + @as(i32, @intCast(column % 3)) - 1, .z = at.z + @as(i32, @intCast(column / 3)) - 1 };
            if (@abs(@as(i64, neighbor.x) - center.x) > radius or @abs(@as(i64, neighbor.z) - center.z) > radius) continue;
            if (!self.hasSent(index, neighbor)) continue;
            const slot = self.columnIndex(index, neighbor);
            masks[column] = self.biome_disclosed[slot] & ~self.stale[slot] & available[column];
        }
        return masks;
    }

    fn coverBiome(self: *Streaming, index: usize, disclosed: ?u16) !i32 {
        const source = &self.sources[index];
        if (disclosed) |biome| {
            source.biome = biome;
            return biome;
        }
        return source.biome orelse self.config.fallback_biome orelse error.MissingBiomeData;
    }

    pub fn visibilityReady(self: *const Streaming, index: usize, at: Position) bool {
        return self.hasSent(index, at) and
            self.stale[self.columnIndex(index, at)] & ~self.occludedMask(index, at) == 0;
    }

    pub fn sectionMaskForChanges(self: *Streaming, index: usize, section: chunks.Section, output: *[64]u64) bool {
        const at: Position = .{ .x = section.x, .z = section.z };
        if (!self.visibilityReady(index, at)) return false;
        @memset(output, if (self.sectionVisible(index, section)) std.math.maxInt(u64) else 0);
        return true;
    }

    fn needsSource(self: *const Streaming, index: usize) bool {
        return self.config.occlusion and self.views[index].occlusion and !self.canConceal(index);
    }

    fn learnSections(self: *Streaming, positions: []const chunks.Section, player: usize) !bool {
        assert(positions.len <= section_visibility_world.World.batch_max);
        const capacity = @min(section_visibility_world.World.batch_max, self.deps.chunks.backgroundCapacity());
        assert(capacity > 0);
        var groups: [section_visibility_world.World.batch_max]chunks.Chunks.StorageGroup = undefined;
        var keys: [section_visibility_world.World.batch_max][16]u8 = undefined;
        var requested: [section_visibility_world.World.batch_max]u64 = @splat(0);
        var buckets: [512]?u8 = @splat(null);
        var group_count: usize = 0;
        for (positions) |position| {
            const group = self.deps.chunks.storageGroup(position);
            const key = chunks.encodeKey(group.minimum);
            var bucket: usize = @intCast(std.hash.Wyhash.hash(0, &key) & (buckets.len - 1));
            while (buckets[bucket]) |index| {
                if (std.mem.eql(u8, &keys[index], &key)) break;
                bucket = (bucket + 1) & (buckets.len - 1);
            }
            const index = buckets[bucket] orelse add: {
                const index: u8 = @intCast(group_count);
                buckets[bucket] = index;
                keys[index] = key;
                groups[index] = group;
                group_count += 1;
                break :add index;
            };
            const part: u6 = @intCast(((position.x - group.minimum.x) * group.side + position.z - group.minimum.z) * group.side + position.y - group.minimum.y);
            requested[index] |= @as(u64, 1) << part;
        }
        var batch: [section_visibility_world.World.batch_max]chunks.Section = undefined;
        const reads = self.classification_requests;
        var count: usize = 0;
        var learned = false;
        const view = self.views[player];
        const dimension = self.deps.worlds.get(view.world).?.dimension;
        for (groups[0..group_count], requested[0..group_count]) |group, wanted| {
            assert(group.minimum.world == view.world);
            for (0..group.side) |x| for (0..group.side) |z| {
                const cx = group.minimum.x + @as(i32, @intCast(x));
                const cz = group.minimum.z + @as(i32, @intCast(z));
                const inside = @abs(@as(i64, cx) - view.center.x) <= self.deliveryRadius() and @abs(@as(i64, cz) - view.center.z) <= self.deliveryRadius();
                for (0..group.side) |y| {
                    const required = wanted & (@as(u64, 1) << @intCast((x * group.side + z) * group.side + y)) != 0;
                    if (!inside and !required) continue;
                    const section: chunks.Section = .{ .world = view.world, .x = cx, .y = group.minimum.y + @as(i32, @intCast(y)), .z = cz };
                    if (section.y < dimension.minimumSection() or section.y >= dimension.minimumSection() + @as(i32, @intCast(dimension.sectionCount()))) continue;
                    if (self.geometry.known(section, dimension.minimumSection(), dimension.sectionCount())) continue;
                    reads[count] = .{ .section = section, .result = &self.classifications[count], .mode = if (required) .complete else .homogeneous };
                    count += 1;
                    if (count == reads.len) {
                        learned = try self.learnClassifications(reads[0..count], player) or learned;
                        count = 0;
                    }
                }
            };
        }
        if (count != 0) learned = try self.learnClassifications(reads[0..count], player) or learned;
        count = 0;
        for (positions) |section| {
            if (self.geometry.known(section, dimension.minimumSection(), dimension.sectionCount())) continue;
            batch[count] = section;
            count += 1;
        }
        var begin: usize = 0;
        while (begin < count) {
            const end = begin + @min(count - begin, capacity);
            learned = try self.learnPrepared(batch[begin..end], player) or learned;
            begin = end;
        }
        return learned;
    }

    fn learnClassifications(self: *Streaming, reads: []const chunks.Chunks.ClassificationRequest, player: usize) !bool {
        assert(reads.len <= section_visibility_world.World.batch_max);
        try self.deps.chunks.classify(reads, self.geometry.properties, section_visibility_world.occluder_property);
        const dimension = self.deps.worlds.get(self.views[player].world).?.dimension;
        var learned = false;
        for (reads) |read| {
            const position = read.section;
            learned = self.geometry.learnClassification(.{ .world = position.world, .x = position.x, .z = position.z, .minimum = dimension.minimumSection() }, dimension.sectionCount(), @intCast(position.y - dimension.minimumSection()), read.result) or learned;
        }
        return learned;
    }

    fn learnPrepared(self: *Streaming, positions: []const chunks.Section, player: usize) !bool {
        assert(positions.len > 0 and positions.len <= self.deps.chunks.backgroundCapacity() and positions.len <= section_visibility_world.World.batch_max);
        var leases: [section_visibility_world.World.batch_max]chunks.Lease = undefined;
        var requests: [section_visibility_world.World.batch_max]chunks.Chunks.Preparation = undefined;
        var ready: [section_visibility_world.World.batch_max]bool = undefined;
        for (positions, 0..) |_, index| requests[index] = .{ .sections = positions[index..][0..1], .leases = leases[index..][0..1], .priority = .{ .urgency = .occupied, .player = player } };
        try self.deps.chunks.prepareMany(requests[0..positions.len], ready[0..positions.len]);
        defer for (leases[0..positions.len], ready[0..positions.len]) |lease, complete| if (complete) lease.release();
        var learned = false;
        for (positions, leases[0..positions.len], ready[0..positions.len]) |position, lease, complete| {
            if (!complete) continue;
            const dimension = self.deps.worlds.get(position.world).?.dimension;
            const view = lease.view();
            self.geometry.learnSection(.{ .world = position.world, .x = position.x, .z = position.z, .minimum = dimension.minimumSection() }, dimension.sectionCount(), @intCast(position.y - dimension.minimumSection()), if (view == .uniform) .{ .uniform = view.uniform } else .{ .chunk = view });
            learned = true;
        }
        return learned;
    }

    fn prepareSources(self: *Streaming) !void {
        const cpu = self.cpu.sources.start();
        defer cpu.end();
        if (!self.config.occlusion) return;
        self.geometry.beginPoll();
        var progressed = false;
        for (self.background_players.values()) |index| {
            const view = self.views[index];
            if (view.handle == null or !view.ready or !view.occlusion) continue;
            const source = &self.sources[index];
            const dimension = self.deps.worlds.get(view.world).?.dimension;
            if (source.origin == null) {
                const point: [3]i32 = .{ view.eye_min[0], view.eye_max, view.eye_min[2] };
                var required: [27]chunks.Section = undefined;
                const requirements = section_visibility_world.World.sourceRequirements(view.world, dimension.minimumSection(), dimension.sectionCount(), point, &required);
                var missing: [27]chunks.Section = undefined;
                var count: usize = 0;
                for (requirements) |position| {
                    if (self.geometry.known(position, dimension.minimumSection(), dimension.sectionCount())) continue;
                    missing[count] = position;
                    count += 1;
                }
                if (count != 0) progressed = try self.learnSections(missing[0..count], index) or progressed;
                source.origin = self.geometry.source(view.world, dimension.minimumSection(), dimension.sectionCount(), point, &self.origins[index]);
                source.query = null;
                source.near_query = null;
                source.revision = 0;
                source.near_revision = 0;
                source.quadrants = 0;
            }
            if (source.origin) |origin| {
                if (self.deliveryRadius() > near_radius) {
                    const retained = if (source.near_query) |query| self.geometry.retain(query) else false;
                    if (!retained) {
                        source.near_query = self.geometry.query(origin, dimension.minimumSection(), dimension.sectionCount(), near_radius);
                        source.near_revision = 0;
                        self.refresh(index, false);
                    }
                }
                const retained = if (source.query) |query| self.geometry.retain(query) else false;
                if (!retained) {
                    source.query = self.geometry.query(origin, dimension.minimumSection(), dimension.sectionCount(), self.deliveryRadius());
                    source.revision = 0;
                    source.quadrants = 0;
                    self.geometry.prioritize(source.query.?, source.direction);
                    self.refresh(index, false);
                }
            }
            source.known = source.origin != null and if (source.query) |handle| self.geometry.valid(handle) else false;
        }
        const before = self.geometry.visits;
        while (true) {
            const advanced = advance: {
                const traversal = self.cpu.visibility.start();
                defer traversal.end();
                break :advance self.geometry.advance();
            };
            progressed = progressed or advanced.progressed;
            const missing = advanced.requests;
            if (missing.len == 0) break;
            const query = self.geometry.activeQuery().?;
            const owner = for (self.background_players.values()) |index| {
                if (self.views[index].handle == null or !self.views[index].ready or !self.views[index].occlusion or self.sources[index].origin == null) continue;
                if (std.meta.eql(self.sources[index].query, query) or std.meta.eql(self.sources[index].near_query, query)) break index;
            } else unreachable;
            const builds = self.geometry.builds;
            const unchanged = self.geometry.unchanged;
            const learned = try self.learnSections(missing, owner);
            progressed = progressed or learned;
            if (!learned or self.geometry.activeQuery() == null or self.deps.sessions.backgroundEpoch() != self.epoch) break;
            assert(self.geometry.builds > builds or self.geometry.unchanged > unchanged);
        }
        progressed = progressed or before != self.geometry.visits;
        for (self.background_players.values()) |index| {
            const source = &self.sources[index];
            const query = source.query orelse continue;
            source.known = source.origin != null and self.geometry.valid(query);
            if (!source.known) {
                self.pending = true;
                continue;
            }
            const complete = self.geometry.ready(query);
            const octants = self.geometry.completedOctants(query);
            // A column needs both vertical octants of every horizontal quadrant that reaches it.
            const quadrants = octants & (octants >> 2) & 0x33;
            const revision = if (complete) self.geometry.revision(query) else source.revision;
            const near_revision = if (source.near_query) |near| if (self.geometry.ready(near)) self.geometry.revision(near) else 0 else 0;
            if (source.quadrants != quadrants or source.revision != revision or source.near_revision != near_revision) {
                const invalidated = (source.quadrants != 0 and quadrants == 0) or (source.near_revision != 0 and near_revision == 0);
                source.quadrants = quadrants;
                source.revision = revision;
                source.near_revision = near_revision;
                if (invalidated) self.refresh(index, false) else self.refreshReady(index);
                progressed = true;
            }
            self.pending = self.pending or !complete;
        }
        if (progressed) self.changed.set(self.io);
    }

    fn advanceCursor(self: *Streaming, index: usize) void {
        const stream = &self.streams[index];
        const side: usize = @intCast(self.deliveryRadius() * 2 + 1);
        assert(stream.cursor <= side * side);
        while (stream.cursor < side * side) {
            const offset = spiral(stream.cursor);
            const at: Position = .{ .x = stream.center.x + offset.x, .z = stream.center.z + offset.z };
            if (!self.hasSent(index, at) or self.needsRefresh(index, at)) {
                if (!self.sources[index].known or !self.needsSource(index)) return;
                const ready = self.deliveryReady(index, at);
                if (ready) return;
                const location: section_visibility_world.Column = .{ .world = self.views[index].world, .x = at.x, .z = at.z, .minimum = stream.minimum_section };
                const occupied = self.collisionMask(index, location, stream.section_count);
                if (occupied != 0 and (!self.hasSent(index, at) or self.missingSections(index, at, occupied) != 0 or self.occludedMask(index, at) & occupied != 0)) return;
            }
            stream.cursor += 1;
        }
    }

    fn refresh(self: *Streaming, index: usize, source_changed: bool) void {
        if (source_changed) {
            self.sources[index].known = false;
            self.sources[index].origin = null;
            self.pending = true;
            return;
        }
        const begin = index * self.words_per_player;
        // Queue reclassification without replacing the last completed visibility result.
        for (self.refresh_bits[begin..][0..self.words_per_player], self.sent[begin..][0..self.words_per_player]) |*bits, sent| bits.* |= sent;
        self.refreshReady(index);
    }

    fn refreshReady(self: *Streaming, index: usize) void {
        self.streams[index].cursor = 0;
        if (self.sources[index].known) {
            const stream = self.streams[index];
            const radius = self.deliveryRadius();
            const side: usize = @intCast(2 * radius + 1);
            var reused: usize = 0;
            for (0..side * side) |column_index| {
                const at: Position = .{
                    .x = stream.center.x - radius + @as(i32, @intCast(column_index % side)),
                    .z = stream.center.z - radius + @as(i32, @intCast(column_index / side)),
                };
                if (!self.hasSent(index, at) or !self.needsRefresh(index, at)) continue;
                if (!self.canConcealColumn(index, at)) continue;
                const column: section_visibility_world.Column = .{ .world = self.views[index].world, .x = at.x, .z = at.z, .minimum = stream.minimum_section };
                const masks = self.disclosureMasks(index, column, stream.section_count);
                self.hideSections(index, at, ~masks.visibility);
                self.restoreSections(index, at, masks.visibility);
                if (!self.canReuseColumn(index, at, masks.disclosure, masks.visibility)) continue;
                self.clearRefresh(index, at);
                reused += 1;
            }
            self.deliveries.reused.add(reused);
            self.advanceCursor(index);
        }
        self.pending = true;
    }

    pub fn invalidateSection(self: *Streaming, index: usize, section: chunks.Section) void {
        const at: Position = .{ .x = section.x, .z = section.z };
        if (!self.hasSent(index, at)) return;
        const stream = self.streams[index];
        const offset = section.y - stream.minimum_section;
        assert(offset >= 0 and offset < stream.section_count);
        self.stale[self.columnIndex(index, at)] |= @as(u32, 1) << @intCast(offset);
    }

    pub fn sectionVisible(self: *const Streaming, index: usize, section: chunks.Section) bool {
        const dimension = self.deps.worlds.get(section.world) orelse return false;
        const offset = section.y - dimension.dimension.minimumSection();
        if (offset < 0 or offset >= dimension.dimension.sectionCount()) return false;
        return self.occludedMask(index, .{ .x = section.x, .z = section.z }) & (@as(u32, 1) << @intCast(offset)) == 0;
    }

    fn markSent(self: *Streaming, index: usize, at: Position, value: bool) void {
        const slot = self.sentIndex(index, at);
        if (!value) {
            self.light_receipts[self.columnIndex(index, at)] = .{};
            self.biome_disclosed[self.columnIndex(index, at)] = 0;
            self.occluded[self.columnIndex(index, at)] = std.math.maxInt(u32);
            self.stale[self.columnIndex(index, at)] = 0;
            self.disclosed[self.columnIndex(index, at)] = 0;
            self.clearRefresh(index, at);
        }
        self.sent[slot.word] = (self.sent[slot.word] & ~slot.mask) | (slot.mask * @intFromBool(value));
        self.dirty_words.set(slot.word);
    }

    fn writeUnload(packet: wire_1_21_5.play.toClient.packet_unload_chunk.Writer, at: Position) ![]u8 {
        return (try (try packet.chunkZ(at.z)).chunkX(at.x)).finish();
    }

    fn writeTerrainReady(packet: wire_1_21_5.play.toClient.packet_game_state_change.Writer) ![]u8 {
        return (try (try packet.reason(13)).gameMode(0)).finish();
    }

    fn writeViewCenter(packet: wire_1_21_5.play.toClient.packet_update_view_position.Writer, at: Position) ![]u8 {
        return (try (try packet.chunkX(at.x)).chunkZ(at.z)).finish();
    }
};

fn columnRange(side: usize, words: usize, word: usize) struct { begin: usize, count: usize } {
    assert(words == (side * side + 63) / 64);
    const offset = (word % words) * 64;
    assert(offset < side * side);
    return .{ .begin = word / words * side * side + offset, .count = @min(64, side * side - offset) };
}

fn departingPosition(center: Streaming.Position, target: Streaming.Position, radius: i32, cursor: usize) ?Streaming.Position {
    assert(radius >= 0);
    const side = radius * 2 + 1;
    const low: Streaming.Position = .{ .x = center.x - radius, .z = center.z - radius };
    const high: Streaming.Position = .{ .x = center.x + radius, .z = center.z + radius };
    const overlap_low: Streaming.Position = .{ .x = @max(low.x, target.x - radius), .z = @max(low.z, target.z - radius) };
    const overlap_high: Streaming.Position = .{ .x = @min(high.x, target.x + radius), .z = @min(high.z, target.z + radius) };
    const Rectangle = struct { x: i32, z: i32, width: i32, height: i32 };
    if (overlap_low.x > overlap_high.x or overlap_low.z > overlap_high.z) {
        const width: usize = @intCast(side);
        if (cursor >= width * width) return null;
        return .{ .x = low.x + @as(i32, @intCast(cursor % width)), .z = low.z + @as(i32, @intCast(cursor / width)) };
    }
    const rectangles = [_]Rectangle{
        .{ .x = low.x, .z = low.z, .width = side, .height = overlap_low.z - low.z },
        .{ .x = low.x, .z = overlap_low.z, .width = overlap_low.x - low.x, .height = overlap_high.z - overlap_low.z + 1 },
        .{ .x = overlap_high.x + 1, .z = overlap_low.z, .width = high.x - overlap_high.x, .height = overlap_high.z - overlap_low.z + 1 },
        .{ .x = low.x, .z = overlap_high.z + 1, .width = side, .height = high.z - overlap_high.z },
    };
    var remaining = cursor;
    for (rectangles) |rectangle| {
        const count: usize = @intCast(rectangle.width * rectangle.height);
        if (remaining < count) {
            const width: usize = @intCast(rectangle.width);
            return .{ .x = rectangle.x + @as(i32, @intCast(remaining % width)), .z = rectangle.z + @as(i32, @intCast(remaining / width)) };
        }
        remaining -= count;
    }
    return null;
}

test "visibility metadata batches respect background capacity and release leases before the next batch" {
    const Generator = struct {
        generated: usize = 0,
        fn read(self: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests) |*request| {
                self.generated += 1;
                request.result = chunks.uniform(game_data.registry.block_stone_default_state, request.output);
            }
        }
    };
    const io = std.testing.io;
    for ([_]usize{ 24, 168 }) |capacity| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/visibility", .{temporary.sub_path});
        var store = try storage.Store.init(allocator, io, .{ .path = path });
        defer store.deinit();
        var registry = try metrics.Registry.init(allocator, io, .{ .enabled = false });
        defer registry.deinit();
        const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = capacity + 24, .demand_sections = 24 }, .{
            .metrics = &registry,
            .storage = try store.openSpace(chunks.Chunks.id),
            .record_workspaces = try persistent_records.Workspaces.init(allocator, io, .{}),
        });
        terrain.attach();
        defer terrain.stop();
        const catalog = try worlds.Worlds.allocate(allocator, .{ .maximum = 1 });
        const world = try catalog.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 24 } });
        var streaming: Streaming = undefined;
        streaming.deps.chunks = terrain;
        streaming.deps.worlds = catalog;
        var player_records = [_]players.Players.Player{.{ .world = world }};
        var player_plugin: players.Players = .{ .deps = undefined, .config = .{ .render_distance = 1 }, .spawn_world = world, .records = &player_records, .dig_handlers = &.{} };
        streaming.deps.players = &player_plugin;
        var views = [_]Streaming.View{.{ .handle = null, .world = world, .protocol = 0, .life = 0, .ready = false, .center = .{ .x = 0, .z = 0 } }};
        streaming.views = &views;
        streaming.config = .{ .prefetch = 0 };
        streaming.classifications = try allocator.alloc(chunks.encoding.Classification, section_visibility_world.World.batch_max);
        streaming.classification_requests = try allocator.alloc(chunks.Chunks.ClassificationRequest, section_visibility_world.World.batch_max);
        streaming.geometry = try .init(allocator, .{ .columns = 9, .sources = 1, .radius = 1 });
        var positions: [section_visibility_world.World.batch_max]chunks.Section = undefined;
        for (&positions, 0..) |*position, index| position.* = .{ .world = world, .x = @as(i32, @intCast(index / 24 % 3)) - 1, .y = @intCast(index % 24), .z = @as(i32, @intCast(index / 72)) - 1 };
        try std.testing.expect(try streaming.learnSections(&positions, 0));
        try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
        try std.testing.expectEqual(@as(usize, 0), terrain.cache.pinned_entries);
        for (positions) |position| try std.testing.expect(streaming.geometry.known(position, 0, 24));

        streaming.geometry.invalidate();
        var generator: Generator = .{};
        terrain.stop();
        terrain.setSource(chunks.Source.init(&generator, Generator.read));
        terrain.attach();
        var attempts: usize = 0;
        while (true) : (attempts += 1) {
            try std.testing.expect(attempts < positions.len * 2);
            var missing: [positions.len]chunks.Section = undefined;
            var count: usize = 0;
            for (positions) |position| {
                if (streaming.geometry.known(position, 0, 24)) continue;
                missing[count] = position;
                count += 1;
            }
            if (count == 0) break;
            _ = try streaming.learnSections(missing[0..count], 0);
            try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
            try std.testing.expect(terrain.cache.pinned_entries <= capacity);
            while (try terrain.generation.processOne(io)) {}
        }
        try std.testing.expectEqual(positions.len, generator.generated);
        try std.testing.expectEqual(@as(usize, 0), terrain.cache.pinned_entries);
        for (positions) |position| try std.testing.expect(streaming.geometry.stoneMask(.{ .world = world, .x = position.x, .z = position.z, .minimum = 0 }, 24) & (@as(u32, 1) << @intCast(position.y)) != 0);
    }
}

test "geometry edit bounds retain individual blocks and span batched edits in negative sections" {
    const section: chunks.Section = .{ .world = 3, .x = -2, .y = -4, .z = 1 };
    try std.testing.expectEqual(geometry_bounds.Box{ .minimum = .{ -29, -62, 20 }, .maximum = .{ -28, -61, 21 } }, Streaming.GeometryChange.boundsFor(section, &.{.{ .index = 2 * 256 + 4 * 16 + 3, .state = 0 }}).?);
    try std.testing.expectEqual(geometry_bounds.Box{ .minimum = .{ -32, -64, 16 }, .maximum = .{ -16, -48, 32 } }, Streaming.GeometryChange.boundsFor(section, &.{ .{ .index = 0, .state = 0 }, .{ .index = 4095, .state = 1 } }).?);
    try std.testing.expect(Streaming.GeometryChange.boundsFor(.{ .world = 0, .x = std.math.maxInt(i32), .y = 0, .z = std.math.minInt(i32) }, &.{.{ .index = 0, .state = 1 }}) == null);
}

test "column order visits every coordinate once in nondecreasing distance rings" {
    const radius = 35;
    const side = radius * 2 + 1;
    var visited: [side * side]bool = @splat(false);
    var previous: u32 = 0;
    for (0..visited.len) |index| {
        const at = spiral(index);
        const distance = @max(@abs(at.x), @abs(at.z));
        try std.testing.expect(distance >= previous and distance <= radius);
        previous = distance;
        const slot: usize = @intCast((at.z + radius) * side + at.x + radius);
        try std.testing.expect(!visited[slot]);
        visited[slot] = true;
    }
    for (visited) |present| try std.testing.expect(present);
}

fn spiral(index: usize) struct {
    x: i32,
    z: i32,
} {
    if (index == 0) return .{ .x = 0, .z = 0 };

    const ring: i32 = @intCast((std.math.sqrt(index) + 1) / 2);
    const side = ring * 2;
    const start: usize = @intCast((side - 1) * (side - 1));
    const offset: i32 = @intCast(index - start);
    return switch (@divTrunc(offset, side)) {
        0 => .{ .x = ring, .z = -ring + 1 + offset },
        1 => .{ .x = ring - 1 - (offset - side), .z = ring },
        2 => .{ .x = -ring, .z = ring - 1 - (offset - 2 * side) },
        3 => .{ .x = -ring + 1 + (offset - 3 * side), .z = -ring },
        else => unreachable,
    };
}

test "light receipts advance only for admitted recipients and reset on column unload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var subjects: players.Players = .{ .deps = undefined, .config = .{ .render_distance = 1 }, .spawn_world = 0, .records = &.{}, .dig_handlers = &.{} };
    var receipts: [18]lighting.Receipt = @splat(.{});
    var sent: [2]u64 = @splat(1);
    var refresh: [2]u64 = @splat(0);
    var masks: [4][18]u32 = @splat(@splat(0));
    var streaming: Streaming = undefined;
    streaming.deps.players = &subjects;
    streaming.config = .{};
    streaming.light_receipts = &receipts;
    streaming.sent = &sent;
    streaming.refresh_bits = &refresh;
    streaming.biome_disclosed = &masks[0];
    streaming.occluded = &masks[1];
    streaming.stale = &masks[2];
    streaming.disclosed = &masks[3];
    streaming.words_per_player = 1;
    streaming.dirty_words = try .initEmpty(arena.allocator(), 2);
    const at: Streaming.Position = .{ .x = 0, .z = 0 };
    const recipients = [_]sessions.Handle{ .{ .index = 0, .generation = 1 }, .{ .index = 1, .generation = 1 } };
    const view: chunks.Light.View = .{ .header = .{ .rules = @splat(1), .minimum = 0, .count = 1, .skylight = true, .coverage = 1, .revisions = @splat(0), .biomes = @splat(0) }, .masks = .{ 2, 7 } };
    const original: lighting.Data = .{ .source = .{ .stored = &view }, .count = 3, .masks = .{ 2, 7 }, .disclosure = 1 };
    var data = original;
    const update = streaming.retainLight(at, &recipients, &data);
    receipts[streaming.columnIndex(0, at)].apply(update);
    data = original;
    _ = streaming.retainLight(at, &recipients, &data);
    try std.testing.expectEqual([2]u32{ 0, 0 }, data.retained);
    data = original;
    _ = streaming.retainLight(at, recipients[0..1], &data);
    try std.testing.expectEqual([2]u32{ 7, 7 }, data.retained);
    receipts[streaming.columnIndex(1, at)].apply(update);
    data = original;
    _ = streaming.retainLight(at, &recipients, &data);
    try std.testing.expectEqual([2]u32{ 7, 7 }, data.retained);
    streaming.markSent(0, at, false);
    try std.testing.expectEqual([2]u32{ 0, 0 }, receipts[streaming.columnIndex(0, at)].retained(original));
    try std.testing.expectEqual([2]u32{ 7, 7 }, receipts[streaming.columnIndex(1, at)].retained(original));
}

test "debug snapshots copy actual disclosure and reject reused connection identities" {
    var subjects: players.Players = .{ .deps = undefined, .config = .{ .render_distance = 1 }, .spawn_world = 0, .records = &.{}, .dig_handlers = &.{} };
    const handle: sessions.Handle = .{ .index = 0, .generation = 7 };
    var views = [_]Streaming.View{.{ .handle = handle, .world = 3, .protocol = 772, .life = 2, .ready = true, .center = .{ .x = 0, .z = 0 }, .eye_min = .{ 0, 16, 0 } }};
    var streams = [_]Streaming.Stream{.{ .generation = 7, .life = 2, .setup = .streaming, .minimum_section = 0, .section_count = 3, .delivered = 9 }};
    var sources: [1]Streaming.Source = @splat(.{});
    var sent = [_]u64{511};
    var occluded: [9]u32 = @splat(7);
    var disclosed: [9]u32 = @splat(0);
    var refresh = [_]u64{0};
    var slots = [_]streaming_debug.Slot{.{ .handle = handle, .world = 3, .life = 2, .requested = true }};
    var streaming: Streaming = undefined;
    streaming.config = .{ .occlusion = false };
    streaming.deps = .{ .metrics = undefined, .players = &subjects, .chunks = undefined, .sessions = undefined, .packets = undefined, .worlds = undefined, .lighting = undefined };
    streaming.views = &views;
    streaming.streams = &streams;
    streaming.sources = &sources;
    streaming.sent = &sent;
    streaming.occluded = &occluded;
    streaming.disclosed = &disclosed;
    streaming.refresh_bits = &refresh;
    streaming.words_per_player = 1;
    streaming.debug_slots = &slots;
    streaming.geometry_revision = 42;
    streaming.epoch = 10;
    disclosed[0] = 2;
    streaming.publishDebug();
    try std.testing.expect(slots[0].ready and !slots[0].requested);
    try std.testing.expectEqual(@as(u64, 42), slots[0].snapshot.revision);
    try std.testing.expectEqual(@as(usize, 27), slots[0].snapshot.count);
    try std.testing.expectEqual(streaming_debug.Status.retained, slots[0].snapshot.sections[13].status);
    occluded[0] = 5;
    try std.testing.expectEqual(streaming_debug.Status.retained, slots[0].snapshot.sections[13].status);
    slots[0].requested = true;
    streaming.publishDebug();
    try std.testing.expectEqual(streaming_debug.Status.visible, slots[0].snapshot.sections[13].status);
    slots[0] = .{ .handle = .{ .index = 0, .generation = 8 }, .world = 3, .life = 2, .requested = true };
    streaming.publishDebug();
    try std.testing.expect(!slots[0].ready);
    slots[0] = .{ .handle = handle, .world = 4, .life = 2, .requested = true };
    streaming.publishDebug();
    try std.testing.expect(!slots[0].ready);
    slots[0] = .{ .handle = handle, .world = 3, .life = 3, .requested = true };
    streaming.publishDebug();
    try std.testing.expect(!slots[0].ready);
}

test "cover biomes come from disclosed world data and never from hidden biome arrays" {
    var sources: [1]Streaming.Source = @splat(.{});
    var streaming: Streaming = undefined;
    streaming.config = .{};
    streaming.sources = &sources;
    const secret: [64]u16 = @splat(37);
    const exposed: [64]u16 = @splat(12);
    const sections = [_]lighting.Section{
        .{ .stamp = .{}, .view = .{ .uniform = 0 }, .biomes = &secret },
        .{ .stamp = .{}, .view = .{ .uniform = 0 }, .biomes = &exposed },
    };
    try std.testing.expect(Streaming.disclosedBiome(&sections, 0) == null);
    try std.testing.expectEqual(@as(?u16, 12), Streaming.disclosedBiome(&sections, 2));
    try std.testing.expectError(error.MissingBiomeData, streaming.coverBiome(0, null));
    streaming.config.fallback_biome = 4;
    try std.testing.expectEqual(@as(i32, 4), try streaming.coverBiome(0, null));
    try std.testing.expect(sources[0].biome == null);
    try std.testing.expectEqual(@as(i32, 12), try streaming.coverBiome(0, Streaming.disclosedBiome(&sections, 2)));
    streaming.config.fallback_biome = null;
    try std.testing.expectEqual(@as(i32, 12), try streaming.coverBiome(0, null));
    try std.testing.expect(sources[0].biome.? != secret[0]);
}

test "biome padding checks only adjacent disclosed columns and excludes stale or wrapped entries" {
    const columns = 25;
    var subjects: players.Players = .{ .deps = undefined, .config = .{ .render_distance = 2 }, .spawn_world = 0, .records = &.{}, .dig_handlers = &.{} };
    var streams: [2]Streaming.Stream = @splat(.{ .center = .{ .x = -17, .z = 91 } });
    var masks: [columns * 2]u32 = @splat(0);
    var stale: [columns * 2]u32 = @splat(0);
    var sent: [2]u64 = @splat(0);
    var streaming: Streaming = undefined;
    streaming.config = .{};
    streaming.deps.players = &subjects;
    streaming.streams = &streams;
    streaming.biome_disclosed = &masks;
    streaming.stale = &stale;
    streaming.sent = &sent;
    streaming.words_per_player = 1;
    const center: Streaming.Position = .{ .x = -17, .z = 91 };
    const available: [9]u32 = @splat(7);
    for ([_]Streaming.Position{ .{ .x = -16, .z = 91 }, .{ .x = -18, .z = 92 }, .{ .x = -15, .z = 91 } }, [_]u32{ 1, 2, 7 }) |at, mask| {
        masks[streaming.columnIndex(0, at)] = mask;
        const slot = streaming.sentIndex(0, at);
        sent[slot.word] |= slot.mask;
    }
    const expected: [9]u32 = .{ 0, 0, 0, 0, 4, 1, 2, 0, 0 };
    try std.testing.expectEqual(expected, streaming.biomeMasks(0, center, 4, &available));
    try std.testing.expectEqual([_]u32{ 0, 0, 0, 0, 4, 0, 0, 0, 0 }, streaming.biomeMasks(1, center, 4, &available));
    const east: Streaming.Position = .{ .x = -16, .z = 91 };
    stale[streaming.columnIndex(0, east)] = 1;
    try std.testing.expectEqual(@as(u32, 0), streaming.biomeMasks(0, center, 4, &available)[5]);
    stale[streaming.columnIndex(0, east)] = 0;
    sent[0] &= ~streaming.sentIndex(0, east).mask;
    try std.testing.expectEqual(@as(u32, 0), streaming.biomeMasks(0, center, 4, &available)[5]);
    try std.testing.expectEqual(@as(u32, 0), streaming.biomeMasks(0, .{ .x = -15, .z = 91 }, 4, &available)[5]);
}

test "opaque observers receive their collision sections without exposing distant sections" {
    var views = [_]Streaming.View{.{ .handle = .{ .index = 0, .generation = 1 }, .world = 0, .protocol = 772, .life = 1, .ready = true, .center = .{ .x = 1, .z = 1 }, .eye_min = .{ 20, -8, 20 }, .eye_max = -7 }};
    var streaming: Streaming = undefined;
    streaming.views = &views;
    const column: section_visibility_world.Column = .{ .world = 0, .x = 1, .z = 1, .minimum = -4 };
    try std.testing.expectEqual(@as(u32, 1 << 3), streaming.collisionMask(0, column, 24));
    try std.testing.expectEqual(@as(u32, 0), streaming.collisionMask(0, .{ .world = 0, .x = 2, .z = 1, .minimum = -4 }, 24));
    views[0].eye_min = .{ 0, 16, 0 };
    views[0].eye_max = 17;
    for ([_]i32{ -1, 0 }) |x| for ([_]i32{ -1, 0 }) |z| {
        try std.testing.expectEqual(@as(u32, 3 << 4), streaming.collisionMask(0, .{ .world = 0, .x = x, .z = z, .minimum = -4 }, 24));
    };
}

test "occupied terrain bypasses occlusion readiness and follows vertical movement" {
    var subjects: players.Players = .{ .deps = undefined, .config = .{ .render_distance = 1 }, .spawn_world = 0, .records = &.{}, .dig_handlers = &.{} };
    var views = [_]Streaming.View{.{ .handle = .{ .index = 0, .generation = 1 }, .world = 0, .protocol = 772, .life = 0, .ready = true, .center = .{ .x = 0, .z = 0 }, .eye_min = .{ 8, 65, 8 }, .eye_max = 66 }};
    var streams = [_]Streaming.Stream{.{ .generation = 1, .setup = .streaming, .delivered = 1 }};
    var sources: [1]Streaming.Source = @splat(.{});
    var sent = [_]u64{1};
    var disclosed: [9]u32 = @splat(0);
    var occluded: [9]u32 = @splat(std.math.maxInt(u32));
    var stale: [9]u32 = @splat(0);
    var streaming: Streaming = undefined;
    streaming.config = .{};
    streaming.deps.players = &subjects;
    streaming.views = &views;
    streaming.streams = &streams;
    streaming.sources = &sources;
    streaming.sent = &sent;
    streaming.disclosed = &disclosed;
    streaming.occluded = &occluded;
    streaming.stale = &stale;
    streaming.words_per_player = 1;
    const column: section_visibility_world.Column = .{ .world = 0, .x = 0, .z = 0, .minimum = -4 };
    try std.testing.expect(streaming.needsSource(0));
    try std.testing.expect(!streaming.placementReady(0));
    try std.testing.expectEqual(@as(u32, 1 << 8), streaming.disclosureMasks(0, column, 24).disclosure);
    try std.testing.expectEqual(Streaming.DeliveryColumn{ .world = 0, .at = .{ .x = 0, .z = 0 } }, streaming.occupiedColumn(0).?);
    disclosed[0] = 1 << 8;
    try std.testing.expect(streaming.occupiedColumn(0) != null);
    occluded[0] &= ~@as(u32, 1 << 8);
    try std.testing.expect(streaming.occupiedColumn(0) == null);
    try std.testing.expect(streaming.needsSource(0));
    try std.testing.expect(streaming.placementReady(0));
    views[0].eye_min[1] = 80;
    views[0].eye_max = 81;
    try std.testing.expectEqual(@as(u32, 3 << 8), streaming.disclosureMasks(0, column, 24).disclosure);
    try std.testing.expect(streaming.occupiedColumn(0) != null);
    disclosed[0] = 3 << 8;
    occluded[0] &= ~@as(u32, 3 << 8);
    try std.testing.expect(streaming.occupiedColumn(0) == null);
    stale[0] = 1 << 8;
    try std.testing.expect(streaming.occupiedColumn(0) != null);
    try std.testing.expect(!streaming.placementReady(0));
}

test "teleports wait for the matching destination terrain without waiting for confirmation" {
    var streams = [_]Streaming.Stream{.{ .generation = 7, .life = 3 }};
    var streaming: Streaming = undefined;
    streaming.visibility.streams = &streams;
    var player: players.Players.Player = .{
        .handle = .{ .index = 0, .generation = 7 },
        .life = 3,
        .teleport_id = 12,
        .stage = .teleport,
    };
    try std.testing.expect(Streaming.View.capture(player).ready);
    try std.testing.expect(!streaming.teleportReady(&player));
    streams[0].prepared_teleport = 11;
    try std.testing.expect(!streaming.teleportReady(&player));
    streams[0].prepared_teleport = 12;
    try std.testing.expect(streaming.teleportReady(&player));
    player.life += 1;
    try std.testing.expect(!streaming.teleportReady(&player));
    player.life -= 1;
    player.handle.?.generation += 1;
    try std.testing.expect(!streaming.teleportReady(&player));
    player.stage = .respawn;
    try std.testing.expect(!Streaming.View.capture(player).ready);
    player.stage = .awaiting_teleport;
    try std.testing.expect(Streaming.View.capture(player).ready);
    player.configuring = true;
    try std.testing.expect(!Streaming.View.capture(player).ready);
}

test "chunk audiences respect source readiness retained state and initial center delivery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const columns = 9;
    var records: [2]players.Players.Player = @splat(.{});
    var subjects: players.Players = .{ .deps = undefined, .config = .{ .maximum = 2, .render_distance = 1 }, .spawn_world = 0, .records = &records, .dig_handlers = &.{} };
    var streams: [2]Streaming.Stream = @splat(.{ .generation = 1, .setup = .streaming, .delivered = columns });
    var sources = [_]Streaming.Source{ .{}, .{ .known = true, .query = .{ .index = 1, .generation = 1 } } };
    var views: [2]Streaming.View = undefined;
    for (&views, 0..) |*view, index| view.* = .{ .handle = .{ .index = index, .generation = 1 }, .world = 0, .protocol = 772, .life = 0, .ready = true, .center = .{ .x = 0, .z = 0 } };
    var occluded: [columns * 2]u32 = @splat(1);
    var stale: [columns * 2]u32 = @splat(0);
    var disclosed: [columns * 2]u32 = @splat(0);
    var biome_disclosed: [columns * 2]u32 = @splat(0);
    var refresh = [_]u64{ (1 << columns) - 1, (1 << columns) - 1 };
    var sent = refresh;
    var recipients: [Streaming.batch_max * 2]sessions.Handle = undefined;
    var streaming: Streaming = undefined;
    streaming.config = .{};
    streaming.deps = .{ .metrics = undefined, .players = &subjects, .chunks = undefined, .sessions = undefined, .packets = undefined, .worlds = undefined, .lighting = undefined };
    streaming.streams = &streams;
    streaming.sources = &sources;
    streaming.views = &views;
    streaming.occluded = &occluded;
    streaming.stale = &stale;
    streaming.disclosed = &disclosed;
    streaming.biome_disclosed = &biome_disclosed;
    streaming.refresh_bits = &refresh;
    streaming.sent = &sent;
    streaming.recipients = &recipients;
    streaming.words_per_player = 1;
    streaming.geometry = try .init(arena.allocator(), .{ .columns = 9, .sources = 3, .radius = 1 });
    const origin: section_visibility_world.Source = .{ .section = .{ .world = 0, .x = 0, .y = 0, .z = 0 }, .component = 0, .point = .{ 0, 0, 0 }, .camera_bounds = .{ .minimum = .{ 0, 0, 0 }, .maximum = .{ 16, 16, 16 } } };
    sources[1].query = streaming.geometry.query(&origin, -4, 24, 1);
    streaming.geometry.queries[sources[1].query.?.index].ready = true;
    @memset(streaming.geometry.queries[sources[1].query.?.index].masks, 1 << 4);
    streaming.observers_index = try SpatialIndex.init(std.testing.allocator, views.len);
    defer streaming.observers_index.deinit(std.testing.allocator);
    for (0..views.len) |index| streaming.updateAudience(index);
    const pending = [_]Streaming.Pending{
        .{ .at = .{ .x = 0, .z = 0 }, .world = 0, .protocol = 772, .owner = 0 },
        .{ .at = .{ .x = 1, .z = 0 }, .world = 0, .protocol = 772, .owner = 0 },
        .{ .at = .{ .x = 1, .z = 0 }, .world = 0, .protocol = 772, .owner = 1 },
    };
    var counts: [pending.len]usize = undefined;
    streaming.planRecipients(&pending, &counts);
    try std.testing.expectEqualSlices(usize, &.{ 2, 1, 1 }, &counts);
    sources[0] = sources[1];
    try std.testing.expect(streaming.canConceal(0) and streaming.canConceal(1));
    var regrouped: [Streaming.batch_max * 2]sessions.Handle = undefined;
    var merged_counts: [2]usize = undefined;
    streaming.recipients = &regrouped;
    streaming.planRecipients(pending[1..], &merged_counts);
    try std.testing.expectEqualSlices(usize, &.{ 2, 2 }, &merged_counts);
    streaming.recipients = &recipients;
    for (pending, counts, 0..) |item, count, i| {
        const targets = recipients[i * views.len ..][0..count];
        try std.testing.expectEqual(item.owner, targets[0].index);
        for (targets) |handle| {
            try std.testing.expect(streaming.needsRefresh(handle.index, item.at));
            streaming.clearRefresh(handle.index, item.at);
        }
    }
    refresh[0] |= 2;
    refresh[1] |= 2;
    const delivery = [_]Streaming.Pending{.{ .at = .{ .x = 1, .z = 0 }, .world = 0, .protocol = 772, .owner = 0 }};
    var delivery_counts: [1]usize = undefined;
    streaming.planRecipients(&delivery, &delivery_counts);
    try std.testing.expectEqual(@as(usize, 2), delivery_counts[0]);
    biome_disclosed[streaming.columnIndex(1, delivery[0].at)] = 1;
    streaming.planRecipients(&delivery, &delivery_counts);
    try std.testing.expectEqual(@as(usize, 1), delivery_counts[0]);
    biome_disclosed[streaming.columnIndex(1, delivery[0].at)] = 0;
    sources[1].known = false;
    streaming.planRecipients(&delivery, &delivery_counts);
    try std.testing.expectEqual(@as(usize, 1), delivery_counts[0]);
    sources[1].known = true;
    streams[1].delivered = 0;
    sent[1] = 0;
    streaming.planRecipients(&delivery, &delivery_counts);
    try std.testing.expectEqual(@as(usize, 1), delivery_counts[0]);
    const initial = [_]Streaming.Pending{.{ .at = streams[1].center, .world = 0, .protocol = 772, .owner = 0 }};
    refresh[0] |= 1;
    streaming.planRecipients(&initial, &delivery_counts);
    try std.testing.expectEqual(@as(usize, 2), delivery_counts[0]);
    streams[1].delivered = 1;
    sent[1] = 1;
    streaming.planRecipients(&delivery, &delivery_counts);
    try std.testing.expectEqual(@as(usize, 2), delivery_counts[0]);
}

test "independent sources share only matching column disclosure and retained state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var records: [2]players.Players.Player = @splat(.{});
    var subjects: players.Players = .{ .deps = undefined, .config = .{ .maximum = 2, .render_distance = 1 }, .spawn_world = 0, .records = &records, .dig_handlers = &.{} };
    var streams: [2]Streaming.Stream = @splat(.{ .generation = 1, .setup = .streaming });
    var sources: [2]Streaming.Source = @splat(.{ .known = true });
    var views: [2]Streaming.View = undefined;
    for (&views, 0..) |*view, index| view.* = .{ .handle = .{ .index = index, .generation = 1 }, .world = 0, .protocol = 772, .life = 0, .ready = true, .center = .{ .x = @intCast(index), .z = 0 }, .eye_min = .{ @as(i32, @intCast(index)) * 16 + 1, 64, 1 }, .eye_max = 65 };
    var stale: [18]u32 = @splat(0);
    var disclosed: [18]u32 = @splat(0);
    var biomes: [18]u32 = @splat(0);
    var streaming: Streaming = undefined;
    streaming.config = .{};
    streaming.deps.players = &subjects;
    streaming.streams = &streams;
    streaming.sources = &sources;
    streaming.views = &views;
    streaming.stale = &stale;
    streaming.disclosed = &disclosed;
    streaming.biome_disclosed = &biomes;
    streaming.geometry = try .init(bounded.allocator(), .{ .columns = 9, .sources = 3, .radius = 1 });
    for (&sources, 0..) |*source, index| {
        const origin: section_visibility_world.Source = .{ .section = .{ .world = 0, .x = @intCast(index), .y = 4, .z = 0 }, .component = 0, .point = .{ @as(i32, @intCast(index)) * 16, 65, 0 }, .camera_bounds = .{ .minimum = .{ 0, 64, 0 }, .maximum = .{ 32, 80, 16 } } };
        source.query = streaming.geometry.query(&origin, -4, 24, 1);
        const query = &streaming.geometry.queries[source.query.?.index];
        query.ready = true;
        @memset(query.masks, 3 << 7);
    }
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    const at: Streaming.Position = .{ .x = 0, .z = 0 };
    try std.testing.expect(!std.meta.eql(sources[0].query, sources[1].query));
    try std.testing.expect(streaming.sameDisclosure(0, 1, at) and streaming.sameDisclosure(1, 0, at));
    const other = streaming.columnIndex(1, at);
    for ([_]*u32{ &stale[other], &disclosed[other], &biomes[other] }) |value| {
        value.* = 1;
        try std.testing.expect(!streaming.sameDisclosure(0, 1, at));
        value.* = 0;
    }
    const query = &streaming.geometry.queries[sources[1].query.?.index];
    query.masks[3] = 0;
    try std.testing.expect(streaming.canConceal(0) and streaming.canConceal(1));
    try std.testing.expectEqual(@as(u32, 3 << 7), streaming.geometry.mask(sources[0].query.?, 0, 0));
    try std.testing.expectEqual(@as(u32, 0), streaming.geometry.mask(sources[1].query.?, 0, 0));
    try std.testing.expect(!streaming.sameDisclosure(0, 1, at));
    query.masks[3] = 3 << 7;
    query.ready = false;
    try std.testing.expect(!streaming.sameDisclosure(0, 1, at));
    query.ready = true;
    for (sources) |source| @memset(streaming.geometry.queries[source.query.?.index].masks, 0);
    for (8..24) |section| streaming.geometry.learnSection(.{ .world = 0, .x = 0, .z = 0, .minimum = -4 }, 24, section, .{ .uniform = 0 });
    try std.testing.expect(streaming.constantMask(0, .{ .world = 0, .x = 0, .z = 0, .minimum = -4 }, 24) & (1 << 8) != 0);
    try std.testing.expect(!streaming.sameDisclosure(0, 1, at));
    try std.testing.expect(!bounded.has_induced_failure);
}

test "visibility restores unchanged delivered sections without authorizing stale or missing data" {
    var subjects: players.Players = .{ .deps = undefined, .config = .{ .render_distance = 1 }, .spawn_world = 0, .records = &.{}, .dig_handlers = &.{} };
    var sent = [_]u64{1};
    var occluded: [9]u32 = @splat(std.math.maxInt(u32));
    var disclosed: [9]u32 = @splat(0);
    var biome_disclosed: [9]u32 = @splat(0);
    var stale: [9]u32 = @splat(0);
    var refresh = [_]u64{0};
    var streams = [_]Streaming.Stream{.{ .section_count = 4 }};
    disclosed[0] = 7;
    stale[0] = 2;
    var streaming: Streaming = undefined;
    streaming.config = .{};
    streaming.deps = .{ .metrics = undefined, .players = &subjects, .chunks = undefined, .sessions = undefined, .packets = undefined, .worlds = undefined, .lighting = undefined };
    streaming.sent = &sent;
    streaming.occluded = &occluded;
    streaming.disclosed = &disclosed;
    streaming.biome_disclosed = &biome_disclosed;
    streaming.stale = &stale;
    streaming.refresh_bits = &refresh;
    streaming.streams = &streams;
    streaming.words_per_player = 1;
    streaming.dirty_words = try .initEmpty(std.testing.allocator, 1);
    defer streaming.dirty_words.deinit(std.testing.allocator);
    streaming.restoreSections(0, .{ .x = 0, .z = 0 }, 1);
    try std.testing.expectEqual(@as(u32, 1), ~occluded[0]);
    try std.testing.expectEqual(@as(u32, 10), streaming.missingSections(0, .{ .x = 0, .z = 0 }, 15));
    streaming.restoreSections(0, .{ .x = 0, .z = 0 }, 15);
    try std.testing.expectEqual(@as(u32, 5), ~occluded[0]);
    try std.testing.expect(!streaming.canReuseColumn(0, .{ .x = 0, .z = 0 }, 5, 5));
    biome_disclosed[0] = 5;
    try std.testing.expect(streaming.canReuseColumn(0, .{ .x = 0, .z = 0 }, 5, 5));
    try std.testing.expect(streaming.visibilityReady(0, .{ .x = 0, .z = 0 }));
    refresh[0] = 1;
    try std.testing.expect(streaming.visibilityReady(0, .{ .x = 0, .z = 0 }));
    stale[0] |= 1;
    try std.testing.expect(!streaming.visibilityReady(0, .{ .x = 0, .z = 0 }));
    stale[0] &= ~@as(u32, 1);
    refresh[0] = 0;
    try std.testing.expect(streaming.dirty_words.isSet(0));
    stale[0] = 0;
    streaming.restoreSections(0, .{ .x = 0, .z = 0 }, 15);
    try std.testing.expectEqual(@as(u32, 7), ~occluded[0]);
    try std.testing.expectEqual(@as(u32, 8), streaming.missingSections(0, .{ .x = 0, .z = 0 }, 15));
    sent[0] = 0;
    try std.testing.expect(!streaming.visibilityReady(0, .{ .x = 0, .z = 0 }));
}

test "leaving spectator schedules source preparation after fully disclosed terrain" {
    const count = 25;
    var records: [1]players.Players.Player = @splat(.{});
    var subjects: players.Players = .{ .deps = undefined, .config = .{ .maximum = 1, .render_distance = 2 }, .spawn_world = 0, .records = &records, .dig_handlers = &.{} };
    var streams: [1]Streaming.Stream = @splat(.{ .setup = .streaming, .cursor = count });
    var sources: [1]Streaming.Source = @splat(.{});
    var views = [_]Streaming.View{.{ .handle = null, .world = 0, .protocol = 0, .life = 0, .ready = true, .center = .{ .x = 0, .z = 0 }, .occlusion = false }};
    var occluded: [count]u32 = @splat(0);
    var refresh = [_]u64{0};
    var sent = [_]u64{(1 << count) - 1};
    var streaming: Streaming = undefined;
    streaming.config = .{};
    streaming.deps = .{ .metrics = undefined, .players = &subjects, .chunks = undefined, .sessions = undefined, .packets = undefined, .worlds = undefined, .lighting = undefined };
    streaming.streams = &streams;
    streaming.sources = &sources;
    streaming.views = &views;
    streaming.occluded = &occluded;
    streaming.refresh_bits = &refresh;
    streaming.sent = &sent;
    streaming.words_per_player = 1;
    streaming.pending = false;

    for (0..2) |movement| {
        var view = views[0];
        view.occlusion = false;
        streaming.updateView(0, view);
        view.eye_min[0] += @intCast(movement);
        streaming.updateView(0, view);
        // Spectator delivery can finish without preparing a source section.
        refresh[0] = 0;
        streams[0].cursor = count;
        streaming.pending = false;
        try std.testing.expect(!streaming.canConceal(0));
        view.occlusion = true;
        streaming.updateView(0, view);
        try std.testing.expect(!streaming.canConceal(0));
        try std.testing.expect(streaming.pending);
        try std.testing.expect(streaming.needsSource(0));
        try std.testing.expect(!streaming.needsRefresh(0, streams[0].center));
        try std.testing.expectEqual(@as(usize, count), streams[0].cursor);
        try std.testing.expectEqual(@as(u32, 0), streaming.occludedMask(0, streams[0].center));
        streaming.refresh(0, false);
        try std.testing.expect(streaming.needsRefresh(0, streams[0].center));
    }
}

test "completed visibility refreshes resolve known columns in one batch and retain stale work" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var registry = try metrics.Registry.init(allocator, std.testing.io, .{ .capacity = 1 });
    defer registry.deinit();
    const reused = try registry.counter(.{ .name = "test.reused", .description = "Retained columns reused" });
    var records = [_]players.Players.Player{.{}};
    var subjects: players.Players = .{ .deps = undefined, .config = .{ .maximum = 1, .render_distance = 1 }, .spawn_world = 0, .records = &records, .dig_handlers = &.{} };
    var streams = [_]Streaming.Stream{.{ .setup = .streaming, .delivered = 9, .section_count = 4, .minimum_section = 0 }};
    var sources: [1]Streaming.Source = @splat(.{});
    var views = [_]Streaming.View{.{ .handle = .{ .index = 0, .generation = 1 }, .world = 0, .protocol = 772, .life = 0, .ready = true, .center = .{ .x = 0, .z = 0 }, .eye_min = .{ 8, 24, 8 }, .eye_max = 25 }};
    var sent = [_]u64{511};
    var refresh = [_]u64{0};
    var disclosed: [9]u32 = @splat(15);
    var biomes: [9]u32 = @splat(15);
    var hidden: [9]u32 = @splat(15);
    var stale: [9]u32 = @splat(0);
    var streaming: Streaming = undefined;
    streaming.deps.players = &subjects;
    streaming.config = .{};
    streaming.streams = &streams;
    streaming.sources = &sources;
    streaming.views = &views;
    streaming.sent = &sent;
    streaming.refresh_bits = &refresh;
    streaming.disclosed = &disclosed;
    streaming.biome_disclosed = &biomes;
    streaming.occluded = &hidden;
    streaming.stale = &stale;
    streaming.words_per_player = 1;
    streaming.deliveries = .{ .reused = reused };
    streaming.dirty_words = try .initEmpty(allocator, 1);
    streaming.geometry = try .init(allocator, .{ .columns = 9, .sources = 1, .radius = 1 });
    const air: [4]lighting.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = 0 } });
    for (0..9) |index| streaming.geometry.learn(.{ .world = 0, .x = @as(i32, @intCast(index % 3)) - 1, .z = @as(i32, @intCast(index / 3)) - 1, .minimum = 0 }, &air);
    var origin_storage: section_visibility_world.Source = undefined;
    const origin = streaming.geometry.source(0, 0, 4, .{ 8, 25, 8 }, &origin_storage).?;
    streaming.geometry.beginPoll();
    const query = streaming.geometry.query(origin, 0, 4, 1);
    while (!streaming.geometry.ready(query)) _ = streaming.geometry.advance();
    sources[0] = .{ .known = true, .origin = origin, .query = query };
    streaming.refresh(0, false);
    try std.testing.expectEqual(@as(u64, 0), refresh[0]);
    try std.testing.expectEqual(@as(usize, 9), streams[0].cursor);
    for (hidden) |mask| try std.testing.expectEqual(@as(u32, 0), mask);
    try std.testing.expectEqual(@as(u64, 9), reused.value());
    streaming.refreshReady(0);
    try std.testing.expectEqual(@as(u64, 9), reused.value());
    stale[0] = 1;
    streaming.refresh(0, false);
    try std.testing.expectEqual(@as(u64, 1), refresh[0]);
    try std.testing.expectEqual(@as(u32, 1), streaming.missingSections(0, .{ .x = 0, .z = 0 }, 15));
}

test "completed leading columns bypass a pending center whose collision terrain is already delivered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const radius = 8;
    const side = 2 * radius + 1;
    const columns = side * side;
    const words = (columns + 63) / 64;
    const all = (1 << 24) - 1;
    var subjects: players.Players = .{ .deps = undefined, .config = .{ .render_distance = radius }, .spawn_world = 0, .records = &.{}, .dig_handlers = &.{} };
    var streams: [1]Streaming.Stream = @splat(.{ .setup = .streaming, .minimum_section = -4, .section_count = 24, .delivered = columns - 1 });
    var sources: [1]Streaming.Source = @splat(.{});
    var views: [1]Streaming.View = .{.{ .handle = null, .world = 0, .protocol = 0, .life = 0, .ready = true, .center = .{ .x = 0, .z = 0 }, .eye_min = .{ 8, 70, 8 }, .eye_max = 72 }};
    var sent: [words]u64 = @splat(0);
    var refresh: [words]u64 = @splat(0);
    var disclosed: [columns]u32 = @splat(all);
    var biomes: [columns]u32 = @splat(all);
    var hidden: [columns]u32 = @splat(0);
    var stale: [columns]u32 = @splat(0);
    var streaming: Streaming = undefined;
    streaming.deps.players = &subjects;
    streaming.config = .{};
    streaming.streams = &streams;
    streaming.sources = &sources;
    streaming.views = &views;
    streaming.sent = &sent;
    streaming.refresh_bits = &refresh;
    streaming.disclosed = &disclosed;
    streaming.biome_disclosed = &biomes;
    streaming.occluded = &hidden;
    streaming.stale = &stale;
    streaming.words_per_player = words;
    streaming.deliveries = .{};
    streaming.dirty_words = try .initEmpty(allocator, words);
    streaming.geometry = try .init(allocator, .{ .columns = columns, .sources = 1, .radius = radius });
    const air: [24]lighting.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = 0 } });
    for (0..columns) |index| {
        sent[index / 64] |= @as(u64, 1) << @intCast(index % 64);
        streaming.geometry.learn(.{ .world = 0, .x = @as(i32, @intCast(index % side)) - radius, .z = @as(i32, @intCast(index / side)) - radius, .minimum = -4 }, &air);
    }
    const leading: Streaming.Position = .{ .x = radius, .z = 0 };
    const leading_slot = streaming.sentIndex(0, leading);
    sent[leading_slot.word] &= ~leading_slot.mask;
    disclosed[streaming.columnIndex(0, leading)] = 0;
    biomes[streaming.columnIndex(0, leading)] = 0;
    hidden[streaming.columnIndex(0, leading)] = all;
    const center_slot = streaming.sentIndex(0, .{ .x = 0, .z = 0 });
    refresh[center_slot.word] = center_slot.mask;
    var origin_storage: section_visibility_world.Source = undefined;
    const origin = streaming.geometry.source(0, -4, 24, .{ 8, 72, 8 }, &origin_storage).?;
    streaming.geometry.beginPoll();
    const query = streaming.geometry.query(origin, -4, 24, radius);
    streaming.geometry.prioritize(query, .{ 1, 0 });
    sources[0] = .{ .origin = origin, .query = query, .known = true };
    streaming.advanceCursor(0);
    try std.testing.expectEqual(@as(usize, columns), streams[0].cursor);
    while (!streaming.deliveryReady(0, leading)) _ = streaming.geometry.advance();
    try std.testing.expect(!streaming.geometry.ready(query));
    streaming.refresh(0, false);
    const selected = spiral(streams[0].cursor);
    try std.testing.expectEqual(leading.x, selected.x);
    try std.testing.expectEqual(leading.z, selected.z);
    try std.testing.expectEqual(@as(u32, all), streaming.disclosureMasks(0, .{ .world = 0, .x = leading.x, .z = leading.z, .minimum = -4 }, 24).disclosure);
}

test "completed visibility refreshes prioritize nearby columns after source preparation" {
    const count = 25;
    var subjects: players.Players = .{ .deps = undefined, .config = .{ .render_distance = 2 }, .spawn_world = 0, .records = &.{}, .dig_handlers = &.{} };
    var streams: [1]Streaming.Stream = @splat(.{ .setup = .streaming });
    var sources: [1]Streaming.Source = @splat(.{});
    var refresh = [_]u64{0};
    var sent = [_]u64{(1 << count) - 1};
    var streaming: Streaming = undefined;
    streaming.deps.players = &subjects;
    streaming.config = .{};
    streaming.streams = &streams;
    streaming.sources = &sources;
    streaming.refresh_bits = &refresh;
    streaming.sent = &sent;
    streaming.words_per_player = 1;
    const near = spiral(10);
    const far = spiral(24);
    const near_slot = streaming.sentIndex(0, .{ .x = near.x, .z = near.z });
    const far_slot = streaming.sentIndex(0, .{ .x = far.x, .z = far.z });
    sent[0] &= ~far_slot.mask;
    refresh[0] = near_slot.mask;
    streaming.advanceCursor(0);
    try std.testing.expectEqual(@as(usize, 10), streams[0].cursor);
    streaming.clearRefresh(0, .{ .x = near.x, .z = near.z });
    streaming.advanceCursor(0);
    try std.testing.expectEqual(@as(usize, 24), streams[0].cursor);
    streaming.refresh(0, true);
    streaming.advanceCursor(0);
    try std.testing.expectEqual(@as(usize, 24), streams[0].cursor);
    try std.testing.expectEqual(@as(u64, 0), refresh[0]);
    streaming.refresh(0, false);
    streaming.advanceCursor(0);
    try std.testing.expectEqual(@as(usize, 0), streams[0].cursor);
    for (0..count) |column| {
        const at = spiral(column);
        const slot = streaming.sentIndex(0, .{ .x = at.x, .z = at.z });
        sent[slot.word] |= slot.mask;
        streaming.clearRefresh(0, .{ .x = at.x, .z = at.z });
        streaming.advanceCursor(0);
    }
    try std.testing.expectEqual(@as(usize, count), streams[0].cursor);
    try std.testing.expectEqual(@as(u64, 0), refresh[0]);
}

test "visibility snapshots remain stable until the simulation captures another publication" {
    var streams = [_]Streaming.Stream{.{ .generation = 1, .life = 4, .setup = .streaming, .section_count = 24 }};
    var sent = [_]u64{1};
    var published_occluded: [9]u32 = @splat(0);
    var published: Streaming.Published = .{
        .occluded = &published_occluded,
        .light = try Streaming.LightChanges.init(std.testing.allocator, 1),
        .views = &.{},
        .streams = &streams,
        .sent = &sent,
        .dirty_words = try .initEmpty(std.testing.allocator, sent.len),
        .changed_views = try lightning_rod.system.IndexSet.init(std.testing.allocator, streams.len),
        .dirty_streams = try lightning_rod.system.IndexSet.init(std.testing.allocator, streams.len),
    };
    defer std.testing.allocator.free(published.light.bits);
    defer published.light.words.deinit(std.testing.allocator);
    defer published.dirty_words.deinit(std.testing.allocator);
    defer published.changed_views.deinit(std.testing.allocator);
    defer published.dirty_streams.deinit(std.testing.allocator);
    published.dirty_streams.insert(0);
    var snapshot_streams: [1]Streaming.Stream = @splat(.{});
    var changed: [1]u64 = undefined;
    var snapshot_sent = [_]u64{0};
    var snapshot_occluded: [9]u32 = @splat(0);
    var snapshot: Streaming.Visibility = .{ .occluded = &snapshot_occluded, .reset = try lightning_rod.system.IndexSet.init(std.testing.allocator, snapshot_streams.len), .changed = &changed, .changed_words = try lightning_rod.system.IndexSet.init(std.testing.allocator, sent.len), .streams = &snapshot_streams, .sent = &snapshot_sent, .words_per_player = 1, .side = 3, .radius = 1 };
    defer snapshot.changed_words.deinit(std.testing.allocator);
    defer snapshot.reset.deinit(std.testing.allocator);
    var player: players.Players.Player = .{ .handle = .{ .index = 0, .generation = 1 }, .world = 0, .life = 4 };
    published.dirty_words.set(0);
    snapshot.capture(&published, std.testing.io);
    try std.testing.expect(snapshot.visible(0, &player, 0, 0, 0));
    try std.testing.expectEqualSlices(usize, &.{0}, snapshot.reset.values());
    try std.testing.expectEqualSlices(usize, &.{0}, snapshot.changed_words.values());
    snapshot.capture(&published, std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), snapshot.reset.count);
    try std.testing.expectEqual(@as(usize, 0), snapshot.changed_words.count);
    const section: chunks.Section = .{ .world = 0, .x = 0, .y = streams[0].minimum_section, .z = 0 };
    published_occluded[0] = 1;
    published.dirty_words.set(0);
    try std.testing.expect(snapshot.sectionVisible(0, &player, section));
    snapshot.capture(&published, std.testing.io);
    try std.testing.expect(snapshot.visible(0, &player, 0, 0, 0));
    try std.testing.expect(!snapshot.sectionVisible(0, &player, section));
    try std.testing.expectEqual(@as(u64, 1), snapshot.changed[0]);
    published_occluded[0] = 0;
    published.dirty_words.set(0);
    snapshot.capture(&published, std.testing.io);
    try std.testing.expect(snapshot.sectionVisible(0, &player, section));
    try std.testing.expectEqual(@as(u64, 1), snapshot.changed[0]);
    sent[0] = 0;
    published.dirty_words.set(0);
    try std.testing.expect(snapshot.visible(0, &player, 0, 0, 0));
    snapshot.capture(&published, std.testing.io);
    try std.testing.expect(!snapshot.visible(0, &player, 0, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), snapshot.reset.count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.changed[0]);
    sent[0] = 1;
    streams[0].generation = 2;
    published.dirty_streams.insert(0);
    published.dirty_words.set(0);
    snapshot.capture(&published, std.testing.io);
    try std.testing.expect(!snapshot.visible(0, &player, 0, 0, 0));
    player.handle.?.generation = 2;
    try std.testing.expect(snapshot.visible(0, &player, 0, 0, 0));
    player.life += 1;
    try std.testing.expect(!snapshot.visible(0, &player, 0, 0, 0));
}

test "departing strips match rectangle subtraction for movement and teleports" {
    const center: Streaming.Position = .{ .x = -17, .z = 31 };
    for ([_]i32{ 0, 2, 8, 32, 34, 35 }) |radius| for ([_]i32{ -71, -65, -3, -1, 0, 1, 3, 65, 71 }) |dx| for ([_]i32{ -71, -65, -3, -1, 0, 1, 3, 65, 71 }) |dz| {
        const target: Streaming.Position = .{ .x = center.x + dx, .z = center.z + dz };
        const side: usize = @intCast(radius * 2 + 1);
        var seen: [71 * 71]bool = @splat(false);
        var count: usize = 0;
        while (departingPosition(center, target, radius, count)) |at| : (count += 1) {
            try std.testing.expect(@abs(at.x - center.x) <= radius and @abs(at.z - center.z) <= radius);
            try std.testing.expect(@abs(at.x - target.x) > radius or @abs(at.z - target.z) > radius);
            const x: usize = @intCast(at.x - center.x + radius);
            const z: usize = @intCast(at.z - center.z + radius);
            const index = z * side + x;
            try std.testing.expect(!seen[index]);
            seen[index] = true;
        }
        var expected: usize = 0;
        for (0..side * side) |index| {
            const x = center.x + @as(i32, @intCast(index % side)) - radius;
            const z = center.z + @as(i32, @intCast(index / side)) - radius;
            const outside = @abs(x - target.x) > radius or @abs(z - target.z) > radius;
            try std.testing.expectEqual(outside, seen[index]);
            expected += @intFromBool(outside);
        }
        try std.testing.expectEqual(expected, count);
        try std.testing.expectEqual(null, departingPosition(center, target, radius, count + 1));
    };
    var count: usize = 0;
    while (departingPosition(center, .{ .x = center.x + 1, .z = center.z }, 32, count) != null) : (count += 1) {}
    try std.testing.expectEqual(@as(usize, 65), count);
}

test "region refresh keeps completed section visibility and block delivery until reclassified" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var records = [_]players.Players.Player{.{ .handle = .{ .index = 0, .generation = 1 }, .stage = .ready }};
    var subjects: players.Players = .{ .deps = undefined, .config = .{ .maximum = 1, .render_distance = 1 }, .spawn_world = 0, .records = &records, .dig_handlers = &.{} };
    var streams = [_]Streaming.Stream{.{ .generation = 1, .setup = .streaming, .minimum_section = 0, .section_count = 3, .delivered = 9, .cursor = 9 }};
    var views = [_]Streaming.View{.{ .handle = records[0].handle, .world = 0, .protocol = 772, .life = 0, .ready = true, .center = .{ .x = 0, .z = 0 } }};
    var sources: [1]Streaming.Source = @splat(.{ .known = true });
    var sent = [_]u64{511};
    var refresh = [_]u64{0};
    var occluded: [9]u32 = @splat(4);
    var disclosed: [9]u32 = @splat(3);
    var stale: [9]u32 = @splat(0);
    var published_streams = streams;
    var published_sent = sent;
    var published_occluded = occluded;
    var published: Streaming.Published = .{
        .light = undefined,
        .views = &views,
        .streams = &published_streams,
        .sent = &published_sent,
        .occluded = &published_occluded,
        .dirty_words = try .initEmpty(allocator, 1),
        .changed_views = try .init(allocator, 1),
        .dirty_streams = try .init(allocator, 1),
    };
    var streaming: Streaming = undefined;
    streaming.config = .{};
    streaming.deps = .{ .metrics = undefined, .players = &subjects, .chunks = undefined, .sessions = undefined, .packets = undefined, .worlds = undefined, .lighting = undefined };
    streaming.native_io = std.testing.io;
    streaming.cpu = .{};
    streaming.deliveries = .{};
    streaming.geometry = try .init(allocator, .{ .columns = 9, .sources = 3, .radius = 1 });
    streaming.published = &published;
    streaming.streams = &streams;
    streaming.views = &views;
    streaming.sources = &sources;
    streaming.sent = &sent;
    streaming.refresh_bits = &refresh;
    streaming.occluded = &occluded;
    streaming.disclosed = &disclosed;
    streaming.stale = &stale;
    streaming.words_per_player = 1;
    streaming.dirty_words = try .initEmpty(allocator, 1);
    streaming.background_players = try .init(allocator, 1);
    streaming.background_players.insert(0);
    streaming.debug_slots = &.{};
    for ([_]bool{ false, true }) |source_changed| {
        streaming.refresh(0, source_changed);
        try std.testing.expectEqual(@as(u64, 511), refresh[0]);
        try std.testing.expect(streaming.visibilityReady(0, .{ .x = 0, .z = 0 }));
        try std.testing.expect(streaming.visibilityReady(0, .{ .x = 1, .z = 1 }));
        streaming.publishVisibility();
        try std.testing.expectEqualSlices(u32, &occluded, &published_occluded);
        for (published_occluded) |mask| try std.testing.expectEqual(@as(u32, 4), mask);
    }
    const at: Streaming.Position = .{ .x = 0, .z = 0 };
    streaming.hideSections(0, at, 2);
    streaming.publishVisibility();
    try std.testing.expectEqual(@as(u32, 6), published_occluded[0]);
    stale[0] = 2;
    streaming.restoreSections(0, at, 2);
    try std.testing.expectEqual(@as(u32, 6), occluded[0]);
    stale[0] = 0;
    streaming.restoreSections(0, at, 2);
    try std.testing.expectEqual(@as(u32, 4), occluded[0]);
}

test "movement inside a source section reuses visibility and crossing its boundary requests a new source" {
    var records: [1]players.Players.Player = @splat(.{});
    var subjects: players.Players = .{ .deps = undefined, .config = .{ .maximum = 1, .render_distance = 2 }, .spawn_world = 0, .records = &records, .dig_handlers = &.{} };
    var streams: [1]Streaming.Stream = @splat(.{ .setup = .streaming, .cursor = 25 });
    var views = [_]Streaming.View{.{ .handle = .{ .index = 0, .generation = 1 }, .world = 0, .protocol = 772, .life = 0, .ready = true, .center = .{ .x = 0, .z = 0 }, .eye_min = .{ 0, 64, 0 }, .eye_max = 65 }};
    const origin: section_visibility_world.Source = .{ .section = .{ .world = 0, .x = 0, .y = 4, .z = 0 }, .component = 0, .point = .{ 0, 65, 0 }, .camera_bounds = .{ .minimum = .{ 0, 64, 0 }, .maximum = .{ 16, 80, 16 } }, .membership = @splat(std.math.maxInt(u64)) };
    var sources: [1]Streaming.Source = @splat(.{ .known = true, .origin = &origin });
    var refresh = [_]u64{0};
    var sent = [_]u64{(1 << 25) - 1};
    var streaming: Streaming = undefined;
    streaming.config = .{};
    streaming.deps = .{ .metrics = undefined, .players = &subjects, .chunks = undefined, .sessions = undefined, .packets = undefined, .worlds = undefined, .lighting = undefined };
    streaming.streams = &streams;
    streaming.sources = &sources;
    streaming.views = &views;
    streaming.refresh_bits = &refresh;
    streaming.sent = &sent;
    streaming.words_per_player = 1;
    streaming.pending = false;
    var next = views[0];
    next.eye_min[0] = 4;
    streaming.updateView(0, next);
    try std.testing.expectEqual(origin.bounds(), sources[0].origin.?.bounds());
    try std.testing.expect(sources[0].known);
    try std.testing.expect(!streaming.pending);
    next.eye_min[0] = 1;
    streaming.updateView(0, next);
    try std.testing.expect(!streaming.pending);
    next.eye_min[0] = 90;
    streaming.updateView(0, next);
    try std.testing.expect(!sources[0].known);
    try std.testing.expect(streaming.pending);
    try std.testing.expectEqual(@as(u64, 0), refresh[0]);
    sources[0].biome = 12;
    next.world += 1;
    streaming.updateView(0, next);
    try std.testing.expect(sources[0].biome == null);
}
