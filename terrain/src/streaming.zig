const geometry_bounds = @import("occlusion").bounds;
const section_visibility_world = @import("occlusion").section_visibility_world;
const streaming_debug = @import("streaming_debug.zig");
const chunk_horizon = @import("occlusion").chunk_horizon;
const SpatialIndex = @import("players").player_spatial.Grid(64);
const metrics = @import("metrics");
const std = @import("std");
const section_views = @import("lighting").section_views;
const wire_1_21_5 = @import("wire_1_21_5");
const lightning_rod = @import("lightning_rod");
const chunks = @import("chunks");
const chunk_encoding = @import("chunk_encoding.zig");
const delivery_cache = @import("delivery_cache.zig");
const game_data = @import("game_data");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const worlds = @import("worlds");
const players = @import("players").players;
const storage = @import("storage");
const persistent_records = @import("records");

const lighting = @import("lighting.zig");
const BlockProperties = @import("block_properties").BlockProperties;
const light_store = @import("lighting").light_store;
const assert = std.debug.assert;
const geometry_change_capacity = 256;

pub const Streaming = struct {
    pub const id = "minecraft:chunk_streaming";

    pub const Configuration = struct {
        /// Shared workspaces require sequential polling on one worker.
        /// Sections read at once to learn occlusion geometry, generation it waits for included.
        chunk_sections: usize = section_visibility_world.World.batch_max,
        delivery_workspace: ?*delivery_cache.Workspace = null,
        prefetch: u2 = 0,
        /// Keep delivered columns loaded until they leave the client chunk storage, so turning
        /// back within it costs no resend. Off unloads at the delivery radius.
        retain_client_storage: bool = true,
        occlusion: bool = true,
        /// Replace hidden blocks in delivered terrain, sending true states within one section of
        /// each player and whenever an edit exposes them.
        hull: bool = false,
        occlusion_columns: ?usize = null,
        occlusion_summary_columns: ?usize = null,
        occlusion_mixed_sections: ?usize = null,
        /// Bound column variants per submission. Complete tiles rotate between observers.
        work: lightning_rod.system.work.Limits = .{ .guaranteed = .{ .operations = 1 }, .burst = .{ .operations = batch_max - 1 } },
        /// Shown where a chunk source stores no biomes. Plains, as vanilla generates by default.
        fallback_biome: i32 = game_data.registry.biomeId("minecraft:plains").?,
    };

    pub const Dependencies = struct {
        metrics: *metrics.Registry,
        players: *players.Players,
        chunks: *chunks.Chunks,
        sessions: *sessions.Service,
        packets: *packets.Packets,
        worlds: *worlds.Worlds,
        lighting: *lighting.Lighting,
        blocks: *BlockProperties,
    };

    const batch_max = lighting.Lighting.delivery_batch_max;
    /// A light update before its light: its packet id and the column's x and z, each a varint.
    const light_update_header = 15;

    const GeometryChange = struct {
        section: chunks.Section,
        bounds: geometry_bounds.Box,
        /// Whether an edit changed what a cell occludes, or whether it is air or stone, the only
        /// things the visibility geometry holds. Other edits, as of a plant growing a stage,
        /// still reach the players who hold the section, but nothing is learned again.
        occlusion: bool,

        const Extent = struct { bounds: geometry_bounds.Box, occlusion: bool };

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

    pub const Position = chunk_horizon.Position;
    pub const Horizon = chunk_horizon;

    pub const View = struct {
        handle: ?sessions.Handle,
        world: u32,
        protocol: i32,
        life: u32,
        teleport_id: i32 = 0,
        ready: bool,
        /// The position for this life has gone out.
        placed: bool = false,
        center: Position,
        eye_min: [3]i32 = .{ 0, 0, 0 },
        eye_max: i32 = 0,
        occlusion: bool = true,
        frontier_debug: bool = false,

        pub fn capture(player: players.Players.Player) View {
            return .{
                .eye_min = .{ @intFromFloat(@floor(player.position.x)), @intFromFloat(@floor(player.position.y + @as(f64, @as(f32, 0.2)))), @intFromFloat(@floor(player.position.z)) },
                .eye_max = @intFromFloat(@floor(player.position.y + @as(f64, @as(f32, 1.62)))),
                .occlusion = player.occluded,
                .handle = player.handle,
                .world = player.world,
                .protocol = player.protocol,
                .life = player.life,
                .teleport_id = player.teleport_id,
                .ready = switch (player.stage) {
                    .teleport, .awaiting_teleport, .ready => !player.configuring,
                    else => false,
                },
                .placed = (player.stage == .awaiting_teleport or player.stage == .ready) and !player.configuring,
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

        fn mark(self: *LightChanges, slot: chunk_horizon.Index.Bit) void {
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

    const LightColumn = struct { world: u32, at: Position };

    /// Light sections a patch changed in one column, with the light they now hold.
    const LightDelta = struct {
        world: u32,
        at: Position,
        /// Light sections the patch changed, by layer.
        sections: [2]u32,
        /// Changed sections that hold a buffer in the mail. The rest are one level.
        dense: [2]u32,
        /// The level of a uniform section, or the index of its buffer in the mail.
        slots: [2][light_store.sections_max]u16,
    };

    /// Patched light on its way from the simulation thread to the players who hold the
    /// columns. The simulation thread copies the changed sections in when it patches.
    /// The streaming thread sends them in the order they were patched, since a later
    /// patch of a section replaces what an earlier one put there.
    const LightMail = struct {
        deltas: []LightDelta,
        count: usize = 0,
        /// Deltas before this one were dealt with.
        next: usize = 0,
        bytes: [][light_store.section_bytes]u8,
        used: usize = 0,
        /// Columns whose light changed in a way the mail does not carry: an edit no patch
        /// could follow, a patch there was no room for, or one nobody was near. Whoever
        /// holds one when the deltas before it have been sent gets its light from a solve.
        /// Without this a player who arrives while an older delta still waits would be
        /// sent that delta and never the change after it.
        lost: std.AutoHashMapUnmanaged(LightColumn, void) = .empty,
        /// More columns were lost than can be listed. Every holder of any column is owed a solve.
        lost_all: bool = false,

        fn create(allocator: std.mem.Allocator, slots: usize) !*LightMail {
            const self = try allocator.create(LightMail);
            // A patch changes a few sections. A share for each player slot rides on room
            // for the two largest columns, and what does not fit is solved instead.
            self.* = .{
                .deltas = try allocator.alloc(LightDelta, 64 + 8 * slots),
                .bytes = try allocator.alloc([light_store.section_bytes]u8, 2 * light_store.Copy.capacity + 8 * slots),
            };
            assert(self.bytes.len <= std.math.maxInt(u16));
            try self.lost.ensureTotalCapacity(allocator, @intCast(1024 + 64 * slots));
            return self;
        }

        fn memory(self: *const LightMail) usize {
            return @sizeOf(LightMail) + self.deltas.len * @sizeOf(LightDelta) + self.bytes.len * light_store.section_bytes + self.lost.capacity() * (@sizeOf(LightColumn) + 1);
        }

        /// Notes a column whose changed light the mail does not carry.
        fn lose(self: *LightMail, world: u32, at: Position) void {
            const column: LightColumn = .{ .world = world, .at = at };
            if (self.lost_all or self.lost.contains(column)) return;
            if (self.lost.count() == self.lost.capacity()) {
                self.lost_all = true;
                return;
            }
            self.lost.putAssumeCapacityNoClobber(column, {});
        }

        /// Copies the changed sections of one column in. False without room.
        fn add(self: *LightMail, world: u32, at: Position, sections: [2]u32, light: *const light_store.Sections) bool {
            assert(sections[0] | sections[1] != 0);
            if (self.count == self.deltas.len) return false;
            var needed: usize = 0;
            for (0..2) |layer| {
                var bits = sections[layer];
                while (bits != 0) : (bits &= bits - 1) needed += @intFromBool(light.light[layer][@ctz(bits)] == .dense);
            }
            if (self.bytes.len - self.used < needed) return false;
            const delta = &self.deltas[self.count];
            delta.* = .{ .world = world, .at = at, .sections = sections, .dense = .{ 0, 0 }, .slots = undefined };
            for (0..2) |layer| {
                var bits = sections[layer];
                while (bits != 0) : (bits &= bits - 1) {
                    const section = @ctz(bits);
                    switch (light.light[layer][section]) {
                        .uniform => |level| delta.slots[layer][section] = level,
                        .dense => |levels| {
                            @memcpy(&self.bytes[self.used], levels);
                            delta.slots[layer][section] = @intCast(self.used);
                            delta.dense[layer] |= @as(u32, 1) << @intCast(section);
                            self.used += 1;
                        },
                    }
                }
            }
            self.count += 1;
            return true;
        }

        /// The changed sections of a delta as light packet data reads them. Sections the
        /// delta does not hold are left undefined.
        fn view(self: *const LightMail, delta: *const LightDelta, output: *light_store.Sections) void {
            for (0..2) |layer| {
                var bits = delta.sections[layer];
                while (bits != 0) : (bits &= bits - 1) {
                    const section = @ctz(bits);
                    const slot = delta.slots[layer][section];
                    output.light[layer][section] = if (delta.dense[layer] & (@as(u32, 1) << @intCast(section)) == 0) .{ .uniform = @intCast(slot) } else .{ .dense = &self.bytes[slot] };
                }
            }
        }

        fn empty(self: *const LightMail) bool {
            return self.next == self.count and self.lost.count() == 0 and !self.lost_all;
        }

        fn clear(self: *LightMail) void {
            self.count = 0;
            self.next = 0;
            self.used = 0;
            self.lost.clearRetainingCapacity();
            self.lost_all = false;
        }
    };

    /// A column whose stored light is gone and that a full solve may bring back.
    const LightResolve = struct {
        world: u32,
        at: Position,
        /// Names the request to the light store. Only the newest one of a column counts.
        stamp: u64,
        /// Gameplay asked for it, so it is solved even while no player holds the column.
        wanted: bool,
    };

    /// Solves the light store is waiting for, oldest first. A full list drops its oldest
    /// entry. That column stays unlit until an edit or gameplay asks again.
    const LightResolves = struct {
        items: []LightResolve,
        count: usize = 0,

        fn init(allocator: std.mem.Allocator, slots: usize) !LightResolves {
            return .{ .items = try allocator.alloc(LightResolve, 64 + 16 * slots) };
        }

        fn add(self: *LightResolves, entry: LightResolve) void {
            assert(entry.stamp != 0);
            self.remove(entry.world, entry.at);
            if (self.count == self.items.len) {
                std.mem.copyForwards(LightResolve, self.items[0 .. self.count - 1], self.items[1..self.count]);
                self.count -= 1;
            }
            self.items[self.count] = entry;
            self.count += 1;
        }

        fn find(self: *const LightResolves, world: u32, at: Position) ?u64 {
            for (self.items[0..self.count]) |entry| {
                if (entry.world == world and std.meta.eql(entry.at, at)) return entry.stamp;
            }
            return null;
        }

        fn remove(self: *LightResolves, world: u32, at: Position) void {
            for (self.items[0..self.count], 0..) |entry, index| {
                if (entry.world != world or !std.meta.eql(entry.at, at)) continue;
                std.mem.copyForwards(LightResolve, self.items[index .. self.count - 1], self.items[index + 1 .. self.count]);
                self.count -= 1;
                return;
            }
        }

        fn wanted(self: *const LightResolves) ?LightResolve {
            for (self.items[0..self.count]) |entry| {
                if (entry.wanted) return entry;
            }
            return null;
        }
    };

    const Published = struct {
        /// Patched light the streaming thread has not taken yet.
        light_mail: *LightMail,
        light_resolves: LightResolves,
        mutex: std.Io.Mutex = .init,
        views: []View,
        streams: []Snapshot,
        sent: []u64,
        occluded: []u32,
        dirty_words: std.DynamicBitSetUnmanaged,
        changed_views: lightning_rod.system.IndexSet,
        dirty_streams: lightning_rod.system.IndexSet,
        geometry_revision: u64 = 0,
        geometry_changes: std.AutoHashMapUnmanaged(chunks.Section, GeometryChange.Extent) = .{},
        geometry_overflow: bool = false,
        epoch: u64 = 0,
        updated: bool = true,

        pub fn setStream(self: *Published, index: usize, stream: Snapshot) void {
            if (std.meta.eql(self.streams[index], stream)) return;
            self.streams[index] = stream;
            self.dirty_streams.insert(index);
        }
    };

    /// A stream opens by sending its view center. It recenters by unloading what leaves and
    /// sending the new center.
    const Setup = enum { opening, center, streaming, unloading };

    const Snapshot = struct {
        generation: u32 = 0,
        life: u32 = 0,
        prepared_teleport: i32 = 0,
        setup: Setup = .opening,
        center: Position = .{ .x = 0, .z = 0 },
        minimum_section: i32 = -4,
        section_count: usize = 24,
        /// Delivery order rank of the next undelivered column, published for load diagnostics.
        cursor: usize = 0,
    };

    const Stream = struct {
        generation: u32 = 0,
        life: u32 = 0,
        prepared_teleport: i32 = 0,
        setup: Setup = .opening,
        /// The client was told terrain is loading for this life. Clients from 1.21.4 then wait for
        /// the chunk under their position, so this follows the position, as vanilla orders them.
        announced: bool = false,
        center: Position = .{ .x = 0, .z = 0 },
        target: Position = .{ .x = 0, .z = 0 },
        cursor: usize = 0,
        departing: chunk_horizon.Difference = .{},
        minimum_section: i32 = -4,
        section_count: usize = 24,
        delivered: usize = 0,
        /// Output credit the next column of this player needs before it is worth reading:
        /// the size of the last reservation made or refused for it. A length after
        /// compression would let a slow connection be read for and refused on every wake.
        reserve_bytes: usize = 0,
        visibility_revision: u64 = 0,
        visibility_origin: Position = .{ .x = 0, .z = 0 },
        debug_history: bool = false,

        pub fn snapshot(self: *const Stream) Snapshot {
            return .{ .generation = self.generation, .life = self.life, .prepared_teleport = self.prepared_teleport, .setup = self.setup, .center = self.center, .minimum_section = self.minimum_section, .section_count = self.section_count, .cursor = self.cursor };
        }
    };

    const Source = struct {
        biome: ?u16 = null,
        origin: ?*const section_visibility_world.Source = null,
        known: bool = false,
        pace: section_visibility_world.Pace = .{},
    };

    const DisclosureMasks = struct { visibility: u32, disclosure: u32 };
    const DisclosureState = struct {
        column: section_visibility_world.Column,
        count: u8,
        masks: DisclosureMasks,
        stale: u32,
        disclosed: u32,
        biomes: u32,
        frontier: u32,
        painted: u32,
        debug: bool,
    };
    const DeliveryColumn = struct { world: u32, at: Position };
    const Cold = struct { world: u32, at: Position, protocol: i32, owner: usize };
    /// Two batches of deferred columns. A full queue drops new entries, which return through
    /// ordinary selection.
    const cold_capacity = 2 * batch_max;
    /// Unknown columns classified per source preparation, about 8 ms of work.
    const topology_budget = 16;
    /// Passes before a player whose urgent column waited on generation is tried again.
    const urgent_retry_passes = 16;
    const Tile = struct {
        world: u32,
        minimum: Position,
        side: usize,
        cursor: usize = 0,
        scanned: usize = 0,
        audience: ?SpatialIndex.Window = null,

        fn columns(self: Tile) usize {
            return self.side * self.side;
        }

        fn at(self: Tile, cursor: usize) Position {
            assert(cursor < self.columns());
            return .{ .x = self.minimum.x + @as(i32, @intCast(cursor % self.side)), .z = self.minimum.z + @as(i32, @intCast(cursor / self.side)) };
        }

        fn contains(self: Tile, world: u32, position: Position) bool {
            return world == self.world and position.x >= self.minimum.x and position.z >= self.minimum.z and
                @as(i64, position.x) - self.minimum.x < self.side and @as(i64, position.z) - self.minimum.z < self.side;
        }
    };

    /// Protocols in a family take the same packet, byte for byte, for the same column or light:
    /// the same packet id and layout, the same writer and, for chunks, the same delivery
    /// variant. One encoding serves every player of a family. A family is named by its first
    /// protocol implementation.
    const Family = struct { chunk: u8, light: u8 };

    /// What decides a protocol's chunk and light packets beyond the delivery variant.
    const ProtocolWire = struct {
        number: i32,
        chunk_id: i32,
        chunk_layout: [32]u8,
        chunk_writer: usize,
        light_id: i32,
        light_layout: [32]u8,
    };

    const protocol_wires = wires: {
        const implementations = packets.protocols.implementations;
        var result: [implementations.len]ProtocolWire = undefined;
        for (implementations, &result) |Version, *wire| {
            const Clientbound = Version.Protocol.play.toClient;
            wire.* = .{
                .number = Version.protocol_number,
                .chunk_id = Clientbound.packetId(.map_chunk),
                .chunk_layout = Clientbound.PacketBody(.map_chunk).layout_fingerprint,
                .chunk_writer = sessions.packet_api.select(Version, chunk_encoding.write_delivery),
                .light_id = Clientbound.packetId(.update_light),
                .light_layout = Clientbound.PacketBody(.update_light).layout_fingerprint,
            };
        }
        break :wires result;
    };

    fn family(self: *Streaming, protocol: i32) Family {
        const at = for (protocol_wires, 0..) |wire, index| {
            if (wire.number == protocol) break index;
        } else unreachable;
        if (self.families[at]) |known| return known;
        const own = protocol_wires[at];
        const variant = self.delivery_catalog.index(protocol) catch unreachable;
        var found: Family = .{ .chunk = @intCast(at), .light = @intCast(at) };
        // The first implementation alike names the family, so every member finds the same.
        for (protocol_wires[0..at], 0..) |wire, index| {
            if (wire.light_id == own.light_id and std.mem.eql(u8, &wire.light_layout, &own.light_layout) and found.light == at) found.light = @intCast(index);
            const other = self.delivery_catalog.index(wire.number) catch continue;
            if (other == variant and wire.chunk_id == own.chunk_id and wire.chunk_writer == own.chunk_writer and std.mem.eql(u8, &wire.chunk_layout, &own.chunk_layout) and found.chunk == at) found.chunk = @intCast(index);
        }
        self.families[at] = found;
        return found;
    }

    /// Whether players on these protocols take the same chunk packet for a column.
    fn sameChunkFamily(self: *Streaming, a: i32, b: i32) bool {
        return a == b or self.family(a).chunk == self.family(b).chunk;
    }

    /// Whether players on these protocols take the same light update.
    fn sameLightFamily(self: *Streaming, a: i32, b: i32) bool {
        return a == b or self.family(a).light == self.family(b).light;
    }

    const Pending = struct {
        at: Position,
        world: u32,
        protocol: i32,
        owner: usize,
        biome: ?u16 = null,
        biome_disclosure: u32 = 0,
        disclosure: u32 = std.math.maxInt(u32),
        visibility: u32 = std.math.maxInt(u32),
        frontier: u32 = 0,
    };

    geometry_changes: []GeometryChange,
    biome_sections: []?section_views.Biomes,
    geometry: section_visibility_world.World,
    classifications: []chunks.encoding.Classification,
    column_summaries: []chunks.classification.ColumnSummary,
    column_prefixes: [chunks.classification.column_batch_max][chunks.Light.prefix_bytes + 32 + section_visibility_world.prepared_codec.column.?.maximum]u8 = undefined,
    classification_requests: []chunks.Chunks.ClassificationRequest,
    prepared_classifications: []chunks.classification.Prepared,
    geometry_revision: u64 = 0,
    occluded: []u32,
    // Changes since the last bulk or reveal snapshot received by the client.
    stale: []u32,
    disclosed: []u32,
    /// Completed chunk packets per column slot. Hull corrections follow each delivery.
    column_deliveries: []u32,
    painted: []u32,
    biome_disclosed: []u32,
    light_receipts: lighting.Receipts,
    refresh_bits: []u64,
    pending_scratch: []u64,
    acquired_chunks: metrics.Counter,
    section_visits: metrics.Counter,
    sweeps_started: metrics.Counter = .{},
    sweeps_completed: metrics.Counter = .{},
    sweeps_shared: metrics.Counter = .{},
    section_builds: metrics.Counter,
    packet_summaries: metrics.Counter,
    concealed_sections: metrics.Counter,
    encoded_bytes: metrics.Counter,
    encoded_packets: metrics.Counter = .{},
    topology: struct {
        restored: metrics.Counter = .{},
        acquired: metrics.Counter = .{},
        lookups: metrics.Counter = .{},
        cached_columns: metrics.Counter = .{},
        column_lookups: metrics.Counter = .{},
        rebuilt: metrics.Counter = .{},
        reused: metrics.Counter = .{},
        evicted: metrics.Counter = .{},
        working_evicted: metrics.Counter = .{},
    } = .{},
    /// How block edits turned into light updates.
    light_edit_counts: struct {
        patched: metrics.Counter = .{},
        unsent: metrics.Counter = .{},
        unlit: metrics.Counter = .{},
        solved: metrics.Counter = .{},
        offered: metrics.Counter = .{},
    } = .{},
    /// Why a batch ended without sending, to separate idle time from stalls.
    stalls: struct {
        idle: metrics.Counter = .{},
        epoch: metrics.Counter = .{},
        candidates: metrics.Counter = .{},
        pool: metrics.Counter = .{},
        credit: metrics.Counter = .{},
    } = .{},
    deliveries: struct {
        new_columns: metrics.Counter = .{},
        replacements: metrics.Counter = .{},
        biome_only_replacements: metrics.Counter = .{},
        reused: metrics.Counter = .{},
        new_sections: metrics.Counter = .{},
        repeated_sections: metrics.Counter = .{},
        refresh_scans: metrics.Counter = .{},
        /// Columns without a stored record, which reserve a full page because their size is unknown.
        page_reservations: metrics.Counter = .{},
        /// Cold columns moved out of a batch to the baker, or behind an urgent column.
        deferred_cold: metrics.Counter = .{},
        /// Columns whose rebuilt packet outgrew the declared bound reserved for it.
        outgrown_reservations: metrics.Counter = .{},
        refresh_columns: metrics.Counter = .{},
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
        metadata: metrics.Timer = .{},
        light_updates: metrics.Timer = .{},
        bake: metrics.Timer = .{},
    } = .{},
    deps: Dependencies,
    /// Reads block sections to learn occlusion geometry.
    chunk_client: chunks.Chunks.Client,
    io: std.Io,
    native_io: std.Io,
    published: *Published,
    tracked_views: lightning_rod.system.IndexSet,
    views: []View,
    changed_players: lightning_rod.system.IndexSet,
    background_players: lightning_rod.system.IndexSet,
    occupied_players: lightning_rod.system.IndexSet,
    /// The pass on which each player's urgent column waited on generation and the player left
    /// the urgent lane. Finished generation does not wake the lane, so it is tried again later.
    urgent_waits: []?u64,
    passes: u64 = 0,
    setup_players: lightning_rod.system.IndexSet,
    publication_players: lightning_rod.system.IndexSet,
    source_players: lightning_rod.system.IndexSet,
    observers_index: SpatialIndex,
    generation_updates: []chunks.Generation.Update,
    epoch: u64 = 0,
    pending: bool = true,
    config: Configuration,
    classification: *const chunks.classification.Index,
    streams: []Stream,
    order: chunk_horizon.Order,
    recipients: []sessions.Handle,
    tile_observers: []usize,
    tile: ?Tile = null,
    /// Columns deferred from batches because they lack stored light. Each batch bakes one, so
    /// later deliveries of it read the stored record instead of solving inside a delivery.
    cold: [cold_capacity]Cold = undefined,
    cold_count: usize = 0,
    /// Cold columns whose bake found their neighbourhood edited, so no frame could be stored.
    /// An edit every tick lands before each bake, so these are solved inline, unstored.
    unstorable: [cold_capacity]DeliveryColumn = undefined,
    unstorable_count: usize = 0,
    group_window: *chunks.Chunks.GroupWindow,
    tile_watch: *chunks.Watch,
    tile_revisions: []u64,
    sent: []u64,
    grid: chunk_horizon.Index,
    visibility: Visibility,
    sources: []Source,
    origin_scratch: section_visibility_world.Source = undefined,
    dirty_words: std.DynamicBitSetUnmanaged,
    next_player: usize = 0,
    next_occupied_player: usize = 0,
    next_visibility_player: usize = 0,
    encoding: *chunk_encoding.Workspace,
    delivery: *delivery_cache.Workspace,
    delivery_catalog: delivery_cache.Catalog,
    /// By protocol implementation, the families it falls in, found when first asked, as the
    /// catalog only knows its variants once configuration completes.
    families: [protocol_wires.len]?Family = @splat(null),
    light_pending: LightChanges,
    /// Patched light being sent. Only the streaming thread touches it.
    light_mail: *LightMail,
    /// Solves the light store waits for. Only the streaming thread touches them.
    light_resolves: LightResolves,
    /// Holders of a patched column that are owed exactly its changed sections.
    light_fresh: []bool,
    /// Simulation thread. Something was put in the published mail during this tick.
    light_mailed: bool = false,
    /// The last batch sent its stored columns ahead of a column that must be solved
    /// inline. That column has the next batch to itself.
    urgent_deferred: bool = false,
    /// The bound the last stored column declared, as a guess at the next one of a
    /// player nothing was reserved for yet.
    reserve_typical: usize = 16 * 1024,
    changed: *std.Io.Event,
    wake_pending: bool = false,
    debug_slots: []streaming_debug.Slot = &.{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration, deps: Dependencies) !*Streaming {
        const self = try allocate(allocator, io, config, deps);
        return self;
    }

    pub fn allocate(allocator: std.mem.Allocator, io: std.Io, config: Configuration, deps: Dependencies) !*Streaming {
        try config.work.validate(1, .{ .operations = 1 });
        const turn = try config.work.maximum(1);
        if (turn.operations > batch_max or turn.bytes != 0) return error.InvalidWorkLimits;
        if (config.chunk_sections < 24 or config.chunk_sections > section_visibility_world.World.batch_max) return error.InvalidConfiguration;
        const chunk_client = try deps.chunks.client(.{ .name = "streaming", .sections = config.chunk_sections });
        if (config.fallback_biome < 0 or config.fallback_biome >= game_data.registry.biome_names.len) return error.UnsupportedBiome;

        const metadata = try prepareMetadata(allocator, deps.chunks);
        if (config.occlusion) deps.lighting.includeClassification(metadata);
        if (config.hull) try deps.lighting.includeHull(allocator);
        const properties = metadata.properties;
        const group_side: usize = deps.chunks.storageGroup(.{ .world = 0, .x = 0, .y = 0, .z = 0 }).side;
        const group_window = try deps.chunks.createGroupWindow(allocator, (section_views.maximum_sections + 2 * (group_side - 1)) / group_side);
        const prepared_classifications = try allocatePrepared(allocator);
        const self = try allocator.create(Streaming);
        const streams = try allocator.alloc(Stream, deps.players.records.len);

        for (streams) |*stream| stream.* = .{};

        const side: usize = @intCast((deps.players.config.render_distance + @as(i32, config.prefetch)) * 2 + 1);
        const visibility_side = side + 2 * section_visibility_world.Source.horizon_padding;
        if (config.occlusion) {
            if (config.occlusion_columns) |columns| if (columns < (visibility_side + 2) * (visibility_side + 2)) return error.VisibilityCacheTooSmall;
        }
        // Per-column state covers every column the client may still hold, not only those delivered.
        const grid = chunk_horizon.Index.init(if (config.retain_client_storage) keepRadiusFor(deps.players.config.render_distance) * 2 + 1 else @intCast(side));
        assert(grid.width >= side);
        const words = grid.words;
        const sent = try allocator.alloc(u64, streams.len * words);
        @memset(sent, 0);
        const occluded = try allocator.alloc(u32, streams.len * grid.columns);
        @memset(occluded, std.math.maxInt(u32));
        const stale = try allocator.alloc(u32, occluded.len);
        @memset(stale, 0);
        const disclosed = try allocator.alloc(u32, occluded.len);
        @memset(disclosed, 0);
        const column_deliveries = try allocator.alloc(u32, occluded.len);
        @memset(column_deliveries, 0);
        const biome_disclosed = try allocator.alloc(u32, occluded.len);
        @memset(biome_disclosed, 0);
        const light_receipts = try lighting.Receipts.init(allocator, occluded.len, deps.lighting.rules);
        const refresh_bits = try allocator.alloc(u64, sent.len);
        @memset(refresh_bits, 0);
        var geometry_changes: std.AutoHashMapUnmanaged(chunks.Section, GeometryChange.Extent) = .{};
        try geometry_changes.ensureTotalCapacity(allocator, geometry_change_capacity);
        const published = try allocator.create(Published);
        published.* = .{
            .geometry_changes = geometry_changes,
            .light_mail = try LightMail.create(allocator, streams.len),
            .light_resolves = try LightResolves.init(allocator, streams.len),
            .views = try allocator.alloc(View, streams.len),
            .streams = try allocator.alloc(Snapshot, streams.len),
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
            .classification = metadata,
            .geometry_changes = try allocator.alloc(GeometryChange, geometry_change_capacity),
            .biome_sections = try allocator.alloc(?section_views.Biomes, 9 * section_views.maximum_sections),
            .column_summaries = try allocator.alloc(chunks.classification.ColumnSummary, chunks.classification.column_batch_max),
            .classifications = try allocator.alloc(chunks.encoding.Classification, section_visibility_world.World.batch_max),
            .classification_requests = try allocator.alloc(chunks.Chunks.ClassificationRequest, section_visibility_world.World.batch_max),
            .prepared_classifications = prepared_classifications,
            .geometry = try section_visibility_world.World.init(allocator, .{
                .properties = properties,
                .columns = if (config.occlusion) config.occlusion_columns orelse (visibility_side + 2) * (visibility_side + 2) else 1,
                .summary_columns = if (config.occlusion) config.occlusion_summary_columns orelse try std.math.mul(usize, streams.len, (visibility_side + 2) * (visibility_side + 2)) else 0,
                .mixed_sections = if (config.occlusion) config.occlusion_mixed_sections else null,
                .views = streams.len,
                .radius = if (config.occlusion) @intCast((visibility_side - 1) / 2) else 0,
            }),
            .occluded = occluded,
            .stale = stale,
            .disclosed = disclosed,
            .column_deliveries = column_deliveries,
            .painted = try allocator.dupe(u32, stale),
            .biome_disclosed = biome_disclosed,
            .light_receipts = light_receipts,
            .refresh_bits = refresh_bits,
            .pending_scratch = try allocator.alloc(u64, words),
            .io = io,
            .native_io = io,
            .changed = deps.chunks.ready(),
            .published = published,
            .tracked_views = try lightning_rod.system.IndexSet.init(allocator, deps.players.records.len),
            .views = try allocator.dupe(View, published.views),
            .section_visits = try deps.metrics.counter(.{ .name = "streaming.visibility.visits", .description = "Sections traversed through neighboring openings" }),
            .sweeps_started = try deps.metrics.counter(.{ .name = "streaming.visibility.sweeps.started", .description = "Visibility snapshots started" }),
            .sweeps_completed = try deps.metrics.counter(.{ .name = "streaming.visibility.sweeps.completed", .description = "Visibility snapshots completed" }),
            .sweeps_shared = try deps.metrics.counter(.{ .name = "streaming.visibility.sweeps.shared", .description = "Completed visibility snapshots copied between equivalent observers" }),
            .section_builds = try deps.metrics.counter(.{ .name = "streaming.visibility.section_builds", .description = "Section face connectivity rebuilt" }),
            .packet_summaries = try deps.metrics.counter(.{ .name = "streaming.encoding.summaries", .description = "Section packet summaries prepared" }),
            .topology = .{
                .restored = try deps.metrics.counter(.{ .name = "streaming.occlusion.metadata_restored", .description = "Section topology restored from prepared world data" }),
                .acquired = try deps.metrics.counter(.{ .name = "streaming.occlusion.column_acquisitions", .description = "Topology column acquisitions during batched geometry preparation" }),
                .lookups = try deps.metrics.counter(.{ .name = "streaming.occlusion.section_resolutions", .description = "Topology sections resolved in traversal batches" }),
                .cached_columns = try deps.metrics.counter(.{ .name = "streaming.occlusion.cached_columns", .description = "Topology columns resolved through retained slot references" }),
                .column_lookups = try deps.metrics.counter(.{ .name = "streaming.occlusion.column_lookups", .description = "Topology columns requiring a shared cache lookup" }),
                .rebuilt = try deps.metrics.counter(.{ .name = "streaming.visibility.metadata_rebuilt", .description = "Initialized section topology changed" }),
                .reused = try deps.metrics.counter(.{ .name = "streaming.visibility.metadata_reused", .description = "Edits retained identical section topology" }),
                .evicted = try deps.metrics.counter(.{ .name = "streaming.visibility.cache_evictions", .description = "Metadata columns evicted" }),
                .working_evicted = try deps.metrics.counter(.{ .name = "streaming.visibility.working_evictions", .description = "Metadata evicted inside the active query horizon" }),
            },
            .concealed_sections = try deps.metrics.counter(.{ .name = "streaming.concealed_sections", .description = "Sections encoded as uniform placeholders" }),
            .acquired_chunks = try deps.metrics.counter(.{ .name = "streaming.acquired_chunks", .description = "Chunks acquired for streaming" }),
            .encoded_bytes = try deps.metrics.counter(.{ .name = "streaming.encoded_bytes", .description = "Encoded chunk packet bytes", .unit = .bytes }),
            .encoded_packets = try deps.metrics.counter(.{ .name = "streaming.encoded_packets", .description = "Chunk packets written into reserved output storage" }),
            .light_edit_counts = .{
                .patched = try deps.metrics.counter(.{ .name = "streaming.light_edits.patched", .description = "Columns whose patched light sections were sent as they were patched" }),
                .unsent = try deps.metrics.counter(.{ .name = "streaming.light_edits.unsent", .description = "Patched columns the hand-off had no room for, which are solved instead" }),
                .unlit = try deps.metrics.counter(.{ .name = "streaming.light_edits.unlit", .description = "Columns whose stored light an edit took away" }),
                .solved = try deps.metrics.counter(.{ .name = "streaming.light_edits.solved", .description = "Light updates that needed a solve" }),
                .offered = try deps.metrics.counter(.{ .name = "streaming.light_edits.offered", .description = "Solved columns handed back to the light store" }),
            },
            .stalls = .{
                .idle = try deps.metrics.counter(.{ .name = "streaming.stalls.idle", .description = "Batches with no pending work" }),
                .epoch = try deps.metrics.counter(.{ .name = "streaming.stalls.epoch", .description = "Batches stopped by a simulation tick boundary" }),
                .candidates = try deps.metrics.counter(.{ .name = "streaming.stalls.candidates", .description = "Batches that found no deliverable column" }),
                .pool = try deps.metrics.counter(.{ .name = "streaming.stalls.pool", .description = "Batches that could not reserve shared output" }),
                .credit = try deps.metrics.counter(.{ .name = "streaming.stalls.credit", .description = "Batches whose owners lacked connection credit" }),
            },
            .deliveries = .{
                .new_columns = try deps.metrics.counter(.{ .name = "streaming.delivery.new_columns", .description = "First deliveries to a recipient" }),
                .replacements = try deps.metrics.counter(.{ .name = "streaming.delivery.replacements", .description = "Column replacements delivered to a recipient" }),
                .biome_only_replacements = try deps.metrics.counter(.{ .name = "streaming.delivery.biome_only_replacements", .description = "Column replacements without new terrain sections" }),
                .reused = try deps.metrics.counter(.{ .name = "streaming.delivery.reused", .description = "Refreshes satisfied by previously delivered terrain" }),
                .page_reservations = try deps.metrics.counter(.{ .name = "streaming.delivery.page_reservations", .description = "Columns reserving a full page because no stored record declares their size" }),
                .deferred_cold = try deps.metrics.counter(.{ .name = "streaming.delivery.deferred_cold", .description = "Cold columns deferred to a batch of their own" }),
                .outgrown_reservations = try deps.metrics.counter(.{ .name = "streaming.delivery.outgrown_reservations", .description = "Columns retried because their rebuilt packet outgrew the declared bound" }),
                .new_sections = try deps.metrics.counter(.{ .name = "streaming.delivery.new_sections", .description = "Sections first disclosed or replaced after a world edit" }),
                .repeated_sections = try deps.metrics.counter(.{ .name = "streaming.delivery.repeated_sections", .description = "Unchanged known sections repeated in column replacements" }),
                .refresh_scans = try deps.metrics.counter(.{ .name = "streaming.delivery.refresh_scans", .description = "Horizon scans after disclosure changes" }),
                .refresh_columns = try deps.metrics.counter(.{ .name = "streaming.delivery.refresh_columns", .description = "Columns reconsidered by disclosure refresh scans" }),
            },
            .lighting_duration = try deps.metrics.timer(.{ .name = "streaming.lighting", .description = "Acquire and light chunk neighborhoods" }),
            .lighting_cpu = try deps.metrics.timer(.{ .name = "streaming.lighting.cpu", .description = "CPU work acquiring and lighting chunk neighborhoods", .clock = .thread_cpu, .detailed = true }),
            .encoding_duration = try deps.metrics.timer(.{ .name = "streaming.encoding", .description = "Encode chunk packets" }),
            .publication = try deps.metrics.timer(.{ .name = "streaming.publication", .description = "Publish chunk packet batches" }),
            .cpu = .{
                .poll = try deps.metrics.timer(.{ .name = "streaming.poll.cpu", .description = "Complete chunk streaming poll", .clock = .thread_cpu }),
                .synchronization = try deps.metrics.timer(.{ .name = "streaming.synchronization.cpu", .description = "Apply simulation changes and prepare observer sources", .clock = .thread_cpu, .detailed = true }),
                .planning = try deps.metrics.timer(.{ .name = "streaming.planning.cpu", .description = "Plan chunk delivery and unloads", .clock = .thread_cpu, .detailed = true }),
                .recipients = try deps.metrics.timer(.{ .name = "streaming.recipients.cpu", .description = "Group recipients for chunk delivery", .clock = .thread_cpu, .detailed = true }),
                .geometry = try deps.metrics.timer(.{ .name = "streaming.geometry.cpu", .description = "Learn occlusion geometry from chunk snapshots", .clock = .thread_cpu, .detailed = true }),
                .visibility = try deps.metrics.timer(.{ .name = "streaming.visibility.cpu", .description = "Compute section disclosure masks", .clock = .thread_cpu, .detailed = true }),
                .encoding = try deps.metrics.timer(.{ .name = "streaming.encoding.cpu", .description = "Encode chunk packets", .clock = .thread_cpu, .detailed = true }),
                .publication = try deps.metrics.timer(.{ .name = "streaming.publication.cpu", .description = "Publish chunk packet batches", .clock = .thread_cpu, .detailed = true }),
                .completion = try deps.metrics.timer(.{ .name = "streaming.completion.cpu", .description = "Record delivery and advance streaming cursors", .clock = .thread_cpu, .detailed = true }),
                .visibility_publication = try deps.metrics.timer(.{ .name = "streaming.visibility_publication.cpu", .description = "Publish visibility to the simulation", .clock = .thread_cpu, .detailed = true }),
                .sources = try deps.metrics.timer(.{ .name = "streaming.sources.cpu", .description = "Prepare source sections and shared visibility queries", .clock = .thread_cpu, .detailed = true }),
                .metadata = try deps.metrics.timer(.{ .name = "streaming.metadata.cpu", .description = "Install baked classification results into visibility caches", .clock = .thread_cpu, .detailed = true }),
                .light_updates = try deps.metrics.timer(.{ .name = "streaming.light_updates.cpu", .description = "Deliver incremental light changes", .clock = .thread_cpu, .detailed = true }),
                .bake = try deps.metrics.timer(.{ .name = "streaming.bake.cpu", .description = "Solve and compile cold columns outside delivery", .clock = .thread_cpu, .detailed = true }),
            },
            .encoding = try chunk_encoding.Workspace.init(allocator, deps.sessions.config.page_bytes, deps.sessions.config.protocols, deps.blocks),
            .delivery = config.delivery_workspace orelse try delivery_cache.Workspace.init(allocator, deps.sessions.config.protocols.len),
            .delivery_catalog = try chunk_encoding.Workspace.initDeliveryCatalog(allocator, deps.sessions.config.protocols),
            .light_pending = try LightChanges.init(allocator, sent.len),
            .light_mail = try LightMail.create(allocator, streams.len),
            .light_resolves = try LightResolves.init(allocator, streams.len),
            .light_fresh = try allocator.alloc(bool, streams.len),
            .deps = deps,
            .chunk_client = chunk_client,
            .changed_players = try lightning_rod.system.IndexSet.init(allocator, streams.len),
            .background_players = try lightning_rod.system.IndexSet.init(allocator, streams.len),
            .occupied_players = try lightning_rod.system.IndexSet.init(allocator, streams.len),
            .urgent_waits = try allocator.alloc(?u64, streams.len),
            .setup_players = try lightning_rod.system.IndexSet.init(allocator, streams.len),
            .publication_players = try lightning_rod.system.IndexSet.init(allocator, streams.len),
            .source_players = try lightning_rod.system.IndexSet.init(allocator, streams.len),
            .observers_index = try SpatialIndex.init(allocator, streams.len),
            .generation_updates = try allocator.alloc(chunks.Generation.Update, streams.len),
            .config = config,
            .streams = streams,
            .order = try chunk_horizon.Order.init(allocator, @intCast((side - 1) / 2), deps.chunks.storageGroup(.{ .world = 0, .x = 0, .y = 0, .z = 0 }).side),
            .sources = try allocator.alloc(Source, streams.len),
            .recipients = try allocator.alloc(sessions.Handle, streams.len * batch_max),
            .tile_observers = try allocator.alloc(usize, streams.len),
            .group_window = group_window,
            .tile_watch = try chunks.Watch.init(allocator, deps.chunks, group_side * group_side * section_views.maximum_sections),
            .tile_revisions = try allocator.alloc(u64, group_side * group_side * section_views.maximum_sections),
            .sent = sent,
            .dirty_words = try .initEmpty(allocator, sent.len),
            .grid = grid,
            .visibility = .{
                .reset = try lightning_rod.system.IndexSet.init(allocator, streams.len),
                .streams = try allocator.alloc(Snapshot, streams.len),
                .sent = try allocator.alloc(u64, sent.len),
                .occluded = try allocator.dupe(u32, occluded),
                .changed = try allocator.alloc(u64, sent.len),
                .changed_words = try lightning_rod.system.IndexSet.init(allocator, sent.len),
                .grid = grid,
                .radius = deps.players.config.render_distance,
            },
        };
        for (deps.players.activeSlots()) |index| self.updateAudience(index);
        @memset(self.visibility.streams, .{});
        @memset(self.sources, .{});
        @memset(self.visibility.sent, 0);
        try deps.chunks.observe(chunks.Observer.init(self, blocksChanged));
        @memset(self.light_fresh, false);
        @memset(self.urgent_waits, null);
        // Light kept in memory scales with the player limit and with nothing else.
        try deps.lighting.includeStore(allocator, .forPlayers(deps.players.records.len));
        deps.lighting.setSink(.{ .context = self, .patched = lightPatched, .unlit = lightUnlit, .wanted = lightWanted });
        try deps.sessions.subscribeOutput(self.changed);
        try deps.chunks.subscribeReady(self.changed);
        deps.players.gateTeleports(players.Players.TeleportGate.init(Streaming, self, teleportReady));
        self.delivery_catalog.metrics = .{
            .hits = try deps.metrics.counter(.{ .name = "streaming.delivery.hits", .description = "Compiled section encodings reused" }),
            .misses = try deps.metrics.counter(.{ .name = "streaming.delivery.misses", .description = "Missing or outdated compiled encodings" }),
            .compiled_bytes = try deps.metrics.counter(.{ .name = "streaming.delivery.compiled_bytes", .description = "Derived encoding bytes compiled" }),
            .compilation = try deps.metrics.timer(.{ .name = "streaming.delivery.compilation.cpu", .description = "Compile missing section encodings", .clock = .thread_cpu, .detailed = true }),
            .transient_compiles = try deps.metrics.counter(.{ .name = "streaming.delivery.transient_compiles", .description = "Compiles from unbaked sections that cannot be stored" }),
            .unbaked_uniform = try deps.metrics.counter(.{ .name = "streaming.delivery.unbaked_uniform", .description = "Unbaked columns delivered without a record because disclosed sections are uniform" }),
        };
        return self;
    }

    pub fn prepareMetadata(allocator: std.mem.Allocator, terrain: *chunks.Chunks) !*const chunks.classification.Index {
        const properties = try section_visibility_world.World.createProperties(allocator);
        const registered = terrain.registerClassification(allocator, properties, section_visibility_world.occluder_property, section_visibility_world.prepared_codec) catch |err| {
            allocator.free(properties);
            return err;
        };
        if (registered.properties.ptr != properties.ptr) allocator.free(properties);
        return registered;
    }

    fn allocatePrepared(allocator: std.mem.Allocator) ![]chunks.classification.Prepared {
        const buffers = try allocator.alloc([section_visibility_world.prepared_codec.maximum]u8, section_visibility_world.World.batch_max);
        errdefer allocator.free(buffers);
        const prepared = try allocator.alloc(chunks.classification.Prepared, buffers.len);
        for (buffers, prepared) |*bytes, *value| value.* = .{ .bytes = bytes };
        return prepared;
    }

    pub fn close(self: *Streaming, _: *lightning_rod.Closing) void {
        self.releaseTile();
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

    pub fn debugFrontier(self: *Streaming, handle: sessions.Handle, enabled: bool) bool {
        self.published.mutex.lockUncancelable(self.native_io);
        defer self.published.mutex.unlock(self.native_io);
        if (handle.index >= self.published.views.len) return false;
        const view = &self.published.views[handle.index];
        if (!std.meta.eql(view.handle, handle)) return false;
        if (view.frontier_debug == enabled) return true;
        view.frontier_debug = enabled;
        self.published.changed_views.insert(handle.index);
        self.published.updated = true;
        self.changed.set(self.native_io);
        return true;
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
            self.deps.lighting.discardUnsettled();
            return;
        }
        // The light around each player stays in memory whatever the others do.
        self.deps.lighting.beginProtection();
        for (self.deps.players.activeSlots()) |index| {
            const view = View.capture(self.deps.players.records[index]);
            if (view.handle != null) self.deps.lighting.protect(view.world, view.center.x, view.center.z);
        }
        // Stored light is patched for the edits of this tick. The sections that changed
        // and the columns no patch could follow arrive through the sink, which puts them
        // in the published mail.
        self.deps.lighting.finishTick();
        const published = self.published;
        published.mutex.lockUncancelable(self.native_io);
        defer published.mutex.unlock(self.native_io);
        // Disk work for the light store wakes the terrain thread as well.
        var changed = self.light_mailed or !self.deps.lighting.storeIdle();
        self.light_mailed = false;
        for (self.deps.players.activeSlots()) |index| self.tracked_views.insert(index);
        var view_index: usize = 0;
        while (view_index < self.tracked_views.count) {
            const index = self.tracked_views.indices[view_index];
            const player = self.deps.players.records[index];
            const view = &published.views[index];
            if (player.handle == null) self.tracked_views.remove(index) else view_index += 1;
            var current = View.capture(player);
            current.frontier_debug = std.meta.eql(view.handle, current.handle) and view.frontier_debug;
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
        const summaries = self.encoding.summary_builds;
        const rebuilds = self.geometry.rebuilds;
        const acquisitions = self.geometry.acquisitions;
        const restored = self.geometry.restored;
        const section_resolutions = self.geometry.section_resolutions;
        const topology_reuses = self.geometry.topology_reuses;
        const topology_lookups = self.geometry.topology_lookups;
        const reused = self.geometry.unchanged;
        const evictions = self.geometry.evictions;
        const working_evictions = self.geometry.working_evictions;
        const visits = self.geometry.visits;
        const started = self.geometry.started;
        const completed = self.geometry.completed;
        const shared = self.geometry.shared;
        defer {
            self.section_builds.add(self.geometry.builds - builds);
            self.packet_summaries.add(self.encoding.summary_builds - summaries);
            self.topology.rebuilt.add(self.geometry.rebuilds - rebuilds);
            self.topology.acquired.add(self.geometry.acquisitions - acquisitions);
            self.topology.restored.add(self.geometry.restored - restored);
            self.topology.lookups.add(self.geometry.section_resolutions - section_resolutions);
            self.topology.cached_columns.add(self.geometry.topology_reuses - topology_reuses);
            self.topology.column_lookups.add(self.geometry.topology_lookups - topology_lookups);
            self.topology.reused.add(self.geometry.unchanged - reused);
            self.topology.evicted.add(self.geometry.evictions - evictions);
            self.topology.working_evicted.add(self.geometry.working_evictions - working_evictions);
            self.section_visits.add(self.geometry.visits - visits);
            self.sweeps_started.add(self.geometry.started - started);
            self.sweeps_completed.add(self.geometry.completed - completed);
            self.sweeps_shared.add(self.geometry.shared - shared);
        }
        if (!self.deps.chunks.ownsCurrentThread()) return error.InvalidChunkOwner;
        defer self.deps.sessions.retryBackground(self.epoch);
        const turn = self.config.work.maximum(1) catch unreachable;
        const progressed = try self.sendBatch(io, turn.operations);
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
            // The changes that alter occlusion come first, and only they are learned again.
            var occluding_count: usize = 0;
            if (self.geometry_revision != self.published.geometry_revision) {
                self.geometry_revision = self.published.geometry_revision;
                var changed_sections = self.published.geometry_changes.iterator();
                while (changed_sections.next()) |entry| {
                    const change: GeometryChange = .{ .section = entry.key_ptr.*, .bounds = entry.value_ptr.bounds, .occlusion = entry.value_ptr.occlusion };
                    self.geometry_changes[geometry_count] = change;
                    if (change.occlusion) {
                        std.mem.swap(GeometryChange, &self.geometry_changes[occluding_count], &self.geometry_changes[geometry_count]);
                        occluding_count += 1;
                    }
                    geometry_count += 1;
                }
                self.published.geometry_changes.clearRetainingCapacity();
                self.published.geometry_overflow = false;
            }
            self.pending = self.pending or self.published.updated;
            self.published.updated = false;
            // The mail is taken whole once the last one is dealt with, so that patches of
            // one section are sent in the order they were made.
            if (self.light_mail.empty() and !self.published.light_mail.empty()) {
                self.light_mail.clear();
                std.mem.swap(*LightMail, &self.light_mail, &self.published.light_mail);
            }
            for (self.published.light_resolves.items[0..self.published.light_resolves.count]) |entry| self.light_resolves.add(entry);
            self.published.light_resolves.count = 0;
            if (!self.pending) {
                self.published.mutex.unlock(self.native_io);
                self.stalls.idle.add(1);
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
                self.setup_players.insert(index);
                self.publication_players.insert(index);
            }
            self.published.changed_views.clear();
            self.published.mutex.unlock(self.native_io);
            if (geometry_overflow) {
                self.geometry.invalidate();
            } else for (self.geometry_changes[0..geometry_count]) |change| {
                const section = change.section;
                const dimension = self.deps.worlds.get(section.world).?.dimension;
                // With occlusion the section is learned again below, and only a change in what
                // it occludes costs anyone a new sweep.
                if (change.occlusion) self.geometry.changed(section.world, dimension.minimumSection(), change.bounds, self.config.occlusion);
                const offset = section.y - dimension.minimumSection();
                if (offset < 0 or offset >= dimension.sectionCount()) continue;
                var nearby = self.observers_index.query(.{ .world = section.world, .x = section.x, .z = section.z }, self.deliveryRadius() + 1);
                while (nearby.next()) |index| {
                    if (self.views[index].world != section.world) continue;
                    // A player who just changed world still has the stream of the old one
                    // until it is unloaded. Its columns and its height are not this world's.
                    const stream = self.streams[index];
                    const handle = self.views[index].handle orelse continue;
                    if (stream.generation != handle.generation or stream.life != self.views[index].life) continue;
                    if (stream.minimum_section != dimension.minimumSection() or stream.section_count != dimension.sectionCount()) continue;
                    if (!chunk_horizon.contains(self.deliveryRadius(), stream.center, .{ .x = section.x, .z = section.z })) continue;
                    // Visible edits arrive as deltas. Concealed edits invalidate retained terrain.
                    if (!self.sectionVisible(index, section)) self.invalidateSection(index, section);
                }
                self.forgetKept(section);
            }
            if (geometry_overflow) {
                @memset(self.stale, std.math.maxInt(u32));
                @memset(self.occluded, std.math.maxInt(u32));
                self.dirty_words.setRangeValue(.{ .start = 0, .end = self.sent.len }, true);
                for (self.background_players.values()) |index| {
                    self.occupied_players.insert(index);
                    // Nobody knows which sections changed, so every column a player holds is
                    // looked at again. A player whose visibility has to be solved first gets
                    // the same full pass when it is ready, as on a first view.
                    self.streams[index].visibility_revision = 0;
                    if (self.streams[index].setup == .streaming) self.refreshReady(index);
                }
            }
            if (self.config.occlusion and !geometry_overflow and occluding_count != 0) {
                var window = chunks.ReadWindow(section_visibility_world.World.batch_max).init(self.chunk_client);
                defer window.deinit();
                var views: [192]chunks.View = undefined;
                var begin: usize = 0;
                while (begin < occluding_count) {
                    const count = @min(occluding_count - begin, views.len, self.chunk_client.budget());
                    var sections: [192]chunks.Section = undefined;
                    // A column the geometry holds no tile for is learned when a view needs it,
                    // from the blocks as they are then, so learning it now would be wasted.
                    var held: usize = 0;
                    for (self.geometry_changes[begin..][0..count]) |change| {
                        const minimum = self.deps.worlds.get(change.section.world).?.dimension.minimumSection();
                        if (!self.geometry.holds(.{ .world = change.section.world, .x = change.section.x, .z = change.section.z, .minimum = minimum })) continue;
                        sections[held] = change.section;
                        held += 1;
                    }
                    begin += count;
                    if (held == 0) continue;
                    try window.readMany(sections[0..held], views[0..held]);
                    for (sections[0..held], views[0..held]) |section, view| {
                        const dimension = self.deps.worlds.get(section.world).?.dimension;
                        const offset = section.y - dimension.minimumSection();
                        if (offset < 0 or offset >= dimension.sectionCount()) continue;
                        self.geometry.learnSection(.{ .world = section.world, .x = section.x, .z = section.z, .minimum = dimension.minimumSection() }, dimension.sectionCount(), @intCast(offset), .fromChunk(view));
                    }
                }
            }
            // What could not be compared on relearn invalidates the views that may see it.
            self.geometry.settleChanges();
            if (occluding_count != 0 or geometry_overflow) {
                for (self.background_players.values()) |index| {
                    const view = self.views[index];
                    const source = &self.sources[index];
                    var source_changed = geometry_overflow;
                    if (source.origin) |origin| {
                        const bounds = origin.bounds();
                        for (self.geometry_changes[0..occluding_count]) |change| {
                            if (change.section.world != view.world) continue;
                            var touches = true;
                            for (0..3) |axis| touches = touches and change.bounds.minimum[axis] < bounds.maximum[axis] and change.bounds.maximum[axis] > bounds.minimum[axis];
                            source_changed = source_changed or touches;
                        }
                    }
                    if (source_changed) self.refresh(index, true);
                    if (self.needsSource(index)) self.source_players.insert(index);
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
        if (self.epoch != self.deps.sessions.backgroundEpoch() or self.epoch & 1 != 0) {
            self.stalls.epoch.add(1);
            return false;
        }
        // A stopping service accepts no output, so baking or planning for it would be wasted.
        if (self.deps.sessions.stopped()) return false;
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
        // Baked records turn queued cold columns into hits. Queued columns are skipped during
        // selection, so baking cannot wait for a batch that selected something. A column whose
        // inputs are still loading is not progress: its loads wake the thread when they land,
        // and asking again before then spins without letting them finish.
        if (self.cold_count != 0) progressed = try self.bakeCold();
        self.passes += 1;
        for (self.urgent_waits, 0..) |*waited, index| {
            const since = waited.* orelse continue;
            if (self.passes - since < urgent_retry_passes) continue;
            waited.* = null;
            if (self.occupiedColumn(index) != null) self.occupied_players.insert(index);
        }
        // Any cursor with columns left keeps the stream pending. A wake that returns credit or
        // output must resume delivery instead of waiting for the next simulation publication.
        self.pending = false;
        for (self.background_players.values()) |index| {
            const view = self.views[index];
            const stream = self.streams[index];
            if (view.handle == null or !view.ready or stream.setup != .streaming) continue;
            if (stream.cursor < side * side) self.pending = true;
        }
        {
            const cpu = self.cpu.planning.start();
            defer cpu.end();
            var setup_cursor: usize = 0;
            while (setup_cursor < self.setup_players.count) {
                const index = self.setup_players.indices[setup_cursor];
                const player = &self.views[index];
                const stream = &self.streams[index];
                const handle = player.handle orelse {
                    self.setup_players.remove(index);
                    continue;
                };
                if (!player.ready) {
                    self.setup_players.remove(index);
                    continue;
                }
                setup_cursor += 1;
                self.publication_players.insert(index);
                if (self.needsSource(index)) {
                    self.pending = true;
                }

                const center = player.center;

                if (stream.generation != handle.generation or stream.life != player.life) {
                    const dimension = self.deps.worlds.get(player.world).?.dimension;
                    stream.* = .{ .generation = handle.generation, .life = player.life, .center = center, .target = center, .minimum_section = dimension.minimumSection(), .section_count = dimension.sectionCount(), .debug_history = player.frontier_debug };
                    const columns = self.grid.columns;
                    @memset(self.occluded[index * columns ..][0..columns], std.math.maxInt(u32));
                    @memset(self.stale[index * columns ..][0..columns], 0);
                    @memset(self.disclosed[index * columns ..][0..columns], 0);
                    @memset(self.painted[index * columns ..][0..columns], 0);
                    @memset(self.refresh_bits[index * self.grid.words ..][0..self.grid.words], 0);
                    @memset(self.sent[index * self.grid.words ..][0..self.grid.words], 0);
                    @memset(self.biome_disclosed[index * columns ..][0..columns], 0);
                    self.light_receipts.reset(index * columns, columns);
                    self.refreshReady(index);
                    self.dirty_words.setRangeValue(.{ .start = index * self.grid.words, .end = (index + 1) * self.grid.words }, true);
                }

                self.pending = self.pending or stream.setup != .streaming or stream.cursor < side * side or
                    self.needsSource(index) or !std.meta.eql(center, stream.center) or (!stream.announced and player.placed);
                if (!service.canSend(handle, 1) and (stream.setup != .streaming or !std.meta.eql(center, stream.center))) continue;

                if (stream.setup == .streaming and !std.meta.eql(center, stream.center)) {
                    stream.target = center;
                    // Columns stay loaded until they leave the client storage, not the delivery radius.
                    stream.departing = .init(stream.center, center, self.keepRadius());
                    stream.setup = .unloading;
                }

                if (stream.setup == .unloading) {
                    var search = stream.departing;
                    var departing = false;
                    while (search.next()) |at| {
                        if (self.hasSent(index, at)) {
                            departing = true;
                            break;
                        }
                        stream.departing = search;
                    }

                    if (!departing) {
                        self.moveCenter(index, stream.target);
                        self.updateAudience(index);
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
                    const bytes = try self.deps.packets.writePacket(writeViewCenter, player.protocol, packet.bytes, .{stream.center});
                    packet.publish(bytes.len, &.{handle}) catch |err| switch (err) {
                        error.Backpressured, error.Closed => continue,
                        else => return err,
                    };
                    stream.setup = .streaming;
                    self.publication_players.insert(index);
                    progressed = true;
                    setup_progress = true;
                    continue;
                }
                if (!stream.announced and player.placed) {
                    var packet = service.reserveBackground(64, self.epoch) catch |err| switch (err) {
                        error.Backpressured => continue,
                        error.Closed => return false,
                        else => return err,
                    };
                    defer packet.cancel();
                    const bytes = try self.deps.packets.writePacket(writeTerrainReady, player.protocol, packet.bytes, .{});
                    packet.publish(bytes.len, &.{handle}) catch |err| switch (err) {
                        error.Backpressured, error.Closed => continue,
                        else => return err,
                    };
                    stream.announced = true;
                    progressed = true;
                    setup_progress = true;
                }
                assert(std.meta.eql(center, stream.center));
                self.setup_players.remove(index);
                setup_cursor -= 1;
            }
            self.pending = self.pending or self.setup_players.count != 0 or self.source_players.count != 0;
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
                self.next_occupied_player = (position + 1) % self.occupied_players.count;
                selected = .{ .at = column.at, .world = column.world, .protocol = self.views[index].protocol, .owner = index };
                break;
            }
            if (self.tile != null and !self.tile_watch.unchanged()) self.releaseTile();
            if (selected == null and !setup_progress) try self.prepareSources(batch_limit);
            if (selected == null) selected = self.nextTileColumn();
            if (self.tile == null and !setup_progress) {
                for (0..self.background_players.count) |offset| {
                    const position = (self.next_player + offset) % self.background_players.count;
                    const index = self.background_players.indices[position];
                    const stream = self.streams[index];
                    if (stream.cursor == side * side) continue;
                    // Remaining columns stay pending while credit or output is exhausted, so the
                    // wake that returns them resumes delivery instead of waiting for the next tick.
                    self.pending = true;
                    const column: DeliveryColumn = .{ .world = self.views[index].world, .at = self.order.at(stream.center, stream.cursor) };
                    if (!self.canDeliverColumn(index, column)) continue;
                    self.beginTile(column);
                    self.next_player = (position + 1) % self.background_players.count;
                    if (selected == null) selected = self.nextTileColumn();
                    break;
                }
            }
            if (selected) |first| {
                pending[0] = first;
                count = 1;
                var planned_states: [batch_max]?DisclosureState = @splat(null);
                var nearby = self.candidateObservers(first.world, first.at);
                while (nearby.next()) |index| {
                    if (count == batch_limit) break;
                    const column: DeliveryColumn = .{ .world = first.world, .at = first.at };
                    if (!self.canDeliverColumn(index, column)) continue;
                    if (index == first.owner) continue;
                    const player = self.views[index];
                    const candidate_state = self.disclosureState(index, first.at);
                    var duplicate = false;
                    for (pending[0..count], planned_states[0..count]) |item, *state| {
                        if (!self.sameChunkFamily(item.protocol, player.protocol)) continue;
                        if (state.* == null) state.* = self.disclosureState(item.owner, first.at);
                        if (std.meta.eql(state.*.?, candidate_state)) {
                            duplicate = true;
                            break;
                        }
                    }
                    if (duplicate) continue;
                    pending[count] = .{ .at = first.at, .world = first.world, .protocol = player.protocol, .owner = index };
                    planned_states[count] = candidate_state;
                    count += 1;
                }
                if (self.tile) |tile| {
                    for (0..tile.columns()) |offset| {
                        if (count == batch_limit) break;
                        const at = tile.at((tile.cursor + offset) % tile.columns());
                        var duplicate = false;
                        for (pending[0..count]) |item| duplicate = duplicate or (item.world == tile.world and std.meta.eql(item.at, at));
                        if (duplicate) continue;
                        const candidate = self.tileColumn(at) orelse continue;
                        pending[count] = candidate;
                        count += 1;
                    }
                }
                self.pending = true;
            }
            var urgent_remaining = self.occupied_players.count;
            while (selected != null and count < batch_limit and urgent_remaining != 0) : (urgent_remaining -= 1) {
                const position = self.next_occupied_player % self.occupied_players.count;
                const index = self.occupied_players.indices[position];
                self.next_occupied_player = (position + 1) % self.occupied_players.count;
                const column = self.occupiedColumn(index) orelse continue;
                if (!self.canDeliverColumn(index, column)) continue;
                const candidate: Pending = .{ .at = column.at, .world = column.world, .protocol = self.views[index].protocol, .owner = index };
                var duplicate = false;
                for (pending[0..count]) |item| duplicate = duplicate or (item.world == candidate.world and self.sameChunkFamily(item.protocol, candidate.protocol) and std.meta.eql(item.at, candidate.at) and self.sameDisclosure(item.owner, candidate.owner, candidate.at));
                if (duplicate) continue;
                pending[count] = candidate;
                count += 1;
            }
            if (selected != null and count < batch_limit and self.background_players.count != 0) {
                const cohort = @min(4, @max(1, batch_limit / 2));
                const rounds = (batch_limit + cohort - 1) / cohort;
                for (0..rounds) |_| {
                    if (count == batch_limit) break;
                    const first_player = self.next_player;
                    for (0..self.background_players.count) |offset| {
                        if (count == batch_limit) break;
                        const position = (first_player + offset) % self.background_players.count;
                        const index = self.background_players.indices[position];
                        const view = self.views[index];
                        const handle = view.handle orelse continue;
                        const stream = self.streams[index];
                        if (!view.ready or stream.generation != handle.generation or stream.life != view.life or stream.setup != .streaming or stream.cursor == side * side) continue;
                        const bits = self.refresh_bits[index * self.grid.words ..][0..self.grid.words];
                        var rank = stream.cursor;
                        var inspected: usize = 0;
                        var added: usize = 0;
                        while (rank < side * side and inspected < batch_limit and added < cohort and count < batch_limit) {
                            const word = rank / 64;
                            const available = bits[word] & (@as(u64, std.math.maxInt(u64)) << @as(u6, @intCast(rank % 64)));
                            if (available == 0) {
                                rank = @min(side * side, (word + 1) * 64);
                                continue;
                            }
                            rank = word * 64 + @as(usize, @ctz(available));
                            if (rank >= side * side) break;
                            const at = self.order.at(stream.center, rank);
                            rank += 1;
                            inspected += 1;
                            const candidate: Pending = .{ .world = self.views[index].world, .at = at, .owner = index, .protocol = self.views[index].protocol };
                            var duplicate = false;
                            for (pending[0..count]) |item| {
                                if (item.world != candidate.world or !self.sameChunkFamily(item.protocol, candidate.protocol) or !std.meta.eql(item.at, at)) continue;
                                if (self.sameDisclosure(item.owner, index, at)) duplicate = true;
                            }
                            if (duplicate or !self.canDeliverColumn(index, .{ .world = candidate.world, .at = at })) continue;
                            pending[count] = candidate;
                            count += 1;
                            added += 1;
                        }
                        if (added != 0) self.next_player = (position + 1) % self.background_players.count;
                    }
                }
            }
        }
        if (count == 0) {
            self.stalls.candidates.add(1);
            return progressed;
        }
        if (service.backgroundEpoch() != self.epoch) {
            self.stalls.epoch.add(1);
            return progressed;
        }
        var needing_data: usize = 0;
        for (pending[0..count]) |candidate| {
            var item = candidate;
            const owner = item.owner;
            const handle = self.views[owner].handle.?;
            const dimension = self.deps.worlds.get(item.world).?.dimension;
            const column: section_visibility_world.Column = .{ .world = item.world, .x = item.at.x, .z = item.at.z, .minimum = dimension.minimumSection() };
            const query = if (self.hasSent(owner, item.at)) self.columnView(owner, item.at) else null;
            if (query) |ready_query| {
                const mask = self.sectionMask(owner, column, dimension.sectionCount(), ready_query);
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
        // Columns beyond what the shared output pool can hold would be read and decoded
        // only to be dropped at the reservation below. Each is tried at the size of the
        // last reservation made for its player, since its own bound is in the record
        // that has not been read yet.
        var estimates: [batch_max]usize = undefined;
        for (pending[0..count], estimates[0..count]) |item, *estimate| {
            // A player nothing was reserved for yet is tried at what stored columns have
            // been declaring. A whole page for each would need a run of free units that
            // a busy pool never has, and new players would wait behind everyone else.
            const last = self.streams[item.owner].reserve_bytes;
            estimate.* = @min(if (last == 0) self.reserve_typical else last, service.config.page_bytes);
        }
        count = service.outputFit(estimates[0..count]);
        if (count == 0) {
            self.stalls.pool.add(1);
            return progressed;
        }
        // Stored records are read before output is reserved, so each column reserves the bound
        // its record declares. A full page per column let one batch claim the whole shared pool
        // and hold it through lighting and encoding while packets of 3 KB were in flight.
        var delivery_requests: [batch_max]delivery_cache.Request = undefined;
        for (pending[0..count], delivery_requests[0..count]) |item, *request| request.* = .{ .column = .{ .world = item.world, .x = item.at.x, .z = item.at.z }, .protocol = item.protocol };
        const cache_read = try self.delivery.begin(&self.delivery_catalog, delivery_requests[0..count]);
        defer self.delivery.cancel();
        {
            const cpu = self.lighting_cpu.start();
            defer cpu.end();
            var deliveries: [batch_max]lighting.Lighting.Delivery = undefined;
            var distinct: usize = 0;
            for (pending[0..count]) |item| {
                const dimension = self.deps.worlds.get(item.world).?.dimension;
                const column: section_visibility_world.Column = .{ .world = item.world, .x = item.at.x, .z = item.at.z, .minimum = dimension.minimumSection() };
                const slot = self.columnIndex(item.owner, item.at);
                const selection = self.disclosureMasks(item.owner, column, dimension.sectionCount()).disclosure | (self.disclosed[slot] & ~self.stale[slot]);
                var duplicate: ?usize = null;
                for (deliveries[0..distinct], 0..) |delivery, index| if (delivery.world == item.world and delivery.x == item.at.x and delivery.z == item.at.z) {
                    duplicate = index;
                    break;
                };
                if (duplicate) |index| {
                    deliveries[index].selection |= selection;
                    continue;
                }
                deliveries[distinct] = .{ .world = item.world, .x = item.at.x, .z = item.at.z, .dimension = dimension, .selection = selection };
                distinct += 1;
            }
            try self.deps.lighting.prepareDeliveries(deliveries[0..distinct], cache_read);
        }
        // A column without stored light needs a neighbourhood solve, and the batch stops before
        // that solve so ready packets publish first. Mixed into a batch, it discarded the
        // neighbourhood and every frame read after it, so cold columns leave the batch.
        var stored_count: usize = 0;
        // A cold column a player occupies is solved inline ahead of everything else, since the
        // client cannot collide with terrain it does not have.
        var urgent: ?Pending = null;
        for (pending[0..count]) |item| {
            const stored = self.deps.lighting.deliveryStored(item.world, item.at.x, item.at.z);
            stored_count += @intFromBool(stored);
            if (stored or urgent != null) continue;
            const dimension = self.deps.worlds.get(item.world).?.dimension;
            const column: section_visibility_world.Column = .{ .world = item.world, .x = item.at.x, .z = item.at.z, .minimum = dimension.minimumSection() };
            // A dirty or generating neighbourhood cannot be stored, so baking it would be wasted.
            const clean = self.deps.chunks.lightClean(.{ .world = item.world, .x = item.at.x, .z = item.at.z }, dimension.minimumSection(), dimension.sectionCount());
            if (!clean or self.unstorablePending(item.world, item.at) or self.missingSections(item.owner, item.at, self.collisionMask(item.owner, column, dimension.sectionCount())) != 0) urgent = item;
        }
        if (urgent != null and stored_count != 0 and !self.urgent_deferred) {
            // The stored columns of this batch were read and decoded already. They go out
            // first, and the urgent column leads the batch after. It waits one batch at most.
            self.urgent_deferred = true;
            var kept: usize = 0;
            for (pending[0..count]) |item| {
                if (!self.deps.lighting.deliveryStored(item.world, item.at.x, item.at.z)) continue;
                pending[kept] = item;
                kept += 1;
            }
            assert(kept == stored_count);
            self.deliveries.deferred_cold.add(count - kept);
            count = kept;
        } else if (urgent) |first| {
            self.urgent_deferred = false;
            self.clearUnstorable(first.world, first.at);
            // The urgent column gets the batch to itself. The rest return through selection.
            var kept: usize = 0;
            for (pending[0..count]) |item| {
                if (item.world != first.world or !std.meta.eql(item.at, first.at)) continue;
                pending[kept] = item;
                kept += 1;
            }
            assert(kept > 0 and kept <= count);
            self.deliveries.deferred_cold.add(count - kept);
            count = kept;
        } else if (stored_count != count) {
            // Storable cold columns wait for the baker, which takes the queued column nearest
            // its last solve. Solving one inline here would start a fresh neighbourhood.
            var kept: usize = 0;
            for (pending[0..count]) |item| {
                if (!self.deps.lighting.deliveryStored(item.world, item.at.x, item.at.z)) {
                    self.queueCold(item);
                    continue;
                }
                pending[kept] = item;
                kept += 1;
            }
            assert(kept == stored_count);
            self.deliveries.deferred_cold.add(count - kept);
            count = kept;
            // A batch of only cold columns still made progress when it queued work for the baker.
            if (count == 0) return true;
        }
        var reservation_sizes: [batch_max]usize = undefined;
        for (pending[0..count], reservation_sizes[0..count]) |item, *size| {
            // A stored frame declares the bound of the saved blocks it was baked from. A column
            // built from live sections can be larger, and its packet is stored nowhere, so
            // a retry would read the same bound again. It gets a whole page.
            const stored = self.deps.lighting.deliveryStored(item.world, item.at.x, item.at.z);
            const frame = if (stored) self.delivery.storedFrame(.{ .world = item.world, .x = item.at.x, .z = item.at.z }) else null;
            const record = if (frame) |bytes| self.encoding.frameBound(bytes) else null;
            // Frames bound their terrain without light, which changes after they are kept, so
            // the reservation adds the most light a column of this height carries.
            const sections = self.deps.worlds.get(item.world).?.dimension.sectionCount();
            const declared = if (record) |bound| bound + lighting.Data.maximumEncodedSize(@intCast(sections)) else null;
            if (declared) |bound| self.reserve_typical = @min(bound, service.config.page_bytes);
            if (declared == null) self.deliveries.page_reservations.add(1);
            size.* = @min(service.config.page_bytes, declared orelse service.config.page_bytes);
            assert(size.* > 0);
        }
        reserved = service.reserveBatch(reservation_sizes[0..count], reservations[0..count]) catch |err| switch (err) {
            error.Closed => return progressed,
            else => return err,
        };
        for (reservations[0..reserved]) |*packet| packet.epoch = self.epoch;
        if (reserved == 0) {
            self.stalls.pool.add(1);
            return progressed;
        }
        var owners: [batch_max]sessions.Handle = undefined;
        for (pending[0..reserved], owners[0..reserved]) |item, *owner| owner.* = self.views[item.owner].handle.?;
        var credit = service.reserveRecipients(reservations[0..reserved], owners[0..reserved]);
        defer credit.release();
        var ready_count: usize = 0;
        for (0..reserved) |index| {
            if (!credit.canWrite(&reservations[index], owners[index])) {
                // The player is passed over until its connection has taken this much.
                self.streams[pending[index].owner].reserve_bytes = reservations[index].bytes.len;
                reservations[index].cancel();
                continue;
            }
            pending[ready_count] = pending[index];
            if (ready_count != index) {
                reservations[ready_count] = reservations[index];
                reservations[index].reservation = null;
                reservations[index].credit = null;
            }
            ready_count += 1;
        }
        reserved = ready_count;
        count = ready_count;
        if (count == 0) {
            self.stalls.credit.add(1);
            self.releaseTile();
            return progressed;
        }
        const last_owner = pending[count - 1].owner;
        assert(self.background_players.contains(last_owner));
        self.next_player = (self.background_players.positions[last_owner] + 1) % self.background_players.count;

        var publications: [batch_max]sessions.Service.Publication = undefined;
        var accepted: [batch_max]usize = undefined;
        var encoded_count: usize = 0;
        var encoded_slots: [batch_max]bool = @splat(false);
        var encoded_indices: [batch_max]usize = undefined;
        var light_updates: [batch_max]lighting.Receipt.Update = undefined;
        var recipient_counts: [batch_max]usize = undefined;
        {
            const cpu = self.cpu.recipients.start();
            defer cpu.end();
            self.planRecipients(pending[0..count], recipient_counts[0..count]);
        }
        columns: for (pending[0..count], recipient_counts[0..count], 0..) |*item, recipient_count, i| {
            if (encoded_count == reserved) break;
            const packet = &reservations[i];
            if (credit.available(self.views[item.owner].handle.?) < service.framedBound(1)) continue;
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
            if (service.backgroundEpoch() != self.epoch) {
                break;
            }
            switch (ready) {
                .ready => {},
                .pending => {
                    // Pending generation must not monopolize the urgent delivery lane.
                    self.occupied_players.remove(item.owner);
                    self.urgent_waits[item.owner] = self.passes;
                    continue;
                },
                .deferred => continue,
            }
            const needs_light = !self.deps.lighting.delivery_prepared;
            // Commit ready packets before a cold lighting solve can cross a tick boundary.
            if (needs_light and encoded_count != 0) break;
            {
                const cpu = self.cpu.geometry.start();
                defer cpu.end();
                if (self.config.occlusion) {
                    var learned = false;
                    if (self.deps.lighting.deliveryFrame()) |frame| if (frame.metadata) |metadata| {
                        assert(std.mem.eql(u8, &metadata.identity, &self.classification.identity));
                        learned = try self.geometry.learnPreparedColumn(column, dimension.sectionCount(), metadata.bytes);
                    };
                    if (!learned) self.geometry.learnConstants(column, self.deps.lighting.deliveryMetadata());
                }
            }
            assert(recipients != 0 and targets[0].index == item.owner);
            var matching: usize = 1;
            var owner_state: ?DisclosureState = null;
            for (targets[1..recipients]) |handle| {
                if (owner_state == null) owner_state = self.disclosureState(item.owner, item.at);
                if (!std.meta.eql(owner_state.?, self.disclosureState(handle.index, item.at))) continue;
                targets[matching] = handle;
                matching += 1;
            }
            recipients = matching;
            const candidate = if (owner_state) |state| state.masks else self.disclosureMasks(item.owner, column, dimension.sectionCount());
            // Publish authority only after any newly disclosed terrain has been delivered.
            item.visibility = candidate.visibility;
            item.frontier = self.frontierMask(item.owner, item.at);
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
                self.finishRefresh(item, targets[0..recipients]);
                progressed = true;
                continue;
            }
            const slot = self.columnIndex(item.owner, item.at);
            // Retain known terrain without granting authority to observe its current activity.
            if (!self.views[item.owner].frontier_debug) {
                const painted = if (self.streams[item.owner].debug_history) self.painted[slot] else 0;
                item.disclosure |= self.disclosed[slot] & ~(self.stale[slot] | painted);
            }
            item.biome_disclosure |= self.biome_disclosed[slot] & ~self.stale[slot];
            {
                const timing = self.lighting_duration.start();
                defer timing.end();
                const cpu = self.lighting_cpu.start();
                defer cpu.end();
                const sections_ready = self.deps.lighting.validateDelivery();
                if (service.backgroundEpoch() != self.epoch) {
                    break;
                }
                if (!sections_ready) {
                    self.occupied_players.remove(item.owner);
                    self.urgent_waits[item.owner] = self.passes;
                    continue;
                }
            }
            const stone = self.geometry.stoneMask(column, dimension.sectionCount());
            {
                const timing = self.lighting_duration.start();
                defer timing.end();
                const cpu = self.lighting_cpu.start();
                defer cpu.end();
                const all = (@as(u32, 1) << @intCast(dimension.sectionCount())) - 1;
                if (self.deps.lighting.deliveryCoverage() != all) {
                    var selection = item.disclosure;
                    var nearby = self.candidateObservers(item.world, item.at);
                    while (nearby.next()) |index| {
                        if (!self.canDeliverColumn(index, .{ .world = item.world, .at = item.at })) continue;
                        const desired = self.disclosureMasks(index, column, dimension.sectionCount()).disclosure;
                        const retained = self.columnIndex(index, item.at);
                        selection |= desired | (self.disclosed[retained] & ~self.stale[retained]);
                    }
                    try self.deps.lighting.lightDelivery(selection & all & ~stone);
                } else try self.deps.lighting.lightDelivery(all);
                assert(item.disclosure & ((@as(u32, 1) << @intCast(dimension.sectionCount())) - 1) & ~stone & ~self.deps.lighting.deliveryCoverage() == 0);
            }
            if (service.backgroundEpoch() != self.epoch) {
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
                const biome_source = self.deps.lighting.deliveryBiomes(self.biome_sections[0 .. 9 * dimension.sectionCount()]);
                const available = biome_source.available(dimension.sectionCount());
                item.biome = disclosedBiome(biome_source, dimension.sectionCount(), item.biome_disclosure & available[4]);
                const neighbors: chunk_encoding.BiomeNeighborhood = .{
                    .source = biome_source,
                    .count = dimension.sectionCount(),
                    .disclosed = self.biomeMasks(item.owner, item.at, item.biome_disclosure, &available),
                };
                const sample = item.biome orelse neighbors.first();
                const biome = self.coverBiome(item.owner, sample);
                if (recipients > 1 and item.biome_disclosure != (@as(u32, 1) << @intCast(dimension.sectionCount())) - 1) {
                    matching = 1;
                    for (targets[1..recipients]) |handle| {
                        const masks = self.biomeMasks(handle.index, item.at, item.biome_disclosure, &available);
                        if (!std.mem.eql(u32, &masks, &neighbors.disclosed)) continue;
                        const other = self.coverBiome(handle.index, sample);
                        if (other != biome) continue;
                        targets[matching] = handle;
                        matching += 1;
                    }
                    recipients = matching;
                    assert(recipients != 0 and targets[0].index == item.owner);
                }
                light_updates[i] = self.retainLight(item.at, targets[0..recipients], &light);
                const chunk: chunk_encoding.Chunk = .{
                    .world = item.world,
                    .x = item.at.x,
                    .z = item.at.z,
                    .sections = self.deps.lighting.deliveryTerrain(item.disclosure),
                    .biome = biome,
                    .minimum_section = dimension.minimumSection(),
                    .workspace = self.encoding,
                    .light = light,
                    .disclosure = item.disclosure,
                    .biome_disclosure = item.biome_disclosure,
                    .biome_neighbors = if (self.config.occlusion) &neighbors else null,
                    .concealment = 0,
                    .frontier = item.frontier,
                };
                const definition = try self.deps.packets.definition(item.protocol);
                const prepared = self.encoding.prepareDelivery(self.delivery, chunk, item.protocol) catch |err| switch (err) {
                    error.DeliveryDeferred => continue :columns,
                    else => return err,
                };
                // A stale record can rebuild into a larger packet than the bound reserved from it.
                // The rebuilt record is stored at batch end, so the retry reserves its new bound.
                if (prepared.maximumSize() > packet.bytes.len) {
                    self.deliveries.outgrown_reservations.add(1);
                    continue :columns;
                }
                packet.limit(prepared.maximumSize());
                self.streams[item.owner].reserve_bytes = packet.bytes.len;
                if (!credit.canWrite(packet, self.views[item.owner].handle.?)) continue :columns;
                break :encode try prepared.writePacket(self.deps.packets, item.protocol, packet, definition);
            };
            credit.finish(packet, self.views[item.owner].handle.?, encoded.len);
            self.concealed_sections.add(@popCount(~item.disclosure & ((@as(u32, 1) << @intCast(dimension.sectionCount())) - 1)));
            self.encoded_bytes.add(encoded.len);
            self.encoded_packets.add(1);
            encoded_indices[encoded_count] = i;
            encoded_slots[i] = true;
            publications[encoded_count] = .{ .packet = packet, .length = encoded.len, .recipients = targets[0..recipients] };
            encoded_count += 1;
            if (service.backgroundEpoch() != self.epoch) {
                self.next_player = self.background_players.positions[item.owner];
                break;
            }
            if (needs_light) break;
        }
        for (reservations[0..reserved], encoded_slots[0..reserved]) |*packet, encoded| if (!encoded) packet.cancel();
        credit.release();
        {
            const publication = self.publication.start();
            defer publication.end();
            const cpu = self.cpu.publication.start();
            defer cpu.end();
            service.publishManyReady(publications[0..encoded_count], accepted[0..encoded_count]);
        }
        released = reserved;
        const completion = self.cpu.completion.start();
        defer completion.end();
        for (encoded_indices[0..encoded_count], publications[0..encoded_count], accepted[0..encoded_count]) |item_index, publication, admitted| {
            const item = &pending[item_index];
            if (admitted != 0 and self.occupied_players.contains(item.owner)) {
                const position = self.occupied_players.positions[item.owner];
                assert(position < self.occupied_players.count and self.occupied_players.indices[position] == item.owner);
                self.next_occupied_player = (position + 1) % self.occupied_players.count;
            }
            if (admitted != 0) {
                assert(self.background_players.contains(item.owner));
                self.next_player = (self.background_players.positions[item.owner] + 1) % self.background_players.count;
            }
            for (publication.recipients[0..admitted]) |handle| {
                assert(self.streams[handle.index].delivered != 0 or std.meta.eql(item.at, self.streams[handle.index].center));
                if (self.sources[handle.index].biome == null) self.sources[handle.index].biome = item.biome;
                const was_sent = self.hasSent(handle.index, item.at);
                const slot = self.columnIndex(handle.index, item.at);
                if (was_sent) self.deliveries.replacements.add(1) else self.deliveries.new_columns.add(1);
                const known = if (was_sent) self.disclosed[slot] & ~self.stale[slot] else 0;
                const valid = (@as(u32, 1) << @intCast(self.streams[handle.index].section_count)) - 1;
                if (was_sent and item.disclosure & valid & ~known == 0 and item.biome_disclosure & ~self.biome_disclosed[slot] != 0) self.deliveries.biome_only_replacements.add(1);
                self.deliveries.new_sections.add(@popCount(item.disclosure & valid & ~known));
                self.deliveries.repeated_sections.add(@popCount(item.disclosure & valid & known));
                self.biome_disclosed[slot] = item.biome_disclosure;
                self.light_receipts.apply(slot, light_updates[item_index]);
                const painted = if (self.streams[handle.index].debug_history) self.painted[slot] else 0;
                assert(self.views[handle.index].frontier_debug or self.disclosed[slot] & ~(self.stale[slot] | painted) & ~item.disclosure == 0);
                self.occluded[slot] = (~item.visibility | item.frontier) & ((@as(u32, 1) << @intCast(self.deps.worlds.get(item.world).?.dimension.sectionCount())) - 1);
                if (self.streams[handle.index].debug_history) self.painted[slot] = item.frontier;
                self.stale[slot] = 0;
                self.disclosed[slot] = item.disclosure & ((@as(u32, 1) << @intCast(self.streams[handle.index].section_count)) - 1);
                self.column_deliveries[slot] +%= 1;
                self.clearRefresh(handle.index, item.at);
                self.markSent(handle.index, item.at, true);
                const stream = &self.streams[handle.index];
                stream.delivered += @intFromBool(!was_sent);
                self.publication_players.insert(handle.index);
                self.advanceCursor(handle.index);
            }

            progressed = progressed or admitted != 0;
        }

        assert(released == reserved);
        assert(encoded_count <= reserved and reserved <= count);
        assert(count <= maximum_items);
        if (encoded_count == 0) self.releaseTile();
        try self.delivery.finish(self.deps.chunks);
        return progressed;
    }

    /// Queued columns wait for their stored record instead of being read every batch.
    fn coldPending(self: *const Streaming, world: u32, at: Position) bool {
        for (self.cold[0..self.cold_count]) |queued| {
            if (queued.world == world and std.meta.eql(queued.at, at)) return true;
        }
        return false;
    }

    fn nearestCold(cold: []const Cold, last: ?lighting.Workspace.Region) usize {
        assert(cold.len > 0);
        const previous = last orelse return 0;
        var best: usize = 0;
        var best_distance: u64 = std.math.maxInt(u64);
        for (cold, 0..) |entry, index| {
            if (entry.world != previous.world) continue;
            const dx = @abs(@as(i64, entry.at.x) - previous.x);
            const dz = @abs(@as(i64, entry.at.z) - previous.z);
            // A diagonal step brings five new columns into the neighbourhood, a straight one three.
            const distance = @max(dx, dz) * 2 + @intFromBool(dx != 0 and dz != 0);
            if (distance >= best_distance) continue;
            best = index;
            best_distance = distance;
        }
        return best;
    }

    fn markUnstorable(self: *Streaming, world: u32, at: Position) void {
        assert(self.unstorable_count <= self.unstorable.len);
        if (self.unstorablePending(world, at)) return;
        // A full list drops the column, which then waits for the baker as before.
        if (self.unstorable_count == self.unstorable.len) return;
        self.unstorable[self.unstorable_count] = .{ .world = world, .at = at };
        self.unstorable_count += 1;
    }

    fn unstorablePending(self: *const Streaming, world: u32, at: Position) bool {
        for (self.unstorable[0..self.unstorable_count]) |column| {
            if (column.world == world and std.meta.eql(column.at, at)) return true;
        }
        return false;
    }

    fn clearUnstorable(self: *Streaming, world: u32, at: Position) void {
        for (self.unstorable[0..self.unstorable_count], 0..) |column, index| {
            if (column.world != world or !std.meta.eql(column.at, at)) continue;
            self.unstorable[index] = self.unstorable[self.unstorable_count - 1];
            self.unstorable_count -= 1;
            return;
        }
    }

    fn queueCold(self: *Streaming, item: Pending) void {
        assert(self.cold_count <= self.cold.len);
        if (self.coldPending(item.world, item.at)) return;
        if (self.cold_count == self.cold.len) return;
        self.cold[self.cold_count] = .{ .world = item.world, .at = item.at, .protocol = item.protocol, .owner = item.owner };
        self.cold_count += 1;
    }

    /// Bakes a deferred column into the delivery cache without sending it. A column whose
    /// inputs are still loading leaves the queue and returns through ordinary selection. Tells
    /// whether anything changed that selection could act on now.
    fn bakeCold(self: *Streaming) !bool {
        assert(self.cold_count > 0 and self.cold_count <= self.cold.len);
        const cpu = self.cpu.bake.start();
        defer cpu.end();
        // A column next to the last solve scrolls the neighbourhood, so lighting reads and
        // solves one new strip instead of all nine columns. Ties keep the oldest.
        const choice = nearestCold(self.cold[0..self.cold_count], self.deps.lighting.background.solved);
        const cold = self.cold[choice];
        std.mem.copyForwards(Cold, self.cold[choice .. self.cold_count - 1], self.cold[choice + 1 .. self.cold_count]);
        self.cold_count -= 1;
        const dimension = self.deps.worlds.get(cold.world).?.dimension;
        const frame = switch (try self.deps.lighting.bakeDelivery(cold.world, cold.at.x, cold.at.z, dimension, cold.owner)) {
            .loading => return false,
            .unstorable => {
                // The neighbourhood changed after selection checked it. Waiting for it to settle
                // would wait forever beside a block edited every tick, so selection solves it inline.
                self.markUnstorable(cold.world, cold.at);
                return true;
            },
            .baked => |view| view,
        };
        const column: chunks.Light.Column = .{ .world = cold.world, .x = cold.at.x, .z = cold.at.z };
        const requests = [1]delivery_cache.Request{.{ .column = column, .protocol = cold.protocol }};
        _ = try self.delivery.begin(&self.delivery_catalog, &requests);
        self.encoding.storeFrame(self.delivery, column, &frame, @intCast(self.config.fallback_biome)) catch |err| switch (err) {
            error.DeliveryDeferred => {
                self.delivery.cancel();
                return true;
            },
            else => {
                self.delivery.cancel();
                return err;
            },
        };
        try self.delivery.finish(self.deps.chunks);
        return true;
    }

    fn unloadBatch(self: *Streaming, index: usize) !bool {
        const service = self.deps.sessions;
        const stream = &self.streams[index];
        const player = self.views[index];
        assert(stream.setup == .unloading and player.handle != null);
        var positions: [batch_max]Position = undefined;
        var cursors: [batch_max]chunk_horizon.Difference = undefined;
        var count: usize = 0;
        var cursor = stream.departing;
        while (count < positions.len) {
            const at = cursor.next() orelse break;
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
            if (!rejected and admitted != 0) stream.departing = position_cursor;
            rejected = rejected or admitted == 0;
            if (admitted == 0) continue;
            self.markSent(index, at, false);
            stream.delivered -= 1;
            self.publication_players.insert(index);
            progressed = true;
        }
        // Keep the cursor before rejected entries so partial admission cannot skip an unload.
        return progressed;
    }

    fn planRecipients(self: *Streaming, pending: []const Pending, counts: []usize) void {
        assert(pending.len == counts.len and pending.len <= batch_max);
        const radius = self.deliveryRadius();
        for (pending, counts, 0..) |item, *count, i| {
            const targets = self.recipients[i * self.views.len ..][0..self.views.len];
            const owner = self.views[item.owner];
            const handle = owner.handle.?;
            assert(handle.index == item.owner and owner.ready and owner.world == item.world and owner.protocol == item.protocol);
            assert(self.streams[item.owner].setup == .streaming and self.streams[item.owner].generation == handle.generation);
            assert(chunk_horizon.contains(radius, self.streams[item.owner].center, item.at));
            targets[0] = handle;
            count.* = 1;
            var owner_state: ?DisclosureState = null;
            var nearby = self.candidateObservers(item.world, item.at);
            while (nearby.next()) |index| {
                if (index == item.owner) continue;
                const player = &self.views[index];
                const stream = &self.streams[index];
                const recipient = player.handle orelse continue;
                if (player.world != item.world or !player.ready or !self.sameChunkFamily(player.protocol, item.protocol) or stream.setup != .streaming or stream.generation != recipient.generation)
                    continue;
                if (!chunk_horizon.contains(radius, stream.center, item.at) or (self.hasSent(index, item.at) and !self.needsRefresh(index, item.at))) continue;
                if (stream.delivered == 0 and !std.meta.eql(item.at, stream.center)) continue;
                if (self.needsSource(index) and !self.deliveryReady(index, item.at)) {
                    const location: section_visibility_world.Column = .{ .world = item.world, .x = item.at.x, .z = item.at.z, .minimum = stream.minimum_section };
                    if (self.collisionMask(index, location, stream.section_count) == 0) continue;
                }
                if (owner_state == null) owner_state = self.disclosureState(item.owner, item.at);
                if (!std.meta.eql(owner_state.?, self.disclosureState(index, item.at))) continue;
                targets[count.*] = recipient;
                count.* += 1;
            }
            assert(targets[0].index == item.owner and count.* <= targets.len);
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

    fn blocksChanged(self: *Streaming, section: chunks.Section, edits: []const chunks.BlockEdit, previous: []const u16) void {
        assert(edits.len == previous.len);
        const dimension = (self.deps.worlds.get(section.world) orelse return).dimension;
        if (section.y < dimension.minimumSection() or @as(i64, section.y) >= @as(i64, dimension.minimumSection()) + @as(i64, @intCast(dimension.sectionCount()))) return;
        const bounds = GeometryChange.boundsFor(section, edits) orelse return;
        // The geometry's table of what each state occludes is fixed once it is built, so the
        // simulation thread reads it as terrain does.
        const properties = self.geometry.properties;
        const occlusion = for (edits, previous) |edit, old| {
            if (properties[edit.state] != properties[old]) break true;
        } else false;
        self.published.mutex.lockUncancelable(self.native_io);
        self.published.geometry_revision += 1;
        if (self.published.geometry_changes.getPtr(section)) |known| {
            for (0..3) |axis| {
                known.bounds.minimum[axis] = @min(known.bounds.minimum[axis], bounds.minimum[axis]);
                known.bounds.maximum[axis] = @max(known.bounds.maximum[axis], bounds.maximum[axis]);
            }
            known.occlusion = known.occlusion or occlusion;
        } else if (self.published.geometry_changes.count() == geometry_change_capacity) {
            self.published.geometry_overflow = true;
        } else self.published.geometry_changes.putAssumeCapacityNoClobber(section, .{ .bounds = bounds, .occlusion = occlusion });
        self.published.updated = true;
        self.published.mutex.unlock(self.native_io);
    }

    /// Simulation thread, from the lighting service. The edits to a column were patched
    /// in memory. Each column whose light changed has exactly those sections copied into
    /// the mail for the players near it.
    fn lightPatched(raw: *anyopaque, world: u32, x: i32, z: i32, sections: [2][9]u32) void {
        const self: *Streaming = @ptrCast(@alignCast(raw));
        const dimension = (self.deps.worlds.get(world) orelse return).dimension;
        var light: light_store.Sections = undefined;
        for (0..9) |column| {
            if (sections[0][column] | sections[1][column] == 0) continue;
            const at: Position = .{
                .x = std.math.add(i32, x, @as(i32, @intCast(column % 3)) - 1) catch continue,
                .z = std.math.add(i32, z, @as(i32, @intCast(column / 3)) - 1) catch continue,
            };
            // The sections are copied only when somebody is near enough to be sent them.
            const near = self.lightAudience(world, at) and self.deps.lighting.storedLight(world, at.x, at.z, dimension, &light);
            const published = self.published;
            published.mutex.lockUncancelable(self.native_io);
            defer published.mutex.unlock(self.native_io);
            if (near and published.light_mail.add(world, at, .{ sections[0][column], sections[1][column] }, &light)) {
                self.light_mailed = true;
                continue;
            }
            // Without room the column is solved for whoever holds it, which sends the same light.
            if (near) self.light_edit_counts.unsent.add(1);
            published.light_mail.lose(world, at);
            self.light_mailed = self.light_mailed or near;
        }
    }

    /// Simulation thread, from the lighting service. No patch could follow an edit, so
    /// the stored light of the nine columns around it is gone. Every player near one of
    /// them gets its light from a solve, and the solve may light the store again.
    fn lightUnlit(raw: *anyopaque, world: u32, x: i32, z: i32, stamps: [9]u64) void {
        const self: *Streaming = @ptrCast(@alignCast(raw));
        const published = self.published;
        for (stamps, 0..) |stamp, column| {
            if (stamp == 0) continue;
            const at: Position = .{ .x = x + @as(i32, @intCast(column % 3)) - 1, .z = z + @as(i32, @intCast(column / 3)) - 1 };
            self.light_edit_counts.unlit.add(1);
            published.mutex.lockUncancelable(self.native_io);
            defer published.mutex.unlock(self.native_io);
            published.light_mail.lose(world, at);
            published.light_resolves.add(.{ .world = world, .at = at, .stamp = stamp, .wanted = false });
        }
        self.light_mailed = true;
    }

    /// Simulation thread, from the lighting service. Gameplay asked for the light of a
    /// column no stage has.
    fn lightWanted(raw: *anyopaque, world: u32, x: i32, z: i32, stamp: u64) void {
        const self: *Streaming = @ptrCast(@alignCast(raw));
        const published = self.published;
        published.mutex.lockUncancelable(self.native_io);
        defer published.mutex.unlock(self.native_io);
        published.light_resolves.add(.{ .world = world, .at = at: {
            break :at .{ .x = x, .z = z };
        }, .stamp = stamp, .wanted = true });
        self.light_mailed = true;
    }

    /// Simulation thread. Whether any player is near enough to have been sent the column.
    fn lightAudience(self: *Streaming, world: u32, at: Position) bool {
        const radius = self.deliveryRadius();
        var audience = self.deps.players.nearby(world, .{ .x = @as(f64, @floatFromInt(at.x)) * 16, .y = 0, .z = @as(f64, @floatFromInt(at.z)) * 16 }, radius + 1);
        while (audience.next()) |index| {
            const player = self.deps.players.records[index];
            if (player.handle == null or player.stage != .ready) continue;
            if (chunk_horizon.contains(radius, View.capture(player).center, at)) return true;
        }
        return false;
    }

    /// No patched light waits to be sent, no light update waits for a solve, and
    /// gameplay waits for no column.
    pub fn lightSettled(self: *const Streaming) bool {
        return self.light_mail.empty() and self.light_pending.words.count == 0 and self.light_resolves.wanted() == null and self.deps.lighting.storeIdle();
    }

    /// Sends the light sections that patches changed, as they were when each patch
    /// finished and in the order the patches were made. A holder that cannot take its
    /// packet now keeps a pending update, which later sends every section it may see
    /// from a solve.
    fn sendLightDeltas(self: *Streaming) !bool {
        const mail = self.light_mail;
        if (mail.empty()) return false;
        if (mail.next == mail.count) return self.markLostLight();
        // Each packet is reserved once it is planned, at the size its light takes, as reserving
        // a whole column's for every packet of the batch held the pool's room for nothing.
        var output: [batch_max]sessions.Service.Packet = undefined;
        var reserved: usize = 0;
        var full = false;
        defer for (output[0..reserved]) |*packet| packet.cancel();
        var publications: [batch_max]sessions.Service.Publication = undefined;
        var admitted: [batch_max]usize = undefined;
        const Plan = struct { world: u32, at: Position, light: lighting.Receipt.Update };
        var plans: [batch_max]Plan = undefined;
        var planned: usize = 0;
        var sections: light_store.Sections = undefined;
        pass: while (mail.next < mail.count and planned < output.len and !full) {
            const delta = &mail.deltas[mail.next];
            const at = delta.at;
            // A later patch of a column waits until the packets of the earlier one are
            // admitted. Only then is it known which holders are owed exactly its sections.
            for (plans[0..planned]) |plan| {
                if (plan.world == delta.world and std.meta.eql(plan.at, at)) break :pass;
            }
            mail.next += 1;
            const dimension = (self.deps.worlds.get(delta.world) orelse continue).dimension;
            const light_count = dimension.sectionCount() + 2;
            mail.view(delta, &sections);
            var masks: [2]u32 = .{ 0, 0 };
            for (0..2) |layer| {
                var bits = delta.sections[layer];
                while (bits != 0) : (bits &= bits - 1) {
                    // A dense section holds more than one level, so some cell is lit.
                    const lit = switch (sections.light[layer][@ctz(bits)]) {
                        .uniform => |level| level != 0,
                        .dense => true,
                    };
                    if (lit) masks[layer] |= @as(u32, 1) << @intCast(@ctz(bits));
                }
            }
            // Each holder is owed an update until a packet for it is admitted. One that
            // already waited on an older change needs more than these sections.
            var holders = self.visibleObservers(self.views, delta.world, at.x, at.z);
            while (holders.next()) |index| {
                const slot = self.sentIndex(index, at);
                self.light_fresh[index] = self.light_pending.bits[slot.word] & slot.mask == 0;
                self.light_pending.mark(.{ .word = slot.word, .mask = slot.mask });
            }
            holders = self.visibleObservers(self.views, delta.world, at.x, at.z);
            while (holders.next()) |index| {
                if (!self.light_fresh[index]) continue;
                self.light_fresh[index] = false;
                if (full or planned == output.len or !self.visibilityReady(index, at)) continue;
                const view = self.views[index];
                const occluded = self.occludedMask(index, at);
                var count: usize = 0;
                const recipients = self.recipients[planned * self.views.len ..][0..self.views.len];
                recipients[count] = view.handle.?;
                count += 1;
                var others = self.visibleObservers(self.views, delta.world, at.x, at.z);
                while (others.next()) |other| {
                    if (!self.light_fresh[other] or !self.sameLightFamily(self.views[other].protocol, view.protocol) or self.occludedMask(other, at) != occluded or !self.visibilityReady(other, at)) continue;
                    self.light_fresh[other] = false;
                    recipients[count] = self.views[other].handle.?;
                    count += 1;
                }
                const base = (~occluded << 1 | 1 | (@as(u32, 1) << @intCast(light_count - 1))) & ((@as(u32, 1) << @intCast(light_count)) - 1);
                const selection = base & (delta.sections[0] | delta.sections[1]);
                if (selection == 0) {
                    // Every changed section is hidden from this group. Disclosing one sends its light.
                    for (recipients[0..count]) |handle| {
                        const slot = self.sentIndex(handle.index, at);
                        self.light_pending.bits[slot.word] &= ~slot.mask;
                    }
                    continue;
                }
                var light: lighting.Data = .{ .source = .{ .patched = &sections }, .count = light_count, .masks = masks };
                light.disclosure = ~occluded;
                light.selection = selection;
                output[planned] = self.deps.sessions.reserve(light_update_header + light.encodedSize()) catch |err| switch (err) {
                    // The group keeps its pending update for a later pass.
                    error.Backpressured => {
                        full = true;
                        continue;
                    },
                    error.Closed => return false,
                    else => return err,
                };
                reserved += 1;
                var update = self.retainLight(at, recipients[0..count], &light);
                for (&light.retained, &update.selected, delta.sections) |*retained, *selected, layer| {
                    // A section only the other layer changed in keeps the client's copy of this one.
                    const kept = selection & ~layer;
                    retained.* |= kept;
                    selected.* &= ~kept;
                }
                const packet = &output[planned];
                packet.epoch = self.epoch;
                const bytes = try self.deps.packets.writePacket(lighting.writeUpdate, view.protocol, packet.bytes, .{ at.x, at.z, light });
                publications[planned] = .{ .packet = packet, .length = bytes.len, .recipients = recipients[0..count] };
                plans[planned] = .{ .world = delta.world, .at = at, .light = update };
                planned += 1;
            }
            self.light_edit_counts.patched.add(1);
        }
        self.deps.sessions.publishManyReady(publications[0..planned], admitted[0..planned]);
        var progressed = false;
        for (plans[0..planned], publications[0..planned], admitted[0..planned]) |plan, publication, count| {
            for (publication.recipients[0..count]) |handle| {
                const slot = self.sentIndex(handle.index, plan.at);
                self.light_pending.bits[slot.word] &= ~slot.mask;
                self.light_receipts.apply(self.columnIndex(handle.index, plan.at), plan.light);
            }
            progressed = progressed or count != 0;
        }
        self.deps.sessions.flush();
        // Admission is known now, so the columns the mail lost can claim their holders.
        if (mail.next == mail.count and self.markLostLight()) progressed = true;
        if (progressed or !mail.empty()) self.changed.set(self.io);
        return progressed;
    }

    /// Owes every holder of a column the mail lost all of its light, from a solve. Runs
    /// once the deltas of the mail are dealt with, so that no older delta follows it.
    fn markLostLight(self: *Streaming) bool {
        const mail = self.light_mail;
        assert(mail.next == mail.count);
        var marked = false;
        if (mail.lost_all) {
            // Nobody knows which columns changed, so every column anybody was sent is owed.
            for (self.sent, 0..) |bits, word| {
                if (bits == 0) continue;
                self.light_pending.bits[word] |= bits;
                self.light_pending.words.insert(word);
                marked = true;
            }
        } else {
            var lost = mail.lost.keyIterator();
            while (lost.next()) |column| {
                var holders = self.visibleObservers(self.views, column.world, column.at.x, column.at.z);
                while (holders.next()) |index| {
                    const slot = self.sentIndex(index, column.at);
                    self.light_pending.mark(.{ .word = slot.word, .mask = slot.mask });
                    marked = true;
                }
            }
        }
        mail.lost.clearRetainingCapacity();
        mail.lost_all = false;
        return marked;
    }

    /// Solves a column in full for the light store, which lost its light there.
    fn solveLight(self: *Streaming, world: u32, at: Position, dimension: worlds.Worlds.Dimension, player: usize) !bool {
        const timing = self.lighting_duration.start();
        defer timing.end();
        const cpu = self.lighting_cpu.start();
        defer cpu.end();
        return self.deps.lighting.prepare(world, at.x, at.z, dimension, player);
    }

    /// Lights one column gameplay asked for, while no delivery waits for the solver.
    fn solveWanted(self: *Streaming) !bool {
        if (self.pending) return false;
        const entry = self.light_resolves.wanted() orelse return false;
        self.light_resolves.remove(entry.world, entry.at);
        const dimension = (self.deps.worlds.get(entry.world) orelse return true).dimension;
        if (!try self.solveLight(entry.world, entry.at, dimension, 0)) {
            // Its terrain is still loading. It goes to the back and others get their turn.
            self.light_resolves.add(entry);
            return false;
        }
        self.light_edit_counts.solved.add(1);
        if (self.deps.lighting.offer(entry.stamp)) self.light_edit_counts.offered.add(1);
        self.changed.set(self.io);
        return true;
    }

    pub fn pollLight(self: *Streaming) !bool {
        const cpu = self.cpu.light_updates.start();
        defer cpu.end();
        // A tick that begins during a solve voids it. The end of that tick wakes this thread again.
        defer if (!self.lightSettled()) self.deps.sessions.retryBackground(self.epoch);
        // The light store's disk work does not depend on the blocks clients were sent.
        const stored = try self.deps.lighting.pollStore();
        if (stored) self.changed.set(self.io);
        if (self.deps.lighting.background.pending != null and self.pending) return stored;
        if (self.epoch & 1 != 0 or self.epoch != self.deps.sessions.backgroundEpoch()) return stored;
        const patched = (try self.sendLightDeltas()) or stored;
        if (self.light_pending.words.count == 0) return (try self.solveWanted()) or patched;
        // As for deltas, each packet is reserved at the size of the light it was solved for.
        var output: [batch_max]sessions.Service.Packet = undefined;
        var reserved: usize = 0;
        defer for (output[0..reserved]) |*packet| packet.cancel();
        var publications: [batch_max]sessions.Service.Publication = undefined;
        var admitted: [batch_max]usize = undefined;
        const Plan = struct { world: u32, at: Position, protocol: i32, occluded: u32, owner: usize, light: lighting.Receipt.Update };
        var plans: [batch_max]Plan = undefined;
        var planned: usize = 0;
        var attempts: usize = 0;
        var cursor: usize = 0;
        while (attempts < output.len) {
            if (cursor >= self.light_pending.words.count) break;
            const word = self.light_pending.words.indices[cursor];
            const index = word / self.grid.words;
            const view = self.views[index];
            const stream = self.streams[index];
            const bits = self.light_pending.bits[word];
            if (bits == 0 or view.handle == null or !view.ready or stream.generation != view.handle.?.generation or stream.life != view.life) {
                self.light_pending.bits[word] = 0;
                self.light_pending.words.remove(word);
                continue;
            }
            const bit = (word % self.grid.words) * 64 + @ctz(bits);
            const side: i32 = @intCast(self.grid.width);
            const radius = self.keepRadius();
            const left = stream.center.x - radius;
            const top = stream.center.z - radius;
            const at: Position = .{
                .x = left + @mod(@as(i32, @intCast(bit % @as(usize, @intCast(side)))) - @mod(left, side), side),
                .z = top + @mod(@as(i32, @intCast(bit / @as(usize, @intCast(side)))) - @mod(top, side), side),
            };
            if (bit >= @as(usize, @intCast(side * side)) or !self.visibleView(index, view, view.world, at.x, at.z)) {
                self.light_pending.bits[word] &= ~(@as(u64, 1) << @intCast(bit % 64));
                continue;
            }
            const slot = self.sentIndex(index, at);
            if (!self.visibilityReady(index, at)) {
                cursor += 1;
                continue;
            }
            var duplicate = false;
            for (plans[0..planned]) |plan| duplicate = duplicate or (plan.world == view.world and self.sameLightFamily(plan.protocol, view.protocol) and std.meta.eql(plan.at, at) and plan.occluded == self.occludedMask(index, at));
            if (duplicate) {
                cursor += 1;
                continue;
            }
            attempts += 1;
            var count: usize = 0;
            const recipients = self.recipients[planned * self.views.len ..][0..self.views.len];
            var nearby = self.visibleObservers(self.views, view.world, at.x, at.z);
            while (nearby.next()) |recipient| {
                if (!self.sameLightFamily(self.views[recipient].protocol, view.protocol) or self.occludedMask(recipient, at) != self.occludedMask(index, at)) continue;
                if (!self.visibilityReady(recipient, at)) continue;
                const other = self.sentIndex(recipient, at);
                if (self.light_pending.bits[other.word] & other.mask == 0) continue;
                recipients[count] = self.views[recipient].handle.?;
                count += 1;
            }
            assert(count != 0 and self.light_pending.bits[slot.word] & slot.mask != 0);
            const dimension = self.deps.worlds.get(view.world).?.dimension;
            const disclosure = ~self.occludedMask(index, at);
            const light_count = dimension.sectionCount() + 2;
            const selection = (disclosure << 1 | 1 | (@as(u32, 1) << @intCast(light_count - 1))) & ((@as(u32, 1) << @intCast(light_count)) - 1);
            if (planned != 0 and !self.deps.lighting.background.current(self.deps.chunks, view.world, at.x, at.z, dimension)) break;
            // Room for the column's light is asked for before it is solved, so no solve is
            // wasted on a packet that cannot be reserved.
            if (self.deps.sessions.outputFit(&.{light_update_header + lighting.Data.maximumEncodedSize(dimension.sectionCount())}) == 0) break;
            // The light store lost this column to an edit no patch could follow. One
            // solve of the whole column serves the players and lights the store again.
            const lost = self.light_resolves.find(view.world, at);
            const lit = if (lost != null) try self.solveLight(view.world, at, dimension, index) else try self.prepareLight(view.world, at, dimension, index, disclosure);
            if (lit) {
                self.light_edit_counts.solved.add(1);
                if (lost) |stamp| {
                    // The store checks the stamp against edits made since, so the solve
                    // may be handed over whatever tick has begun meanwhile.
                    self.light_resolves.remove(view.world, at);
                    if (self.deps.lighting.offer(stamp)) self.light_edit_counts.offered.add(1);
                }
            }
            if (self.deps.sessions.backgroundEpoch() != self.epoch) break;
            if (!lit) {
                cursor += 1;
                continue;
            }
            var light = self.deps.lighting.background.data();
            assert(light.count == light_count);
            light.disclosure = disclosure;
            light.selection = selection;
            output[planned] = self.deps.sessions.reserve(light_update_header + light.encodedSize()) catch |err| switch (err) {
                error.Backpressured => break,
                error.Closed => return false,
                else => return err,
            };
            reserved += 1;
            const packet = &output[planned];
            packet.epoch = self.epoch;
            const update = self.retainLight(at, recipients[0..count], &light);
            const bytes = try self.deps.packets.writePacket(lighting.writeUpdate, view.protocol, packet.bytes, .{ at.x, at.z, light });
            publications[planned] = .{ .packet = packet, .length = bytes.len, .recipients = recipients[0..count] };
            plans[planned] = .{ .world = view.world, .at = at, .protocol = view.protocol, .occluded = self.occludedMask(index, at), .owner = index, .light = update };
            planned += 1;
            cursor += 1;
        }
        self.deps.sessions.publishManyReady(publications[0..planned], admitted[0..planned]);
        var progressed = patched;
        for (plans[0..planned], publications[0..planned], admitted[0..planned]) |plan, publication, count| {
            for (publication.recipients[0..count]) |handle| {
                const other = self.sentIndex(handle.index, plan.at);
                self.light_pending.bits[other.word] &= ~other.mask;
                self.light_receipts.apply(self.columnIndex(handle.index, plan.at), plan.light);
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
        for (self.publication_players.values()) |index| {
            if (self.views[index].handle == null) {
                self.streams[index] = .{};
                @memset(self.sent[index * self.grid.words ..][0..self.grid.words], 0);
                self.dirty_words.setRangeValue(.{ .start = index * self.grid.words, .end = (index + 1) * self.grid.words }, true);
                self.background_players.remove(index);
                self.occupied_players.remove(index);
                self.setup_players.remove(index);
                self.source_players.remove(index);
            }
            const view = self.views[index];
            const current = &self.streams[index];
            // Collision terrain gates placement. A horizon-wide visibility solve does not.
            if (current.prepared_teleport != view.teleport_id and self.placementReady(index)) {
                current.prepared_teleport = view.teleport_id;
            }
            published.setStream(index, current.snapshot());
        }
        self.publication_players.clear();
        var dirty = self.dirty_words.iterator(.{});
        while (dirty.next()) |word| {
            const range = columnRange(self.grid.width, self.grid.words, word);
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
                .total_columns = chunk_horizon.count(self.deliveryRadius()),
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
                // After a teleport the view is where the player is and the stream is still
                // where they were. Nothing is known there about columns around the view.
                const within = chunk_horizon.contains(self.deliveryRadius(), stream.center, at);
                const column = if (within) self.columnIndex(handle.index, at) else 0;
                const queued = stream.setup == .streaming and within and self.hasSent(handle.index, at);
                snapshot.sections[snapshot.count] = .{
                    .bounds = .{ .minimum = .{ x * 16, y * 16, z * 16 }, .maximum = .{ x * 16 + 16, y * 16 + 16, z * 16 + 16 } },
                    .status = streaming_debug.Status.classify(queued, within and self.occluded[column] & bit == 0, within and self.disclosed[column] & bit != 0, within and self.needsRefresh(handle.index, at)),
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
        streams: []Snapshot,
        sent: []u64,
        occluded: []u32,
        grid: chunk_horizon.Index,
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
                const range = columnRange(@intCast(self.grid.width), self.grid.words, word);
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
            const slot = player * self.grid.columns + self.grid.at(.{ .x = section.x, .z = section.z });
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
            const slot = self.grid.bit(player, .{ .x = x, .z = z });
            return stream.generation == handle.generation and stream.life == record.life and stream.setup != .opening and
                chunk_horizon.contains(self.radius, stream.center, .{ .x = x, .z = z }) and
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

    /// The vanilla client keeps columns within max(2, view distance) + 3 chunks of its view
    /// center (ClientChunkCache.calculateStorageRange), so a column it was sent stays usable
    /// until then. Keeping it that long saves a full resend when the player turns back.
    /// Columns stay loaded out to the radius the per-column grid covers, which `init` sizes
    /// to the client storage. A grid sized to the delivery radius keeps no extra band.
    fn keepRadius(self: *const Streaming) i32 {
        const result: i32 = @intCast((self.grid.width - 1) / 2);
        assert(result >= self.deliveryRadius());
        return result;
    }

    fn keepRadiusFor(view_distance: i32) i32 {
        return @max(2, view_distance) + 3;
    }

    /// Columns kept past the delivery radius receive no deltas, so an edit in one, or in a
    /// neighbor whose light reaches it, leaves the client copy stale. Forgetting the column
    /// here resends it in full if the player returns. The client drops its copy on its own.
    fn forgetKept(self: *Streaming, section: chunks.Section) void {
        const delivery = self.deliveryRadius();
        const keep = self.keepRadius();
        if (keep == delivery) return;
        var nearby = self.observers_index.query(.{ .world = section.world, .x = section.x, .z = section.z }, keep + 1);
        while (nearby.next()) |index| {
            if (self.views[index].world != section.world) continue;
            const center = self.streams[index].center;
            for (0..9) |neighbor| {
                const at: Position = .{ .x = section.x + @as(i32, @intCast(neighbor % 3)) - 1, .z = section.z + @as(i32, @intCast(neighbor / 3)) - 1 };
                if (chunk_horizon.contains(delivery, center, at) or !chunk_horizon.contains(keep, center, at)) continue;
                if (self.hasSent(index, at)) self.markSent(index, at, false);
            }
        }
    }

    fn visibilityRadius(self: *const Streaming) i32 {
        return self.deliveryRadius() + section_visibility_world.Source.horizon_padding;
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
        return .{ .owner = self, .views = views, .world = world, .at = .{ .x = x, .z = z }, .query = self.candidateObservers(world, .{ .x = x, .z = z }) };
    }

    fn candidateObservers(self: *const Streaming, world: u32, at: Position) SpatialIndex.Query {
        const center: SpatialIndex.Position = .{ .world = world, .x = at.x, .z = at.z };
        if (self.tile) |tile| if (tile.audience) |audience| if (audience.query(center, self.deliveryRadius())) |query| return query;
        return self.observers_index.query(center, self.deliveryRadius());
    }

    pub fn visibleView(self: *const Streaming, index: usize, view: View, world: u32, x: i32, z: i32) bool {
        const handle = view.handle orelse return false;
        const stream = self.streams[index];
        return view.world == world and stream.generation == handle.generation and stream.life == view.life and
            stream.setup != .opening and chunk_horizon.contains(self.deliveryRadius(), stream.center, .{ .x = x, .z = z }) and self.hasSent(index, .{ .x = x, .z = z });
    }

    fn sentIndex(self: *const Streaming, index: usize, at: Position) chunk_horizon.Index.Bit {
        return self.grid.bit(index, at);
    }

    fn hasSent(self: *const Streaming, index: usize, at: Position) bool {
        const slot = self.sentIndex(index, at);
        return self.sent[slot.word] & slot.mask != 0;
    }

    fn columnIndex(self: *const Streaming, index: usize, at: Position) usize {
        return index * self.grid.columns + self.grid.at(at);
    }

    fn occludedMask(self: *const Streaming, index: usize, at: Position) u32 {
        return if (self.hasSent(index, at)) self.occluded[self.columnIndex(index, at)] else std.math.maxInt(u32);
    }

    fn missingSections(self: *const Streaming, index: usize, at: Position, desired: u32) u32 {
        const slot = self.columnIndex(index, at);
        const painted = if (self.streams[index].debug_history) self.painted[slot] else 0;
        return desired & (~self.disclosed[slot] | self.stale[slot] | painted) & ((@as(u32, 1) << @intCast(self.streams[index].section_count)) - 1);
    }

    fn retainLight(self: *const Streaming, at: Position, recipients: []const sessions.Handle, data: *lighting.Data) lighting.Receipt.Update {
        assert(recipients.len != 0 and data.retained[0] == 0 and data.retained[1] == 0);
        var retained: [2]u32 = @splat(std.math.maxInt(u32));
        var update = self.light_receipts.capture(data.*);
        for (recipients) |handle| {
            const known = self.light_receipts.retained(self.columnIndex(handle.index, at), update);
            for (&retained, known) |*bits, previous| bits.* &= previous;
        }
        data.retained = retained;
        for (&update.selected, retained) |*selected, known| selected.* &= ~known;
        if (data.selection == null) {
            // A full send leaves the lit top of the column to clients that hold nothing there.
            var absent: u32 = std.math.maxInt(u32);
            for (recipients) |handle| absent &= self.light_receipts.absentSky(self.columnIndex(handle.index, at), update);
            update.selected[1] &= ~data.leaveTop(absent);
        }
        return update;
    }

    fn canReuseColumn(self: *const Streaming, index: usize, at: Position, blocks_mask: u32, biomes_mask: u32) bool {
        var painted: u32 = 0;
        if (self.streams[index].debug_history) {
            if (self.views[index].frontier_debug and self.disclosed[self.columnIndex(index, at)] & ~blocks_mask != 0) return false;
            painted = self.frontierMask(index, at);
            if (self.painted[self.columnIndex(index, at)] != painted) return false;
        }
        return self.hasSent(index, at) and self.missingSections(index, at, blocks_mask & ~painted) == 0 and
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
        const painted = if (self.streams[index].debug_history) self.painted[slot] else 0;
        const known = visible & self.disclosed[slot] & ~(self.stale[slot] | painted);
        const restored = self.occluded[slot] & known;
        if (restored == 0) return;
        self.occluded[slot] &= ~restored;
        self.dirty_words.set(self.sentIndex(index, at).word);
        assert(self.occluded[slot] & known == 0);
    }

    fn needsRefresh(self: *const Streaming, index: usize, at: Position) bool {
        const rank = self.order.positionRank(self.streams[index].center, at);
        return self.refresh_bits[index * self.grid.words + rank / 64] & (@as(u64, 1) << @intCast(rank % 64)) != 0;
    }

    fn clearRefresh(self: *Streaming, index: usize, at: Position) void {
        const radius = self.deliveryRadius();
        if (!chunk_horizon.contains(radius, self.streams[index].center, at)) return;
        const rank = self.order.positionRank(self.streams[index].center, at);
        self.refresh_bits[index * self.grid.words + rank / 64] &= ~(@as(u64, 1) << @intCast(rank % 64));
    }

    fn updateView(self: *Streaming, index: usize, current: View) void {
        const previous = self.views[index];
        const same = previous.world == current.world and previous.life == current.life and std.meta.eql(previous.handle, current.handle);
        self.views[index] = current;
        if (current.frontier_debug) self.streams[index].debug_history = true;
        if (self.config.occlusion) self.geometry.captureFrontier(index, current.frontier_debug);
        if (same and previous.frontier_debug != current.frontier_debug) self.refreshReady(index);
        if (previous.teleport_id != current.teleport_id) self.streams[index].prepared_teleport = 0;
        const source = &self.sources[index];
        if (!same) source.biome = null;
        if (!same) source.pace = .{};
        source.pace.observe(.{ current.eye_min[0], current.eye_max, current.eye_min[2] });
        if (!self.config.occlusion) return;
        if (same and !previous.frontier_debug and current.frontier_debug) {
            self.refresh(index, true);
            return;
        }
        if (!current.occlusion) {
            self.source_players.remove(index);
            if (previous.occlusion) self.refresh(index, false);
            return;
        }
        const point: [3]i32 = .{ current.eye_min[0], current.eye_max, current.eye_min[2] };
        const reusable = same and if (source.origin) |origin| origin.supports(current.world, point) and self.geometry.covers(index, current.world, current.center, self.deliveryRadius()) else false;
        if (!reusable or previous.occlusion != current.occlusion) self.refresh(index, !reusable);
    }

    fn constantMask(self: *const Streaming, index: usize, column: section_visibility_world.Column, count: usize) u32 {
        const slot = self.columnIndex(index, .{ .x = column.x, .z = column.z });
        return self.geometry.skyAirForView(index, column, count) & ~self.stale[slot];
    }

    fn sectionMask(self: *const Streaming, index: usize, column: section_visibility_world.Column, count: usize, view: usize) u32 {
        assert(column.world == self.views[index].world);
        const mask = self.geometry.mask(view, column.x, column.z);
        assert(mask & ~((@as(u32, 1) << @intCast(count)) - 1) == 0);
        return mask;
    }

    fn frontierMask(self: *const Streaming, index: usize, at: Position) u32 {
        if (!self.views[index].frontier_debug) return 0;
        const query = self.columnView(index, at) orelse return 0;
        const stream = self.streams[index];
        const column: section_visibility_world.Column = .{ .world = self.views[index].world, .x = at.x, .z = at.z, .minimum = stream.minimum_section };
        return self.geometry.stoppingMask(query, at.x, at.z) & ~self.collisionMask(index, column, stream.section_count);
    }

    fn canConceal(self: *const Streaming, index: usize) bool {
        if (!self.config.occlusion or !self.sources[index].known) return false;
        return self.views[index].occlusion and self.geometry.ready(index);
    }

    fn canConcealColumn(self: *const Streaming, index: usize, at: Position) bool {
        return self.columnView(index, at) != null;
    }

    fn columnView(self: *const Streaming, index: usize, at: Position) ?usize {
        if (!self.config.occlusion or !self.sources[index].known or !self.views[index].occlusion) return null;
        if (self.geometry.readyColumn(index, at.x, at.z)) return index;
        return null;
    }

    fn deliveryReady(self: *const Streaming, index: usize, at: Position) bool {
        return self.columnView(index, at) != null;
    }

    fn disclosureMasks(self: *const Streaming, index: usize, column: section_visibility_world.Column, count: usize) DisclosureMasks {
        const occupied = self.collisionMask(index, column, count);
        if (!self.config.occlusion or !self.views[index].occlusion) {
            const all = self.unrestrictedMask(index, count);
            return .{ .visibility = all, .disclosure = all };
        }
        const query = self.columnView(index, .{ .x = column.x, .z = column.z }) orelse return .{ .visibility = occupied, .disclosure = occupied };
        const visible = self.sectionMask(index, column, count, query) | occupied;
        return .{ .visibility = visible, .disclosure = visible | self.constantMask(index, column, count) };
    }

    fn occupiedColumn(self: *const Streaming, index: usize) ?DeliveryColumn {
        const view = self.views[index];
        const stream = self.streams[index];
        const handle = view.handle orelse return null;
        if (!view.ready or stream.setup != .streaming or stream.generation != handle.generation) return null;
        for (0..9) |offset| {
            const relative = chunk_horizon.spiral(offset);
            const column: DeliveryColumn = .{ .world = view.world, .at = .{ .x = view.center.x + relative.x, .z = view.center.z + relative.z } };
            if (stream.delivered == 0 and !std.meta.eql(column.at, stream.center)) continue;
            const occupied = self.collisionMask(index, .{ .world = column.world, .x = column.at.x, .z = column.at.z, .minimum = stream.minimum_section }, stream.section_count);
            if (occupied == 0) continue;
            if (!self.hasSent(index, column.at) or self.missingSections(index, column.at, occupied) != 0 or self.occludedMask(index, column.at) & occupied != 0) return column;
        }
        return null;
    }

    fn beginTile(self: *Streaming, column: DeliveryColumn) void {
        assert(self.tile == null);
        const dimension = self.deps.worlds.get(column.world).?.dimension;
        const group = self.deps.chunks.storageGroup(.{ .world = column.world, .x = column.at.x, .y = dimension.minimumSection(), .z = column.at.z });
        self.tile_watch.configure(.{
            .world = column.world,
            .minimum = .{ .x = group.minimum.x, .y = dimension.minimumSection(), .z = group.minimum.z },
            .maximum = .{ .x = group.minimum.x + group.side - 1, .y = dimension.minimumSection() + @as(i32, @intCast(dimension.sectionCount())) - 1, .z = group.minimum.z + group.side - 1 },
        }, self.tile_revisions);
        self.group_window.begin(.{ .world = column.world, .x = group.minimum.x, .z = group.minimum.z, .minimum = dimension.minimumSection(), .count = dimension.sectionCount() });
        self.tile = .{ .world = column.world, .minimum = .{ .x = group.minimum.x, .z = group.minimum.z }, .side = group.side, .audience = self.observers_index.window(.{ .world = column.world, .x = group.minimum.x, .z = group.minimum.z }, self.deliveryRadius() + group.side - 1, self.tile_observers) };
    }

    fn tileColumn(self: *Streaming, at: Position) ?Pending {
        const tile = self.tile.?;
        var nearby = self.candidateObservers(tile.world, at);
        while (nearby.next()) |index| {
            if (!self.canDeliverColumn(index, .{ .world = tile.world, .at = at })) continue;
            return .{ .world = tile.world, .at = at, .owner = index, .protocol = self.views[index].protocol };
        }
        return null;
    }

    fn nextTileColumn(self: *Streaming) ?Pending {
        if (self.tile == null) return null;
        while (self.tile.?.scanned < self.tile.?.columns()) {
            const at = self.tile.?.at(self.tile.?.cursor);
            if (self.tileColumn(at)) |candidate| return candidate;
            self.tile.?.cursor = (self.tile.?.cursor + 1) % self.tile.?.columns();
            self.tile.?.scanned += 1;
        }
        self.releaseTile();
        return null;
    }

    pub fn releaseTile(self: *Streaming) void {
        if (self.tile != null) self.group_window.reset();
        self.tile = null;
    }

    fn canDeliverColumn(self: *const Streaming, index: usize, column: DeliveryColumn) bool {
        const view = self.views[index];
        const handle = view.handle orelse return false;
        const stream = self.streams[index];
        if (!view.ready or view.world != column.world or stream.setup != .streaming or stream.generation != handle.generation) return false;
        if (!chunk_horizon.contains(self.deliveryRadius(), stream.center, column.at)) return false;
        if (self.coldPending(column.world, column.at)) return false;
        const ready = self.deliveryReady(index, column.at);
        if (self.needsSource(index) and !ready) {
            const occupied = self.collisionMask(index, .{ .world = column.world, .x = column.at.x, .z = column.at.z, .minimum = stream.minimum_section }, stream.section_count);
            if (occupied == 0 or (self.hasSent(index, column.at) and self.missingSections(index, column.at, occupied) == 0 and self.occludedMask(index, column.at) & occupied == 0)) return false;
        }
        // A concealed first column has no permitted biome for padding its hidden sections.
        if (stream.delivered == 0 and !std.meta.eql(column.at, stream.center)) return false;
        if (self.hasSent(index, column.at)) {
            if (!self.needsRefresh(index, column.at)) return false;
            if (self.columnView(index, column.at)) |query| {
                const location: section_visibility_world.Column = .{ .world = column.world, .x = column.at.x, .z = column.at.z, .minimum = stream.minimum_section };
                const mask = self.sectionMask(index, location, stream.section_count, query);
                if (self.canReuseColumn(index, column.at, mask | self.constantMask(index, location, stream.section_count), mask)) return true;
            }
        }
        const estimate = if (stream.reserve_bytes == 0) self.deps.sessions.config.page_bytes else stream.reserve_bytes;
        return self.deps.sessions.packetCapacity(handle, estimate) != 0;
    }

    fn unrestrictedMask(self: *const Streaming, index: usize, count: usize) u32 {
        assert(!self.config.occlusion or !self.views[index].occlusion);
        return (@as(u32, 1) << @intCast(count)) - 1;
    }

    fn collisionMask(self: *const Streaming, index: usize, column: section_visibility_world.Column, count: usize) u32 {
        const view = self.views[index];
        assert(count > 0 and count <= section_views.maximum_sections);
        assert(column.world == view.world and view.eye_max >= view.eye_min[1]);
        for ([_]usize{ 0, 2 }, [_]i32{ column.x, column.z }) |axis, coordinate| {
            if (@divFloor(view.eye_min[axis] - 1, 16) > coordinate or @divFloor(view.eye_min[axis] + 1, 16) < coordinate) return 0;
        }
        const lower = std.math.clamp(@divFloor(view.eye_min[1] - 1, 16) - column.minimum, 0, @as(i32, @intCast(count)) - 1);
        const upper = std.math.clamp(@divFloor(view.eye_max, 16) - column.minimum, 0, @as(i32, @intCast(count)) - 1);
        return ((@as(u32, 1) << @intCast(upper + 1)) - 1) & ~((@as(u32, 1) << @intCast(lower)) - 1);
    }

    fn disclosureState(self: *const Streaming, index: usize, at: Position) DisclosureState {
        const stream = self.streams[index];
        const column: section_visibility_world.Column = .{ .world = self.views[index].world, .x = at.x, .z = at.z, .minimum = stream.minimum_section };
        const slot = self.columnIndex(index, at);
        return .{
            .column = column,
            .count = @intCast(stream.section_count),
            .masks = self.disclosureMasks(index, column, stream.section_count),
            .stale = self.stale[slot],
            .disclosed = self.disclosed[slot],
            .biomes = self.biome_disclosed[slot],
            .frontier = self.frontierMask(index, at),
            .painted = if (self.streams[index].debug_history) self.painted[slot] else 0,
            .debug = self.views[index].frontier_debug,
        };
    }

    fn sameDisclosure(self: *const Streaming, a: usize, b: usize, at: Position) bool {
        if (a == b) return true;
        assert(self.views[a].world == self.views[b].world);
        assert(self.streams[a].minimum_section == self.streams[b].minimum_section and self.streams[a].section_count == self.streams[b].section_count);
        return std.meta.eql(self.disclosureState(a, at), self.disclosureState(b, at));
    }

    fn disclosedBiome(source: chunk_encoding.BiomeNeighborhood.Source, count: usize, disclosed: u32) ?u16 {
        if (disclosed == 0) return null;
        return source.get(count, 4, @ctz(disclosed)).?.get(0);
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

    fn coverBiome(self: *Streaming, index: usize, disclosed: ?u16) i32 {
        const source = &self.sources[index];
        if (disclosed) |biome| {
            source.biome = biome;
            return biome;
        }
        return source.biome orelse self.config.fallback_biome;
    }

    /// Changes whenever a chunk packet for the column completes for this player.
    pub fn columnDelivery(self: *const Streaming, index: usize, at: Position) u32 {
        return self.column_deliveries[self.columnIndex(index, at)];
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

    fn learnSources(self: *Streaming, positions: []const chunks.Section, player: usize) !bool {
        assert(positions.len <= section_visibility_world.World.batch_max);
        if (positions.len == 0) return false;
        const capacity = self.chunk_client.budget();
        assert(capacity > 0);
        var batch: [section_visibility_world.World.batch_max]chunks.Section = undefined;
        const reads = self.classification_requests;
        var count: usize = 0;
        var learned = false;
        const world = positions[0].world;
        const dimension = self.deps.worlds.get(world).?.dimension;
        for (positions) |section| {
            assert(section.world == world);
            if (self.geometry.known(section, dimension.minimumSection(), dimension.sectionCount())) continue;
            reads[count] = .{ .section = section, .result = &self.classifications[count], .prepared = &self.prepared_classifications[count] };
            count += 1;
        }
        if (count != 0) learned = try self.learnClassifications(reads[0..count]) or learned;
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

    fn learnTopologies(self: *Streaming, columns: []const chunks.classification.Column, player: usize) !bool {
        assert(columns.len > 0 and columns.len <= chunks.classification.column_batch_max);
        const dimension = self.deps.worlds.get(columns[0].world).?.dimension;
        const minimum = dimension.minimumSection();
        const count = dimension.sectionCount();
        const capacity = self.chunk_client.budget();
        var unresolved: [chunks.classification.column_batch_max]chunks.classification.Column = undefined;
        var unresolved_count: usize = 0;
        var learned = false;
        if (self.deps.lighting.config.stored and self.deps.lighting.classification != null) {
            var requests: [chunks.classification.column_batch_max]chunks.Light.PrefixRequest = undefined;
            var snapshots: [chunks.classification.column_batch_max]chunks.Light.PrefixSnapshot = undefined;
            for (columns, self.column_prefixes[0..columns.len], requests[0..columns.len]) |column, *buffer, *request| request.* = .{ .column = .{ .world = column.world, .x = column.x, .z = column.z }, .minimum = column.minimum, .count = column.count, .destination = buffer };
            try self.deps.chunks.lightPrefixes(requests[0..columns.len], snapshots[0..columns.len]);
            for (columns, snapshots[0..columns.len], self.column_prefixes[0..columns.len]) |column, snapshot, *buffer| {
                const accepted = prepared: {
                    if (!snapshot.clean) break :prepared false;
                    const length = snapshot.length orelse break :prepared false;
                    const prefix = chunks.Light.Prefix.read(buffer[0..length]) catch |err| switch (err) {
                        error.Outdated => break :prepared false,
                        else => return err,
                    };
                    if (prefix.minimum != column.minimum or prefix.count != column.count or !std.mem.eql(u8, &prefix.rules, &self.deps.lighting.rules)) break :prepared false;
                    const metadata = prefix.metadata orelse break :prepared false;
                    if (!std.mem.eql(u8, &metadata.identity, &self.classification.identity)) break :prepared false;
                    break :prepared try self.geometry.learnPreparedColumn(.{ .world = column.world, .x = column.x, .z = column.z, .minimum = column.minimum }, column.count, metadata.bytes);
                };
                learned = learned or accepted;
                if (!accepted) {
                    unresolved[unresolved_count] = column;
                    unresolved_count += 1;
                }
            }
        } else {
            @memcpy(unresolved[0..columns.len], columns);
            unresolved_count = columns.len;
        }
        const summaries = self.column_summaries[0..unresolved_count];
        if (unresolved_count != 0) try self.deps.chunks.summarize(unresolved[0..unresolved_count], summaries, self.geometry.properties, section_visibility_world.occluder_property);
        learned = apply: {
            const timing = self.cpu.metadata.start();
            defer timing.end();
            break :apply (try self.geometry.learnColumnTopology(unresolved[0..unresolved_count], summaries)) or learned;
        };
        var missing: [section_visibility_world.World.batch_max]chunks.Section = undefined;
        var missing_count: usize = 0;
        for (columns) |column| {
            assert(column.world == columns[0].world and column.minimum == minimum and column.count == count);
            const all: u32 = @truncate((@as(u64, 1) << @intCast(count)) - 1);
            var unavailable = all & ~self.geometry.knownTopology(.{ .world = column.world, .x = column.x, .z = column.z, .minimum = minimum }, count);
            while (unavailable != 0) : (unavailable &= unavailable - 1) {
                missing[missing_count] = .{ .world = column.world, .x = column.x, .z = column.z, .y = minimum + @as(i32, @intCast(@ctz(unavailable))) };
                missing_count += 1;
                if (missing_count == capacity) {
                    learned = try self.learnPrepared(missing[0..missing_count], player) or learned;
                    missing_count = 0;
                }
            }
        }
        if (missing_count != 0) learned = try self.learnPrepared(missing[0..missing_count], player) or learned;
        return learned;
    }

    fn learnClassifications(self: *Streaming, reads: []const chunks.Chunks.ClassificationRequest) !bool {
        assert(reads.len <= section_visibility_world.World.batch_max);
        try self.deps.chunks.classify(reads, self.geometry.properties, section_visibility_world.occluder_property);
        const dimension = self.deps.worlds.get(reads[0].section.world).?.dimension;
        const cpu = self.cpu.metadata.start();
        defer cpu.end();
        return self.geometry.learnClassifications(reads, dimension.minimumSection(), dimension.sectionCount(), .source);
    }

    fn learnPrepared(self: *Streaming, positions: []const chunks.Section, player: usize) !bool {
        assert(positions.len > 0 and positions.len <= self.chunk_client.budget());
        var leases: [section_visibility_world.World.batch_max]chunks.Lease = undefined;
        var requests: [section_visibility_world.World.batch_max]chunks.Chunks.Preparation = undefined;
        var ready: [section_visibility_world.World.batch_max]bool = undefined;
        for (positions, 0..) |_, index| requests[index] = .{ .sections = positions[index..][0..1], .leases = leases[index..][0..1], .priority = .{ .urgency = .occupied, .player = player } };
        try self.chunk_client.prepareMany(requests[0..positions.len], ready[0..positions.len]);
        defer for (leases[0..positions.len], ready[0..positions.len]) |lease, complete| if (complete) lease.release();
        var learned = false;
        for (positions, leases[0..positions.len], ready[0..positions.len]) |position, lease, complete| {
            if (!complete) continue;
            const dimension = self.deps.worlds.get(position.world).?.dimension;
            const view = lease.view();
            self.geometry.learnSection(.{ .world = position.world, .x = position.x, .z = position.z, .minimum = dimension.minimumSection() }, dimension.sectionCount(), @intCast(position.y - dimension.minimumSection()), .fromChunk(view));
            learned = true;
        }
        return learned;
    }

    fn prepareSources(self: *Streaming, maximum_batches: usize) !void {
        assert(maximum_batches > 0 and maximum_batches <= batch_max);
        const cpu = self.cpu.sources.start();
        defer cpu.end();
        if (!self.config.occlusion) return;
        var owner = self.geometry.active;
        if (owner == null) {
            while (self.source_players.count != 0) {
                const slot = self.next_visibility_player % self.source_players.count;
                const index = self.source_players.indices[slot];
                const view = self.views[index];
                if (view.handle == null or !view.ready or !view.occlusion or (self.sources[index].known and self.geometry.ready(index))) {
                    self.source_players.remove(index);
                    continue;
                }
                owner = index;
                self.next_visibility_player = (slot + 1) % self.source_players.count;
                break;
            }
        }
        const index = owner orelse return;
        const source = &self.sources[index];
        if (self.geometry.active == null) {
            const view = self.views[index];
            const dimension = self.deps.worlds.get(view.world).?.dimension;
            const point: [3]i32 = .{ view.eye_min[0], view.eye_max, view.eye_min[2] };
            if (self.geometry.reuse(index, view.world, point, dimension.minimumSection(), dimension.sectionCount(), self.visibilityRadius(), source.pace.precision())) {
                source.origin = self.geometry.sourceSnapshot(index);
                source.known = true;
                self.source_players.remove(index);
                self.refreshVisibility(index);
                self.changed.set(self.io);
                return;
            }
            if (source.origin == null or self.geometry.sourceInvalidated(index)) {
                var required: [27]chunks.Section = undefined;
                const requirements = section_visibility_world.World.sourceRequirements(view.world, dimension.minimumSection(), dimension.sectionCount(), point, &required);
                _ = try self.learnSources(requirements, index);
                // Slow heads get rays from their head cell. Fast heads keep section-wide reuse.
                source.origin = self.geometry.narrowSource(view.world, dimension.minimumSection(), dimension.sectionCount(), point, source.pace.precision(), &self.origin_scratch);
                if (source.origin == null) return;
            }
            {
                const timing = self.cpu.visibility.start();
                defer timing.end();
                self.geometry.begin(index, source.origin.?, dimension.minimumSection(), dimension.sectionCount(), self.visibilityRadius());
            }
            source.origin = self.geometry.sourceSnapshot(index);
        }
        var learned_columns: usize = 0;
        for (0..maximum_batches) |_| {
            if (learned_columns == topology_budget) break;
            if (self.geometry.active == null) break;
            const advanced = evaluate: {
                const timing = self.cpu.visibility.start();
                defer timing.end();
                break :evaluate self.geometry.advance();
            };
            if (advanced.requests.len != 0) {
                // Unknown columns are classified from their sections at about half a millisecond
                // each. A bound per call keeps one flood from holding the thread for a second.
                const taken = @min(advanced.requests.len, topology_budget - learned_columns);
                assert(taken > 0);
                learned_columns += taken;
                const topology_learned = try self.learnTopologies(advanced.requests[0..taken], index);
                if (!topology_learned) {
                    self.pending = true;
                    return;
                }
            } else assert(advanced.progressed);
        }
        if (self.geometry.active != null) {
            self.pending = true;
            self.changed.set(self.io);
            return;
        }
        const current = self.views[index];
        const point: [3]i32 = .{ current.eye_min[0], current.eye_max, current.eye_min[2] };
        source.known = self.geometry.ready(index) and self.geometry.sourceSnapshot(index).supports(current.world, point);
        if (source.known) {
            self.source_players.remove(index);
            source.origin = self.geometry.sourceSnapshot(index);
            self.refreshVisibility(index);
        } else source.origin = null;
        self.pending = true;
        self.changed.set(self.io);
    }

    fn advanceCursor(self: *Streaming, index: usize) void {
        const stream = &self.streams[index];
        const side: usize = @intCast(self.deliveryRadius() * 2 + 1);
        const limit = side * side;
        assert(stream.cursor <= limit);
        const bits = self.refresh_bits[index * self.grid.words ..][0..self.grid.words];
        var cursor = stream.cursor;
        while (cursor < limit) {
            const word = cursor / 64;
            const available = bits[word] & (@as(u64, std.math.maxInt(u64)) << @as(u6, @intCast(cursor % 64)));
            if (available == 0) {
                cursor = @min(limit, (word + 1) * 64);
                continue;
            }
            cursor = word * 64 + @ctz(available);
            if (cursor >= limit) break;
            if (self.columnPending(index, cursor)) break;
            bits[word] &= ~(@as(u64, 1) << @intCast(cursor % 64));
            cursor += 1;
        }
        stream.cursor = @min(cursor, limit);
    }

    fn scheduleColumn(self: *Streaming, index: usize, at: Position) void {
        const stream = &self.streams[index];
        const radius = self.deliveryRadius();
        if (!chunk_horizon.contains(radius, stream.center, at)) return;
        const rank = self.order.positionRank(stream.center, at);
        const ready = !self.config.occlusion or !self.views[index].occlusion or self.deliveryReady(index, at);
        if (self.hasSent(index, at) and ready) {
            const column: section_visibility_world.Column = .{ .world = self.views[index].world, .x = at.x, .z = at.z, .minimum = stream.minimum_section };
            const masks = self.disclosureMasks(index, column, stream.section_count);
            self.hideSections(index, at, ~masks.visibility);
            self.restoreSections(index, at, masks.visibility);
            if (self.canReuseColumn(index, at, masks.disclosure, masks.visibility)) {
                self.clearRefresh(index, at);
                self.deliveries.reused.add(1);
                return;
            }
        }
        self.refresh_bits[index * self.grid.words + rank / 64] |= @as(u64, 1) << @intCast(rank % 64);
        stream.cursor = @min(stream.cursor, rank);
        self.pending = true;
    }

    fn columnPending(self: *const Streaming, index: usize, cursor: usize) bool {
        const stream = self.streams[index];
        const at = self.order.at(stream.center, cursor);
        if (!chunk_horizon.contains(self.deliveryRadius(), stream.center, at)) return false;
        return !self.hasSent(index, at) or self.needsRefresh(index, at);
    }

    fn refresh(self: *Streaming, index: usize, source_changed: bool) void {
        if (source_changed) {
            if (self.config.occlusion) self.source_players.insert(index);
            self.sources[index].known = false;
            self.sources[index].origin = null;
            self.pending = true;
            return;
        }
        self.refreshReady(index);
    }

    fn moveCenter(self: *Streaming, index: usize, center: Position) void {
        const stream = &self.streams[index];
        const previous = stream.center;
        const radius = self.deliveryRadius();
        const side: usize = @intCast(2 * radius + 1);
        const bits = self.refresh_bits[index * self.grid.words ..][0..self.grid.words];
        @memset(self.pending_scratch, 0);
        for (bits, 0..) |word, word_index| {
            var pending = word;
            while (pending != 0) : (pending &= pending - 1) {
                const rank = word_index * 64 + @as(usize, @ctz(pending));
                assert(rank < side * side);
                const at = self.order.at(previous, rank);
                if (!chunk_horizon.contains(radius, center, at)) continue;
                const moved = self.order.positionRank(center, at);
                self.pending_scratch[moved / 64] |= @as(u64, 1) << @intCast(moved % 64);
            }
        }
        @memcpy(bits, self.pending_scratch);
        stream.center = center;
        stream.cursor = 0;
        var arrivals = chunk_horizon.Difference.init(center, previous, radius);
        while (arrivals.next()) |at| self.scheduleColumn(index, at);
        self.advanceCursor(index);
    }

    fn refreshVisibility(self: *Streaming, index: usize) void {
        assert(self.geometry.ready(index));
        const revision = self.geometry.revision(index);
        if (self.streams[index].visibility_revision == revision) return;
        const previous = self.streams[index].visibility_revision;
        const previous_origin = self.streams[index].visibility_origin;
        const source = self.geometry.sourceSnapshot(index).section;
        const origin: Position = .{ .x = source.x, .z = source.z };
        self.streams[index].visibility_revision = revision;
        self.streams[index].visibility_origin = origin;
        if (previous == 0 or self.views[index].frontier_debug) {
            self.refreshReady(index);
            return;
        }
        var changed = self.geometry.changes(index);
        while (changed.next()) |at| self.scheduleColumn(index, at);
        // Collision disclosure also depends on the observer, even when world masks agree.
        for ([_]Position{ previous_origin, origin }, 0..) |center, i| {
            if (i == 1 and std.meta.eql(previous_origin, origin)) continue;
            for (0..9) |offset| {
                const relative = chunk_horizon.spiral(offset);
                self.scheduleColumn(index, .{ .x = center.x + relative.x, .z = center.z + relative.z });
            }
        }
        self.advanceCursor(index);
    }

    fn refreshReady(self: *Streaming, index: usize) void {
        if (self.config.occlusion and self.views[index].occlusion) {
            if (!self.sources[index].known) return;
            if (!self.geometry.ready(index)) return;
        }
        const side: usize = @intCast(self.deliveryRadius() * 2 + 1);
        @memset(self.refresh_bits[index * self.grid.words ..][0..self.grid.words], 0);
        self.streams[index].cursor = side * side;
        self.deliveries.refresh_scans.add(1);
        for (0..side * side) |rank| self.scheduleColumn(index, self.order.at(self.streams[index].center, rank));
        self.deliveries.refresh_columns.add(side * side);
        self.advanceCursor(index);
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
        if (value) assert(chunk_horizon.contains(self.deliveryRadius(), self.streams[index].center, at));
        const slot = self.sentIndex(index, at);
        if (!value) {
            if (self.streams[index].debug_history) self.painted[self.columnIndex(index, at)] = 0;
            self.light_receipts.reset(self.columnIndex(index, at), 1);
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
        const terrain = try chunks.Chunks.init(allocator, io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = capacity + 1 }, .{
            .metrics = &registry,
            .storage = try store.openSpace(chunks.Chunks.id),
            .record_workspaces = try persistent_records.Workspaces.init(allocator, io, .{}),
        });
        terrain.attach();
        defer terrain.stop();
        const catalog = try worlds.Worlds.allocate(allocator, .{ .maximum = 1 });
        const world = try catalog.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 24 } });
        var streaming: Streaming = undefined;
        streaming.cpu = .{};
        streaming.deps.chunks = terrain;
        streaming.chunk_client = try terrain.client(.{ .name = "streaming", .sections = capacity });
        streaming.deps.worlds = catalog;
        var player_records = [_]players.Players.Player{.{ .world = world }};
        var player_plugin: players.Players = .{ .deps = undefined, .config = .{ .render_distance = 1 }, .spawn_world = world, .records = &player_records, .dig_handlers = &.{} };
        streaming.deps.players = &player_plugin;
        var views = [_]Streaming.View{.{ .handle = null, .world = world, .protocol = 0, .life = 0, .ready = false, .center = .{ .x = 0, .z = 0 } }};
        streaming.views = &views;
        streaming.config = .{ .prefetch = 0 };
        streaming.grid = .init(streaming.deliveryRadius() * 2 + 1);
        streaming.column_summaries = try allocator.alloc(chunks.classification.ColumnSummary, chunks.classification.column_batch_max);
        streaming.classifications = try allocator.alloc(chunks.encoding.Classification, section_visibility_world.World.batch_max);
        streaming.classification_requests = try allocator.alloc(chunks.Chunks.ClassificationRequest, section_visibility_world.World.batch_max);
        streaming.prepared_classifications = try Streaming.allocatePrepared(allocator);
        streaming.geometry = try .init(allocator, .{ .columns = 9, .views = 1, .radius = 1 });
        var positions: [section_visibility_world.World.batch_max]chunks.Section = undefined;
        for (&positions, 0..) |*position, index| position.* = .{ .world = world, .x = @as(i32, @intCast(index / 24 % 3)) - 1, .y = @intCast(index % 24), .z = @as(i32, @intCast(index / 72)) - 1 };
        try std.testing.expect(try streaming.learnSources(&positions, 0));
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
            _ = try streaming.learnSources(missing[0..count], 0);
            try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
            try std.testing.expect(terrain.cache.pinned_entries <= capacity);
            while (try terrain.generation.processOne(io)) {}
        }
        try std.testing.expectEqual(positions.len, generator.generated);
        try std.testing.expectEqual(@as(usize, 0), terrain.cache.pinned_entries);
        for (positions) |position| try std.testing.expect(streaming.geometry.stoneMask(.{ .world = world, .x = position.x, .z = position.z, .minimum = 0 }, 24) & (@as(u32, 1) << @intCast(position.y)) != 0);
    }
}

test "stored topology supplies adjacent mixed sections without decoding block groups" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = bounded.allocator();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/mixed", .{temporary.sub_path});
    var database = try storage.Store.init(allocator, io, .{ .path = path });
    defer database.deinit();
    var registry = try metrics.Registry.init(allocator, io, .{});
    defer registry.deinit();
    const terrain = try chunks.Chunks.init(allocator, io, .{ .simulation_sections = 0, .cache_sections = 48 }, .{
        .metrics = &registry,
        .storage = try database.openSpace(chunks.Chunks.id),
        .record_workspaces = try persistent_records.Workspaces.init(allocator, io, .{}),
    });
    const metadata = try Streaming.prepareMetadata(allocator, terrain);
    const properties = metadata.properties;
    terrain.attach();
    defer terrain.stop();
    const catalog = try worlds.Worlds.allocate(allocator, .{ .maximum = 1 });
    const world = try catalog.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 4 } });
    const first: chunks.Section = .{ .world = world, .x = 0, .y = 0, .z = 0 };
    const second: chunks.Section = .{ .world = world, .x = 1, .y = 0, .z = 0 };
    const keys = [_][16]u8{ chunks.encodeKey(first), chunks.encodeKey(second) };
    var raw: [chunks.encoding.dense_block_bytes]u8 = undefined;
    raw[0] = 1;
    for (0..4096) |index| std.mem.writeInt(u16, raw[1 + index * 2 ..][0..2], if (index % 2 == 0) game_data.registry.block_stone_default_state else game_data.registry.block_air_default_state, .little);
    var encoded: [raw.len]u8 = undefined;
    const value = try chunks.encoding.encode(&raw, &encoded);
    var column_keys: [8][16]u8 = undefined;
    var column_writes: [8]persistent_records.Write = undefined;
    const air = [_]u8{ 0, 0, 0 };
    for (&column_keys, &column_writes, 0..) |*key, *write, index| {
        key.* = chunks.encodeKey(.{ .world = world, .x = @intCast(index / 4), .y = @intCast(index % 4), .z = 0 });
        write.* = .{ .key = key, .value = if (index % 4 == 0) value else &air };
    }
    try terrain.cache.backend.store.putBatch(&column_writes);
    try terrain.cache.backend.store.flush();
    const columns = [_]chunks.classification.Column{
        .{ .world = first.world, .x = first.x, .z = first.z, .minimum = 0, .count = 4 },
        .{ .world = second.world, .x = second.x, .z = second.z, .minimum = 0, .count = 4 },
    };
    var summaries: [columns.len]chunks.classification.ColumnSummary = undefined;
    try terrain.summarize(&columns, &summaries, properties, section_visibility_world.occluder_property);
    for (summaries) |summary| try std.testing.expectEqual(@as(u32, 1), summary.prefixed);
    terrain.cache.backend.store.bases.invalidate(&keys[0]);
    var streaming: Streaming = undefined;
    streaming.cpu = .{};
    streaming.deps.chunks = terrain;
    streaming.chunk_client = try terrain.client(.{ .name = "streaming", .sections = 24 });
    streaming.deps.worlds = catalog;
    var delivery: lighting.Lighting = undefined;
    delivery.config = .{ .stored = false };
    streaming.deps.lighting = &delivery;
    var player_records = [_]players.Players.Player{.{ .world = world }};
    var subjects: players.Players = .{ .deps = undefined, .config = .{ .render_distance = 1 }, .spawn_world = world, .records = &player_records, .dig_handlers = &.{} };
    streaming.deps.players = &subjects;
    var views = [_]Streaming.View{.{ .handle = null, .world = world, .protocol = 0, .life = 0, .ready = false, .center = .{ .x = 0, .z = 0 } }};
    streaming.views = &views;
    streaming.config = .{ .prefetch = 0 };
    streaming.grid = .init(streaming.deliveryRadius() * 2 + 1);
    streaming.column_summaries = try allocator.alloc(chunks.classification.ColumnSummary, chunks.classification.column_batch_max);
    streaming.classifications = try allocator.alloc(chunks.encoding.Classification, section_visibility_world.World.batch_max);
    streaming.classification_requests = try allocator.alloc(chunks.Chunks.ClassificationRequest, section_visibility_world.World.batch_max);
    streaming.prepared_classifications = try Streaming.allocatePrepared(allocator);
    streaming.geometry = try .init(allocator, .{ .columns = 9, .views = 1, .radius = 1, .properties = properties });
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    const reads = terrain.cache.backend.store.bases.metrics.reads.value();
    const decoded = terrain.cache.backend.store.classification_decoded_bytes.value();
    try std.testing.expect(try streaming.learnTopologies(&columns, 0));
    try std.testing.expectEqual(reads, terrain.cache.backend.store.bases.metrics.reads.value());
    try std.testing.expectEqual(decoded, terrain.cache.backend.store.classification_decoded_bytes.value());
    try std.testing.expect(streaming.geometry.hasTopology(first, 0, 4));
    try std.testing.expect(streaming.geometry.hasTopology(second, 0, 4));
    const restored_topology = streaming.geometry.restored;
    try std.testing.expectEqual(@as(u64, 2), restored_topology);
    try std.testing.expect(try streaming.learnSources(&.{ first, second }, 0));
    try std.testing.expectEqual(reads, terrain.cache.backend.store.bases.metrics.reads.value());
    for ([_]chunks.Section{ first, second }) |section| {
        try std.testing.expect(streaming.geometry.known(section, 0, 4));
        const tile = streaming.geometry.lookup.get(.{ .world = world, .x = section.x, .z = section.z, .minimum = 0 }).?;
        const topology = streaming.geometry.mixed[streaming.geometry.tiles[tile].sections[0]].data;
        for (topology.solid) |word| try std.testing.expectEqual(@as(u64, 0x5555555555555555), word);
    }
    try std.testing.expect(!try streaming.learnSources(&.{second}, 0));
    try std.testing.expectEqual(reads, terrain.cache.backend.store.bases.metrics.reads.value());
    try std.testing.expectEqual(restored_topology + 2, streaming.geometry.restored);
    try terrain.setBlock(world, .{ .x = 2, .y = 8, .z = 8 }, game_data.registry.block_air_default_state);
    try terrain.checkpoint(try database.openSpace(chunks.Chunks.id));
    try database.waitDurable(try database.commit(database.lastTick() + 1));
    terrain.cache.invalidate(&keys[0]);
    streaming.geometry.invalidate();
    const reads_after_edit = terrain.cache.backend.store.bases.metrics.reads.value();
    try std.testing.expect(try streaming.learnSources(&.{first}, 0));
    try std.testing.expectEqual(reads_after_edit, terrain.cache.backend.store.bases.metrics.reads.value());
    const tile = streaming.geometry.lookup.get(.{ .world = world, .x = first.x, .z = first.z, .minimum = 0 }).?;
    const topology = streaming.geometry.mixed[streaming.geometry.tiles[tile].sections[0]].data;
    try std.testing.expectEqual(@as(u16, 7), topology.components);
    try std.testing.expectEqual(restored_topology + 3, streaming.geometry.restored);
    try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
    try std.testing.expect(!bounded.has_induced_failure);
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
        const at = chunk_horizon.spiral(index);
        const distance = @max(@abs(at.x), @abs(at.z));
        try std.testing.expect(distance >= previous and distance <= radius);
        previous = distance;
        const slot: usize = @intCast((at.z + radius) * side + at.x + radius);
        try std.testing.expect(!visited[slot]);
        visited[slot] = true;
    }
    for (visited) |present| try std.testing.expect(present);
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
    streaming.light_receipts = .{ .entries = &receipts, .rules = @splat(1) };
    streaming.sent = &sent;
    streaming.refresh_bits = &refresh;
    streaming.biome_disclosed = &masks[0];
    streaming.occluded = &masks[1];
    streaming.stale = &masks[2];
    streaming.disclosed = &masks[3];
    streaming.grid = .init(streaming.deliveryRadius() * 2 + 1);
    streaming.dirty_words = try .initEmpty(arena.allocator(), 2);
    const at: Streaming.Position = .{ .x = 0, .z = 0 };
    const recipients = [_]sessions.Handle{ .{ .index = 0, .generation = 1 }, .{ .index = 1, .generation = 1 } };
    const view: chunks.Light.View = .{ .header = .{ .rules = @splat(1), .minimum = 0, .count = 1, .skylight = true, .coverage = 1, .revisions = @splat(0), .biomes = @splat(0) }, .masks = .{ 2, 7 } };
    const original: lighting.Data = .{ .source = .{ .stored = &view }, .count = 3, .masks = .{ 2, 7 }, .disclosure = 1 };
    var data = original;
    const update = streaming.retainLight(at, &recipients, &data);
    streaming.light_receipts.apply(streaming.columnIndex(0, at), update);
    data = original;
    _ = streaming.retainLight(at, &recipients, &data);
    try std.testing.expectEqual([2]u32{ 0, 0 }, data.retained);
    data = original;
    _ = streaming.retainLight(at, recipients[0..1], &data);
    try std.testing.expectEqual([2]u32{ 7, 7 }, data.retained);
    streaming.light_receipts.apply(streaming.columnIndex(1, at), update);
    data = original;
    _ = streaming.retainLight(at, &recipients, &data);
    try std.testing.expectEqual([2]u32{ 7, 7 }, data.retained);
    var streams: [2]Streaming.Stream = @splat(.{});
    streaming.streams = &streams;
    streaming.order = try chunk_horizon.Order.init(std.testing.allocator, streaming.deliveryRadius(), 4);
    defer std.testing.allocator.free(streaming.order.ranks);
    streaming.markSent(0, at, false);
    try std.testing.expectEqual([2]u32{ 0, 0 }, streaming.light_receipts.retained(streaming.columnIndex(0, at), streaming.light_receipts.capture(original)));
    try std.testing.expectEqual([2]u32{ 7, 7 }, streaming.light_receipts.retained(streaming.columnIndex(1, at), streaming.light_receipts.capture(original)));
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
    streaming.deps = .{ .metrics = undefined, .players = &subjects, .chunks = undefined, .sessions = undefined, .packets = undefined, .worlds = undefined, .lighting = undefined, .blocks = undefined };
    streaming.views = &views;
    streaming.streams = &streams;
    streaming.order = try chunk_horizon.Order.init(std.testing.allocator, streaming.deliveryRadius(), 4);
    defer std.testing.allocator.free(streaming.order.ranks);
    streaming.sources = &sources;
    streaming.sent = &sent;
    streaming.occluded = &occluded;
    streaming.disclosed = &disclosed;
    streaming.refresh_bits = &refresh;
    streaming.grid = .init(streaming.deliveryRadius() * 2 + 1);
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
    var biomes: [18]?section_views.Biomes = @splat(null);
    biomes[8] = .{ .values = &secret };
    biomes[9] = .{ .values = &exposed };
    const source: chunk_encoding.BiomeNeighborhood.Source = .{ .loaded = &biomes };
    try std.testing.expect(Streaming.disclosedBiome(source, 2, 0) == null);
    try std.testing.expectEqual(@as(?u16, 12), Streaming.disclosedBiome(source, 2, 2));
    try std.testing.expectEqual(@as(i32, game_data.registry.biomeId("minecraft:plains").?), streaming.coverBiome(0, null));
    streaming.config.fallback_biome = 4;
    try std.testing.expectEqual(@as(i32, 4), streaming.coverBiome(0, null));
    try std.testing.expect(sources[0].biome == null);
    try std.testing.expectEqual(@as(i32, 12), streaming.coverBiome(0, Streaming.disclosedBiome(source, 2, 2)));
    streaming.config.fallback_biome = 6;
    try std.testing.expectEqual(@as(i32, 12), streaming.coverBiome(0, null));
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
    streaming.order = try chunk_horizon.Order.init(std.testing.allocator, streaming.deliveryRadius(), 4);
    defer std.testing.allocator.free(streaming.order.ranks);
    streaming.biome_disclosed = &masks;
    streaming.stale = &stale;
    streaming.sent = &sent;
    streaming.grid = .init(streaming.deliveryRadius() * 2 + 1);
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

test "frontier debug toggles rebuild stopping metadata and restore painted sections before reuse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var subjects: players.Players = .{ .deps = undefined, .config = .{ .render_distance = 0 }, .spawn_world = 0, .records = &.{}, .dig_handlers = &.{} };
    var views = [_]Streaming.View{.{ .handle = .{ .index = 0, .generation = 1 }, .world = 0, .protocol = 772, .life = 0, .ready = true, .center = .{ .x = 0, .z = 0 }, .eye_min = .{ 8, 16, 8 }, .eye_max = 17 }};
    var streams = [_]Streaming.Stream{.{ .generation = 1, .setup = .streaming, .section_count = 3, .minimum_section = 0 }};
    var sources: [1]Streaming.Source = @splat(.{ .known = true });
    var sent = [_]u64{1};
    var disclosed = [_]u32{7};
    var biomes = [_]u32{7};
    var stale = [_]u32{0};
    var painted = [_]u32{0};
    var occluded = [_]u32{0};
    var refresh = [_]u64{0};
    var streaming: Streaming = undefined;
    streaming.config = .{};
    streaming.deps.players = &subjects;
    streaming.views = &views;
    streaming.streams = &streams;
    streaming.sources = &sources;
    streaming.grid = .init(1);
    streaming.sent = &sent;
    streaming.disclosed = &disclosed;
    streaming.biome_disclosed = &biomes;
    streaming.stale = &stale;
    streaming.painted = &painted;
    streaming.occluded = &occluded;
    streaming.refresh_bits = &refresh;
    streaming.source_players = try .init(arena.allocator(), sources.len);
    streaming.order = try chunk_horizon.Order.init(arena.allocator(), 0, 4);
    streaming.deliveries = .{};
    streaming.pending = false;
    streaming.dirty_words = try .initEmpty(arena.allocator(), 1);
    streaming.geometry = try .init(arena.allocator(), .{ .columns = 1, .views = 1, .radius = 0 });
    const origin: section_visibility_world.Source = .{ .section = .{ .world = 0, .x = 0, .y = 1, .z = 0 }, .component = 0, .point = .{ 8, 17, 8 }, .camera_bounds = .{ .minimum = .{ 0, 16, 0 }, .maximum = .{ 16, 32, 16 } } };
    setVisibilitySnapshot(&streaming.geometry, 0, &origin, 0, 3, 0, 7);
    sources[0].origin = &origin;
    const at: Streaming.Position = .{ .x = 0, .z = 0 };
    try std.testing.expect(streaming.canReuseColumn(0, at, 7, 7));
    var current = views[0];
    current.frontier_debug = true;
    streaming.updateView(0, current);
    try std.testing.expect(streams[0].debug_history);
    try std.testing.expect(streaming.geometry.views[0].capture_frontier);
    try std.testing.expect(!streaming.geometry.ready(0));
    try std.testing.expect(!sources[0].known);
    try std.testing.expect(streaming.needsSource(0));
    try std.testing.expect(!streaming.needsRefresh(0, at));
    for (0..3) |_| {
        current.frontier_debug = false;
        streaming.updateView(0, current);
        try std.testing.expect(!streaming.geometry.views[0].capture_frontier);
        try std.testing.expect(!streaming.geometry.ready(0));
        current.frontier_debug = true;
        streaming.updateView(0, current);
        try std.testing.expect(streaming.geometry.views[0].capture_frontier);
        try std.testing.expect(!streaming.geometry.ready(0));
        try std.testing.expect(!streaming.needsRefresh(0, at));
    }
    setVisibilitySnapshot(&streaming.geometry, 0, &origin, 0, 3, 0, 7);
    sources[0].known = true;
    sources[0].origin = &origin;
    streaming.geometry.views[0].outgoing[0] = 2;
    streaming.geometry.views[0].revision += 1;
    streaming.refreshVisibility(0);
    try std.testing.expect(streaming.needsRefresh(0, at));
    try std.testing.expectEqual(@as(u32, 4), streaming.frontierMask(0, at));
    try std.testing.expect(!streaming.canReuseColumn(0, at, 7, 7));
    painted[0] = 4;
    occluded[0] = 4;
    streaming.clearRefresh(0, at);
    try std.testing.expect(streaming.canReuseColumn(0, at, 7, 7));
    streaming.restoreSections(0, at, 7);
    try std.testing.expectEqual(@as(u32, 4), occluded[0]);
    current.frontier_debug = false;
    streaming.updateView(0, current);
    try std.testing.expect(!streaming.geometry.views[0].capture_frontier);
    try std.testing.expect(streaming.geometry.ready(0));
    try std.testing.expect(streaming.needsRefresh(0, at));
    try std.testing.expectEqual(@as(u32, 0), streaming.frontierMask(0, at));
    try std.testing.expect(!streaming.canReuseColumn(0, at, 7, 7));
    try std.testing.expectEqual(@as(u32, 4), streaming.missingSections(0, at, 7));
    painted[0] = 0;
    try std.testing.expect(streaming.canReuseColumn(0, at, 7, 7));
    streaming.restoreSections(0, at, 7);
    try std.testing.expectEqual(@as(u32, 0), occluded[0]);
    current.frontier_debug = true;
    streaming.updateView(0, current);
    try std.testing.expect(!streaming.geometry.ready(0));
    setVisibilitySnapshot(&streaming.geometry, 0, &origin, 0, 3, 0, 3);
    sources[0].known = true;
    streaming.geometry.views[0].outgoing[0] = 2;
    try std.testing.expect(!streaming.canReuseColumn(0, at, 3, 3));
    disclosed[0] = 3;
    try std.testing.expect(streaming.canReuseColumn(0, at, 3, 3));
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
    streaming.order = try chunk_horizon.Order.init(std.testing.allocator, streaming.deliveryRadius(), 4);
    defer std.testing.allocator.free(streaming.order.ranks);
    streaming.sources = &sources;
    streaming.sent = &sent;
    streaming.disclosed = &disclosed;
    streaming.occluded = &occluded;
    streaming.stale = &stale;
    streaming.grid = .init(streaming.deliveryRadius() * 2 + 1);
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
    var streams = [_]Streaming.Snapshot{.{ .generation = 7, .life = 3 }};
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

/// Whether the build selected every one of these protocols, which a single release does not.
fn selectsProtocols(numbers: []const i32) bool {
    for (numbers) |number| {
        for (Streaming.protocol_wires) |wire| {
            if (wire.number == number) break;
        } else return false;
    }
    return true;
}

test "releases whose chunk and light packets come out alike share a family" {
    if (!selectsProtocols(&.{ 771, 772, 773, 774, 775, 776 })) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var selected = try packets.protocols.Default.init(arena.allocator());
    var streaming: Streaming = undefined;
    streaming.delivery_catalog = try chunk_encoding.Workspace.initDeliveryCatalog(arena.allocator(), &selected.values);
    streaming.families = @splat(null);
    // 1.21.6 and 1.21.8 number blocks alike, as do 1.21.9 and 1.21.11; 26.1 adds fluid counts
    // and 26.2 new blocks.
    try std.testing.expect(streaming.sameChunkFamily(771, 772));
    try std.testing.expect(streaming.sameChunkFamily(773, 774));
    try std.testing.expect(!streaming.sameChunkFamily(772, 773));
    try std.testing.expect(!streaming.sameChunkFamily(774, 775));
    try std.testing.expect(!streaming.sameChunkFamily(775, 776));
    // A family is the same whichever member asks first.
    streaming.families = @splat(null);
    try std.testing.expectEqual(streaming.family(774).chunk, streaming.family(773).chunk);
    // Light carries no block numbers, so it only parts where the packet itself does.
    for (Streaming.protocol_wires) |a| for (Streaming.protocol_wires) |b| {
        const alike = a.light_id == b.light_id and std.mem.eql(u8, &a.light_layout, &b.light_layout);
        try std.testing.expectEqual(alike, streaming.sameLightFamily(a.number, b.number));
    };
}

test "chunk audiences respect source readiness retained state and initial center delivery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const columns = 9;
    var records: [2]players.Players.Player = @splat(.{});
    var subjects: players.Players = .{ .deps = undefined, .config = .{ .maximum = 2, .render_distance = 1 }, .spawn_world = 0, .records = &records, .dig_handlers = &.{} };
    var streams: [2]Streaming.Stream = @splat(.{ .generation = 1, .setup = .streaming, .delivered = columns });
    var sources = [_]Streaming.Source{ .{}, .{ .known = true } };
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
    streaming.deps = .{ .metrics = undefined, .players = &subjects, .chunks = undefined, .sessions = undefined, .packets = undefined, .worlds = undefined, .lighting = undefined, .blocks = undefined };
    streaming.streams = &streams;
    streaming.order = try chunk_horizon.Order.init(std.testing.allocator, streaming.deliveryRadius(), 4);
    defer std.testing.allocator.free(streaming.order.ranks);
    streaming.sources = &sources;
    streaming.source_players = try .init(arena.allocator(), sources.len);
    streaming.views = &views;
    streaming.occluded = &occluded;
    streaming.stale = &stale;
    streaming.disclosed = &disclosed;
    streaming.biome_disclosed = &biome_disclosed;
    streaming.refresh_bits = &refresh;
    streaming.sent = &sent;
    streaming.recipients = &recipients;
    streaming.grid = .init(streaming.deliveryRadius() * 2 + 1);
    streaming.geometry = try .init(arena.allocator(), .{ .columns = 9, .views = 3, .radius = 1 });
    const origin: section_visibility_world.Source = .{ .section = .{ .world = 0, .x = 0, .y = 0, .z = 0 }, .component = 0, .point = .{ 0, 0, 0 }, .camera_bounds = .{ .minimum = .{ 0, 0, 0 }, .maximum = .{ 16, 16, 16 } } };
    setVisibilitySnapshot(&streaming.geometry, 1, &origin, -4, 24, 1, 1 << 4);
    streaming.observers_index = try SpatialIndex.init(std.testing.allocator, views.len);
    streaming.tile = null;
    defer streaming.observers_index.deinit(std.testing.allocator);
    for (0..views.len) |index| streaming.updateAudience(index);
    const pending = [_]Streaming.Pending{
        .{ .at = .{ .x = 0, .z = 0 }, .world = 0, .protocol = 772, .owner = 0 },
        .{ .at = .{ .x = 0, .z = 1 }, .world = 0, .protocol = 772, .owner = 1 },
        .{ .at = .{ .x = 1, .z = 0 }, .world = 0, .protocol = 772, .owner = 1 },
    };
    var counts: [pending.len]usize = undefined;
    streaming.planRecipients(&pending, &counts);
    try std.testing.expectEqualSlices(usize, &.{ 2, 1, 1 }, &counts);
    // A player on another release whose chunk packets come out alike shares the packet, and
    // one whose do not gets its own.
    if (selectsProtocols(&.{ 771, 772, 773 })) {
        var selected = try packets.protocols.Default.init(arena.allocator());
        streaming.delivery_catalog = try chunk_encoding.Workspace.initDeliveryCatalog(arena.allocator(), &selected.values);
        streaming.families = @splat(null);
        views[1].protocol = 771;
        streaming.planRecipients(pending[0..1], counts[0..1]);
        try std.testing.expectEqual(@as(usize, 2), counts[0]);
        views[1].protocol = 773;
        streaming.planRecipients(pending[0..1], counts[0..1]);
        try std.testing.expectEqual(@as(usize, 1), counts[0]);
        views[1].protocol = 772;
    }
    streaming.planRecipients(&pending, &counts);
    sources[0] = sources[1];
    setVisibilitySnapshot(&streaming.geometry, 0, &origin, -4, 24, 1, 1 << 4);
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
    var delayed = origin;
    delayed.section.x += 1;
    setVisibilitySnapshot(&streaming.geometry, 1, &delayed, -4, 24, 1, 0);
    streaming.geometry.views[1].ready = false;
    sources[0].known = true;
    sources[1].known = true;
    for (&streams) |*stream| stream.delivered = 1;
    @memset(&sent, 0);
    @memset(&disclosed, 0);
    @memset(&biome_disclosed, 0);
    for (streaming.geometry.views[0..sources.len]) |view| @memset(view.masks, 0);
    const concealed = [_]Streaming.Pending{.{ .at = .{ .x = 1, .z = 0 }, .world = 0, .protocol = 772, .owner = 0 }};
    streaming.planRecipients(&concealed, &delivery_counts);
    try std.testing.expectEqual(@as(usize, 1), delivery_counts[0]);
    streaming.geometry.views[1].ready = true;
    streaming.planRecipients(&concealed, &delivery_counts);
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
    streaming.grid = .init(streaming.deliveryRadius() * 2 + 1);
    streaming.streams = &streams;
    streaming.order = try chunk_horizon.Order.init(std.testing.allocator, streaming.deliveryRadius(), 4);
    defer std.testing.allocator.free(streaming.order.ranks);
    streaming.sources = &sources;
    streaming.source_players = try .init(arena.allocator(), sources.len);
    streaming.views = &views;
    streaming.stale = &stale;
    streaming.disclosed = &disclosed;
    streaming.biome_disclosed = &biomes;
    streaming.geometry = try .init(bounded.allocator(), .{ .columns = 9, .views = 3, .radius = 1 });
    for (&sources, 0..) |*source, index| {
        const origin: section_visibility_world.Source = .{ .section = .{ .world = 0, .x = @intCast(index), .y = 4, .z = 0 }, .component = 0, .point = .{ @as(i32, @intCast(index)) * 16, 65, 0 }, .camera_bounds = .{ .minimum = .{ 0, 64, 0 }, .maximum = .{ 32, 80, 16 } } };
        source.known = true;
        setVisibilitySnapshot(&streaming.geometry, index, &origin, -4, 24, 1, 3 << 7);
    }
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    const at: Streaming.Position = .{ .x = 0, .z = 0 };
    try std.testing.expect(streaming.sameDisclosure(0, 1, at) and streaming.sameDisclosure(1, 0, at));
    const other = streaming.columnIndex(1, at);
    for ([_]*u32{ &stale[other], &disclosed[other], &biomes[other] }) |value| {
        value.* = 1;
        try std.testing.expect(!streaming.sameDisclosure(0, 1, at));
        value.* = 0;
    }
    const query = &streaming.geometry.views[1];
    query.masks[3] = 0;
    try std.testing.expect(streaming.canConceal(0) and streaming.canConceal(1));
    try std.testing.expectEqual(@as(u32, 3 << 7), streaming.geometry.mask(0, 0, 0));
    try std.testing.expectEqual(@as(u32, 0), streaming.geometry.mask(1, 0, 0));
    try std.testing.expect(!streaming.sameDisclosure(0, 1, at));
    query.masks[3] = 3 << 7;
    query.ready = false;
    try std.testing.expect(!streaming.sameDisclosure(0, 1, at));
    query.ready = true;
    for (streaming.geometry.views[0..sources.len]) |view| @memset(view.masks, 0);
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
    streaming.deps = .{ .metrics = undefined, .players = &subjects, .chunks = undefined, .sessions = undefined, .packets = undefined, .worlds = undefined, .lighting = undefined, .blocks = undefined };
    streaming.sent = &sent;
    streaming.occluded = &occluded;
    streaming.disclosed = &disclosed;
    streaming.biome_disclosed = &biome_disclosed;
    streaming.stale = &stale;
    streaming.refresh_bits = &refresh;
    streaming.streams = &streams;
    streaming.order = try chunk_horizon.Order.init(std.testing.allocator, streaming.deliveryRadius(), 4);
    defer std.testing.allocator.free(streaming.order.ranks);
    streaming.grid = .init(streaming.deliveryRadius() * 2 + 1);
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
    streaming.geometry = try .init(arena.allocator(), .{ .columns = 25, .views = 1, .radius = 2 });
    streaming.deps = .{ .metrics = undefined, .players = &subjects, .chunks = undefined, .sessions = undefined, .packets = undefined, .worlds = undefined, .lighting = undefined, .blocks = undefined };
    streaming.streams = &streams;
    streaming.order = try chunk_horizon.Order.init(std.testing.allocator, streaming.deliveryRadius(), 4);
    defer std.testing.allocator.free(streaming.order.ranks);
    streaming.sources = &sources;
    streaming.source_players = try .init(arena.allocator(), sources.len);
    streaming.views = &views;
    streaming.occluded = &occluded;
    streaming.refresh_bits = &refresh;
    streaming.sent = &sent;
    streaming.grid = .init(streaming.deliveryRadius() * 2 + 1);
    streaming.deliveries = .{};
    var masks: [3][count]u32 = @splat(@splat(0));
    streaming.disclosed = &masks[0];
    streaming.biome_disclosed = &masks[1];
    streaming.stale = &masks[2];
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
        try std.testing.expect(!streaming.needsRefresh(0, streams[0].center));
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
    streaming.order = try chunk_horizon.Order.init(std.testing.allocator, streaming.deliveryRadius(), 4);
    defer std.testing.allocator.free(streaming.order.ranks);
    streaming.sources = &sources;
    streaming.source_players = try .init(arena.allocator(), sources.len);
    streaming.views = &views;
    streaming.sent = &sent;
    streaming.refresh_bits = &refresh;
    streaming.disclosed = &disclosed;
    streaming.biome_disclosed = &biomes;
    streaming.occluded = &hidden;
    streaming.stale = &stale;
    streaming.grid = .init(streaming.deliveryRadius() * 2 + 1);
    streaming.deliveries = .{ .reused = reused };
    streaming.dirty_words = try .initEmpty(allocator, 1);
    streaming.geometry = try .init(allocator, .{ .columns = 9, .views = 1, .radius = 1 });
    const air: [4]section_views.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = 0 } });
    for (0..9) |index| streaming.geometry.learn(.{ .world = 0, .x = @as(i32, @intCast(index % 3)) - 1, .z = @as(i32, @intCast(index / 3)) - 1, .minimum = 0 }, &air);
    var origin_storage: section_visibility_world.Source = undefined;
    const origin = streaming.geometry.source(0, 0, 4, .{ 8, 25, 8 }, &origin_storage).?;
    const view_index = @as(usize, 0);
    streaming.geometry.begin(view_index, origin, 0, 4, 1);
    while (!streaming.geometry.ready(view_index)) _ = streaming.geometry.advance();
    sources[0] = .{ .known = true, .origin = origin };
    streaming.refresh(0, false);
    try std.testing.expectEqual(@as(u64, 0), refresh[0]);
    try std.testing.expectEqual(@as(usize, 9), streams[0].cursor);
    for (hidden) |mask| try std.testing.expectEqual(@as(u32, 0), mask);
    try std.testing.expectEqual(@as(u64, 9), reused.value());
    streaming.refreshReady(0);
    try std.testing.expectEqual(@as(u64, 18), reused.value());
    stale[0] = 1;
    streaming.refresh(0, false);
    try std.testing.expectEqual(@as(u64, 1), refresh[0]);
    try std.testing.expectEqual(@as(u32, 1), streaming.missingSections(0, .{ .x = 0, .z = 0 }, 15));
    const catalog = try worlds.Worlds.allocate(allocator, .{ .maximum = 1 });
    _ = try catalog.create(.{ .name = "test:refresh", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 4 } });
    streaming.deps.worlds = catalog;
    streaming.background_players = try lightning_rod.system.IndexSet.init(allocator, 1);
    streaming.background_players.insert(0);
    streaming.cpu = .{};
    streaming.io = std.testing.io;
    var changed: std.Io.Event = .unset;
    streaming.changed = &changed;
    streaming.pending = false;
    stale[0] = 0;
    disclosed[0] = 14;
    refresh[0] = 0;
    streaming.refreshReady(0);
    try std.testing.expectEqual(@as(u64, 1), refresh[0]);
    try std.testing.expectEqual(@as(usize, 0), streams[0].cursor);
}

test "completed leading columns bypass a pending center whose collision terrain is already delivered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const radius = 16;
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
    streaming.order = try chunk_horizon.Order.init(std.testing.allocator, streaming.deliveryRadius(), 4);
    defer std.testing.allocator.free(streaming.order.ranks);
    streaming.sources = &sources;
    streaming.source_players = try .init(arena.allocator(), sources.len);
    streaming.views = &views;
    streaming.sent = &sent;
    streaming.refresh_bits = &refresh;
    streaming.disclosed = &disclosed;
    streaming.biome_disclosed = &biomes;
    streaming.occluded = &hidden;
    streaming.stale = &stale;
    streaming.grid = .init(streaming.deliveryRadius() * 2 + 1);
    streaming.deliveries = .{};
    streaming.dirty_words = try .initEmpty(allocator, words);
    streaming.geometry = try .init(allocator, .{ .columns = columns, .views = 1, .radius = radius });
    var air: [24]section_views.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = 0 } });
    air[0].view = .{ .uniform = game_data.registry.block_stone_default_state };
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
    const view_index = @as(usize, 0);
    streaming.geometry.begin(view_index, origin, -4, 24, radius);
    sources[0] = .{ .origin = origin, .known = true };
    streaming.advanceCursor(0);
    try std.testing.expectEqual(@as(usize, 0), streams[0].cursor);
    while (!streaming.geometry.ready(view_index)) _ = streaming.geometry.advance();
    try std.testing.expect(streaming.deliveryReady(0, leading));
    streaming.refresh(0, false);
    const selected = streaming.order.at(streams[0].center, streams[0].cursor);
    try std.testing.expectEqual(leading.x, selected.x);
    try std.testing.expectEqual(leading.z, selected.z);
    try std.testing.expectEqual(@as(u32, all), streaming.disclosureMasks(0, .{ .world = 0, .x = leading.x, .z = leading.z, .minimum = -4 }, 24).disclosure);
}

test "circular arrivals remain pending until accepted while visibility is unavailable" {
    const radius = 32;
    const prefetch = 3;
    const delivery = radius + prefetch;
    const side = 2 * delivery + 1;
    const words = (side * side + 63) / 64;
    var subjects: players.Players = .{ .deps = undefined, .config = .{ .render_distance = radius }, .spawn_world = 0, .records = &.{}, .dig_handlers = &.{} };
    var streams: [1]Streaming.Stream = @splat(.{ .setup = .streaming });
    var sources: [1]Streaming.Source = @splat(.{});
    var views = [_]Streaming.View{.{ .handle = null, .world = 0, .protocol = 0, .life = 0, .ready = true, .center = .{ .x = 0, .z = 0 }, .occlusion = true }};
    var refresh: [words]u64 = @splat(0);
    var sent: [words]u64 = @splat(std.math.maxInt(u64));
    var streaming: Streaming = undefined;
    streaming.deps.players = &subjects;
    streaming.config = .{ .prefetch = prefetch, .occlusion = true };
    streaming.streams = &streams;
    streaming.order = try chunk_horizon.Order.init(std.testing.allocator, streaming.deliveryRadius(), 4);
    defer std.testing.allocator.free(streaming.order.ranks);
    streaming.sources = &sources;
    streaming.views = &views;
    streaming.refresh_bits = &refresh;
    streaming.sent = &sent;
    streaming.grid = .init(streaming.deliveryRadius() * 2 + 1);
    var arrivals = chunk_horizon.Difference.init(.{ .x = 0, .z = 0 }, .{ .x = -1, .z = 0 }, delivery);
    var expected: usize = 0;
    while (arrivals.next()) |at| {
        const slot = streaming.sentIndex(0, at);
        sent[slot.word] &= ~slot.mask;
        expected += 1;
    }
    var queued_arrivals = chunk_horizon.Difference.init(.{ .x = 0, .z = 0 }, .{ .x = -1, .z = 0 }, delivery);
    streaming.pending = false;
    while (queued_arrivals.next()) |at| {
        streaming.scheduleColumn(0, at);
    }
    try std.testing.expect(streaming.pending);
    var delivered: usize = 0;
    streaming.advanceCursor(0);
    while (streams[0].cursor < side * side) {
        const cursor = streams[0].cursor;
        streaming.advanceCursor(0);
        try std.testing.expectEqual(cursor, streams[0].cursor);
        const at = streaming.order.at(streams[0].center, cursor);
        const slot = streaming.sentIndex(0, at);
        try std.testing.expect(sent[slot.word] & slot.mask == 0);
        sent[slot.word] |= slot.mask;
        streaming.clearRefresh(0, at);
        delivered += 1;
        streaming.advanceCursor(0);
    }
    try std.testing.expectEqual(expected, delivered);
}

test "observer collision disclosure changes even when world visibility masks agree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var subjects: players.Players = .{ .deps = undefined, .config = .{ .render_distance = 2 }, .spawn_world = 0, .records = &.{}, .dig_handlers = &.{} };
    var streams = [_]Streaming.Stream{.{ .setup = .streaming, .generation = 1, .center = .{ .x = 1, .z = 0 }, .cursor = 25, .section_count = 2, .minimum_section = 0, .delivered = 25, .visibility_revision = 1 }};
    var sources = [_]Streaming.Source{.{ .known = true }};
    var views = [_]Streaming.View{.{ .handle = .{ .index = 0, .generation = 1 }, .world = 0, .protocol = 772, .life = 0, .ready = true, .center = .{ .x = 1, .z = 0 }, .eye_min = .{ 16, 8, 8 }, .eye_max = 9, .occlusion = true }};
    var sent = [_]u64{(1 << 25) - 1};
    var pending = [_]u64{0};
    var disclosed: [25]u32 = @splat(3);
    var biomes: [25]u32 = @splat(3);
    var stale: [25]u32 = @splat(0);
    var occluded: [25]u32 = @splat(std.math.maxInt(u32));
    var streaming: Streaming = undefined;
    streaming.deps.players = &subjects;
    streaming.config = .{};
    streaming.streams = &streams;
    streaming.sources = &sources;
    streaming.source_players = try .init(arena.allocator(), sources.len);
    streaming.views = &views;
    streaming.sent = &sent;
    streaming.refresh_bits = &pending;
    streaming.disclosed = &disclosed;
    streaming.biome_disclosed = &biomes;
    streaming.stale = &stale;
    streaming.occluded = &occluded;
    streaming.grid = .init(streaming.deliveryRadius() * 2 + 1);
    streaming.deliveries = .{};
    streaming.pending = false;
    streaming.order = try chunk_horizon.Order.init(allocator, 2, 4);
    streaming.dirty_words = try .initEmpty(allocator, 1);
    streaming.geometry = try .init(allocator, .{ .columns = 25, .views = 1, .radius = 2 });
    const origin: section_visibility_world.Source = .{ .section = .{ .world = 0, .x = 1, .y = 0, .z = 0 }, .component = 0, .point = .{ 16, 9, 8 }, .camera_bounds = .{ .minimum = .{ 0, 0, 0 }, .maximum = .{ 32, 16, 16 } } };
    setVisibilitySnapshot(&streaming.geometry, 0, &origin, 0, 2, 2, 0);
    streaming.geometry.views[0].revision = 2;
    for ([_]i32{ -1, 0 }) |x| occluded[streaming.columnIndex(0, .{ .x = x, .z = 0 })] = ~@as(u32, 1);
    streaming.refreshVisibility(0);
    for (0..25) |rank| {
        const at = streaming.order.at(streams[0].center, rank);
        if (!chunk_horizon.contains(2, streams[0].center, at)) continue;
        const expected: u32 = if ((at.x == 0 or at.x == 1) and at.z == 0) 1 else 0;
        try std.testing.expectEqual(expected, ~occluded[streaming.columnIndex(0, at)] & 3);
    }
    try std.testing.expectEqual(@as(u64, 0), pending[0]);
    try std.testing.expect(streaming.dirty_words.isSet(0));
}

test "unchanged visibility preserves pending delivery without rescanning the horizon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var streaming: Streaming = undefined;
    var streams = [_]Streaming.Stream{.{ .setup = .streaming, .cursor = 7, .visibility_revision = 3 }};
    var pending = [_]u64{1 << 7};
    streaming.streams = &streams;
    streaming.refresh_bits = &pending;
    streaming.geometry = try .init(arena.allocator(), .{ .columns = 9, .views = 1, .radius = 1 });
    const origin: section_visibility_world.Source = .{ .section = .{ .world = 0, .x = 0, .y = 0, .z = 0 }, .component = 0, .point = .{ 8, 8, 8 }, .camera_bounds = .{ .minimum = .{ 0, 0, 0 }, .maximum = .{ 16, 16, 16 } } };
    setVisibilitySnapshot(&streaming.geometry, 0, &origin, 0, 1, 1, 1);
    streaming.geometry.views[0].revision = 3;
    streaming.refreshVisibility(0);
    try std.testing.expectEqual(@as(usize, 7), streams[0].cursor);
    try std.testing.expectEqual(@as(u64, 1 << 7), pending[0]);
}

