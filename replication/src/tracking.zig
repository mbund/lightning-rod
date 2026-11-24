//! Who sees which entity, for every kind at once: vanilla's ChunkMap.TrackedEntity.updatePlayer,
//! with the occlusion of what the client was sent on top.
//!
//! A player sees an entity when both are in the same world, the player is within the entity's
//! tracking range (its type's, raised by its passengers' as getEffectiveRange does, and no
//! further than the player's view distance) measured horizontally from their feet, the entity
//! lets the player see it (broadcastToPlayer), the entity's chunk was sent to the player
//! (isChunkTracked), and some section its box is in is not hidden from the player.
//!
//! What each client was told lives here, a row of player bits for every directory slot: `known`
//! is who has the entity spawned, `stale` who of them missed a delta and needs it whole. Each
//! tick, what changed (players moving, reconnecting, changing view distance, chunks sent or
//! hidden, entities moving, spawning, leaving) picks the entities whose answer can differ and
//! for which players; only those are asked again. Kinds take the differences, send what they
//! send in their own order, and confirm what was accepted: what was not is offered again.
//!
//! An entity some client still knows keeps its directory slot, and with it its network id,
//! until every such client was told it is gone.

const std = @import("std");
const entities_module = @import("entities");
const lightning_rod = @import("lightning_rod");
const Players = @import("players").players.Players;
const Player = Players.Player;
const Streaming = @import("terrain").streaming.Streaming;
const geometry_bounds = @import("occlusion").bounds;
const PlayerChanges = @import("player_changes.zig").PlayerChanges;

const bit_sets = lightning_rod.system.bit_sets;
const Entities = entities_module.Entities;
const Array = entities_module.Array;
const Entry = entities_module.space.Entry;
const Sweeps = entities_module.Sweeps;
const Sweep = entities_module.sweeps.Sweep;
const SweptBox = entities_module.sweeps.Box;
const Placed = entities_module.Space.Placed;
const builtin = @import("builtin");
const Kinds = entities_module.Kinds;
const Column = entities_module.Column;
const assert = std.debug.assert;