test "pending column ranks prioritize nearby work and survive source revalidation" {
    const count = 25;
    var subjects: players.Players = .{ .deps = undefined, .config = .{ .render_distance = 2 }, .spawn_world = 0, .records = &.{}, .dig_handlers = &.{} };
    var streams: [1]Streaming.Stream = @splat(.{ .setup = .streaming });
    var sources: [1]Streaming.Source = @splat(.{});
    var refresh = [_]u64{0};
    var sent = [_]u64{(1 << count) - 1};
    var streaming: Streaming = undefined;
    streaming.deps.players = &subjects;
    streaming.config = .{ .occlusion = false };
    streaming.streams = &streams;
    streaming.order = try chunk_horizon.Order.init(std.testing.allocator, streaming.deliveryRadius(), 4);
    defer std.testing.allocator.free(streaming.order.ranks);
    streaming.sources = &sources;
    streaming.refresh_bits = &refresh;
    streaming.sent = &sent;
    streaming.grid = .init(streaming.deliveryRadius() * 2 + 1);
    const near = streaming.order.at(streams[0].center, 10);
    const far = streaming.order.at(streams[0].center, 24);
    const far_slot = streaming.sentIndex(0, .{ .x = far.x, .z = far.z });
    sent[0] &= ~far_slot.mask;
    refresh[0] = (1 << 10) | (1 << 24);
    streaming.advanceCursor(0);
    try std.testing.expectEqual(@as(usize, 10), streams[0].cursor);
    streaming.clearRefresh(0, .{ .x = near.x, .z = near.z });
    streaming.advanceCursor(0);
    try std.testing.expectEqual(@as(usize, 24), streams[0].cursor);
    streaming.refresh(0, true);
    streaming.advanceCursor(0);
    try std.testing.expectEqual(@as(usize, 24), streams[0].cursor);
    try std.testing.expectEqual(@as(u64, 1 << 24), refresh[0]);
}

test "visibility snapshots remain stable until the simulation captures another publication" {
    var streams = [_]Streaming.Snapshot{.{ .generation = 1, .life = 4, .setup = .streaming, .section_count = 24 }};
    var sent = [_]u64{1};
    var published_occluded: [9]u32 = @splat(0);
    var published: Streaming.Published = .{
        .occluded = &published_occluded,
        .light_mail = undefined,
        .light_resolves = .{ .items = &.{} },
        .views = &.{},
        .streams = &streams,
        .sent = &sent,
        .dirty_words = try .initEmpty(std.testing.allocator, sent.len),
        .changed_views = try lightning_rod.system.IndexSet.init(std.testing.allocator, streams.len),
        .dirty_streams = try lightning_rod.system.IndexSet.init(std.testing.allocator, streams.len),
    };
    defer published.dirty_words.deinit(std.testing.allocator);
    defer published.changed_views.deinit(std.testing.allocator);
    defer published.dirty_streams.deinit(std.testing.allocator);
    published.dirty_streams.insert(0);
    var snapshot_streams: [1]Streaming.Snapshot = @splat(.{});
    var changed: [1]u64 = undefined;
    var snapshot_sent = [_]u64{0};
    var snapshot_occluded: [9]u32 = @splat(0);
    var snapshot: Streaming.Visibility = .{ .occluded = &snapshot_occluded, .reset = try lightning_rod.system.IndexSet.init(std.testing.allocator, snapshot_streams.len), .changed = &changed, .changed_words = try lightning_rod.system.IndexSet.init(std.testing.allocator, sent.len), .streams = &snapshot_streams, .sent = &snapshot_sent, .grid = .init(3), .radius = 1 };
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
    var published_streams = [_]Streaming.Snapshot{streams[0].snapshot()};
    var published_sent = sent;
    var published_occluded = occluded;
    var published: Streaming.Published = .{
        .light_mail = undefined,
        .light_resolves = .{ .items = &.{} },
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
    streaming.deps = .{ .metrics = undefined, .players = &subjects, .chunks = undefined, .sessions = undefined, .packets = undefined, .worlds = undefined, .lighting = undefined, .blocks = undefined };
    streaming.native_io = std.testing.io;
    streaming.cpu = .{};
    streaming.deliveries = .{};
    streaming.geometry = try .init(allocator, .{ .columns = 9, .views = 3, .radius = 1 });
    streaming.published = &published;
    streaming.streams = &streams;
    streaming.order = try chunk_horizon.Order.init(std.testing.allocator, streaming.deliveryRadius(), 4);
    defer std.testing.allocator.free(streaming.order.ranks);
    streaming.views = &views;
    streaming.sources = &sources;
    streaming.source_players = try .init(arena.allocator(), sources.len);
    streaming.sent = &sent;
    streaming.refresh_bits = &refresh;
    streaming.occluded = &occluded;
    streaming.disclosed = &disclosed;
    streaming.stale = &stale;
    streaming.grid = .init(streaming.deliveryRadius() * 2 + 1);
    streaming.dirty_words = try .initEmpty(allocator, 1);
    streaming.background_players = try .init(allocator, 1);
    streaming.background_players.insert(0);
    streaming.setup_players = try .init(allocator, 1);
    streaming.publication_players = try .init(allocator, 1);
    streaming.debug_slots = &.{};
    for ([_]bool{ false, true }) |source_changed| {
        streaming.publication_players.insert(0);
        streaming.refresh(0, source_changed);
        try std.testing.expectEqual(@as(u64, 0), refresh[0]);
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
    streaming.geometry = try .init(arena.allocator(), .{ .columns = 25, .views = 1, .radius = 2 });
    setVisibilitySnapshot(&streaming.geometry, 0, &origin, 4, 1, 2, 1);
    streaming.deps = .{ .metrics = undefined, .players = &subjects, .chunks = undefined, .sessions = undefined, .packets = undefined, .worlds = undefined, .lighting = undefined, .blocks = undefined };
    streaming.streams = &streams;
    streaming.order = try chunk_horizon.Order.init(std.testing.allocator, streaming.deliveryRadius(), 4);
    defer std.testing.allocator.free(streaming.order.ranks);
    streaming.sources = &sources;
    streaming.source_players = try .init(arena.allocator(), sources.len);
    streaming.views = &views;
    streaming.refresh_bits = &refresh;
    streaming.sent = &sent;
    streaming.grid = .init(streaming.deliveryRadius() * 2 + 1);
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

test "moving the delivery center remaps pending ranks and schedules only circular arrivals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const radius = 4;
    const columns = (radius * 2 + 1) * (radius * 2 + 1);
    const words = (columns + 63) / 64;
    var subjects: players.Players = .{ .deps = undefined, .config = .{ .render_distance = radius }, .spawn_world = 0, .records = &.{}, .dig_handlers = &.{} };
    var streams: [1]Streaming.Stream = @splat(.{ .setup = .streaming });
    var sources: [1]Streaming.Source = @splat(.{});
    var bits: [words]u64 = @splat(0);
    var scratch: [words]u64 = undefined;
    var sent: [words]u64 = @splat(0);
    var streaming: Streaming = undefined;
    streaming.config = .{ .occlusion = false };
    streaming.deps.players = &subjects;
    streaming.streams = &streams;
    streaming.sources = &sources;
    streaming.source_players = try .init(arena.allocator(), sources.len);
    streaming.refresh_bits = &bits;
    streaming.pending_scratch = &scratch;
    streaming.sent = &sent;
    streaming.grid = .init(streaming.deliveryRadius() * 2 + 1);
    streaming.order = try chunk_horizon.Order.init(arena.allocator(), radius, 4);
    streaming.pending = false;
    const previous: Streaming.Position = .{ .x = 0, .z = 0 };
    const next: Streaming.Position = .{ .x = 1, .z = 0 };
    const pending = [_]Streaming.Position{ .{ .x = -4, .z = 0 }, .{ .x = 0, .z = 0 }, .{ .x = 1, .z = 1 } };
    for (pending) |at| streaming.scheduleColumn(0, at);
    streaming.moveCenter(0, next);
    for (0..columns) |rank| {
        const at = streaming.order.at(next, rank);
        var expected = chunk_horizon.contains(radius, next, at) and !chunk_horizon.contains(radius, previous, at);
        for (pending) |position| expected = expected or (std.meta.eql(position, at) and chunk_horizon.contains(radius, next, at));
        const actual = bits[rank / 64] & (@as(u64, 1) << @intCast(rank % 64)) != 0;
        try std.testing.expectEqual(expected, actual);
    }
}

fn setVisibilitySnapshot(world: *section_visibility_world.World, index: usize, origin: *const section_visibility_world.Source, minimum: i32, count: usize, radius: i32, mask: u32) void {
    const view = &world.views[index];
    view.key = .{ .section = origin.section, .component = origin.component, .minimum = minimum, .count = count, .radius = radius };
    view.origin = origin.*;
    view.ready = true;
    @memset(view.masks, mask);
}

test "columns stay loaded out to the client storage until an edit there makes them stale" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Matches ClientChunkCache.calculateStorageRange: max(2, view distance) + 3.
    try std.testing.expectEqual(@as(i32, 5), Streaming.keepRadiusFor(1));
    try std.testing.expectEqual(@as(i32, 35), Streaming.keepRadiusFor(32));
    // View distance 1 keeps columns out to radius 5, an 11 by 11 grid.
    const side = 11;
    const columns = side * side;
    try std.testing.expectEqual(@as(i32, side), Streaming.keepRadiusFor(1) * 2 + 1);
    var records: [1]players.Players.Player = @splat(.{});
    var subjects: players.Players = .{ .deps = undefined, .config = .{ .maximum = 1, .render_distance = 1 }, .spawn_world = 0, .records = &records, .dig_handlers = &.{} };
    var streams: [1]Streaming.Stream = @splat(.{ .generation = 1, .setup = .streaming });
    var views: [1]Streaming.View = .{.{ .handle = .{ .index = 0, .generation = 1 }, .world = 0, .protocol = 772, .life = 0, .ready = true, .center = .{ .x = 0, .z = 0 } }};
    var masks: [5][columns]u32 = @splat(@splat(0));
    var receipts: [columns]lighting.Receipt = @splat(.{});
    var sent: [(columns + 63) / 64]u64 = @splat(0);
    var refresh = sent;
    var streaming: Streaming = undefined;
    streaming.config = .{};
    streaming.deps = .{ .metrics = undefined, .players = &subjects, .chunks = undefined, .sessions = undefined, .packets = undefined, .worlds = undefined, .lighting = undefined, .blocks = undefined };
    streaming.streams = &streams;
    streaming.views = &views;
    streaming.grid = .init(side);
    streaming.order = try chunk_horizon.Order.init(std.testing.allocator, streaming.deliveryRadius(), 4);
    defer std.testing.allocator.free(streaming.order.ranks);
    streaming.occluded = &masks[0];
    streaming.stale = &masks[1];
    streaming.disclosed = &masks[2];
    streaming.biome_disclosed = &masks[3];
    streaming.painted = &masks[4];
    streaming.light_receipts = .{ .entries = &receipts, .rules = @splat(1) };
    streaming.sent = &sent;
    streaming.refresh_bits = &refresh;
    streaming.dirty_words = try .initEmpty(arena.allocator(), sent.len);
    streaming.observers_index = try SpatialIndex.init(std.testing.allocator, views.len);
    defer streaming.observers_index.deinit(std.testing.allocator);
    streaming.tile = null;
    const column: Streaming.Position = .{ .x = 1, .z = 0 };
    streaming.markSent(0, column, true);
    // Moving four chunks east takes the column out of delivery but not out of client storage.
    const east: Streaming.Position = .{ .x = 4, .z = 0 };
    var departing = chunk_horizon.Difference.init(streams[0].center, east, streaming.keepRadius());
    while (departing.next()) |at| try std.testing.expect(!std.meta.eql(at, column));
    streams[0].center = east;
    views[0].center = east;
    streaming.updateAudience(0);
    try std.testing.expect(!chunk_horizon.contains(streaming.deliveryRadius(), east, column) and streaming.hasSent(0, column));
    // Edits whose light cannot reach the column leave the client copy usable.
    streaming.forgetKept(.{ .world = 0, .x = 4, .y = 0, .z = 0 });
    try std.testing.expect(streaming.hasSent(0, column));
    // An edit next to it may change its light, and it receives no deltas, so it is forgotten.
    streaming.forgetKept(.{ .world = 0, .x = 2, .y = 0, .z = 0 });
    try std.testing.expect(!streaming.hasSent(0, column));
}

test "light mail carries each patched section as it was and refuses what it has no room for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const mail = try Streaming.LightMail.create(arena.allocator(), 1);
    try std.testing.expect(mail.empty());
    var dense: [3][light_store.section_bytes]u8 = undefined;
    for (&dense, 0..) |*bytes, index| @memset(bytes, @intCast(index + 1));
    var light: light_store.Sections = undefined;
    light.light[0][2] = .{ .dense = &dense[0] };
    light.light[0][5] = .{ .uniform = 7 };
    light.light[1][2] = .{ .dense = &dense[1] };
    try std.testing.expect(mail.add(3, .{ .x = -4, .z = 9 }, .{ 0b100100, 0b100 }, &light));
    // The mail holds its own copy. What the store does next cannot change it.
    @memset(&dense[0], 0xee);
    light.light[1][0] = .{ .dense = &dense[2] };
    try std.testing.expect(mail.add(3, .{ .x = -4, .z = 9 }, .{ 0, 0b1 }, &light));
    try std.testing.expect(!mail.empty());
    try std.testing.expectEqual(@as(usize, 3), mail.used);

    var view: light_store.Sections = undefined;
    const first = &mail.deltas[0];
    mail.view(first, &view);
    try std.testing.expectEqual([2]u32{ 0b100100, 0b100 }, first.sections);
    try std.testing.expectEqual(@as(u8, 1), view.light[0][2].dense[100]);
    try std.testing.expectEqual(@as(u4, 7), view.light[0][5].uniform);
    try std.testing.expectEqual(@as(u8, 2), view.light[1][2].dense[0]);
    mail.view(&mail.deltas[1], &view);
    try std.testing.expectEqual(@as(u8, 3), view.light[1][0].dense[2047]);

    // Without room for every dense section of a column nothing of it is taken.
    var everything: light_store.Sections = undefined;
    for (0..2) |layer| for (0..light_store.sections_max) |section| {
        everything.light[layer][section] = .{ .dense = &dense[1] };
    };
    const all = (@as(u32, 1) << light_store.sections_max) - 1;
    var taken: usize = 0;
    while (mail.add(0, .{ .x = @intCast(taken), .z = 0 }, .{ all, all }, &everything)) taken += 1;
    try std.testing.expect(taken >= 1);
    try std.testing.expectEqual(@as(usize, 2 + taken), mail.count);
    try std.testing.expectEqual(@as(usize, 3 + taken * 2 * light_store.sections_max), mail.used);
    // Uniform sections need none, so they still fit until the list of columns is full.
    try std.testing.expect(mail.add(0, .{ .x = 0, .z = 1 }, .{ 0b100000, 0 }, &light));
    while (mail.add(0, .{ .x = 0, .z = 2 }, .{ 0b100000, 0 }, &light)) {}
    try std.testing.expectEqual(mail.deltas.len, mail.count);

    mail.next = mail.count;
    try std.testing.expect(mail.empty());
    mail.clear();
    try std.testing.expectEqual(@as(usize, 0), mail.used);
}