pub const Tracking = struct {
    pub const id = "lightning_rod:tracking";

    pub const Configuration = struct {
        /// server.properties entity-broadcast-range-percentage: every tracking range scaled by it,
        /// as a dedicated server does, from 10 to 1000.
        range_percentage: u32 = 100,
        /// Entities whose answer can change in one tick before the tick looks over every entity
        /// near every player instead.
        work: u32 = 65536,
    };

    pub const Dependencies = struct {
        entities: *Entities,
        players: *Players,
        streaming: ?*Streaming = null,
    };

    /// What a kind tells about its entities.
    pub const Spec = struct {
        kinds: Kinds,
        /// The type's tracking range in blocks: EntityType clientTrackingRange × 16.
        range: u32,
        /// The most any of its entities' own ranges reaches, as one carrying passengers takes theirs:
        /// the range when none has a range of its own.
        max_range: ?u32 = null,
        /// Where its entities that do not keep a place in the space every tick are: a box each
        /// stays in until a tick. With them, `exact` says where one is now, which tracking asks
        /// only where a box leaves an answer unsure.
        sweeps: ?*Sweeps = null,
        exact: ?Exact = null,
    };

    /// Where a swept entity is now, from its kind: without side effects, as tracking asks it
    /// whenever it must.
    pub const Exact = struct {
        context: *anyopaque,
        place: *const fn (*anyopaque, u32) anyerror!Placed,

        /// `Kind.trackingPlace(kind, slot) !Placed`.
        pub fn of(comptime Kind: type, kind: *Kind) Exact {
            const Adapter = struct {
                fn place(raw: *anyopaque, slot: u32) anyerror!Placed {
                    return Kind.trackingPlace(@ptrCast(@alignCast(raw)), slot);
                }
            };
            return .{ .context = kind, .place = Adapter.place };
        }
    };

    /// One player's answer for an entity anywhere in a box: the same everywhere, or unsure.
    const Answer = enum { no, yes, unsure };

    pub const TrackerId = u8;
    const max_trackers = 32;
    const no_tracker = std.math.maxInt(u8);
    const none = std.math.maxInt(u32);

    /// `own_ranges` counts its entities with ranges of their own: with none, the group's circle is
    /// every one's.
    const Group = struct { range: f64, kinds: Kinds, own_ranges: u32 = 0, live: bool = true };

    const Tracker = struct {
        kinds: Kinds,
        range: f64,
        max_range: f64,
        group: u8,
        sweeps: ?*Sweeps,
        exact: ?Exact,
    };
    const no_owner = std.math.maxInt(u16);
    const PlayerBounds = struct { world: u32, low: [2]f64, high: [2]f64 };
    const NearKey = struct { world: u32, x: i32, z: i32, chunks: i32 };
    const Run = struct { start: u32, count: u32 };
    const SeenKey = struct { world: u32, x: i32, z: i32, footprint: Footprint };
    /// Columns and footprints one tick shares; past them each entity asks alone.
    const shared_columns = 4096;
    const bounds_max = 8;
    const any_world = std.math.maxInt(u32);

    /// What tracking keeps of an entity beside its rows.
    const Meta = struct {
        tracker: u8 = no_tracker,
        /// The entity the rest is about, as a slot comes to hold another.
        entity: u64 = 0,
        /// Its entry in this tick's work, or none.
        work: u32 = none,
        /// The tick it was last looked at, so a log naming it twice costs once.
        looked: u64 = 0,
        /// Gone from the space, its removal owed to whoever still knows it.
        gone: bool = false,
        /// The tick it last joined the unsettled, so it joins once.
        unsettled: u64 = 0,
        /// The tracking tick a kind was told an entity is settled anywhere in a box, and the box:
        /// swept there that tick, it needs no asking again.
        settled_for: u64 = 0,
        settled_box: SweptBox = .{ .low = .{ 0, 0, 0 }, .high = .{ 0, 0, 0 } },
        /// What the entity says of itself, which the rule reads: its own range, scaled, where it
        /// is not its type's (getEffectiveRange with passengers); the player it is, who never
        /// sees itself; whether only spectators see it (ServerPlayer.broadcastToPlayer); and
        /// whether only the players of its allowed row may.
        range: f64 = 0,
        owner: u16 = no_owner,
        spectators_only: bool = false,
        restricted: bool = false,
        /// Where it was checked against every player, how far it could go from there before any
        /// answer could change, and the players' drift and epoch then.
        world: u32 = 0,
        x: f64 = 0,
        z: f64 = 0,
        /// Its own column, then the columns and sections its box is in, as occlusion reads them.
        column: [2]i32 = .{ 0, 0 },
        footprint: Footprint = .{},
        margin: f64 = -1,
        drift: f64 = 0,
        epoch: u64 = 0,
    };

    /// A change of one entity's audience to send: whom to spawn it for, whom to remove it from,
    /// and whether it is gone.
    pub const Change = struct {
        slot: u32,
        spawn: bit_sets.Set,
        remove: bit_sets.Set,
        gone: bool,
    };

    deps: Dependencies,
    config: Configuration,
    changes: PlayerChanges,
    trackers: [max_trackers]Tracker = undefined,
    tracker_count: usize = 0,
    tracker_of: [Kinds.max_kinds]u8 = @splat(no_tracker),
    tracked: Kinds = .{},
    /// The trackers' kinds by their widest range, so each ring is walked once a range.
    groups: [max_trackers]Group = undefined,
    group_count: usize = 0,
    /// Every kind's sweeps, once each.
    sources: [max_trackers]*Sweeps = undefined,
    source_count: usize = 0,
    /// Swept entities some player was unsure of this tick: asked again the next.
    unsettled: Array(u32),
    /// Words of player bits in a row as kept: a power of two, so a slot's rows share a page.
    words: usize,
    /// Words of player bits in the sets handed out: as many as the players need.
    row_words: usize,
    /// Every slot's known row then its stale row.
    rows: Array(u64),
    metas: Array(Meta),
    /// This tick's work: the slots, and for each its mask of players and their answers, which
    /// become the spawn and remove rows once the tick has looked everything over.
    work_slots: Array(u32),
    work_rows: Array(u64),
    work_overflowed: bool = false,
    /// Slots whose differences were not all accepted, asked again next tick.
    retry: Array(u32),
    /// Slots of entities gone that clients still know.
    gone: Array(u32),
    candidates: []u16,
    /// This tick's players near each column, and who of them the terrain lets see each box
    /// footprint there: shared by every entity of the column, as a volley's arrows or a herd are.
    near_columns: std.AutoHashMapUnmanaged(NearKey, Run),
    near_players: []u16,
    near_count: usize = 0,
    seen_footprints: std.AutoHashMapUnmanaged(SeenKey, u32),
    seen_rows: []u64,
    seen_count: usize = 0,
    /// The players as columns, for the distance test eight at a time.
    xs: []f64,
    zs: []f64,
    reaches: []f64,
    worlds: []u32,
    ready: []bool,
    spectating: []bool,
    /// The box around each world's ready players this tick, horizontally: an entity whose reach
    /// misses it is seen by no one, without looking for players. Past room for worlds, the last
    /// stands for every other and covers everything.
    bounds: [bounds_max]PlayerBounds = undefined,
    bounds_count: usize = 0,
    /// For entities only some players may see, those players, by slot.
    allowed: Array(u64),
    scratch: []u64,
    /// A row of nobody, for slots never tracked.
    zeros: []u64,
    tick_count: u64 = 0,
    /// Players as subjects too, once asked: each in the space while in its world, by a slot of
    /// its own, its tracker's and its kind.
    player_tracker: ?TrackerId = null,
    player_kind: u32 = 0,
    player_slots: []u32,
    player_ids: []u64,
    subject_at: [][3]f64,
    subject_world: []u32,
    /// Whether each was last told tracking it is in spectator mode.
    subject_spectator: []bool,
    /// Their x and z apart, for the distance test eight at a time; none where there is none.
    subject_x: []f64,
    subject_z: []f64,
    /// Each observer's last measure of players as subjects: where, the drift then, and how far
    /// the nearest was from its edge; negative asks for a measure.
    player_anchor: [][2]f64,
    player_drift: []f64,
    player_slack: []f64,
    finalized: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Tracking {
        if (config.range_percentage < 10 or config.range_percentage > 1000 or config.work == 0) return error.InvalidConfiguration;
        const self = try allocator.create(Tracking);
        const count = deps.players.records.len;
        // A power of two, so a slot's rows never straddle a page.
        const words = try std.math.ceilPowerOfTwo(usize, @max(1, std.math.divCeil(usize, count, 64) catch unreachable));
        const pool = &deps.entities.pool;
        var near_columns: std.AutoHashMapUnmanaged(NearKey, Run) = .empty;
        try near_columns.ensureTotalCapacity(allocator, shared_columns);
        var seen_footprints: std.AutoHashMapUnmanaged(SeenKey, u32) = .empty;
        try seen_footprints.ensureTotalCapacity(allocator, shared_columns);
        self.* = .{
            .deps = deps,
            .config = config,
            .changes = try .init(allocator, count, true),
            .words = words,
            .row_words = std.math.divCeil(usize, count, 64) catch unreachable,
            .rows = try .init(allocator, pool),
            .metas = try .init(allocator, pool),
            .work_slots = try .init(allocator, pool),
            .work_rows = try .init(allocator, pool),
            .retry = try .init(allocator, pool),
            .unsettled = try .init(allocator, pool),
            .gone = try .init(allocator, pool),
            .candidates = try allocator.alloc(u16, count),
            .near_columns = near_columns,
            .near_players = try allocator.alloc(u16, shared_columns * 16),
            .seen_footprints = seen_footprints,
            .seen_rows = try allocator.alloc(u64, shared_columns * words),
            .xs = try allocator.alloc(f64, count),
            .zs = try allocator.alloc(f64, count),
            .reaches = try allocator.alloc(f64, count),
            .worlds = try allocator.alloc(u32, count),
            .ready = try allocator.alloc(bool, count),
            .spectating = try allocator.alloc(bool, count),
            .player_slots = try allocator.alloc(u32, count),
            .player_ids = try allocator.alloc(u64, count),
            .subject_at = try allocator.alloc([3]f64, count),
            .subject_world = try allocator.alloc(u32, count),
            .subject_spectator = try allocator.alloc(bool, count),
            .subject_x = try allocator.alloc(f64, std.mem.alignForward(usize, count, 8)),
            .subject_z = try allocator.alloc(f64, std.mem.alignForward(usize, count, 8)),
            .player_anchor = try allocator.alloc([2]f64, count),
            .player_drift = try allocator.alloc(f64, count),
            .player_slack = try allocator.alloc(f64, count),
            .allowed = try .init(allocator, pool),
            .scratch = try allocator.alloc(u64, 4 * words),
            .zeros = try allocator.alloc(u64, words),
        };
        @memset(self.ready, false);
        @memset(self.spectating, false);
        @memset(self.player_slots, none);
        @memset(self.player_ids, 0);
        @memset(self.subject_x, std.math.inf(f64));
        @memset(self.player_slack, -1);
        @memset(self.subject_spectator, false);
        @memset(self.player_drift, 0);
        @memset(self.player_anchor, .{ 0, 0 });
        @memset(self.subject_z, std.math.inf(f64));
        @memset(self.zeros, 0);
        deps.entities.places.space.logging = true;
        return self;
    }

    /// Players are tracked as entities of a kind from now on, at vanilla's 32 chunks: each in the
    /// space from joining its world, never shown itself, and in spectator mode shown to spectators
    /// alone (ServerPlayer.broadcastToPlayer). Call while starting.
    pub fn trackPlayers(self: *Tracking, kind: u32) !TrackerId {
        const tracker = try self.register(.{ .kinds = .of(&.{kind}), .range = 32 * 16 });
        self.player_tracker = tracker;
        self.player_kind = kind;
        return tracker;
    }

    /// The slot a player is tracked by as a subject, if it is in its world.
    pub fn playerSlot(self: *const Tracking, player: usize) ?u32 {
        const slot = self.player_slots[player];
        return if (slot == none) null else slot;
    }

    /// Ids of players as subjects, apart from every entity's, which count up from one.
    const player_id_base: u64 = 1 << 63;

    /// Players as subjects follow the players: placed while in their world, moved as they move,
    /// gone as they leave it or their connection does.
    fn syncPlayers(self: *Tracking) !void {
        if (self.player_tracker == null) return;
        for (self.deps.players.records, self.changes.snapshots, 0..) |player, snapshot, index| {
            const entity = player_id_base | (@as(u64, snapshot.generation) << 16) | index;
            // In its world from joining, as vanilla adds a player to its level before the first
            // teleport is confirmed.
            const wanted = player.inWorld();
            if (self.player_slots[index] != none and (!wanted or self.player_ids[index] != entity)) {
                const slot = self.player_slots[index];
                self.player_slots[index] = none;
                self.subject_x[index] = std.math.inf(f64);
                self.subject_z[index] = std.math.inf(f64);
                self.deps.entities.leave(slot);
                try self.look(slot, false);
            }
            if (!wanted) continue;
            const position: [3]f64 = .{ player.position.x, player.position.y, player.position.z };
            if (self.player_slots[index] == none) {
                const slot = try self.deps.entities.enter(entity, self.player_kind);
                self.player_slots[index] = slot;
                self.player_ids[index] = entity;
                self.subject_at[index] = position;
                self.subject_world[index] = player.world;
                self.subject_x[index] = position[0];
                self.subject_z[index] = position[2];
                self.subject_spectator[index] = false;
                self.nearObservers(index);
                try self.setOwner(slot, index);
                try self.look(slot, false);
            } else if (self.subject_world[index] != player.world or !std.meta.eql(self.subject_at[index], position)) {
                self.subject_at[index] = position;
                self.subject_world[index] = player.world;
                self.subject_x[index] = position[0];
                self.subject_z[index] = position[2];
                try self.look(self.player_slots[index], true);
            }
            if (self.subject_spectator[index] != snapshot.spectator) {
                self.subject_spectator[index] = snapshot.spectator;
                try self.setSpectatorsOnly(self.player_slots[index], snapshot.spectator);
            }
        }
    }

    /// Occlusion is asked of the sections a block and a half around a player and three high, as
    /// players replicated before: a looser box than its own, so one at a section's edge does not
    /// come and go.
    const player_shape_half_width = 1.5;
    const player_shape_height = 3;

    /// Where the entity in a slot is: a player as a subject where tracking last saw it, as they
    /// are not in the space; every other entity in its place there.
    fn placedAt(self: *const Tracking, slot: u32) ?Placed {
        const directory = &self.deps.entities.directory;
        if (self.player_tracker != null and slot < directory.high() and slot < self.metas.len) {
            const entry = directory.entry(slot);
            if (!entry.retired and entry.id != 0 and entry.kind == self.player_kind) {
                const player = self.metas.at(slot).owner;
                if (player == no_owner or self.player_slots[player] != slot) return null;
                const position = self.subject_at[player];
                const shape: entities_module.space.Shape = .{ .kind = self.player_kind, .half_width = player_shape_half_width, .height = player_shape_height };
                return .{ .entry = .{ .id = entry.id, .slot = slot, .section = entities_module.space.coordinate(position[1]), .entered = 0, .position = position, .shape = shape }, .world = self.subject_world[player] };
            }
        }
        return self.deps.entities.places.space.atSlot(slot);
    }

    /// A tracking layer over entities of its own, for tests of what builds on it.
    pub fn forTests(allocator: std.mem.Allocator, players: *Players) !*Tracking {
        const owned = try Entities.allocate(allocator, std.testing.io, .{ .memory = 256 * entities_module.pool.page_bytes }, undefined);
        return Tracking.init(allocator, .{}, .{ .entities = owned, .players = players });
    }

    /// A kind's entities are tracked from now on. Call while starting.
    pub fn register(self: *Tracking, spec: Spec) !TrackerId {
        if (self.tracker_count == max_trackers) return error.TooManyTrackers;
        const scale = self.config.range_percentage;
        const index: TrackerId = @intCast(self.tracker_count);
        const max_range: f64 = @floatFromInt((spec.max_range orelse spec.range) * scale / 100);
        // Trackers of one widest range share their walks.
        const group: u8 = for (self.groups[0..self.group_count], 0..) |*group, at| {
            if (group.range != max_range) continue;
            group.kinds.bits.setUnion(spec.kinds.bits);
            break @intCast(at);
        } else group: {
            self.groups[self.group_count] = .{ .range = max_range, .kinds = spec.kinds };
            self.group_count += 1;
            break :group @intCast(self.group_count - 1);
        };
        if ((spec.sweeps == null) != (spec.exact == null)) return error.InvalidConfiguration;
        self.trackers[index] = .{ .kinds = spec.kinds, .range = @floatFromInt(spec.range * scale / 100), .max_range = max_range, .group = group, .sweeps = spec.sweeps, .exact = spec.exact };
        if (spec.sweeps) |source| {
            for (self.sources[0..self.source_count]) |existing| {
                if (existing == source) break;
            } else {
                self.sources[self.source_count] = source;
                self.source_count += 1;
            }
        }
        for (0..Kinds.max_kinds) |entity_kind| if (spec.kinds.has(@intCast(entity_kind))) {
            if (self.tracker_of[entity_kind] != no_tracker) return error.KindTrackedTwice;
            self.tracker_of[entity_kind] = index;
            self.tracked.bits.set(entity_kind);
        };
        self.tracker_count += 1;
        return index;
    }

    // Rows.

    fn rowsOf(self: *const Tracking, slot: u32) []u64 {
        const stride = 2 * self.words;
        return self.rows.run(@as(usize, slot) * stride, @as(usize, slot) * stride + stride).?;
    }

    fn knownWords(self: *const Tracking, slot: u32) []u64 {
        return self.rowsOf(slot)[0..self.words];
    }

    fn staleWords(self: *const Tracking, slot: u32) []u64 {
        return self.rowsOf(slot)[self.words..];
    }

    fn set(self: *const Tracking, words: []const u64) bit_sets.Set {
        return .{ .words = @ptrCast(words[0..self.row_words]), .capacity = self.deps.players.records.len };
    }

    /// Who has the entity spawned: who gets its deltas and metadata.
    pub fn known(self: *const Tracking, slot: u32) bit_sets.Set {
        if (slot >= self.metas.len) return self.set(self.zeros);
        return self.set(self.knownWords(slot));
    }

    /// No player at all, to confirm one side of a change with.
    pub fn nobody(self: *const Tracking) bit_sets.Set {
        return self.set(self.zeros);
    }

    /// Who of those missed a delta and needs the entity's state whole.
    pub fn stale(self: *const Tracking, slot: u32) bit_sets.Set {
        if (slot >= self.metas.len) return self.set(self.zeros);
        return self.set(self.staleWords(slot));
    }

    fn ensureSlot(self: *Tracking, slot: u32) !void {
        if (slot < self.metas.len) return;
        try self.rows.ensureFilled((@as(usize, slot) + 1) * 2 * self.words, 0);
        try self.metas.ensureFilled(@as(usize, slot) + 1, .{});
        try self.allowed.ensureFilled((@as(usize, slot) + 1) * self.words, 0);
    }

    fn allowedWords(self: *const Tracking, slot: u32) []u64 {
        return self.allowed.run(@as(usize, slot) * self.words, (@as(usize, slot) + 1) * self.words).?;
    }

    fn has(words: []const u64, player: usize) bool {
        return words[player / 64] & (@as(u64, 1) << @intCast(player % 64)) != 0;
    }

    fn put(words: []u64, player: usize, value: bool) void {
        const bit = @as(u64, 1) << @intCast(player % 64);
        if (value) words[player / 64] |= bit else words[player / 64] &= ~bit;
    }

    /// A word of a set a kind passes, nothing past its end.
    fn wordOf(players: bit_sets.Set, index: usize) u64 {
        if (index * 64 >= players.capacity) return 0;
        if (players.sparse == null and index >= players.words.len) return 0;
        return players.wordAt(index);
    }

    fn any(words: []const u64) bool {
        for (words) |word| if (word != 0) return true;
        return false;
    }

    // The rule.

    /// Where the distance test stands for a whole column: every point inside the circle, none
    /// of them, or some.
    const Hint = enum { inside, outside, test_each };

    /// An entity's tracking range: its own, else its type's.
    fn rangeOf(self: *const Tracking, tracker: *const Tracker, slot: u32) f64 {
        const own = self.metas.at(slot).range;
        return if (own > 0) own else tracker.range;
    }

    /// The whole blocks an entity's box is in, as occlusion asks about them.
    fn blocksOf(entry: Entry) geometry_bounds.Box {
        const box = entry.box();
        return .{
            .minimum = .{ @intFromFloat(@floor(box.min[0])), @intFromFloat(@floor(box.min[1])), @intFromFloat(@floor(box.min[2])) },
            .maximum = .{ @intFromFloat(@ceil(box.max[0])), @intFromFloat(@ceil(box.max[1])), @intFromFloat(@ceil(box.max[2])) },
        };
    }

    /// The columns and sections an entity's box is in: low x, y, z, then high.
    const Footprint = struct { low: [3]i32 = .{ 0, 0, 0 }, high: [3]i32 = .{ 0, 0, 0 } };

    fn footprintOf(entry: Entry) Footprint {
        const blocks = blocksOf(entry);
        var result: Footprint = undefined;
        for (0..3) |axis| {
            result.low[axis] = @divFloor(blocks.minimum[axis], 16);
            result.high[axis] = @divFloor(@max(blocks.maximum[axis], blocks.minimum[axis] + 1) - 1, 16);
        }
        return result;
    }

    /// updatePlayer's answer for one player.
    fn sees(self: *const Tracking, slot: u32, entry: Entry, world: u32, range: f64, player: usize, hint: Hint) bool {
        if (!self.ready[player] or self.worlds[player] != world) return false;
        switch (hint) {
            .outside => return false,
            .inside => {},
            .test_each => {
                const reach = @min(range, self.reaches[player]);
                const dx = self.xs[player] - entry.position[0];
                const dz = self.zs[player] - entry.position[2];
                if (dx * dx + dz * dz > reach * reach) return false;
            },
        }
        const meta = self.metas.at(slot);
        if (meta.owner == player or (meta.spectators_only and !self.spectating[player])) return false;
        if (meta.restricted and !has(self.allowedWords(slot), player)) return false;
        const streaming = self.deps.streaming orelse return true;
        const visibility = streaming.snapshotVisibility();
        const record = &self.deps.players.records[player];
        const column = entities_module.space.columnOf(world, entry.position);
        if (!visibility.visible(player, record, world, column.x, column.z)) return false;
        return visibility.boundsVisible(player, record, world, blocksOf(entry));
    }

    // Work.

    fn item(self: *const Tracking, index: u32) []u64 {
        const stride = 2 * self.words;
        return self.work_rows.run(@as(usize, index) * stride, @as(usize, index) * stride + stride).?;
    }

    /// The slot's entry in this tick's work, made if it has none; null once the work is full.
    fn workOf(self: *Tracking, slot: u32) !?[]u64 {
        const meta = self.metas.at(slot);
        if (meta.work != none) return self.item(meta.work);
        if (self.work_slots.len == self.config.work) {
            self.work_overflowed = true;
            return null;
        }
        const index = try self.work_slots.append(slot);
        try self.work_rows.ensureFilled((index + 1) * 2 * self.words, 0);
        meta.work = @intCast(index);
        const rows = self.item(meta.work);
        @memset(rows, 0);
        return rows;
    }

    /// One player's answer for an entity, kept where it differs from what the client has.
    fn note(self: *Tracking, slot: u32, player: usize, wanted: bool) !void {
        const meta = self.metas.at(slot);
        if (meta.work == none and has(self.knownWords(slot), player) == wanted) return;
        const rows = (try self.workOf(slot)) orelse return;
        put(rows[0..self.words], player, true);
        put(rows[self.words..], player, wanted);
    }

    /// The entity checked against one player, as a player change asks.
    fn checkFor(self: *Tracking, entry: Entry, world: u32, player: usize, hint: Hint) !void {
        const tracker_index = self.tracker_of[entry.shape.kind];
        if (tracker_index == no_tracker) return;
        const tracker = &self.trackers[tracker_index];
        // A swept one is where its sweep says, which the walks of sweeps ask about.
        if (tracker.sweeps) |source| if (source.of(entry.slot) != null) return;
        try self.adopt(entry, tracker_index);
        const meta = self.metas.at(entry.slot);
        if (meta.gone) return;
        const exact = self.metas.at(entry.slot).range == 0;
        try self.note(entry.slot, player, self.sees(entry.slot, entry, world, self.rangeOf(tracker, entry.slot), player, if (exact) hint else .test_each));
    }

    fn adopt(self: *Tracking, entry: Entry, tracker: u8) !void {
        _ = try self.adoptSlot(entry.slot, entry.id, tracker);
    }

    /// What tracking keeps of the entity in a slot, made afresh for one it has not seen there.
    fn adoptSlot(self: *Tracking, slot: u32, entity: u64, tracker: u8) !*Meta {
        try self.ensureSlot(slot);
        const meta = self.metas.at(slot);
        if (meta.tracker == tracker and meta.entity == entity) return meta;
        // A slot let go and taken by another entity: nobody has the new one yet.
        assert(!any(self.knownWords(slot)));
        if (meta.work != none) @memset(self.item(meta.work), 0);
        self.forgetData(meta);
        meta.* = .{ .tracker = tracker, .entity = entity, .looked = meta.looked, .work = meta.work };
        return meta;
    }

    /// What an entity said of itself goes with it.
    fn forgetData(self: *Tracking, meta: *Meta) void {
        if (meta.range > 0) self.groups[self.trackers[meta.tracker].group].own_ranges -= 1;
        meta.range = 0;
    }

    // What entities say of themselves.

    /// The tracking data of the entity in a slot, for a kind to set before or after tracking first
    /// looks at it.
    fn subject(self: *Tracking, slot: u32) !*Meta {
        const entry = self.deps.entities.directory.entry(slot);
        const tracker = self.tracker_of[entry.kind];
        assert(tracker != no_tracker and !entry.retired);
        return self.adoptSlot(slot, entry.id, tracker);
    }

    /// An entity's own tracking range in blocks, as one carrying passengers takes the farthest of
    /// theirs; null for its type's. No more than its tracker's widest.
    pub fn setRange(self: *Tracking, slot: u32, blocks: ?u32) !void {
        const meta = try self.subject(slot);
        const tracker = &self.trackers[meta.tracker];
        const range: f64 = if (blocks) |value| @floatFromInt(value * self.config.range_percentage / 100) else 0;
        assert(range <= tracker.max_range);
        if (range == meta.range) return;
        const group = &self.groups[tracker.group];
        if (meta.range > 0) group.own_ranges -= 1;
        if (range > 0) group.own_ranges += 1;
        meta.range = range;
        try self.relook(slot);
    }

    /// The player an entity is, who is never shown itself.
    pub fn setOwner(self: *Tracking, slot: u32, player: ?usize) !void {
        const meta = try self.subject(slot);
        const owner: u16 = if (player) |value| @intCast(value) else no_owner;
        if (owner == meta.owner) return;
        meta.owner = owner;
        try self.relook(slot);
    }

    /// Whether only spectators may see an entity, as only they see a player in spectator mode.
    pub fn setSpectatorsOnly(self: *Tracking, slot: u32, only: bool) !void {
        const meta = try self.subject(slot);
        if (only == meta.spectators_only) return;
        meta.spectators_only = only;
        try self.relook(slot);
    }

    /// The only players who may see an entity, or null for every one. Whether that changed.
    pub fn restrict(self: *Tracking, slot: u32, players: ?bit_sets.Set) !bool {
        const meta = try self.subject(slot);
        const words = self.allowedWords(slot);
        if (players) |allowed| {
            var same = meta.restricted;
            for (words, 0..) |*word, at| {
                const value = wordOf(allowed, at);
                same = same and word.* == value;
                word.* = value;
            }
            if (same) return false;
            meta.restricted = true;
        } else {
            if (!meta.restricted) return false;
            meta.restricted = false;
        }
        try self.relook(slot);
        return true;
    }

    /// The entity checked against every player who could see it and every one who has it, as
    /// its own change asks; and how far it can now go before any answer could change.
    fn checkAll(self: *Tracking, entry: Entry, world: u32) !void {
        const tracker_index = self.tracker_of[entry.shape.kind];
        if (tracker_index == no_tracker) return;
        const tracker = &self.trackers[tracker_index];
        try self.adopt(entry, tracker_index);
        const meta = self.metas.at(entry.slot);
        meta.gone = false;
        const range = self.rangeOf(tracker, entry.slot);
        const chunks: i32 = @intFromFloat(@ceil(tracker.max_range / 16) + 2);
        // Players beyond the chunks asked about are at least this far from the entity, and
        // their circles no wider than the widest.
        var margin: f64 = @as(f64, @floatFromInt(chunks - 1)) * 16 - tracker.max_range;
        // Far from every player: seen by none, until one comes that much nearer. The players near
        // are not asked about, so that is all the margin says.
        const away = self.awayFromPlayers(world, .{ entry.position[0], entry.position[2] }, .{ entry.position[0], entry.position[2] });
        if (away > tracker.max_range) margin = away - tracker.max_range;
        const column = entities_module.space.columnOf(world, entry.position);
        const around = if (away <= tracker.max_range) self.playersNear(column, chunks) else self.candidates[0..0];
        const seen = if (around.len > 0) self.seenFrom(column, entry, around) else self.zeros;
        const wanted = self.scratch[0..self.words];
        @memset(wanted, 0);
        // The distance test eight players at a time.
        const lanes = 8;
        const V = @Vector(lanes, f64);
        var start: usize = 0;
        while (start < around.len) : (start += lanes) {
            const count = @min(lanes, around.len - start);
            var xs: [lanes]f64 = @splat(0);
            var zs: [lanes]f64 = @splat(0);
            var reaches: [lanes]f64 = @splat(-1);
            for (0..count) |lane| {
                const player = around[start + lane];
                if (!self.ready[player] or self.worlds[player] != world) continue;
                xs[lane] = self.xs[player];
                zs[lane] = self.zs[player];
                reaches[lane] = @min(range, self.reaches[player]);
            }
            const px: V = xs;
            const pz: V = zs;
            const reach: V = reaches;
            const dx = px - @as(V, @splat(entry.position[0]));
            const dz = pz - @as(V, @splat(entry.position[2]));
            const squared = dx * dx + dz * dz;
            // Compared squared, as vanilla does; the margin only needs the distance.
            const within: [lanes]bool = squared <= reach * reach;
            const distance: [lanes]f64 = @as(V, @sqrt(squared));
            for (0..count) |lane| {
                if (reaches[lane] < 0) continue;
                margin = @min(margin, @abs(distance[lane] - reaches[lane]));
                if (!within[lane]) continue;
                const player = around[start + lane];
                if (has(seen, player) and self.admits(meta, entry.slot, player)) put(wanted, player, true);
            }
        }
        meta.world = world;
        meta.x = entry.position[0];
        meta.z = entry.position[2];
        meta.column = .{ column.x, column.z };
        meta.footprint = footprintOf(entry);
        meta.margin = margin;
        meta.drift = self.changes.drift;
        meta.epoch = self.changes.epoch;
        try self.commit(entry.slot, wanted);
    }

    /// Every player's answer for an entity, kept where it differs from what clients have: whoever
    /// has it and is not wanted, and whoever is wanted and lacks it.
    fn commit(self: *Tracking, slot: u32, wanted: []const u64) !void {
        const meta = self.metas.at(slot);
        const known_words = self.knownWords(slot);
        var differs = meta.work != none;
        for (known_words, wanted) |have, want| differs = differs or have != want;
        if (!differs) return;
        const rows = (try self.workOf(slot)) orelse return;
        for (rows[0..self.words], rows[self.words..], known_words, wanted) |*mask, *answer, have, want| {
            mask.* |= have | want;
            answer.* = (answer.* & ~(have | want)) | want;
        }
    }

    // Swept entities.

    /// The swept entity in a slot of a tracker, if it is swept.
    fn sweptIn(self: *const Tracking, slot: u32) ?struct { sweep: *const Sweep, tracker: u8 } {
        const directory = &self.deps.entities.directory;
        if (slot >= directory.high()) return null;
        const entry = directory.entry(slot);
        if (entry.retired or entry.id == 0) return null;
        const tracker = self.tracker_of[entry.kind];
        if (tracker == no_tracker) return null;
        const source = self.trackers[tracker].sweeps orelse return null;
        return .{ .sweep = source.of(slot) orelse return null, .tracker = tracker };
    }

    /// Where a swept entity is now, as its kind says, which must be in its sweep.
    fn placeOf(self: *Tracking, tracker: u8, slot: u32, sweep: *const Sweep) !Placed {
        const exact = self.trackers[tracker].exact.?;
        const placed = try exact.place(exact.context, slot);
        assert(placed.world == sweep.world and sweep.box.contains(placed.entry.position));
        return placed;
    }

    /// One player's answer for an entity anywhere in a sweep: where its feet may be, and its box
    /// anywhere along.
    fn boxAnswer(self: *const Tracking, slot: u32, world: u32, feet: SweptBox, reach_box: SweptBox, range: f64, player: usize) Answer {
        if (!self.ready[player] or self.worlds[player] != world) return .no;
        const meta = self.metas.at(slot);
        if (meta.owner == player or (meta.spectators_only and !self.spectating[player])) return .no;
        if (meta.restricted and !has(self.allowedWords(slot), player)) return .no;
        var answer: Answer = switch (distanceAnswer(feet, self.xs[player], self.zs[player], @min(range, self.reaches[player]))) {
            .no => return .no,
            else => |value| value,
        };
        const streaming = self.deps.streaming orelse return answer;
        const visibility = streaming.snapshotVisibility();
        const record = &self.deps.players.records[player];
        // isChunkTracked for every column the feet may be in.
        var some = false;
        var all = true;
        var x = entities_module.space.coordinate(feet.low[0]);
        while (x <= entities_module.space.coordinate(feet.high[0])) : (x += 1) {
            var z = entities_module.space.coordinate(feet.low[2]);
            while (z <= entities_module.space.coordinate(feet.high[2])) : (z += 1) {
                const seen = visibility.visible(player, record, world, x, z);
                some = some or seen;
                all = all and seen;
            }
        }
        if (!some) return .no;
        if (!all) answer = .unsure;
        // Some section of its box not hidden, for every box along: all of them shown is yes,
        // none is no.
        const blocks: geometry_bounds.Box = .{
            .minimum = .{ @intFromFloat(@floor(reach_box.low[0])), @intFromFloat(@floor(reach_box.low[1])), @intFromFloat(@floor(reach_box.low[2])) },
            .maximum = .{ @intFromFloat(@ceil(reach_box.high[0])), @intFromFloat(@ceil(reach_box.high[1])), @intFromFloat(@ceil(reach_box.high[2])) },
        };
        some = false;
        all = true;
        var section_x = @divFloor(blocks.minimum[0], 16);
        while (section_x <= @divFloor(@max(blocks.maximum[0], blocks.minimum[0] + 1) - 1, 16)) : (section_x += 1) {
            var section_z = @divFloor(blocks.minimum[2], 16);
            while (section_z <= @divFloor(@max(blocks.maximum[2], blocks.minimum[2] + 1) - 1, 16)) : (section_z += 1) {
                var section_y = @divFloor(blocks.minimum[1], 16);
                while (section_y <= @divFloor(@max(blocks.maximum[1], blocks.minimum[1] + 1) - 1, 16)) : (section_y += 1) {
                    const seen = visibility.sectionVisible(player, record, .{ .world = world, .x = section_x, .y = section_y, .z = section_z });
                    some = some or seen;
                    all = all and seen;
                }
            }
        }
        if (!some) return .no;
        if (!all) answer = .unsure;
        return answer;
    }

    /// The distance test for feet anywhere in a box: all of it within reach, none, or some.
    fn distanceAnswer(feet: SweptBox, x: f64, z: f64, reach: f64) Answer {
        const near_x = @max(0, @max(feet.low[0] - x, x - feet.high[0]));
        const near_z = @max(0, @max(feet.low[2] - z, z - feet.high[2]));
        const far_x = @max(@abs(x - feet.low[0]), @abs(x - feet.high[0]));
        const far_z = @max(@abs(z - feet.low[2]), @abs(z - feet.high[2]));
        const squared = reach * reach;
        if (near_x * near_x + near_z * near_z > squared) return .no;
        if (far_x * far_x + far_z * far_z <= squared) return .yes;
        return .unsure;
    }

    /// A swept entity checked against every player who could see it anywhere in its sweep and
    /// every one who has it.
    fn checkSwept(self: *Tracking, slot: u32, sweep: *const Sweep, tracker_index: u8) !void {
        const meta = try self.adoptSlot(slot, self.deps.entities.directory.entry(slot).id, tracker_index);
        meta.gone = false;
        meta.margin = -1;
        meta.looked = self.tick_count;
        // Answered for this very box this tick already, as players stood before it; what they did
        // since the walks of sweeps ask about.
        if (meta.settled_for == self.tick_count and meta.work == none and std.meta.eql(meta.settled_box, sweep.box)) return;
        const wanted = self.scratch[0..self.words];
        @memset(wanted, 0);
        _ = try self.sweepAnswers(slot, sweep.world, sweep.box, sweep.reach(), tracker_index, sweep, wanted);
        try self.commit(slot, wanted);
    }

    /// Every player's answer for an entity anywhere in a box into `wanted`; the kind is asked where
    /// it is for those unsure, when `sweep` says it is swept there, and it is asked again next
    /// tick. Returns whether some answer was unsure.
    fn sweepAnswers(self: *Tracking, slot: u32, world: u32, feet: SweptBox, reach_box: SweptBox, tracker_index: u8, sweep: ?*const Sweep, wanted: []u64) !bool {
        const tracker = &self.trackers[tracker_index];
        const range = self.rangeOf(tracker, slot);
        const middle: [2]f64 = .{ (feet.low[0] + feet.high[0]) / 2, (feet.low[2] + feet.high[2]) / 2 };
        const half = @max(feet.high[0] - feet.low[0], feet.high[2] - feet.low[2]) / 2;
        const chunks: i32 = @intFromFloat(@ceil((tracker.max_range + half) / 16) + 2);
        var exact: ?Placed = null;
        var unsure = false;
        if (self.awayFromPlayers(world, .{ feet.low[0], feet.low[2] }, .{ feet.high[0], feet.high[2] }) > tracker.max_range) return false;
        var nearby = self.deps.players.nearby(world, .{ .x = middle[0], .y = feet.low[1], .z = middle[1] }, chunks);
        while (nearby.next()) |player| switch (self.boxAnswer(slot, world, feet, reach_box, range, player)) {
            .no => {},
            .yes => put(wanted, player, true),
            .unsure => {
                unsure = true;
                const swept = sweep orelse continue;
                if (exact == null) exact = try self.placeOf(tracker_index, slot, swept);
                if (self.sees(slot, exact.?.entry, exact.?.world, range, player, .test_each)) put(wanted, player, true);
            },
        };
        if (unsure and sweep != null) try self.unsettle(slot);
        return unsure;
    }

    fn unsettle(self: *Tracking, slot: u32) !void {
        const meta = self.metas.at(slot);
        if (meta.unsettled == self.tick_count) return;
        meta.unsettled = self.tick_count;
        _ = try self.unsettled.append(slot);
    }

    /// A swept entity checked against one player, as a player change asks.
    fn checkSweptFor(self: *Tracking, slot: u32, sweep: *const Sweep, tracker_index: u8, player: usize) !void {
        const meta = try self.adoptSlot(slot, self.deps.entities.directory.entry(slot).id, tracker_index);
        if (meta.gone) return;
        const tracker = &self.trackers[tracker_index];
        const range = self.rangeOf(tracker, slot);
        const wanted = switch (self.boxAnswer(slot, sweep.world, sweep.box, sweep.reach(), range, player)) {
            .no => false,
            .yes => true,
            .unsure => wanted: {
                try self.unsettle(slot);
                const placed = try self.placeOf(tracker_index, slot, sweep);
                break :wanted self.sees(slot, placed.entry, placed.world, range, player, .test_each);
            },
        };
        try self.note(slot, player, wanted);
    }

    /// Whether an entity anywhere in a box, until its kind places it again, is seen by every
    /// player as clients have it now: none unsure, none to spawn or remove. What a kind asks before
    /// sweeping one.
    pub fn settled(self: *Tracking, slot: u32, world: u32, feet: SweptBox, half_width: f32, height: f32) !bool {
        // Far from every player, it is settled where no one has it.
        if (slot < self.metas.len) {
            const meta = self.metas.at(slot);
            const entry = self.deps.entities.directory.entry(slot);
            if (meta.entity == entry.id and meta.tracker == self.tracker_of[entry.kind] and meta.work == none and
                self.awayFromPlayers(world, .{ feet.low[0], feet.low[2] }, .{ feet.high[0], feet.high[2] }) > self.trackers[meta.tracker].max_range)
            {
                if (any(self.knownWords(slot))) return false;
                meta.settled_for = self.tick_count + 1;
                meta.settled_box = feet;
                return true;
            }
        }
        const meta = try self.subject(slot);
        if (meta.work != none) return false;
        const reach_box: SweptBox = .{
            .low = .{ feet.low[0] - half_width, feet.low[1], feet.low[2] - half_width },
            .high = .{ feet.high[0] + half_width, feet.high[1] + height, feet.high[2] + half_width },
        };
        const wanted = self.scratch[self.words..][0..self.words];
        @memset(wanted, 0);
        if (try self.sweepAnswers(slot, world, feet, reach_box, meta.tracker, null, wanted)) return false;
        if (!std.mem.eql(u64, wanted, self.knownWords(slot))) return false;
        // Before the tracking tick, which counts on.
        meta.settled_for = self.tick_count + 1;
        meta.settled_box = feet;
        return true;
    }

    /// The players near a column this tick, out to `chunks` of it: asked once for every entity of
    /// the column.
    fn playersNear(self: *Tracking, column: Column, chunks: i32) []const u16 {
        const key: NearKey = .{ .world = column.world, .x = column.x, .z = column.z, .chunks = chunks };
        if (self.near_columns.get(key)) |run| return self.near_players[run.start..][0..run.count];
        var count: usize = 0;
        var nearby = self.deps.players.nearby(column.world, .{ .x = @as(f64, @floatFromInt(column.x)) * 16 + 8, .y = 0, .z = @as(f64, @floatFromInt(column.z)) * 16 + 8 }, chunks);
        while (nearby.next()) |player| {
            self.candidates[count] = @intCast(player);
            count += 1;
        }
        if (self.near_columns.count() == shared_columns or self.near_count + count > self.near_players.len) return self.candidates[0..count];
        const start = self.near_count;
        @memcpy(self.near_players[start..][0..count], self.candidates[0..count]);
        self.near_count += count;
        self.near_columns.putAssumeCapacity(key, .{ .start = @intCast(start), .count = @intCast(count) });
        return self.near_players[start..][0..count];
    }

    /// Who of the players near a column the terrain lets see an entity there: in its world and
    /// ready, sent its column, and some section of its box not hidden from them. The same for
    /// every entity of the column whose box is in the same sections.
    fn seenFrom(self: *Tracking, column: Column, entry: Entry, around: []const u16) []const u64 {
        const footprint = footprintOf(entry);
        const key: SeenKey = .{ .world = column.world, .x = column.x, .z = column.z, .footprint = footprint };
        if (self.seen_footprints.get(key)) |at| return self.seen_rows[at * self.words ..][0..self.words];
        const shared = self.seen_footprints.count() < shared_columns;
        const row = if (shared) self.seen_rows[self.seen_count * self.words ..][0..self.words] else self.scratch[2 * self.words ..][0..self.words];
        @memset(row, 0);
        const visibility = if (self.deps.streaming) |streaming| streaming.snapshotVisibility() else null;
        const blocks = blocksOf(entry);
        for (around) |player| {
            if (!self.ready[player] or self.worlds[player] != column.world) continue;
            if (visibility) |view| {
                const record = &self.deps.players.records[player];
                if (!view.visible(player, record, column.world, column.x, column.z) or !view.boundsVisible(player, record, column.world, blocks)) continue;
            }
            put(row, player, true);
        }
        if (shared) {
            self.seen_footprints.putAssumeCapacity(key, @intCast(self.seen_count));
            self.seen_count += 1;
        }
        return row;
    }

    /// What an entity says of itself lets a player see it.
    fn admits(self: *const Tracking, meta: *const Meta, slot: u32, player: usize) bool {
        if (meta.owner == player or (meta.spectators_only and !self.spectating[player])) return false;
        return !meta.restricted or has(self.allowedWords(slot), player);
    }

    /// Whether an entity that moved can still give every player the answer it gave.
    fn unchanged(self: *const Tracking, meta: *const Meta, entry: Entry, world: u32) bool {
        if (meta.margin < 0 or meta.epoch != self.changes.epoch or meta.world != world) return false;
        const column = entities_module.space.columnOf(world, entry.position);
        if (column.x != meta.column[0] or column.z != meta.column[1] or !std.meta.eql(footprintOf(entry), meta.footprint)) return false;
        const dx = entry.position[0] - meta.x;
        const dz = entry.position[2] - meta.z;
        const left = meta.margin - (self.changes.drift - meta.drift);
        return dx * dx + dz * dz < left * left and left > 0;
    }

    // Columns.

    /// The columns of a world within `reach` of a point, and how each stands against the circle.
    const Circle = struct {
        world: u32,
        x: f64,
        z: f64,
        reach: f64,

        fn contains(self: Circle, position: [3]f64) bool {
            const dx = self.x - position[0];
            const dz = self.z - position[2];
            return dx * dx + dz * dz <= self.reach * self.reach;
        }

        fn hint(self: Circle, column: Column) Hint {
            const low_x: f64 = @floatFromInt(column.x * 16);
            const low_z: f64 = @floatFromInt(column.z * 16);
            const near_x = @max(0, @max(low_x - self.x, self.x - (low_x + 16)));
            const near_z = @max(0, @max(low_z - self.z, self.z - (low_z + 16)));
            const far_x = @max(@abs(self.x - low_x), @abs(self.x - (low_x + 16)));
            const far_z = @max(@abs(self.z - low_z), @abs(self.z - (low_z + 16)));
            const squared = self.reach * self.reach;
            if (near_x * near_x + near_z * near_z > squared) return .outside;
            if (far_x * far_x + far_z * far_z <= squared) return .inside;
            return .test_each;
        }

        /// The column rows the circle touches.
        fn rows(self: Circle) [2]i32 {
            return .{ @intFromFloat(@floor((self.z - self.reach) / 16)), @intFromFloat(@floor((self.z + self.reach) / 16)) };
        }

        /// In one column row, the columns the circle touches, and those wholly inside it.
        fn span(self: Circle, row: i32) struct { touch: ?[2]i32, inside: ?[2]i32 } {
            const low: f64 = @floatFromInt(row * 16);
            const nearest = @max(0, @max(low - self.z, self.z - (low + 16)));
            const far = @max(@abs(self.z - low), @abs(self.z - (low + 16)));
            const squared = self.reach * self.reach;
            if (nearest * nearest > squared) return .{ .touch = null, .inside = null };
            const wide = @sqrt(squared - nearest * nearest);
            const touch: [2]i32 = .{ @intFromFloat(@floor((self.x - wide) / 16)), @intFromFloat(@floor((self.x + wide) / 16)) };
            if (far * far > squared) return .{ .touch = touch, .inside = null };
            const narrow = @sqrt(squared - far * far);
            const first: i32 = @intFromFloat(@ceil((self.x - narrow) / 16));
            const last: i32 = @as(i32, @intFromFloat(@floor((self.x + narrow) / 16))) - 1;
            return .{ .touch = touch, .inside = if (first <= last) .{ first, last } else null };
        }
    };

    /// Every column where a player's answer can differ between two circles: those either touches,
    /// but not those wholly inside both. `before` null asks for every column `after` touches.
    fn eachBetween(self: *Tracking, before: ?Circle, after: Circle, player: usize, kinds: Kinds, exact: bool) !void {
        if (self.source_count > 0) try self.sweptBetween(before, after, player, kinds);
        // Players as subjects are few and listed: each is looked at, rather than the columns.
        if (self.player_tracker != null and kinds.has(self.player_kind)) {
            try self.playersBetween(before, after, player, exact);
            var rest = kinds;
            rest.bits.unset(self.player_kind);
            if (rest.bits.count() == 0) return;
            return self.columnsBetween(before, after, player, rest, exact);
        }
        return self.columnsBetween(before, after, player, kinds, exact);
    }

    /// An observer's answers for players as subjects hold while it and they moved less, together,
    /// than the nearest of them was from its reach's edge when it last measured: only then is the
    /// circle it measured from compared with where it is, and the nearest measured again.
    fn playerRing(self: *Tracking, player: usize, snapshot: PlayerChanges.Snapshot, reach: f64) !void {
        const anchor = self.player_anchor[player];
        const walked = @sqrt((snapshot.x - anchor[0]) * (snapshot.x - anchor[0]) + (snapshot.z - anchor[1]) * (snapshot.z - anchor[1]));
        const slack = self.player_slack[player];
        if (slack >= 0 and walked + (self.changes.drift - self.player_drift[player]) < slack) return;
        const after: Circle = .{ .world = snapshot.world, .x = snapshot.x, .z = snapshot.z, .reach = reach };
        const before: ?Circle = if (slack >= 0) .{ .world = snapshot.world, .x = anchor[0], .z = anchor[1], .reach = reach } else null;
        try self.playersBetween(before, after, player, true);
        self.player_anchor[player] = .{ snapshot.x, snapshot.z };
        self.player_drift[player] = self.changes.drift;
        self.player_slack[player] = self.measurePlayers(player, after);
    }

    /// How far the nearest player as a subject is from the edge of a circle.
    fn measurePlayers(self: *const Tracking, player: usize, circle: Circle) f64 {
        var nearest = circle.reach;
        for (self.player_slots, self.subject_x[0..self.player_slots.len], self.subject_z[0..self.player_slots.len], self.subject_world, 0..) |slot, x, z, world, index| {
            if (slot == none or world != circle.world or index == player) continue;
            const distance = @sqrt((x - circle.x) * (x - circle.x) + (z - circle.z) * (z - circle.z));
            nearest = @min(nearest, @abs(distance - circle.reach));
        }
        return nearest;
    }

    /// A player newly a subject is as near some observer's edge as it is: their measures say so.
    fn nearObservers(self: *Tracking, newcomer: usize) void {
        const x = self.subject_x[newcomer];
        const z = self.subject_z[newcomer];
        const range = self.trackers[self.player_tracker.?].max_range;
        for (self.player_slack, self.player_anchor, self.reaches, 0..) |*slack, anchor, reach, observer| {
            if (slack.* < 0 or observer == newcomer) continue;
            const distance = @sqrt((x - anchor[0]) * (x - anchor[0]) + (z - anchor[1]) * (z - anchor[1]));
            slack.* = @min(slack.*, @abs(distance - @min(range, reach)) - (self.changes.drift - self.player_drift[observer]));
            if (slack.* < 0) slack.* = 0;
        }
    }

    /// Every player as a subject where an observer's answer can differ between two circles.
    fn playersBetween(self: *Tracking, before: ?Circle, after: Circle, player: usize, exact: bool) !void {
        // Eight at a time: those on one side of one circle and the other side of the other.
        const lanes = 8;
        const V = @Vector(lanes, f64);
        const count = self.player_slots.len;
        var start: usize = 0;
        while (start < count) : (start += lanes) {
            const width = @min(lanes, count - start);
            var crossed: u8 = if (before == null or !exact) @truncate((@as(u16, 1) << @intCast(width)) - 1) else 0;
            if (before) |then| if (exact) {
                // Padded to whole vectors with no one there.
                const x: V = self.subject_x[start..][0..lanes].*;
                const z: V = self.subject_z[start..][0..lanes].*;
                const ax = x - @as(V, @splat(after.x));
                const az = z - @as(V, @splat(after.z));
                const bx = x - @as(V, @splat(then.x));
                const bz = z - @as(V, @splat(then.z));
                const inside_after = ax * ax + az * az <= @as(V, @splat(after.reach * after.reach));
                const inside_before = bx * bx + bz * bz <= @as(V, @splat(then.reach * then.reach));
                crossed = @bitCast(inside_after != inside_before);
                crossed &= @truncate((@as(u16, 1) << @intCast(width)) - 1);
            };
            while (crossed != 0) : (crossed &= crossed - 1) {
                const index = start + @ctz(crossed);
                const slot = self.player_slots[index];
                if (slot == none or self.subject_world[index] != after.world) continue;
                const placed = self.placedAt(slot) orelse continue;
                try self.checkFor(placed.entry, placed.world, player, .test_each);
            }
        }
    }

    fn columnsBetween(self: *Tracking, before: ?Circle, after: Circle, player: usize, kinds: Kinds, exact: bool) !void {
        const space = &self.deps.entities.places.space;
        if (space.countOf(kinds) == 0) return;
        // Walked along x, as the space keeps its columns: the circles with their axes swapped give,
        // for each x, the run of z they touch.
        const now_circle = swapped(after);
        const then_circle = if (before) |circle| swapped(circle) else null;
        const lines_after = now_circle.rows();
        const lines_before = if (then_circle) |circle| circle.rows() else lines_after;
        var x = @min(lines_after[0], lines_before[0]);
        while (x <= @max(lines_after[1], lines_before[1])) : (x += 1) {
            const now = now_circle.span(x);
            const then = if (then_circle) |circle| circle.span(x) else @TypeOf(now){ .touch = null, .inside = null };
            const first = if (now.touch) |a| (if (then.touch) |b| @min(a[0], b[0]) else a[0]) else (if (then.touch) |b| b[0] else continue);
            const last = if (now.touch) |a| (if (then.touch) |b| @max(a[1], b[1]) else a[1]) else then.touch.?[1];
            // Wholly inside both: the answer stands.
            const both: ?[2]i32 = if (before == null) null else if (now.inside) |a| (if (then.inside) |b| .{ @max(a[0], b[0]), @min(a[1], b[1]) } else null) else null;
            // Either side of what is wholly inside both, each found by one search.
            const runs: [2][2]i32 = if (both) |range| .{ .{ first, range[0] - 1 }, .{ range[1] + 1, last } } else .{ .{ first, last }, .{ 1, 0 } };
            for (runs) |run| {
                var along = space.columnsAlong(after.world, x, run[0], run[1]);
                while (along.next()) |found| try self.eachAt(found.column, found.index, player, kinds, after, before, exact);
            }
        }
    }

    /// The swept entities of some kinds where a player's answer can differ between two circles.
    fn sweptBetween(self: *Tracking, before: ?Circle, after: Circle, player: usize, kinds: Kinds) !void {
        var low: [2]f64 = .{ after.x - after.reach, after.z - after.reach };
        var high: [2]f64 = .{ after.x + after.reach, after.z + after.reach };
        if (before) |then| {
            low = .{ @min(low[0], then.x - then.reach), @min(low[1], then.z - then.reach) };
            high = .{ @max(high[0], then.x + then.reach), @max(high[1], then.z + then.reach) };
        }
        try self.eachSwept(after.world, low, high, struct {
            owner: *Tracking,
            before: ?Circle,
            after: Circle,
            player: usize,
            kinds: Kinds,
            fn visit(walk: @This(), sweep: *const Sweep) !void {
                const owner = walk.owner;
                const kind = owner.deps.entities.directory.entry(sweep.slot).kind;
                if (!walk.kinds.has(kind)) return;
                const tracker = owner.tracker_of[kind];
                // With its type's range, the circles are its own: the same answer in both stands.
                if (walk.before) |then| if (sweep.slot >= owner.metas.len or owner.metas.at(sweep.slot).range == 0) {
                    const now = distanceAnswer(sweep.box, walk.after.x, walk.after.z, walk.after.reach);
                    if (now != .unsure and now == distanceAnswer(sweep.box, then.x, then.z, then.reach)) return;
                };
                try owner.checkSweptFor(sweep.slot, sweep, tracker, walk.player);
            }
        }{ .owner = self, .before = before, .after = after, .player = player, .kinds = kinds });
    }

    /// Visits every swept entity whose box reaches into a horizontal box, of every kind's sweeps.
    fn eachSwept(self: *Tracking, world: u32, low: [2]f64, high: [2]f64, context: anytype) !void {
        for (self.sources[0..self.source_count]) |source| {
            if (source.count == 0) continue;
            const Walk = struct {
                inner: @TypeOf(context),
                source: *Sweeps,
                failure: *?anyerror,
                pub fn visit(walk: @This(), index: u32) bool {
                    walk.inner.visit(walk.source.at(index)) catch |err| {
                        walk.failure.* = err;
                        return false;
                    };
                    return true;
                }
            };
            var failure: ?anyerror = null;
            _ = source.each(world, .{ .low = .{ low[0], 0, low[1] }, .high = .{ high[0], 0, high[1] } }, 0, Walk{ .inner = context, .source = source, .failure = &failure }, false);
            if (failure) |err| return err;
        }
    }

    fn swapped(circle: Circle) Circle {
        return .{ .world = circle.world, .x = circle.z, .z = circle.x, .reach = circle.reach };
    }

    /// Every entity whose box is in a column, for one player: those placed in it, and those of
    /// the columns around whose box reaches into it.
    fn eachTouching(self: *Tracking, column: Column, player: usize) !void {
        // Players as subjects whose box reaches into it, from the list, as they are not in the space.
        if (self.player_tracker != null) for (self.player_slots, self.subject_world) |slot, world| {
            if (slot == none or world != column.world) continue;
            const placed = self.placedAt(slot) orelse continue;
            const footprint = footprintOf(placed.entry);
            if (column.x < footprint.low[0] or column.x > footprint.high[0] or column.z < footprint.low[2] or column.z > footprint.high[2]) continue;
            try self.checkFor(placed.entry, placed.world, player, .test_each);
        };
        const low: [2]f64 = .{ @as(f64, @floatFromInt(column.x)) * 16, @as(f64, @floatFromInt(column.z)) * 16 };
        try self.eachSwept(column.world, low, .{ low[0] + 16, low[1] + 16 }, struct {
            owner: *Tracking,
            player: usize,
            fn visit(walk: @This(), sweep: *const Sweep) !void {
                const owner = walk.owner;
                try owner.checkSweptFor(sweep.slot, sweep, owner.tracker_of[owner.deps.entities.directory.entry(sweep.slot).kind], walk.player);
            }
        }{ .owner = self, .player = player });
        try self.eachInColumn(column, player, self.tracked, null);
        const space = &self.deps.entities.places.space;
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                if (dx == 0 and dz == 0) continue;
                const around: Column = .{ .world = column.world, .x = column.x + dx, .z = column.z + dz };
                if (space.indexOf(around) == null) continue;
                var walk = space.entries(around, self.tracked);
                while (walk.next()) |entry| {
                    const footprint = footprintOf(entry);
                    if (column.x < footprint.low[0] or column.x > footprint.high[0] or column.z < footprint.low[2] or column.z > footprint.high[2]) continue;
                    try self.checkFor(entry, column.world, player, .test_each);
                }
            }
        }
    }

    /// The entities of a column for one player whose circle went from `before` to `circle`: only
    /// those on one side of one and the other side of the other can be answered differently, as
    /// every other input has a change of its own to ask again by.
    fn eachAt(self: *Tracking, column: Column, index: u32, player: usize, kinds: Kinds, circle: Circle, before: ?Circle, exact: bool) !void {
        const hint = circle.hint(column);
        const space = &self.deps.entities.places.space;
        const Visit = struct {
            owner: *Tracking,
            world: u32,
            player: usize,
            hint: Hint,
            fn each(visit: @This(), entry: Entry) !void {
                try visit.owner.checkFor(entry, visit.world, visit.player, visit.hint);
            }
        };
        const visit: Visit = .{ .owner = self, .world = column.world, .player = player, .hint = hint };
        if (before) |then| if (exact) return space.eachCrossing(index, kinds, .{ circle.x, circle.z }, circle.reach, .{ then.x, then.z }, then.reach, visit, Visit.each);
        var walk = space.entriesAt(index, kinds);
        while (walk.next()) |entry| try visit.each(entry);
    }

    fn eachInColumn(self: *Tracking, column: Column, player: usize, kinds: Kinds, circle: ?Circle) !void {
        const space = &self.deps.entities.places.space;
        if (space.indexOf(column) == null) return;
        const hint: Hint = if (circle) |value| value.hint(column) else .test_each;
        var walk = space.entries(column, kinds);
        while (walk.next()) |entry| try self.checkFor(entry, column.world, player, hint);
    }

    /// What to do with each entity near a player.
    const Near = enum {
        /// Its client forgot it: clear the player from it.
        forget,
        /// The player stopped being ready: tell it the entities it has are gone.
        drop,
        /// Ask about it again for the player.
        recheck,
    };

    /// Every entity a player could know, from where it stood: those within its widest reach
    /// and a little more, which is as far as any it was shown can have gone without being asked
    /// about again; and, but for a recheck, those gone.
    fn near(self: *Tracking, player: usize, was: PlayerChanges.Snapshot, mode: Near) !void {
        var widest: f64 = 0;
        for (self.trackers[0..self.tracker_count]) |tracker| widest = @max(widest, tracker.max_range);
        const reach = @min(widest, was.reach) + 32;
        const space = &self.deps.entities.places.space;
        const low_x: i32 = @intFromFloat(@floor((was.x - reach) / 16));
        const high_x: i32 = @intFromFloat(@floor((was.x + reach) / 16));
        const low_z: i32 = @intFromFloat(@floor((was.z - reach) / 16));
        const high_z: i32 = @intFromFloat(@floor((was.z + reach) / 16));
        var x = low_x;
        while (x <= high_x) : (x += 1) {
            var along = space.columnsAlong(was.world, x, low_z, high_z);
            while (along.next()) |found| {
                var walk = space.entriesAt(found.index, self.tracked);
                while (walk.next()) |entry| switch (mode) {
                    .forget => if (entry.slot < self.metas.len) self.forgetPair(entry.slot, player),
                    .drop => if (entry.slot < self.metas.len and has(self.knownWords(entry.slot), player)) try self.note(entry.slot, player, false),
                    .recheck => try self.checkFor(entry, was.world, player, .test_each),
                };
            }
        }
        // And the swept ones there.
        try self.eachSwept(was.world, .{ @as(f64, @floatFromInt(low_x)) * 16, @as(f64, @floatFromInt(low_z)) * 16 }, .{ @as(f64, @floatFromInt(high_x + 1)) * 16, @as(f64, @floatFromInt(high_z + 1)) * 16 }, struct {
            owner: *Tracking,
            player: usize,
            mode: Near,
            fn visit(walk: @This(), sweep: *const Sweep) !void {
                const owner = walk.owner;
                const slot = sweep.slot;
                switch (walk.mode) {
                    .forget => if (slot < owner.metas.len) owner.forgetPair(slot, walk.player),
                    .drop => if (slot < owner.metas.len and has(owner.knownWords(slot), walk.player)) try owner.note(slot, walk.player, false),
                    .recheck => try owner.checkSweptFor(slot, sweep, owner.tracker_of[owner.deps.entities.directory.entry(slot).kind], walk.player),
                }
            }
        }{ .owner = self, .player = player, .mode = mode });
        // And players as subjects there, from the list.
        if (self.player_tracker != null) for (self.player_slots, self.subject_at, self.subject_world) |slot, at, world| {
            if (slot == none or world != was.world or slot >= self.metas.len) continue;
            if (at[0] < was.x - reach or at[0] > was.x + reach or at[2] < was.z - reach or at[2] > was.z + reach) continue;
            switch (mode) {
                .forget => self.forgetPair(slot, player),
                .drop => if (has(self.knownWords(slot), player)) try self.note(slot, player, false),
                .recheck => if (self.placedAt(slot)) |placed| try self.checkFor(placed.entry, placed.world, player, .test_each),
            }
        };
        if (mode != .forget) return;
        // And those it may have farther off: gone, offered last tick and not taken, or moved
        // since.
        var at: usize = 0;
        while (at < self.gone.len) : (at += 1) self.forgetPair(self.gone.at(at).*, player);
        at = 0;
        while (at < self.retry.len) : (at += 1) if (self.retry.at(at).* < self.metas.len) self.forgetPair(self.retry.at(at).*, player);
        const log = space.logged();
        at = 0;
        while (at < log.len) : (at += 1) if (log.at(at).slot < self.metas.len) self.forgetPair(log.at(at).slot, player);
        if (space.log_overflowed) for (0..self.metas.len) |slot| self.forgetPair(@intCast(slot), player);
    }

    fn forget(self: *Tracking, player: usize, was: PlayerChanges.Snapshot) !void {
        return self.near(player, was, .forget);
    }

    fn forgetPair(self: *Tracking, slot: u32, player: usize) void {
        put(self.knownWords(slot), player, false);
        put(self.staleWords(slot), player, false);
        self.release(slot);
    }

    /// An entity nobody knows any more lets its slot go; one that is gone is forgotten.
    fn release(self: *Tracking, slot: u32) void {
        if (any(self.knownWords(slot))) return;
        const meta = self.metas.at(slot);
        if (meta.tracker == no_tracker) return;
        self.deps.entities.holdSlot(slot, false);
        if (meta.gone) {
            self.forgetData(meta);
            meta.* = .{};
        }
    }

    // The tick.

    /// Works out every change of audience since the last tick. Run after entities moved and
    /// players were heard, before kinds send.
    pub fn tick(self: *Tracking) !void {
        return self.pass(true);
    }

    /// The second pass of a tick, once entities ticked: what they did, answered against the
    /// players as the first pass heard them, as vanilla moves its trackers by players once a tick.
    pub fn tickEntities(self: *Tracking) !void {
        return self.pass(false);
    }

    fn pass(self: *Tracking, heard: bool) !void {
        self.tick_count += 1;
        try self.carryOver();
        const players = self.deps.players;
        if (heard) {
            self.changes.update(players);
            for (players.records, 0..) |_, index| {
                const snapshot = self.changes.snapshots[index];
                self.ready[index] = snapshot.ready;
                self.xs[index] = snapshot.x;
                self.zs[index] = snapshot.z;
                self.reaches[index] = snapshot.reach;
                self.worlds[index] = snapshot.world;
                self.spectating[index] = snapshot.spectator;
            }
            self.gatherBounds();
        } else self.changes.clearLists();
        // Cleared only when used: clearing wipes the whole table.
        if (self.near_columns.count() > 0) self.near_columns.clearRetainingCapacity();
        self.near_count = 0;
        if (self.seen_footprints.count() > 0) self.seen_footprints.clearRetainingCapacity();
        self.seen_count = 0;
        // Players as subjects move with the players, asked about as they do.
        if (heard) try self.syncPlayers();
        // Groups with nothing placed or swept have no walks to make this tick.
        const space = &self.deps.entities.places.space;
        var swept = false;
        for (self.sources[0..self.source_count]) |source| swept = swept or source.count > 0;
        var subjects = false;
        for (self.player_slots) |slot| subjects = subjects or slot != none;
        for (self.groups[0..self.group_count]) |*group| group.live = swept or space.countOf(group.kinds) > 0 or (subjects and group.kinds.has(self.player_kind));
        if (self.tracker_count == 0) {
            self.deps.entities.places.space.clearLog();
            self.finalize();
            return;
        }
        const resets = self.changes.resetList();
        for (resets) |reset| if (reset.was.ready) {
            // A client that forgot is cleared; one that only stopped being ready is told.
            // One that changed only its mode is asked about again where it stood, as it may also
            // have moved.
            if (reset.forgot) try self.forget(reset.player, reset.was) else if (!reset.now.ready) try self.near(reset.player, reset.was, .drop) else try self.near(reset.player, reset.was, .recheck);
        };
        for (resets) |reset| if (reset.now.ready) try self.disc(reset.player, reset.now);
        for (self.changes.moveList()) |move| try self.ring(move);
        for (self.changes.viewList()) |view| try self.annulus(view);
        if (self.deps.streaming) |streaming| try self.terrain(streaming.snapshotVisibility(), resets);
        // What was offered and not taken first, in full: a move logged later finds it looked at.
        var at: usize = 0;
        while (at < self.retry.len) : (at += 1) try self.again(self.retry.at(at).*);
        self.retry.reset();
        try self.logged();
        if (self.work_overflowed) try self.sweepAll();
        self.finalize();
    }

    fn gatherBounds(self: *Tracking) void {
        self.bounds_count = 0;
        for (self.ready, 0..) |ready, player| {
            if (!ready) continue;
            const at: [2]f64 = .{ self.xs[player], self.zs[player] };
            for (self.bounds[0..self.bounds_count]) |*box| {
                if (box.world != self.worlds[player] and box.world != any_world) continue;
                box.low = .{ @min(box.low[0], at[0]), @min(box.low[1], at[1]) };
                box.high = .{ @max(box.high[0], at[0]), @max(box.high[1], at[1]) };
                break;
            } else if (self.bounds_count < bounds_max) {
                self.bounds[self.bounds_count] = .{ .world = self.worlds[player], .low = at, .high = at };
                self.bounds_count += 1;
            } else {
                const last = &self.bounds[bounds_max - 1];
                last.* = .{ .world = any_world, .low = @splat(-std.math.inf(f64)), .high = @splat(std.math.inf(f64)) };
            }
        }
    }

    /// How far a box of a world is from every ready player there, horizontally, at least: zero
    /// when some may be within it, infinite when there is none.
    fn awayFromPlayers(self: *const Tracking, world: u32, low: [2]f64, high: [2]f64) f64 {
        var nearest = std.math.inf(f64);
        for (self.bounds[0..self.bounds_count]) |box| {
            if (box.world != world and box.world != any_world) continue;
            const dx = @max(0, @max(box.low[0] - high[0], low[0] - box.high[0]));
            const dz = @max(0, @max(box.low[1] - high[1], low[1] - box.high[1]));
            nearest = @min(nearest, @sqrt(dx * dx + dz * dz));
        }
        return nearest;
    }

    /// What the last tick offered and was not all accepted is asked again; the last tick's work
    /// is let go.
    fn carryOver(self: *Tracking) !void {
        for (0..self.work_slots.len) |index| {
            const slot = self.work_slots.at(index).*;
            const rows = self.item(@intCast(index));
            if (any(rows)) _ = try self.retry.append(slot);
            self.metas.at(slot).work = none;
        }
        self.work_slots.reset();
        self.work_rows.reset();
        self.work_overflowed = false;
        self.finalized = false;
        // Swept entities some player was unsure of move along their sweeps: asked again.
        var at: usize = 0;
        while (at < self.unsettled.len) : (at += 1) _ = try self.retry.append(self.unsettled.at(at).*);
        self.unsettled.reset();
        if (builtin.mode == .debug) try self.checkSweeps();
    }

    /// Every swept entity is where its sweep says: what tracking trusts its answers to.
    fn checkSweeps(self: *Tracking) !void {
        for (self.sources[0..self.source_count]) |source| {
            for (0..source.sweeps.len) |index| {
                if (!source.used(@intCast(index))) continue;
                const sweep = source.at(@intCast(index));
                _ = try self.placeOf(self.tracker_of[self.deps.entities.directory.entry(sweep.slot).kind], sweep.slot, sweep);
            }
        }
    }

    fn disc(self: *Tracking, player: usize, now: PlayerChanges.Snapshot) !void {
        self.player_slack[player] = -1;
        for (self.groups[0..self.group_count]) |tracker| {
            if (!tracker.live) continue;
            try self.eachBetween(null, .{ .world = now.world, .x = now.x, .z = now.z, .reach = @min(tracker.range, now.reach) }, player, tracker.kinds, tracker.own_ranges == 0);
        }
    }

    fn ring(self: *Tracking, move: PlayerChanges.Move) !void {
        const snapshot = self.changes.snapshots[move.player];
        for (self.groups[0..self.group_count], 0..) |tracker, group| {
            if (!tracker.live) continue;
            const reach = @min(tracker.range, snapshot.reach);
            if (self.player_tracker) |players| if (group == self.trackers[players].group and tracker.kinds.bits.count() == 1) {
                try self.playerRing(move.player, snapshot, reach);
                continue;
            };
            try self.eachBetween(
                .{ .world = snapshot.world, .x = move.from[0], .z = move.from[1], .reach = reach },
                .{ .world = snapshot.world, .x = move.to[0], .z = move.to[1], .reach = reach },
                move.player,
                tracker.kinds,
                tracker.own_ranges == 0,
            );
        }
    }

    fn annulus(self: *Tracking, view: PlayerChanges.View) !void {
        const snapshot = self.changes.snapshots[view.player];
        self.player_slack[view.player] = -1;
        for (self.groups[0..self.group_count]) |tracker| {
            if (!tracker.live) continue;
            const was = @min(tracker.range, view.from);
            const now = @min(tracker.range, view.to);
            if (was == now) continue;
            try self.eachBetween(
                .{ .world = snapshot.world, .x = snapshot.x, .z = snapshot.z, .reach = was },
                .{ .world = snapshot.world, .x = snapshot.x, .z = snapshot.z, .reach = now },
                view.player,
                tracker.kinds,
                tracker.own_ranges == 0,
            );
        }
    }

    /// Chunks sent, taken back or hidden: each such column's entities for its player, and every
    /// column in reach of a player whose view the terrain reset.
    fn terrain(self: *Tracking, visibility: *const Streaming.Visibility, resets: []const PlayerChanges.Reset) !void {
        for (visibility.reset.values()) |player| {
            if (!self.ready[player]) continue;
            for (resets) |reset| {
                if (reset.player == player) break;
            } else try self.disc(player, self.changes.snapshots[player]);
        }
        for (visibility.changed_words.values()) |word| {
            const player = word / visibility.grid.words;
            if (visibility.reset.contains(player) or !self.ready[player]) continue;
            const center = visibility.viewCenter(player);
            const x = center.x - visibility.radius;
            const z = center.z - visibility.radius;
            var bits = visibility.changed[word];
            while (bits != 0) {
                const cell: i32 = @intCast((word % visibility.grid.words) * 64 + @ctz(bits));
                bits &= bits - 1;
                if (cell >= visibility.grid.columns) continue;
                const side: i32 = @intCast(visibility.grid.width);
                const column: Column = .{
                    .world = self.worlds[player],
                    .x = x + @mod(@mod(cell, side) - @mod(x, side), side),
                    .z = z + @mod(@divTrunc(cell, side) - @mod(z, side), side),
                };
                try self.eachTouching(column, player);
            }
        }
    }

    /// Entities placed, moved and removed since the last tick.
    fn logged(self: *Tracking) !void {
        const space = &self.deps.entities.places.space;
        const log = space.logged();
        var at: usize = 0;
        while (at < log.len) : (at += 1) {
            const change = log.at(at).*;
            if (change.slot < self.metas.len and self.metas.at(change.slot).looked == self.tick_count) continue;
            try self.look(change.slot, change.event == .moved);
        }
        const overflowed = space.log_overflowed;
        space.clearLog();
        if (overflowed) try self.sweepGone();
    }

    /// Asks again about one entity by its slot, as it stands now.
    fn look(self: *Tracking, slot: u32, moved: bool) !void {
        const directory = &self.deps.entities.directory;
        if (slot >= directory.high()) return;
        // Swept: answered by its box, whatever place it kept.
        if (self.sweptIn(slot)) |swept| return self.checkSwept(slot, swept.sweep, swept.tracker);
        if (self.placedAt(slot)) |placed| {
            const entry = placed.entry;
            const world = placed.world;
            if (!self.tracked.has(entry.shape.kind)) return;
            try self.ensureSlot(slot);
            const meta = self.metas.at(slot);
            meta.looked = self.tick_count;
            if (moved and meta.tracker != no_tracker and meta.entity == entry.id and !meta.gone and self.unchanged(meta, entry, world)) return;
            try self.checkAll(entry, world);
            return;
        }
        // Gone from the space: whoever has it is told.
        if (slot >= self.metas.len) return;
        const meta = self.metas.at(slot);
        if (meta.tracker == no_tracker) return;
        meta.looked = self.tick_count;
        if (!any(self.knownWords(slot))) {
            meta.gone = true;
            self.release(slot);
            return;
        }
        if (!meta.gone) {
            meta.gone = true;
            _ = try self.gone.append(slot);
        }
        try self.owe(slot);
    }

    /// Every client that has a gone entity is to be told.
    fn owe(self: *Tracking, slot: u32) !void {
        const rows = (try self.workOf(slot)) orelse return;
        for (rows[0..self.words], rows[self.words..], self.knownWords(slot)) |*mask, *answer, have| {
            mask.* |= have;
            answer.* &= ~have;
        }
    }

    /// Asks about an entity again at the next tick, as something it said of itself changed.
    fn relook(self: *Tracking, slot: u32) !void {
        // What was settled was settled for what it said before.
        if (slot < self.metas.len) self.metas.at(slot).settled_for = 0;
        _ = try self.retry.append(slot);
    }

    fn again(self: *Tracking, slot: u32) !void {
        if (slot < self.metas.len and self.metas.at(slot).looked == self.tick_count) return;
        try self.look(slot, false);
    }

    /// The work did not fit: every entity near a ready player, and every one a client has, asked
    /// again.
    fn sweepAll(self: *Tracking) !void {
        self.work_overflowed = false;
        for (0..self.work_slots.len) |index| self.metas.at(self.work_slots.at(index).*).work = none;
        self.work_slots.clear();
        self.work_rows.clear();
        // The sweep's work is every entity near a player and every one some client has, which
        // the pool bounds and the configured work does not.
        const limit = self.config.work;
        self.config.work = std.math.maxInt(u32);
        defer self.config.work = limit;
        for (self.changes.snapshots, 0..) |snapshot, player| {
            if (!snapshot.ready) continue;
            try self.near(player, snapshot, .recheck);
        }
        // Those some client has, wherever they are and whoever it is.
        for (0..self.metas.len) |index| {
            const slot: u32 = @intCast(index);
            if (self.metas.at(slot).tracker == no_tracker or !any(self.knownWords(slot))) continue;
            try self.look(slot, false);
        }
    }

    /// The log could not hold a removal: every tracked slot no longer placed is looked at.
    fn sweepGone(self: *Tracking) !void {
        for (0..self.metas.len) |index| {
            const slot: u32 = @intCast(index);
            const meta = self.metas.at(slot);
            if (meta.tracker == no_tracker or meta.gone or self.placedAt(slot) != null) continue;
            try self.look(slot, false);
        }
    }

    /// Turns each entity's answers into whom to spawn it for and whom to remove it from.
    fn finalize(self: *Tracking) void {
        for (0..self.work_slots.len) |index| {
            const slot = self.work_slots.at(index).*;
            const rows = self.item(@intCast(index));
            const gone = self.metas.at(slot).gone;
            for (rows[0..self.words], rows[self.words..], self.knownWords(slot)) |*mask_word, *answer_word, have| {
                const mask = mask_word.*;
                const want = if (gone) 0 else answer_word.*;
                mask_word.* = want & ~have & mask;
                answer_word.* = have & ~want & mask;
            }
        }
        // A gone entity that has its removals owed keeps them; the list keeps only those.
        var kept: usize = 0;
        for (0..self.gone.len) |index| {
            const slot = self.gone.at(index).*;
            if (self.metas.at(slot).gone and any(self.knownWords(slot))) {
                self.gone.at(kept).* = slot;
                kept += 1;
            }
        }
        while (self.gone.len > kept) self.gone.pop();
        self.finalized = true;
    }

    // What kinds read.

    /// This tick's changes for one tracker's entities, in the order they were found.
    pub fn changesOf(self: *const Tracking, tracker: TrackerId) Changes {
        assert(self.finalized);
        return .{ .owner = self, .tracker = tracker };
    }

    pub const Changes = struct {
        owner: *const Tracking,
        tracker: TrackerId,
        at: usize = 0,

        pub fn next(self: *Changes) ?Change {
            while (self.at < self.owner.work_slots.len) {
                const index = self.at;
                self.at += 1;
                const slot = self.owner.work_slots.at(index).*;
                if (self.owner.metas.at(slot).tracker != self.tracker) continue;
                if (self.owner.changeAt(@intCast(index))) |change| return change;
            }
            return null;
        }
    };

    fn changeAt(self: *const Tracking, index: u32) ?Change {
        const slot = self.work_slots.at(index).*;
        const rows = self.item(index);
        if (!any(rows)) return null;
        return .{ .slot = slot, .spawn = self.set(rows[0..self.words]), .remove = self.set(rows[self.words..]), .gone = self.metas.at(slot).gone };
    }

    /// Asks about an entity again now, after the tick's changes were worked out, as something it
    /// said of itself changed since: its change becomes what it now must be. Every player is
    /// asked, as this is rare.
    pub fn reconsider(self: *Tracking, slot: u32) !void {
        assert(self.finalized);
        if (slot >= self.metas.len) return;
        const meta = self.metas.at(slot);
        if (meta.tracker == no_tracker or meta.gone) return;
        const tracker = &self.trackers[meta.tracker];
        const placed = if (self.sweptIn(slot)) |swept| try self.placeOf(swept.tracker, slot, swept.sweep) else self.placedAt(slot) orelse return;
        const wanted = self.scratch[0..self.words];
        @memset(wanted, 0);
        const range = self.rangeOf(tracker, slot);
        for (0..self.deps.players.records.len) |player| {
            if (self.sees(slot, placed.entry, placed.world, range, player, .test_each)) put(wanted, player, true);
        }
        const known_words = self.knownWords(slot);
        var differs = meta.work != none;
        for (known_words, wanted) |have, want| differs = differs or have != want;
        if (!differs) return;
        const rows = (try self.workOf(slot)) orelse return;
        for (rows[0..self.words], rows[self.words..], known_words, wanted) |*spawn, *remove, have, want| {
            spawn.* = want & ~have;
            remove.* = have & ~want;
        }
    }

    /// The change for one entity this tick, if any: for kinds that walk their own order.
    pub fn changed(self: *const Tracking, slot: u32) ?Change {
        assert(self.finalized);
        if (slot >= self.metas.len) return null;
        const work = self.metas.at(slot).work;
        if (work == none) return null;
        return self.changeAt(work);
    }

    /// What of a change was accepted: those spawned have the entity now, those removed not.
    /// What was not accepted is offered again next tick.
    pub fn confirm(self: *Tracking, slot: u32, spawned: bit_sets.Set, removed: bit_sets.Set) void {
        const meta = self.metas.at(slot);
        assert(meta.work != none);
        const rows = self.item(meta.work);
        const known_words = self.knownWords(slot);
        const stale_words = self.staleWords(slot);
        for (rows[0..self.words], rows[self.words..], known_words, stale_words, 0..) |*spawn, *remove, *have, *behind, word| {
            const taken = spawn.* & wordOf(spawned, word);
            const dropped = remove.* & wordOf(removed, word);
            have.* = (have.* | taken) & ~dropped;
            // A fresh spawn carries the whole state; a removal ends it.
            behind.* &= ~(taken | dropped);
            spawn.* &= ~taken;
            remove.* &= ~dropped;
        }
        if (!any(known_words)) return self.release(slot);
        if (!meta.gone) self.deps.entities.holdSlot(slot, true);
    }

    /// Players who missed a delta of an entity they have: they need its state whole.
    pub fn missed(self: *Tracking, slot: u32, players: bit_sets.Set) void {
        for (self.staleWords(slot), self.knownWords(slot), 0..) |*word, have, index| word.* |= wordOf(players, index) & have;
    }

    /// Players sent an entity's state whole: they have it as it stands.
    pub fn caughtUp(self: *Tracking, slot: u32, players: bit_sets.Set) void {
        for (self.staleWords(slot), 0..) |*word, index| word.* &= ~wordOf(players, index);
    }

    // The oracle.

    /// updatePlayer asked of every tracked entity and every player, against what clients have:
    /// with every change confirmed, they agree. For tests and checked benches.
    pub fn check(self: *Tracking) !void {
        for (0..self.metas.len) |index| {
            const slot: u32 = @intCast(index);
            const meta = self.metas.at(slot);
            // A swept one where its kind says it is.
            const placed = if (self.sweptIn(slot)) |swept| try self.placeOf(swept.tracker, slot, swept.sweep) else self.placedAt(slot);
            const tracker_index = if (placed) |value| self.tracker_of[value.entry.shape.kind] else meta.tracker;
            if (tracker_index == no_tracker) continue;
            const known_words = self.knownWords(slot);
            for (0..self.deps.players.records.len) |player| {
                const wanted = if (placed) |value| self.sees(slot, value.entry, value.world, self.rangeOf(&self.trackers[tracker_index], slot), player, .test_each) else false;
                if (wanted != has(known_words, player)) {
                    std.log.err("event=tracking_mismatch slot={d} player={d} wanted={} known={} placed={} gone={} margin={d} epoch={d}/{d} at={d},{d} player_at={d},{d} reach={d} ready={} tick={d} looked={d}", .{ slot, player, wanted, has(known_words, player), placed != null, meta.gone, meta.margin, meta.epoch, self.changes.epoch, meta.x, meta.z, self.xs[player], self.zs[player], self.reaches[player], self.ready[player], self.tick_count, meta.looked });
                    if (placed) |value| std.log.err("event=tracking_mismatch_entity position={any} kind={d}", .{ value.entry.position, value.entry.shape.kind });
                    return error.TrackingMismatch;
                }
            }
        }
    }
};

/// Tracking's second pass each tick, once entities ticked: what they did is answered for that
/// tick, as vanilla tells of an entity added or removed at once. The first pass, before player
/// replication, answers for the players' own moves.
pub const TrackingPass = struct {
    pub const id = "lightning_rod:tracking_pass";
    pub const Configuration = struct {};
    pub const Dependencies = struct { tracking: *Tracking };

    tracking: *Tracking,

    pub fn init(allocator: std.mem.Allocator, _: Configuration, deps: Dependencies) !*TrackingPass {
        const self = try allocator.create(TrackingPass);
        self.* = .{ .tracking = deps.tracking };
        return self;
    }

    pub fn tick(self: *TrackingPass) !void {
        try self.tracking.tickEntities();
    }
};