test "light solves waiting for the store keep the newest request of a column and drop the oldest column" {
    var slots: [3]Streaming.LightResolve = undefined;
    var resolves: Streaming.LightResolves = .{ .items = &slots };
    resolves.add(.{ .world = 0, .at = .{ .x = 1, .z = 1 }, .stamp = 10, .wanted = false });
    resolves.add(.{ .world = 0, .at = .{ .x = 2, .z = 1 }, .stamp = 11, .wanted = true });
    // A later edit darkens the column again. Only a solve made after it may light the store.
    resolves.add(.{ .world = 0, .at = .{ .x = 1, .z = 1 }, .stamp = 12, .wanted = false });
    try std.testing.expectEqual(@as(usize, 2), resolves.count);
    try std.testing.expectEqual(@as(?u64, 12), resolves.find(0, .{ .x = 1, .z = 1 }));
    try std.testing.expectEqual(@as(?u64, null), resolves.find(1, .{ .x = 1, .z = 1 }));
    try std.testing.expectEqual(@as(u64, 11), resolves.wanted().?.stamp);
    resolves.add(.{ .world = 1, .at = .{ .x = 1, .z = 1 }, .stamp = 13, .wanted = false });
    resolves.add(.{ .world = 0, .at = .{ .x = 9, .z = 9 }, .stamp = 14, .wanted = false });
    // The list was full, so the request that waited longest gave way.
    try std.testing.expectEqual(@as(usize, 3), resolves.count);
    try std.testing.expectEqual(@as(?u64, null), resolves.find(0, .{ .x = 2, .z = 1 }));
    try std.testing.expect(resolves.wanted() == null);
    resolves.remove(0, .{ .x = 1, .z = 1 });
    resolves.remove(0, .{ .x = 1, .z = 1 });
    try std.testing.expectEqual(@as(usize, 2), resolves.count);
    try std.testing.expectEqual(@as(?u64, 13), resolves.find(1, .{ .x = 1, .z = 1 }));
    try std.testing.expectEqual(@as(?u64, 14), resolves.find(0, .{ .x = 9, .z = 9 }));
}
